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
