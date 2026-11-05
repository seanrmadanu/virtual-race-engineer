# Category 2 — Corner Technique

October 15, 2026: the first increment is a continuous **route-phase estimate in
Model Review**. It does not drive the main HUD or change Category 1 steering.

## Try it

Double-click **Open Corner Technique Review.command** in the project folder.
It opens the shared verified chatgpt build on Video 2, with Category 2 selected and a
prepared analysis of **2:32–2:56**. Outside that analyzed interval, phase guidance
is unavailable. The main-app and guidance-review launchers use the same current build.

Use **Next Phase**, **−0.1 s / +0.1 s**, **Replay Turn**, and the
**Corner Phase Changes** filter. Corrections and notes remain attached to their
selected timestamp while the playback readout follows the video. A second
prepared run covers Video 1 at **1:20–1:36** in
`data/guidance/category2-20261015/video1-final/video.review.json`.

For another interval or recording, use **Analyze Video** in this build, then
select **2 · Corner Technique**. Old bundles retain their original labels;
they are not silently reclassified.

## What the estimates mean

| Estimate | Evidence used |
| --- | --- |
| Straight | Confirmed straight near-route tangent |
| Approach | Straight near route with a separately confirmed bend farther ahead |
| Entry | Confirmed change from an established straight or opposite direction into this bend |
| In bend | Continuing near-route direction, or starting analysis inside a bend |
| Exit | Sustained easing of the near-route angle, or its transition back to straight |
| Phase unavailable | Missing/uncertain/stale evidence, stopped motion, or direction still confirming |

These are deterministic geometry estimates, not a newly trained model or measured
vehicle steering. Minimap angle changes cannot establish the true apex, tire grip,
optimal line, braking, throttle, or exact turn-in timing. **Apex and racing-line
guidance remain unimplemented.** Angle thresholds and transition windows are
provisional and require separately reviewed recordings.

The tracker uses only completed observations available at or before the decision.
It checks route, minimap, player position, input validity, speed, units, source
session, and timestamp alignment. A 0.25-second trailing median rejects isolated
angle noise; direction changes need at least three distinct captures spanning
0.25 seconds. Duplicate frames cannot advance phases. Source changes, seeks,
large clock gaps and unusable evidence clear progression. Startup in a bend does
not fabricate an observed entry. Current bend and upcoming bend stay separate.

## Contracts and integration

- `CornerTechnique.swift`: versioned sample, vocabulary and validation.
- `CornerTechniqueTracker.swift`: independent causal tracker; no dependency on
  turn cues, road-line curvature, wheel animation, or pedal policy.
- `GuidanceVideoAnalyzer.swift`: warms the tracker with up to two seconds of
  causal lead-in, records 10 Hz samples, and includes phase starts in review events.
- `ModelReviewModels.swift`: optional `cornerTechnique` event field and
  `cornerTechniqueSamples` stream. Validation checks event/stream agreement.
  Playhead lookup never chooses a future, expired, or more than 0.25-second-old sample.
- `ModelReviewStore.swift`, `ModelReviewView.swift`, `CornerTechniqueReadout.swift`:
  readout, phase filter/navigation, and separate `cornerPhase` correction field.
  Historical `phase` labels and frozen AI reviews remain unchanged.
- Xcode test source registration and five existing CLI source lists include the
  new model/tracker dependencies. `check-corner-technique.sh` tests the actual store.

Feedback is still collected after showing the estimates. It is not blind ground
truth and is not automatically promoted into training. The new `cornerPhase`
field has no training consumer in this increment.

## Verification and limits

**134 native tests passed in Debug and Release**, including 12 Category 2 tests for left/right
progression, startup inside a bend, linked bends, direction noise, duplicate frames,
source/seek/gap resets, invalid evidence, stopped motion, replay expiry,
backward compatibility, separate feedback, and invalid bundle rejection.

Native analysis processed **400 samples**: 240 from Video 2 at 152–176 s and
160 from Video 1 at 80–96 s. The stability refinement reduced unavailable
samples in Video 2 from 86 to 68 and phase starts from 28 to 23; Video 1 retained
13 unavailable samples and phase starts fell from 24 to 20. These are development
availability/stability counts, **not accuracy measurements**. Direction confirmation
and missing speed still interrupt phase coverage. Entry/exit timing has not had
an independent annotated evaluation.

Evidence, exact source hashes, build logs, native traces, and comparison counts
are under `data/guidance/category2-20261015/`. The store integration result and
off-screen readout preview are documented in the shared change log.

## Next work

Review phase transition intervals on separate recordings, measure missed/early/late
entry and exit estimates, and resolve route/OCR gaps before proposing live Category 2
coaching. Apex and racing-line work needs additional road/vehicle evidence; it must
not equate the minimap's largest curve with a real apex.

The October 15 app cleanup repoints this launcher to the shared current Release
build; the prepared Category 2 bundle and review journal remain unchanged. See
[the app update](STEERING_AND_APP_CLEANUP.md).
