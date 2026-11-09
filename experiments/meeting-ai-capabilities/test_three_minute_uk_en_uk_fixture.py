import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import wave

import make_three_minute_uk_en_uk_fixture as fixture


class UkrainianEnglishUkrainianFixtureTests(unittest.TestCase):
    def test_fixture_contains_three_unique_language_blocks(self):
        self.assertEqual([language for language, _, _ in fixture.BLOCKS], ['uk', 'en', 'uk'])
        self.assertEqual(len({text for _, _, lines in fixture.BLOCKS for text in lines}),
                         sum(len(lines) for _, _, lines in fixture.BLOCKS))

    def test_generation_writes_three_exact_minute_blocks_and_reference(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / 'uk-en-uk.wav'
            reference_file = root / 'reference.txt'

            def fake_process(command, check, timeout):
                if command[0] == 'say':
                    Path(command[command.index('-o') + 1]).write_bytes(b'fake aiff')
                    return
                with wave.open(command[-1], 'wb') as generated:
                    generated.setparams((1, 2, fixture.SAMPLE_RATE, 160, 'NONE', 'not compressed'))
                    generated.writeframes(b'\x01\x00' * 160)

            with patch.object(fixture.subprocess, 'run', side_effect=fake_process):
                report = fixture.generate(output, reference_file, say='say', ffmpeg='ffmpeg')

            with wave.open(str(output), 'rb') as generated:
                self.assertEqual(generated.getparams()[:3], (1, 2, fixture.SAMPLE_RATE))
                self.assertEqual(generated.getnframes(), 180 * fixture.SAMPLE_RATE)
            self.assertEqual(report['languagePattern'], ['uk', 'en', 'uk'])
            self.assertEqual(report['sourceSha256'], hashlib.sha256(output.read_bytes()).hexdigest())
            self.assertEqual(reference_file.read_text(), report['referenceText'] + '\n')


if __name__ == '__main__':
    unittest.main()
