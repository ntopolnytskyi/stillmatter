import unittest

from asr_minute_language_probe import selected_language


class MinuteLanguageSelectionTests(unittest.TestCase):
    def test_english_detection_selects_english(self):
        self.assertEqual(selected_language('en'), 'en')

    def test_ukrainian_and_russian_detections_select_ukrainian(self):
        self.assertEqual(selected_language('uk'), 'uk')
        self.assertEqual(selected_language('ru'), 'uk')

    def test_unsupported_non_english_detection_never_selects_russian(self):
        self.assertEqual(selected_language('pl'), 'uk')
        self.assertNotEqual(selected_language('ru'), 'ru')


if __name__ == '__main__':
    unittest.main()
