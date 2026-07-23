# Backend Plan — Bilingual VI⇄EN Realtime Translation Service

## Goal

Local Python service: mic/video audio in → realtime transcript in whichever of Vietnamese/English was spoken → realtime translation into the other language out. Runs entirely offline on Apple Silicon Mac. Exposes WebSocket API for the SwiftUI client. See "Bilingual Transcription" below for the dual-ASR design.

## Tech Stack

| Layer | Choice | Why |
|---|---|---|
| Language | Python 3.11+ | ASR/LLM ecosystem, MLX/onnxruntime bindings |
| Package/env mgr | `uv` | Gipformer repo already uses it, fast |
| Server | FastAPI + `websockets` (via `uvicorn`) | Simple WS streaming, async-friendly |
| VAD | Silero VAD (`torch.hub` or ONNX export) | Lightweight, accurate speech-segment boundaries |
| ASR (vi) | Gipformer via `sherpa-onnx` (offline recognizer) | Vietnamese ASR, 65M params — repo's own example uses sherpa-onnx offline transducer API, not raw onnxruntime |
| ASR (en) | Whisper base.en via `sherpa-onnx` (offline recognizer, `from_whisper`) | English ASR, runs every segment alongside Gipformer — see "Bilingual Transcription" |
| Translation + language disambiguation | Qwen3.5-9B, `UD-Q4_K_XL` GGUF (Unsloth), served via `llama-server` (OpenAI-compatible HTTP, port 8081) | Switched from Bonsai-8B 1-bit — translation quality was too degraded at 1-bit. Upgraded from Qwen3.5-4B to 9B to make rolling cross-segment context viable (4B confused context with the actual task, see "Core Design"). Also does source-language disambiguation between the two ASR outputs (JSON `response_format`), see "Bilingual Transcription". Our app talks HTTP, doesn't embed llama.cpp directly |
| Audio I/O | `sounddevice` (PortAudio) for dev; Swift AVAudioEngine sends PCM over WS in prod | Dev testing without Swift app |
| Inter-process | Localhost-only WebSocket (Swift↔our backend) + localhost HTTP (our backend↔llama-server) | Keeps Swift/Python decoupled, no network exposure; translation server isolated as its own process |

## Pipeline (offline-ASR mode — see "ASR Mode Decision" below)

```
[Swift client]
   │  binary PCM frames (16kHz mono int16), streamed over WS
   ▼
[VAD] ── buffers audio, detects speech segment start/end
   │  full speech segment (silence-terminated, ~1–4s typical utterance)
   ▼
[Gipformer ASR] ── vi transcribe        [Whisper base.en ASR] ── en transcribe
   │  both run in parallel (asyncio.to_thread) on the SAME segment audio
   ▼                                       ▼
   └────────────────┬──────────────────────┘
                     ▼
[Qwen3.5-9B via llama-server] ── receives BOTH raw ASR outputs, picks the real
   │  one (source_language) and translates it into the other language
   │  {"source_language": "vi", "translated_text": "Hello everyone."}
   ▼
[WS push to Swift client] ── asr_final {text: source_text, source_language},
                              translation_update {text: translated_text, source_language}
```

### ASR Mode Decision

Gipformer's README does not confirm whether its Zipformer encoder is exported causal (streaming-capable) or non-causal (offline-only). The repo's own `infer_onnx.py` example uses sherpa-onnx's **offline** recognizer pattern (`create_recognizer` + `transcribe`, whole-file in, text out) — not `OnlineRecognizer`. Building against the confirmed offline path for v1.

**Consequence:** no mid-utterance ASR partials. Latency is VAD-endpoint-to-transcript, not word-by-word streaming. UI must be designed around "text appears per completed utterance," not "text grows word by word" (see UI.md).

**Upgrade path:** if Gipformer later confirms a streaming/causal export, swap `asr/gipformer.py` internals to `sherpa_onnx.OnlineRecognizer.from_transducer()` + `create_stream()`/`accept_waveform()`/`decode_stream()` — the module's external interface (segment in, text out) can stay the same, so this is a contained change.

## Bilingual Transcription

Original design assumed every speaker is Vietnamese. Extended to handle mixed VI/EN conversations (e.g. a Vietnamese speaker and an English speaker on the same call) without a dedicated language-ID model:

- **Every finalized VAD segment is transcribed by both ASR models in parallel** — Gipformer (vi-only vocabulary) and Whisper base.en (`sherpa_onnx.OfflineRecognizer.from_whisper(..., language="en", task="transcribe")`, en-only). Whichever model ran on the wrong-language audio typically emits empty or garbled text (out-of-vocabulary sounds don't decode to coherent text), so no separate lang-ID step is needed before ASR.
- **Both raw ASR outputs go to Qwen3.5-9B in one request.** The system prompt asks the model to decide which transcript is real (`source_language`) and translate it into the *other* language (`translated_text`) — so a VI segment produces an EN translation and vice versa, symmetric/bidirectional instead of VI→EN only.
- **Constrained via `response_format: {type: "json_schema", ...}`** in the `/v1/chat/completions` request body (llama-server's OpenAI-compatible surface supports this — grammar-backed on the server side, not just prompt-asked, so output is always valid JSON matching `{source_language: "vi"|"en", translated_text: string}`).
- If both ASR outputs come back empty (silence misdetected as speech, or audio too garbled for either model), the segment is dropped — no WS message sent.
- Client-visible effect: the app's two columns are now labeled **Transcription** (source text + `[Vietnamese]`/`[English]` tag per segment) and **Translation** (translated text + the opposite-language tag) instead of a fixed VI/EN split — see UI.md.

## Core Design: Per-Segment Translation with Rolling Context

History:

1. **No context** (each segment translated fully independently) — baseline, works but pronouns/terminology can drift slightly across sentences since the model has no memory of prior phrasing.
2. **Rolling context, attempt 1** (fed last N locked EN segments alongside the new VI segment, instructed "translate only the new part, don't restate context") — tried to fix (1)'s drift. Backfired in testing: Qwen3.5-**4B**, being a small model, would sometimes confuse the reference context with the actual task — echoing/duplicating the prior context into its output, or (separately) occasionally returning the Vietnamese input untranslated. Both symptoms observed directly in the running app, not theoretical.
3. **Back to no context** — the context-confusion bugs were worse than the cross-segment consistency loss it was meant to fix, at 4B scale.
4. **Rolling context, attempt 2** — model upgraded to Qwen3.5-**9B**; context confusion is a known small-model failure mode (per attempt 1's postmortem), worth retrying at the larger size. `SessionState.recent_context()` returns the last `CONTEXT_WINDOW` (2) locked `translated_text` values, oldest first, kept flowing across a source-language switch. Passed to `BonsaiTranslator.translate(vi_text, en_text, context=...)`, inserted into the user message as a clearly-labeled `CONTEXT (reference only, do NOT translate or repeat this):` block. **Still reproduced the attempt-1 symptom (context echoed verbatim into `translated_text`) at 9B** — but root cause turned out to be different from attempt 1: not the model confusing context with task, but llama-server's `--cache-prompt` (default enabled) reusing KV state across requests sharing an identical prefix (system prompt + repeated CONTEXT block), which biased the model toward continuing the cached tokens instead of attending to the new segment. Confirmed via direct HTTP calls: identical request body returned the correct translation at `cached_tokens: 0`, then echoed the context verbatim at `cached_tokens: 206`/`290` on repeat calls.
5. **Rolling context, attempt 3 (current)** — `--no-cache-prompt` added to the llama-server launch command (see "Model Setup"), fixing the caching-driven echo. But re-testing an adversarial short/low-content segment (`"Gì đâu đúng không tụi em ok anh chỉ cho em tả nha đầu tiên á"`) at `cached_tokens: 0` still echoed context 2/3 times — a second, independent, model-level failure mode (genuine context/task confusion, same shape as attempt 1's original 4B bug, now confirmed at 9B too with lower but nonzero frequency). Two mitigations applied together: (a) `CONTEXT_WINDOW` dropped from 2 to 1 (`session_state.py`) — less context text for the model to latch onto; (b) `bonsai.py`'s user-message layout changed to put an explicit `---` divider and a `NEW SEGMENT TO TRANSLATE NOW (ignore everything above, translate only this):` header directly before the ASR outputs, and the context block's own label strengthened to `(reference only, do NOT translate, repeat, or continue this — it is from EARLIER segments, already handled)`. Verified against the same adversarial segment: 5/5 correct after this change (was failing ~2/3 before).

- `SessionState` tracks segment history/IDs and is now also the source of rolling context (`recent_context()`), see `app/translate/session_state.py`.
- Two distinct bugs were conflated at first — always separate "is prompt caching stale?" (check `cached_tokens` in the raw HTTP response) from "is the model itself confused?" (test the exact same request body twice; if the *first* call at `cached_tokens: 0` already echoes, it's the model, not the cache) before changing flags or prompts.
- 5/5 on one adversarial input is not a large sample — if echoing recurs in live use, this is a probabilistic failure mode (temperature 0.2, not 0), not something one clean test run rules out permanently.

### Prompt format

```
System: You are a real-time bilingual Vietnamese<->English transcription
disambiguator and translator. You receive two automatic speech recognition
(ASR) outputs for the SAME audio segment: one from a Vietnamese-only ASR
model, one from an English-only ASR model. Exactly one of them is a real
transcript of the actual speech; the other is from the wrong-language model
and will usually be empty, nonsensical, or garbled. Decide which one is real
(source_language), then translate that real transcript into the OTHER
language (translated_text) — if source_language is 'vi', translated_text
must be English; if source_language is 'en', translated_text must be
Vietnamese. You may also receive a few prior translated lines as CONTEXT —
that is reference only, for keeping pronouns/terminology/topic consistent.
NEVER translate, repeat, summarize, or continue the context — only ever
translate the new ASR output for THIS segment. Output nothing but the JSON
object — no notes, no explanations.

User: CONTEXT (reference only, do NOT translate or repeat this):
- '{prior translated_text N-1}'
- '{prior translated_text N}'

Vietnamese ASR output: '{vi_asr_text}'
English ASR output: '{en_asr_text}'
```

(Context block is omitted entirely for the first segment(s) of a session, before any prior translation exists.)

Response constrained to `{"source_language": "vi"|"en", "translated_text": string}` via `response_format`/`json_schema` — see "Bilingual Transcription" above.

**Known issue (pre-bilingual, may resurface):** occasionally the model returned the Vietnamese input verbatim instead of translating. Not re-verified since the bilingual/JSON-schema rework — revisit if it reproduces.

## Project Structure

```
backend/
├── pyproject.toml            # uv-managed deps
├── README.md                 # setup/run instructions
├── app/
│   ├── main.py                # FastAPI app, WS endpoint
│   ├── config.py               # model paths, sample rate, window sizes
│   ├── audio/
│   │   ├── vad.py              # Silero VAD wrapper, segment detection
│   │   └── buffer.py           # rolling PCM ring buffer
│   ├── asr/
│   │   ├── gipformer.py        # sherpa-onnx OfflineRecognizer wrapper (vi), one-shot segment transcribe
│   │   ├── whisper.py          # sherpa-onnx OfflineRecognizer.from_whisper wrapper (en), one-shot segment transcribe
│   │   └── types.py            # FinalResult dataclass (no partials in offline mode)
│   ├── translate/
│   │   ├── bonsai.py           # httpx client → local llama-server (OpenAI-compatible HTTP); named bonsai.py for now, serves Qwen3.5 since the switch. Takes both ASR outputs, returns {source_language, translated_text} via JSON-schema response_format — see "Bilingual Transcription"
│   │   └── session_state.py    # segment history/ID sequencing per WS session (no longer builds translation context — see "Core Design" above)
│   └── ws/
│       └── protocol.py         # message schema (see below)
├── vendor/
│   └── bonsai-demo/             # gitignored — no longer the active translation path, kept on disk from the earlier Bonsai/MLX setup; see Model Setup below
├── models/                     # gitignored — downloaded weights
│   ├── gipformer/               # ONNX encoder/decoder/joiner (HF: g-group-ai-lab/gipformer-65M-rnnt)
│   └── whisper-base.en/         # ONNX encoder/decoder (HF: csukuangfj/sherpa-onnx-whisper-base.en)
└── scripts/
    ├── download_models.sh
    └── bench_latency.py         # measure end-to-end latency offline
```

## WebSocket Protocol

**Client → Server**
- Binary frames: raw PCM16 audio chunks (streamed continuously while mic open)
- `{"type": "control", "action": "start" | "stop" | "reset"}`

**Server → Client**
```jsonc
{"type": "asr_final", "text": "Xin chào các bạn.", "source_language": "vi", "segment_id": 3}
{"type": "translation_update", "text": "Hello, everyone.", "source_language": "vi", "is_final": true, "segment_id": 3}
{"type": "asr_final", "text": "How are you?", "source_language": "en", "segment_id": 4}
{"type": "translation_update", "text": "Bạn khỏe không?", "source_language": "en", "is_final": true, "segment_id": 4}
{"type": "error", "message": "..."}
```

`source_language` is the language of `text`/the ASR transcript in both message types — client infers target language as the opposite (only two languages supported). No `asr_partial` — offline ASR has no mid-utterance output (see "ASR Mode Decision"). `is_final` is always `true` today (kept in the schema for forward-compat, no revision flow exists).

`is_final` on translation locks that segment in the UI (no more revision); client should visually distinguish locked vs. still-updating text.

## Latency

No formal budget/benchmark script exists yet (`scripts/bench_latency.py` referenced in the original plan was never built) — perceived latency has been tuned reactively based on actual usage, not measured. Real latency sources, in order of impact:

1. **VAD silence wait** (`VAD_MIN_SILENCE_MS`, currently 300ms) — dominant source. Gipformer is offline-only (no streaming decode, see "ASR Mode Decision"), so nothing can start transcribing until VAD confirms the speaker paused. This is the main lever available for perceived responsiveness; lowering it trades against risk of cutting a segment mid-thought on a brief hesitation pause.
2. **Gipformer transcribe** — one-shot whole-segment decode, roughly proportional to segment length. No streaming/partial output possible with the current model (see "ASR Mode Decision" upgrade path if this changes).
3. **Qwen3.5-9B translation** — timing not re-measured since the 4B→9B upgrade (4B was observed ~2.4s for a 256-token generation); actual time depends on response length and `enable_thinking` being correctly disabled (a thinking-mode miss burns tokens without producing translation, see backend/README.md Status). Now also carries the rolling-context block in the prompt (see "Core Design"), which adds a small amount of input length per request.

4. **Max segment duration cap** (`VAD_MAX_SEGMENT_MS`, 5s): if speech runs continuously with no VAD-detected pause (e.g. a long monologue), `SpeechSegmenter` force-cuts a segment boundary at this duration instead of buffering indefinitely — bounds worst-case wait on long continuous speech without needing true streaming ASR. The cut is a boundary on our side only: Silero's own VAD state isn't reset, so if the speaker is still talking, the next window immediately starts accumulating the next segment (no re-trigger delay). See `app/audio/vad.py`.

## Model Setup

- **Gipformer**: install `sherpa-onnx` + `huggingface_hub`. Weights pulled from HF repo `g-group-ai-lab/gipformer-65M-rnnt` (encoder/decoder/joiner ONNX triple, fp32 or int8). Load via `sherpa_onnx.OfflineRecognizer.from_transducer(...)`, decode with `create_stream()` → `accept_waveform()` → `recognizer.decode_stream()` → `stream.result.text` (whole segment at once, per confirmed offline pattern — see ASR Mode Decision above).
  - **Case normalization**: Gipformer's vocabulary is uppercase-only (confirmed in `models/gipformer/tokens.txt` — every token is ALL CAPS, the model was trained that way, no case information exists to preserve). Raw output is always shouting-case. Worse than just a display issue: feeding uppercase VI text into the translation prompt was observed priming Qwen3.5 to mirror uppercase into its English output too. `gipformer.py`'s `transcribe()` now lowercases + sentence-cases the result before it's used anywhere downstream (ASR display and translation input both benefit).
- **Whisper base.en**: install via the same `sherpa-onnx` dependency already used for Gipformer — `sherpa_onnx.OfflineRecognizer.from_whisper(encoder, decoder, tokens, language="en", task="transcribe")` (confirmed via `inspect.signature` against the installed `sherpa-onnx` version). Weights pulled from HF repo `csukuangfj/sherpa-onnx-whisper-base.en` (filenames confirmed via HF API file listing: `base.en-encoder.int8.onnx`, `base.en-decoder.int8.onnx`, `base.en-tokens.txt` — int8 quant, matching Gipformer's quant choice). `language="en"` fixes English-only decode, skipping Whisper's language-detection step since we already know which ASR slot this is.
- **Translation model — Qwen3.5-9B** (switched from Bonsai-8B 1-bit, too low quality for translation; then from Qwen3.5-4B, upgraded to 9B to make rolling context viable — see "Core Design"): served via `llama-server` (from Homebrew's `llama.cpp` formula — `brew install llama.cpp`, ships Metal-accelerated `llama-server`/`llama-cli` prebuilt, no source build needed on Apple Silicon).
  ```bash
  brew install llama.cpp
  cd backend
  LLAMA_CACHE="$(pwd)/models/llm" llama-server -hf unsloth/Qwen3.5-9B-GGUF:UD-Q4_K_XL \
      --no-mmproj --port 8081 \
      --chat-template-kwargs '{"enable_thinking":false}' \
      --slot-prompt-similarity 1.0 \
      --no-cache-prompt \
      --ctx-size 2048
  ```
  `-hf <repo>:<quant>` downloads and caches the GGUF directly (confirmed via `llama-server --help`: `-hf, -hfr, --hf-repo <user>/<model>[:quant]`) — no separate download script step needed, unlike Gipformer/Bonsai. Repo confirmed real: `unsloth/Qwen3.5-9B-GGUF` on HF (verified via HF API file listing), quant tag `UD-Q4_K_XL` = Unsloth's dynamic 4-bit (better quality-per-bit than plain `Q4_K_M`, per Unsloth's own recommendation).
  - **`--no-mmproj`**: `unsloth/Qwen3.5-9B-GGUF` ships a vision projector (`mmproj-BF16.gguf`, ~644MB) that `-hf` auto-downloads by default (confirmed via `llama-server --help`: "mmproj is also downloaded automatically if available. to disable, add --no-mmproj"). We don't need image input for text translation — `--no-mmproj` skips that download entirely.
  - **`--chat-template-kwargs '{"enable_thinking":false}'`**: required. Qwen3.5 defaults to "thinking" mode — confirmed in testing that without this flag, the model burned its entire `LLM_MAX_TOKENS` budget (256 at the time) on `<think>...</think>` reasoning and the EN column stayed empty (llama-server logs showed requests completing normally at exactly 256/256 tokens, no errors — the response was just never useful text). Also bumped `LLM_MAX_TOKENS` to 512 in `config.py` as headroom.
  - **`--slot-prompt-similarity 1.0`**: required. Default `-sps` threshold (0.10) let llama-server match unrelated translation requests to a stale cached slot since every request shares an identical system prompt — confirmed via server log (`selected slot by LCP similarity, sim_best = 0.535 (> 0.100 thold)`) and observed symptom: EN output for one segment was hallucinated or verbatim-identical to a *different* segment's previous translation, not related to that segment's actual VI input. `1.0` forces near-exact prompt match before reusing a slot's KV cache, eliminating the false-positive reuse. Each of our requests differs (different `vi_window`), so this doesn't lose any legitimate caching benefit we were relying on.
  - **`--no-cache-prompt`**: required, discovered after re-adding rolling context (see "Core Design" attempt 2). `--cache-prompt` defaults to **enabled** — a distinct mechanism from `--slot-prompt-similarity` (that one decides which slot a request lands on; this one reuses KV state for matching prefix tokens *within* a slot). Since our requests deliberately share a large identical prefix (system prompt + the CONTEXT block, which repeats verbatim across consecutive segments), confirmed live via direct HTTP calls that identical request bodies returned the correct new-segment translation at `cached_tokens: 0`, then on repeat calls with `cached_tokens: 206` / `290`, the model instead echoed the CONTEXT block back verbatim as `translated_text` — ignoring the actual new ASR input entirely. Same failure signature as attempt 1's 4B echo bug, but caused by a different mechanism (prompt caching, not slot-similarity) and reproducible at 9B too. `--no-cache-prompt` forces every request to reprocess its full prompt fresh, eliminating this.
  - **`--ctx-size 2048`**: caps KV-cache memory (RAM/VRAM) footprint. Default (`-c 0`) loads the model's full native context window — far more than needed for a system prompt + a couple lines of context + one short segment (see "Core Design"). Raise if the rolling-context prompt ever grows enough to overflow 2048 tokens (unlikely at `CONTEXT_WINDOW = 2`). Other flags confirmed via `llama-server --help` for further memory tuning if 2048 isn't enough: `-ngl/--gpu-layers` (offload fewer layers to VRAM, trades to CPU RAM instead), `-b/-ub` (batch size, default 2048/512), `-fit-target` (auto-fit memory margin, default 1024MiB per device).
  - **Download location**: defaults to `~/Library/Caches/llama.cpp/` on macOS. We set `LLAMA_CACHE` (checked first, ahead of `HF_HOME`) to `backend/models/llm/`, matching Gipformer's convention of keeping all weights under `backend/models/`. `config.py`'s `LLM_MODEL_DIR` documents this path (not read by Python — llama-server is a separate process — but keeps the convention discoverable in code).
  - `translate/bonsai.py` → generalize to `translate/llm_client.py` (or keep the filename if not yet renamed — it's already a generic OpenAI-compatible HTTP client, only `config.py`'s endpoint/port and possibly the prompt format need to change).
  - `http://127.0.0.1:8081/v1/chat/completions`, same as before — `llama-server` implements the same OpenAI-compatible surface `mlx_lm.server` did, so the client code itself barely changes.
  - Qwen models use their own chat template (`<|im_start|>`/`<|im_end|>` ChatML-style) — `llama-server`'s `/v1/chat/completions` applies the GGUF's embedded template automatically from the `messages` array, same as before. No manual template string needed.
- Server process managed independently (start `llama-server` before our backend, or have our backend spawn/supervise it — same open decision as before, unresolved).
- Historical note: the Bonsai/MLX setup (PrismML-Eng fork, `vendor/bonsai-demo/`, `mx.quantize` pin issue) is no longer the active path but the vendored repo/venv can stay on disk if you want to compare quality later — nothing here deletes it.

## Open Items / To Validate

- [RESOLVED] Gipformer streaming vs offline — building offline v1, see "ASR Mode Decision" above.
- [RESOLVED] Bonsai-8B 1-bit MLX translation quality — confirmed too degraded, switched to Qwen3.5 via llama-server (4B initially, later 9B — see "Core Design").
- Decide segment/session reset behavior (e.g. long pauses, speaker changes).
- Not yet tuned: sampler settings (`temp`/`top_p`) for Qwen3.5-9B translation — carried over from the 4B setup, not re-tuned for the larger model, pick values and verify determinism/quality once running.
- Not yet decided: whether to keep the `-hf` direct-download flow (simplest, downloads on first `llama-server` launch) or pre-download via a script step matching the Gipformer/Bonsai pattern — direct-download is fine for now but means first startup is slow (fetching ~2-3GB).

## Non-goals (v1)

- No multi-speaker diarization (per-segment source-language detection exists, but not per-speaker identity).
- No cloud fallback — strictly local.
- No languages beyond VI⇄EN (bidirectional between exactly these two — see "Bilingual Transcription").
