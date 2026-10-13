"""Loopback-only, standard-library review tool. No model or external API calls."""
import argparse
import hashlib
import json
import math
import os
import secrets
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

WEB = Path(__file__).parent / "web"
ENUMS = {
    "hud_unit": {"kmh", "mph", "unknown"},
    "turn_direction": {"left", "right", "straight", "unknown"},
    "turn_target": {"current_corner", "next_corner", "straight_segment", "unknown"},
    "corner_phase": {"straight", "approach", "entry", "apex_region", "exit", "transition", "unknown"},
}


def finite_number(value):
    return type(value) in (int, float) and math.isfinite(value)


def validate_batch(batch, directory):
    if batch.get("schema_version") != "review-batch-v1" or batch.get("action_labels_enabled") is not False:
        raise ValueError("Unsupported or action-enabled batch")
    if not batch.get("batch_id") or not isinstance(batch.get("cases"), list) or not batch["cases"]:
        raise ValueError("Batch identity/cases missing")
    case_ids, frame_ids = set(), set()
    for case in batch["cases"]:
        case_id = case["event_id"]
        if case_id in case_ids:
            raise ValueError("Duplicate event")
        case_ids.add(case_id)
        start, end = case["input_interval_s"]
        decision = case["decision_time_s"]
        if not all(map(finite_number, [start, end, decision])) or not 0 <= start < end <= decision:
            raise ValueError("Invalid causal interval")
        if not case["recording_id"] or not case["source_group_id"] or not case["frames"]:
            raise ValueError("Missing provenance/frames")
        last = -math.inf
        for frame in case["frames"]:
            stamp = frame["source_time_s"]
            if frame["frame_id"] in frame_ids or not finite_number(stamp) or not start <= stamp <= end or stamp <= last:
                raise ValueError("Duplicate, non-monotonic or non-causal frame")
            frame_ids.add(frame["frame_id"])
            last = stamp
            path = (directory / frame["path"]).resolve()
            if not path.is_relative_to(directory.resolve()) or not path.is_file():
                raise ValueError("Frame path escapes batch or is missing")
            if hashlib.sha256(path.read_bytes()).hexdigest() != frame["sha256"]:
                raise ValueError("Frame hash mismatch")


def reviewer_id(value):
    if not isinstance(value, str) or not value.strip() or len(value) > 64 or not value.isprintable():
        raise ValueError("Enter a reviewer name or nickname (1–64 characters)")
    return value.strip()


def validate_label(payload, batch):
    reviewer = reviewer_id(payload.get("reviewer_id"))
    if payload.get("batch_id") != batch["batch_id"]:
        raise ValueError("Wrong batch")
    cases = {case["event_id"]: case for case in batch["cases"]}
    case = cases.get(payload.get("event_id"))
    if case is None:
        raise ValueError("Unknown case")
    if payload.get("independent_of_teacher") is not True:
        raise ValueError("Confirm you labeled without AI answers")
    obs = payload.get("observations")
    required = set(ENUMS) | {"hud_speed_displayed", "speed_source_frame_id"}
    if not isinstance(obs, dict) or set(obs) != required:
        raise ValueError("Incomplete observation fields")
    for key, allowed in ENUMS.items():
        if obs[key] not in allowed:
            raise ValueError(f"Choose {key}, or explicitly choose unknown")
    frames = {frame["frame_id"] for frame in case["frames"]}
    evidence = payload.get("evidence_frame_ids")
    if not isinstance(evidence, list) or len(evidence) != len(set(evidence)) or not set(evidence) <= frames:
        raise ValueError("Invalid evidence frame IDs")
    speed = obs["hud_speed_displayed"]
    if speed is not None and (type(speed) is not int or not 0 <= speed <= 999):
        raise ValueError("Displayed speed must be a whole number from 0–999, or explicitly unknown")
    speed_frame = obs["speed_source_frame_id"]
    if speed is None and speed_frame is not None:
        raise ValueError("Unknown speed cannot have a speed observation frame")
    if speed is not None and (speed_frame not in frames or speed_frame not in evidence):
        raise ValueError("Readable speed needs its supporting frame in evidence")
    if any(obs[key] != "unknown" for key in ENUMS) or speed is not None:
        if not evidence:
            raise ValueError("Mark at least one supporting frame for known observations")
    if obs["turn_direction"] == "straight" and obs["turn_target"] != "straight_segment":
        raise ValueError("Straight direction requires the straight-segment target")
    if obs["turn_target"] == "straight_segment" and obs["turn_direction"] not in {"straight", "unknown"}:
        raise ValueError("A straight segment cannot have left/right direction")
    notes = payload.get("notes")
    if not isinstance(notes, str) or not notes.strip() or len(notes) > 4000:
        raise ValueError("Add a short evidence/uncertainty note (up to 4,000 characters)")
    return {
        "schema_version": "independent-human-label-v1", "batch_id": batch["batch_id"],
        "event_id": case["event_id"], "recording_id": case["recording_id"], "source_group_id": case["source_group_id"],
        "decision_time_s": case["decision_time_s"], "input_interval_s": case["input_interval_s"],
        "reviewer_id": reviewer, "origin": "independent_human", "independent_of_teacher": True,
        "review_status": "pending", "action_labels_collected": False,
        "observations": obs, "evidence_frame_ids": evidence, "notes": notes.strip(),
        "saved_at": datetime.now(timezone.utc).isoformat(),
    }


class Store:
    def __init__(self, directory, labels_dir=None):
        self.directory = Path(directory).resolve()
        self.batch = json.loads((self.directory / "manifest.json").read_text())
        validate_batch(self.batch, self.directory)
        self.manifest_sha256 = hashlib.sha256((self.directory / "manifest.json").read_bytes()).hexdigest()
        self.labels_dir = Path(labels_dir or self.directory / "labels").resolve()
        self.labels_dir.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock()
        self.token = secrets.token_urlsafe(32)

    def path(self, reviewer):
        key = hashlib.sha256(reviewer_id(reviewer).encode()).hexdigest()[:24]
        return self.labels_dir / f"reviewer-{key}.jsonl"

    def latest(self, reviewer):
        with self.lock:
            path = self.path(reviewer)
            rows = [json.loads(line) for line in path.read_text().splitlines() if line] if path.exists() else []
            if any(row.get("manifest_sha256") != self.manifest_sha256 for row in rows):
                raise ValueError("Saved labels belong to a different manifest; do not mix batch versions")
            return {row["event_id"]: row for row in rows}

    def save(self, payload):
        record = validate_label(payload, self.batch)
        record["manifest_sha256"] = self.manifest_sha256
        with self.lock:
            prior = self.latest(record["reviewer_id"]).get(record["event_id"])
            if payload.get("base_revision", 0) != (prior["revision"] if prior else 0):
                raise ValueError("This label changed in another session. Reload the page before saving another revision.")
            record["revision"] = 1 + (prior["revision"] if prior else 0)
            with self.path(record["reviewer_id"]).open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(record, allow_nan=False) + "\n")
                handle.flush()
                os.fsync(handle.fileno())
        return record

    def export(self, payload):
        if payload.get("batch_id") != self.batch["batch_id"]:
            raise ValueError("Wrong export batch")
        reviewer = reviewer_id(payload.get("reviewer_id"))
        with self.lock:
            rows = list(self.latest(reviewer).values())
            key = self.path(reviewer).stem
            folder = self.labels_dir / "exports"
            folder.mkdir(exist_ok=True)
            stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
            path = folder / f"{key}-{stamp}.json"
            bundle = {"schema_version":"human-review-export-v1", "batch_id":self.batch["batch_id"],
                      "manifest_sha256":self.manifest_sha256,"reviewer_id":reviewer,
                      "action_labels_collected":False,"labels":rows}
            with path.open("x",encoding="utf-8") as handle:
                json.dump(bundle,handle,indent=2,allow_nan=False)
                handle.write("\n"); handle.flush(); os.fsync(handle.fileno())
            return {"path":str(path),"label_count":len(rows)}


def handler_for(store):
    frame_paths = {f["frame_id"]: store.directory / f["path"] for c in store.batch["cases"] for f in c["frames"]}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def respond(self, status, value, content_type="application/json"):
            data = json.dumps(value, allow_nan=False).encode() if content_type == "application/json" else value
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' blob:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
            self.end_headers()
            self.wfile.write(data)

        def authorized(self, token=False):
            host = f"127.0.0.1:{self.server.server_port}"
            origin = self.headers.get("Origin")
            valid = self.headers.get("Host") == host and origin in (None, f"http://{host}")
            valid = valid and self.headers.get("Sec-Fetch-Site") not in {"cross-site"}
            if token:
                valid = valid and secrets.compare_digest(self.headers.get("X-Review-Token", ""), store.token)
            if not valid:
                self.respond(403, {"error": "Local same-origin request required"})
            return valid

        def do_GET(self):
            if not self.authorized():
                return
            url = urlsplit(self.path)
            if url.path == "/api/bootstrap":
                self.respond(200, {"batch": store.batch, "token": store.token})
            elif url.path == "/api/labels":
                if not self.authorized(token=True):
                    return
                try:
                    name = parse_qs(url.query).get("reviewer", [""])[0]
                    self.respond(200, {"labels": store.latest(name)})
                except (ValueError, TypeError) as error:
                    self.respond(400, {"error": str(error)})
            elif url.path in {"/", "/app.js", "/style.css"}:
                filename = {"/": "index.html", "/app.js": "app.js", "/style.css": "style.css"}[url.path]
                mime = {"index.html": "text/html; charset=utf-8", "app.js": "text/javascript; charset=utf-8", "style.css": "text/css; charset=utf-8"}[filename]
                self.respond(200, (WEB / filename).read_bytes(), mime)
            elif url.path.startswith("/frames/") and url.path[8:] in frame_paths:
                self.respond(200, frame_paths[url.path[8:]].read_bytes(), "image/jpeg")
            else:
                self.respond(404, {"error": "Not found"})

        def do_POST(self):
            if not self.authorized(token=True):
                return
            if self.path not in {"/api/labels", "/api/export"}:
                self.respond(404, {"error": "Not found"})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 32768 or self.headers.get_content_type() != "application/json":
                    raise ValueError("Expected a small JSON label record")
                payload = json.loads(self.rfile.read(length))
                if not isinstance(payload, dict):
                    raise ValueError("Expected a label object")
                result = {"label": store.save(payload)} if self.path == "/api/labels" else store.export(payload)
                self.respond(200, result)
            except (ValueError, KeyError, TypeError) as error:
                self.respond(400, {"error": str(error)})
            except OSError:
                self.respond(500, {"error": "Could not save to disk; your label is not saved. Retry after checking storage."})

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("batch", type=Path)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--labels-dir", type=Path, help="Separate directory for disposable QA only")
    args = parser.parse_args()
    store = Store(args.batch, args.labels_dir)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), handler_for(store))
    print(f"Review page: http://127.0.0.1:{server.server_port}", flush=True)
    print(f"Labels stay on this Mac: {store.labels_dir}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
