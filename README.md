# Virtual Race Engineer

Virtual Race Engineer is an early-stage macOS racing coach for **The Crew
Motorfest**. It accepts gameplay from a capture card or a local video file,
reads HUD information locally, and is being developed toward real-time braking,
acceleration, and steering guidance.

## Current phase

This is the canonical `Racing Trainer-3` project. Roadmap v2 implementation has
started with a tested safety policy and timestamped evidence contracts. See
[implementation status](docs/IMPLEMENTATION_STATUS.md) for completed work,
verification, dataset locations and remaining gates. Historical copies live in
the sibling `Versions` folder.

Phase 1B currently provides:

- live capture-card video and game-audio preview;
- local `.mov` and `.mp4` playback for testing without a console;
- speedometer OCR diagnostics;
- shape-validated Motorfest minimap and cyan local-player detection, with a
  reduced-confidence circular-rim fallback when the arrow disappears;
- a hybrid GPS-route detector: deterministic yellow geometry first, a reviewed-
  mask-trained segmenter for difficult normal routes, and a learned component
  verifier for ambiguous short routes;
- a magenta route-mask overlay with confidence and performance statistics;
- an ordered green route centerline anchored at the cyan local-player marker;
- separate minimap, anchor, mask, path, geometry, temporal, freshness, and
  motion-tracking confidence gates;
- upcoming direction, severity, and timing classification;
- timestamp-synchronized speed/route observations;
- conservative brake/hold/accelerate-if-clear and categorical steering
  guidance;
- paired minimap-image and predicted-mask recording;
- a route-mask reviewer with accept, reject, brush, eraser, undo, and redo;
- source-grouped train/validation export and reproducible offline training
  scripts under `Training/`.

The reviewed export contains 582 image/mask pairs. In the offline presence
audit, normal color geometry detected 510 of 526 route frames with no false
route in 56 reviewed no-route frames. Verified short-route recovery raised that
to 524 of 526 while retaining 56/56 no-route rejection. These are dataset
results, not proof of generalization; the newer 39-frame source holdout contains
no no-route examples, so unseen-source specificity is still unmeasured. The
full report is `Training/hybrid_detector_audit.json`.

## Build the route-mask dataset

1. Load a full 16:9 Motorfest recording or use live capture.
2. In the right sidebar, press the red record button under **Minimap Dataset**.
3. Play footage with waypoint routes, no waypoint, and varied scenery.
4. Stop recording. Each saved crop now has a same-sized automatic binary mask.
5. Press the paintbrush button in **Route Mask Dataset**.
   - Use **Generate Missing** when older crops have no automatic mask.
   - Use **Regenerate Pending** to replace stale automatic masks after a
     detector update. Accepted and corrected samples are preserved.
6. For each sample:
   - **Accept Prediction** if magenta covers only the yellow GPS trail;
   - use **Brush** or **Eraser**, then **Save Corrected Mask**, if it is wrong;
   - use **Approve as No Route** for a visible minimap with no waypoint;
   - **Reject Sample** if the minimap is missing, moved, obstructed, or unusable.
7. Export reviewed pairs when the seed set is ready.

The export keeps every frame from one source video in the same split. This
prevents adjacent frames from one clip appearing in both training and
validation data and producing misleading accuracy.

## Requirements

- macOS and Xcode
- a complete, uncropped 16:9 Motorfest gameplay feed
- the default Motorfest HUD position
- a capture card for live console input, or a local AVFoundation-compatible
  gameplay video for offline testing

## Build and test

For a repeatable unsigned Debug build and the automated safety suite:

```sh
bash scripts/check.sh build
bash scripts/check.sh test
```

The XCTest target runs the shared production policy and model sources without
launching capture. It covers missing/stale/uncertain evidence, source changes,
brake thresholds, acceleration prerequisites and decision expiration. These
tests do not replace labeled video replay or live validation.

For manual gameplay checks:

1. Open `Racing Trainer.xcodeproj`.
2. Choose **Product > Clean Build Folder** (`Shift-Command-K`).
3. Build with `Command-B`, then run.
4. Open the **Live Input** menu.
5. Select the capture card or **Open Video File…**.
6. Keep **Analyzer** enabled.

Expected route states:

- **COACH READY**: the ordered path passed every critical confidence gate.
- **SET A WAYPOINT**: the minimap and player anchor exist, but no route exists.
- **ROUTE UNCERTAIN**: route evidence exists but is unsafe to interpret.
- **GUIDANCE STALE**: no sufficiently recent path result exists.
- **MINIMAP / GAMEPLAY NOT FOUND**: the HUD is hidden, moved, cropped, in a
  menu/transition, or incompatible with the calibrated layout.

## Route-overlay performance

The minimap pipeline has a 30 FPS scheduling ceiling and never queues a backlog
of full detections. While a full detection is running, only the newest frame is
retained. A lightweight tracker attempts to rotate/translate the verified green
centerline onto that newest frame. Failed tracking suppresses guidance; it does
not silently reuse an old path. Each completed minimap/coach result is published
to SwiftUI as one atomic state update.

The **Frame Analyzer** panel displays both:

- **Map FPS**: the actual rate followed by the configured ceiling (for example,
  `27.5 / 30.0`);
- **Map Time**: the processing time actually reached on the current Mac.

## Local processing and YouTube

Frame analysis is performed locally; the current pipeline does not require a
paid API. A normal YouTube watch-page URL cannot provide decoded pixel buffers
to `AVPlayerItemVideoOutput`. Use a permitted local recording or send a
full-screen browser source through OBS Virtual Camera.

## Known limitations

- HUD crop coordinates are currently calibrated for default 16:9 Motorfest
  footage.
- The hybrid detector still needs testing across more cars, weather,
  regions, display modes, and capture devices.
- The short-route policy is calibrated from few failure cases. Collect a newer
  source holdout containing no-waypoint, menu, objective-ring, water, and HUD-
  contamination negatives before calling minimap detection production-ready.
- The magenta mask comes from the full detector; the green ordered centerline
  is the path used by the coach and may be motion-tracked to a newer frame.
- Checkpoint gaps are bridged only when endpoints are close and aligned. An
  ambiguous intersection or gap correctly produces ROUTE UNCERTAIN.
- BRAKE thresholds are conservative KM/H heuristics, not vehicle-specific
  braking models.
- ACCELERATE IF CLEAR cannot see traffic, obstacles, grip, elevation, or lane
  position.
- Steering is categorical. The minimap cannot provide honest G29 wheel degrees,
  an ideal racing line, or lane corrections by itself.
- App icon, bundle identity, signing, sandbox entitlements, privacy text, and
  release testing still need to be completed before App Store distribution.

## Roadmap

Follow `Racing_Trainer_System_Design_and_Roadmap_v2.md` in the parent folder:

1. Establish the canonical baseline and verify dataset locations.
2. Add safety contracts, automated tests and integration regression coverage.
3. Build deterministic replay and independent recording-level evaluation splits.
4. Recover speed OCR and measure accepted errors, coverage and latency.
5. Evaluate route generalization; adopt pretrained models only if all gates pass.
6. Calibrate stable coaching, then add local voice output.
7. Validate three complete capture-card sessions on the M4.
8. Address public distribution after the dependable local milestone.

Lane/obstacle perception, exact wheel degrees, automated input, additional games
and screen capture are deferred.

## Licensing

A license has not yet been selected. Adding code to a public repository does
not by itself make the project open source; choose a license before presenting
it as an open-source release.
