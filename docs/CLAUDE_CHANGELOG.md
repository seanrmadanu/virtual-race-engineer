# Claude change log

Every change Claude makes to this project is logged here, newest first, so ChatGPT/Codex and Claude stay in sync. Each entry lists the files touched, why, how it was verified, and anything the other side needs to act on.

**Ownership (set by the user, October 14, 2026):**

- ChatGPT/Codex owns the guidance model: `TurnGuidanceTracker`, `LiveTurnGuidance`, `RouteTurnSelector`, `CoachSafetyPolicy`, `ModularCoach`, and the minimap detectors.
- Claude owns road-line detection (`RoadLineDetector`, `RoadLineOverlay`) and the steering-wheel animation (`SteeringWheelMotion`, plus the wheel section of `TrainerCoachHUD`).
- When Claude has to touch a file outside that list, the entry says so explicitly.

**Working copies (from October 15, 2026):**

- `Racing Trainer-3/` is the shared copy ChatGPT works in.
- Claude develops further road-line work in a separate copy, `Racing Trainer-3-claude/`, next to it in the project root.
- Changes reach `Racing Trainer-3/` only when they are finished and verified. Each one gets an entry here naming exactly which files were copied over.

---

## 2026-10-15 (round 2) — Still lines when stopped, smooth drawing, steadier wheel, app renamed "Claude" (Claude's copy only)

**Where:** `Racing Trainer-3-claude/` only. **Nothing in `Racing Trainer-3/` changed** except this log.

**User feedback:** lines don't stay still when the car is stopped, aren't smooth in motion, and look buggy. Fix the shade dropouts and the wheel. Rename the app to Claude.

**Changes:**

| File | Change |
| --- | --- |
| `RoadLineTracker.swift` | Line ends smooth more slowly (180 ms). A lane, once filled, stays paired on looser overlap/width checks (hysteresis). A lane boundary stays the same line while that line remains visible on the same side, so a nearer streak can't steal it. New `RoadOverlayAnimator`: fades lines and fill in (0.12 s) and out (0.25 s), and crossfades when a boundary moves to a different painted line (more than 0.03 of frame width). |
| `RoadLineDetector.swift` | Car mask widened to x 0.315–0.685: the car's own body edge was being paired as the right lane line. Lines shorter than 0.10 of frame height can't be lane boundaries. A line must head toward the horizon along its whole length (rejects the game's floating GPS ribbon and shadows across the road). `lane(keepPaired:)` parameter. |
| `RoadLineOverlay.swift` | Redraws every display frame (`TimelineView(.animation)`) from `RoadOverlayAnimator` output. |
| `SteeringWheelMotion.swift` | New `SteeringWheelTargetFilter`: bend size smoothed (0.35 s); a route gap up to 0.6 s keeps the last size instead of jumping to the 45°/120° fallback. Spring responsiveness 8 → 6.5. |
| `TrainerCoachHUD.swift` | Uses the filter (`@State wheelTarget`). |
| `RoadTrackingTests.swift` | +3 tests: fades don't pop, crossfade on switch, wheel size kept through route gaps and smoothed. |
| `project.pbxproj`, `ContentView.swift`, `scripts/check-modular-local.sh` | App renamed: product **Claude** (`Claude.app`), bundle ID `NoName.Racing-Trainer.claude`, window title "Claude". Module name stays `Racing_Trainer`. |
| `Training/road/RoadStability.swift`, `WheelTrace.swift`, `scripts/road-stability.sh`, `scripts/wheel-trace.sh`, `scripts/open-claude-build.sh` | Measurement suite (6+ fixed clips, stopped and moving) and wheel trace through the real analyzer; launcher points at `Claude.app`. |

**Results:**

- **Stopped (Video 2, tunnel, 3:37):** lane fill on 99% of frames with 1 blink (was 2% with 14 blinks), lines move ≤ 0.6 px. Line ends were jumping up to 17 px; now 0.3 px (95th percentile).
- **Drawn output:** the largest one-frame change in the lane fill is now 0.14–0.27. It used to be 1.0, a full pop.
- **Wheel**, 24 s of Video 2 at 152–176 s through the real analyzer: direction reversals 30 → 8, with 13 instruction changes; target jumps over 30° 5 → 2; peak wheel speed 229 → 170°/s.

**Tried and reverted:**

- Lowering the paint brightness floor for shade: no shade gain, and the stopped tunnel dropped to 19% lane fill.
- Raising the asphalt brightness cap for glare: neutral to worse.

In the glare clip, the yellow line runs mostly behind the speedometer dial, which is deliberately masked, so that dropout is a HUD-layout limit.

**Verified:**

- 142 tests pass in Debug and Release.
- `check-live-guidance.sh` at 152–176 s passes with the same key transitions.
- Before/after videos (top = before): `data/guidance/road-tracking-20261015/road-lines-round2-moving-stopped-shade.mp4`.
- App: `data/guidance/road-tracking-20261015/app-claude/Claude.app`, left open on Video 2 at 2:40.

**Note:** compiling straight after a file copy sometimes fails with "input file was modified during the build", because the project lives in iCloud Documents. Re-running fixes it.

---

## 2026-10-15 — Road lines: frame-to-frame tracking, every-frame updates (Claude's copy only)

**Where:** `Racing Trainer-3-claude/` only. **Nothing in `Racing Trainer-3/` was changed** except this log.

**Problem the user reported:** the road lines were slow and not smooth. Measured causes:

1. They updated only when a full minimap analysis ran: 30/s in Release on 60 fps video, about 4/s in Debug.
2. Each frame was solved from scratch, so each lane line blinked on and off 100–170 times per 10 s of video, with occasional 200+ px jumps to a different line.

**Changes in Claude's copy:**

| File | Change |
| --- | --- |
| `Racing Trainer/RoadLineTracker.swift` (new) | Follows lines between frames. Matches by median distance; glides to new positions (45 ms time constant); a line is shown only after 4 hits and recent presence ≥ 0.3; held up to 0.5 s through dropouts for display only; merges duplicates; keeps the same lane lines unless another is clearly closer; resets on seek, backwards time or a >0.5 s gap. Outputs `observation` (lines with paint support in this frame only, for guidance) and `display` (for drawing). |
| `Racing Trainer/RoadLineDetector.swift` | Split into reusable stages (`markingCurves`, `laneSides`, `lane`). The last frame's lines are tried first as hypotheses and can be re-found with 5 rows of paint instead of 8. When two lane lines can't be paired, both are still returned (unpaired, `hasCorridor` false) instead of dropping one. Bright blue sky no longer counts as road surface. |
| `Racing Trainer/FrameAnalyzer.swift` (ChatGPT-owned; changed only in Claude's copy) | Road detection moved out of `analyzeMinimap` to its own `roadAnalysisQueue`. It runs on every incoming frame and skips a frame only while the previous one is still processing. It publishes `roadLines` (strict) and the new `roadDisplay`. Guidance gets the newest strict observation captured at or before its minimap frame (`roadObservationLocked(atOrBefore:)`). Reset clears both. |
| `Racing Trainer/TrainerCoachHUD.swift` | The overlay draws `analyzer.roadDisplay`. |
| `RacingTrainerSafetyTests/RoadTrackingTests.swift` (new) | 5 tests: confirmation and hold, glints never shown, jitter smoothed but drift followed, seek reset, lane hysteresis. |
| `project.pbxproj` | `RoadLineTracker.swift` added to the test target (`AC0000000000000000000003/4`). |
| `Training/road/*`, `scripts/road-lag-benchmark.sh`, `scripts/open-claude-build.sh` | Measurement tools and a launcher. `scripts/check-live-guidance.sh` in the copy also compiles `RoadLineTracker`. |

**Results (Claude's copy):**

| Measure | Before | After |
| --- | --- | --- |
| Road-line updates/s with the real `FrameAnalyzer` fed 60 fps video, Release | 30 | **60** |
| Same, Debug | 3.7 | 13.8 |
| Age of drawn lines (median, Release) | 3 ms | 3 ms |
| Drawn-line on/off flips per 10 s, 5 clips | 47–171 | **1–28** (mostly under 15) |
| Steady-line jitter (median) | — | 0–2 px |
| Detector cost | 1.4 ms/frame Release | unchanged (tracker cost negligible) |
| Guidance updates/s, Debug | 3.9 | 4.3 (unaffected) |

**Verified:**

- **139 tests pass in Debug and Release**: ChatGPT's 134 plus 5 new.
- `check-live-guidance.sh` on Video 2 at 152–176 s gives exactly the same output as before: 240 frames, the same stage counts, and the same Turn right / Follow bend / Go straight times.
- Before/after video: `Racing Trainer-3-claude/data/guidance/road-tracking-20261015/road-lines-before-top-after-bottom.mp4`. The app build is in the same folder. It was left open on Video 2 at 2:40.

**Proposal for ChatGPT (not applied to `Racing Trainer-3/`):** the `FrameAnalyzer` change above. It needs `RoadLineTracker.swift`, the new detector stages, and the HUD line. Guidance semantics are unchanged: guidance still only sees lines with paint in a frame at or before its minimap frame. If you want it, take these files from Claude's copy: `FrameAnalyzer.swift`, `RoadLineDetector.swift`, `RoadLineTracker.swift`, `TrainerCoachHUD.swift`, `RoadTrackingTests.swift`, plus the 3 pbxproj lines `AC…03/04`. Don't take them if you've changed those files since.

**Sync note:** at 04:10 Claude copied ChatGPT's newer Category 2 files (`CornerTechnique*`, scripts, docs, project file) into Claude's copy, so it builds against current ChatGPT code. Claude's files were not overwritten.

---

## 2026-10-15 — Handed `Racing Trainer-3/` back to ChatGPT

At the user's request, Claude stopped working in this folder.

- Claude created its own copy, `../Racing Trainer-3-claude/`.
- ChatGPT has the green light to rebuild this folder with only the features it needs. The handoff note, with the exact list of Claude's changes and revert steps, is `docs/HANDOFF_FROM_CLAUDE_20261015.md`.
- Revert check: applying those steps to a scratch copy of the current sources builds, and 123 tests pass.
- No other files were changed in this step.

---

## 2026-10-15 — Fixed "Guidance unavailable" caused by the slow road detector

**Problem.** In the Debug build that was launched, guidance showed "Guidance unavailable" and the road lines lagged.

**Cause (Claude's bug).** The detector from 2026-10-14 was slow:

| Build | Old detector | 10-14 detector |
| --- | --- | --- |
| Debug | 3.5 ms/frame | 216 ms/frame |
| Release | 0.2 ms/frame | 5.6 ms/frame |

`FrameAnalyzer.analyzeMinimap` runs road detection *before* minimap detection on the same queue, so the slow detector delayed route evidence past its freshness limit. A Debug build of `scripts/check-live-guidance.sh` on Video 2 at 160–176 s showed "Fresh route evidence is missing" through the whole turn and failed with "No upcoming cue was published". The same build with the old detector passed.

**Fix.** Changed one file, `Racing Trainer/RoadLineDetector.swift`. Detection behaviour and the API are unchanged.

- The candidate search uses raw float buffers, and the HUD/car exclusions are computed once per row as x ranges (`excludedRanges`, which matches `isExcluded`).
- Fitting uses running least-squares sums solved by Cramer's rule, walks pre-sorted points with no per-hypothesis arrays, sets or sorts, and runs 160 hypotheses per round instead of 400.

**Result:** 1.4 ms/frame in Release (was 5.6 ms), about 30 ms/frame in Debug (was 216 ms). Coverage, sampling one frame every 3 s from 40–610 s:

| | Corridor before → after | Frames with a boundary before → after |
| --- | --- | --- |
| Video 1 | 38 → 36 | 156 → 154 |
| Video 2 | 30 → 33 | 161 → 161 |

**Verified:**

- 122 Release native tests passed, zero failures.
- `check-live-guidance.sh` on Video 2 at 160–176 s passes in Release: 160 frames, 2 unavailable (start-up confirmation only).
- The same check also passes in a Debug build.
- Logs are in `data/guidance/road-steering-20261014/`: `build-tests-release.log`, `live-smoke-fast-release.log`, `live-smoke-fast-debug.log`.
- Release app: `data/guidance/road-steering-20261014/app-release/` (executable SHA-256 is in `executable.sha256`). It was left open on Video 2 at 2:40.

**For ChatGPT:**

- Road detection still runs inside `analyzeMinimap`, so road lines update only when a full minimap analysis runs. That is why they look less smooth than the video. Claude will prototype a separate road queue that runs on every input frame in `Racing Trainer-3-claude/`.
- That change touches `FrameAnalyzer.swift`, which ChatGPT owns, so it will be proposed here before being copied into the shared tree.
- Prefer Release builds when judging live guidance timing. Debug builds are much slower everywhere.

---

## 2026-10-14 — Road-paint detection, overlay, and wheel animation

The full write-up is in `docs/GUIDANCE_REVIEW_UPDATE.md`, section "October 14 road-paint detection and wheel animation (Claude)".

**Files:**

- `Racing Trainer/RoadLineDetector.swift`: rewritten. It detects white and yellow paint and adds an optional `RoadLineObservation.markings` field. Existing fields keep their meaning.
- `Racing Trainer/RoadLineOverlay.swift`: rewritten. Lines are drawn in their paint colour, the lane tint is clipped around the car, and lines fade with age. It takes a new `camera` parameter.
- `Racing Trainer/TrainerCoachHUD.swift`: the wheel section now uses an animated angle target, and the overlay call passes the camera.
- `Racing Trainer/SteeringWheelMotion.swift`: new. It holds `SteeringWheelTarget` (illustrative angle from the cue plus minimap route) and `SteeringWheelMotion` (spring with a speed limit, dropout hold, and Reduce Motion support).
- `RacingTrainerSafetyTests/RoadSteeringTests.swift`: new, 11 tests.
- `Racing Trainer.xcodeproj/project.pbxproj`: one change, adding `SteeringWheelMotion.swift` to the test target (ids `AC0000000000000000000001/2`).

The originals are backed up in `data/guidance/road-steering-20261014/baseline-source/`.

**For ChatGPT:**

- `currentBendDirection` needs paired paint covering y 0.50–0.70. The visible paired span is usually 0.10–0.15 tall, so that Turn Now gate still almost never fires.
- Shortening the window was tried and rejected: it got about 1 in 4 directions wrong.
