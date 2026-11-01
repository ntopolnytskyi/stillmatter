"""Non-shipped synthetic tone fixture and measured PCM scope assertion.

No recording permission, browser automation, or actual capture is performed.
Use the generated tones in an explicitly authorized synthetic call and unrelated tab/app,
then analyze a PCM16 WAV copied from the capture under test.
"""
import argparse
import array
import json
import math
from pathlib import Path
import sys
import wave

RATE = 48000
TARGET = 440
UNRELATED = 997


def write_tone(path, frequency, seconds=4, rate=RATE):
    values = array.array('h', (round(8000 * math.sin(2 * math.pi * frequency * n / rate))
                               for n in range(round(seconds * rate))))
    if sys.byteorder != 'little':
        values.byteswap()
    with wave.open(str(path), 'wb') as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(rate)
        output.writeframes(values.tobytes())


def measure(path, target=TARGET, unrelated=UNRELATED, minimum_target=0.02, maximum_leakage_db=-40):
    with wave.open(str(path), 'rb') as source:
        if source.getsampwidth() != 2 or source.getcomptype() != 'NONE':
            raise ValueError('Expected uncompressed signed PCM16 WAV')
        rate, channels, frames = source.getframerate(), source.getnchannels(), source.getnframes()
        samples = array.array('h', source.readframes(frames))
    if sys.byteorder != 'little':
        samples.byteswap()
    if not samples:
        raise ValueError('No retained samples')
    # Measure each channel separately so phase-opposed stereo cannot cancel leakage.
    amplitudes = []
    for channel in range(channels):
        values = [value / 32768 for value in samples[channel::channels]]
        def amplitude(frequency):
            angular = 2 * math.pi * frequency / rate
            real = sum(v * math.cos(angular * i) for i, v in enumerate(values))
            imaginary = sum(v * math.sin(angular * i) for i, v in enumerate(values))
            return 2 * math.hypot(real, imaginary) / len(values)
        amplitudes.append((amplitude(target), amplitude(unrelated)))
    target_amplitude = max(v[0] for v in amplitudes)
    leakage_amplitude = max(v[1] for v in amplitudes)
    leakage_db = 20 * math.log10(max(leakage_amplitude, 1e-12) / max(target_amplitude, 1e-12))
    return {'frames': frames, 'sampleRate': rate, 'channels': channels,
            'durationSeconds': frames / rate, 'targetAmplitude': target_amplitude,
            'unrelatedAmplitude': leakage_amplitude, 'leakageRelativeDB': leakage_db,
            'scopePassed': target_amplitude >= minimum_target and leakage_db <= maximum_leakage_db,
            'thresholdPurpose': 'synthetic fixture discrimination, not speech quality'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--generate', type=Path)
    parser.add_argument('--analyze', type=Path)
    args = parser.parse_args()
    if args.generate:
        args.generate.mkdir(parents=True, exist_ok=True)
        write_tone(args.generate / 'authorized-440hz.wav', TARGET)
        write_tone(args.generate / 'unrelated-997hz.wav', UNRELATED)
        return 0
    if args.analyze:
        result = measure(args.analyze)
        print(json.dumps(result, indent=2))
        return 0 if result['scopePassed'] else 1
    parser.error('Select --generate or --analyze')


if __name__ == '__main__':
    raise SystemExit(main())
