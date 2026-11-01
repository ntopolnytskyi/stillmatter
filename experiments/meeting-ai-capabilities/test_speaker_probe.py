import array
import math
from pathlib import Path
import tempfile
import unittest
import wave

from speaker_probe import cosine, load_pcm, run, score, synthetic_reference


class SpeakerMetricTests(unittest.TestCase):
    def test_anonymous_mapping_does_not_count_label_permutation_as_error(self):
        ref = [{'a'}] * 100 + [{'b'}] * 100
        measured = score(ref, [{'start': 0, 'end': 1, 'speaker': 12},
                               {'start': 1, 'end': 2, 'speaker': 3}], 2)
        self.assertEqual(measured['syntheticFrameErrorRate'], 0)
        self.assertEqual(measured['referenceSpeakerCount'], 2)

    def test_overlap_missing_speaker_is_counted_and_wrong_cluster_cannot_map_twice(self):
        measured = score([{'a', 'b'}] * 100,
                         [{'start': 0, 'end': 1, 'speaker': 0}], 1)
        self.assertEqual(measured['syntheticFrameErrorRate'], .5)
        self.assertEqual(measured['missedSpeakerSeconds'], 1)
        measured = score([{'a'}] * 50 + [{'b'}] * 50,
                         [{'start': 0, 'end': 1, 'speaker': 0}], 1)
        self.assertEqual(measured['confusedSpeakerSeconds'], .5)

    def test_silence_reports_false_alarm_without_inventing_error_denominator(self):
        measured = score([set()] * 100, [{'start': .2, 'end': .8, 'speaker': 0}], 1)
        self.assertIsNone(measured['syntheticFrameErrorRate'])
        self.assertAlmostEqual(measured['falseAlarmSpeakerSeconds'], .6)

    def test_perfect_overlap_and_extra_speaker(self):
        measured = score([{'a', 'b'}] * 100,
                         [{'start': 0, 'end': 1, 'speaker': i} for i in range(3)], 1)
        self.assertEqual(measured['confusedSpeakerSeconds'], 0)
        self.assertEqual(measured['falseAlarmSpeakerSeconds'], 1)
        self.assertEqual(measured['observedOverlapSeconds'], 1)

    def test_invalid_timestamps_are_rejected(self):
        for start, end in ((-.1, .5), (.5, .5), (0, 10)):
            with self.assertRaisesRegex(ValueError, 'timestamp'):
                score([{'a'}] * 100, [{'start': start, 'end': end, 'speaker': 1}], 1)

    def test_source_offsets_cover_partial_final_frame_and_preserve_overlap(self):
        frames = synthetic_reference([('a', array.array('h', [10000] * 161), 0),
                                      ('b', array.array('h', [10000] * 160), 160)], 320)
        self.assertEqual(frames, [{'a'}, {'a', 'b'}])
        self.assertEqual(synthetic_reference([('a', array.array('h', [0] * 320), 0)], 320),
                         [set(), set()])

    def test_cosine_rejects_invalid_vectors_and_measures_identity(self):
        self.assertAlmostEqual(cosine([1, 2], [2, 4]), 1)
        self.assertAlmostEqual(cosine([1, 0], [0, 1]), 0)
        for first, second in (([], []), ([0], [1]), ([math.nan], [1]), ([1], [1, 2])):
            with self.assertRaises(ValueError):
                cosine(first, second)

    def test_pcm_rejects_wrong_rate_or_empty_audio(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'test.wav'
            for rate, data in ((8000, b'\x01\x00'), (16000, b'')):
                with wave.open(str(path), 'wb') as output:
                    output.setparams((1, 2, rate, 0, 'NONE', 'not compressed'))
                    output.writeframes(data)
                with self.assertRaises(ValueError):
                    load_pcm(path)

    def test_missing_models_fail_before_runtime_or_fixture_access(self):
        with tempfile.TemporaryDirectory() as temporary:
            missing = Path(temporary) / 'missing.onnx'
            with self.assertRaisesRegex(ValueError, 'Local model file unavailable'):
                run(Path(temporary), missing, missing, Path(temporary))


if __name__ == '__main__':
    unittest.main()
