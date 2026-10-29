#!/bin/zsh
# Downloads and converts the AI removal models into Models/ (not checked in):
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
