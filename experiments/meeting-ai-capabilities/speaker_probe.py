"""Disposable local synthetic speaker evaluation; never enrolls People or persists vectors.

Reference activity is constructed from clean fixture energy at 10 ms resolution,
not human speech annotations. Resulting error rates are fixture diagnostics only.
"""
import argparse
import array
import hashlib
import importlib.metadata
import itertools
import json
import math
from pathlib import Path
import platform
import resource
import subprocess
import sys
import time
import wave

RATE = 16000
FRAME = 160


def load_pcm(path):
    with wave.open(str(path), 'rb') as source:
        if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (1, 2, RATE):
            raise ValueError('Expected mono PCM16 at 16000 Hz')
        samples = array.array('h', source.readframes(source.getnframes()))
    if sys.byteorder != 'little':
        samples.byteswap()
    if not samples:
        raise ValueError('Empty fixture')
    return samples


def synthetic_reference(sources, total_samples):
    """Sources are (speaker, original PCM samples, offset in samples)."""
    frames = [set() for _ in range(math.ceil(total_samples / FRAME))]
    for speaker, pcm, offset in sources:
        for index in range(0, len(pcm), FRAME):
            block = pcm[index:index + FRAME]
            # Fixture-specific energy labelling, not an enrollment/VAD threshold.
            rms = math.sqrt(sum((value / 32768) ** 2 for value in block) / len(block))
            if rms > .005:
                first = (index + offset) // FRAME
                last = min(len(frames), math.ceil((index + len(block) + offset) / FRAME))
                for target in range(first, last):
                    frames[target].add(speaker)
    return frames


def score(reference, segments, duration):
    """Anonymous one-to-one optimal mapping; include overlap, no boundary collar."""
    if not reference or duration <= 0:
        raise ValueError('Nonempty reference and positive duration required')
    hypothesis = [set() for _ in reference]
    for row in segments:
        if not (0 <= row['start'] < row['end'] <= duration + .1):
            raise ValueError('Invalid diarization timestamp')
        for index in range(len(reference)):
            center = (index + .5) * FRAME / RATE
            if row['start'] <= center < row['end']:
                hypothesis[index].add(row['speaker'])
    expected = sorted(set().union(*reference))
    predicted = sorted(set().union(*hypothesis))
    # Tiny synthetic set: at most two reference voices. Nulls allow missing voices.
    choices = predicted + [f'unmapped-{index}' for index in range(len(expected))]
    best_correct, best = -1, {}
    for assignment in itertools.permutations(choices, len(expected)):
        mapping = dict(zip(assignment, expected))
        correct = sum(len(ref.intersection(mapping.get(h) for h in hyp))
                      for ref, hyp in zip(reference, hypothesis))
        if correct > best_correct:
            best_correct, best = correct, mapping
    miss = false_alarm = confusion = denominator = 0
    for ref, hyp in zip(reference, hypothesis):
        correct = len(ref.intersection(best.get(h) for h in hyp))
        miss += max(len(ref) - len(hyp), 0)
        false_alarm += max(len(hyp) - len(ref), 0)
        confusion += min(len(ref), len(hyp)) - correct
        denominator += len(ref)
    seconds = FRAME / RATE
    return {'referenceSpeakerSeconds': denominator * seconds,
            'missedSpeakerSeconds': miss * seconds,
            'falseAlarmSpeakerSeconds': false_alarm * seconds,
            'confusedSpeakerSeconds': confusion * seconds,
            'syntheticFrameErrorRate': ((miss + false_alarm + confusion) / denominator
                                        if denominator else None),
            'referenceSpeakerCount': len(expected), 'observedSpeakerCount': len(predicted),
            'referenceOverlapSeconds': sum(len(row) > 1 for row in reference) * seconds,
            'observedOverlapSeconds': sum(len(row) > 1 for row in hypothesis) * seconds}


def cosine(first, second):
    if len(first) != len(second) or not first:
        raise ValueError('Matching nonempty vector dimensions required')
    if not all(math.isfinite(value) for value in itertools.chain(first, second)):
        raise ValueError('Nonfinite embedding')
    norm = math.sqrt(sum(v * v for v in first) * sum(v * v for v in second))
    if norm == 0:
        raise ValueError('Zero embedding')
    return sum(a * b for a, b in zip(first, second)) / norm


def generate_held_out(output):
    fixtures = [('same-samantha', 'Samantha', 'Please check the calendar. The budget discussion begins tomorrow morning.'),
                ('same-lesya', 'Lesya', 'Сьогодні ми перевіримо план. Наступна розмова відбудеться завтра вранці.'),
                ('unknown-daniel', 'Daniel', 'We need another review before the release. Please bring the latest report.')]
    records = []
    for name, voice, text in fixtures:
        aiff, wav = output / (name + '.aiff'), output / (name + '.wav')
        subprocess.run(['/usr/bin/say', '-v', voice, '-o', str(aiff), text], check=True, timeout=30)
        subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(aiff), '-ar', str(RATE), '-ac', '1', str(wav)],
                       check=True, timeout=15)
        records.append({'id': name, 'voice': voice, 'text': text, 'sha256': sha(wav)})
    return records


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(fixtures, segmentation, embedding, output):
    # Model paths must exist before importing a runtime; no downloader/fallback.
    for path in (segmentation, embedding):
        if not path.is_file():
            raise ValueError('Local model file unavailable: ' + str(path))
    import numpy as np
    import sherpa_onnx as sherpa
    output.mkdir(parents=True, exist_ok=True)
    pcm = {name: load_pcm(fixtures / (name + '.wav'))
           for name in ('english', 'ukrainian', 'mixed', 'silence', 'overlap')}
    if pcm['mixed'] != pcm['english'] + pcm['ukrainian']:
        raise ValueError('Mixed fixture is not exact full-coverage source concatenation')
    references = {'english': [('samantha', pcm['english'], 0)],
                  'ukrainian': [('lesya', pcm['ukrainian'], 0)],
                  'mixed': [('samantha', pcm['english'], 0), ('lesya', pcm['ukrainian'], len(pcm['english']))],
                  'silence': [],
                  'overlap': [('samantha', pcm['english'], 0), ('lesya', pcm['ukrainian'], 0)]}
    report = {'kind': 'actual-local-inference-on-synthetic-tts-only',
              'environment': {'platform': platform.platform(), 'python': platform.python_version(),
                              'sherpa-onnx': importlib.metadata.version('sherpa-onnx'),
                              'numpy': importlib.metadata.version('numpy')},
              'models': {'segmentation': {'name': 'sherpa-onnx pyannote segmentation 3.0 FP32', 'sha256': sha(segmentation)},
                         'speakerEmbedding': {'name': 'sherpa-onnx NVIDIA NeMo TitaNet small', 'sha256': sha(embedding)}},
              'settings': {'provider': 'cpu', 'threads': 2, 'clusterThreshold': .5,
                           'minDurationOn': .3, 'minDurationOff': .5},
              'metric': {'reference': 'Clean source PCM RMS >0.005 per 10ms frame, fixture-only oracle activity',
                         'identityMapping': 'Optimal one-to-one anonymous cluster mapping; no collar; overlap included',
                         'limitations': 'Not human DER, voice identity, or validated enrollment thresholds'},
              'diarization': []}
    for name, samples in pcm.items():
        duration = len(samples) / RATE
        reference = synthetic_reference(references[name], len(samples))
        expected_count = len(set().union(*reference))
        for mode, count in [('unknown-count', -1), ('oracle-count', max(1, expected_count))]:
            if name == 'silence' and mode == 'oracle-count':
                continue
            started = time.monotonic()
            config = sherpa.OfflineSpeakerDiarizationConfig(
                segmentation=sherpa.OfflineSpeakerSegmentationModelConfig(
                    pyannote=sherpa.OfflineSpeakerSegmentationPyannoteModelConfig(model=str(segmentation)),
                    num_threads=2, provider='cpu'),
                embedding=sherpa.SpeakerEmbeddingExtractorConfig(model=str(embedding), num_threads=2, provider='cpu'),
                clustering=sherpa.FastClusteringConfig(num_clusters=count, threshold=.5),
                min_duration_on=.3, min_duration_off=.5)
            if not config.validate():
                raise ValueError('Invalid diarization model configuration')
            model = sherpa.OfflineSpeakerDiarization(config)
            loaded = time.monotonic()
            cpu_started = time.process_time()
            segments = [{'start': float(row.start), 'end': float(row.end), 'speaker': int(row.speaker)}
                        for row in model.process(np.array(samples, dtype=np.float32) / 32768).sort_by_start_time()]
            elapsed = time.monotonic() - loaded
            cpu_elapsed = time.process_time() - cpu_started
            result = {'fixture': name, 'sha256': sha(fixtures / (name + '.wav')), 'mode': mode,
                      'requestedClusters': count, 'durationSeconds': duration,
                      'loadSeconds': loaded - started, 'elapsedSeconds': elapsed,
                      'processCPUSeconds': cpu_elapsed,
                      'realTimeFactor': elapsed / duration, 'segments': segments,
                      'maxEndBeyondInputSeconds': max([0] + [row['end'] - duration for row in segments]),
                      'score': score(reference, segments, duration),
                      'peakRSSBytes': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss}
            report['diarization'].append(result)
            print(json.dumps({'fixture': name, 'mode': mode, 'score': result['score']}), flush=True)
            del model
    held_out = generate_held_out(output)
    extractor = sherpa.SpeakerEmbeddingExtractor(sherpa.SpeakerEmbeddingExtractorConfig(
        model=str(embedding), num_threads=2, provider='cpu'))
    vectors, voice_runs = {}, []
    for name in ('english', 'ukrainian', 'silence', 'overlap', *(row['id'] for row in held_out)):
        path = fixtures / (name + '.wav') if name in pcm else output / (name + '.wav')
        samples = load_pcm(path)
        started = time.monotonic()
        cpu_started = time.process_time()
        stream = extractor.create_stream()
        stream.accept_waveform(sample_rate=RATE, waveform=np.array(samples, dtype=np.float32) / 32768)
        stream.input_finished()
        ready = extractor.is_ready(stream)
        values = list(extractor.compute(stream)) if ready else []
        valid = bool(values) and all(math.isfinite(v) for v in values) and sum(v*v for v in values) > 0
        if valid:
            vectors[name] = values
        voice_runs.append({'fixture': name, 'sha256': sha(path), 'durationSeconds': len(samples) / RATE,
                           'elapsedSeconds': time.monotonic() - started, 'runtimeReady': ready,
                           'processCPUSeconds': time.process_time() - cpu_started,
                           'finiteNonzeroEmbedding': valid, 'dimensions': len(values),
                           'cleanEnrollmentCandidate': name not in ('silence', 'overlap')})
    comparisons = []
    for first, second, relation in [('english', 'same-samantha', 'same-synthetic-voice-independent-text'),
                                    ('ukrainian', 'same-lesya', 'same-synthetic-voice-independent-text'),
                                    ('english', 'ukrainian', 'different-synthetic-voices-and-languages'),
                                    ('english', 'unknown-daniel', 'unenrolled-synthetic-voice'),
                                    ('ukrainian', 'unknown-daniel', 'unenrolled-synthetic-voice'),
                                    ('english', 'silence', 'silence-invalid-for-enrollment'),
                                    ('english', 'overlap', 'overlap-invalid-for-enrollment')]:
        comparisons.append({'first': first, 'second': second, 'relation': relation,
                            'cosine': cosine(vectors[first], vectors[second]) if first in vectors and second in vectors else None})
    report['voiceMatching'] = {'heldOutGeneration': held_out, 'runs': voice_runs, 'comparisons': comparisons,
                               'thresholdSelected': None,
                               'limitations': 'No vectors persisted. Synthetic voices and languages confound identity; not a held-out human-speaker precision evaluation. Runtime readiness alone is not a clean-speech quality gate.'}
    report['peakRSSBytes'] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    (output / 'speaker-results.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixtures', type=Path, required=True)
    parser.add_argument('--segmentation', type=Path, required=True)
    parser.add_argument('--embedding', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    run(args.fixtures, args.segmentation, args.embedding, args.output)
