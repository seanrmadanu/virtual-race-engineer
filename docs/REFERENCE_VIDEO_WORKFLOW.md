# Reference videos first

## Decision

Accepted 29 September 2026: player recordings are no longer a prerequisite for
data preparation or the initial offline model. The user can join when there is
a candidate overlay ready for gameplay testing. Work remains in the `codex` copy.

The native lab now opens in single-reference mode. The paired comparison remains
an optional evaluation tool, enabled with **Compare player recording**.

## Workflow

1. Process downloaded driving videos automatically. Choose the HUD speed unit for
   each batch. Extract source-timestamped observations and preserve confidence,
   missing readings and recording identity. No matching player clip is required.
2. Audit representative frames and suspicious intervals, and build a small
   independently checked evaluation set. Automatic extraction does not require
   clicking through every frame. Candidate observations remain marked unreviewed.
3. Add upcoming-route/road features and calibrated wheel observations where the
   footage supports them. A future model's inputs must be available in gameplay
   at runtime. Hide wheel/input overlays from its visual inputs if they are used
   to obtain targets. The current batch tool extracts speed observations only.
4. Group compatible successful demonstrations by route, car/setup and conditions.
   Keep unknown metadata unknown. Keep all chunks, re-edits and duplicate uploads
   from an original recording in the same dataset split.
5. Train a small initial predictor from current/past scene features to future
   demonstrated speed or checked corner phases. Compare it with simple baselines
   on untouched reference recordings. Same-frame speed must not be both input and
   target; future frames and centered smoothing must not enter causal inputs.
6. Build the initial supported cue set and check timing on recorded video. Invite
   the user to play when the overlay is ready for a short validation session.
   Use those later trials to assess cue usefulness and identify missing examples.

The first learned prediction describes demonstrated behavior. Calling its output
an optimal speed or a useful correction requires further evaluation. A successful
reference drive alone does not show how to recover from every possible mistake.

## What footage can tell us

HUD speed can provide an observed speed trace. Changes in that trace describe net
deceleration/acceleration; they do not identify exact pedal inputs. Steering-wheel
camera footage can be a label source after neutral, direction, rotation range,
occlusion and synchronization are checked. Exact pedal pressure needs visible
input measurements or another validated label source.

The existing minimap detector can later supply route geometry and confidence.
Its GPS path is not the actual racing line, and its normalized distances are not
meters. Do not use the live coach's hand-written actions as expert training labels.

This follows the data distinction illustrated by [VPT](https://arxiv.org/abs/2206.11795):
its action inference was trained using a smaller dataset with known actions before
labeling large amounts of video. VPT does not establish that arbitrary action
labels can be recovered from video without that evidence. The sequential-learning
problem discussed in [DAgger](https://proceedings.mlr.press/v15/ross11a.html) also
motivates testing the coach on the states a learner actually reaches. For this
project those live trials occur after the initial offline work, not before it.

## Use the app

Open **Reference Video Lab**, choose one downloaded clip, pick its HUD unit, sample
an interval, and select **Export observations…**. No route/corner IDs, matching
landmarks or player video are needed for this export. **Optional audit and
corrections** allows targeted manual checks. Unit selection applies to the next
sampling job; an export retains the unit selected when its samples were extracted.

**Import observations or labels…** accepts batch exports. Reattach the original
video only when visual inspection is needed. Where available, its SHA-256 hash is
checked before attaching; filename and duration are also checked. A byte hash
detects identical files, not every re-encoded or edited copy of a recording.

## Process videos without the app

From the copied project:

```sh
bash scripts/extract-reference-videos.sh \
  --input '../Training Video' \
  --output './data/reference-observations/run-01' \
  --unit kmh
```

Use `--unit mph` for a batch whose videos all display mph. Put mixed-unit sources
in separate runs. `--start 120 --end 130` processes a short pilot interval. Without
those options, each complete video is processed in bounded windows at 5 Hz.

The command processes local `.mp4`, `.mov`, and `.m4v` files, preserves source
timestamps, fingerprints files, writes one JSON per source and reports failures.
Existing outputs are protected from replacement. Use a new output directory for
a changed extraction configuration. Data remains local and media is not copied.

The schema permits missing source metadata and keeps raw candidate review status.
No player footage or frame-by-frame approval is required to produce these files.
Automatic candidates must still be checked before they are treated as evaluation
ground truth. The command creates observations, not model weights or action labels.

## Tradeoffs and remaining work

This removes the user's need to drive during initial development and makes the
existing videos useful immediately. It also means the first model will primarily
see demonstrated trajectories. It will need later tests for recovery advice and
behavior outside those trajectories. More compute cannot replace missing action
labels or independent evaluation recordings.

At this change, one source video was located in `Training Video`. It can validate
the extraction workflow; adjacent chunks of that video do not constitute an
independent training/test split. Additional original recordings are needed for a
credible generalization assessment. Road/minimap batch features, wheel tracking,
the model trainer and the live integration remain subsequent milestones.

## Current verification

The native Debug app builds and all **51 tests pass** on 29 September 2026. Eight
new schema tests specifically cover reference-only preparation without player,
route or setup fields; optional hashes; explicit units; review/missingness
preservation; invalid schemas, ranges and sample values.

The CLI compiles, handles invalid arguments, and successfully processed seconds
120–130 of the existing `Video 1.mp4`: 49 actual-timestamp observations, including
39 nonmissing OCR candidates, all unreviewed. The source is 1920×1080 and its HUD
was visually checked as km/h. This measures extraction coverage, not accuracy.

The complete 673.563-second recording also finished processing successfully:
**3,357 timestamped observations**, with 2,884 nonmissing speed candidates and
473 missing readings. All remain unreviewed. The output covers source times
0 through 673.389 seconds, has strictly increasing timestamps, and declares the
full recording interval. Its SHA-256 matches the original video. The small
difference from an ideal 5 Hz sample count comes from accepting only decoded
frame timestamps inside each requested window.

The completed dataset is
`data/reference-observations/full-2026-09-29/Video 1-30732c1a2691.json`.
It can be imported directly into Reference Video Lab. No player recording was
used, and no speed candidates were silently promoted to reviewed labels.

A targeted audit confirmed an OCR error at source time 121.588133 seconds: the
HUD displays 096 km/h, while the raw OCR candidate is 9 with confidence 1. This
shows why OCR confidence alone cannot establish label correctness. Preserve raw
observations, improve extraction and audit held-out frames before using this data
as training/evaluation truth. No model weights were trained in this increment.

The native interface still requires a visual interaction check; the earlier
computer-use connection failed during click actions. Automated schema/decoder
tests and command-line video extraction do not establish native file-dialog or
signed-sandbox export behavior.
