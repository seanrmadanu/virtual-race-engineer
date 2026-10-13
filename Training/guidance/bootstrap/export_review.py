#!/usr/bin/env python3
"""Package completed replay outputs for the native Model Review window."""
import argparse
import hashlib
import json
from pathlib import Path


def export_review(predictions_path, manifest_path, output):
    if output.exists():
        raise ValueError("Refusing to overwrite an existing review package")
    prediction_bytes = predictions_path.read_bytes()
    manifest_bytes = manifest_path.read_bytes()
    replay = json.loads(prediction_bytes)
    manifest = json.loads(manifest_bytes)
    if (replay["schema_version"] != "bootstrap-temporal-softmax-v1"
            or manifest["schema_version"] != "bootstrap-batch-v1"
            or replay["batch_manifest_sha256"] != hashlib.sha256(manifest_bytes).hexdigest()
            or manifest["action_labels_enabled"] is not False):
        raise ValueError("Replay and manifest do not match")
    cases = manifest["cases"]
    rows = replay["predictions"]
    if len(cases) != len(rows) or len({r["event_id"] for r in rows}) != len(rows):
        raise ValueError("Missing or duplicate replay events")
    by_id = {r["event_id"]: r for r in rows}
    events = []
    for case in cases:
        row = by_id[case["event_id"]]
        if (row["decision_time_s"] != case["decision_time_s"]
                or row["source_group_id"] != case["source_group_id"]
                or row["source_group_id"] != "sha256-" + manifest["source"]["sha256"]
                or row["action"] != "disabled"):
            raise ValueError("Replay event identity mismatch or enabled action output")
        events.append({"id": row["event_id"], "time": row["decision_time_s"],
                       "direction": row["turn_direction"], "target": row["turn_target"],
                       "phase": row["corner_phase"], "reasons": row["suppression_reasons"]})
    source = manifest["source"]
    package = {
        "schemaVersion": "racing-trainer-review-v1",
        "title": source["filename"] + " · Model Review",
        "source": {"filename": source["filename"], "sha256": source["sha256"], "duration": source["duration_s"]},
        "modelSHA256": replay["model_sha256"],
        "predictionsSHA256": hashlib.sha256(prediction_bytes).hexdigest(),
        "events": events,
    }
    with output.open("x") as stream:
        json.dump(package, stream, indent=2, allow_nan=False)
        stream.write("\n")
    print(f"Ready: {output} ({len(events)} moments)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("predictions", type=Path)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    export_review(args.predictions, args.manifest, args.output)
