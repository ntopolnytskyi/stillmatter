import array
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import wave

from scope_probe import measure, write_tone
from rpc_probe import ProbeFailure, run_child
from asr_probe import wer


class ScopeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_authorized_tone_passes_and_unrelated_tone_fails(self):
        target, other = self.root / 'target.wav', self.root / 'other.wav'
        write_tone(target, 440, seconds=.1)
        write_tone(other, 997, seconds=.1)
        self.assertTrue(measure(target)['scopePassed'])
        self.assertFalse(measure(other)['scopePassed'])

    def test_phase_opposed_stereo_leakage_cannot_cancel(self):
        target = self.root / 'target.wav'
        other = self.root / 'other.wav'
        write_tone(target, 440, seconds=.1)
        write_tone(other, 997, seconds=.1)
        def read(path):
            with wave.open(str(path)) as source:
                return array.array('h', source.readframes(source.getnframes()))
        target_samples, other_samples = read(target), read(other)
        mixed = array.array('h', (v for t, o in zip(target_samples, other_samples) for v in (t+o, t-o)))
        path = self.root / 'stereo.wav'
        with wave.open(str(path), 'wb') as output:
            output.setparams((2, 2, 48000, 0, 'NONE', 'not compressed'))
            output.writeframes(mixed.tobytes())
        self.assertFalse(measure(path)['scopePassed'])

    def test_silence_and_empty_do_not_prove_scope(self):
        path = self.root / 'silence.wav'
        write_tone(path, 0, seconds=.1)
        self.assertFalse(measure(path)['scopePassed'])
        write_tone(path, 0, seconds=0)
        with self.assertRaisesRegex(ValueError, 'No retained samples'):
            measure(path)

    def test_cli_returns_failure_for_unrelated_audio(self):
        path = self.root / 'other.wav'
        write_tone(path, 997, seconds=.1)
        result = subprocess.run([sys.executable, str(Path(__file__).with_name('scope_probe.py')),
                                 '--analyze', str(path)], capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(json.loads(result.stdout)['scopePassed'])


class ASRMetricTests(unittest.TestCase):
    def test_word_error_rate_counts_unicode_insertions_deletions_and_substitutions(self):
        self.assertEqual(wer("Привіт, Олено!", "привіт олено"), 0)
        self.assertEqual(wer("one two", "one"), .5)
        self.assertEqual(wer("one two", "one three"), .5)
        self.assertEqual(wer("one two", "one two three"), .5)
        self.assertIsNone(wer("", "hallucination"))


class RPCTests(unittest.TestCase):
    def child(self, records, status=0, raw=None):
        script = 'import sys; sys.stdin.buffer.readline(); '
        script += f'sys.stdout.buffer.write({raw!r}); ' if raw is not None else f'print({chr(10).join(json.dumps(r, ensure_ascii=False) for r in records)!r}); '
        script += f'sys.stdout.flush(); sys.exit({status})'
        with tempfile.TemporaryDirectory() as root:
            return run_child([sys.executable, '-c', script], root, timeout=2)

    def accepted(self):
        return {'type': 'response', 'id': 'probe-1', 'command': 'prompt', 'success': True,
                'data': {'disposition': 'started'}}

    def test_acknowledgement_and_agent_end_are_not_completion(self):
        with self.assertRaisesRegex(ProbeFailure, 'No agent_settled'):
            self.child([self.accepted(), {'type': 'agent_end'}])

    def test_settled_still_requires_valid_artifact(self):
        result = self.child([self.accepted(), {'type': 'agent_settled', 'aborted': False}])
        self.assertTrue(result['settled'])
        self.assertFalse(result['validArtifact'])

    def test_final_message_can_be_validated_after_settlement(self):
        result = self.child([self.accepted(), {'type': 'message_end', 'message': {
            'role': 'assistant', 'content': [{'type': 'text', 'text': '{"probe":"synthetic"}'}]}},
            {'type': 'agent_end'}, {'type': 'agent_settled', 'aborted': False}])
        self.assertTrue(result['validArtifact'])

    def test_malformed_protocol_fails(self):
        with self.assertRaisesRegex(ProbeFailure, 'Malformed JSONL'):
            self.child([], raw=b'not json\n')

    def test_child_failure_fails_even_after_acknowledgement(self):
        with self.assertRaisesRegex(ProbeFailure, 'status 9'):
            self.child([self.accepted()], status=9)

    def test_unicode_separator_does_not_split_jsonl(self):
        result = self.child([self.accepted(), {'type': 'diagnostic', 'value': 'А\u2028B\u2029C'},
                             {'type': 'agent_settled', 'aborted': False}])
        self.assertTrue(result['settled'])

    def test_provider_failure_is_not_valid_output(self):
        result = self.child([self.accepted(), {'type': 'message_end', 'message': {
            'role': 'assistant', 'stopReason': 'error', 'content': []}},
            {'type': 'agent_settled', 'aborted': False}])
        self.assertTrue(result['providerFailed'])
        self.assertFalse(result['validArtifact'])


if __name__ == '__main__':
    unittest.main()
