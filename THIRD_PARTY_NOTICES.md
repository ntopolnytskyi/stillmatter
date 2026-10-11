# Third-party notices

This file records third-party components identified in Stillmatter's source and
runtime setup. It is **not yet a complete attribution record**: the upstream
source and copyright holder of the modified echo-cancellation port have not
been identified in this repository. Do not distribute Stillmatter until the
missing attribution and applicable original license notices are verified.

## Modified echo-cancellation port — attribution pending

`Sources/StillmatterCore/EchoCanceller.swift` and the surrounding
`EchoCancellationSidecar` / `MacEchoCancellationProcessor` integration are
identified by this repository as a modified GPLv3 echo-cancellation port. The
original project's name, source URL, copyright holder(s), original notice,
and modification history are not recorded in the available source. **Do not
attribute this code to a guessed upstream project.** Obtain the upstream
provenance and preserve its actual copyright/license notices here and in the
relevant source files before distributing the app.

ATTRIBUTION_REVIEW_REQUIRED

## Optional, user-installed transcription components

Stillmatter's Settings can download and install these into the user's
Application Support directory; they are **not bundled in the app produced by
`scripts/build-app.sh`**:

- [faster-whisper](https://github.com/SYSTRAN/faster-whisper), pinned to
  version 1.2.1 by `Sources/StillmatterTranscriptionRuntime/FasterWhisperTranscription.swift`.
  Its installer also downloads Python dependencies, including CTranslate2;
  their exact versions and license notices are determined by the installed
  environment and must be reviewed separately if distributing that environment.
- Recommended model:
  [`dropbox-dash/faster-whisper-large-v3-turbo`](https://huggingface.co/dropbox-dash/faster-whisper-large-v3-turbo).
- Full-quality model:
  [`Systran/faster-whisper-large-v3`](https://huggingface.co/Systran/faster-whisper-large-v3).

An explicitly configured whisper.cpp executable/model may also be used, but
Stillmatter does not ship those files. These links identify downloads, **not**
a claim that the downloads share Stillmatter's GPLv3 license. Consult the
license terms accompanying the specific installed components and models.

## Stillmatter license

Stillmatter's GPL version 3 license text is in [`LICENSE`](LICENSE) and is
copied into the development app bundle. This notice does not replace the
original notices or license obligations of any third-party component.
