# Curve animation and app cleanup — October 15, 2026

The canonical app is `Racing Trainer-3`. Claude's green-light handoff is in
[HANDOFF_FROM_CLAUDE_20261015.md](HANDOFF_FROM_CLAUDE_20261015.md); its separate
`Racing Trainer-3-claude` copy has not been merged.

## What was fixed

The supplied 58.75-second screen recording shows the wheel changing angle during
an otherwise steady bend instruction. Its visible video controls identify Video 1;
the affected bend is around 96–116 seconds in the original recording.

The old wheel combined the confirmed cue's direction with an independent,
per-frame minimap tangent to decide the magnitude. Skeleton noise and fallback
changes could move the wheel between 20 and 90 degrees without a new instruction.
A separate triangle jumped immediately to the raw target. The spring also
advanced inside SwiftUI body evaluation.

The wheel now restates the confirmed cue: centre for straight/ahead, 45 degrees
for a bend, and 120 degrees for a turn, signed by the cue. These are illustrative
poses, not calibrated vehicle steering angles. The redundant target triangle and
route-angle calculation are removed. One damped animation owns the rotation;
normal view redraws cannot advance it twice. It stops ticking when settled.

Unavailable guidance dims the wheel immediately, freezes its current pose for
0.4 seconds, then recentres. This hold is visual only and does not renew evidence.
A seek or source-generation change clears prior motion. Reduce Motion uses direct
poses; duplicate/backward timestamps cannot advance the spring.

## App organization

- Practice: gameplay, confirmed navigation, illustrative wheel, speed, road marks,
  session timer, and game audio.
- Review: direct Turns & Timing and Corner Technique actions. Category 2 remains
  recorded-video review; it is not a live apex, racing-line or pedal coach.
- Input Diagnostics: separate on-demand sheet for live input and datasets. The
  practice sidebar no longer subscribes to frame-analysis publications.
- Removed the disabled Trainer Voice slider, the always-inactive Pedal Action
  card and its settings/rendering code, and the empty Advanced review tab.
- The older comparison lab is under Development Tools. Its two players are owned
  by its window instead of eagerly created at app launch.
- The unused legacy dataset counter/labeler UI is archived in
  `Training/legacy-ui/`, outside the app target. Metadata compatibility and saved
  datasets remain intact; the current route-mask editor is still available.

Design scope: improve the existing native SwiftUI driving/review workflow, with
system typography/colors and the wheel as the main visual element. The Apple
Design skill informed grouping, reduced motion, and labeled audio controls:
`layout.md > Best practices` ("Make essential information easy to find"),
`motion.md > Providing feedback` ("Aim for brevity and precision"), and
`accessibility.md > Vision` ("Prefer system-defined colors"). This was a focused
cleanup, not a full accessibility audit. Light/dark sidebar previews were inspected
at 320 points wide; the regular window is resizable with a hideable sidebar.

## Verification

Evidence: `data/guidance/ui-rebuild-20261015/` (local, ignored by Git).

- 138 XCTest tests pass for the wheel fix in Debug and the final app in Release.
  Regression coverage includes cue freshness, upcoming turns staying centred,
  dropout during motion, source resets, reversal, speed limits, invalid/duplicate
  clocks, and consistent 30/60/120 Hz spring integration.
- Native FrameAnalyzer replay of Video 1 at 96–116 seconds with the standard HUD
  profile: 600 frames, 279 active steering frames. On the same analyzer outputs,
  the archived target calculation changed 38 times while the instruction was
  unchanged (largest step 25 degrees). The new target changed zero times.
  This is animation consistency, not measured coaching accuracy.
- Native replay also checked stale guidance, reset suppression, no early steering
  for upcoming turns, and no brake/accelerate commands.
- Real wheel artwork and sidebar were rendered in owned off-screen hosting views.
  Initial CLI previews lacked the compiled asset catalog and are superseded by
  `ui-preview-assets/` and the repeatable `ui-preview-final/` output. No running
  app screenshot or screen-control access was used.
- All 66 Swift/test/project/scheme files match the final tested source copy.
  Manifest and executable hash: `verified-release.json`.
- Release package: `verified-app-release/Racing Trainer.app`. The normal app,
  guidance-review and Category 2 launchers all point to this same package.

The original video, frozen review labels, historical builds, and Claude's copy
were not changed. Guidance can still become unavailable when its actual evidence
is missing, stale or unconfirmed. Use Standard Motorfest HUD for Video 1 and
Reference Recording HUD for Video 2; a mismatched crop can misread speed. The
recording shows truncated three-digit speeds, but its selected profile was not
visible, so that cause is not established from the screen recording alone.

Live capture-card behavior and human judgments of cue/phase timing remain
unverified by this change. No claim of calibrated steering or increased coaching
accuracy is made.

## Reproduce

```sh
RACING_BUILD_CONFIGURATION=Release bash scripts/check-modular-local.sh
bash scripts/check-steering-wheel.sh '../Training Video/Video 1.mp4' 96 116 \
  motorfest-standard-v1 data/guidance/wheel-check
```

The wheel script freezes compiler inputs in a temporary directory and builds its
own asset catalog. Optional `RACING_WHEEL_BASELINE_SOURCE` accepts the archived
`before/BaselineWheel.swift` for same-frame comparison. `RACING_WHEEL_RENDER_ONLY=1`
skips replay for visual checks. Native macOS compiler/media access is required.

Use **Open Racing Trainer.command** for the updated app and
**Open Corner Technique Review.command** for the prepared Category 2 interval.
