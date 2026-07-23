#!/bin/sh
# Downloads Gipformer ONNX weights and sets up the Bonsai MLX server (via
# the vendored Bonsai-demo repo, which owns the MLX fork build + weight
# download). Run from backend/.
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
echo "=== Whisper base.en (English ASR) ==="
python -c "
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id='csukuangfj/sherpa-onnx-whisper-base.en',
    local_dir='$BACKEND_DIR/models/whisper-base.en',
    allow_patterns=['base.en-encoder.int8.onnx', 'base.en-decoder.int8.onnx', 'base.en-tokens.txt'],
)
"

echo ""
echo "=== Bonsai-8B (translation, MLX 1-bit) ==="
if [ ! -d "$BACKEND_DIR/vendor/bonsai-demo" ]; then
    git clone https://github.com/PrismML-Eng/Bonsai-demo.git "$BACKEND_DIR/vendor/bonsai-demo"
fi
cd "$BACKEND_DIR/vendor/bonsai-demo"
: "${HF_TOKEN:?Set HF_TOKEN in your shell env before running this script}"
BONSAI_MODEL=8B BONSAI_FAMILY=bonsai ./setup.sh

# setup.sh clones the MLX fork at branch `prism` tip, which can drift past
# the commit the 1-bit weights were actually validated against (README.md
# "Tested versions" pins 88c9c205a50f). A newer tip has been observed to
# break `mx.quantize(..., bits=1)` ("requested number of bits 1 is not
# supported"). Force the pinned commit and rebuild the editable install.
PINNED_MLX_COMMIT="88c9c205a50f"
if [ -d mlx/.git ]; then
    CURRENT_MLX_COMMIT="$(git -C mlx rev-parse HEAD)"
    case "$CURRENT_MLX_COMMIT" in
        "$PINNED_MLX_COMMIT"*) ;;
        *)
            echo ""
            echo "=== Pinning MLX fork to validated commit $PINNED_MLX_COMMIT (was $CURRENT_MLX_COMMIT) ==="
            git -C mlx checkout "$PINNED_MLX_COMMIT"
            uv pip install --python .venv/bin/python -e mlx/ --no-build-isolation --reinstall-package mlx
            ;;
    esac
fi

echo ""
echo "Done. Start the translation server separately with:"
echo "  cd vendor/bonsai-demo && BONSAI_MODEL=8B BONSAI_FAMILY=bonsai ./scripts/start_mlx_server.sh"
