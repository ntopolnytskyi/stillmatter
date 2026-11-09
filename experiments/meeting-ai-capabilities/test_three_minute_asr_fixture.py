import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import wave

import make_three_minute_asr_fixture as fixture


class ThreeMinuteConversationFixtureTests(unittest.TestCase):
    def test_dialogue_has_unique_alternating_bilingual_turns(self):
        self.assertEqual(len(fixture.DIALOGUE), 40)
        self.assertEqual(len({text for _, text in fixture.DIALOGUE}), 40)
        self.assertEqual([voice for voice, _ in fixture.DIALOGUE],
                         ['Samantha', 'Lesya'] * 20)

    def test_generation_writes_exact_pcm_duration_and_matching_reference(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / 'conversation.wav'
            reference_file = root / 'reference.txt'

            def fake_process(command, check, timeout):
                if command[0] == 'say':
                    Path(command[command.index('-o') + 1]).write_bytes(b'fake aiff')
                    return
                wav_path = Path(command[-1])
                with wave.open(str(wav_path), 'wb') as generated:
                    generated.setparams((1, 2, fixture.SAMPLE_RATE, 160, 'NONE', 'not compressed'))
                    generated.writeframes(b'\x01\x00' * 160)

            with patch.object(fixture.subprocess, 'run', side_effect=fake_process) as run_process:
                report = fixture.generate(output, reference_file, say='say', ffmpeg='ffmpeg')

            with wave.open(str(output), 'rb') as generated:
                self.assertEqual(generated.getparams()[:3], (1, 2, fixture.SAMPLE_RATE))
                self.assertEqual(generated.getnframes(), fixture.TARGET_SECONDS * fixture.SAMPLE_RATE)
            expected_reference = ' '.join(text for _, text in fixture.DIALOGUE) + '\n'
            self.assertEqual(reference_file.read_text(), expected_reference)
            self.assertEqual(report['uniqueTurnCount'], len(fixture.DIALOGUE))
            self.assertEqual(report['sourceSha256'], hashlib.sha256(output.read_bytes()).hexdigest())
            self.assertEqual(run_process.call_count, len(fixture.DIALOGUE) * 2)


if __name__ == '__main__':
    unittest.main()
