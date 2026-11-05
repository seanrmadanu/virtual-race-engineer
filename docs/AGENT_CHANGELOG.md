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

## 2026-10-15 — Codex — curve animation and canonical app cleanup (complete)

Sean reported wheel twitching in a 58.75-second desktop recording. Claude's
`HANDOFF_FROM_CLAUDE_20261015.md` now grants the canonical tree to Codex; the
older scope reservation above is superseded. Claude's separate copy remains
unmerged. Inspected the supplied video and saved overview/quarter-second wheel
frames under `data/guidance/ui-rebuild-20261015/` (source video is not modified).

- `SteeringWheelMotion.swift`: removes uncalibrated, per-frame minimap-angle
  scaling. Stable bend/turn cues have stable illustrative targets (45/120 degrees).
  Freshness and upcoming-turn behavior retained. Exact damped spring, bounded
  speed, duplicate/backward-time rejection, source reset, and freeze-on-dropout.
- `SteeringWheelView.swift` (new), `TrainerCoachHUD.swift`: extracts wheel rendering;
  advances motion from display tick callbacks rather than view body evaluation;
  resets on source generation changes, removes the jumping raw-target arrow,
  prevents inherited SwiftUI rotation animations. Unavailable display dims.
- `RacingTrainerSafetyTests/RoadSteeringTests.swift`: updates cue contract tests;
  adds frame-rate, dropout, source reset, duplicate time, and reversal regressions.

Baseline files retained in the evidence folder before edits. Final verification is below.

### Cleanup and completion

| Files | Change |
| --- | --- |
| `ContentView.swift`, `TrainerSidebar.swift` (new) | Practice/review/audio sidebar; removed disconnected Trainer Voice state; direct category navigation; diagnostics opened on demand instead of observing analyzer updates in the sidebar |
| `TrainerDiagnosticsView.swift` (new) | Live Input and Datasets tabs, explicit Done/Escape dismissal; retains current recording and route-mask editing |
| `TrainerCoachHUD.swift` | Removes inactive pedal card, visibility preferences and obsolete action palette; delegates wheel rendering to the new view |
| `SteeringWheelView.swift` | Pauses display ticks once settled; preserves hub geometry and editor support; labeled illustrative direction and Reduce Motion behavior |
| `Racing_TrainerApp.swift` | Moves the older comparison lab's player ownership into its window; shares category-review store with practice navigation |
| `ModelReviewView.swift` | Removes empty Advanced placeholder tab/pane; category data vocabulary retained for old bundles |
| `Training/legacy-ui/*` (new archive), removed `Racing Trainer/DatasetLabelerView.swift` | Archives unreachable legacy dataset counter and its only labeler UI; no data/model deletion |
| `Training/guidance/modular/SteeringWheelChecks.swift`, `scripts/check-steering-wheel.sh` (new) | Actual FrameAnalyzer replay, stale/reset/no-pedal assertions, optional archived comparison, and off-screen production-view renders; frozen compiler inputs and a real asset catalog |
| `scripts/open-racing-trainer.sh`, `open-guidance-review.sh`, `open-corner-technique-review.sh` | All three launch the same verified current Release package; existing review bundles/journals preserved |
| `README.md`, `docs/STEERING_AND_APP_CLEANUP.md`, `docs/GUIDANCE_REVIEW_UPDATE.md`, this log | Current navigation, reproduction, verification, limitations and collaboration handoff |

Verified: **138 native tests passed** in Debug for the wheel change and in Release
for the final cleaned app. Native Video 1 replay exercised **600 frames**, including
279 active steering frames. On identical analyzer output, old same-cue target
changes were **38**, new changes **0**. Stale/source-reset/no-pedal assertions passed.
This measures stability, not correctness of the coaching instructions.

The final **66 source/test/project/scheme files match** the tested copy at
`/private/tmp/racing-modular-source.Dv26DH`. Packaged executable SHA-256:
`b32c2495c90db55888f02e1ab0b6b1ad569576fba011d6be97bc93a711840154`.
Evidence, baseline backups, logs, trace, comparisons and manifest are in
`data/guidance/ui-rebuild-20261015/`. Light/dark sidebar and all wheel poses were
visually checked off screen. The initial render lacked Assets.car; the completed
asset-backed preview supersedes it. A CLI compilation also saw shared-folder
input timestamp changes; the check now builds frozen temporary source copies.

**Status: complete for the reported wheel jitter and this cleanup increment.**
Category 2 remains the previously tested review prototype. Further work should
independently judge its phase timing before live integration. Road perception
from Claude's separate copy is not merged. No existing running app was stopped,
no global settings were rewritten, and no screen-control access was requested.

## 2026-10-15 — Codex — rename app to `chatgpt`

Sean requested the exact lowercase name `chatgpt`.

- `Racing Trainer.xcodeproj/project.pbxproj`: Debug/Release product, built app,
  display name and capture permission descriptions renamed; Swift module name
  explicitly retained. Bundle identifier stays `NoName.Racing-Trainer` so the
  app continues using its existing settings/data identity.
- Shared Xcode scheme: launch/profile/build references now name `chatgpt.app`;
  project/target/scheme directory names remain compatible with build scripts.
- `ContentView.swift`, `ModelReviewView.swift`, `RouteMaskEditorView.swift`,
  `CaptureSessionManager.swift`, `SettingsView.swift`: visible title, fallback
  subtitle, reviewer window, errors and permission instructions use `chatgpt`.
- `Open chatgpt.command` (new preferred shortcut); existing app/review launchers
  target `data/guidance/app-rename-20261015/verified-app-release/chatgpt.app`.
  The old main shortcut remains compatible. Historical build launchers and
  datasets retain their original paths.
- `scripts/check-modular-local.sh` reports the renamed build product; README
  documents the name and preferred shortcut.

Verification complete: **138 native tests passed in Release**. All 66
Swift/test/project/scheme files match the tested copy. Inspected the packaged
Info.plist: CFBundleName, CFBundleDisplayName and CFBundleExecutable all equal
`chatgpt`; bundle identifier remains `NoName.Racing-Trainer`. The renamed
executable and asset catalog exist, all three current launchers resolve to it,
and launcher shell syntax checks pass. No guidance behavior was changed.

Evidence: `data/guidance/app-rename-20261015/release-tests.log` and
`verified-release.json`. Packaged executable SHA-256:
`af8dbdcfd0c4ca845c1872dd401ee3fa2ed9341c2fa671a4d902989ca368643a`.

Local iCloud hydration was required to finish the rename source comparison;
all 66 tested source files matched after download.

## 2026-10-15 — Codex — Category 3 linked turns (complete review increment)

Sean requested the next turn-guidance categories. Scope: experimental visible-route
sequences (left then right / right then left), integrated into recorded Model Review.
Current vehicle phase stays separate. No pedal, wheel, live-category promotion,
trained weights, or changes to Claude's separate copy. Existing source/WIP preserved.

Implemented:

| Files | Change |
| --- | --- |
| `LinkedTurns.swift` (new) | Versioned sequence vocabulary/sample and causal tracker; confirms first two separated opposite bends, refuses stale/missing evidence, duplicate renewal and skipped bends |
| `RouteTurnSelector.swift` | Extracts the existing scan for reuse; existing turn selection behavior retained and replay-compared against the saved baseline |
| `GuidanceVideoAnalyzer.swift` | Category 3 warm-up, 10 Hz stream, trace field, sequence-start review moments, pipeline-version bump |
| `ModelReviewModels.swift` | Optional event/stream fields, validation and playback expiry; separate `linkedTurnPattern` feedback; existing `advanced` identifier retained |
| `ModelReviewStore.swift` | Category 3 filtering, current playhead sample, Next Sequence, CLI category selection and draft persistence |
| `ModelReviewView.swift`, `LinkedTurnReadout.swift` (new) | Category 3 appears only with actual analysis data; visible sequence and current phase separated; correction picker and review instructions |
| `RacingTrainerSafetyTests/LinkedTurnTests.swift` (new), project.pbxproj | 13 regressions for sequence order, single/angled corners, no-speed preview, confirmation, duplicate/stale/future/missing evidence, seeks/source resets, distance jumps, serialization and isolated corrections |
| Seven existing CLI source lists | Add the new model dependency; `analyze-video.sh` freezes compiler inputs outside iCloud |
| `Training/guidance/modular/LinkedTurnChecks.swift`, `scripts/check-linked-turns.sh` (new) | Actual store/navigation/draft/video identity checks and production-view off-screen rendering from frozen compiler inputs |
| `Open Linked Turn Review.command`, `scripts/open-linked-turn-review.sh` (new) | Opens prepared Video 2 analysis in Category 3 with its own review directory |
| Three existing main/review launch scripts | Repoint to the shared verified current chatgpt Release package; preserve existing bundles and journals |
| `README.md`, `docs/LINKED_TURNS.md` (new), `CORNER_TECHNIQUE.md`, this log | Feature scope, launch instructions, test evidence, current launcher wording and evaluation limits |

Verification: **151 Release native tests passed**, including the 13 new tests.
A final repeat after restricting selection to the immediately following bend also
passed all 151. **2,560 selector comparisons matched** the saved pre-change selector
across 640 recorded paths (both prefer-upcoming modes, both 16/24-degree thresholds).
Native analysis of the final code processed Video 1 at 80–120 s (400 samples) and
Video 2 at 152–176 s (240 samples). Respectively: 41/39 two-bend samples, 241/117
single-bend samples, 118/84 unavailable samples and 23/15 sequence starts.

The actual ModelReviewStore check passed filtering, separate draft correction and
reload, original-video identity, Next Sequence, backward seek and playhead agreement.
Automated draft feedback lives only in the QA folder and remains unreviewed.
Inspected the off-screen native readout and minimap frames from both recordings;
no user-screen access was requested. Native video and test results establish
integration/contracts, not independent sequence accuracy or live coaching quality.

The final package is `data/guidance/linked-turns-20261015/verified-app-release/chatgpt.app`.
Its 69 Swift/test/project/scheme inputs match the canonical checkout by SHA-256;
executable SHA-256 is `aaf4d987ca94bb9b626f6e3de7ee07a232dd26d380eaa66b14d54169ca33b13e`.
Final analyzer sources also match the canonical files. Evidence and manifests are
in the same dated directory. No running app was terminated or replaced in place.

Limits / handoff: Category 3 is a review-only deterministic route preview. No weights
were trained, no live/pedal/wheel policy changed, and no correction is promoted
into training. About 30–35% of these development samples remain unavailable, mostly
while sequence order is reconfirming. Do not promote to live until independently
reviewed sequence order, false second bends and transition stability are evaluated.
Same-direction linked corners, physical chicane classification, apex/line/braking/grip
remain outside this increment. Claude's separate app remains untouched and unmerged.
