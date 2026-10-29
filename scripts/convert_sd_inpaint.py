"""Converts Stable Diffusion 1.5 inpainting to Core ML for AI removal.

Usage: python convert_sd_inpaint.py <diffusers model dir> <output dir>

The app runs its own sampling loop (DPM-Solver++ 2M, classifier-free
guidance), so only these are converted:

- SDInpaintUNet.mlpackage: the 9-channel inpainting UNet, batch 2 (unconditional and
  conditional), 6-bit palettized weights.
- SDInpaintVAEEncoder.mlpackage: 512×512 RGB image -> 4×64×64 latent (scaled by 0.18215).
- SDInpaintVAEDecoder.mlpackage: latent -> 512×512 RGB image.
- SDInpaintEmbeddings.bin: the text embeddings for the removal prompt and the negative
  prompt (float32, 2×77×768, negative first), so the app needs no tokenizer
  or text encoder.

Model: stable-diffusion-v1-5/stable-diffusion-inpainting, CreativeML OpenRAIL-M.
"""
import json
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from diffusers import AutoencoderKL, UNet2DConditionModel
from transformers import CLIPTextModel, CLIPTokenizer

# What a removal asks for, and what it should avoid. Tuned on real photos (docs/spikes/diffusion-inpaint.md).
PROMPT = "empty background, seamless natural continuation of the surroundings, photo"
NEGATIVE = "person, people, man, woman, object, text, logo, watermark, blurry, artifacts, frame, border"
SCALE = 0.18215


class UNet(torch.nn.Module):
    def __init__(self, unet):
        super().__init__()
        self.unet = unet

    def forward(self, sample, timestep, encoder_hidden_states):
        return self.unet(sample, timestep, encoder_hidden_states, return_dict=False)[0]


class Encoder(torch.nn.Module):
    """0–255 RGB in (as Core ML image inputs provide) -> scaled latent mean."""

    def __init__(self, vae):
        super().__init__()
        self.vae = vae

    def forward(self, image):
        moments = self.vae.quant_conv(self.vae.encoder(image / 127.5 - 1.0))
        mean, _ = torch.chunk(moments, 2, dim=1)
        return mean * SCALE


class Decoder(torch.nn.Module):
    """Scaled latent -> 0–255 RGB."""

    def __init__(self, vae):
        super().__init__()
        self.vae = vae

    def forward(self, latent):
        image = self.vae.decoder(self.vae.post_quant_conv(latent / SCALE))
        return torch.clamp((image + 1.0) * 127.5, 0.0, 255.0)


def embeddings(source: Path) -> np.ndarray:
    tokenizer = CLIPTokenizer.from_pretrained(source / "tokenizer")
    encoder = CLIPTextModel.from_pretrained(source / "text_encoder", variant="fp16").float().eval()
    out = []
    for text in [NEGATIVE, PROMPT]:
        ids = tokenizer(text, padding="max_length", max_length=77, truncation=True, return_tensors="pt").input_ids
        with torch.no_grad():
            out.append(encoder(ids)[0][0].numpy())
    return np.stack(out).astype(np.float32)


def convert(module, inputs, outputs, name):
    traced = torch.jit.trace(module.eval(), tuple(torch.zeros(*s) if isinstance(s, tuple) else s for s in [i[1] for i in inputs]), check_trace=False)
    model = ct.convert(
        traced,
        inputs=[spec for spec, _ in inputs],
        outputs=outputs,
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16,
    )
    model.license = "CreativeML OpenRAIL-M"
    model.short_description = f"Stable Diffusion 1.5 inpainting: {name}"
    return model


def main():
    source, destination = Path(sys.argv[1]), Path(sys.argv[2])
    only = sys.argv[3] if len(sys.argv) > 3 else None  # "vae" or "unet", to rerun one part
    destination.mkdir(parents=True, exist_ok=True)

    if only is None:
        embeddings(source).tofile(destination / "SDInpaintEmbeddings.bin")
        (destination / "SDInpaintPrompts.json").write_text(json.dumps({"negative": NEGATIVE, "prompt": PROMPT}, indent=2))
        print("embeddings", flush=True)
    if only in (None, "vae"):
        convert_vae(source, destination)
    if only in (None, "unet"):
        convert_unet(source, destination)


def convert_vae(source: Path, destination: Path):
    vae = AutoencoderKL.from_pretrained(source / "vae", variant="fp16").float().eval()
    vae.set_default_attn_processor()  # The SDPA processor's shape math doesn't convert.
    encoder = convert(Encoder(vae), [(ct.ImageType(name="image", shape=(1, 3, 512, 512), color_layout=ct.colorlayout.RGB), (1, 3, 512, 512))],
                      [ct.TensorType(name="latent")], "VAE encoder")
    encoder.save(destination / "SDInpaintVAEEncoder.mlpackage")
    print("encoder", flush=True)
    decoder = convert(Decoder(vae), [(ct.TensorType(name="latent", shape=(1, 4, 64, 64)), (1, 4, 64, 64))],
                      [ct.ImageType(name="image", color_layout=ct.colorlayout.RGB)], "VAE decoder")
    decoder.save(destination / "SDInpaintVAEDecoder.mlpackage")
    print("decoder", flush=True)


def convert_unet(source: Path, destination: Path):
    unet = UNet2DConditionModel.from_pretrained(source / "unet", variant="fp16").float().eval()
    unet.set_default_attn_processor()
    model = convert(UNet(unet), [
        (ct.TensorType(name="sample", shape=(2, 9, 64, 64)), (2, 9, 64, 64)),
        (ct.TensorType(name="timestep", shape=(2,)), torch.tensor([999.0, 999.0])),
        (ct.TensorType(name="encoder_hidden_states", shape=(2, 77, 768)), (2, 77, 768)),
    ], [ct.TensorType(name="noise")], "UNet")
    print("unet converted", flush=True)
    config = ct.optimize.coreml.OptimizationConfig(
        global_config=ct.optimize.coreml.OpPalettizerConfig(nbits=6, mode="kmeans", granularity="per_grouped_channel", group_size=16)
    )
    model = ct.optimize.coreml.palettize_weights(model, config)
    model.save(destination / "SDInpaintUNet.mlpackage")
    print("unet palettized", flush=True)


if __name__ == "__main__":
    main()
