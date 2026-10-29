# Spike: diffusion inpainting for Remove

**Question:** can Stable Diffusion inpainting, running on-device in Core ML, beat LaMa for object removal, and how should it be used?

**Answer:** yes, as a second pass over LaMa. Diffusion alone tends to invent a new object where the old one was; started from LaMa's fill at strength 0.6, it removes the object and makes the area look like a photo.

## Setup

- Model: `stable-diffusion-v1-5/stable-diffusion-inpainting` (9-channel UNet), DPM-Solver++ 2M, guidance 7.5, 512 px crops cut by the app's own `InpaintStore.modelInputs` from the full-resolution A7R V and X-T5 fixtures.
- Prompt: "empty background, seamless natural continuation of the surroundings, photo". Negative: "person, people, man, woman, object, text, logo, watermark, blurry, artifacts, frame, border".
- Run in PyTorch on the Mac first, to judge quality before converting anything.

## Findings

1. **Masks that cut through an object** (part of a runner): every method completes the object. That's not a fair test of removal; whole-object masks are what Remove is for.
2. **Whole objects, diffusion alone** (`images/diffusion-whole-object.jpg`: original, mask, three seeds, then LaMa): a railing came out clean in one of three seeds. In a crowd, every seed paints a different, plausible person. LaMa leaves gray smears where people were and softens structure (the door edge).
3. **LaMa, then diffusion** (`images/diffusion-lama-refine.jpg`: original, LaMa, then strength 0.45, 0.6, 0.75): at 0.6 the person at the edge is gone, replaced by street and background crowd, and the railing area keeps the door's detail. At 0.75 it starts inventing people again; at 0.45 LaMa's smear shows through.
4. Speed (M4 Pro, PyTorch MPS, fp16): about 19 s for 30 full steps at batch 2, about 12 s at strength 0.6 (18 steps).

## Decisions

- Engine "LaMa + diffusion": LaMa at 512 px, then 30-step DPM-Solver++ at strength 0.6. "Try another" changes the seed (stored on the spot as `variation`).
- No Stable Diffusion runtime package: the app runs its own sampler (`DiffusionSampler`) with converted models and precomputed prompt embeddings, so there's no tokenizer or text encoder to ship.
- UNet palettized to 6 bits (about 650 MB); total about 850 MB with the VAE.

## Conversion notes

- coremltools 8.3 fails with numpy 2 ("only 0-dimensional arrays can be converted to Python scalars"); pin `numpy<2`.
- The VAE needs `set_default_attn_processor()`; diffusers' SDPA processor doesn't trace cleanly.
- Palettizing with k-means needs scikit-learn and takes a long time on one core.

## Open questions

- Device timing and memory on the iPhone 16 Pro and the M1 iPad Pro, and whether the Neural Engine gives correct output (it returned noise for LaMa at 1024; the diffusion models run on CPU+GPU for now).
