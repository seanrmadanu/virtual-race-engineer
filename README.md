# Virtual Race Engineer

> **Experiment snapshot from October 15, 2026.** This branch preserves the separate Claude prototype for frame-to-frame road-paint tracking, smoother lane overlays, and steering-wheel stabilization.
> Published November 5, 2026. See [main](https://github.com/seanrmadanu/virtual-race-engineer) for the canonical app. Local recordings, review data, and packaged builds are separate.

Virtual Race Engineer (project folder: Racing Trainer) is an early-stage macOS
driving coach for **The Crew Motorfest**. It takes gameplay video from a capture
card or a local video file, reads the speedometer and minimap on the Mac, and
shows experimental turn guidance on an animated steering wheel.

All analysis runs locally. The app needs no paid API and sends no gameplay
anywhere.

## Status — October 13, 2026

| Area | State |
| --- | --- |
| Capture and playback | Live capture-card video and audio, plus `.mov`/`.mp4` playback for testing without a console |
| Perception | Speedometer OCR, minimap and player-marker detection, hybrid GPS-route detection, experimental white road-marking detection |
| Live guidance | **Category 1 "Turns & Timing"** (experimental): one instruction and arrow (*Continue straight*, *Left/right turn ahead*, *Turn left/right now*, *Keep turning left/right*, *Guidance unavailable*) with an animated wheel |
| Not shown | Brake, throttle and target-speed advice. Wheel angle is illustrative, not a calibrated steering angle |
| Review tools | Model Review window: timestamped verdicts beside saved ChatGPT and Claude reviews, plus in-app video analysis |
| Data tools | Route-mask dataset recorder and reviewer, opt-in shadow capture, offline training and replay scripts |
| Tests | 91 XCTest tests and 66 Python tests pass (run October 13, 2026) |

Turn timing is a deterministic prototype. It has not been calibrated or validated
on a live capture-card session. Reviews found missed cues, direction switching
and tracker resets ([turn cue audit](docs/TURN_CUE_AUDIT_20261013.md)), plus at
least one early *Turn now* cue. A fix is in progress.

The full timeline is in [development history](docs/DEVELOPMENT_HISTORY.md).

Active collaborator work is recorded in the [shared agent change log](docs/AGENT_CHANGELOG.md).
The October 15 [Category 2 review prototype](docs/CORNER_TECHNIQUE.md) adds
experimental corner-phase estimates; use **Open Corner Technique Review.command** to try it.

## Technical decisions

### Why the app reads video instead of telemetry

The target setup is The Crew Motorfest on a PS4 Pro, with a USB capture card
sending video and game audio to a Mac. In that setup the app has **no game
telemetry and no wheel or pedal input data**, so it infers everything from the
pixels on screen.

We have not found a documented telemetry or "data out" feature for The Crew
Motorfest. The closest reference found was a
[SimHub community request](https://www.simhubdash.com/community-2/simhub/hopefully-telemetry-data-support-can-be-added-for-the-game-the-crew-motorfest/)
asking for support (checked October 2026). This repository does not use or
depend on any telemetry source.

Working from video alone shapes the whole design:

- **Speed is read with OCR from the speedometer.** OCR can misread: at 01:45 in
  test Video 2, an older crop read 151 km/h as "15". Readings outside 0–500 km/h
  are rejected, sudden jumps are filtered, and a measured HUD profile rejects
  partly clipped digits. Uncertain readings are marked uncertain, not guessed.
- **Turn distance comes from the minimap.** Distances are in normalized minimap
  units, not meters or seconds, because no map-scale calibration exists yet.
- **No throttle, brake or steering input is visible.** A visible slowdown does
  not prove the driver braked. So braking labels can't be learned from video
  alone, and brake/throttle advice stays off.
- **Much of the driving situation is invisible.** The app cannot see traffic,
  grip, elevation, lane position or an ideal racing line.
- **HUD positions are calibrated.** Crops assume the default Motorfest HUD on
  uncropped 16:9 video. Other layouts need their own measured profile.
- **Timestamps are receipt times.** The app knows when the Mac received a frame,
  not when the console drew it. Capture delay has not been measured.

### Driving guidance model

What runs in the main app today is mostly deterministic. Only two small
perception models are learned, and neither makes driving decisions.

1. **Perception**
   - Speedometer OCR uses Apple's Vision framework with a per-layout crop.
   - The minimap and the player's cyan marker are found by shape and color.
   - GPS-route detection is a hybrid. Deterministic yellow color/geometry
     detection runs first. If it can't form a valid route, a small learned
     segmenter (a 3×3 convolution with 20 channels, trained on reviewed masks)
     takes over. A tiny learned verifier checks short, ambiguous route pieces
     near the car. The deterministic path stays primary because it generalized
     best to a held-out recording.
   - The route becomes an ordered centerline anchored at the player marker.
     Between full detections, a lightweight tracker moves the last verified
     centerline onto the newest frame. If tracking fails, guidance is suppressed.
2. **Evidence checks** ([`CoachSafetyPolicy.swift`](Racing%20Trainer/CoachSafetyPolicy.swift)).
   Every reading is a timestamped observation marked fresh, stale, uncertain or
   missing, with a confidence and a source session. Route evidence must be at
   most 650 ms old with confidence ≥ 0.52. Speed must be at most 750 ms old,
   with confidence ≥ 0.30, and within 750 ms of the route reading. Otherwise
   guidance is withheld or reduced to direction only. These are prototype
   limits, not calibrated guarantees.
3. **Turn selection** ([`RouteTurnSelector.swift`](Racing%20Trainer/RouteTurnSelector.swift)).
   It measures the sustained change in route heading ahead of the player. A bend
   needs at least 24°. Gentle is under 42°, medium 42–80°, sharp 80–135° and
   U-turn 135° or more.
4. **Turn timing** ([`TurnGuidanceTracker.swift`](Racing%20Trainer/TurnGuidanceTracker.swift)).
   The tracker follows the closest bend through *straight → turn ahead → turn
   now → keep turning*, plus *unavailable*. *Turn now* needs all of the following:
   - at least 0.7 s of tracked approach;
   - the bend seen at least 0.08 map units away earlier in that approach;
   - the bend now within 0.035 units;
   - an estimated arrival within 0.6 s.

   History resets after gaps over 0.75 s, a direction change, or a distance jump
   over 0.075 units. These thresholds were chosen by hand, not trained.
5. **Display.** The banner shows one instruction. The wheel stays centered for
   *turn ahead* and rotates for *turn now* and *keep turning*. Missing or expired
   evidence clears the target.

Offline only (not used by the live coach):

- **Modular coach pipeline** ([docs](docs/MODULAR_COACH.md)). Native modules
  build a 2-second, 10 Hz history for each decision, keeping missing values
  explicit. A rule proposal and an independent evidence guard are kept separate.
  This powers Model Review, Analyze Video and shadow capture. Learned live output
  is switched off in code (`learnedLiveEnabled = false`).
- **Bootstrap perception classifier**
  ([docs](Training/guidance/bootstrap/README.md)). Apple Vision image features
  feed small trained softmax heads that predict current/next turn direction and
  corner phase. It was trained on 78 unreviewed AI-proposed labels from one
  11-minute recording. It has no independent test yet and is not in the app.
- **Causal temporal network.** A small NumPy network with training gates and
  benchmarks is implemented, but not trained on real labels. An optional script
  exports to Core ML, but only after a PyTorch/Core ML parity check passes.

Why it is built this way:

- **There's no ground truth for driving actions.** Without telemetry or pedal
  data, learned driving advice can't yet be trained or evaluated honestly. So
  explicit rules with evidence checks come first. Models may propose, and the
  guard can veto them.
- **Labels come from human review.** ChatGPT and Claude reviews are stored
  separately and shown as comparison columns. The training pipeline rejects them
  as labels. Agreement between AIs is not treated as approval.
- **Splits are by recording.** Train and validation sets are grouped by source
  video so that adjacent frames can't leak across the split.
- **Features are causal.** Each decision uses only observations that were
  captured *and* finished processing before the decision time. That keeps replay
  results consistent with what live play could know.
- **Literature supplies vocabulary, not thresholds.** Driver61 and Ross Bentley
  material provide corner-phase terms and a review rubric
  ([research notes](docs/RACING_LITERATURE_RESEARCH.md)). They are not
  Motorfest-specific numbers.

## Languages and frameworks

| Language | Used for | Size (October 13, 2026) |
| --- | --- | --- |
| **Swift** | The macOS app (SwiftUI, AppKit, AVFoundation, AVKit, Vision, Core Video, Core Image, Core Graphics, CryptoKit), the XCTest suite, and command-line replay/analysis tools in `Training/guidance` | 67 files, ~30,900 lines (app ~28,900; tests ~1,200; tools ~750) |
| **Python 3** | Route-model training (NumPy, scikit-learn, SciPy, Pillow), guidance training, evaluation, report tools and `unittest` suites. PyTorch is needed only for the optional Core ML export | 22 files, ~3,900 lines |
| **Bash** | Build/test wrappers, launchers and replay scripts in `scripts/` | 15 files, ~200 lines |
| **JavaScript, HTML, CSS** | A small local browser review tool in `Training/guidance/review/web`, served by `server.py` | 3 files, ~340 lines |
| **JSON** | Trained route-model weights, training reports, review bundles and saved AI reviews | 17 files |

The app targets macOS and builds with Xcode. It has no third-party Swift
package dependencies.

## Repository layout

| Path | Contents |
| --- | --- |
| `Racing Trainer/` | App source |
| `RacingTrainerSafetyTests/` | XCTest suite (runs without launching capture) |
| `Training/` | Route segmenter/verifier training scripts, weights and reports |
| `Training/guidance/` | Guidance tooling: `bootstrap`, `modular`, `review`, `teacher`, `literature` |
| `scripts/` | Build, test, launch, replay and analysis scripts |
| `docs/` | Design notes and dated reports |
| `data/` | **Local only, git-ignored**: recordings, evidence, packaged test builds and review journals |

## Build and test

Requirements: macOS with Xcode. No Apple signing identity is needed for the
Debug build.

```sh
bash scripts/check.sh build
bash scripts/check.sh test
```

Python tests need Python 3 with NumPy and Pillow (verified with 3.12):

```sh
python3 -m unittest discover -s Training/guidance/bootstrap -p 'test_*.py'
python3 -m unittest discover -s Training/guidance/modular -p 'test_*.py'
python3 -m unittest discover -s Training/guidance/review -p 'test_*.py'
```

These are contract and regression tests. They do not measure OCR accuracy,
cue timing quality or live capture behavior.

To run the app manually, open `Racing Trainer.xcodeproj`, build and run. Then
choose the capture card or **Open Video File…** from the source menu (labeled
**Live Input** or **Test Video**).
Under **Guidance**, choose the HUD layout and speed unit that match the footage.
Open Model Review with **Model Review → Show Model Review** (Shift–Command–R).

`Open Racing Trainer.command` and `Open Guidance Review.command` launch a
packaged test build from the local `data/` folder. That folder is not in the
repository, so on a fresh clone use Xcode instead.

## Route states

- **COACH READY**: the ordered path passed every critical confidence check.
- **SET A WAYPOINT**: the minimap and player marker exist, but no route does.
- **ROUTE UNCERTAIN**: route evidence exists but is unsafe to interpret.
- **GUIDANCE STALE**: no recent enough path result exists.
- **MINIMAP / GAMEPLAY NOT FOUND**: the HUD is hidden, moved, cropped, in a
  menu or transition, or doesn't match the calibrated layout.

Route readiness and turn-timing readiness are separate. The route can be ready
while turn timing is unavailable.

## Build the route-mask dataset

1. Load a full 16:9 Motorfest recording or use live capture.
2. In the right sidebar, press the red record button under **Minimap Dataset**.
3. Play footage with waypoint routes, no waypoint, and varied scenery.
4. Stop recording. Each saved crop gets a same-sized automatic binary mask.
5. Press the paintbrush button in **Route Mask Dataset**.
   - Use **Generate Missing** when older crops have no automatic mask.
   - Use **Regenerate Pending** to replace stale automatic masks after a
     detector update. Accepted and corrected samples are kept.
6. For each sample:
   - **Accept Prediction** if magenta covers only the yellow GPS trail;
   - use **Brush** or **Eraser**, then **Save Corrected Mask**, if it is wrong;
   - use **Approve as No Route** for a visible minimap with no waypoint;
   - **Reject Sample** if the minimap is missing, moved, obstructed or unusable.
7. Export reviewed pairs when the seed set is ready.

The export keeps every frame from one source video in the same split.

The reviewed export has 582 image/mask pairs. In the offline audit, color
geometry alone found the route in 510 of 526 route frames, with no false route
in 56 no-route frames. Adding the verified short-route recovery raised that to
524 of 526, still rejecting all 56 no-route frames. These are results on the
development dataset, not proof of generalization. The newer 39-frame held-out
recording has no no-route examples, so specificity on unseen footage is
unmeasured. Full report: `Training/hybrid_detector_audit.json`.

## Route-overlay performance

The minimap pipeline is capped at 30 FPS and never queues a backlog. While a
full detection runs, only the newest frame is kept, and the tracker moves the
verified centerline onto it. The **Frame Analyzer** panel shows **Map FPS**
(actual vs. ceiling, e.g. `27.5 / 30.0`) and **Map Time** (processing time on
this Mac).

## YouTube and other sources

A YouTube watch-page URL can't provide decoded frames to AVFoundation. Use a
local recording you're allowed to use, or send a full-screen browser source
through OBS Virtual Camera.

## Known limitations

- HUD crops are calibrated for the default 16:9 Motorfest HUD plus one measured
  reference-recording profile (test Video 2).
- The route detector needs testing across more cars, weather, regions, display
  modes and capture devices. The short-route policy is calibrated from few
  failure cases.
- Turn timing uses hand-set thresholds in normalized map units. The minimap
  bend onset is not a physical turn-in point.
- Route gaps are bridged only when endpoints are close and aligned. Ambiguous
  intersections correctly produce ROUTE UNCERTAIN.
- Steering is categorical. The minimap can't provide real G29 wheel degrees, an
  ideal racing line or lane corrections by itself.
- The road-marking overlay is an image-space estimate, not a lane or clearance
  guarantee.
- App icon, bundle identity, signing, sandbox entitlements, privacy text and
  release testing are still needed before App Store distribution.

## Roadmap

The system design and roadmap (v2, September 24, 2026) are kept outside this
repository. In short:

1. Establish the canonical baseline and verify dataset locations.
2. Add safety contracts, automated tests and integration regression coverage.
3. Build deterministic replay and recording-level evaluation splits.
4. Recover speed OCR and measure errors, coverage and latency.
5. Evaluate route generalization; adopt pretrained models only if all gates pass.
6. Calibrate stable coaching, then add local voice output.
7. Validate three complete capture-card sessions on the M4 MacBook Air.
8. Address public distribution after the dependable local milestone.

Next for turn guidance: one shared bend identity for the banner and wheel,
direction confirmation across frames, approach tracking that survives brief
glitches, and scoring missed, false, early and late cues on reviewed intervals.

Lane/obstacle perception, exact wheel degrees, automated input, other games and
screen capture are deferred.

## Licensing

No license has been chosen yet. Publishing code in a public repository does not
by itself make it open source; choose a license before presenting it as an
open-source release.
