#!/usr/bin/env python3
"""Bind explicitly authored assistant observations to immutable frame provenance.

This does NOT call a VLM or invent labels. Raw observations must be authored by
an image-capable teacher after inspecting the named causal images. V1 was
annotated interactively by the Codex assistant, not an unattended API runner.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path

from pipeline import digest, load_batch, load_labels, FIELDS


def materialize(batch: Path, raw_path: Path, output: Path):
    manifest, _ = load_batch(batch)
    raw = [json.loads(line) for line in raw_path.read_text().splitlines() if line.strip()]
    lookup = {f'event-{r["event"]:04d}': r for r in raw}
    if len(lookup) != len(raw) or set(lookup) != {c["event_id"] for c in manifest["cases"]}:
        raise ValueError("Raw observations must cover each case once; no filling missing labels")
    if output.exists():
        raise ValueError("Refusing to overwrite labels")
    manifest_hash = hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest()
    here = Path(__file__).resolve().parent
    rows = []
    for case in manifest["cases"]:
        observation = lookup[case["event_id"]]
        values = dict(zip(FIELDS, (observation["direction"], observation["target"], observation["phase"])))
        rows.append({"event_id": case["event_id"], "source_group_id": case["source_group_id"],
                     "manifest_hash": manifest_hash, "origin": "assistant_proposal", "review_status": "unreviewed",
                     "annotator": "Codex multimodal assistant; exact model identifier unavailable to run log",
                     "annotation_mode": "interactive_contact_sheet_observation_not_automated_teacher_API",
                     "teacher_contract_sha256": digest(here / "TEACHER_CONTRACT.md"),
                     "handbook_sha256": digest(here.parent / "teacher/ANNOTATION_HANDBOOK.md"),
                     "concept_cards_sha256": digest(here.parent / "literature/concept_cards.jsonl"),
                     "raw_observations_sha256": digest(raw_path), "actions_enabled": False,
                     "reason": observation["reason"], **values,
                     "evidence": {field: case["teacher_frame_ids"] if values[field] != "unknown" else [] for field in FIELDS}})
    with output.open("x") as stream:
        for row in rows:
            stream.write(json.dumps(row, sort_keys=True) + "\n")
    load_labels(output, manifest)
    print(json.dumps({"labels": len(rows), "origin": "unreviewed_assistant_proposal",
                      "counts": {f: dict(Counter(r[f] for r in rows)) for f in FIELDS}}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("batch", type=Path)
    parser.add_argument("raw_observations", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    materialize(args.batch, args.raw_observations, args.output)
