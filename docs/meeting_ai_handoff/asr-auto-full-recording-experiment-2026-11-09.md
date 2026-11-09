# Auto ASR full-recording segmentation experiment

This evaluates independent local Auto recognition on speech chunks found by the installed faster-whisper Silero VAD. It is a synthetic fixture experiment, not a production ASR change or evidence about human meeting quality.

## Setup

- Source: retained [`mixed.wav`](../../experiments/meeting-ai-capabilities/fixtures/mixed.wav), 16 kHz mono PCM16, 8.8088125 seconds, SHA-256 `1f7e3999a57995f2ffdd53fced7461ca56319f7269bb413d871dce81b4d69b14`.
- Reference: English sentence followed by Ukrainian sentence. The synthetic construction boundary is 3.680875 seconds; the segmenter was not given that boundary.
- Model: installed `faster-whisper-large-v3-turbo`, faster-whisper 1.2.1, CTranslate2 4.8.2, PyAV 18.1.0; local CPU/int8, four threads. Inference ran offline and used no downloaded or remote model.
- WER uses the same Unicode-word tokenizer as the earlier ASR probes. These small TTS fixtures do not define a product pass threshold.

## Results

| Strategy | Full source accounted for | WER | Result |
| --- | --- | ---: | --- |
| Existing whole-recording Auto + VAD | 8.8088125 s | 60.87% | Reported earlier: detected Ukrainian and omitted all English. |
| Independent Auto in overlapping 3 s windows, 0.75 s overlap | 8.8088125 s | 21.74% | Recovered both scripts, but generated a false Ukrainian phrase over the English part and repeated text in overlapping windows. |
| Independent Auto in overlapping 1.5 s windows, 0.5 s overlap | 8.8088125 s | 60.87% | Produced several short-window hallucinations, including “Дякую за перегляд!”. |
| Independent Auto per Silero VAD chunk, 2 s maximum | 8.8088125 s | 17.39% | Six chunks covered all 140,941 samples with no gaps. The chunk boundary near 3.6 s happened to align within 81 ms of the synthetic language switch. It still misspelled `п’ятницю`, hallucinated `кого?`, and labelled the final Ukrainian chunk Russian (`ru`, unsupported by the app). |
| Independent Auto per VAD chunk, 2.5 s maximum, merge chunks under 0.5 s | 8.8088125 s | 13.04% | Four chunks covered all samples. It recovered both languages, but the English-labelled chunk extended across the true language switch and omitted `Наша`; `п’ятницю` remained misspelled. |

The 2 s VAD run took 120.42 seconds for 8.81 seconds of audio (13.67× real-time) and peaked at about 3.28 GB RSS. The 2.5 s run with short-chunk merging took 78.54 seconds (8.91× real-time) and peaked at about 3.31 GB RSS. These measurements were on the shared x86_64 test machine and are observations, not guarantees.

The 2.5 s run without short-chunk merging made a 0.208 s speech chunk and transcribed it as unrelated English (“I’ll be right back.”); merging it into the next interval removed that hallucination but did not restore the omitted Ukrainian word. The exact 5-second silence fixture produced zero VAD chunks and an empty transcript, while the timeline recorded all 80,000 samples as non-speech. This only checks exact synthetic silence.

### Second fixture with three language switches

To check whether the first result depended on one English-to-Ukrainian switch, a second retained fixture concatenates four short Samantha/Lesya TTS phrases, alternating English and Ukrainian three times without inserted silence. It is 12.1430625 seconds and has SHA-256 `9c68ba23d266cb70b80eae6f6f789feeee99477eae93b229ee291e89765c7d50`.

On this fixture, whole-recording Auto detected only Ukrainian (`uk`) but transcribed phrases from both languages; its WER was 12.90%. The same 2.5-second VAD strategy with sub-0.5-second merging also scored 12.90%, using six chunks and 0.00 seconds of VAD gaps. Its chunk boundaries dropped `Перевіримо` and `We`, while whole-recording Auto retained those phrases. Both paths made other word errors, and the whole-run language label does not describe every phrase. Segmentation therefore did not improve this clip. Together, the two fixtures show inconsistent behavior: whole-clip Auto omitted English in the first but recovered both languages in the second; VAD segmentation improved the first and failed to improve the second.

Full machine-readable per-chunk timings, language probabilities, words, and source hashes are preserved in the [2 s report](capability-asr-autospeech-vad-2s-2026-11-09.json), [2.5 s merged report](capability-asr-autospeech-vad-25s-merge05-2026-11-09.json), and [three-switch report](capability-asr-autospeech-interleaved-vad-25s-2026-11-09.json). The [3 s overlapping-window report](capability-asr-autowindow-3s-2026-11-09.json) and [1.5 s report](capability-asr-autowindow-15s-2026-11-09.json) preserve the rejected fixed-window hypotheses.

### Auto sample comparison followed by one full-track decode

Implemented the candidate policy for the installed faster-whisper engine: decode the first 120 seconds and the 120 seconds beginning at 600 seconds in English and Ukrainian, compare speech-duration-weighted average log probability, then decode the full track once using the higher-scoring language. If both candidates have no usable speech or their scores tie, keep recognizer Auto. The sample pass uses one model process per audio track and records scores in Transcript diagnostics. Unsupported engines fail before audio inference with setup guidance.

On the 12.14-second three-switch TTS fixture, only the first window contained audio. The forced-English score was -0.837; forced-Ukrainian was -0.131, so Auto selected Ukrainian. The full forced-Ukrainian decode still recovered both English and Ukrainian phrases, with 12.90% WER (same as the earlier whole-clip Auto run). It took 54.14 seconds including process/model startup and peaked at 3.59 GB RSS. This is one synthetic observation only; it does not validate recordings long enough to contain the 10-minute sample, real meetings, arbitrary speaker/language balance, or the confidence heuristic as a general quality predictor. Raw result: [sample-selection report](capability-asr-language-selection-interleaved-2026-11-09.json). Reproduce with `asr_language_selection_probe.py` and the same component/fixture/reference.

At the user's request, a longer fixture was generated by alternating the retained Samantha English and Lesya Ukrainian utterances twenty times, with 98 ms between utterances, then measuring an exact 180 seconds. Its SHA-256 is `a2f9a7c0160c1e0768146ce8b5f9efb3ee0072495715a5584852eaa51f617f75`. The first 120-second sample scored English -0.239 and Ukrainian -0.121, so Auto selected Ukrainian. The 600-second sample was correctly empty. The full three-minute decode scored **75.43% WER** against the repeated reference, took **270.07 seconds**, and peaked at **3.88 GB RSS**. The transcript omitted many repeated phrases. Because the fixture repeats the same two short sentences unnaturally, this WER is a stress result for repetition handling, not a representative estimate for ordinary meetings. It still shows that the sample choice alone cannot establish full-recording quality. Raw output: [three-minute result](capability-asr-language-selection-three-minute-2026-11-09.json).

Whole-clip Auto on the exact same 180-second WAV detected Ukrainian and scored **63.70% WER** (124.94 seconds, 3.64 GB RSS). The sampling policy therefore did not improve this fixture; forcing the selected Ukrainian language made the repetitive clip's WER 11.74 percentage points worse. Both results omit or miss many repeated words, so this remains a poor fixture for ordinary meeting quality, but it is direct evidence that the current language-score heuristic can choose a worse full-transcript result. Baseline transcript and raw metrics: [Auto baseline](capability-asr-language-selection-three-minute-auto-baseline-2026-11-09.json).

### Varied three-minute conversation

At the user's request, replaced phrase repetition with a newly synthesized two-person project-review conversation: 40 unique, responsive turns alternating between the local Samantha English and Lesya Ukrainian voices. It contains 115.45 seconds of speech and realistic turn pauses distributed across exactly 180 seconds. The exact transcript is retained for scoring. Its waveform SHA-256 is `678edb63d48f6868dc2d823797d98f1f35c5ed67903c91e20f79a2bda85099b0`.

With the installed large-v3-turbo model on CPU/int8, sample selection scored English -0.278 and Ukrainian -0.218 on the first 120 seconds, selected Ukrainian, and scored **53.68% WER**. Whole-track Auto on the exact same bytes also detected Ukrainian and produced the same **53.68% WER**. Sampling took **290.26 seconds** and peaked at about **3.70 GB RSS**; whole-track Auto took **100.89 seconds** and peaked at about **3.44 GB RSS**. The selector therefore added about 189 seconds here without improving the transcript. Both paths omitted most English turns. Reports: [sample selection](capability-asr-language-selection-three-minute-dialogue-2026-11-09.json), [same-audio Auto baseline](capability-asr-language-selection-three-minute-dialogue-auto-2026-11-09.json).

This is still synthesized speech with one voice assigned to each language, not recorded human conversation. The test does not establish accent, overlap, microphone, room-noise, or actual code-switching quality. Ticket 19 remains open; these results do not establish a generally reliable mixed-language Auto policy.

### Per-segment language detection candidate

The user asked to improve Auto selection. faster-whisper 1.2.1 exposes `multilingual=True`, which detects language for each decoder segment, plus a configurable `chunk_length`. This avoids choosing one language for a full mixed recording. Tested the same 180-second dialogue and exact reference with five- and ten-second chunks.

| Mode | WER | Decode time | Peak RSS | Observation |
| --- | ---: | ---: | ---: | --- |
| Whole-track Auto, one initial language | 53.68% | 100.89 s | 3.44 GB | Detected Ukrainian, omitted all 20 English turns. |
| Per-segment Auto, 10 s chunks | 50.65% | 210.40 s | 3.44 GB | Small WER gain, about twice the runtime. |
| Per-segment Auto, 5 s chunks | **26.19%** | 406.91 s | 3.41 GB | Recovered English turns, but several Ukrainian phrases were rendered as Russian. |

The five-second setting is the strongest candidate so far on this dialogue. It is still much slower than normal Auto, and language identification is imperfect. The production Auto path now uses this setting for faster-whisper and marks segment language as Auto rather than mislabeling every segment with the initial language. Explicit English and Ukrainian choices still use a fixed language. The pinned Whisper CLI has no per-segment mode and remains unsupported for Auto in this pipeline.

Raw reports: [5-second per-segment Auto](capability-asr-auto-multilingual-dialogue-5s-2026-11-09.json), [10-second per-segment Auto](capability-asr-auto-multilingual-dialogue-10s-2026-11-09.json).

This is a synthetic two-voice test, not human-recorded conversation. Accent, room noise, overlapping speech, and real within-speaker code-switching remain untested. Keep the UI disclosure and Ticket 19 open until manual human-audio evaluation verifies useful transcript quality and acceptable runtime.

Validation for the implementation: the full package coverage lane passed **438 tests, 4 skipped, 0 failures**. The incremental changed-source gate passed **15/15 executable lines (100%)**: Core 8/8 and transcription runtime 7/7. UI tests were skipped because no UI code changed. The focused clean-worktree Swift run passed 3/3 tests.

## Disposition

VAD chunking with independent Auto detection remains a candidate, not a validated approach. It improved the first fixture, did not improve the second, and missed words at language boundaries. Results change with chunk length; a short window emitted a hallucination; Ukrainian text still has errors; and runtime cost was high. The close 2 s boundary match is specific to one concatenated fixture. These TTS fixtures do not test arbitrary human switch positions, accents, noise, overlap, long recordings, or checkpoint/restart behavior. No production policy or quality threshold is selected.

Reproduce the best observed candidate with the app-installed Python/runtime and existing model:

```sh
'<component>/runtime/bin/python3' experiments/meeting-ai-capabilities/asr_autospeech_probe.py \
  --component '<component>' --fixture experiments/meeting-ai-capabilities/fixtures/mixed.wav \
  --output .build/capabilities/autospeech-vad-25s-merge05 \
  --max-speech-duration-seconds 2.5 --min-chunk-duration-seconds 0.5
```

The three-switch fixture includes a transcript reference and whole-clip baseline using `--reference-text "The review begins at nine. Please send the updated plan. Перевіримо план до дев’ятої. Надішліть оновлений документ. We can move the launch date after testing. Після перевірки оберемо дату запуску." --include-whole-clip-baseline`.

The probe tests account-for-all-samples interval partitioning, VAD gaps, short chunks, and invalid fixed-window settings with:

```sh
python3 -m unittest discover -s experiments/meeting-ai-capabilities -p 'test_asr_segmentation_probe.py' -v
```
