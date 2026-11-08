# Third-party notices

Nook is MIT-licensed (see [LICENSE](LICENSE)). It bundles no third-party code. Dictation uses the following:

- **Speech models** (downloaded on request from Hugging Face, not shipped with Nook), licensed
  [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/):
  - [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) by NVIDIA;
  - [moondream/parakeet-ultra](https://huggingface.co/moondream/parakeet-ultra) and the Redux re-training by moondream;
  - the Core ML conversions [FluidInference/parakeet-ultra-coreml](https://huggingface.co/FluidInference/parakeet-ultra-coreml)
    and [FluidInference/parakeet-redux-coreml](https://huggingface.co/FluidInference/parakeet-redux-coreml) by FluidInference.
- **Streaming speech model** (downloaded on request from Hugging Face, not shipped with Nook), licensed
  [OpenMDW-1.1](https://openmdw.ai/license/1-1/):
  [nvidia/nemotron-3.5-asr-streaming-0.6b](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b) by NVIDIA,
  in the Core ML conversion
  [FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML](https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML)
  by FluidInference (folder `multilingual/1120ms`).
- **Decoding approach:** the greedy TDT decoding in `Sources/Parakeet.swift` and the streaming pipeline in
  `Sources/Nemotron.swift` (mel features, encoder caches, greedy RNN-T) follow the model contracts and algorithms of
  [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0, Copyright FluidInference); for Nemotron,
  v0.18.3: `StreamingNemotronMultilingualAsrManager` and `NemotronMelExtractor`.
  The code is written for Nook; no FluidAudio source file is included.
