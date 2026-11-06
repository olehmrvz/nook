# Third-party notices

Nook is MIT-licensed (see [LICENSE](LICENSE)). It bundles no third-party code. Dictation uses the following:

- **Speech models** (downloaded on request from Hugging Face, not shipped with Nook), licensed
  [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/):
  - [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) by NVIDIA;
  - [moondream/parakeet-ultra](https://huggingface.co/moondream/parakeet-ultra) and the Redux re-training by moondream;
  - the Core ML conversions [FluidInference/parakeet-ultra-coreml](https://huggingface.co/FluidInference/parakeet-ultra-coreml)
    and [FluidInference/parakeet-redux-coreml](https://huggingface.co/FluidInference/parakeet-redux-coreml) by FluidInference.
- **Decoding approach:** the greedy TDT decoding in `Sources/Parakeet.swift` follows the model contract and
  algorithm of [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0, Copyright FluidInference).
  The code is written for Nook; no FluidAudio source file is included.
