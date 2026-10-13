import copy
import json
from pathlib import Path
import tempfile
import unittest
from ai_review_report import build, digest, validate


class AIReviewReportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        evidence_root = self.root / 'evidence'
        evidence_root.mkdir()
        frames = []
        for i, pts in enumerate([8, 8.5, 9, 10]):
            path = evidence_root / f'{i}.png'
            path.write_bytes(b'Synthetic fingerprint fixture, not visual review evidence: ' + bytes([i]))
            frames.append(dict(path=path.name, sha256=digest(path), sourceTime=pts))
        sheet = evidence_root / 'sheet.jpg'
        sheet.write_bytes(b'Synthetic contact sheet fixture')
        self.bundle = dict(source={'filename': 'fixture.mp4', 'sha256': 's', 'duration': 20},
            modelSHA256='m', predictionsSHA256='p', events=[dict(id='one', time=10, direction='right',
            target='next_corner', diagnostics={'cue': 'advance_warning'})])
        self.bundle_path = self.root / 'bundle.json'
        self.bundle_path.write_text(json.dumps(self.bundle))
        self.review = dict(schemaVersion='racing-trainer-ai-review-v1', reviewer='Synthetic AI fixture',
            reviewSetID='fixture', reviewerType='ai', origin='ai_after_model_output', sawModelAnswers=True,
            humanApproved=False, trainingEligible=False, sourceSHA256='s', modelSHA256='m', predictionsSHA256='p',
            bundleSHA256=digest(self.bundle_path), evidenceManifest='evidence/manifest.json',
            method='Synthetic unit test, not a visual inspection.', scope='Unit test.', windowMeaning='Candidate only.',
            events=[dict(eventID='one', time=10, reviewed=True, confidence='medium', direction='right',
                target='next_corner', speedKmh=30, basicVerdict='correct', cueVerdict='needs_timing_review',
                proposedAction='uncertain', candidateWindow=None, observation='Synthetic fixture', followUp='Unit test only')])
        self.evidence = {k: self.review[k] for k in ['sourceSHA256', 'modelSHA256', 'predictionsSHA256', 'bundleSHA256']}
        self.evidence.update(schemaVersion='racing-trainer-ai-evidence-v1', events=[dict(eventID='one', time=10,
            frames=frames, contactSheet='sheet.jpg', contactSheetSHA256=digest(sheet))])

    def tearDown(self):
        self.temp.cleanup()

    def check(self, review=None, evidence=None):
        validate(review or self.review, self.bundle, evidence or self.evidence, self.root)

    def test_provenance_identity_and_duplicate_reviews_fail_closed(self):
        self.check()
        for key, value in [('humanApproved', True), ('trainingEligible', True), ('reviewerType', 'human'),
                           ('origin', 'human_after_model_output'), ('sourceSHA256', 'different')]:
            changed = copy.deepcopy(self.review); changed[key] = value
            with self.assertRaises(ValueError): self.check(review=changed)
        changed = copy.deepcopy(self.review); changed['events'].append(changed['events'][0])
        with self.assertRaisesRegex(ValueError, 'exactly one'): self.check(review=changed)

    def test_future_evidence_and_unsupported_timing_rejected(self):
        changed = copy.deepcopy(self.evidence); changed['events'][0]['frames'][-1]['sourceTime'] = 10.1
        with self.assertRaisesRegex(ValueError, 'Future'): self.check(evidence=changed)
        for window in [[9, 11], [7, 10], [10, 9], [float('nan'), 10], [9, 10]]:
            changed = copy.deepcopy(self.review); changed['events'][0]['candidateWindow'] = window
            with self.assertRaisesRegex(ValueError, 'Candidate window'): self.check(review=changed)

    def test_evidence_tampering_and_escaping_paths_rejected(self):
        changed = copy.deepcopy(self.evidence); changed['events'][0]['frames'][0]['sha256'] = 'changed'
        with self.assertRaisesRegex(ValueError, 'fingerprint'): self.check(evidence=changed)
        changed = copy.deepcopy(self.evidence); changed['events'][0]['frames'][0]['path'] = '../../elsewhere.png'
        with self.assertRaisesRegex(ValueError, 'escapes'): self.check(evidence=changed)

    def test_handoff_keeps_claude_blank_and_refuses_overwrite(self):
        review_path = self.root / 'review.json'
        review_path.write_text(json.dumps(self.review))
        (self.root / 'evidence/manifest.json').write_text(json.dumps(self.evidence))
        output = self.root / 'handoff'
        build(review_path, self.bundle_path, output)
        template = json.loads((output / 'claude.review.template.json').read_text())
        self.assertFalse(template['humanApproved'])
        self.assertFalse(template['trainingEligible'])
        self.assertFalse(template['events'][0]['reviewed'])
        self.assertIsNone(template['events'][0]['proposedAction'])
        before = digest(output / 'CLAUDE_HANDOFF.md')
        with self.assertRaises(FileExistsError): build(review_path, self.bundle_path, output)
        self.assertEqual(digest(output / 'CLAUDE_HANDOFF.md'), before)


if __name__ == '__main__':
    unittest.main()
