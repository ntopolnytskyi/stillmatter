"""Non-shipped local ASR synthetic smoke evaluation using existing installed weights.

Invoke with the app-installed runtime Python. It creates synthetic TTS fixtures only,
never reads a Meeting, downloads a model, or writes into the installed component.
Results do not establish real human speech, diarization, or speaker-recognition quality.
"""
import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import time
import wave


def words(text):
    return re.findall(r"\w+", text.casefold())


def wer(reference, actual):
    expected, heard = words(reference), words(actual)
    previous = list(range(len(heard) + 1))
    for index, word in enumerate(expected, 1):
        current = [index]
        for column, other in enumerate(heard, 1):
            current.append(min(current[-1] + 1, previous[column] + 1,
                               previous[column - 1] + (word != other)))
        previous = current
    return previous[-1] / len(expected) if expected else None


def run(component, output, retained_fixtures=None):
    os.environ['HF_HUB_OFFLINE'] = '1'
    os.environ['TRANSFORMERS_OFFLINE'] = '1'
    os.environ['HF_HOME'] = str(output / 'isolated-hf-cache')
    os.environ['XDG_CACHE_HOME'] = str(output / 'isolated-cache')
    output.mkdir(parents=True, exist_ok=True)
    english = 'The launch review is on Friday. Anna will send the project notes.'
    ukrainian = 'Наша зустріч відбудеться у п’ятницю. Олена підготує звіт для команди.'
    if retained_fixtures:
        for name in ('english', 'ukrainian', 'mixed', 'silence', 'overlap'):
            shutil.copy2(retained_fixtures / (name + '.wav'), output / (name + '.wav'))
    else:
        fixtures = [('english', 'Samantha', english), ('ukrainian', 'Lesya', ukrainian)]
        for name, voice, text in fixtures:
            subprocess.run(['/usr/bin/say', '-v', voice, '-o', str(output / (name + '.aiff')), text], check=True, timeout=30)
            subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(output / (name + '.aiff')),
                            '-ar', '16000', '-ac', '1', str(output / (name + '.wav'))], check=True, timeout=15)
        subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(output / 'english.wav'),
                        '-i', str(output / 'ukrainian.wav'), '-filter_complex', '[0:a][1:a]concat=n=2:v=0:a=1',
                        str(output / 'mixed.wav')], check=True, timeout=15)
        subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(output / 'english.wav'),
                        '-i', str(output / 'ukrainian.wav'), '-filter_complex', 'amix=inputs=2:duration=longest',
                        str(output / 'overlap.wav')], check=True, timeout=15)
        with wave.open(str(output / 'silence.wav'), 'wb') as silence:
            silence.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
            silence.writeframes(b'\x00\x00' * 16000 * 5)
    from faster_whisper import WhisperModel
    started = time.monotonic()
    model = WhisperModel(str(component / 'model'), device='cpu', compute_type='int8', local_files_only=True,
                         cpu_threads=4, num_workers=1)
    report = {'kind': 'synthetic-smoke-only', 'wordTokenization': 'Unicode word runs; punctuation including apostrophes splits tokens; casefolded', 'modelLoadSeconds': time.monotonic() - started,
              'runtime': {name: importlib.metadata.version(name) for name in ['faster-whisper','ctranslate2','av','onnxruntime']},
              'device': 'cpu', 'computeType': 'int8', 'cpuThreads': 4,
              'vadFilter': True, 'language': 'Auto (None)', 'fixtures': []}
    for name, reference in [('english', english), ('ukrainian', ukrainian), ('mixed', english + ' ' + ukrainian),
                            ('silence', ''), ('overlap', None)]:
        path = output / (name + '.wav')
        with wave.open(str(path)) as source:
            duration = source.getnframes() / source.getframerate()
        start = time.monotonic()
        segments, info = model.transcribe(str(path), language=None, vad_filter=True)
        segments = [{'start': s.start, 'end': s.end, 'text': s.text} for s in segments]
        elapsed = time.monotonic() - start
        actual = ' '.join(s['text'] for s in segments)
        fixture = {'id': name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                   'durationSeconds': duration, 'elapsedSeconds': elapsed, 'realTimeFactor': elapsed / duration,
                   'detectedLanguage': info.language, 'segments': segments,
                   'reference': reference, 'wordErrorRate': wer(reference, actual) if reference else None,
                   'peakRSSBytes': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss}
        report['fixtures'].append(fixture)
        (output / 'results.json').write_text(json.dumps(report, indent=2, ensure_ascii=False))
        print(json.dumps({'fixture': name, 'elapsedSeconds': elapsed, 'wordErrorRate': fixture['wordErrorRate'],
                          'segmentCount': len(segments)}), flush=True)
    return report


def compare(component, output):
    os.environ['HF_HUB_OFFLINE'] = '1'
    os.environ['TRANSFORMERS_OFFLINE'] = '1'
    os.environ['HF_HOME'] = str(output / 'isolated-hf-cache')
    os.environ['XDG_CACHE_HOME'] = str(output / 'isolated-cache')
    from faster_whisper import WhisperModel
    prior = json.loads((output / 'results.json').read_text())
    references = {f['id']: f['reference'] for f in prior['fixtures']}
    model = WhisperModel(str(component / 'model'), device='cpu', compute_type='int8', local_files_only=True,
                         cpu_threads=4, num_workers=1)
    results = {'kind': 'synthetic-configuration-comparison-only', 'cpuThreads': 4,
               'device': 'cpu', 'computeType': 'int8', 'language': 'Auto (None)',
               'chunkBoundaryPolicy': 'Known synthetic concatenation boundary; not a validated real-recording segmenter',
               'runs': []}
    for label, names, vad in [('whole-clip-no-vad', ['mixed'], False),
                              ('all-fixture-chunks-auto', ['english','ukrainian'], True)]:
        text, pieces, elapsed_total, offset = [], [], 0, 0
        for name in names:
            path = output / (name + '.wav')
            start = time.monotonic()
            segments, info = model.transcribe(str(path), language=None, vad_filter=vad)
            rows = [{'start': s.start + offset, 'end': s.end + offset, 'text': s.text} for s in segments]
            elapsed = time.monotonic() - start
            with wave.open(str(path)) as source:
                duration = source.getnframes() / source.getframerate()
            pieces.append({'fixture': name, 'originalStartSeconds': offset,
                           'durationSeconds': duration, 'language': info.language,
                           'elapsedSeconds': elapsed, 'segments': rows})
            text.extend(r['text'] for r in rows)
            elapsed_total += elapsed
            offset += duration
        combined = ' '.join(text)
        record = {'configuration': label, 'vadFilter': vad, 'coveredDurationSeconds': offset,
                  'elapsedSeconds': elapsed_total, 'wordErrorRate': wer(references['mixed'], combined),
                  'pieces': pieces, 'peakRSSBytes': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss}
        results['runs'].append(record)
        (output / 'comparison.json').write_text(json.dumps(results, indent=2, ensure_ascii=False))
        print(json.dumps({'configuration': label, 'wordErrorRate': record['wordErrorRate'],
                          'elapsedSeconds': elapsed_total}), flush=True)
    return results


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--component', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--compare', action='store_true')
    parser.add_argument('--retained-fixtures', type=Path)
    args = parser.parse_args()
    if args.compare:
        compare(args.component, args.output)
    else:
        run(args.component, args.output, args.retained_fixtures)
