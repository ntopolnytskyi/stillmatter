"""Report unrelated 997 Hz tone in an authorized speech-call PCM16 WAV.

A human must confirm the remote speaker's unique phrase is audible in the retained track.
Speech is not a pure-frequency reference: these diagnostics do not establish a pass
threshold or replace the controlled 440/997 Hz fixture experiment.
"""

import argparse
import array
import json
import math
import sys
import wave


def inspect(path):
    with wave.open(str(path), "rb") as audio:
        if audio.getsampwidth() != 2 or audio.getcomptype() != "NONE":
            raise ValueError("Expected uncompressed signed PCM16 WAV")
        rate, channels = audio.getframerate(), audio.getnchannels()
        samples = array.array("h", audio.readframes(audio.getnframes()))
    if sys.byteorder != "little":
        samples.byteswap()
    if not samples or rate <= 0 or channels <= 0:
        raise ValueError("No retained audio samples")
    results = []
    for channel in range(channels):
        values = samples[channel::channels]
        # One-second windows avoid diluting a short utterance with silent capture time.
        windows = [values[start:start + rate] for start in range(0, len(values), rate)]
        powers = []
        for window in windows:
            if not window:
                continue
            rms = math.sqrt(sum((sample / 32768) ** 2 for sample in window) / len(window))
            real = sum((sample / 32768) * math.cos(2 * math.pi * 997 * i / rate)
                       for i, sample in enumerate(window))
            imaginary = sum((sample / 32768) * math.sin(2 * math.pi * 997 * i / rate)
                            for i, sample in enumerate(window))
            tone = 2 * math.hypot(real, imaginary) / len(window)
            powers.append({"rms": rms, "unrelated997HzAmplitude": tone})
        results.append({"channel": channel, "peakOneSecondRMS": max(p["rms"] for p in powers),
                        "peak997HzAmplitude": max(p["unrelated997HzAmplitude"] for p in powers)})
    return {"frames": len(samples) // channels, "sampleRate": rate, "channels": results,
            "manualSpeechConfirmationRequired": True, "scopePassed": None,
            "interpretation": "Confirm the unique remote phrase by listening; compare the 997 Hz amplitude to a separately authorized all-system control before claiming leakage rejection."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wav")
    print(json.dumps(inspect(parser.parse_args().wav), indent=2))


if __name__ == "__main__":
    main()
