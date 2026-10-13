import copy
import unittest
import numpy as np
from benchmark import compare, confidence_bins, event_metrics
from temporal import FEATURES, TemporalNetwork, features
from train import reviewed_intervals


class PipelineTests(unittest.TestCase):
    def test_features_preserve_missingness(self):
        history = [{'time': 10 + index / 10, 'observations': {}, 'ages': {}} for index in range(20)]
        x = features(history)
        self.assertEqual(x.shape, (20, len(FEATURES)))
        self.assertTrue(np.isfinite(x).all()); self.assertEqual(x[0, 1], 0); self.assertEqual(x[0, 3], 15)

    def test_future_data_rejected(self):
        history = [{'time': 10 + index / 10, 'observations': {}, 'ages': {}} for index in range(20)]
        history[0]['observations']['speed'] = {'capturedAt': 10, 'completedAt': 10.1}
        with self.assertRaisesRegex(ValueError, 'Future'): features(history)

    def test_network_gradient_matches_finite_difference(self):
        model = TemporalNetwork()
        x = np.random.default_rng(2).normal(size=(3, 20, len(FEATURES))).astype(np.float32)
        y = np.array([0, 1, 2]); _, gradients = model.loss_gradients(x, y)
        for key, index in [('kernel', (1, 2, 3)), ('bias', (3,)), ('head', (3, 1)), ('head_bias', (2,))]:
            original = model.params[key][index]; epsilon = .005
            model.params[key][index] = original + epsilon; plus = model.loss_gradients(x, y)[0]
            model.params[key][index] = original - epsilon; minus = model.loss_gradients(x, y)[0]
            model.params[key][index] = original
            self.assertAlmostEqual(float(gradients[key][index]), (plus-minus)/(2*epsilon), delta=1e-4)

    def test_synthetic_training_reduces_loss_without_writing_weights(self):
        model = TemporalNetwork(); rng = np.random.default_rng(4)
        x = rng.normal(size=(8, 20, len(FEATURES))).astype(np.float32); y = np.arange(8) % 4
        before = model.loss_gradients(x, y)[0]; after = model.fit(x, y, epochs=30)
        self.assertLess(after, before)

    def fixture(self):
        bundle = {'schemaVersion': 'racing-trainer-review-v2', 'source': {'sha256': 's', 'duration': 100},
                  'modelSHA256': 'm', 'predictionsSHA256': 'p', 'events': [{'id': str(i), 'time': float(i)} for i in range(30)]}
        feedback = {'schemaVersion': 'racing-trainer-feedback-v2', 'sourceSHA256': 's', 'modelSHA256': 'm',
                    'predictionsSHA256': 'p', 'notes': []}
        return bundle, feedback

    def test_unreviewed_pilot_blocks_training(self):
        with self.assertRaisesRegex(ValueError, 'Human review'): reviewed_intervals(*self.fixture())

    def test_wrong_identity_rejected(self):
        bundle, feedback = self.fixture(); feedback['sourceSHA256'] = 'other'
        with self.assertRaisesRegex(ValueError, 'identity'): reviewed_intervals(bundle, feedback)

    def test_uncertain_human_reviews_are_not_training_labels(self):
        bundle, feedback = self.fixture()
        feedback['notes'] = [dict(category='slowdown_timing', eventID=e['id'], time=e['time'], reviewed=True,
            reviewer='Synthetic unit test', verdict='unclear', origin='human_after_model_output', sawModelAnswers=True,
            slowdown={'action': 'uncertain'}) for e in bundle['events']]
        self.assertEqual(reviewed_intervals(bundle, feedback), [])

    def test_named_completed_ai_reviews_cannot_become_training_labels(self):
        bundle, feedback = self.fixture()
        feedback['notes'] = [dict(category='slowdown_timing', eventID=e['id'], time=e['time'], reviewed=True,
            reviewer='Codex — AI preliminary review', verdict='correct', origin='ai_after_model_output',
            sawModelAnswers=True, slowdown={'action': 'no_cue', 'start': str(e['time']), 'end': str(e['time'])})
            for e in bundle['events']]
        with self.assertRaisesRegex(ValueError, 'provenance'):
            reviewed_intervals(bundle, feedback)

    def test_one_ai_note_still_blocks_an_otherwise_human_journal(self):
        bundle, feedback = self.fixture()
        feedback['notes'] = [dict(category='slowdown_timing', eventID=e['id'], time=e['time'], reviewed=True,
            reviewer='Human unit-test fixture', verdict='unclear', origin='human_after_model_output',
            sawModelAnswers=True, slowdown={'action': 'uncertain'}) for e in bundle['events']]
        feedback['notes'][-1]['origin'] = 'ai_after_model_output'
        feedback['notes'][-1]['reviewer'] = 'Claude — AI verification'
        with self.assertRaisesRegex(ValueError, 'provenance'):
            reviewed_intervals(bundle, feedback)

    def test_separate_ai_review_schema_is_not_a_training_journal(self):
        bundle, feedback = self.fixture()
        feedback['schemaVersion'] = 'racing-trainer-ai-review-v1'
        with self.assertRaisesRegex(ValueError, 'Version 2'):
            reviewed_intervals(bundle, feedback)

    def test_event_metrics_and_no_cue_false_alarms(self):
        references = [dict(start=10, end=12, action='brake'), dict(start=20, end=21, action='lift'),
                      dict(start=30, end=32, action='no_cue'), dict(start=40, end=42, action='advance_warning')]
        predictions = [dict(time=9, cue='brake'), dict(time=22, cue='lift'), dict(time=31, cue='brake')]
        result = event_metrics(predictions, references)
        self.assertEqual((result['early'], result['late'], result['missed'], result['falseCuesInReviewedWindows']), (1, 1, 1, 1))

    def test_benchmark_rejects_mismatched_timestamps(self):
        with self.assertRaisesRegex(ValueError, 'identical'):
            compare(dict(schema='modular-benchmark-v1', sourceSHA256='s', reviewer='fixture', references=[],
                         systems={'rules': [dict(time=1, cue='cannot_judge')], 'learned': [dict(time=2, cue='no_cue')]}))

    def test_confidence_bins_do_not_average_other_modules(self):
        bins = confidence_bins([dict(score=.9, correct=False), dict(score=.9, correct=True)])
        self.assertEqual(bins[-1]['observedErrorRate'], .5)
        self.assertIsNone(bins[0]['observedErrorRate'])


if __name__ == '__main__': unittest.main()
