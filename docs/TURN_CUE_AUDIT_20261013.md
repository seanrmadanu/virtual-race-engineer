# Turn cue audit — October 13, 2026

**Later update:** The user subsequently requested simpler panels. The main app now uses a single instruction and arrow, merges preview/heads-up wording into “Left/right turn ahead,” and removes the competing Upcoming list, readiness score, timing badges, captions and footer strip. The session panel is only a timer. The inventory below documents the pre-cleanup behavior observed in the recording. This presentation change does not repair the tracker resets or calibrate Turn Now.

Inspected the user's 63.426-second screen recording, sampled banner frames at 2 Hz, exact frames at 00:04 and 00:54, and the current app source. Times below are elapsed time in the submitted screen recording, not the gameplay video or app session timer. This is an observation and vocabulary audit; app behavior and labels have not been changed in this audit.

## Observations

- At 00:04 the main banner says “Left ahead · tracking,” while the Upcoming panel lists “Gentle right” twice. Two panels can present different route targets without explaining which bend each describes.
- Turn Now is present: the exact 00:54 frame shows “Turn left now” and the NOW badge. Other sampled frames also show turn cues. The complaint is intermittent or missed guidance and unstable sequencing, rather than the cue being completely absent.
- The sampled sequence switches between left, right, straight, preview, heads-up and unavailable states. It also returns from Turn Now / following to preview. The recording alone cannot establish which individual route observation or timing condition failed.
- A green “COACH READY” state can coexist with “Turn timing unavailable”: route readiness and turn-timing readiness are distinct, but the UI makes them look like one status.

Evidence images: `data/guidance/cue-audit-20261013/frame-04.png`, `frame-54.png`, `banner-sequence.jpg`, and `contact-sheet.jpg`.

## Current main-banner instructions

Each left/right entry represents two exact labels.

| Internal stage | Instruction | Badge | Caption |
| --- | --- | --- | --- |
| straight | Continue straight | — | Route ahead |
| preview | Left ahead · tracking / Right ahead · tracking | AHEAD | Confirming turn timing |
| heads_up | Left turn coming up / Right turn coming up | SOON | Upcoming turn |
| turn_now | Turn left now / Turn right now | NOW | Turn-in cue · Experimental |
| following | Follow the left bend / Follow the right bend | BEND | Bend in progress |
| unavailable | Turn timing unavailable | WAIT when the badge is shown | Reason text |

The source is `Racing Trainer/TurnGuidance.swift:16` and `Racing Trainer/TrainerCoachHUD.swift:629`. The main tracker supports left/right/straight/unknown, not a separate U-turn instruction.

Unavailable reason text currently includes “Fresh route evidence is missing” and “No established nearby bend.” “Waiting for gameplay” is the initial empty-snapshot reason.

## Upcoming-panel signs

- STRAIGHT: straight arrow.
- LEFT / RIGHT: bent turn arrows.
- GENTLE LEFT / GENTLE RIGHT: diagonal arrows.
- SHARP LEFT / SHARP RIGHT: the same bent turn arrows used for ordinary left/right.
- U-TURN LEFT / U-TURN RIGHT: U-turn arrows.
- —: unknown placeholder with a question-mark symbol.

Medium severity is displayed as LEFT/RIGHT; it does not add the word MEDIUM. Source: `TrainerCoachHUD.swift:548` and `MinimapCoachModels.swift:55`.

## Older fallback vocabulary still in the banner source

These strings are outside the normal fresh Category 1 cue path:

- Follow the route; Continue straight.
- Bear left / Bear right.
- Turn left / Turn right.
- Sharp left / Sharp right.
- U-turn left / U-turn right.
- Timing captions: Turn in now; Coming up; Ahead; Clear road; Route ahead.
- Status messages: Analyzing minimap; Set a waypoint; Minimap not found; Route uncertain; Guidance paused; No guidance.

The session status labels are ANALYZING MINIMAP, COACH READY, SET A WAYPOINT, MINIMAP / GAMEPLAY NOT FOUND, ROUTE UNCERTAIN and GUIDANCE STALE. These are readiness messages, not additional turn classes.

Legacy internal timing values are unknown / none / later / soon / now, with displayed titles UNKNOWN / CLEAR / LATER / SOON / NOW. New timing stages are unavailable / straight / preview / heads_up / turn_now / following. Both vocabularies remain in the code because the live adapter maps between them.

## Confirmed implementation causes and limits

1. `TurnGuidanceTracker.update` selects the closest bend with `preferUpcoming: false`. `LiveTurnGuidanceSnapshot` supplies this cue to the main banner and wheel.
2. `MinimapCoachSnapshot.applying` independently selects with the default `preferUpcoming: true`. This can choose a later bend once the closest bend is near. `SessionPanelView.upcoming` then uses another extractor and replaces its first result with the snapshot direction. The duplicated right entries at 00:04 are consistent with this construction, though identical successive bends are also possible.
3. The separate extractors also disagree on classification thresholds: the route selector establishes a bend at 24 degrees with medium/sharp boundaries of 42/80; the Upcoming extractor uses a 16-degree minimum and 34/72 boundaries. Therefore severity and list membership can differ for the same path.
4. The tracker clears its approach history immediately on unusable route/speed, an unestablished bend, direction change or a distance jump over 0.075 normalized map units. A new direction is displayed immediately as preview. There is no persistent bend identity across these changes.
5. Turn Now requires at least 0.7 seconds of approach history, an earlier distance of at least 0.08 in the retained 1.5-second window, a current distance no greater than 0.035, and estimated arrival within 0.6 seconds. Thus a correct direction alone cannot produce Turn Now. Slow approaches can also lose the earlier outside-zone evidence from this short window. These are code-level failure mechanisms, not proof of the exact cause of every missed cue in the recording.
6. After Turn Now fires, a perception discontinuity can clear the fired state before its nominal 1.2-second display duration finishes. The same-direction cooldown can suppress a subsequent cue without proving that it is the same physical bend.
7. UI wording is generated from enums after prediction; the labels are not fed back into the predictor. Renaming removes user-facing ambiguity, but does not repair bend selection or temporal tracking.

## Proposed simplification

For Category 1, show one stable progression: Continue straight → Left/Right turn ahead → Turn left/right now → Follow the left/right bend, plus Guidance unavailable when evidence cannot support guidance. Keep preview/confirmation as internal state rather than an additional instruction that competes with the heads-up. Use severity only as an optional descriptor of that same identified bend; use “Then” for a separately established later bend.

Implementation work should unify the banner, wheel and list around the same identified bend, confirm direction changes across frames, retain approach milestones for that bend rather than only in a short slope window, and handle brief uncertainty without authorizing stale steering. Evaluate missed, false, early and late cues on reviewed intervals. Changing copy alone or blindly holding an old direction would not resolve this.
