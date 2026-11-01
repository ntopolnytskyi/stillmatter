# Disposable Meeting AI capability probes

These are **non-shipped** probes for tickets 02/03. They never read a Meeting or credentials and do not establish product parity. Findings, source links and unexecuted acceptance criteria are in [the capability evaluation](../../docs/meeting_ai_handoff/capability-evaluation-2026-11-01.md).

Run the behavioral probe self-tests:

```sh
python3 -m unittest discover -s experiments/meeting-ai-capabilities -v
```

Run the read-only native permission/display preflight (no permission request or capture):

```sh
mkdir -p .build/capabilities
xcrun swiftc experiments/meeting-ai-capabilities/capture_preflight.swift -o .build/capabilities/capture-preflight
.build/capabilities/capture-preflight
```

Permission and display results inside a sandbox may differ from the app's actual launch identity. Do not diagnose hardware support from sandbox-only denials.

Generate synthetic scope tones and analyze a separately authorized captured PCM16 WAV:

```sh
python3 experiments/meeting-ai-capabilities/scope_probe.py --generate .build/capabilities/tones
python3 experiments/meeting-ai-capabilities/scope_probe.py --analyze retained-synthetic-track.wav
```

A direct generated-tone self-analysis proves the checker works, not that a call source is isolated. A target must be audible and unrelated source leakage must be at most -40 dB for this fixture; this is not a universal speech-quality threshold. See the evaluation note for the call/permission/reconnect/concurrent-inference lane.

Exercise installed Pi RPC with an isolated deliberately unavailable loopback provider:

```sh
python3 experiments/meeting-ai-capabilities/rpc_probe.py
```

It uses the installed Pi binary, a fresh agent configuration and synthetic prompt, no tools, no MCP, no ambient resources and no session. Expected result is acknowledged and settled **provider failure**, with no valid artifact. It neither contacts a hosted provider nor proves successful local model inference. `--offline` alone is not a network sandbox.

For actual ASR, use the Python in the existing installed app component:

```sh
'<component>/runtime/bin/python3' experiments/meeting-ai-capabilities/asr_probe.py \
  --component '<component>' --output .build/capabilities/asr \
  --retained-fixtures experiments/meeting-ai-capabilities/fixtures
'<component>/runtime/bin/python3' experiments/meeting-ai-capabilities/asr_probe.py \
  --component '<component>' --output .build/capabilities/asr --compare
```

The retained fixtures preserve the exact evaluated PCM16 bytes and match hashes in the result JSON. Omit `--retained-fixtures` to generate fresh TTS instead. The component path is derived from Stillmatter's `Transcription/installed.json` marker and installer paths. The probe reads existing model weights only. macOS `say` with installed Samantha/Lesya voices generates disposable fixtures; `ffmpeg` converts them. No weights or voices are downloaded. The first run measures five fixtures; `--compare` measures the same full mixed recording with VAD off and every constructed fixture chunk with independent Auto. Chunk boundaries are known from synthetic construction, not a validated segmentation algorithm. All recording duration remains included; chunk experiments never authorize content boundaries. Reports include outputs, references, waveform hashes, WER, runtime versions, timings and peak RSS. WER splits Unicode word runs at punctuation (including apostrophes) and casefolds; no metric threshold or human-speech/voice-matching guarantee is implied.

## Ticket 03 downloaded-model evaluation

The user authorized evaluation downloads. Model weights stay outside the repository in
`/private/tmp/stillmatter-meeting-ai-03-models`; runtime packages stay in
`/private/tmp/stillmatter-meeting-ai-03-runtime`. Only synthetic text/audio enters these
probes. Nothing reads a real Meeting, enrolls a Person, writes a Voice Profile or
uses a hosted inference provider. These scripts are non-shipped research tools.

Install a disposable Python 3.12 environment with
`python3.12 -m venv /private/tmp/stillmatter-meeting-ai-03-runtime`, then run its
`bin/pip install -r experiments/meeting-ai-capabilities/evaluation-requirements.txt`.
The requirements record the actual resolved environment on macOS x86_64; other
platforms may require different wheels and must report their own environment.

[evaluation-models.json](evaluation-models.json) contains public URLs, exact sizes,
and SHA-256 hashes of evaluated artifacts. Download each URL to its listed filename
under a disposable model root, verify SHA-256, and extract `segmentation.tar.bz2`
there. Do not treat a successful download as a quality result. Candidate source,
license and installation constraints are in
[local-model-candidates.md](../../docs/meeting_ai_handoff/local-model-candidates.md).
No gated model agreement or credential was needed for these public conversions.
Installed `llama-server`, Pi, macOS `say` voices and `ffmpeg` versions are recorded
in the corresponding reports; packages alone do not install these executables.

Local text retrieval (CPU, all supplied passages/queries included, no hub call):

```sh
/private/tmp/stillmatter-meeting-ai-03-runtime/bin/python \
  experiments/meeting-ai-capabilities/retrieval_probe.py \
  --model /private/tmp/stillmatter-meeting-ai-03-models/e5-small.onnx \
  --tokenizer /private/tmp/stillmatter-meeting-ai-03-models/e5-tokenizer.json \
  --output /private/tmp/stillmatter-meeting-ai-03-retrieval.json
```

The model hash is enforced before loading. Inputs over 512 tokens fail rather than
silently truncate. The fixture contains seven answerable English/Ukrainian questions,
six passages and one unanswerable query. Recall excludes the unanswerable query;
its ranking is still reported, with no claim that a relevance threshold can reject
it. Output includes rankings and aggregate metrics, never embedding vectors.
Archive exclusion, external edits, purge/delete refresh and private-profile storage
boundaries require later product tests; this probe is not a search implementation.

Local acoustic diarization and synthetic voice comparisons:

```sh
/private/tmp/stillmatter-meeting-ai-03-runtime/bin/python \
  experiments/meeting-ai-capabilities/speaker_probe.py \
  --fixtures experiments/meeting-ai-capabilities/fixtures \
  --segmentation /private/tmp/stillmatter-meeting-ai-03-models/sherpa-onnx-pyannote-segmentation-3-0/model.onnx \
  --embedding /private/tmp/stillmatter-meeting-ai-03-models/nemo_en_titanet_small.onnx \
  --output /private/tmp/stillmatter-meeting-ai-03-speaker-results
```

Anonymous cluster timing is compared to synthetic source-energy labels, with no
collar and overlap included. This diagnostic is not human-annotated DER. Both
unknown-count and oracle-count configurations are reported. TTS same/different
voice cosine comparisons do not establish human recognition, false acceptance,
rejection rates or a universal enrollment threshold. Runtime readiness on silence
and overlap is explicitly reported; it must not be mistaken for clean enrollment.
No private profile or vector is persisted by this probe.

Speaker comparisons use the exact retained held-out WAVs by default and verify
hashes before loading them. Missing/corrupt fixtures fail without downloading or
regenerating audio. Add `--generate-held-out` to explicitly create fresh Samantha,
Lesya and Daniel utterances using installed macOS voices and `ffmpeg`; record the
new hashes because voice synthesis can vary by OS version. No voice download is
performed. The retained source texts/voice names are recorded in the speaker JSON.
