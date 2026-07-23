# Backend — VI→EN Realtime Translation Service

See `../BACKEND.md` for full design. This is the setup/run quickstart.

## Setup

```bash
uv sync

# Download Gipformer (vi) + Whisper base.en (en) ASR weights
./scripts/download_models.sh

# Install llama.cpp (serves the translation model)
brew install llama.cpp
```

## Run

Two processes, both required:

```bash
# Terminal 1 — translation server (port 8081), downloads the model into
# backend/models/llm/ on first run. --no-mmproj skips the vision projector
# (unused for text translation). enable_thinking:false is required — Qwen3.5
# defaults to "thinking" mode (burns the token budget on <think>...</think>
# reasoning before any real output otherwise, confirmed in testing).
# --slot-prompt-similarity 1.0 is required — our requests share an identical
# system prompt, so llama-server's default slot-reuse heuristic (matches
# requests to cached slots by prompt similarity, default threshold 0.10) was
# treating unrelated translation requests as similar enough to reuse a stale
# KV cache, causing hallucinated/repeated output from a prior request
# (confirmed in testing — log showed "selected slot by LCP similarity").
# 1.0 forces near-exact match, effectively disabling harmful reuse.
# --ctx-size 2048 caps the KV-cache memory footprint — default (0) loads
# Qwen3.5's full native context window, which is far more than a short
# single-segment translation prompt needs. Cuts RAM/VRAM use significantly;
# raise if segments are ever long enough to overflow 2048 tokens (unlikely
# for a few sentences of speech).
# --no-cache-prompt is required — confirmed via `llama-server --help`:
# --cache-prompt defaults to ENABLED, a separate mechanism from
# --slot-prompt-similarity (that one controls slot *assignment*; this one
# reuses KV state for matching prefix tokens WITHIN a slot). Our requests
# deliberately share a large identical prefix (system prompt + rolling
# CONTEXT block, see BACKEND.md "Core Design"), and with prompt caching on,
# the model was observed regurgitating the cached CONTEXT verbatim instead
# of translating the new segment — confirmed live: identical request bodies
# returned the correct new-segment translation at cached_tokens=0, then
# echoed the context back verbatim at cached_tokens=206/290 on repeat calls.
# --no-cache-prompt forces every request to reprocess its full prompt fresh.
LLAMA_CACHE="$(pwd)/models/llm" llama-server -hf unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL \
    --no-mmproj --port 8081 \
    --chat-template-kwargs '{"enable_thinking":false}' \
    --slot-prompt-similarity 1.0 \
    --no-cache-prompt \
    --ctx-size 2048

# Terminal 2 — this backend (port 8000)
uv run uvicorn app.main:app --host 127.0.0.1 --port 8000
```

The Swift client connects to `ws://127.0.0.1:8000/ws`.

Weights land in `backend/models/llm/`, alongside `backend/models/gipformer/`
— keeps all downloaded model weights under one `models/` dir instead of
llama.cpp's global `~/Library/Caches/llama.cpp/` default. Run the
`llama-server` command from `backend/` (as shown) so `$(pwd)/models/llm`
resolves correctly; use an absolute path if launching from elsewhere.

If you already ran the command without `--no-mmproj`, a `mmproj-BF16.gguf`
(~644MB vision projector, unused) was auto-downloaded alongside the real
weights — safe to delete: `rm models/llm/models--unsloth--Qwen3.5-9B-GGUF/snapshots/*/mmproj-BF16.gguf`.

## Status

Mic + video-file → dual ASR (Gipformer + Whisper base.en) → llama-server
(Qwen3.5-9B) → bilingual JSON round-trip confirmed working at various points;
see BACKEND.md "Core Design" for full history. Fixed issues (thinking-mode
token burn, slot-cache-reuse hallucination — see git history / BACKEND.md
"Model Setup" for `--chat-template-kwargs`/`--slot-prompt-similarity` flags
if these resurface).

**Rolling context, re-added at 9B — two real bugs found and fixed, see
BACKEND.md "Core Design" attempts 2–3 for the full diagnosis:**

1. llama-server's `--cache-prompt` (default enabled) was reusing KV state
   across requests sharing an identical prefix (system prompt + repeated
   CONTEXT block) — confirmed live via `cached_tokens` in the raw response:
   `0` → correct translation, `206`/`290` on repeat calls → context echoed
   back verbatim as `translated_text`. Fixed: `--no-cache-prompt` added to
   the launch command below.
2. Separately, even at `cached_tokens: 0`, the model itself sometimes echoed
   context on short/low-content segments — same shape as the original 4B
   failure mode, now confirmed at 9B too (lower frequency, not zero).
   Mitigated: `CONTEXT_WINDOW` dropped 2→1 (`session_state.py`), and
   `bonsai.py`'s prompt now puts an explicit `---` divider + `NEW SEGMENT TO
   TRANSLATE NOW (ignore everything above, translate only this):` header
   right before the ASR outputs. Verified 5/5 on the adversarial segment
   that was failing ~2/3 before — small sample, not a guarantee at
   temperature 0.2, re-test in live multi-segment use.

**Restart llama-server (updated flags below) before testing this.**

**Bilingual VI⇄EN mode** — every segment runs through both Gipformer (vi)
and Whisper base.en (en) in parallel, and the LLM call returns JSON
`{source_language, translated_text}` via `response_format`/`json_schema`
instead of a plain English string — see BACKEND.md "Bilingual
Transcription". Backend module imports verified clean and both ASR models
load successfully, but no live mic/video run has fully confirmed: (a) the
LLM reliably distinguishing real vs. garbled ASR output, (b)
`response_format` JSON-schema actually constraining Qwen3.5-9B's output on
this llama-server build, (c) translation direction correctness for both
vi→en and en→vi.

**Restart both llama-server (updated model/command below) and the Python
backend (context + bilingual logic changed) — re-test end to end.**

- Confirm `/v1/chat/completions` response's `content` field is now
  non-empty, matches the actual input segment, and isn't leftover `<think>`
  tags or reused from a different request.
- Sampler settings (`LLM_TEMPERATURE=0.2`, `LLM_TOP_P=0.85`) carried over
  from the Bonsai setup, not re-tuned for Qwen3.5 — revisit if translation
  quality or determinism seems off.
- Confirm `sherpa_onnx.OfflineRecognizer.from_transducer(...)` kwargs match the installed sherpa-onnx version (verified against upstream examples at design time, but pin/check on install).
- Confirm `silero-vad`'s `VADIterator` event dict shape (`{"start": ...}` / `{"end": ...}`) matches installed version.

The earlier Bonsai/MLX setup (`vendor/bonsai-demo/`) is left on disk but no
longer the active path — can delete it if not needed for comparison.
