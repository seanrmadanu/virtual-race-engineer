# Trained perception bootstrap — offline testing only

The first checkpoint is trained and saved at
[`temporal-v1-final`](../../../data/guidance/bootstrap/runs/temporal-v1-final/model.json).
It is a small **temporal perception classifier**, not a trained braking coach.
Sean chose to test after training on different footage; no pre-training human
review was required for this separate, explicitly provisional run.

## What is ready

- 132 sampled windows / 660 masked frames from one 11-minute source recording.
- 78 usable direction/target labels; 68 phase labels. All are unreviewed assistant
  proposals. The other 54 windows were excluded entirely from supervised losses
  and normalization statistics; ten additional phases remain unknown.
- Five joint direction/target classes: current left (17), next left (19), current
  right (24), next right (13), straight segment (5).
- Four learned phase classes: approach (32), entry (18), exit (13), straight (5).
  Apex-region and transition are **not learned**.
- Saved NumPy weights, model metadata, training report, replay predictions and a
  verification report. Original source footage, human-label journals and the native
  coach are unchanged. Nothing was uploaded to a separate API; no paid compute or
  additional model download was used.

The trained arrays occupy about 355 KiB; this excludes Apple's system image
encoder. This is transfer learning with fixed image features and trained softmax
heads, **not** a fine-tuned VLM, end-to-end video network, or completed guidance model.

## Important limits

There are zero independent test recordings so far. Training-label agreement is
100% on the fitted cases, which can reflect memorization and is **not test accuracy**.
Windows are correlated within one recording, not 132 independent corners/sessions.

The smoke replay produces non-unknown corner predictions on 9 of the 54 excluded
windows. These include unusable or ambiguous cases. There is no qualified
unsupported-camera/scene rejection mechanism yet, and the 0.65 score threshold is
uncalibrated. Inspect results; do not treat scores as probabilities of correctness.

No speed head was trained. Braking, throttle, target speed, exact steering, optimal
line and traffic clearance are disabled. There is no native-app integration or
live end-to-end latency result. **Use a separate recorded video for the first test.**

## Quick check on this Mac

From the repository root, use the bundled Python (NumPy + Pillow are already
available). The old `temporal-v1` run is preserved; `temporal-v1-final` is the
checksum-recorded packaging run with numerically identical weights.

```sh
cd "/Users/sean/Documents/Projects/Racing Trainer/Racing Trainer-3"
GUIDANCE_PYTHON="/Users/sean/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3"
"$GUIDANCE_PYTHON" -m unittest discover -s Training/guidance/bootstrap -p 'test_*.py' -v
```

Current verification: 27 bootstrap contract/solver tests and 15 existing review-tool
tests passed. See [test plan](TEST_PLAN.md) for the distinction between automated
checks and the human evaluation that remains.

## Run on a new video

Use another original recording, not a crop, excerpt or re-encode of Video 1. Verify
the footage has stable forward third-person chase view, unrotated 1920×1080 output,
the same HUD/minimap layout and no coaching overlay. Resolution alone does not prove
the HUD/camera profile matches. Initial source platform and car setup were unknown;
new PS4 footage is a domain-change test, not assumed equivalent.

The following is the operator workflow; Sean can supply the file and have the
assistant run it. Output directories must be new. The preparation step samples five
frames across two seconds every five seconds, burns the same mask, and extracts
local features. It may need permission for macOS video/Vision framework access.

```sh
xcrun swift -module-cache-path /private/tmp/guidance-swift-module-cache \
  Training/guidance/bootstrap/prepare.swift \
  "/absolute/path/to/new-recording.mp4" \
  data/guidance/bootstrap/tests/new-recording-01

"$GUIDANCE_PYTHON" Training/guidance/bootstrap/pipeline.py predict \
  data/guidance/bootstrap/runs/temporal-v1-final \
  data/guidance/bootstrap/tests/new-recording-01 \
  data/guidance/bootstrap/replays/new-recording-01
```

The source-hash guard rejects the training file unless an explicit smoke-test flag
is used. It cannot detect re-encoded duplicates or separate captures from one
session; the operator must preserve that source grouping. Encoder revision,
preprocessing and OS version must match the checkpoint, or prediction stops.

Results are `predictions.json`: timestamped direction, current/next target, phase,
raw uncalibrated scores and suppression reasons. JSON is the current replay
interface; there is **not yet a new-video review UI or a live overlay** for this model.
The existing ten-moment practice page is not connected to these predictions.

### Human testing after training

For a quick qualitative check, watch the new recording and compare the timestamped
predictions. Save failures, but call this assisted error review rather than an
independent accuracy measurement.

For quantitative testing, record your answers for a frozen set of causal clips
before opening `predictions.json`. The predictor also creates a blank
`blind_reference_template.jsonl`; fill the actual observations, supporting first/
middle/last frame IDs, reviewer name and notes, then set each completed row's
`review_status` to `reviewed`. Leave genuinely uncertain fields unknown. Do not claim
`saw_model_answers: false` if you saw the predictions first.

```sh
"$GUIDANCE_PYTHON" Training/guidance/bootstrap/pipeline.py evaluate \
  data/guidance/bootstrap/tests/new-recording-01 \
  /absolute/path/to/completed-independent-references.jsonl \
  data/guidance/bootstrap/replays/new-recording-01/predictions.json \
  data/guidance/bootstrap/replays/new-recording-01/human-evaluation.json
```

This reports coverage, accepted-answer accuracy, confusion counts and assertions
on unknown references separately. A reused training source, unfinished reference,
teacher-derived reference or manifest mismatch cannot be scored as independent.
After errors guide a fix, those cases are development/regression cases for the next
version; reserve fresh footage for its next test.

## Architecture and tradeoffs

```text
Source video -> causal masked frames -> fixed road/minimap image features
                          |                         |
                    assistant labels         latest + mean + delta
                          |                         |
                          +---- train softmax heads-+
                                         |
                                 frozen model package
                                         |
New video -> identical preprocessing -> predictions -> Sean's later evaluation
```

`prepare.swift` uses AVFoundation plus Apple's revision-2 image feature print.
Each frame has two 768-value vectors. Latest, mean and last-minus-first pooling
produces 4,608 causal features; normalization is fitted only on eligible training
windows. `pipeline.py` learns class-balanced regularized softmax heads with 600
Adam steps, then saves non-executable NPZ arrays and a hashed JSON contract.

The frozen encoder avoids installing a large training runtime and fits this Mac's
local workflow. The tradeoff is a very small, layout-specific linear baseline; it
does not have a task-fine-tuned visual backbone, explicit road geometry or a GRU.
Apple documents the feature-print API for image similarity; using its vectors for
this classifier is an **experimental project choice**, not a demonstrated racing
perception capability. [Apple feature-print documentation](https://developer.apple.com/documentation/vision/vnfeatureprintobservation).

The teacher was the image-capable assistant inspecting contact sheets, not the
installed text-only Llama model or an unattended teacher API. Read the
[teacher contract](TEACHER_CONTRACT.md) for weak-label provenance and multi-row
contact-sheet bias. Literature informed vocabulary; no controlled literature
comparison was run. The [original audited pilot](../teacher/README.md) remains a
separate uncompleted experiment.

Revisit data diversity, event grouping, independent labels, supported-view detection,
unknown handling, score calibration and an explicit temporal network after the
first external tests. Train action advice only with defensible action supervision.
Live use additionally needs Swift/Core ML parity, capture-history resets, latency
measurement, evidence gates and shadow testing before user-facing cues.

## Reproduction and artifact integrity

Raw observations, bound labels, frames and checkpoints live under ignored
`data/guidance/bootstrap/`. Keep that folder when backing up the project; a Git clone
alone will not contain the trained checkpoint. Do not commit the user's recordings.

`materialize_labels.py` only binds explicitly authored observations to case/frame
hashes; it never fills missing labels or calls a model. Original labels and earlier
checkpoints are preserved. Every new training run must use a new output directory:

```sh
"$GUIDANCE_PYTHON" Training/guidance/bootstrap/pipeline.py train \
  data/guidance/bootstrap/video1-v1 \
  data/guidance/bootstrap/video1-v1/labels.jsonl \
  data/guidance/bootstrap/runs/my-new-run --allow-unreviewed-ai
```

Contract failures stop the operation. Partial extraction folders are not ready
batches; use a new output directory after investigating a failure. No automatic
in-place retraining, deployment, source modification or rollback is performed.
