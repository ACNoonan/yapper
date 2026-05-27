"""Kokoro TTS HTTP server.

Loads a KPipeline at startup so the first request is fast. Exposes:

  POST /speak         — synthesize full text, return a single WAV.
  POST /speak_stream  — length-prefixed WAV frames (big-endian u32 + WAV) per
                        Kokoro chunk as they're produced.

Both share an LRU cache keyed on (text, voice, speed, lang).
"""

from __future__ import annotations

import io
import logging
import os
import struct
from collections import OrderedDict
from contextlib import asynccontextmanager
from hashlib import sha256
from threading import Lock
from typing import Iterator

import numpy as np
import soundfile as sf
import torch
from fastapi import FastAPI, HTTPException
from fastapi.responses import Response, StreamingResponse
from pydantic import BaseModel, Field

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("kokoro-server")

SAMPLE_RATE = 24_000
DEFAULT_LANG = os.environ.get("KOKORO_LANG", "a")
DEFAULT_VOICE = os.environ.get("KOKORO_VOICE", "af_heart")
CACHE_MAX_ENTRIES = int(os.environ.get("KOKORO_CACHE_ENTRIES", "64"))

# Split on sentence-ending punctuation OR newlines so each pipeline chunk stays
# under Kokoro's ~30s-per-utterance ceiling and the stream endpoint flushes
# audio every sentence (low first-audio latency on long passages).
SPLIT_PATTERN = r"(?<=[.!?])\s+|\n+"

AMERICAN_ENGLISH_VOICES = [
    "af_heart", "af_bella", "af_nicole", "af_sarah", "af_sky",
    "am_adam", "am_michael",
]

pipelines: dict[str, "KPipeline"] = {}

_cache: "OrderedDict[str, list[np.ndarray]]" = OrderedDict()
_cache_lock = Lock()


def get_pipeline(lang_code: str):
    if lang_code not in pipelines:
        from kokoro import KPipeline

        log.info("loading KPipeline for lang_code=%s", lang_code)
        pipelines[lang_code] = KPipeline(lang_code=lang_code)
    return pipelines[lang_code]


def _cache_key(text: str, voice: str, speed: float, lang_code: str) -> str:
    h = sha256()
    h.update(f"{voice}\x00{speed}\x00{lang_code}\x00".encode())
    h.update(text.encode("utf-8"))
    return h.hexdigest()


def _cache_get(key: str) -> "list[np.ndarray] | None":
    with _cache_lock:
        chunks = _cache.get(key)
        if chunks is not None:
            _cache.move_to_end(key)
            return list(chunks)
    return None


def _cache_put(key: str, chunks: "list[np.ndarray]") -> None:
    with _cache_lock:
        _cache[key] = chunks
        _cache.move_to_end(key)
        while len(_cache) > CACHE_MAX_ENTRIES:
            _cache.popitem(last=False)


def _audio_to_wav(audio: np.ndarray) -> bytes:
    buf = io.BytesIO()
    sf.write(buf, audio, SAMPLE_RATE, format="WAV", subtype="PCM_16")
    return buf.getvalue()


def synth_audio_chunks(text: str, voice: str, speed: float, lang_code: str) -> Iterator[np.ndarray]:
    """Yield one int16 numpy array per Kokoro chunk. Cache-aware."""
    key = _cache_key(text, voice, speed, lang_code)
    cached = _cache_get(key)
    if cached is not None:
        log.info("cache hit (%d chunks)", len(cached))
        for arr in cached:
            yield arr
        return

    pipeline = get_pipeline(lang_code)
    collected: list[np.ndarray] = []
    for _, _, audio in pipeline(text, voice=voice, speed=speed, split_pattern=SPLIT_PATTERN):
        arr = audio.cpu().numpy() if hasattr(audio, "cpu") else np.asarray(audio)
        as_int16 = (np.clip(arr, -1.0, 1.0) * 32767.0).astype(np.int16)
        collected.append(as_int16)
        yield as_int16
    if collected:
        _cache_put(key, collected)


@asynccontextmanager
async def lifespan(app: FastAPI):
    if torch.backends.mps.is_available():
        log.info("MPS available (Apple Silicon GPU)")
    get_pipeline(DEFAULT_LANG)
    log.info("warm — ready on default lang=%s voice=%s", DEFAULT_LANG, DEFAULT_VOICE)
    yield


app = FastAPI(title="Kokoro TTS", lifespan=lifespan)


class SpeakRequest(BaseModel):
    text: str = Field(..., min_length=1, max_length=20_000)
    voice: str = DEFAULT_VOICE
    speed: float = Field(1.0, ge=0.5, le=2.0)
    lang_code: str = DEFAULT_LANG


@app.get("/health")
def health():
    return {
        "ok": True,
        "loaded_langs": list(pipelines.keys()),
        "cache_entries": len(_cache),
    }


@app.get("/voices")
def voices():
    return {"default": DEFAULT_VOICE, "american_english": AMERICAN_ENGLISH_VOICES}


@app.post("/speak")
def speak(req: SpeakRequest):
    try:
        chunks = list(synth_audio_chunks(req.text, req.voice, req.speed, req.lang_code))
        if not chunks:
            raise HTTPException(status_code=400, detail="no audio produced")
        full = np.concatenate(chunks)
        return Response(content=_audio_to_wav(full), media_type="audio/wav")
    except HTTPException:
        raise
    except Exception as e:
        log.exception("synthesis failed")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/speak_stream")
def speak_stream(req: SpeakRequest):
    def generate() -> Iterator[bytes]:
        try:
            for arr in synth_audio_chunks(req.text, req.voice, req.speed, req.lang_code):
                wav = _audio_to_wav(arr)
                yield struct.pack(">I", len(wav)) + wav
        except Exception:
            log.exception("stream synthesis failed")
            return

    return StreamingResponse(generate(), media_type="application/octet-stream")


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "server:app",
        host="127.0.0.1",
        port=int(os.environ.get("KOKORO_PORT", "8765")),
        log_level="info",
        reload=False,
    )
