"""Synthetic contract/solver tests. These do not measure gameplay accuracy."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import numpy as np
from PIL import Image

import pipeline as p


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="guidance-bootstrap-test-")
        self.root = Path(self.temp.name)
        self.batch = self.root / "batch"
        (self.batch / "frames").mkdir(parents=True)
        (self.batch / "features").mkdir()
        encoder = {"name": "apple-vision-featureprint", "revision": 2, "elements_per_view": 768,
                   "view_names": ["road", "minimap"], "crop_xywh": [[384, 344, 1152, 576], [1536, 688, 384, 352]],
                   "crop_and_scale": "scaleFit", "os": "synthetic-test", "frame_count": 5, "nominal_hz": 2,
                   "dtype": "little-endian-float32", "mask_top_left_xywh": [0, 0, 520, 344],
                   "jpeg_quality": .97, "profile": "motorfest-1080p-reference-v1"}
        self.manifest = {"schema_version": "bootstrap-batch-v1", "action_labels_enabled": False,
                         "source": {"sha256": "a" * 64}, "encoder": encoder, "cases": []}
        group = "sha256-" + "a" * 64
        for index, decision in enumerate([10, 15], 1):
            frames = []
            for j in range(5):
                name = f"event-{index:04d}-f{j + 1}"
                path = self.batch / f"frames/{name}.jpg"
                Image.new("RGB", (1920, 1080), "black").save(path)
                requested = decision - 2 + j * .5
                frames.append({"frame_id": name, "path": str(path.relative_to(self.batch)),
                               "sha256": p.digest(path), "requested_time_s": requested, "source_time_s": requested - .005})
            feature_path = self.batch / f"features/event-{index:04d}.f32"
            np.full((5, 2, 768), index * .1, dtype="<f4").tofile(feature_path)
            self.manifest["cases"].append({"event_id": f"event-{index:04d}", "source_group_id": group,
                "recording_id": group, "decision_time_s": decision, "input_interval_s": [decision - 2.1, decision],
                "frames": frames, "teacher_frame_ids": [frames[j]["frame_id"] for j in (0, 2, 4)],
                "features_path": str(feature_path.relative_to(self.batch)), "features_sha256": p.digest(feature_path),
                "encoding_seconds": .01})
        self.save_manifest()

    def tearDown(self):
        self.temp.cleanup()

    def save_manifest(self):
        (self.batch / "manifest.json").write_text(json.dumps(self.manifest))

    def label_rows(self, human=False):
        mh = hashlib.sha256(json.dumps(self.manifest, sort_keys=True).encode()).hexdigest()
        rows = []
        for c in self.manifest["cases"]:
            rows.append({"event_id": c["event_id"], "source_group_id": c["source_group_id"], "manifest_hash": mh,
                         "origin": "independent_human" if human else "assistant_proposal", "annotator": "synthetic-test",
                         "review_status": "reviewed" if human else "unreviewed", "saw_model_answers": False,
                         "actions_enabled": False, "reason": "Synthetic contract test, not real data",
                         "turn_direction": "left", "turn_target": "next_corner", "corner_phase": "approach",
                         "evidence": {f: c["teacher_frame_ids"] for f in p.FIELDS}})
        return rows

    def save_labels(self, rows):
        path = self.root / "labels.jsonl"
        path.write_text("".join(json.dumps(r) + "\n" for r in rows))
        return path

    def model(self, same_source=False):
        directory = self.root / "model"
        directory.mkdir()
        arrays = {"mean": np.zeros(4608), "scale": np.ones(4608), "corner_w": np.zeros((4608, 2)),
                  "corner_b": np.array([1., 0.]), "phase_w": np.zeros((4608, 2)), "phase_b": np.array([1., 0.])}
        np.savez_compressed(directory / "weights.npz", **arrays)
        config = {"schema_version": p.SCHEMA, "action_outputs_enabled": False,
                  "encoder": self.manifest["encoder"], "feature_count": 4608,
                  "heads": {"corner": {"classes": ["left|next_corner", "right|next_corner"]},
                            "phase": {"classes": ["approach", "entry"]}},
                  "proposal_threshold": .65, "training_sources": ["a" * 64 if same_source else "b" * 64],
                  "weights_sha256": p.digest(directory / "weights.npz")}
        p.write_json(directory / "model.json", config)
        return directory

    def test_valid_batch(self):
        _, x = p.load_batch(self.batch)
        self.assertEqual(x.shape, (2, 4608))

    def test_temporal_order_matters(self):
        x = np.arange(5 * 2 * 768).reshape(5, 2, 768)
        feature = p.temporal_features(x)
        np.testing.assert_equal(feature[:1536], x[-1].ravel())
        np.testing.assert_equal(feature[3072:], (x[-1] - x[0]).ravel())
        self.assertFalse(np.array_equal(feature, p.temporal_features(x[::-1])))

    def test_future_frame_rejected(self):
        self.manifest["cases"][0]["frames"][-1]["source_time_s"] = 10.1
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, "Future"):
            p.load_batch(self.batch)

    def test_duplicate_pts_rejected(self):
        frames = self.manifest["cases"][0]["frames"]
        frames[1]["source_time_s"] = frames[0]["source_time_s"]
        self.save_manifest()
        with self.assertRaises(ValueError): p.load_batch(self.batch)

    def test_gap_rejected(self):
        self.manifest["cases"][0]["frames"][2]["source_time_s"] -= .2
        self.save_manifest()
        with self.assertRaises(ValueError): p.load_batch(self.batch)

    def test_source_mismatch(self):
        self.manifest["cases"][0]["source_group_id"] = "wrong"
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, "Source"): p.load_batch(self.batch)

    def test_outside_path(self):
        self.manifest["cases"][0]["frames"][0]["path"] = "../outside.jpg"
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, "escapes"): p.load_batch(self.batch)

    def test_hash_corruption(self):
        path = self.batch / self.manifest["cases"][0]["features_path"]
        path.write_bytes(b"corrupt")
        with self.assertRaisesRegex(ValueError, "hash"): p.load_batch(self.batch)

    def test_nonfinite_features(self):
        case = self.manifest["cases"][0]
        path = self.batch / case["features_path"]
        np.full((5, 2, 768), np.nan, dtype="<f4").tofile(path)
        case["features_sha256"] = p.digest(path)
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, "Malformed"): p.load_batch(self.batch)

    def test_mask_required(self):
        frame = self.manifest["cases"][0]["frames"][0]
        path = self.batch / frame["path"]
        Image.new("RGB", (1920, 1080), "white").save(path)
        frame["sha256"] = p.digest(path)
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, "mask"): p.load_batch(self.batch)

    def test_recipe_change(self):
        self.manifest["encoder"]["crop_xywh"][0][0] = 0
        self.save_manifest()
        with self.assertRaises(ValueError): p.load_batch(self.batch)

    def test_teacher_cannot_reference_unseen_frame(self):
        rows = self.label_rows()
        rows[0]["evidence"]["corner_phase"] = ["event-0001-f2"]
        with self.assertRaisesRegex(ValueError, "unseen"):
            p.load_labels(self.save_labels(rows), self.manifest)

    def test_unknowns_allowed_without_evidence(self):
        rows = self.label_rows()
        for field in p.FIELDS:
            rows[0][field] = "unknown"
            rows[0]["evidence"][field] = []
        self.assertEqual(len(p.load_labels(self.save_labels(rows), self.manifest)), 2)

    def test_ai_cannot_certify_human_review(self):
        rows = self.label_rows()
        rows[0]["review_status"] = "reviewed"
        with self.assertRaisesRegex(ValueError, "certify"):
            p.load_labels(self.save_labels(rows), self.manifest)

    def test_blind_test_requires_human_and_no_answers(self):
        with self.assertRaises(ValueError):
            p.load_labels(self.save_labels(self.label_rows()), self.manifest, independent=True)
        rows = self.label_rows(human=True)
        rows[0]["saw_model_answers"] = True
        with self.assertRaises(ValueError):
            p.load_labels(self.save_labels(rows), self.manifest, independent=True)

    def test_inconsistent_phase(self):
        rows = self.label_rows()
        rows[0]["corner_phase"] = "entry"
        with self.assertRaisesRegex(ValueError, "current corner"):
            p.load_labels(self.save_labels(rows), self.manifest)

    def test_straight_pair_consistency(self):
        rows = self.label_rows()
        rows[0]["turn_direction"] = "straight"
        with self.assertRaisesRegex(ValueError, "straight"):
            p.load_labels(self.save_labels(rows), self.manifest)

    def test_manifest_change_invalidates_labels(self):
        path = self.save_labels(self.label_rows())
        self.manifest["source"]["filename"] = "changed"
        with self.assertRaisesRegex(ValueError, "different manifest"):
            p.load_labels(path, self.manifest)

    def test_duplicate_labels(self):
        rows = self.label_rows()
        rows.append(copy.deepcopy(rows[0]))
        with self.assertRaises(ValueError): p.load_labels(self.save_labels(rows), self.manifest)

    def test_explicit_weak_label_opt_in(self):
        with self.assertRaisesRegex(ValueError, "allow-unreviewed"):
            p.train(self.batch, self.root / "missing", self.root / "out", False)

    def test_solver_learns_and_is_finite(self):
        x = np.array([[-2., 0.], [-1., .1], [1., -.1], [2., 0.]])
        labels = ["left", "left", "right", "right"]
        w, b, classes, losses = p.fit_head(x, labels, epochs=300)
        probability = p.softmax(x @ w + b)
        self.assertTrue(np.isfinite(probability).all())
        self.assertLess(losses[-1]["regularized_loss"], losses[0]["regularized_loss"])
        self.assertEqual([classes[i] for i in probability.argmax(axis=1)], labels)

    def test_training_source_not_test(self):
        with self.assertRaisesRegex(ValueError, "Training source"):
            p.predict(self.model(same_source=True), self.batch, self.root / "predictions")

    def test_prediction_roundtrip_and_evaluation(self):
        out = self.root / "predictions"
        p.predict(self.model(), self.batch, out)
        rows = json.loads((out / "predictions.json").read_text())["predictions"]
        self.assertTrue(all(r["action"] == "disabled" for r in rows))
        self.assertTrue(all(r["turn_direction"] == "left" for r in rows))
        report = self.root / "report.json"
        p.evaluate(self.batch, self.save_labels(self.label_rows(human=True)), out / "predictions.json", report)
        self.assertEqual(json.loads(report.read_text())["fields"]["turn_direction"]["correct"], 2)
        with self.assertRaises(ValueError): p.predict(self.root / "model", self.batch, out)

    def test_contradictory_phase_suppressed(self):
        model = self.model()
        config = json.loads((model / "model.json").read_text())
        config["heads"]["phase"]["classes"] = ["entry", "approach"]
        (model / "model.json").write_text(json.dumps(config))
        out = self.root / "predictions"
        p.predict(model, self.batch, out)
        rows = json.loads((out / "predictions.json").read_text())["predictions"]
        self.assertTrue(all(r["corner_phase"] == "unknown" for r in rows))
        self.assertTrue(all("inconsistent_phase_suppressed" in r["suppression_reasons"] for r in rows))

    def test_corrupt_checkpoint_rejected(self):
        model = self.model()
        (model / "weights.npz").write_bytes(b"not a checkpoint")
        with self.assertRaisesRegex(ValueError, "weight hash"):
            p.predict(model, self.batch, self.root / "predictions")

    def test_unreviewed_reference_not_scored(self):
        rows = self.label_rows(human=True)
        rows[0]["review_status"] = "pending"
        with self.assertRaises(ValueError):
            p.load_labels(self.save_labels(rows), self.manifest, independent=True)

    def test_invalid_softmax_dimensions(self):
        model = self.model()
        config = json.loads((model / "model.json").read_text())
        config["feature_count"] = 1
        (model / "model.json").write_text(json.dumps(config))
        with self.assertRaisesRegex(ValueError, "dimension"):
            p.predict(model, self.batch, self.root / "predictions")


if __name__ == "__main__":
    unittest.main()
