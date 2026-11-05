# Shared agent change log

Read this before editing the app. Record each work session's files, behavior changes,
tests, limitations, and handoff here. Existing uncommitted changes can belong to
another active agent; preserve them and re-read shared files before patching.

Earlier work: [Guidance review updates](GUIDANCE_REVIEW_UPDATE.md), including
Claude's October 14 road-paint and steering-wheel changes.
Claude maintains [its own detailed log](CLAUDE_CHANGELOG.md); read both. Its
October 15 entry establishes a separate `Racing Trainer-3-claude` development
copy and reserves road detection/wheel work for Claude. Codex handles guidance
and the Category 2 review work below.

## 2026-10-15 — Codex — Category 2 phase-review increment complete

Requested by Sean after Category 1. Claude is concurrently working on the app;
`RoadLineDetector.swift` was modified at 03:37 PDT. Codex's scope is the Category 2
review pipeline, not the road detector, wheel, main HUD, or live guidance tracker.

Implemented: a separate causal route-phase estimator, saved Category 2 samples
and review readout, transition timestamps, focused tests, and native video checks.
Integration files: `ModelReviewModels.swift`, `GuidanceVideoAnalyzer.swift`,
`ModelReviewStore.swift`, `ModelReviewView.swift`, the Xcode test source list,
and CLI script source lists. New phase estimates remain experimental and separate
from historical learned phase labels and Category 1 steering cues. No apex,
racing-line, braking, or throttle claim is implied.

### Changes made

| Files | Change |
| --- | --- |
| `Racing Trainer/CornerTechnique.swift` (new) | Separate versioned phase vocabulary and validated evidence/expiry metadata; no apex/control output |
| `Racing Trainer/CornerTechniqueTracker.swift` (new) | Causal approach/entry/in-bend/exit progression from near-route geometry and fresh motion evidence; median filter, direction confirmation, easing confirmation; source/seek/missing/stale reset |
| `Racing Trainer/CornerTechniqueReadout.swift` (new) | Phase and separate upcoming-bend readout, reasons, and explicit experimental status |
| `Racing Trainer/GuidanceVideoAnalyzer.swift` | Two-second causal warmup for Category 2; 10 Hz phase trace and exact phase-start events; pipeline identity updated |
| `Racing Trainer/ModelReviewModels.swift` | Optional event/sample stream, consistency validation, causal playhead lookup, Category 2 summary, and separate `cornerPhase` correction; historical labels untouched |
| `Racing Trainer/ModelReviewStore.swift` | Playhead phase, phase-start filter, Next Phase, filtered Save & Next, Category 2 startup flag |
| `Racing Trainer/ModelReviewView.swift` | Category 2 readout, tenth-second replay controls, phase filter, correction picker and review instructions |
| `RacingTrainerSafetyTests/CornerTechniqueTests.swift` (new) | 12 regression tests for transitions, separate next bend, startup, noise, duplicate/stale/future/wrong-session evidence, resets, bundle compatibility, expiry and corrections |
| `Racing Trainer.xcodeproj/project.pbxproj` | Adds both Category 2 model/tracker files to the hostless test target using `AD100…01`–`AD100…04`; preserves Claude's wheel registration |
| `scripts/analyze-video.sh`, `check-live-guidance.sh`, `check-review-visibility.sh`, `replay-turn-timing.sh`, `check-modular-pilot.sh` | Registers new source dependencies for existing CLI builds |
| `Training/guidance/modular/CornerTechniqueChecks.swift`, `scripts/check-corner-technique.sh` (new) | Real store integration check with isolated unreviewed drafts; original video, phase navigation, backward seek, and off-screen readout render |
| `Open Corner Technique Review.command`, `scripts/open-corner-technique-review.sh` (new) | Separate Release review launcher, Category 2 selected, prepared Video 2 interval and separate user-review directory |
| `README.md`, `docs/MODEL_REVIEW.md`, `docs/CORNER_TECHNIQUE.md` (new), this log and `docs/GUIDANCE_REVIEW_UPDATE.md` | Discoverability, current curriculum, use instructions, verification, limits, and cross-agent handoff |

### Verified

- **134 native tests passed in Debug and Release**, including all 12 new Category 2 tests. Full app builds passed. Existing unrelated concurrency/Codable/deprecation warnings remain.
- Native video analysis: **240 samples** from Video 2 (152–176 s) and **160 samples** from Video 1 (80–96 s). The final Video 2 run exercises all six states. Counts and initial/final comparisons are in `comparison.json`; these are not accuracy scores.
- The actual `ModelReviewStore` passed phase filtering, draft persistence without promotion to reviewed labels, category separation, exact video identity, Next Phase, backwards seeking and phase/readout synchronization.
- The actual readout was rendered with an off-screen `NSHostingView` and visually checked. The initial `ImageRenderer` attempt omitted AppKit-backed GroupBox content; that blank artifact is superseded by `store-qa-final/corner-technique-readouts.png`. No screen-control access was used or requested.
- All **63 Swift/project files** matched the exact Release test copy before packaging. Release executable SHA-256: `e1d7c00eb783f71fbb929c69ebb25649227e164f34dbea883a4863ef359ac546`.
- Build/analysis first attempts inside the sandbox were blocked by SwiftUI compiler-plugin and AVFoundation decoder access. Authorized reruns outside the sandbox passed; diagnostic logs are retained.

Evidence root: `data/guidance/category2-20261015/`. The launcher uses
`verified-app-release/Racing Trainer.app` and `video2-final/video.review.json`.
Baseline copies, exact manifests, logs, traces and QA-only draft journals are retained.

### Handoff / remaining work

This delivers **Category 2 review**, not a live technique coach. Phase timing needs
independent human review; route/OCR dropouts remain. Apex, racing line, braking,
throttle and live HUD integration are not implemented by this increment. Historical
phase labels and frozen AI reviews have not been modified or used as training labels.
The new correction field has no training consumer yet.

The prepared Video 2 bundle covers **2:32–2:56 only**; moving outside it correctly
shows no fresh phase sample. Analyze Video creates another range/run. Existing
main/review launchers were not changed in this session, and no running app was
replaced. Claude can continue road/wheel work in its separate copy; the current
phase tracker does not consume road-line output. See `CORNER_TECHNIQUE.md` for the
next evaluation tasks.

Related report: the earlier Codex investigation of “Guidance unavailable” was
interrupted. Claude subsequently documented and fixed a slow Debug road detector
that delayed minimap evidence past its freshness limit. See its October 15 log
for the reproduction, timing measurements, and Debug/Release checks. Codex did
not modify the detector in this session. The tested Category 2 copy includes
Claude's integrated optimization.
