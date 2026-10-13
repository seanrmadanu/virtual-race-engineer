# Model Review: skill categories and timestamped feedback

Model Review is a native Racing Trainer window with the recording, saved model
outputs and review notes together. Open it through **Replay → Model Review** in
the main window or **Model Review → Show Model Review** in the menu bar
(Shift–Command–R).

## The curriculum

| Category | Skills | Current support |
| --- | --- | --- |
| 1. Basic turns | Left/right/straight, current vs. upcoming corner, unknown handling | Experimental v1 outputs available for review |
| 2. Corner technique | Approach, entry, apex region, exit, racing line | Only coarse approach/entry/exit/straight outputs are trained; apex and racing line remain planned |
| 3. Advanced driving | Braking technique, linked corners, grip and traffic decisions | Planned; no model outputs or action advice |

Categories organize skills and feedback, not separate trained models or unlocked
proficiency levels. A useful progression is: review category 1 across different
recordings and camera conditions; resolve basic perception and uncertainty errors;
then build defensible supervision for category 2; qualify category 3 only after
its required perception and action evidence exists. Literature supplies definitions,
not game-specific optimal actions. Each category needs its own held-out evaluation.

## Review a test

1. **Open Test…** and select a prepared `.review.json` file. Video 2 is prepared at
   `data/guidance/bootstrap/replays/video2-v1/video2.review.json`.
2. **Attach Video…** and select the original recording. The app checks its SHA-256
   and duration against the model log before enabling playback reviews.
3. Pick a skill category. Select a timestamp in **Timestamp Log** to pause at that
   moment. **Replay 2 Seconds** plays the lead-in and pauses at the decision time.
4. Add your name, choose **Correct**, **Wrong / Missed**, **Unsure**, or **Unusable
   View**, optionally choose corrections, and write what you saw.
5. **Save Review** marks that moment reviewed; **Save & Next** moves to the next
   matching row. Filter the log by answered, unknown, or unreviewed moments.
6. **Export Reviews…** exports machine-readable feedback for later assistant review
   and training preparation. Retraining is a separate operation.

The log retains unknown predictions. The playback readout uses only the most recent
sample at or before the playhead and always displays its timestamp. With five-second
sampling it is a recorded observation, not a continuous live inference stream.
The note editor stays pinned to the selected log row while playback advances.
The timestamp log highlights the sample at the playhead with a **Now** marker,
following playback, scrubbing and backward seeks. It scrolls that row into view
without moving the review editor. A pencil marks the moment selected for review.
If a filter hides the current sample, the app says so and offers **Show All**;
it never highlights an older answered row as if it were still the current output.

Draft edits persist immediately. Changing a saved review makes it a draft again.
The recording/model/replay hashes key the feedback file, preventing corrections
from carrying over silently to another model run. Drafts and reviewed rows are
exported with distinct `reviewed` flags. All rows are explicitly feedback after
seeing model outputs; this UI does not create blind accuracy references.

Normal app storage is `Application Support/RacingTrainer/ModelReview` within the
app's sandbox when applicable. The last test is copied there and the video is
remembered with a security-scoped bookmark. A moved or unavailable video can be
reattached. Import or save errors appear inline; an invalid existing journal is
not silently replaced. `--review-storage /absolute/path` provides an isolated
storage directory for development checks.

## Implementation

```text
Frozen model + prepared video → predictions.json + manifest.json
                                    ↓ export_review.py
                              video2.review.json
                                    ↓ native import + matching video
                   AVPlayer ← click timestamp → selected log event
                                                ↓
                                    draft / reviewed feedback JSON
```

`ModelReviewModels.swift` owns the category vocabulary, replay contract, timestamp
selection and feedback identity validation. `ModelReviewStore.swift` owns player
seeking, two-second replay, file identity checks, atomic local saves and exports.
`ModelReviewView.swift` provides the native split view and editor. The existing
live analyzer and hand-written driving policy are not sources of these logged
bootstrap-model predictions.

The UI uses native semantic colors, standard controls, readable system text and a
resizable split view. A selected row stays highlighted, and errors and review
states have text as well as symbols. This follows the Apple design skill's
split-view selection and data-entry guidance. The deliberate visual focus is the
gameplay video; notes and model outputs stay alongside it rather than covering it.
Save controls remain visible below the scrolling review form. User-selected file
access is read/write so the native Save panel can export feedback in sandboxed builds;
this does not grant unrestricted filesystem access.

## Prepare another completed replay

After running the existing bootstrap `predict` command, package its results:

```sh
GUIDANCE_PYTHON="/Users/sean/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3"
"$GUIDANCE_PYTHON" Training/guidance/bootstrap/export_review.py \
  data/guidance/bootstrap/replays/video2-v1/predictions.json \
  data/guidance/bootstrap/tests/video2-v1/manifest.json \
  /absolute/path/to/a-new-test.review.json
```

The exporter preserves final output values and verifies manifest and event identity.
It refuses to overwrite a package. App import checks sorted unique timestamps,
supported labels and compatible final direction/phase fields. This first version
displays completed offline runs; it does not run Python training or live inference
inside the app.

For developer launch, build with `bash scripts/check.sh build`, then run the app
with `--model-review --review-bundle /absolute/test.review.json --review-video
/absolute/video.mp4`. The default UI import path works without launch arguments.

## Verification scope

Model contract tests cover causal playhead lookup, unknown preservation, duplicate
and invalid timestamps, contradictory output rejection, feedback round-trips and
source/model/run identity mismatches. Runtime checks must additionally cover real
video decode, timestamp clicks, replay stopping, note persistence, resizing and
category changes. Build/test success alone does not establish those interactions.

Verified in the local development build on 2026-10-02:

- All 44 native tests passed, including eight model-review contract tests.
- Video 2 decoded; selecting 01:35 sought to 95 seconds. Two-second replay stopped
  at the selected timestamp.
- A draft and its matching recording restored after reopening; an isolated QA
  review saved, and Save & Next advanced from 01:35 to 01:45 under Model Answered.
- The export matched the saved journal. All 121 packaged outputs matched the
  original replay exactly, including unknowns and suppression reasons.
- Switching categories showed eight basic answers, three coarse phase answers,
  and an explicitly untrained advanced category.

These checks used `data/guidance/model-review-qa`, not the user's review journal.
They validate review mechanics, not prediction accuracy or advanced coaching.

Timestamp-sync follow-up: all 46 tests passed, including forward/backward lookup
and unknown-interval coverage. Runtime playback in Video 2 advanced the highlighted
row from 00:50 to 01:00 with automatic scrolling while the review editor stayed
pinned to 00:10. The active row has both a highlight and a text/symbol marker.

Next extensions: completed-run discovery, verified inference launched from the
app, assistant-review provenance, multiple reviewers with conflict resolution,
and per-category held-out metrics. Revisit them as the number of recordings and
model versions grows.
