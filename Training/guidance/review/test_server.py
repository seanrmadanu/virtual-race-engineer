import copy
import hashlib
import json
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from server import Store, handler_for, validate_batch, validate_label


class ReviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "f.jpg").write_bytes(b"synthetic fixture, never gameplay")
        digest = hashlib.sha256((self.root / "f.jpg").read_bytes()).hexdigest()
        self.batch = {"schema_version":"review-batch-v1","batch_id":"test-only","action_labels_enabled":False,"cases":[{
            "event_id":"case-01","recording_id":"fixture","source_group_id":"fixture","decision_time_s":2,
            "input_interval_s":[0,2],"frames":[{"frame_id":"f1","source_time_s":1.9,"path":"f.jpg","sha256":digest}]}]}
        (self.root / "manifest.json").write_text(json.dumps(self.batch))
        self.payload = {"batch_id":"test-only","event_id":"case-01","reviewer_id":"qa-only","base_revision":0,
            "independent_of_teacher":True,"observations":{"hud_speed_displayed":None,"hud_unit":"unknown",
            "speed_source_frame_id":None,"turn_direction":"unknown","turn_target":"unknown","corner_phase":"unknown"},
            "evidence_frame_ids":[],"notes":"Synthetic unknown fixture, not a human observation."}

    def tearDown(self):
        self.temp.cleanup()

    def test_unknown_is_not_zero_and_actions_not_collected(self):
        row = validate_label(self.payload,self.batch)
        self.assertIsNone(row["observations"]["hud_speed_displayed"])
        self.assertFalse(row["action_labels_collected"])
        self.assertEqual(row["review_status"],"pending")
        self.assertNotIn("recommendation",row)

    def test_zero_requires_real_evidence(self):
        self.payload["observations"]["hud_speed_displayed"] = 0
        with self.assertRaises(ValueError): validate_label(self.payload,self.batch)
        self.payload["observations"]["speed_source_frame_id"] = "f1"
        self.payload["evidence_frame_ids"] = ["f1"]
        self.assertEqual(validate_label(self.payload,self.batch)["observations"]["hud_speed_displayed"],0)

    def test_reject_invalid_speed_types(self):
        for value in [True,-1,1000,1.5,"114",float("nan")]:
            with self.subTest(value=value):
                self.payload["observations"]["hud_speed_displayed"] = value
                with self.assertRaises(ValueError): validate_label(self.payload,self.batch)

    def test_known_value_unknown_units_permitted_with_evidence(self):
        self.payload["observations"].update(hud_speed_displayed=114,speed_source_frame_id="f1")
        self.payload["evidence_frame_ids"] = ["f1"]
        self.assertEqual(validate_label(self.payload,self.batch)["observations"]["hud_unit"],"unknown")

    def test_known_direction_requires_evidence(self):
        self.payload["observations"]["turn_direction"] = "left"
        with self.assertRaises(ValueError): validate_label(self.payload,self.batch)

    def test_unknown_enum_and_invented_frame_rejected(self):
        self.payload["observations"]["corner_phase"] = "brake_now"
        with self.assertRaises(ValueError): validate_label(self.payload,self.batch)
        self.payload["observations"]["corner_phase"] = "unknown"
        self.payload["evidence_frame_ids"] = ["future-frame"]
        with self.assertRaises(ValueError): validate_label(self.payload,self.batch)

    def test_identity_confirmation_notes_and_batch_required(self):
        for key,value in [("reviewer_id",""),("independent_of_teacher",False),("notes",""),("batch_id","other"),("event_id","invented")]:
            with self.subTest(key=key):
                payload = copy.deepcopy(self.payload); payload[key] = value
                with self.assertRaises(ValueError): validate_label(payload,self.batch)

    def test_straight_target_consistency(self):
        self.payload["evidence_frame_ids"] = ["f1"]
        self.payload["observations"].update(turn_direction="straight",turn_target="current_corner")
        with self.assertRaises(ValueError): validate_label(self.payload,self.batch)

    def test_reject_future_and_nonfinite_timestamps(self):
        for time in [2.01,-1,float("nan"),True]:
            with self.subTest(time=time):
                batch = copy.deepcopy(self.batch); batch["cases"][0]["frames"][0]["source_time_s"] = time
                with self.assertRaises(ValueError): validate_batch(batch,self.root)

    def test_reject_duplicate_frames_and_cases(self):
        batch = copy.deepcopy(self.batch)
        batch["cases"][0]["frames"].append(copy.deepcopy(batch["cases"][0]["frames"][0]))
        with self.assertRaises(ValueError): validate_batch(batch,self.root)
        batch = copy.deepcopy(self.batch); batch["cases"].append(copy.deepcopy(batch["cases"][0]))
        with self.assertRaises(ValueError): validate_batch(batch,self.root)

    def test_reject_path_escape_and_changed_frame(self):
        batch = copy.deepcopy(self.batch); batch["cases"][0]["frames"][0]["path"] = "../outside.jpg"
        with self.assertRaises(ValueError): validate_batch(batch,self.root)
        (self.root / "f.jpg").write_bytes(b"changed")
        with self.assertRaises(ValueError): validate_batch(self.batch,self.root)

    def test_append_history_reload_isolation_and_conflicts(self):
        store = Store(self.root)
        one = store.save(self.payload)
        self.assertEqual(one["revision"],1)
        with self.assertRaises(ValueError): store.save(self.payload)
        self.payload["base_revision"] = 1; self.payload["notes"] = "Synthetic revision."
        two = store.save(self.payload)
        self.assertEqual(two["revision"],2)
        self.assertEqual(len(store.path("qa-only").read_text().splitlines()),2)
        reloaded = Store(self.root)
        self.assertEqual(reloaded.latest("qa-only")["case-01"]["notes"],"Synthetic revision.")
        self.assertEqual(reloaded.latest("another-reviewer"),{})

    def test_http_read_save_and_security_boundaries(self):
        store = Store(self.root)
        server = ThreadingHTTPServer(("127.0.0.1",0),handler_for(store))
        worker = threading.Thread(target=server.serve_forever,daemon=True); worker.start()
        base = f"http://127.0.0.1:{server.server_port}"
        def request(path, payload=None, headers=None):
            req = Request(base+path,data=json.dumps(payload).encode() if payload is not None else None,
                          headers={"Content-Type":"application/json",**(headers or {})})
            return urlopen(req,timeout=3)
        try:
            with request("/api/bootstrap") as response:
                self.assertEqual(json.load(response)["batch"]["batch_id"],"test-only")
                self.assertIn("frame-ancestors 'none'",response.headers["Content-Security-Policy"])
            for path,body,headers,status in [
                ("/api/labels",self.payload,{},403),
                ("/api/labels",self.payload,{"X-Review-Token":store.token,"Origin":"https://example.com"},403),
                ("/api/bootstrap",None,{"Host":"evil.example"},403),
                ("/manifest.json",None,{},404),
                ("/frames/../manifest.json",None,{},404),
                ("/api/labels",{"batch_id":"other"},{"X-Review-Token":store.token},400),
            ]:
                with self.subTest(path=path,headers=headers):
                    with self.assertRaises(HTTPError) as error: request(path,body,headers)
                    self.assertEqual(error.exception.code,status)
            with request("/api/labels",self.payload,{"X-Review-Token":store.token}) as response:
                self.assertEqual(json.load(response)["label"]["revision"],1)
            with request("/api/labels?reviewer=qa-only",headers={"X-Review-Token":store.token}) as response:
                self.assertEqual(len(json.load(response)["labels"]),1)
            with request("/api/export",{"reviewer_id":"qa-only","batch_id":"test-only"},{"X-Review-Token":store.token}) as response:
                exported = json.load(response)
                self.assertEqual(exported["label_count"],1)
                self.assertEqual(json.loads(Path(exported["path"]).read_text())["labels"][0]["revision"],1)
        finally:
            server.shutdown(); server.server_close(); worker.join(timeout=3)

    def test_exports_are_new_snapshots_and_preserve_revision_history(self):
        store = Store(self.root); store.save(self.payload)
        first = store.export({"reviewer_id":"qa-only","batch_id":"test-only"})
        self.payload["base_revision"] = 1; self.payload["notes"] = "A second synthetic revision."
        store.save(self.payload)
        second = store.export({"reviewer_id":"qa-only","batch_id":"test-only"})
        self.assertNotEqual(first["path"],second["path"])
        self.assertEqual(json.loads(Path(first["path"]).read_text())["labels"][0]["revision"],1)
        self.assertEqual(json.loads(Path(second["path"]).read_text())["labels"][0]["revision"],2)

    def test_saved_labels_cannot_cross_manifest_versions(self):
        store = Store(self.root); store.save(self.payload)
        store.manifest_sha256 = "changed"
        with self.assertRaises(ValueError): store.latest("qa-only")


if __name__ == "__main__":
    unittest.main()
