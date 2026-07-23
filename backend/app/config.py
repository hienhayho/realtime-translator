"""Central config: model paths, audio params, windowing. See BACKEND.md."""

from pathlib import Path

BACKEND_ROOT = Path(__file__).resolve().parent.parent

# Audio
SAMPLE_RATE = 16_000
CHANNELS = 1

# VAD
VAD_THRESHOLD = 0.5
# Lower = segments finalize faster on natural pauses (less perceived
# latency), at the cost of risking a cut mid-thought on brief hesitation
# pauses. Gipformer is offline-only (no streaming decode — see BACKEND.md
# "ASR Mode Decision"), so this silence wait is the dominant latency source
# before a segment can even be transcribed. Tune down from the original 500
# if segments still feel slow; watch for segments getting cut too early if
# pushed much lower than this.
VAD_MIN_SILENCE_MS = 200  # silence duration that ends a speech segment
VAD_MIN_SPEECH_MS = 250  # ignore blips shorter than this
# Force a segment cut if speech runs continuously this long without a
# VAD-detected pause (e.g. a speaker who doesn't stop). Without this, a long
# monologue would buffer indefinitely and only get transcribed once silence
# finally happens — bad for both perceived latency and Whisper/Gipformer
# accuracy on very long single-shot inputs. See BACKEND.md "Latency".
VAD_MAX_SEGMENT_MS = 10_000

# Gipformer ASR (sherpa-onnx offline transducer) — Vietnamese
# Filenames confirmed against HF repo g-group-ai-lab/gipformer-65M-rnnt file listing.
GIPFORMER_MODEL_DIR = BACKEND_ROOT / "models" / "gipformer"
GIPFORMER_ENCODER = GIPFORMER_MODEL_DIR / "encoder-epoch-35-avg-6.int8.onnx"
GIPFORMER_DECODER = GIPFORMER_MODEL_DIR / "decoder-epoch-35-avg-6.int8.onnx"
GIPFORMER_JOINER = GIPFORMER_MODEL_DIR / "joiner-epoch-35-avg-6.int8.onnx"
GIPFORMER_TOKENS = GIPFORMER_MODEL_DIR / "tokens.txt"
GIPFORMER_NUM_THREADS = 2
GIPFORMER_DECODING_METHOD = "greedy_search"  # or "modified_beam_search"

# Whisper base.en ASR (sherpa-onnx offline whisper) — English
# Filenames confirmed against HF repo csukuangfj/sherpa-onnx-whisper-base.en file listing.
WHISPER_MODEL_DIR = BACKEND_ROOT / "models" / "whisper-base.en"
WHISPER_ENCODER = WHISPER_MODEL_DIR / "base.en-encoder.int8.onnx"
WHISPER_DECODER = WHISPER_MODEL_DIR / "base.en-decoder.int8.onnx"
WHISPER_TOKENS = WHISPER_MODEL_DIR / "base.en-tokens.txt"
WHISPER_NUM_THREADS = 2

# Translation LLM (llama-server, OpenAI-compatible HTTP). Currently Qwen3.5-9B
# UD-Q4_K_XL — swapped from Bonsai-8B 1-bit (too low quality), then upgraded
# from Qwen3.5-4B to 9B to make rolling cross-segment context viable. See
# BACKEND.md "Model Setup" and "Core Design".
#
# Bilingual mode: each segment is transcribed by BOTH Gipformer (vi) and
# Whisper tiny.en (en) in parallel (see app/asr/bilingual.py). The LLM gets
# both raw ASR outputs (plus a little rolling context, see session_state.py)
# and returns JSON {source_language, translated_text} — it picks whichever
# transcript is coherent and translates into the other language. See
# BACKEND.md "Bilingual Transcription".
#
# NOTE: llama-server is a separate process we don't launch from this app, so
# this path isn't read by Python code — it documents where the model lives.
# Launch llama-server with LLAMA_CACHE set to this path (see backend/README.md).
LLM_MODEL_DIR = BACKEND_ROOT / "models" / "llm"
LLM_SERVER_URL = "http://127.0.0.1:8081"
LLM_CHAT_ENDPOINT = f"{LLM_SERVER_URL}/v1/chat/completions"
LLM_TEMPERATURE = 0.2  # low — translation wants determinism, not creativity
LLM_TOP_P = 0.85
# Qwen3.5 defaults to "thinking" mode (emits <think>...</think> reasoning
# before the actual answer) unless the server is launched with
# --chat-template-kwargs '{"enable_thinking":false}' — see backend/README.md.
# 512 leaves headroom even if thinking isn't fully disabled server-side.
LLM_MAX_TOKENS = 512
LLM_REQUEST_TIMEOUT_S = 30.0

# WebSocket server
WS_HOST = "127.0.0.1"
WS_PORT = 8000
