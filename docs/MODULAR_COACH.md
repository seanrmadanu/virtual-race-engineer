# Modular coach: implementation and review handoff

Status: pre-training development pilot. Updated October 5, 2026.

The modular pipeline and review format are implemented. The full 12-step plan is not complete.
No gameplay slowdown model has been trained. No learned live cues are enabled.
The existing live coach, image-classifier weights, recordings, and original review files remain in place.

October 5 follow-up: native shadow capture, state-reset tests and calibration evidence recording are implemented.
See [Shadow capture](SHADOW_CAPTURE.md). They do not require or modify your unfinished reviews.

## Review the pilot

1. Run `bash scripts/open-modular-pilot.sh` from the repository root.
2. Select **Slowdown Timing · Pilot**. The package contains 30 moments from Video 2.
3. Click a timestamp. Use **Replay 2 Seconds** to watch its lead-in.
4. Expand module evidence below the video. Evidence follows the selected review, not the moving playhead.
5. Compare the unreviewed label hypothesis, rule proposal, guarded result, and legacy-policy comparison.
6. Add your name. Choose **Correct**, **Early**, **Late**, **Wrong / Missed**, **Missed Cue**, **Unsure**, or **Unusable View**.
7. Choose **Your Cue**. Enter its acceptable start and end times in seconds from video start.
8. For **No cue needed**, enter the interval that needs no slowdown cue.
9. Choose **Uncertain** or **Cannot judge** when the footage cannot establish the action. Neither needs a timing interval.
10. Select **Save & Next**. Export reviews when finished.

The verdict judges the displayed proposal. **Your Cue** is your explicit training label.
The application never copies a suggested label into your answer automatically.
Visible deceleration does not prove braking. A minimap bend does not prove current steering or corner phase.
Do not assign lift/brake labels solely because a rule suggested them.
These reviews follow model outputs. They are development feedback, not blind final-test ground truth.

Current package: `data/guidance/modular/video2-v4/pilot.review.json`.
The earlier v1–v3 traces remain available for regression comparison. Do not mix their feedback with v4.
The launcher uses the build that passed 59 native tests on October 4, stored separately under
`data/guidance/modular/verified-app-20261004/`. Your reviews save under `data/guidance/modular/user-reviews/`.
QA uses a different folder. No QA feedback is included in the training pilot.

## Verification status

- The current app built successfully. All 59 native tests passed, including v1 compatibility and v2 timing reviews.
- Ten Python tests passed. They check training gates, causal features, gradients and benchmark behavior.
- Six native module check groups passed, including the Video 2 speed regression, clipped digits, geometry and stalls.
- The complete Video 2 replay produced 6,194 samples and the 30-event pilot.
- On October 5, the verified app loaded the actual pilot and completed its recording-identity check.
- The read-only native validator passed all 30 events, source/trace fingerprints, serialization and causal timestamp lookup.
- Visual and interaction checks remain unverified: the native inspection service reports a closed pipe.

These checks do not establish coaching accuracy, calibrated confidence, or live readiness.
The testing strategy separates contract/regression checks from gameplay evaluation.
The review UI uses native controls and separates selected evidence from the moving playback marker.

## What changed

| Plan step | Implemented | Remaining gate |
| --- | --- | --- |
| 1. Preserve baseline | Snapshot of 86 source/model/output or recording-identity entries; prior recordings/reviews untouched | Full tracked live-engine replay comparison remains separate |
| 2. Module boundaries | Swift adapters reuse speed OCR, minimap detection and route geometry; opt-in native shadow capture is connected | Physical capture behavior and overhead still need validation |
| 3. Shared output | Existing observation extended with units, evidence and confidence kind; timestamp, state, version and reason retained | Add new HUD profiles only after measurement |
| 4. Causal history | 20 rows at 10 Hz; missing values and ages; capture/completion causality; seek/source/gap resets | Verify real capture interruptions when live integration starts |
| 5. Module tests | Synthetic geometry, clipped pixels, actual speed frame, missing HUD, stalls, resets and policy failures | Independent speed/direction accuracy; camera/menu classification is incomplete |
| 6. Calibrated baseline | Calibration contract, guarded rules, local evidence recorder and measurement-report tools | Confirm car/setup, map scale, target speeds, measured deceleration and warning delay |
| 7. Independent safety | Proposal and evidence guard are separate; no-cue and cannot-judge differ | Qualified learned live enablement is deliberately absent |
| 8. Review screen | v2 evidence, module scores/ages/reasons, timing intervals, early/late/missed verdicts; v1 decode retained | Final visual/interaction verification still needs a working app-inspection connection |
| 9. Reviewed pilot | 30 varied, explicitly unreviewed hypotheses from Video 2; includes known 00:50, 01:35 and 01:45 issues | User reviews before training |
| 10. Structured model | NumPy causal temporal network, feature schema, gradients, training gates and artifact provenance | No real-label training yet; sufficient reviewed action examples and separate validation source needed |
| 11. Benchmarks | Identical-timestamp comparison, cue-onset timing metrics, coverage and separate confidence-bin utility | No measured superiority or calibrated confidence without reviewed references |
| 12. Core ML / live | Export/parity script and native module shadow recording prepared; learned live flag remains false | Export dependencies, real trained artifact, parity run, native learned inference integration, three reviewed 20-minute shadow sessions |

## Source map

- `Racing Trainer/CoachSafetyPolicy.swift`: existing generic observation and preserved legacy policy.
- `Racing Trainer/ModularCoach.swift`: serializable values, causal history, calibration contract, proposals and independent evidence guards.
- `Racing Trainer/ModularVideoModules.swift`: native pixel adapters. No wheel inset or future frames enter features.
- `Racing Trainer/ModelReviewModels.swift`: versioned review bundle and journal models.
- `Racing Trainer/ModelReviewStore.swift` and `ModelReviewView.swift`: native video review, diagnostics and feedback.
- `Training/guidance/modular/ReplayModules.swift`: sequential AVFoundation replay, simulated arrival clock and legacy-policy comparison.
- `prepare_pilot.py`: deterministic varied-event selection and label hypotheses.
- `temporal.py` and `train.py`: structured features and new randomly initialized temporal network.
- `benchmark.py`: reviewed cue-onset comparisons; unreviewed regions remain unscored.
- `export_coreml.py`: optional export; requires NumPy/PyTorch/Core ML prediction parity before saving.

## Data contract and clocks

Each observation contains a value, state, confidence, capture time, completion time, source session,
implementation/version, failure reason, units, raw evidence, and confidence kind.
Raw evidence includes source-frame timestamps, OCR text, detection diagnostics, and ordered route points.
The original video supplies the inspectable pixels. The review screen can seek to the evidence frame.

Replay uses video time. Completion times add measured analysis duration to a serial virtual processing clock.
Each decision reads only observations captured **and completed** by that time.
The grid covers `(decision time - 2 seconds, decision time]`, with 20 rows spaced 0.1 seconds apart.
Missing observations are not converted to zeros in the record. Model encoding uses explicit missingness fields.
A newer failed reading replaces the older successful reading. It does not refresh the successful value's age.

Reset history and module state on source changes, backward seeks, repeated frame timestamps, or gaps over 0.75 seconds.
The history also exposes an explicit reset for callers that know a pause or seek occurred.
The current UI replays stored outputs. It does not recompute or retain a live model state when seeking.

## Speed regression and layout limits

At Video 2, 01:45, the visible speed is **151 km/h**. The legacy crop reads **15** on the regression fixture.
The new `reference-video2-v1` profile uses the measured crop `(0.075, 0.854, 0.070, 0.073)`.
It reads 151 on that fixture. Pixel-edge checks reject partially clipped white digits.
The legacy live crop and its default call behavior remain unchanged for comparison.
Do not apply this source-specific profile to another recording without checking its HUD layout.
An unconfirmed profile marks speed uncertain. The unit must also be explicitly configured after visual inspection.

Vision can omit a partial digit from its text box. Bounding-box margins alone did not catch this example.
Pixel-edge rejection is conservative and can reject glare. It does not reconstruct missing digits.
This fixes a reproduced case; it is not evidence of general OCR accuracy.

## Calibration and safety

No real calibration profile exists yet. No scale, car setup, braking constant or target speed was invented.
The calibration contract requires a car/setup ID, HUD profile, unit, measured map scale, lift/brake deceleration,
delay, supported speed range, severity-specific target speeds, reviewer and evidence references.
Normalized map distance is not meters or time-to-turn until validated calibration supplies that mapping.

The independent guard rejects missing, stale, uncertain, future, wrong-session or mismatched speed.
It also checks geometry, minimap, input validity, units, distance, calibration and camera verification where required.
Learned proposals always remain shadow-only. `no_cue` is not acceleration advice.
Input validity currently detects layout/HUD failures and repeated pixels. It does not reliably identify every camera orbit or menu.
Module confidence values remain diagnostic scores. Neither averaging scores nor module agreement proves correctness.

## Reproduce the development work

Run from the repository root. Commands refuse existing replay/model output directories.

```sh
bash scripts/replay-modules.sh '../Training Video/Video 2.mp4' \
  data/guidance/modular/new-video2-run km/h reference-video2-v1

python3 Training/guidance/modular/prepare_pilot.py \
  data/guidance/modular/new-video2-run \
  data/guidance/modular/new-video2-run/pilot.review.json

bash scripts/check.sh test
bash scripts/check-modular-pilot.sh
python3 -m unittest discover -s Training/guidance/modular -p 'test_*.py' -v
```

Python requires NumPy. The bundled runtime used here is
`/Users/sean/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3`.
If iCloud offloads generated caches, use a new local `RACING_TRAINER_DERIVED_DATA` and `PYTHONPYCACHEPREFIX`.
If Xcode stalls while coordinating an iCloud project read, first restore the source files locally.
Then run `bash scripts/check-modular-local.sh`. It tests an exact source copy in a new temporary folder,
without cloud metadata, recordings, user state or Git history. It prints the built app path on success.
Do not overwrite source files to bypass an unavailable cloud download.

The native regression runner expects the full 01:45 frame from Video 2:

```sh
ffmpeg -ss 105 -i '../Training Video/Video 2.mp4' -frames:v 1 /private/tmp/video2-105.png
bash scripts/replay-modules.sh --self-test /private/tmp/video2-105.png
```

Replay writes `observations.jsonl` and a completion manifest. A missing manifest means an incomplete run.
The manifest stores recording and compiled-source fingerprints. The review bundle also fingerprints the exact trace.
Its legacy `modelSHA256` field identifies the native pipeline for this untrained pilot, not learned weights.
The full trace repeats history for inspection and is large. Earlier runs were retained, not deleted.

## Training gates

`train.py CONFIG.json NEW_MODEL_DIRECTORY` reads a `sources` array. Each entry supplies:

```json
{
  "split": "train",
  "sourceGroup": "original-recording-group-id",
  "bundle": "/absolute/path/pilot.review.json",
  "feedback": "/absolute/path/exported-feedback.json",
  "trace": "/absolute/path/observations.jsonl"
}
```

The current trainer requires each supplied pilot to have all 30 moments reviewed.
Uncertain/unusable examples are excluded, not silently labeled no-cue.
It checks source/run identity, explicit action/timing labels, interval conflicts and group leakage.
Training and validation must use different source recordings. Edited copies still need a shared source-group ID.
Each action must have enough reviewed examples. Video 2 alone cannot satisfy the separate-recording validation gate.
Video 1 and Video 2 remain development footage; neither is an untouched final test.

The network uses 20 × 26 structured features: noisy values, missingness, freshness, ages and separate module scores.
It uses a left-padded temporal convolution, tanh, history pooling and a four-class head.
Turn direction remains a geometry output. The old image-classifier weights are never loaded.
Synthetic tests exercise optimization and gradients without saving gameplay weights or creating human reviews.

## Evaluation and deployment gates

`benchmark.py` requires identical ordered decision timestamps for each compared system and reviewed cue intervals.
It scores cue onsets rather than repeated state rows. It reports early/late/missed cues, false cues in reviewed windows,
answer coverage, and unscored outputs outside reviewed windows.
Keep each confidence-bin evaluation tied to one module/target and an independent correctness criterion.
Accuracy and calibration results are not available yet. Offline processing latency is not end-to-end warning delay.

Core ML export additionally needs `torch` and `coremltools`, which were not installed for this pre-training phase.
The export script has not been exercised on a real model. It reconstructs the NumPy network, compares both implementations,
then compares Core ML outputs on saved validation inputs. Only a passing run saves a model package.
Reference: [Apple's conversion workflow](https://apple.github.io/coremltools/docs-guides/source/convert-pytorch-workflow.html).

Before deployment: confirm the calibration, add native structured-feature/inference integration, pass parity/reset/safety tests,
evaluate untouched recordings, and collect three distinct 20-minute live shadow sessions.
Review false, missed, early and late cues and every suppression failure before considering an enablement change.
No code in this change enables learned live advice. Apex, traffic, acceleration and exact steering remain deferred.
