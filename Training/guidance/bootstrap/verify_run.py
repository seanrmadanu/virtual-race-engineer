#!/usr/bin/env python3
"""Verify a frozen local run and describe its smoke replay without claiming accuracy."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import tempfile

import numpy as np

from pipeline import digest, load_batch, load_labels, predict, write_json


def verify(model_dir, batch, replay_path, output, previous_model=None):
    config = json.loads((model_dir / "model.json").read_text())
    manifest, _ = load_batch(batch)
    labels_path = batch / "labels.jsonl"
    labels = load_labels(labels_path, manifest)
    if digest(batch / "manifest.json") != config["training_manifest_sha256"] or digest(labels_path) != config["labels_sha256"]:
        raise ValueError("Training provenance mismatch")
    if digest(model_dir / "weights.npz") != config["weights_sha256"]:
        raise ValueError("Checkpoint checksum mismatch")
    if digest(Path(__file__).with_name("pipeline.py")) != config["training_code_sha256"]:
        raise ValueError("Training code changed after checkpoint was frozen")
    if digest(Path(__file__).with_name("prepare.swift")) != config["preparation_code_sha256"]:
        raise ValueError("Preprocessing code changed after checkpoint was frozen")
    replay = json.loads(replay_path.read_text())
    if (replay["model_sha256"] != digest(model_dir / "model.json") or not replay["training_source_reused"]
            or replay["batch_manifest_sha256"] != digest(batch / "manifest.json")):
        raise ValueError("Smoke replay identity mismatch")
    rows = replay["predictions"]
    if len(rows) != len(labels) or len({r["event_id"] for r in rows}) != len(rows):
        raise ValueError("Smoke replay count/identity mismatch")
    by_id = {r["event_id"]: r for r in labels}
    if set(by_id) != {r["event_id"] for r in rows}:
        raise ValueError("Smoke replay cases differ")
    if any(r["action"] != "disabled" or r["hud_speed_displayed"] is not None for r in rows):
        raise ValueError("Unexpected action or speed output")
    with tempfile.TemporaryDirectory(prefix="guidance-source-guard-") as scratch:
        try:
            predict(model_dir, batch, Path(scratch) / "must-not-exist")
        except ValueError as exc:
            if "Training source cannot count as a new test" not in str(exc):
                raise
        else:
            raise ValueError("Training-source guard did not reject")
        if (Path(scratch) / "must-not-exist").exists():
            raise ValueError("Rejected test wrote output")
    parity = None
    if previous_model:
        with np.load(model_dir / "weights.npz", allow_pickle=False) as current, np.load(previous_model / "weights.npz", allow_pickle=False) as old:
            parity = set(current.files) == set(old.files) and all(np.array_equal(current[key], old[key]) for key in current.files)
        if not parity:
            raise ValueError("Expected packaging-only refit to preserve numeric weights")
    report = {"verified_at_utc": datetime.now(timezone.utc).isoformat(),
              "model_sha256": digest(model_dir / "model.json"), "source_hash_guard_passed": True,
              "frame_feature_code_label_hashes_passed": True, "checkpoint_numeric_parity_with_initial_run": parity,
              "smoke_prediction_count": len(rows), "all_actions_disabled": True,
              "excluded_window_corner_proposals": sum(r["turn_direction"] != "unknown" and by_id[r["event_id"]]["turn_direction"] == "unknown" for r in rows),
              "excluded_windows": sum(r["turn_direction"] == "unknown" for r in labels),
              "independent_test_recordings": 0, "human_accuracy": None, "live_integration": False,
              "release_status": "offline_experimental_testing_only",
              "limitation": "Unknown-window proposals are a known rejection gap, not evidence of correctness or calibrated confidence."}
    write_json(output, report)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model", type=Path)
    parser.add_argument("batch", type=Path)
    parser.add_argument("replay", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--previous-model", type=Path)
    args = parser.parse_args()
    verify(args.model, args.batch, args.replay, args.output, args.previous_model)
