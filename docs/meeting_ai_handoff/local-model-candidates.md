# Ticket 03: local evaluation model candidates

Primary-source investigation on 2026-11-01. These are reproducible evaluation candidates, not approved shipping defaults or accuracy claims. Executed measurements belong in the [capability evaluation](capability-evaluation-2026-11-01.md). This note performs no inference, reads no Meeting, and changes no product requirement.

## Analysis through Pi RPC

Official Qwen GGUF distributions provide a practical small-model baseline. The [0.5B model card](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF) declares Apache-2.0 and llama.cpp support. Its 32,768-token context limit does not justify truncating a full Meeting. Multilingual marketing claims do not establish Ukrainian grounding, citation accuracy, or acceptable ownership inference. Evaluate English outputs from English/Ukrainian evidence, empty input, quoted prompt injection, unresolved owners, unsupported facts, and invalid citations. Qwen does not supply acoustic diarization.

| Artifact | Immutable download | SHA-256 advertised by publisher |
| --- | --- | --- |
| Qwen2.5-0.5B-Instruct Q4_K_M, approximately 491 MB | [GGUF](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/6dd44a1fb35d11b5d1b28902876ce3cc9e882d0e/qwen2.5-0.5b-instruct-q4_k_m.gguf) | `74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db` |
| Qwen2.5-1.5B-Instruct Q4_K_M, approximately 1.12 GB | [GGUF](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/dd26da440ef0330c47919d1ecae0966d24022222/qwen2.5-1.5b-instruct-q4_k_m.gguf) | `6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e` |

Hashes and revisions come from the publisher's [0.5B artifact](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/blob/main/qwen2.5-0.5b-instruct-q4_k_m.gguf) and [1.5B artifact](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/blob/main/qwen2.5-1.5b-instruct-q4_k_m.gguf). The [1.5B card](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF) also declares Apache-2.0. Verify downloaded bytes independently; these are advertised identities, not evidence of a completed download.

Use the already installed llama.cpp server with an explicit local model path, CPU settings, and `127.0.0.1` binding. Route Pi's isolated custom provider to that endpoint, with tools and ambient resources disabled as described in [Pi RPC research](pi-rpc-research.md). Model download is a separate network operation; do not send fixture or Meeting context to a hosted model. Runtime compatibility and latency require an executed test on this Intel Mac.

## Text embeddings

[intfloat/multilingual-e5-small](https://huggingface.co/intfloat/multilingual-e5-small/raw/main/README.md) declares MIT, includes Ukrainian, and produces 384-dimensional vectors. Retrieval requires `query: ` and `passage: ` prefixes even for Ukrainian; use attention-mask-aware mean pooling and L2 normalization. Inputs truncate after 512 tokens, so a later product adapter must chunk all permitted text rather than silently drop the tail. The card warns that lower-resource language performance may degrade. Evaluate ranking and Recall@k on labelled cross-language questions; absolute cosine values are not a universal relevance threshold.

The author's [ONNX directory](https://huggingface.co/intfloat/multilingual-e5-small/tree/main/onnx) contains FP32 `model.onnx` (~470 MB), FP16 `model_O4.onnx`, and `model_qint8_avx512_vnni.onnx`. Prefer FP32 as the CPU baseline: the AVX512-specific filename is not evidence of compatibility with the host CPU, and FP16 CPU support cannot be assumed. Tokenization is available as `onnx/tokenizer.json` (~17.1 MB), with accompanying configuration files. ONNX Runtime plus Hugging Face tokenizers can avoid installing PyTorch; verify actual session inputs/output before inference.

Pinned FP32 [download](https://huggingface.co/intfloat/multilingual-e5-small/resolve/ffdcc22a9a5c973ef0470385cef91e1ecb461d9f/onnx/model.onnx), publisher [artifact hash](https://huggingface.co/intfloat/multilingual-e5-small/blob/main/onnx/model.onnx): `ca456c06b3a9505ddfd9131408916dd79290368331e7d76bb621f1cba6bc8665`. Pin tokenizer/configuration identities alongside the model in the executed manifest. No text-embedding model may receive private Voice Profile vectors or enrollment audio.

## Diarization and Voice Profiles

The [sherpa-onnx diarization documentation](https://k2-fsa.github.io/sherpa/onnx/speaker-diarization/models.html) provides public converted models:

- [pyannote segmentation 3.0 ONNX archive](https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2): `model.onnx` (~5.7 MB), `model.int8.onnx` (~1.5 MB), LICENSE and README.
- [NVIDIA NeMo TitaNet small ONNX](https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/nemo_en_titanet_small.onnx): speaker embedding model used by the documented pipeline. Preserve this exact spelling of `speaker-recongition-models` in download URLs.

The runtime expects 16 kHz mono PCM. Speaker count can be supplied or estimated with clustering; a fixture-specific count or clustering threshold is not an unknown-speaker accuracy result. The docs' speed and diarization examples are upstream results, not measurements on this machine. [CPU Python installation](https://k2-fsa.github.io/sherpa/onnx/python/install.html) documents macOS x64 and arm64 precompiled wheels: install `sherpa-onnx` and `sherpa-onnx-bin` into a disposable environment and record resolved versions. The [runtime repository](https://github.com/k2-fsa/sherpa-onnx) declares Apache-2.0; model terms remain separate.

[Upstream pyannote segmentation](https://huggingface.co/pyannote/segmentation-3.0) is MIT, but direct upstream downloads require accepting contact-sharing conditions and an access token. The public sherpa conversion avoids credential-dependent download; record conversion provenance and inspect its bundled license. Upstream powerset output supports local overlapping speaker states, which does not establish overlap handling by the complete sherpa clustering pipeline.

The [NVIDIA TitaNet-S card](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/nemo/models/titanet_small) links its license to the [NeMo Apache-2.0 license](https://raw.githubusercontent.com/NVIDIA/NeMo/main/LICENSE), describes 192-dimensional embeddings and 16 kHz mono input, and warns about domain mismatch. Conversion provenance is documented in [sherpa's export scripts](https://github.com/k2-fsa/sherpa-onnx/tree/master/scripts/nemo/speaker-verification). Do not substitute the different TitaNet-large Hugging Face card's license. English/telephone/celebrity training results are not calibrated Ukrainian enrollment thresholds.

[SpeechBrain ECAPA VoxCeleb](https://huggingface.co/speechbrain/spkrec-ecapa-voxceleb) is an alternative Apache-2.0 speaker embedding model with a PyTorch/SpeechBrain dependency and 16 kHz mono expectations. Its VoxCeleb score does not establish performance for this product. The ONNX TitaNet candidate is a smaller installation experiment for this machine; that is an operational choice, not an accuracy ranking.

For both candidates, use held-out synthetic utterances for basic same/different-voice mechanics, silence and overlap rejection. Synthetic TTS voices cannot validate Person recognition precision, accents, cross-device stability, or thresholds; use a separate consented labelled human-speaker lane before selecting a shipping threshold. Naming a Person never authorizes enrollment. Keep independent Voice Profiles local and outside transcripts, AI context, search, diagnostics, exports, and the CLI.
