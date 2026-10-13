# Shadow capture and calibration evidence

Implemented October 5, 2026. This is recording infrastructure, not a trained or calibrated coach.
The current review app, 30-event package, human feedback and old model weights are unchanged.

## What is connected

```text
Live capture or local playback
  ├─ Existing FrameAnalyzer → existing coaching (unchanged policy)
  └─ Optional shadow recorder
       source token → bounded worker → native modules → causal history → guarded proposal
                                                          └─ local evidence files only
```

`CaptureSessionManager` and `VideoFilePlaybackController` share one optional shadow pipeline.
The system-design boundary is strict: the shadow pipeline has no voice, HUD, or cue-delivery callback.
It never loads a learned model or calibration profile. Existing coaching continues independently.
Extra CPU and disk work can still affect performance; live overhead has not yet been measured.

## Start later, after the current review

Do not restart your review app now. Its binary and files were not replaced.
When ready, run from the repository root:

```sh
bash scripts/open-shadow-capture.sh
```

The launcher opens a separate native capture window and opts into local HUD evidence recording.
It may use the capture device already selected in Settings. Select Live Capture or open a local video normally.
The default HUD profile, speed unit and car/setup remain unconfirmed. That is intentional.
The measured Video 2 profile is not automatically applied to live footage.

For a deliberate Video 2 development replay only:

```sh
bash scripts/open-shadow-capture.sh unconfirmed reference-video2-v1 --shadow-speed-unit km/h
```

Launching the app normally, or using `open-modular-pilot.sh`, performs no shadow recording.
No new capture permissions were granted or live recording started during implementation.

## State and clock contract

- Every selected source has a token. Old callbacks cannot submit using a replacement source's token.
- Live callbacks also check the connection's device. Reconfiguration drains the stopped source's callback queue.
- Seeks, source changes, pauses, failures, and capture notifications invalidate pending shadow results.
- A watchdog clears history after 0.75 seconds without advancing frames, even if callbacks stop entirely.
- Duplicate/backward source PTS and clock discontinuities invalidate the analysis generation.
- Delivery delayed more than 0.25 seconds, completion older than 0.75 seconds, invalid clocks, and non-BGRA buffers are rejected.
- One retained frame spans analysis and disk writes. A busy worker drops samples; it never grows a frame backlog.
- Accepted analysis targets at most 10 Hz. It retains 20 causal history rows, each 0.1 seconds apart.
- Decisions are evaluated at actual analysis completion, so irregular delivery is not described as exact 10 Hz inference.
- Logs store each current row once, not 20 repeated copies. Generations preserve reset boundaries for later reconstruction.

Observations use monotonic **receipt uptime**, not a verified camera-acquisition timestamp.
Original capture/playback PTS is stored separately. File playback uses the decoded frame's display PTS, not the requested seek time.
First-frame transport delay remains unknown. These logs cannot establish photon-to-cue or full warning delay.
Freeze detection uses a central-gameplay fingerprint, excluding the upper-left wheel inset (validity module v2).
A moving inset must not hide frozen gameplay. Camera classification remains incomplete.

## Recorded files and limits

Each launch creates `data/guidance/shadow-sessions/shadow-<UUID>/`:

- `manifest.json`: configuration, role, sample count, recording status and final trace fingerprint.
- `observations.jsonl`: source, generation, source PTS, receipt/completion clocks, module values, missingness,
  ages, individual diagnostic scores, raw evidence, proposals, suppression reasons and cumulative drop counts.
- Optional speedometer/minimap PNGs at up to one pair per second and on a new generation. No full-screen video or audio.
  Each trace entry fingerprints its images. These crops can support OCR and map inspection, not brake-input identification.

The recorder stops at 30 minutes or the 512 MiB byte cap, whichever applies first.
A full disk or write failure stops shadow recording only. Earlier files remain for diagnosis.
Normal shutdown finalizes the trace hash. An abrupt crash leaves an unfinished manifest, which the report tool rejects.
The capture window's normal shutdown closes the run. Start a new app instance for a new run after a limit or failure.
Files are not uploaded or automatically deleted. Source names/device IDs are stored locally; inspect logs before sharing.

## Calibration recording tools

After a run closes, prepare a report in a **new** directory:

```sh
python3 Training/guidance/modular/calibration_report.py \
  data/guidance/shadow-sessions/shadow-EXACT-RUN-ID \
  data/guidance/calibration-report-NEW-NAME
```

The tool checks the finalized trace and image fingerprints, source isolation and causal timestamps.
It writes:

1. `evidence-report.json`: speed/route time series with missing values, failures, segments, and receipt-to-analysis duration.
2. `calibration-notes.template.json`: empty fields for independent measurements and review.

It does **not** create an enabled `SlowdownCalibration`, human labels, or model weights.
Speed-dependent shadow advice stays disabled. Candidate observations are not calibrated game telemetry.

Independent measurements still needed:

| Quantity | Required evidence |
| --- | --- |
| Map scale | Identified corner/landmark, unchanged map zoom, normalized distance, independently established meters |
| Lift/brake deceleration | Confirmed action, speed interval, grade, car/setup and repeated runs; speed drop alone is insufficient |
| Warning delay | Input event and actual cue delivery on a verified common clock; shadow mode emits no cues |
| Target speeds | Reviewed cornering behavior for the confirmed car/setup |

Uncertain measurements stay blank. No literature constants or provisional estimates are silently promoted to calibration.

## Verification and remaining checks

Testing separates deterministic state contracts, recorder integration, and hardware qualification.

Verified results: 71 native tests, 17 Python tests, seven native module regression groups, and 120 real-pixel smoke samples passed.
The real recorder's output also passed the calibration report's fingerprint and causality checks.
At the 01:45 regression frame, the recorded speed was 151 km/h and route direction was right.
These are regression observations, not accuracy estimates.
The separate packaged app is `data/guidance/shadow-build-20261005-v2/Racing Trainer.app`.

- Native tests cover old tokens, bounded work, dropped/duplicate/stale frames, PTS jumps, backward seeks via resets,
  missing-callback watchdogs, source changes during analysis, late completion, I/O failure, file identity and limits.
- Python tests cover evidence report integrity, missingness, future/cross-source timestamps, unsafe paths,
  incomplete runs, changed images and non-overwriting reports.
- `bash scripts/check-shadow-capture.sh` runs a 12-second accelerated replay with real Video 2 pixels,
  actual native modules and the real recorder. It forces a reset and a no-frame interruption.
  Its source is explicitly `syntheticTest`; it does not count as a live shadow session.
- No automated GUI interaction or physical capture-card interruption was tested during this change.
- Still required later: hardware reconnects, sleep/wake, camera changes, live processing overhead and three reviewed 20-minute sessions.

Use `bash scripts/check-modular-local.sh` for the isolated full native build/test.
Use `python3 -m unittest discover -s Training/guidance/modular -p 'test_*.py' -v` for the Python checks.
The review bundle and the existing coach remain separate baselines.
