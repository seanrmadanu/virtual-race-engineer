# Category 3 — Linked Turns

October 15, 2026: Category 3 now previews **left → right** and **right → left**
sequences in recorded Model Review. It also distinguishes one visible left/right
bend, no supported bend sequence, and unavailable evidence. This is a deterministic
route-geometry prototype; no guidance model weights were trained.

## Try it

Double-click **Open Linked Turn Review.command** in the project root. It opens the
verified **chatgpt** app on Video 2 at the first confirmed two-bend sequence in the
prepared **2:32–2:56** analysis. Category 3 and **Sequence Changes** are selected.
Use **Next Sequence**, **−0.1 s / +0.1 s**, or **Replay Turn** to inspect it. The current
Category 2 phase is shown separately from the visible route sequence.

Outside the analyzed interval, the sequence readout is unavailable. To try another
clip, use **Analyze Video**, then select **3 · Linked Turns**. Category 3 appears
only in bundles containing the new stream. An additional prepared run covers
Video 1 **1:20–2:00** at
`data/guidance/linked-turns-20261015/video1-final/video.review.json`.

Corrections use a separate `linkedTurnPattern` field in the existing review journal.
They remain feedback after viewing model output; drafts do not become reviewed
labels automatically, and no training consumer uses the new field. Historical
labels and frozen AI reviews remain unchanged. The persisted category identifier
is still `advanced` for compatibility.

## Detection contract

- Uses the existing route scanner's heading changes of at least 24 degrees with
  sustained path support. Only the first bend and its immediately following
  opposite bend can form a sequence; it cannot skip a nearby bend to select one
  farther away. Same-direction linked turns are not supported in this increment.
- Requires at least 0.08 normalized map units between the two onsets. Distances
  include the player-to-visible-path gap and have no physical time/distance meaning.
- Confirms the same sequence over at least three distinct captures spanning
  0.25 seconds. A direction contradiction withdraws the preview while reconfirming.
  Capture gaps over 0.35 seconds and onset-distance jumps over 0.06 reset confirmation.
- Checks finite normalized coordinates, player connectivity, route/minimap confidence,
  valid input, source identity, completion time, 0.65-second freshness, and
  route/minimap/input timestamp agreement within 0.25 seconds.
- Duplicate captures cannot advance confirmation, renew expiry, or create a new
  sequence event. Missing/uncertain evidence, seeks and source changes clear state.
- This is spatial preview, so it can operate without speed or while stopped. It
  cannot authorize braking, throttle, steering, or a "turn now" instruction.
- A single bend or no visible sequence does not assert that the road is straight.
  A reversal in the map is not proof of a named chicane, an apex, or a racing line.

The thresholds are provisional development choices, not calibrated driving physics.
The main HUD and steering wheel still use Category 1. Category 3 is review-only.

## Implementation and tests

| Area | Implementation / verification |
| --- | --- |
| Geometry | `RouteTurnSelector.swift` exposes the existing scan; Category 1 selection semantics retained |
| Model | `LinkedTurns.swift`: versioned sample validation, causal confirmation, explicit unknowns |
| Analyzer | Native video analyzer warms with causal lead-in, saves 10 Hz samples and sequence-start events |
| Review | Optional event/stream fields, event-stream agreement, causal expiring playhead lookup, sequence filter/navigation, separate draft correction |
| UI | `LinkedTurnReadout.swift`: route preview and independent current phase; available in `ModelReviewView.swift` for new bundles |
| Regression | 151 Release XCTest tests pass, including 13 new linked-turn tests |
| Selector parity | All 2,560 old/new comparisons match across 640 route paths, both selection modes and 16/24-degree thresholds |
| Store integration | Actual store passes filtering, isolated draft persistence, original-video identity, Next Sequence, backward seek, and playhead synchronization |
| Visual check | Off-screen rendering of the production readout inspected; no screen control/capture used |

Fresh native analysis of the final implementation:

| Recording / interval | Samples | Two-bend samples | Single-bend samples | Unavailable | Sequence starts |
| --- | ---: | ---: | ---: | ---: | ---: |
| Video 1 / 80–120 s | 400 | 41 | 241 | 118 | 23 |
| Video 2 / 152–176 s | 240 | 39 | 117 | 84 | 15 |

In Video 1, 92 samples were confirming a sequence and 26 lacked usable player-connected
route geometry. All 84 unavailable Video 2 samples were confirming. Confirmed
sequences can still change or disappear as the extracted route changes. These are
availability and integration measurements on development recordings, **not accuracy
or coaching-quality scores**. The raw-video spot checks are not independent labels.

Evidence is under `data/guidance/linked-turns-20261015/`: final review bundles,
traces, replay-summary.json, native test logs, selector-parity.log, store-qa-final,
and verified-release.json. The packaged Release app matches 69 source/test/project
files, verified by hashes. All main/review launchers use this package; existing
Category 1/2 review data and journals are preserved.

## Next evaluation

Collect independently reviewed sequence order and transition intervals on separate
recordings, including single corners, close reversals, same-direction corners,
straight routes, marker occlusion and route truncation. Measure false second bends,
missed sequences, ordering errors and transition instability before considering
live display. Apex, braking, grip and racing-line coaching still need additional
road/vehicle evidence and reviewed targets.
