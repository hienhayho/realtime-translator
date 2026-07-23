#!/bin/sh
# Downloads the ASR weights needed for a fresh install: Gipformer (Vietnamese,
# always used, never swapped) and Whisper tiny.en (English, the default STT
# tier — see config.py's WHISPER_TIER). Other Whisper tiers (base.en,
# medium.en) and the LLM GGUF are NOT downloaded here — both download lazily
# on first selection/use (see BACKEND.md "Bilingual Transcription" and
# macapp's BackendProcessManager). Run from backend/.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Gipformer (Vietnamese ASR) ==="
python -c "
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id='g-group-ai-lab/gipformer-65M-rnnt',
    local_dir='$BACKEND_DIR/models/gipformer',
)
"

echo ""
echo "=== Whisper tiny.en (English ASR, default tier) ==="
python -c "
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id='csukuangfj/sherpa-onnx-whisper-tiny.en',
    local_dir='$BACKEND_DIR/models/whisper-tiny.en',
    allow_patterns=['tiny.en-encoder.int8.onnx', 'tiny.en-decoder.int8.onnx', 'tiny.en-tokens.txt'],
)
"

echo ""
echo "Done. Translation model (Qwen3.5, via llama-server) and other Whisper"
echo "tiers download automatically on first use — see backend/README.md."
