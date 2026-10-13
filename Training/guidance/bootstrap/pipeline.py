#!/usr/bin/env python3
"""Train a local, provisional temporal perception classifier; never an action policy.

The encoder is frozen Apple Vision revision 2. Trainable softmax heads use
latest, mean, and last-minus-first road/minimap embeddings. Only NumPy + Pillow
are needed. No network calls, executable checkpoints, or implicit data splits.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import time

import numpy as np
from PIL import Image, ImageDraw

SCHEMA = "bootstrap-temporal-softmax-v1"
FIELDS = ("turn_direction", "turn_target", "corner_phase")
VOCAB = {
    "turn_direction": {"left", "right", "straight", "unknown"},
    "turn_target": {"current_corner", "next_corner", "straight_segment", "unknown"},
    "corner_phase": {"straight", "approach", "entry", "apex_region", "exit", "transition", "unknown"},
}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value) -> None:
    with path.open("x") as stream:
        json.dump(value, stream, indent=2, sort_keys=True, allow_nan=False)
        stream.write("\n")


def safe_path(root: Path, relative: str) -> Path:
    path = (root / relative).resolve()
    if Path(relative).is_absolute() or not path.is_relative_to(root.resolve()):
        raise ValueError("Path escapes batch")
    return path


def load_batch(root: Path):
    manifest = json.loads((root / "manifest.json").read_text())
    if manifest.get("schema_version") != "bootstrap-batch-v1" or manifest.get("action_labels_enabled") is not False:
        raise ValueError("Unsupported batch or enabled actions")
    encoder = manifest["encoder"]
    if (encoder["revision"], encoder["frame_count"], encoder["elements_per_view"]) != (2, 5, 768):
        raise ValueError("Encoder shape mismatch")
    if (encoder["name"] != "apple-vision-featureprint" or encoder["dtype"] != "little-endian-float32"
            or encoder.get("crop_xywh") != [[384, 344, 1152, 576], [1536, 688, 384, 352]]
            or encoder.get("mask_top_left_xywh") != [0, 0, 520, 344]
            or encoder.get("view_names") != ["road", "minimap"]
            or encoder.get("crop_and_scale") != "scaleFit" or encoder.get("nominal_hz") != 2
            or encoder.get("profile") != "motorfest-1080p-reference-v1"
            or not encoder.get("os") or encoder.get("jpeg_quality") != .97):
        raise ValueError("Encoder type mismatch")
    cases = manifest["cases"]
    if not cases or len({c["event_id"] for c in cases}) != len(cases):
        raise ValueError("Empty or duplicate cases")
    expected_group = "sha256-" + manifest["source"]["sha256"]
    all_ids, seen_pts, vectors = set(), set(), []
    for case in cases:
        if case["source_group_id"] != expected_group or case["recording_id"] != expected_group:
            raise ValueError("Source identity mismatch")
        frames = case["frames"]
        pts = np.array([f["source_time_s"] for f in frames], dtype=float)
        requested = np.array([f["requested_time_s"] for f in frames], dtype=float)
        begin, end = case["input_interval_s"]
        decision = case["decision_time_s"]
        if not np.isfinite([begin, end, decision]).all() or abs(end - decision) > 1e-6 or abs(end - begin - 2.1) > 1e-5:
            raise ValueError("Invalid input interval")
        if (len(frames) != 5 or not np.isfinite(pts).all() or not np.isfinite(requested).all()
                or pts[0] < begin or pts[-1] > decision or np.any(np.diff(pts) <= 0)
                or np.any(pts > requested + 1e-6) or np.any(requested - pts > .05)
                or not np.allclose(requested, decision - 2 + np.arange(5) * .5)
                or np.any(np.abs(np.diff(pts) - .5) > .05)):
            raise ValueError("Future, duplicated, stale, or gapped frames")
        frame_ids = {f["frame_id"] for f in frames}
        if len(frame_ids) != 5 or frame_ids & all_ids or any(float(p) in seen_pts for p in pts):
            raise ValueError("Reused frame identity or overlapping sampled frames")
        all_ids |= frame_ids
        seen_pts.update(float(p) for p in pts)
        if case["teacher_frame_ids"] != [frames[i]["frame_id"] for i in (0, 2, 4)]:
            raise ValueError("Teacher evidence selection mismatch")
        for frame in frames:
            path = safe_path(root, frame["path"])
            if digest(path) != frame["sha256"]:
                raise ValueError("Frame hash mismatch")
            with Image.open(path) as im:
                if im.size != (1920, 1080):
                    raise ValueError("Unexpected frame dimensions")
                # Ignore JPEG ringing at the burned-mask boundary.
                if np.asarray(im.convert("RGB").crop((0, 0, 512, 336))).max() > 5:
                    raise ValueError("Wheel-camera mask missing")
        path = safe_path(root, case["features_path"])
        if digest(path) != case["features_sha256"]:
            raise ValueError("Feature hash mismatch")
        encoded = np.frombuffer(path.read_bytes(), dtype="<f4")
        if encoded.size != 5 * 2 * 768 or not np.isfinite(encoded).all():
            raise ValueError("Malformed features")
        vectors.append(temporal_features(encoded.reshape(5, 2, 768)))
    return manifest, np.array(vectors, dtype=np.float64)


def temporal_features(sequence: np.ndarray) -> np.ndarray:
    if sequence.shape != (5, 2, 768) or not np.isfinite(sequence).all():
        raise ValueError("Expected five ordered two-view feature vectors")
    return np.concatenate([sequence[-1].ravel(), sequence.mean(axis=0).ravel(),
                           (sequence[-1] - sequence[0]).ravel()])


def load_labels(path: Path, manifest: dict, *, independent=False):
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    by_id = {r["event_id"]: r for r in rows}
    cases = {c["event_id"]: c for c in manifest["cases"]}
    if len(by_id) != len(rows) or set(by_id) != set(cases):
        raise ValueError("Labels must cover every case exactly once")
    manifest_hash = hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest()
    for key, row in by_id.items():
        case = cases[key]
        if row.get("manifest_hash") != manifest_hash:
            raise ValueError("Labels belong to a different manifest")
        if row.get("source_group_id") != case["source_group_id"]:
            raise ValueError("Label source mismatch")
        if row.get("origin") not in {"assistant_proposal", "independent_human"}:
            raise ValueError("Missing label provenance")
        if row["origin"] == "assistant_proposal" and row.get("review_status") != "unreviewed":
            raise ValueError("AI proposals cannot certify themselves")
        if independent and (row["origin"] != "independent_human" or row.get("saw_model_answers") is not False
                            or row.get("review_status") != "reviewed"):
            raise ValueError("Evaluation requires independent human references without model answers")
        if not row.get("annotator") or not row.get("reason") or row.get("actions_enabled") is not False:
            raise ValueError("Missing provenance/reason or enabled action labels")
        for field, choices in VOCAB.items():
            if row[field] not in choices:
                raise ValueError("Invalid observation enum")
            ids = row["evidence"][field]
            if len(ids) != len(set(ids)) or not set(ids).issubset(case["teacher_frame_ids"]):
                raise ValueError("Invented or unseen evidence frame")
            if row[field] != "unknown" and not ids:
                raise ValueError("Known observation without evidence")
        d, t, p = (row[f] for f in FIELDS)
        if (d == "straight") != (t == "straight_segment"):
            raise ValueError("Inconsistent straight direction/target")
        if p == "straight" and d != "straight":
            raise ValueError("Straight phase with an established corner")
        if p == "approach" and t != "next_corner":
            raise ValueError("Approach requires next corner")
        if p in {"entry", "apex_region", "exit"} and t != "current_corner":
            raise ValueError("Corner phase requires current corner")
    return [by_id[c["event_id"]] for c in manifest["cases"]]


def softmax(logits):
    logits = logits - logits.max(axis=1, keepdims=True)
    exp = np.exp(logits)
    return exp / exp.sum(axis=1, keepdims=True)


def fit_head(x, labels, *, epochs=600, regularization=.001):
    classes = sorted(set(labels))
    y = np.array([classes.index(label) for label in labels])
    counts = np.bincount(y, minlength=len(classes))
    sample_weight = 1 / counts[y]
    sample_weight /= sample_weight.sum()
    w = np.zeros((x.shape[1], len(classes)))
    b = np.zeros(len(classes))
    mw, vw, mb, vb = np.zeros_like(w), np.zeros_like(w), np.zeros_like(b), np.zeros_like(b)
    losses = []
    for epoch in range(1, epochs + 1):
        probability = softmax(x @ w + b)
        loss = float(-(np.log(np.maximum(probability[np.arange(len(y)), y], 1e-12)) * sample_weight).sum()
                     + .5 * regularization * np.square(w).sum())
        if not np.isfinite(loss):
            raise ValueError("Nonfinite training loss")
        if epoch in {1, 100, 300, epochs}:
            losses.append({"epoch": epoch, "regularized_loss": loss})
        gradient = probability.copy()
        gradient[np.arange(len(y)), y] -= 1
        gradient *= sample_weight[:, None]
        gw = x.T @ gradient + regularization * w
        gb = gradient.sum(axis=0)
        mw = .9 * mw + .1 * gw
        vw = .999 * vw + .001 * gw * gw
        mb = .9 * mb + .1 * gb
        vb = .999 * vb + .001 * gb * gb
        rate = .01 * np.sqrt(1 - .999 ** epoch) / (1 - .9 ** epoch)
        w -= rate * mw / (np.sqrt(vw) + 1e-8)
        b -= rate * mb / (np.sqrt(vb) + 1e-8)
    return w, b, classes, losses


def training_metrics(labels, probability, classes):
    predicted = np.argmax(probability, axis=1)
    truth = np.array([classes.index(v) for v in labels])
    confusion = np.zeros((len(classes), len(classes)), int)
    for actual, proposed in zip(truth, predicted):
        confusion[actual, proposed] += 1
    return {"kind": "resubstitution_agreement_with_unreviewed_AI_NOT_test_accuracy",
            "n": len(labels), "agreement": float(np.mean(truth == predicted)),
            "classes": classes, "confusion_rows_reference_cols_prediction": confusion.tolist()}


def train(batch, labels_path, output, allow_unreviewed):
    if not allow_unreviewed:
        raise ValueError("Pass --allow-unreviewed-ai to explicitly opt into experimental weak supervision")
    manifest, x = load_batch(batch)
    labels = load_labels(labels_path, manifest)
    if output.exists():
        raise ValueError("Refusing to overwrite a model run")
    eligible = np.array([r["turn_direction"] != "unknown" and r["turn_target"] != "unknown" for r in labels])
    if not eligible.any():
        raise ValueError("No supported training windows")
    # Unsupported/cockpit/cinematic windows never influence preprocessing statistics.
    mean = x[eligible].mean(axis=0)
    scale = np.maximum(x[eligible].std(axis=0), .01)
    # Stable scaling preserves layout dimensions and limits rare feature outliers.
    normalized = np.clip((x - mean) / scale, -5, 5) / np.sqrt(x.shape[1])
    arrays = {"mean": mean, "scale": scale}
    heads, metrics = {}, {}
    before = time.perf_counter()
    candidates = {
        "corner": [f'{r["turn_direction"]}|{r["turn_target"]}'
                   if r["turn_direction"] != "unknown" and r["turn_target"] != "unknown" else "unknown" for r in labels],
        "phase": [r["corner_phase"] for r in labels],
    }
    exclusions = {}
    for head, values in candidates.items():
        counts = Counter(v for v in values if v != "unknown")
        supported = {v for v, count in counts.items() if count >= 5}
        keep = np.array([v in supported for v in values])
        exclusions[head] = {"unknown": values.count("unknown"), "class_counts": dict(counts),
                            "rare_classes_excluded": sorted(set(counts) - supported)}
        if len(supported) < 2 or int(keep.sum()) < 20:
            exclusions[head]["disabled_reason"] = "Need at least two classes with five cases each and twenty supported cases"
            continue
        selected = [v for v, take in zip(values, keep) if take]
        w, b, classes, losses = fit_head(normalized[keep], selected)
        arrays[head + "_w"], arrays[head + "_b"] = w, b
        heads[head] = {"classes": classes, "loss_history": losses}
        metrics[head] = training_metrics(selected, softmax(normalized[keep] @ w + b), classes)
    if "corner" not in heads:
        raise ValueError("Insufficient label coverage to train even the corner head")
    config = {"schema_version": SCHEMA, "status": "experimental_unreviewed_AI_supervision",
              "encoder": manifest["encoder"], "pooling": "latest_mean_last-minus-first",
              "heads": heads, "excluded_labels": exclusions, "initialization": "deterministic_zeros", "epochs": 600,
              "l2_regularization": .001, "minimum_class_count": 5,
              "feature_count": x.shape[1], "sampled_window_count": len(labels),
              "training_event_count": int(eligible.sum()), "excluded_window_count": int((~eligible).sum()),
              "training_sources": [manifest["source"]["sha256"]],
              "training_manifest_sha256": digest(batch / "manifest.json"), "labels_sha256": digest(labels_path),
              "action_outputs_enabled": False, "speed_head_trained": False,
              "human_reviewed_training_labels": sum(r["origin"] == "independent_human" for r in labels),
              "independent_test_recordings": 0, "live_integration": False,
              "proposal_threshold": .65, "threshold_calibrated": False,
              "training_seconds": time.perf_counter() - before,
              "numpy_version": np.__version__,
              "training_code_sha256": digest(Path(__file__)),
              "preparation_code_sha256": digest(Path(__file__).with_name("prepare.swift")),
              "limitations": ["One source recording; no generalization measurement.",
                              "Teacher labels are provisional, not human ground truth.",
                              "Unknown and rare labels are excluded from their respective head losses.",
                              "Scores are uncalibrated; threshold is not a reliability guarantee.",
                              "No learned braking, throttle, target speed, steering angle, or traffic clearance.",
                              "Source hash checks cannot detect re-encoded duplicates; group these manually."]}
    output.mkdir(parents=True)
    np.savez_compressed(output / "weights.npz", **arrays)
    config["weights_sha256"] = digest(output / "weights.npz")
    write_json(output / "model.json", config)
    write_json(output / "training_report.json", {"model": config, "training_only_metrics": metrics,
               "encoder_seconds_per_frame": float(sum(c["encoding_seconds"] for c in manifest["cases"]) / (5 * len(labels))),
               "not_measured": ["independent correctness", "generalization", "live end-to-end latency", "coaching quality"]})
    # No pickle: loading this artifact cannot execute serialized Python code.
    loaded = np.load(output / "weights.npz", allow_pickle=False)
    for key, value in arrays.items():
        if not np.array_equal(value, loaded[key]):
            raise ValueError("Checkpoint roundtrip mismatch")
    print(json.dumps({"output": str(output), "trained_heads": list(heads), "training_events": int(eligible.sum()),
                      "independent_test_recordings": 0, "training_only_metrics": metrics}, indent=2))


def predict(model_dir, batch, output, allow_training_source=False):
    if output.exists():
        raise ValueError("Refusing to overwrite predictions")
    config = json.loads((model_dir / "model.json").read_text())
    if config.get("schema_version") != SCHEMA or config.get("action_outputs_enabled") is not False:
        raise ValueError("Unsupported model contract")
    if digest(model_dir / "weights.npz") != config["weights_sha256"]:
        raise ValueError("Model weight hash mismatch")
    manifest, x = load_batch(batch)
    if manifest["encoder"] != config["encoder"]:
        raise ValueError("Encoder/preprocessing/OS mismatch; re-qualify or re-encode with matching version")
    repeated = manifest["source"]["sha256"] in config["training_sources"]
    if repeated and not allow_training_source:
        raise ValueError("Training source cannot count as a new test; use --allow-training-source for smoke checks only")
    arrays = np.load(model_dir / "weights.npz", allow_pickle=False)
    if x.shape[1] != config["feature_count"] or arrays["mean"].shape != (x.shape[1],) or arrays["scale"].shape != (x.shape[1],):
        raise ValueError("Model feature dimension mismatch")
    if (not all(np.isfinite(arrays[key]).all() for key in arrays.files) or np.any(arrays["scale"] <= 0)
            or not np.isfinite(config["proposal_threshold"]) or not 0 <= config["proposal_threshold"] <= 1):
        raise ValueError("Invalid model numeric values")
    if "corner" not in config["heads"] or not set(config["heads"]).issubset({"corner", "phase"}):
        raise ValueError("Invalid model head set")
    valid_corner = {f'{d}|{t}' for d in ("left", "right") for t in ("current_corner", "next_corner")} | {"straight|straight_segment"}
    for head, spec in config["heads"].items():
        classes = spec["classes"]
        choices = valid_corner if head == "corner" else VOCAB["corner_phase"] - {"unknown"}
        if len(classes) < 2 or len(set(classes)) != len(classes) or not set(classes).issubset(choices):
            raise ValueError("Invalid model classes")
        if arrays[head + "_w"].shape != (x.shape[1], len(classes)) or arrays[head + "_b"].shape != (len(classes),):
            raise ValueError("Model head dimension mismatch")
    x = np.clip((x - arrays["mean"]) / arrays["scale"], -5, 5) / np.sqrt(config["feature_count"])
    before = time.perf_counter()
    scores = {h: softmax(x @ arrays[h + "_w"] + arrays[h + "_b"]) for h in config["heads"]}
    elapsed = time.perf_counter() - before
    rows = []
    for i, case in enumerate(manifest["cases"]):
        proposals, reasons = {}, []
        for head, probability in scores.items():
            index = int(np.argmax(probability[i]))
            score = float(probability[i, index])
            proposals[head] = {"label": config["heads"][head]["classes"][index], "score": score,
                               "accepted": score >= config["proposal_threshold"], "score_is_calibrated": False}
        direction, target, phase = "unknown", "unknown", "unknown"
        if proposals["corner"]["accepted"]:
            direction, target = proposals["corner"]["label"].split("|")
        else:
            reasons.append("corner_score_below_uncalibrated_threshold")
        if "phase" in proposals and proposals["phase"]["accepted"]:
            candidate = proposals["phase"]["label"]
            compatible = ((candidate == "straight" and target == "straight_segment")
                          or (candidate == "approach" and target == "next_corner")
                          or (candidate in {"entry", "apex_region", "exit", "transition"} and target == "current_corner"))
            if compatible:
                phase = candidate
            else:
                reasons.append("inconsistent_phase_suppressed")
        else:
            reasons.append("phase_unavailable_or_below_threshold")
        rows.append({"event_id": case["event_id"], "source_group_id": case["source_group_id"],
                     "decision_time_s": case["decision_time_s"], "origin": "unvalidated_student_prediction",
                     "turn_direction": direction, "turn_target": target, "corner_phase": phase,
                     "raw_heads": proposals, "suppression_reasons": reasons,
                     "action": "disabled", "hud_speed_displayed": None})
    output.mkdir(parents=True)
    write_json(output / "predictions.json", {"schema_version": SCHEMA, "model_sha256": digest(model_dir / "model.json"),
               "batch_manifest_sha256": digest(batch / "manifest.json"), "training_source_reused": repeated,
               "training_source_hashes": config["training_sources"],
               "purpose": "training_smoke_only" if repeated else "unvalidated_replay_for_human_testing",
               "head_batch_seconds": elapsed, "head_event_seconds": elapsed / len(rows),
               "head_timing_excludes": ["video_decode", "image_encoding", "capture", "UI"], "predictions": rows})
    # Blank references let Sean test without being anchored by model outputs.
    manifest_hash = hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest()
    with (output / "blind_reference_template.jsonl").open("x") as stream:
        for case in manifest["cases"]:
            row = {"event_id": case["event_id"], "source_group_id": case["source_group_id"],
                   "manifest_hash": manifest_hash, "origin": "independent_human", "annotator": "",
                   "saw_model_answers": False, "actions_enabled": False, "reason": "",
                   "review_status": "pending", **{field: "unknown" for field in FIELDS},
                   "evidence": {field: [] for field in FIELDS}}
            stream.write(json.dumps(row) + "\n")
    print(json.dumps({"predictions": str(output / "predictions.json"), "training_source_reused": repeated,
                      "independent_accuracy": "not measured"}))


def evaluate(batch, reference_path, prediction_path, output):
    manifest, _ = load_batch(batch)
    references = load_labels(reference_path, manifest, independent=True)
    data = json.loads(prediction_path.read_text())
    if (data["training_source_reused"] or data["batch_manifest_sha256"] != digest(batch / "manifest.json")
            or manifest["source"]["sha256"] in data["training_source_hashes"]):
        raise ValueError("Not an independent matching replay")
    predicted = {r["event_id"]: r for r in data["predictions"]}
    if (len(predicted) != len(references) or len(predicted) != len(data["predictions"])
            or set(predicted) != {r["event_id"] for r in references}):
        raise ValueError("Missing or duplicate predictions")
    for case in manifest["cases"]:
        row = predicted[case["event_id"]]
        if row["source_group_id"] != case["source_group_id"] or row["decision_time_s"] != case["decision_time_s"]:
            raise ValueError("Prediction identity mismatch")
        if any(row[field] not in VOCAB[field] for field in FIELDS):
            raise ValueError("Invalid prediction enum")
    report = {"n_events": len(references), "n_sources": 1, "action_accuracy": "not applicable", "fields": {},
              "reference_sha256": digest(reference_path), "prediction_sha256": digest(prediction_path),
              "model_sha256": data["model_sha256"], "reviewers": sorted({r["annotator"] for r in references})}
    for field in FIELDS:
        known = [r for r in references if r[field] != "unknown"]
        accepted = [r for r in known if predicted[r["event_id"]][field] != "unknown"]
        correct = sum(predicted[r["event_id"]][field] == r[field] for r in accepted)
        confusion = Counter((r[field], predicted[r["event_id"]][field]) for r in known)
        report["fields"][field] = {"readable_references": len(known), "accepted": len(accepted), "correct": correct,
            "coverage": len(accepted) / len(known) if known else None,
            "accepted_accuracy": correct / len(accepted) if accepted else None,
            "correct_over_all_readable": correct / len(known) if known else None,
            "nonunknown_on_unknown_reference": sum(predicted[r["event_id"]][field] != "unknown" for r in references if r[field] == "unknown"),
            "confusion": [{"reference": a, "prediction": b, "count": n} for (a, b), n in sorted(confusion.items())]}
    write_json(output, report)


def sheets(batch, output):
    manifest, _ = load_batch(batch)
    if output.exists():
        raise ValueError("Refusing to overwrite contact sheets")
    output.mkdir(parents=True)
    # Only causal first/middle/last road images and the latest minimap are shown.
    for page, begin in enumerate(range(0, len(manifest["cases"]), 5), 1):
        selected = manifest["cases"][begin:begin + 5]
        canvas = Image.new("RGB", (1536, 248 * len(selected)), "#101820")
        draw = ImageDraw.Draw(canvas)
        for row, case in enumerate(selected):
            y = row * 248
            draw.text((6, y + 4), f'{case["event_id"]} decision {case["decision_time_s"]:.1f}s | causal first / middle / last | final minimap', fill="white")
            for col, frame_index in enumerate((0, 2, 4)):
                frame = case["frames"][frame_index]
                with Image.open(batch / frame["path"]) as im:
                    road = im.crop((384, 280, 1536, 928)).resize((384, 216))
                    canvas.paste(road, (col * 384, y + 24))
                    if frame_index == 4:
                        minimap = im.crop((1536, 688, 1920, 1040)).resize((235, 216))
                        canvas.paste(minimap, (1200, y + 24))
                draw.text((col * 384 + 4, y + 225), f'{frame["frame_id"]} {frame["source_time_s"]:.3f}', fill="#b1ffda")
        canvas.save(output / f"sheet-{page:02d}.jpg", quality=95)
    print(f"Created {page} sheets in {output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("sheets")
    p.add_argument("batch", type=Path); p.add_argument("output", type=Path)
    p = sub.add_parser("train")
    p.add_argument("batch", type=Path); p.add_argument("labels", type=Path); p.add_argument("output", type=Path)
    p.add_argument("--allow-unreviewed-ai", action="store_true")
    p = sub.add_parser("predict")
    p.add_argument("model", type=Path); p.add_argument("batch", type=Path); p.add_argument("output", type=Path)
    p.add_argument("--allow-training-source", action="store_true")
    p = sub.add_parser("evaluate")
    p.add_argument("batch", type=Path); p.add_argument("references", type=Path)
    p.add_argument("predictions", type=Path); p.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.command == "sheets": sheets(args.batch, args.output)
    elif args.command == "train": train(args.batch, args.labels, args.output, args.allow_unreviewed_ai)
    elif args.command == "predict": predict(args.model, args.batch, args.output, args.allow_training_source)
    else: evaluate(args.batch, args.references, args.predictions, args.output)


if __name__ == "__main__":
    main()
