import json
import sys
import tempfile
import unittest

from analysis_probe import evaluate_grounding
from rpc_probe import ProbeFailure, actual_pi_local_probe, run_child


class GroundingTests(unittest.TestCase):
    def fixture_result(self):
        return {
            'summary': [{'text': 'The team chose SQLite for storage.', 'citations': ['u2']}],
            'actions': [{'text': 'Send release notes', 'owner': 'Olena', 'due': None, 'citations': ['u1']}],
            'decisions': [{'text': 'Use SQLite', 'citations': ['u2']}],
            'openItems': [{'text': 'Who will review accessibility?', 'citations': ['u3', 'u4']}],
        }

    def test_supported_fixture_passes(self):
        self.assertTrue(all(evaluate_grounding(self.fixture_result()).values()))

    def test_wrong_owner_invented_date_or_citation_fails(self):
        for key, value in [('owner', 'Mark'), ('due', 'Friday'), ('citations', ['u2'])]:
            result = self.fixture_result()
            result['actions'][0][key] = value
            with self.subTest(key=key):
                self.assertFalse(evaluate_grounding(result)['actionOwnerAndEvidence'])

    def test_unknown_citation_fails(self):
        result = self.fixture_result()
        result['summary'][0]['citations'] = ['u100']
        self.assertFalse(evaluate_grounding(result)['allCitationsExist'])

    def test_rejected_suggestion_does_not_become_outcome(self):
        result = self.fixture_result()
        result['decisions'].append({'text': 'Release on Friday', 'citations': ['u4']})
        self.assertFalse(evaluate_grounding(result)['rejectedFridayNotAnOutcome'])

    def test_malformed_outputs_fail_predictably(self):
        for result in (None, [], {}, {'summary': 'invalid'},
                       {k: [None] for k in ('summary', 'actions', 'decisions', 'openItems')}):
            with self.subTest(result=result):
                self.assertEqual(evaluate_grounding(result), {'schema': False})

    def test_cyrillic_output_is_not_claimed_english(self):
        result = self.fixture_result()
        result['summary'][0]['text'] = 'Вибрали SQLite'
        self.assertFalse(evaluate_grounding(result)['noCyrillicInGeneratedText'])

    def test_unassigned_question_cannot_be_assigned_work(self):
        result = self.fixture_result()
        result['openItems'] = []
        result['actions'].append({'text': 'Review accessibility', 'owner': 'Me',
                                  'due': None, 'citations': ['u3']})
        checks = evaluate_grounding(result)
        self.assertFalse(checks['unassignedQuestionRemainsOpen'])
        self.assertFalse(checks['actionOwnerAndEvidence'])


class LocalProviderTests(unittest.TestCase):
    def test_provider_rejects_remote_ambiguous_and_credential_urls_before_launch(self):
        for endpoint in ('https://example.com/v1', 'http://localhost:80/v1',
                         'http://user:secret@127.0.0.1/v1', 'http://127.0.0.1/v1?redirect=x',
                         'http://127.0.0.1/v1#x'):
            with self.subTest(endpoint=endpoint), self.assertRaisesRegex(ProbeFailure, 'loopback'):
                actual_pi_local_probe('must-never-launch', endpoint, 'synthetic')

    def test_configurable_prompt_and_expected_artifact_are_observed(self):
        expected = {'fixture': 'українська'}
        records = [{'type': 'response', 'id': 'probe-1', 'command': 'prompt', 'success': True},
                   {'type': 'message_end', 'message': {'role': 'assistant', 'content': [
                       {'type': 'text', 'text': json.dumps(expected)}]}},
                   {'type': 'agent_settled'}]
        script = ('import sys,json; p=json.loads(sys.stdin.readline()); '
                  'assert p["message"] == "custom synthetic prompt"; '
                  f'print({chr(10).join(json.dumps(r) for r in records)!r})')
        with tempfile.TemporaryDirectory() as root:
            result = run_child([sys.executable, '-c', script], root, prompt='custom synthetic prompt',
                               expected_artifact=expected)
        self.assertTrue(result['validArtifact'])
        self.assertEqual(result['artifact'], expected)

    def test_length_limited_final_message_is_not_valid_completion(self):
        records = [{'type': 'response', 'id': 'probe-1', 'command': 'prompt', 'success': True},
                   {'type': 'message_end', 'message': {'role': 'assistant', 'stopReason': 'length',
                       'content': [{'type': 'text', 'text': '{"probe":"synthetic"}'}]}},
                   {'type': 'agent_settled'}]
        script = ('import sys; sys.stdin.readline(); '
                  f'print({chr(10).join(json.dumps(r) for r in records)!r})')
        with tempfile.TemporaryDirectory() as root:
            result = run_child([sys.executable, '-c', script], root)
        self.assertFalse(result['validArtifact'])
        self.assertEqual(result['finalStopReason'], 'length')
