"""Run full-recording Auto on a retained synthetic fixture for comparison."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import time

from asr_probe import wer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--component', type=Path, required=True)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--reference-file', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--multilingual', action='store_true',
                        help='Redetect language for every decoder segment')
    parser.add_argument('--chunk-length', type=int,
                        help='Optional decoder chunk length in seconds (up to 30)')
    args = parser.parse_args()
    os.environ['HF_HUB_OFFLINE'] = '1'
    os.environ['TRANSFORMERS_OFFLINE'] = '1'

    from faster_whisper import WhisperModel

    model = WhisperModel(str(args.component / 'model'), device='cpu', compute_type='int8',
                         local_files_only=True, cpu_threads=4, num_workers=1)
    reference = args.reference_file.read_text()
    started = time.monotonic()
    transcribe_options = {'language': None, 'vad_filter': True,
                          'condition_on_previous_text': False,
                          'multilingual': args.multilingual}
    if args.chunk_length is not None:
        transcribe_options['chunk_length'] = args.chunk_length
    segments, info = model.transcribe(str(args.fixture), **transcribe_options)
    transcript = ' '.join(segment.text for segment in segments).strip()
    result = {
        'kind': 'synthetic-whole-recording-auto-probe',
        'source': args.fixture.name,
        'sourceSha256': hashlib.sha256(args.fixture.read_bytes()).hexdigest(),
        'model': args.component.name,
        'languageMode': 'Auto with per-segment language detection' if args.multilingual else 'Auto',
        'multilingual': args.multilingual,
        'chunkLengthSeconds': args.chunk_length,
        'detectedLanguage': info.language,
        'transcript': transcript,
        'reference': reference,
        'wordErrorRate': wer(reference, transcript),
        'elapsedSeconds': time.monotonic() - started,
        'peakRSSBytes': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
