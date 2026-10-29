# Third-party components

LightEditor's own source is under [LICENSE](LICENSE). It has **no third-party code dependencies**: the app uses only Apple's frameworks (SwiftUI, Core Image, Metal, PhotoKit, Vision, Core ML, Network, CryptoKit). The only third-party components are the two optional AI models below. Neither is checked into this repository; `scripts/fetch-models.sh` downloads and converts them into `Models/`, and the app bundles whatever is there.

**If you distribute a build that includes these models** (TestFlight, the App Store, or a shared `.app`), you take on their license obligations, summarized below. The app handles them: Settings › Licenses shows every license in full (bundled from `App/Resources/Licenses/`), and the first time someone picks "LaMa + diffusion" it asks them to agree to the Stable Diffusion use restrictions.

| Model | Used for | Bundled as | Size | License |
| --- | --- | --- | --- | --- |
| LaMa (big-lama) | AI object removal | `Models/LaMa.mlpackage` | ~100 MB | Apache-2.0 |
| Stable Diffusion 1.5 inpainting | "LaMa + diffusion" removal | `Models/SDInpaint*` | ~780 MB | CreativeML Open RAIL-M |

## LaMa (big-lama)

Converted to Core ML by `scripts/convert_lama.py`. Without it, the app hides AI removal.

- Paper: Suvorov et al., "Resolution-robust Large Mask Inpainting with Fourier Convolutions", WACV 2022.
- Source: https://github.com/advimman/lama (Samsung AI Center Moscow)
- Weights: `big-lama.pt`, the TorchScript export distributed by IOPaint (https://github.com/Sanster/models/releases/tag/add_big_lama), MD5 `e3aa4aaa15225a33ec84f9f4bc47e500`
- License: Apache License 2.0, https://github.com/advimman/lama/blob/main/LICENSE

Apache-2.0 obligations when redistributing the converted model: include a copy of the license, keep the upstream copyright notices, and state that the weights were modified (converted to Core ML).

## Stable Diffusion 1.5 inpainting

Converted to Core ML by `scripts/convert_sd_inpaint.py`: the UNet (6-bit palettized), the VAE encoder and decoder, and prompt embeddings precomputed from the CLIP text encoder (the text encoder itself isn't shipped). Without them, the app hides the "LaMa + diffusion" engine. `SKIP_DIFFUSION=1 scripts/fetch-models.sh` skips them.

- Model: `stable-diffusion-v1-5/stable-diffusion-inpainting` on Hugging Face, https://huggingface.co/stable-diffusion-v1-5/stable-diffusion-inpainting (originally released by Runway and Stability AI)
- License: CreativeML Open RAIL-M, https://huggingface.co/spaces/CompVis/stable-diffusion-license

Open RAIL-M permits use, modification and redistribution, including commercially, but with conditions that carry through to everyone downstream. When you distribute the model or a derivative (the converted Core ML files are one):

1. Include a full copy of the license.
2. Include the use-based restrictions (paragraph 5 and Attachment A) as an enforceable provision in the terms your users agree to, and give your users notice that they're bound by them.
3. State that you modified the files.

The use restrictions forbid using the model, among other things, to break the law, to harm minors, to generate false information or personal information meant to harm others, to defame or harass, or for medical advice or law-enforcement decisions. The license text is the authority; this is only a summary.

In LightEditor the model runs only in the removal tool, with a fixed, built-in prompt ("empty background, seamless natural continuation of the surroundings, photo"), precomputed at build time, inside a mask the user draws. Users can't type prompts or generate images from scratch.

## Build-time tools (not shipped)

These run on the developer's Mac and aren't part of the app:

- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (MIT) generates the Xcode project.
- PyTorch, coremltools, NumPy, diffusers, transformers, accelerate, safetensors, huggingface_hub and scikit-learn convert the models. `scripts/fetch-models.sh` installs pinned versions into a temporary environment with [uv](https://docs.astral.sh/uv/) and deletes it afterwards.

## Trademarks

Fujifilm film simulation names (Provia, Velvia, Astia, Classic Chrome and others) are trademarks of FUJIFILM Corporation. LightEditor's presets are its own approximations, tuned by eye; the names only say which look a preset aims for. Lightroom is a trademark of Adobe. LightEditor isn't affiliated with or endorsed by Fujifilm, Adobe or Apple.
