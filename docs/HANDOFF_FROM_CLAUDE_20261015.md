# Handoff from Claude: green light for ChatGPT (October 15, 2026)

**Status: Claude is done in this folder.** ChatGPT/Codex has the green light to rebuild `Racing Trainer-3/` however it needs to: keep, rewrite, or remove anything Claude added. Claude will not edit this folder again unless the user asks. The one exception is appending entries to `docs/CLAUDE_CHANGELOG.md`, so ChatGPT can always see what Claude is doing in its own copy.

Claude now works only in a separate copy: `../Racing Trainer-3-claude/`, next to this folder. It was copied from this tree on October 15, 2026, including Claude's changes listed below. Its git history is a local copy, and Claude will not push from it. Road-line and wheel-animation work continues there. If anything from it is wanted later, it will be offered as a specific, logged set of files in `docs/CLAUDE_CHANGELOG.md`. Nothing is merged automatically.

## Everything Claude changed in this folder

Only these files. No guidance-model, tracker, selector, policy or `FrameAnalyzer` code was edited.

| File | Change |
| --- | --- |
| `Racing Trainer/RoadLineDetector.swift` | Rewritten: detects white and yellow paint. Adds optional `RoadLineObservation.markings` and `RoadLineDetector.chaseCarRegion` / `excludedRanges`. |
| `Racing Trainer/RoadLineOverlay.swift` | Rewritten: lines in paint colour, lane tint clipped around the car, fade-out. Adds a `camera` parameter. |
| `Racing Trainer/TrainerCoachHUD.swift` | Wheel section only: animated `SteeringWheelTargetView`. The overlay call passes `camera:`. |
| `Racing Trainer/SteeringWheelMotion.swift` | **New file**: wheel target angle and spring animation. |
| `RacingTrainerSafetyTests/RoadSteeringTests.swift` | **New file**: 11 tests. |
| `Racing Trainer.xcodeproj/project.pbxproj` | 3 added lines with ids `AC0000000000000000000001` / `AC0000000000000000000002`: `SteeringWheelMotion.swift` in the test target. |
| `docs/GUIDANCE_REVIEW_UPDATE.md` | Appended section "October 14 road-paint detection and wheel animation (Claude)", plus a closing pointer paragraph. |
| `docs/CLAUDE_CHANGELOG.md`, this file | New docs. |
| `data/guidance/road-steering-20261014/` | Evidence, baseline backups, and a Release app build. |

## To remove all of Claude's code changes

1. Copy `RoadLineDetector.swift`, `RoadLineOverlay.swift` and `TrainerCoachHUD.swift` from `data/guidance/road-steering-20261014/baseline-source/` back into `Racing Trainer/`. These are the exact October 13 versions, before Claude's edits.
2. Delete `Racing Trainer/SteeringWheelMotion.swift` and `RacingTrainerSafetyTests/RoadSteeringTests.swift`.
3. Delete the 3 lines containing `AC000000000000000000000` in `project.pbxproj`.
4. Optionally remove the Claude section from `docs/GUIDANCE_REVIEW_UPDATE.md`.

After the revert, the old road detector is fast again (about 0.2 ms per frame), but it finds a lane in only about 3 of 191 sampled frames per test video, and it misses yellow centre lines. The live guidance output on Video 2 at 152–176 s was identical with either detector.

**Checked on October 15:** Claude applied steps 1–3 to a scratch copy of this folder's current sources, then ran `scripts/check-modular-local.sh`. The Debug build succeeded and **123 tests passed with zero failures**. That count includes the tests ChatGPT has added since October 14. Nothing in ChatGPT's newer code depends on Claude's files.

## If you keep Claude's road detector instead

- Use a Release build to judge timing. The October 15 version takes about 1.4 ms per frame in Release and about 30 ms in Debug.
- `currentBendDirection` still needs paired paint covering y 0.50–0.70. The visible pair is usually only 0.10–0.15 tall, because the minimap dial hides the right edge line. So it rarely gates Turn Now.
- Road detection runs inside `analyzeMinimap`, so road lines refresh only at the full minimap-analysis rate.
