"""Converts LaMa (big-lama, Apache-2.0) from TorchScript to a Core ML package.

Usage: python convert_lama.py <big-lama.pt> <output.mlpackage>

The package has two functions sharing one set of weights: "full" works at
1024×1024 and "fast" at 512×512. Each takes an RGB image and a mask of the same
size (white = remove) and returns the inpainted RGB image. The app crops around
each removal from the full-resolution original, runs the model, and blends the
result back.
"""
import os
import tempfile
import sys

import coremltools as ct
import numpy as np
import torch

SIZES = {"full": 1024, "fast": 512}


class Wrapper(torch.nn.Module):
    """Takes 0–255 inputs, as Core ML image inputs provide, and returns 0–255."""

    def __init__(self, lama):
        super().__init__()
        self.lama = lama

    def forward(self, image, mask):
        image = image / 255.0
        mask = (mask / 255.0 > 0.5).float()
        result = self.lama(image, mask)
        return torch.clamp(result * 255.0, 0.0, 255.0)


def convert(lama, size):
    wrapper = Wrapper(lama).eval()
    example = (torch.rand(1, 3, size, size) * 255, (torch.rand(1, 1, size, size) > 0.5).float() * 255)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example, check_trace=False)
    return ct.convert(
        traced,
        inputs=[
            ct.ImageType(name="image", shape=(1, 3, size, size), color_layout=ct.colorlayout.RGB),
            ct.ImageType(name="mask", shape=(1, 1, size, size), color_layout=ct.colorlayout.GRAYSCALE),
        ],
        outputs=[ct.ImageType(name="output", color_layout=ct.colorlayout.RGB)],
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16,
    )


def main():
    source, destination = sys.argv[1], sys.argv[2]
    lama = torch.jit.load(source, map_location="cpu").eval()
    work = tempfile.mkdtemp()
    descriptor = ct.utils.MultiFunctionDescriptor()
    for name, size in SIZES.items():
        path = os.path.join(work, f"{name}.mlpackage")
        convert(lama, size).save(path)
        descriptor.add_function(path, src_function_name="main", target_function_name=name)
        print("converted", name, size)
    descriptor.default_function_name = "full"
    combined = os.path.join(work, "LaMa.mlpackage")
    ct.utils.save_multifunction(descriptor, combined)
    model = ct.models.MLModel(combined, skip_model_load=True)
    model.short_description = "LaMa (big-lama) inpainting: full = 1024×1024, fast = 512×512. Apache-2.0, Samsung AI Center Moscow."
    model.author = "Suvorov et al., Resolution-robust Large Mask Inpainting with Fourier Convolutions (WACV 2022)"
    model.license = "Apache-2.0"
    model.save(destination)
    print("saved", destination)


if __name__ == "__main__":
    main()
