"""Evaluate one language decision per minute with Russian mapped to Ukrainian."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import time

from asr_probe import wer


def selected_language(detected_language):
    """Reduce model detections to supported output languages; Russian maps to Ukrainian."""
    return 'en' if detected_language == 'en' else 'uk'


def run(component, fixture, reference, compare_auto=False):
    os.environ['HF_HUB_OFFLINE'] = '1'
    os.environ['TRANSFORMERS_OFFLINE'] = '1'
    from faster_whisper import WhisperModel
    from faster_whisper.audio import decode_audio

    load_started = time.monotonic()
    model = WhisperModel(str(component / 'model'), device='cpu', compute_type='int8',
                         local_files_only=True, cpu_threads=4, num_workers=1)
    model_load_seconds = time.monotonic() - load_started
    audio = decode_audio(str(fixture))
    window_samples = 60 * 16000
    windows = []
    output_segments = []
    transcription_started = time.monotonic()
    for start_sample in range(0, len(audio), window_samples):
        end_sample = min(start_sample + window_samples, len(audio))
        window_audio = audio[start_sample:end_sample]
        if len(window_audio) == 0:
            continue
        detected, probability, alternatives = model.detect_language(
            audio=window_audio, language_detection_segments=2)
        selected = selected_language(detected)
        russian_override = detected == 'ru'
        offset = start_sample / 16000
        segments, _ = model.transcribe(window_audio, language=selected, vad_filter=True,
                                       condition_on_previous_text=False)
        rows = [{'start': segment.start + offset, 'end': segment.end + offset,
                 'text': segment.text, 'language': selected} for segment in segments]
        output_segments.extend(rows)
        windows.append({
            'startSeconds': offset,
            'endSeconds': end_sample / 16000,
            'detectedLanguage': detected,
            'languageProbability': probability,
            'topAlternatives': [{'language': language, 'probability': score}
                                for language, score in alternatives[:5]],
            'selectedLanguage': selected,
            'russianMappedToUkrainian': russian_override,
            'segments': rows,
        })

    transcript = ' '.join(row['text'] for row in output_segments).strip()
    auto_baseline = None
    if compare_auto:
        baseline_started = time.monotonic()
        segments, info = model.transcribe(str(fixture), language=None, vad_filter=True,
                                          condition_on_previous_text=False)
        baseline_text = ' '.join(segment.text for segment in segments).strip()
        auto_baseline = {
            'detectedLanguage': info.language,
            'transcript': baseline_text,
            'wordErrorRate': wer(reference, baseline_text),
            'elapsedSeconds': time.monotonic() - baseline_started,
        }
    return {
        'kind': 'synthetic-one-minute-language-window-probe',
        'source': fixture.name,
        'sourceSha256': hashlib.sha256(fixture.read_bytes()).hexdigest(),
        'model': component.name,
        'runtime': {'device': 'cpu', 'computeType': 'int8', 'cpuThreads': 4},
        'windowSeconds': 60,
        'languageRule': 'detected en selects en; every other detected code selects uk; ru is explicitly recorded as mapped to uk',
        'modelLoadSeconds': model_load_seconds,
        'windows': windows,
        'transcript': transcript,
        'reference': reference,
        'wordErrorRate': wer(reference, transcript),
        'autoBaseline': auto_baseline,
        'elapsedSeconds': time.monotonic() - transcription_started,
        'peakRSSBytes': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--component', type=Path, required=True)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--reference-file', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--compare-auto', action='store_true')
    args = parser.parse_args()
    result = run(args.component, args.fixture, args.reference_file.read_text(), args.compare_auto)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
