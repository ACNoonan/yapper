# Kokoro Speak — TTS on a hotkey

Local [Kokoro-82M](https://github.com/hexgrad/kokoro) TTS server + a tiny native macOS menubar app that speaks your selected text when you hit a hotkey. Apple Silicon only.

Spiritual mirror image of [kitlangton/Hex](https://github.com/kitlangton/Hex) — that app does voice → text on a hotkey, this one does text → voice. The two compose nicely: dictate prompts into your editor with Hex, listen to responses back with Kokoro Speak.

## Pieces

- `server.py` — FastAPI HTTP server wrapping `kokoro` (KPipeline). Preloads the model at startup. Exposes `POST /speak` (one WAV for the whole clip) and `POST /speak_stream` (length-prefixed WAV frames per sentence, for low first-audio latency). Both share an LRU cache.
- `LaunchAgents/com.example.kokoro.plist` — template launchd agent that keeps the server alive at login. Install it into `~/Library/LaunchAgents/`.
- `KokoroSpeak/` — Swift Package menubar app. Global hotkey → grab selection (accessibility API, with Cmd+C fallback) → POST to server → play WAV via `AVAudioPlayer`.

## Default hotkeys

| Action | Shortcut |
|--------|----------|
| Speak selected text (toggles stop while speaking) | `⌃⇧S` |
| Hard-stop playback | `⌃⇧.` |

Change them at any time from the menu bar → **Settings…** (or `⌘,` while the settings window is in focus). The recorder picks up whatever combination you press.

## Setup from scratch

```bash
# 1. Phonemizer fallback (needed by Kokoro for some words/languages)
brew install espeak-ng

# 2. Python deps via uv
uv sync          # creates .venv, installs from uv.lock

# 3. Server smoke test
uv run python server.py    # then: curl http://127.0.0.1:8765/health

# 4. Build the menubar app
cd KokoroSpeak && ./build.sh && open KokoroSpeak.app

# 5. Run server at login via launchd
cp LaunchAgents/com.example.kokoro.plist ~/Library/LaunchAgents/
# Edit the plist: replace every __REPLACE__ with your $HOME (e.g. /Users/you)
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.example.kokoro.plist
```

## Managing the launchd agent

```bash
# Status
launchctl print "gui/$(id -u)/com.example.kokoro" | grep state

# Restart
launchctl kickstart -k "gui/$(id -u)/com.example.kokoro"

# Stop / Start
launchctl bootout  "gui/$(id -u)" ~/Library/LaunchAgents/com.example.kokoro.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.example.kokoro.plist

# Logs
tail -f ~/Library/Logs/kokoro/server.out.log ~/Library/Logs/kokoro/server.err.log
```

Quick sanity check:

```bash
curl -s http://127.0.0.1:8765/health
curl -s -X POST http://127.0.0.1:8765/speak \
    -H 'Content-Type: application/json' \
    -d '{"text":"Hello"}' -o /tmp/t.wav && afplay /tmp/t.wav
```

## Building the menubar app

```bash
cd KokoroSpeak
./build.sh
open KokoroSpeak.app
```

### Stable code signing (optional but recommended)

`build.sh` signs the app with a self-signed certificate named **`KokoroSpeak Local`** if it finds one in your login keychain, otherwise it falls back to ad-hoc signing. The difference matters: ad-hoc signatures change on every rebuild, so macOS treats each build as a new app and you have to re-grant Accessibility every time. A stable self-signed cert keeps the same code-signing identity across rebuilds, so the grant sticks.

Create the cert once (Keychain Access → **Certificate Assistant → Create a Certificate…**):

- **Name:** `KokoroSpeak Local`
- **Identity Type:** Self Signed Root
- **Certificate Type:** Code Signing

Leave it in the login keychain. `build.sh` will pick it up automatically on the next build. This cert is local-only — it does **not** make the app distributable to other machines (that needs an Apple Developer ID + notarization).

### First-launch permissions

KokoroSpeak needs **Accessibility** access to read selected text from the focused app and synthesize Cmd+C as a fallback.

1. Launch the app once (`open KokoroSpeak/KokoroSpeak.app`). A 🔊 icon should appear in the menu bar.
2. macOS will prompt for Accessibility, or you can open: **System Settings → Privacy & Security → Accessibility** and enable **KokoroSpeak**.
3. Quit and relaunch the app after granting.
4. Highlight text anywhere, hit `⌃⇧S`.

### Run at login

Drag `KokoroSpeak.app` into **System Settings → General → Login Items → Open at Login**.

## Customizing

- **Voice**: menubar → Voice. Defaults to `af_heart`. Other curated voices listed in the menu; many more exist on the [Kokoro model card](https://huggingface.co/hexgrad/Kokoro-82M).
- **Speed**: menubar → Speed. Range 0.5–2.0.
- **Hotkey**: menubar → **Settings…** → click the recorder field, press your combination.
- **Server port**: set `KOKORO_PORT` in the launchd plist and the `KOKORO_URL` env var when launching the app.

## Known limitations

- The app streams sentence-by-sentence (`/speak_stream`): playback starts after the first sentence is synthesized and the rest plays back-to-back, so long passages don't wait for the full clip. The plain `/speak` endpoint (full clip in one WAV) is still available for scripting.
- American English only by default. To enable other languages, install the extras (`pip install misaki[ja]` etc.) and pass `lang_code` in the request body.
- Apple Silicon only (matches Hex).
