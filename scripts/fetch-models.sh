#!/bin/zsh
# Downloads and converts the AI models into Models/ (not checked in):
# - Depth Anything V2 Small (Apache-2.0, Apple's Core ML conversion) -> Models/DepthAnything.mlpackage
#   (~50 MB, downloaded as is) for depth range masks. DEPTH_ONLY=1 stops after it.
# - LaMa (big-lama, Apache-2.0) -> Models/LaMa.mlpackage (~100 MB)
# - Stable Diffusion 1.5 inpainting (CreativeML OpenRAIL-M) -> Models/SDInpaint* (~850 MB)
#   Skip it with SKIP_DIFFUSION=1; the app then hides the diffusion engine.
# The model isn't checked in (about 100 MB); the app builds without it and then
# hides AI removal. Needs `uv` (https://docs.astral.sh/uv/).
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/download" Models

# Depth Anything V2 Small, pinned to a revision and checked by SHA-256.
depth_rev=cfef6f6f2a70783dedc0bfae40cecbc2052285d3
depth_url=https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/$depth_rev/DepthAnythingV2SmallF16.mlpackage
depth=$work/DepthAnything.mlpackage
mkdir -p $depth/Data/com.apple.CoreML/weights
for file in Manifest.json Data/com.apple.CoreML/model.mlmodel Data/com.apple.CoreML/weights/weight.bin; do
    curl -L --fail -s -o "$depth/$file" "$depth_url/$file"
done
shasum -a 256 -c - <<SUMS
2883ae290c48fe916dc5ececac03a7d847fa277165a49ef5652fa1d2b9cb55f7  $depth/Manifest.json
44ac97a3efcfd52113183fb2862ff59cd0368e9ec2e30a90a54980dd11407042  $depth/Data/com.apple.CoreML/model.mlmodel
fa60d9b6a155734f59029ebb882fd54e549bfaee3539c1a9cbd2cbbab64a0fed  $depth/Data/com.apple.CoreML/weights/weight.bin
SUMS
rm -rf Models/DepthAnything.mlpackage && mv $depth Models/
[[ -n "${DEPTH_ONLY:-}" ]] && exit 0

curl -L --fail -o "$work/download/big-lama.pt" https://github.com/Sanster/models/releases/download/add_big_lama/big-lama.pt
echo "e3aa4aaa15225a33ec84f9f4bc47e500  $work/download/big-lama.pt" | md5sum -c - 2>/dev/null \
    || [[ "$(md5 -q "$work/download/big-lama.pt")" == "e3aa4aaa15225a33ec84f9f4bc47e500" ]]
uv venv --python 3.12 "$work/venv"
uv pip install --python "$work/venv/bin/python" torch==2.5.1 coremltools==8.3 numpy
rm -rf Models/LaMa.mlpackage
"$work/venv/bin/python" -I scripts/convert_lama.py "$work/download/big-lama.pt" Models/LaMa.mlpackage

# Stable Diffusion 1.5 inpainting, for "LaMa + diffusion". Takes 20–40 minutes.
if [[ -z "${SKIP_DIFFUSION:-}" ]]; then
    uv venv --python 3.11 "$work/sd-venv"
    # coremltools 8.3 needs numpy < 2; scikit-learn is for palettizing.
    uv pip install --python "$work/sd-venv/bin/python" torch==2.5.1 coremltools==8.3 diffusers==0.31.0 transformers==4.46.3 \
        accelerate safetensors huggingface_hub "numpy<2" scikit-learn
    "$work/sd-venv/bin/python" -I -c "
from huggingface_hub import snapshot_download
snapshot_download('stable-diffusion-v1-5/stable-diffusion-inpainting', local_dir='$work/sd', allow_patterns=[
    'tokenizer/*', 'text_encoder/config.json', 'text_encoder/model.fp16.safetensors', 'unet/config.json',
    'unet/diffusion_pytorch_model.fp16.safetensors', 'vae/config.json', 'vae/diffusion_pytorch_model.fp16.safetensors'])"
    rm -rf Models/SDInpaint*
    "$work/sd-venv/bin/python" -I scripts/convert_sd_inpaint.py "$work/sd" Models
fi
