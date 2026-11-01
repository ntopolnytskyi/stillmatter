# Meeting AI frontier capability evaluation

Initial investigation on 2026-11-01 for tickets 02 and 03. **Ticket 02 is resolved as a capability investigation; ticket 03 was incomplete at this stage.** The subsequent user-authorized downloaded-model experiments and current ticket 03 disposition are in the [local capability contract](local-capability-contract.md). Statements below about unexecuted model lanes describe this initial investigation; the follow-up preserves failed evidence and adds actual inference results. This note distinguishes observed behavior, installed-source contracts, and unexecuted evaluation. No product requirement or deployment target was changed. The accompanying probes are disposable, non-shipped validation code in [`experiments/meeting-ai-capabilities`](../../experiments/meeting-ai-capabilities/).

## Environment and privacy

Native helper observed macOS 15.8.1 (24H32), x86_64, 32 GiB physical memory, 12 logical processors. Xcode is 26.3 (17C529). Outside the workspace sandbox it observed one online display and granted Screen Capture, Accessibility and microphone access for the invoking helper identity. The same probe inside the sandbox returned zero displays and denied permissions. **Sandbox denial is not evidence that the installed app lacks permission.** No permission request, microphone read, screen capture, window-title enumeration, real Meeting read or credential read was performed. Permission state is identity-specific and does not prove packaged-app behavior.

Installed application metadata: Teams 26225.1706.5101.3140; Zoom 5.4.0 (58631.1025); Chrome 156.0.8078.79. Installed Pi is `@earendil-works/pi-coding-agent` 1.2.0. Installed command-line alternatives: whisper.cpp 1.9.5; llama.cpp server 0.8.0 build 11960 commit 8642541b2 (AppleClang 17.0.0.17000604 for Darwin x86_64). Their presence alone does not prove usable weights or quality.

The app installer marker and model/runtime files were inspected at the path derived from `AppDelegate.applicationSupportURL` and `TranscriptionComponentPaths`, following the user's instruction to inspect the engines already used by Stillmatter. No other personal support data was read. Generated audio and Pi configuration stay in disposable output roots; original installed weights are read-only. No model installation or remote inference was used.

## Ticket 02: capture scope

| Source | Current Stillmatter backend | Documented narrower API | Capability conclusion |
| --- | --- | --- | --- |
| Teams native | All applications except Stillmatter | ScreenCaptureKit application inclusion can select the native app | Current implementation does not meet selected-source scope. Teams-only implementation and sample measurements still required. App selection does not by itself prove that non-call Teams sounds are excluded. |
| Zoom native | All applications except Stillmatter | Same application inclusion API | Current implementation does not meet selected-source scope. Zoom-only implementation and sample measurements still required. |
| Google Meet in browser | All applications except Stillmatter | ScreenCaptureKit window selection still captures application-level audio | **Meeting/tab-only isolation is unsupported by the current ScreenCaptureKit backend.** Selecting a Chrome window cannot be represented as Meet-only audio. A separate verified tab-scoped integration is required before ticket 02 can unblock its dependents. |

Source observation: [`MacSystemAudioTrackRecorder.startWritingRecovery`](../../Sources/Stillmatter/Platform/MacSystemAudioTrackRecorder.swift) constructs `SCContentFilter(display:excludingApplications:exceptingWindows:)` with only the current application excluded. [`MacTeamsDetectionMonitor`](../../Sources/Stillmatter/Platform/MacTeamsDetectionMonitor.swift) polls a Teams Accessibility hang-up identifier every three seconds; this is detection evidence, not an audio-scope guarantee or measured stop/reconnect latency.

Apple's [ScreenCaptureKit WWDC22 technical contract](https://developer.apple.com/videos/play/wwdc2022/10156/) says audio can only be filtered at the application level. The [SCContentFilter API](https://developer.apple.com/documentation/screencapturekit/sccontentfilter) provides application inclusion and exclusion filters; it does not provide a browser-tab audio filter. This rules out assuming tab isolation from a window picker. This is a documented API constraint, **not a claim that a Teams/Zoom/Meet hardware capture experiment was run**. Supported audio configuration begins with macOS 13 in the current implementation; this research does not authorize raising its macOS 13 shipping target.

[Chrome tabCapture](https://developer.chrome.com/docs/extensions/reference/api/tabCapture) supplies tab media through an extension, requires invocation by the user, and has permission/stream-use constraints. It is a possible research direction for manual Meet capture, not an implemented native API, approved new distribution dependency, or evidence that an extension satisfies the full capture lifecycle. No extension or virtual device was installed. Browser-wide and system-wide audio remain prohibited fallback paths.

### Reproducible source-scope lane

1. Use a disposable macOS test account and isolated signed app identity. Record OS, browser/call versions, audio devices, routing, permissions and timestamps. Explicitly authorize synthetic calls; do not use real call content or other audible personal applications.
2. Generate the distinct PCM fixtures with `python3 experiments/meeting-ai-capabilities/scope_probe.py --generate .build/capabilities/tones`. Authorized target is 440 Hz, unrelated source is 997 Hz; both are mono PCM16 at 48 kHz, four seconds. Repetition is allowed for longer trials. Play target through the remote synthetic participant's selected call and unrelated tone through another app; for Meet also play it in another tab **and** another window of the same browser.
3. Capture with the proposed selected-source adapter, retain original per-track evidence and record source IDs/API selection. Convert only a disposable derivative to PCM16 WAV if necessary. Run `python3 experiments/meeting-ai-capabilities/scope_probe.py --analyze retained-test-track.wav`. A pass requires detectable target and unrelated/target amplitude at most -40 dB. This threshold distinguishes generated fixtures; it is not a universal acoustic quality criterion. Every channel is checked independently so phase-opposed stereo leakage cannot cancel.
4. Repeat denied permission, missing source, source reappearance, hidden call controls, device disconnect and reconnect. Record actual signal transitions and first/last retained sample timestamps. Unknown/hidden UI must not be reported as a real call end. Verify microphone continues with a degraded warning when source fails; never enlarge scope. A successful pure-tone measurement alone is insufficient for call-state behavior.
5. Repeat during the selected local model's inference on long and short synthetic recordings. Measure sample continuity, expected versus retained frames/gaps, start/stop latency, memory, CPU, and immediate next capture through prior finalization. Record raw logs and per-run settings rather than using wall-clock duration as captured duration.

Executed: tone generation/self-analysis and 12 Python behavioral probe tests (scope detection, silence/empty rejection, stereo leakage, CLI exit status, RPC failure/lifecycle, Unicode framing and WER arithmetic). A tone analyzed directly is a tool self-test, **not** application or call isolation evidence. Actual Teams/Zoom/Meet capture, denied-permission capture, reconnect, hidden-controls and concurrent-inference sample tests were not executed. Ticket 02 therefore does not unblock 12/13 or their successors.

## Ticket 03: local inference and Pi RPC

### Existing app runtime, not a replacement model

[`TranscriptionComponentInstaller`](../../Sources/StillmatterCore/TranscriptionComponentInstaller.swift) selects recommended `dropbox-dash/faster-whisper-large-v3-turbo` at revision `0a363e9161cbc7ed1431c9597a8ceaf0c4f78fcf`; full-quality alternative is `Systran/faster-whisper-large-v3` at `edaa852ec7e145841d8ffdb056a99866b5f0a478`. The recommended component is installed and its marker matches schema 1 / `faster-whisper-1.2.1`. Model binary size is 1,617,884,929 bytes. The primary [pinned model repository](https://huggingface.co/dropbox-dash/faster-whisper-large-v3-turbo/tree/0a363e9161cbc7ed1431c9597a8ceaf0c4f78fcf) declares MIT licensing. The install marker identifies a chosen revision through code, but does not cryptographically attest the installed weights; no such attestation is claimed.

Runtime imports measured faster-whisper 1.2.1, CTranslate2 4.8.2, PyAV 18.1.0 and ONNX Runtime 1.23.2. The shipped [`FasterWhisperTranscription`](../../Sources/StillmatterTranscriptionRuntime/FasterWhisperTranscription.swift) uses CPU/int8, VAD and explicit language values. Current `TranscriptLanguage` has English/Ukrainian only; **Auto is not yet exposed by the app**. The research probe evaluates `language=None` against those existing weights, independently of that missing product adapter. [Upstream faster-whisper](https://github.com/SYSTRAN/faster-whisper) owns the ASR/runtime contract. The system's tiny whisper.cpp file is named `for-tests-ggml-tiny.bin` and is only 575,451 bytes; it was not substituted for installed app weights or used to claim ASR quality.

The reproducible probe generates local macOS Samantha/Lesya TTS, converts to 16 kHz mono PCM, concatenates a mixed clip, mixes overlapping speech and creates exact silence. It loads only the existing model directory (`local_files_only=True`), sets Hugging Face offline flags and caches under the disposable output directory, uses CPU/int8 with four threads and VAD, and writes timing/output/hash metrics. This is actual model inference on synthetic content, **not** validation of real human accents, audio quality, identity, long-recording resources or real-call performance. No quality threshold is inferred from a five-clip smoke set.

The initial Auto+VAD smoke run transcribed English with 0% WER, Ukrainian with 18.18% WER under the recorded punctuation-splitting tokenizer (`п’ятницю` became `Татницю`), and the full mixed clip with 60.87% WER: all English speech was omitted while Ukrainian remained. Exact silence produced zero segments. Overlap generated one Ukrainian-labelled segment, without acoustic speaker attribution; no overlap WER is assigned because a single linear reference would conceal simultaneous speakers. The initial settings therefore do **not** establish the required mixed-language preservation. This is a configuration-specific observed failure, not proof that every engine configuration or full-coverage chunk strategy fails.

A bounded comparison disables VAD on the original full mixed clip and separately runs Auto on all known English/Ukrainian fixture chunks while retaining original timing and full duration. Synthetic construction supplies these boundaries; no production segmenter, word alignment or guarantee for arbitrary calls is inferred. The [comparison report](capability-asr-comparison-2026-11-01.json) records:

| Configuration | Included duration | WER | Observed behavior |
| --- | --- | --- | --- |
| Whole mixed clip, Auto, VAD on | 8.8088125 s | 60.87% | All English omitted |
| Same whole clip, Auto, VAD off | 8.8088125 s | 60.87% | All English omitted; 21.39 s inference |
| Every fixture chunk, independent Auto, VAD on | 8.8088125 s | 8.70% | English and Ukrainian both retained; Ukrainian `п’ятницю` error remains; 40.88 s inference |

This supports investigating bounded full-coverage local Auto chunks rather than rejecting the installed model outright. The constructed boundary is an oracle available for this fixture, so a production silence/window segmentation policy, overlap/deduplication handling, bounded resources and real mixed-language quality still need implementation/evaluation. Comparison output supplements rather than replaces failed-run evidence.

Results are captured in [`capability-asr-smoke-2026-11-01.json`](capability-asr-smoke-2026-11-01.json). The JSON includes reference text, actual segment text/times, fixture SHA-256, language, elapsed time, realtime factor and peak RSS. Concurrent compilation/tests may affect throughput; these are observed measurements, not dedicated benchmark guarantees. WAV hashes pin the [retained exact generated fixtures](../../experiments/meeting-ai-capabilities/fixtures); voice output can differ across OS revisions. The reproducible command uses those retained bytes; omit `--retained-fixtures` for fresh TTS generation.

Reproduce with the Python executable in the app's installed component (quotes required for paths with spaces):

```sh
'<component>/runtime/bin/python3' experiments/meeting-ai-capabilities/asr_probe.py \
  --component '<component>' --output .build/capabilities/asr \
  --retained-fixtures experiments/meeting-ai-capabilities/fixtures
```

Here `<component>` is the path from the installer marker: `<app support>/Transcription/faster-whisper-<variant>/<modelDirectory>`. The script never modifies installed weights. It does not inspect settings, recordings or secrets.

### Pi lifecycle and unavailable local model

The previous [Pi RPC research](pi-rpc-research.md) is confirmed against installed package 1.2.0 documentation. Successful prompt acknowledgement means accepted/queued/handled, not generated. `agent_end` is a low-level boundary; stage completion requires `agent_settled`, a non-error/non-aborted final assistant message and validated artifacts. A `handled` disposition means no generation is implied. Host deadlines, child death, JSONL framing and separate stderr remain required. The disposable probe is not the production RPC adapter.

Executed `python3 experiments/meeting-ai-capabilities/rpc_probe.py` against **actual installed Pi**, with a fresh `PI_CODING_AGENT_DIR`, no user credentials/environment secrets, no tools/MCP/extensions/context/skills/templates/session, offline startup and explicit provider/model. The configured custom provider points only to `http://127.0.0.1:9/v1` with a synthetic placeholder key and deliberately unavailable model endpoint. Observed prompt success acknowledgement, assistant error message, `agent_end`, then `agent_settled`; resulting flags were `accepted=true`, `settled=true`, `providerFailed=true`, `validArtifact=false`. This establishes the isolated **failure** path, not a working local LLM. No hosted provider or Meeting upload was used. `--offline` is not a network sandbox; the explicit loopback endpoint and disabled tools matter.

Synthetic child-process tests additionally demonstrate acknowledgement-only failure, `agent_end` without settlement failure, settlement without artifact rejection, valid final-artifact acceptance, malformed JSONL failure, nonzero exit failure, embedded Unicode U+2028/U+2029 framing, and settled provider error rejection. They prove the probe's lifecycle assertions, not real model capabilities.

Installed primary documentation SHA-256:

| File | SHA-256 |
| --- | --- |
| package.json | `d4231a02b6a2ccb357a8e9e420fab9c217490137ade958d4a45a12e169daad0c` |
| docs/rpc.md | `37a03d180115460a0a275022f4aeabef1e5345458df6a9b6e8a6de18474de720` |
| docs/rpc-commands.md | `4deeee367852f4633ef594bc079f9e9fb14640a4e3ba8a69b7c89b6f54740838` |
| docs/cli.md | `f722b2bc9931db5c22d645ea161fd9a37c30b16e662bba51ce4ca75ea6cbdd51` |
| docs/models.md | `d5bd0d886f0e1541648081ae01da91e1a218cd454713336d5100fc820f6c1527` |
| docs/security.md | `3b1e40a8d28b17c9eb7e496a7ba88fbe04665e3e6ae02873a58b943e325ad504` |

All files reside under the installed `@earendil-works/pi-coding-agent` package. Upstream [Pi source/docs](https://github.com/earendil-works/pi/tree/main/packages/coding-agent/docs) are navigation references; hashes above identify the inspected installed contracts.

### Capability choices and explicit remaining blockers

| Capability | Existing evidence | Required next evidence |
| --- | --- | --- |
| Local English/Ukrainian ASR | Existing app model/runtime loads; actual synthetic inference metrics attached | Approved representative human-speech corpus, mixed-code-switch evaluation, full-recording/silence/gap/error and long-recording resource tests; expose/test Auto in product adapter |
| Acoustic diarization | App labels source track `Me` / `Meeting audio`; these are not acoustic speaker clusters | Select/install/license a dedicated local adapter and evaluate speaker boundaries/overlap/DER against labelled clean and overlap fixtures |
| Person voice matching | No shipped acoustic profile engine found in the app's current runtime | Select local embedding model; evaluate genuine/impostor/unknown/overlap cases with held-out speakers; measure false accepts/rejects and quality gates before choosing thresholds |
| Local Pi analysis | Pi custom-provider contract inspected; unavailable-loopback failure exercised | Explicit usable local LLM weights/provider, settled generation and grounded English outcome/citation tests, resource/latency measurements; no fallback to Codex |
| Local semantic search | Existing `SearchIndex` creates SQLite FTS5 index; keyword results are not semantic evidence | Pin local text embedding model and evaluate labelled retrieval Recall@k/ranking, multilingual queries, archive/purge/delete and private-profile exclusion |

Current [`PiCodexWorker`](../../Sources/StillmatterCore/PiCodexWorker.swift) hardcodes remote `openai-codex` / `gpt-5.5` in print-mode calls. This cannot satisfy required fully local analysis or the required RPC lifecycle. Reusing it silently would change R7. It was not invoked with user context.

Candidates for further evaluation, **not selected engines or supported quality claims**: [pyannote.audio](https://github.com/pyannote/pyannote-audio) supplies local diarization components but selected model licenses/access conditions and CPU/runtime compatibility need verification; [SpeechBrain ECAPA model](https://huggingface.co/speechbrain/spkrec-ecapa-voxceleb) declares Apache-2.0 but its English VoxCeleb metrics cannot be copied as Ukrainian/English enrollment thresholds. [llama.cpp server](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md) documents local chat and embeddings endpoints; installed binary alone does not establish a suitable chat or embedding model. Acoustic speaker vectors and text embeddings must remain separate and private-profile material must never enter analysis/search/export.

### Ticket 02 research disposition

The investigation resolves the capability question for the **current implementation**: it captures all applications except Stillmatter, so it does not isolate Teams, Zoom, or Meet. ScreenCaptureKit documents app-level filtering, which could support a future Teams/Zoom-specific adapter if wired and measured; its audio contract does not support Meet-tab-only isolation. This conclusion is sufficient to close the research ticket with explicit constraints, but it does **not** establish that selected-app capture works in Stillmatter or that real-call behavior meets R2.

The following ticket 02 required lanes remain unexecuted: distinguishable tones from actual Teams/Zoom/Meet call sources plus an unrelated app/tab, call start/end/reconnect and hidden-control behavior, permission-denial behavior in the packaged app, and sample continuity/latency while real inference is active. The synthetic scope checker was verified (`python3 -m unittest discover -s experiments/meeting-ai-capabilities -v`: 12 passed), but it only checks fixture discrimination; it performs no capture. The existing read-only native preflight is also not a capture test. These limits are recorded for dependent implementation: do not ship or claim source isolation until the missing app-level and real-call lanes pass. Never fall back to browser-wide/system audio. Ticket 03 remains incomplete on its separate local-model requirements. No production Swift or UI changed, so these probes do not advance coverage or establish UI acceptance.
