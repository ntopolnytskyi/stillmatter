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
    def child(self, records, status=0, raw=None, **limits):
        script = 'import sys; sys.stdin.buffer.readline(); '
        script += f'sys.stdout.buffer.write({raw!r}); ' if raw is not None else f'print({chr(10).join(json.dumps(r, ensure_ascii=False) for r in records)!r}); '
        script += f'sys.stdout.flush(); sys.exit({status})'
        with tempfile.TemporaryDirectory() as root:
            return run_child([sys.executable, '-c', script], root, timeout=2, **limits)

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

    def valid_message(self):
        return {'type': 'message_end', 'message': {
            'role': 'assistant', 'content': [{'type': 'text', 'text': '{"probe":"synthetic"}'}]}}

    def test_aborted_settlement_rejects_otherwise_valid_artifact(self):
        result = self.child([self.accepted(), self.valid_message(),
                             {'type': 'agent_settled', 'aborted': True}])
        self.assertTrue(result['aborted'])
        self.assertFalse(result['validArtifact'])

    def test_handled_prompt_does_not_need_or_imply_settlement(self):
        response = self.accepted()
        response['data']['disposition'] = 'handled'
        result = self.child([response])
        self.assertTrue(result['handled'])
        self.assertTrue(result['accepted'])
        self.assertFalse(result['settled'])
        self.assertFalse(result['validArtifact'])

    def test_handled_prompt_cannot_claim_unrelated_artifact(self):
        response = self.accepted()
        response['data']['disposition'] = 'handled'
        result = self.child([response, self.valid_message(), {'type': 'agent_settled'}])
        self.assertFalse(result['validArtifact'])

    def test_truncated_record_is_rejected(self):
        with self.assertRaisesRegex(ProbeFailure, 'Truncated JSONL'):
            self.child([], raw=b'{"type":"agent_settled"}')

    def test_non_object_record_is_rejected(self):
        with self.assertRaisesRegex(ProbeFailure, 'not an object'):
            self.child([], raw=b'[]\n')

    def test_record_limit_applies_to_complete_and_incomplete_records(self):
        for suffix in (b'\n', b''):
            with self.subTest(suffix=suffix), self.assertRaisesRegex(ProbeFailure, 'Oversized'):
                self.child([], raw=b'{"value":"' + b'x' * 100 + b'"}' + suffix,
                           max_record_bytes=64)

    def test_total_output_limit_includes_many_small_records(self):
        with self.assertRaisesRegex(ProbeFailure, 'output byte limit'):
            self.child([{'type': 'diagnostic'}] * 10, max_output_bytes=100)

    def test_stderr_is_separate_and_bounded(self):
        script = ('import sys; sys.stdin.readline(); '
                  'sys.stderr.buffer.write(b"x" * 10000); sys.stderr.flush()')
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaisesRegex(ProbeFailure, 'output byte limit'):
                run_child([sys.executable, '-c', script], root, max_output_bytes=128)

    def test_child_that_never_settles_is_killed_at_deadline(self):
        script = 'import sys,time; sys.stdin.readline(); time.sleep(30)'
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaisesRegex(ProbeFailure, 'process deadline'):
                run_child([sys.executable, '-c', script], root, timeout=.15)

    def test_nonzero_exit_after_settlement_still_fails(self):
        with self.assertRaisesRegex(ProbeFailure, 'status 9'):
            self.child([self.accepted(), self.valid_message(), {'type': 'agent_settled'}], status=9)

    def test_rejected_prompt_cannot_validate_artifact(self):
        response = self.accepted()
        response['success'] = False
        with self.assertRaisesRegex(ProbeFailure, 'not acknowledged'):
            self.child([response, self.valid_message(), {'type': 'agent_settled'}])

    def test_stderr_cannot_supply_protocol_or_artifact(self):
        records = [self.accepted(), self.valid_message(), {'type': 'agent_settled'}]
        script = ('import sys; sys.stdin.readline(); '
                  'sys.stderr.write("not JSON: diagnostics only\\n"); '
                  f'print({chr(10).join(json.dumps(r) for r in records)!r})')
        with tempfile.TemporaryDirectory() as root:
            result = run_child([sys.executable, '-c', script], root)
        self.assertTrue(result['validArtifact'])

    def test_queued_prompt_still_requires_generation_and_settlement(self):
        response = self.accepted()
        response['data']['disposition'] = 'queued'
        result = self.child([response, self.valid_message(), {'type': 'agent_settled'}])
        self.assertTrue(result['validArtifact'])

    def test_crlf_framing_preserves_valid_artifact(self):
        records = [self.accepted(), self.valid_message(), {'type': 'agent_settled'}]
        raw = ('\r\n'.join(json.dumps(record) for record in records) + '\r\n').encode()
        self.assertTrue(self.child([], raw=raw)['validArtifact'])

    def test_malformed_assistant_content_is_rejected(self):
        for content in ({}, [None], [{'type': 'text', 'text': 42}]):
            message = self.valid_message()
            message['message']['content'] = content
            with self.subTest(content=content), self.assertRaisesRegex(ProbeFailure, 'Malformed assistant'):
                self.child([self.accepted(), message, {'type': 'agent_settled'}])


if __name__ == '__main__':
    unittest.main()
