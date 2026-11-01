import math
import unittest
from retrieval_probe import score_rankings


class RetrievalMetricsTests(unittest.TestCase):
    def test_ranks_metrics_ties_and_unanswerable_are_explicit(self):
        result = score_rankings([{'id': 'b'}, {'id': 'a'}, {'id': 'c'}],
                                [{'text': 'one', 'relevant': 'a'}, {'text': 'two', 'relevant': 'b'},
                                 {'text': 'unknown', 'relevant': None}],
                                [[.5, .5, 0], [.2, .8, .1], [.9, .1, .2]])
        self.assertEqual(result['recallAt1'], .5)
        self.assertEqual(result['recallAt3'], 1)
        self.assertEqual(result['meanReciprocalRank'], .75)
        self.assertEqual(result['results'][0]['ranking'][0]['id'], 'a')
        self.assertIsNone(result['results'][2]['rank'])
        self.assertEqual(result['unanswerableQueries'], 1)

    def test_empty_answerable_set_has_no_accuracy_claim(self):
        result = score_rankings([{'id': 'a'}], [{'text': 'unknown', 'relevant': None}], [[.8]])
        self.assertIsNone(result['recallAt1'])

    def test_invalid_scores_and_labels_fail(self):
        for passages, queries, scores in [
            ([{'id': 'a'}, {'id': 'a'}], [], []),
            ([{'id': 'a'}], [{'text': 'x', 'relevant': 'missing'}], [[0]]),
            ([{'id': 'a'}], [{'text': 'x', 'relevant': 'a'}], [[math.nan]]),
            ([{'id': 'a'}], [{'text': 'x', 'relevant': 'a'}], [[]]),
            ([{'id': 'a'}], [{'text': 'x', 'relevant': 'a'}], [])]:
            with self.subTest(scores=scores), self.assertRaises(ValueError):
                score_rankings(passages, queries, scores)
