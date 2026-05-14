"""Kokoro TTS HTTP server.

Loads a KPipeline at startup so the first request is fast. Synthesizes a full
WAV per request and returns it. Designed to run as a launchd agent on
127.0.0.1.
"""

from __future__ import annotations

import io
import logging
import os
from contextlib import asynccontextmanager

import numpy as np
import soundfile as sf
import torch
from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel, Field

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("kokoro-server")

SAMPLE_RATE = 24_000
DEFAULT_LANG = os.environ.get("KOKORO_LANG", "a")
DEFAULT_VOICE = os.environ.get("KOKORO_VOICE", "af_heart")

# Curated list — Kokoro ships more, but these are the well-tested American
# English voices from the model card. Extend as you wish.
AMERICAN_ENGLISH_VOICES = [
    "af_heart", "af_bella", "af_nicole", "af_sarah", "af_sky",
    "am_adam", "am_michael",
]

pipelines: dict[str, "KPipeline"] = {}


def get_pipeline(lang_code: str):
    if lang_code not in pipelines:
        from kokoro import KPipeline

        log.info("loading KPipeline for lang_code=%s", lang_code)
        pipelines[lang_code] = KPipeline(lang_code=lang_code)
    return pipelines[lang_code]


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
    return {"ok": True, "loaded_langs": list(pipelines.keys())}


@app.get("/voices")
def voices():
    return {"default": DEFAULT_VOICE, "american_english": AMERICAN_ENGLISH_VOICES}


@app.post("/speak")
def speak(req: SpeakRequest):
    try:
        pipeline = get_pipeline(req.lang_code)
        chunks: list[np.ndarray] = []
        for _, _, audio in pipeline(
            req.text, voice=req.voice, speed=req.speed, split_pattern=r"\n+"
        ):
            chunks.append(audio.cpu().numpy() if hasattr(audio, "cpu") else np.asarray(audio))
        if not chunks:
            raise HTTPException(status_code=400, detail="no audio produced")
        full = np.concatenate(chunks).astype(np.float32)
        buf = io.BytesIO()
        sf.write(buf, full, SAMPLE_RATE, format="WAV", subtype="PCM_16")
        return Response(content=buf.getvalue(), media_type="audio/wav")
    except HTTPException:
        raise
    except Exception as e:
        log.exception("synthesis failed")
        raise HTTPException(status_code=500, detail=str(e))


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "server:app",
        host="127.0.0.1",
        port=int(os.environ.get("KOKORO_PORT", "8765")),
        log_level="info",
        reload=False,
    )
