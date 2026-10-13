import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from calibration_report import prepare, summarize


class CalibrationReportTests(unittest.TestCase):
    def fixture(self):
        manifest = dict(schema='modular-shadow-session-v1', cuesEmitted=False, runID='fixture', status='closed',
                        configuration={}, samples=1)
        observation = dict(capturedAt=10, completedAt=10.01, sourceSessionID=1, state='uncertain', units='km/h',
                           value={'number': 100}, confidence=.9, failureReason='hud_profile_unconfirmed')
        sample = dict(type='sample', generation=1, source={'kind': 'syntheticTest', 'identifier': 'fixture'},
                      sourcePTS=5, receivedAt=10, completedAt=10.02, row=dict(time=10.02, observations={'speed': observation}, ages={'speed': .02}),
                      decision={'learnedLiveEnabled': False}, evidenceImages=[])
        return manifest, sample

    def testUncertainSpeedPreservedAndNoPhysicsInvented(self):
        manifest, sample = self.fixture(); report = summarize(manifest, [sample])
        self.assertEqual(report['series'][0]['speedState'], 'uncertain')
        self.assertFalse(report['calibrationEnabled']); self.assertIsNone(report['warningDelaySeconds'])

    def testFutureAndWrongSourceObservationsRejected(self):
        for key, value in [('completedAt', 11), ('sourceSessionID', 2)]:
            manifest, sample = self.fixture(); sample['row']['observations']['speed'][key] = value
            with self.assertRaises(ValueError): summarize(manifest, [sample])

    def testBackwardsPTSRequiresSeparateGeneration(self):
        manifest, sample = self.fixture(); manifest['samples'] = 2
        other = copy.deepcopy(sample); other['sourcePTS'] = 4
        with self.assertRaises(ValueError): summarize(manifest, [sample, other])

    def testEvidenceCannotEscapeSession(self):
        manifest, sample = self.fixture(); sample['evidenceImages'] = ['../elsewhere.png']
        sample['evidenceImageSHA256'] = {'../elsewhere.png': 'a'*64}
        with self.assertRaisesRegex(ValueError, 'Unsafe'): summarize(manifest, [sample])

    def testIncompleteRunAndFingerprintMismatchAreBlocked(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); manifest, sample = self.fixture()
            manifest['status'] = 'recording'
            (root/'manifest.json').write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, 'still recording'): prepare(root, root/'report')
            manifest.update(status='closed', traceSHA256='incorrect')
            (root/'manifest.json').write_text(json.dumps(manifest))
            (root/'observations.jsonl').write_text(json.dumps(sample)+'\n')
            with self.assertRaisesRegex(ValueError, 'fingerprint'): prepare(root, root/'report')
            self.assertFalse((root/'report').exists())

    def testChangedHUDEvidenceIsRejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); manifest, sample = self.fixture()
            sample['evidenceImages'] = ['speed.png']; sample['evidenceImageSHA256'] = {'speed.png': '0'*64}
            trace = json.dumps(sample)+'\n'; manifest['traceSHA256'] = hashlib.sha256(trace.encode()).hexdigest()
            (root/'observations.jsonl').write_text(trace); (root/'manifest.json').write_text(json.dumps(manifest))
            (root/'speed.png').write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'Image evidence'): prepare(root, root/'report')

    def testReportAndBlankMeasurementTemplateDoNotOverwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); manifest, sample = self.fixture()
            trace = json.dumps(sample)+'\n'; manifest['traceSHA256'] = hashlib.sha256(trace.encode()).hexdigest()
            (root/'observations.jsonl').write_text(trace)
            (root/'manifest.json').write_text(json.dumps(manifest))
            prepare(root, root/'report')
            draft = json.loads((root/'report/calibration-notes.template.json').read_text())
            self.assertEqual(draft['measurements'], []); self.assertFalse(draft['calibrationEnabled'])
            with self.assertRaisesRegex(ValueError, 'exists'): prepare(root, root/'report')


if __name__ == '__main__': unittest.main()
