# Corner Replay Lab

> Updated workflow: the app now opens as **Reference Video Lab**, using one
> downloaded recording. See [Reference videos first](REFERENCE_VIDEO_WORKFLOW.md).
> The paired workflow below is optional, under **Compare player recording**;
> it is not a prerequisite for preparing data or the initial offline model.

This first training-workflow milestone prepares and compares reviewed corner
recordings. It does **not** train a guidance model, determine optimal speed, or
change the live coaching policy. There are no learned wheel-angle or pedal labels.

## Quick start

1. Run this isolated Xcode project and click **Replay Lab** in the main toolbar.
   To bypass capture startup, launch with the `--corner-replay-lab` argument.
2. In each pane, use **File > Open video…** for a player and reference recording.
   Use uncropped 16:9 Motorfest footage with the standard HUD. Previews are muted.
3. Fill in route, corner, car/setup and source-group IDs. Route/corner/setup must
   match exactly. Include relevant tune, assists and conditions in setup identity.
   Clips from one original recording must retain the same source-group ID.
4. Pause at matching visible locations and mark `entry`, `apex`, and `exit` in both
   videos. At least two identical, ordered landmark names are required. These
   times approximately align the clips; they are not measured route progress.
5. Select the speed unit actually visible in each video's HUD. Choose a short
   corner interval, no more than 60 seconds, and click **Sample interval**.
   Start with 2–5 seconds to check the workflow. Sampling uses 5 frames/sec and
   records decoded source timestamps, not wall-clock time or requested seek times.
6. Select each sample and inspect its paused video frame. The panel scrolls; return
   to the video when necessary to see the HUD. Correct the value in **km/h**, then
   use **Confirm & next**, or **Unreadable & next** when it cannot be verified.
   For mph footage, multiply the HUD reading by 1.609344. OCR alone is never a
   reviewed label; missing readings are never carried forward.
7. Click **Compare reviewed samples**. Rows describe above/near/below-reference
   speed, or explain why the comparison was withheld. Click a row to seek both
   recordings. **Below reference is not permission to accelerate.**
8. Use each pane's **File > Export labels…** to preserve annotations, and
   **Export report…** for the comparison. Data otherwise remains in memory until
   the app quits. Complete the required identity fields before exporting.

Import labels through the pane's File menu. **Attach original video…** allows
frame inspection after importing; the filename and duration must match. Confirm
it is the exact same edit: this version does not cryptographically identify media.
Replacing a video or sampling again prompts before discarding existing labels.

## Comparison rules

- Session schema version 1; all stored speeds are km/h. Times must be finite,
  in range, unique and strictly increasing; speeds must be in 0–500 km/h.
- Missing identity, a mismatched route/corner/setup, or invalid landmark ordering
  withholds the comparison. Same-source comparisons are flagged as non-independent.
- Piecewise linear alignment uses matching landmark timestamps, without
  extrapolation outside the landmark interval.
- Both speed observations must be reviewed and have confidence at least 0.8.
  Human confirmation sets confidence to 1; unreadable labels remain missing.
  This is label confidence, not a calibrated probability of correct driving.
- Reference interpolation uses adjacent usable samples at most 0.6 seconds apart.
  It never skips an intervening missing/unreviewed reading or extrapolates speed.
- ±10 km/h is a provisional descriptive band, not a brake threshold. Mean absolute
  speed gap measures difference from the selected reference, not model accuracy.
- Label and metadata changes clear the report; it must be recomputed explicitly.
  The HUD-unit selector affects future sampling, not existing km/h labels.

## Verification — 29 September 2026

`bash scripts/check.sh test` builds the native app and runs a hostless test target.
The final run passed **43 tests, zero failures**:

- 11 existing live coach-safety tests.
- 25 replay-model tests: JSON round trips and malformed inputs, identity matching,
  landmark alignment, no extrapolation, interpolation limits, review/confidence
  gates, signed differences, comparison bands and report summaries.
- 7 video-sampler tests: generated AVAssetWriter fixtures exercise source timestamps
  at 7 fps sampled at 5 Hz, missing OCR remaining unreviewed, explicit unit
  conversion, invalid/out-of-video ranges, non-16:9 rejection, preferred track
  rotation and cancellation without returning partial labels.

The blank synthetic fixtures test decoding and failure behavior, **not** HUD OCR
accuracy on gameplay. The only remaining build warnings were Xcode's skipped
App Intents metadata extraction for targets without that framework.

The isolated app launched and its main toolbar was read through accessibility.
Further native UI clicks repeatedly failed with `Sky Computer Use native pipe
closed before response`, including after reconnect/reset. Therefore visual layout,
the full interactive labeling flow, file dialogs and signed-sandbox exports are
**not yet verified end to end**. The export entitlement has been corrected to
user-selected read/write; the unsigned automated build does not prove it works
under a signed app sandbox.

## Manual acceptance checklist

- Open both recordings, scrub, and place matching landmarks. Verify the frame
  shown when a label is accepted corresponds to its source timestamp.
- Sample a short interval. Confirm no OCR-only samples produce comparisons.
- Review matching samples; correct one speed to create a known positive/negative
  gap. Verify the report, then change setup or landmarks to invalidate it.
- Cancel sampling and retry; confirm no partial/stale job replaces existing labels.
- Export/import labels and export a report in a signed sandboxed run. Reattach the
  original videos and check timestamps, values and review status survived.
- Check the pane layout and review controls at the smallest supported window size.

Do not use these draft exports as a production training dataset yet: raw OCR and
correction history, source-unit provenance, media hashes, independent holdout
manifests and expert verification remain later dataset work. Coaching accuracy,
capture/display latency and steering calibration have not been measured here.
