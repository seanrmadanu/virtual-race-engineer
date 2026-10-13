# Observable-state annotation handbook

Version `perception-pilot-v1` | Draft project labeling rules, not validated driving advice

## Purpose and limits

Produce labels for what gameplay video supports at a specified decision time. Separate visible evidence from driver intent and recommended action. The eventual action-review requirements remain in the [implementation plan](../../../docs/GUIDANCE_MODEL_IMPLEMENTATION.md#63-review-policy).

The operational definitions below are **our project conventions**, informed by but not dictated by the [free reference cards](../literature/concept_cards.jsonl). They need reviewer agreement testing. In particular, our coarse visual phases are not the same as the pedal-oriented phases described in L01.

## 1. Establish the evidence boundary

Each case needs an opaque case/event ID, recording ID, source-group ID, decision time, permitted input interval, supported camera/HUD metadata, and a list of actual frame IDs and source timestamps. IDs and filenames must not reveal answers such as `brake_too_late` or `right_turn`.

- Use only frames at or before the decision time and inside the supplied interval. Initial setting: up to two seconds of history at 10 Hz, as proposed in the implementation plan.
- Preserve actual timestamps and sampling gaps. Do not stretch a short clip or duplicate a frame to manufacture history.
- If the camera, scene or capture source changes, begin a new case/history. A frozen frame is not new evidence just because it is redisplayed.
- Never use the existing coach's text/audio, a reviewed reference answer, later collision, later lap time, or future frames as evidence for the current label. Exclude coach overlays from both conditions with identical preprocessing, or exclude the affected case.
- Record unsupported views and missing/corrupt input explicitly. A partly observable case may retain its supported fields; uncertainty in phase need not erase a readable speed.

Reviewers may inspect full events for separate retrospective analysis, but first save the causal reference label. Retrospective corrections must state whether their evidence existed at the decision time; otherwise they cannot be used as a live-model target.

## 2. Field definitions

### HUD speed

`hud_speed_displayed` is an integer read from the latest usable speed display in the supplied input, or `null`. `speed_source_frame_id` identifies the exact supporting frame; its timestamp remains the observation time. A historical readable frame does not establish current speed after a long gap.

- Read the complete speed digits. Cropped, overlapping, partly hidden or ambiguous digits are `null`, even when one value seems likely.
- Do not infer speed from scenery motion, engine sound, other frames' expected values, or a reference book.
- `hud_unit` is `kmh`, `mph` or `unknown`. A configured unit is permitted only if independently verified and provided identically in both conditions; note that provenance in the reason.
- Readable digits with an unknown unit may retain their raw displayed value. They must not be converted or used for speed-dependent advice. This first format intentionally has no normalized-speed field.
- Use `null`, not zero, for missing speed. Zero is a real displayed value and requires visible evidence.
- Human labels describe the displayed HUD value, not instantaneous physical ground-truth velocity.

### Turn direction and target

`turn_direction` is `left`, `right`, `straight` or `unknown`, relative to the vehicle's direction of travel—not simply the left/right side of the screen. `turn_target` is `current_corner`, `next_corner`, `straight_segment` or `unknown`.

Choose the target consistently:

1. If the car is clearly negotiating a corner, label that current corner.
2. Otherwise, if an upcoming bend on the relevant route is clearly visible, label the next corner.
3. If the supported visible segment is straight and no upcoming bend is established in the supplied evidence, use `straight` / `straight_segment`. This does not claim that the entire future route is straight.
4. If player heading, the route branch, the current/next distinction or bend direction cannot be resolved, use `unknown` for the uncertain fields and explain why.

For an S-bend, a current left corner and upcoming right bend are not interchangeable labels. If the current corner is established, it takes priority. When its end cannot be distinguished from the next corner's start, mark the ambiguity rather than silently changing targets.

Use the minimap only with a readable relevant route and an interpretable player heading. It can support upcoming route direction; it does not show exact steering input or prove where the driven car is within a corner. Contradictory minimap and road evidence requires review, not a guessed reconciliation.

### Coarse corner phase

Use `straight`, `approach`, `entry`, `apex_region`, `exit`, `transition` or `unknown`. These are visual temporal labels; they do not assert pedal use.

| Label | Working observable definition | When not to force it |
| --- | --- | --- |
| `straight` | The current visible driven segment is straight, with no relevant bend approach established in the supplied evidence. | A route bend exists but its relevance/distance is unclear. |
| `approach` | A relevant bend is established ahead while the observed trajectory has not yet clearly entered it. | A minimap bend alone does not distinguish approach from already being in the corner. |
| `entry` | Recent frames support the car beginning to follow the corner's curved path. | One rotated camera frame does not establish entry. |
| `apex_region` | Visible road/trajectory references over time support the car passing the interior region of that corner. | Cannot locate it, or deciding requires future frames. This is not a claim of an ideal geometric apex. |
| `exit` | Recent evidence supports the car leaving that corner as its path opens toward the following segment. | No usable exit context or an unresolved immediate next bend. |
| `transition` | A change between connected bends is visible, but assigning one stable corner phase is inappropriate. | Not a catch-all for poor image quality; use `unknown` for insufficient evidence. |
| `unknown` | Available evidence cannot support one of the above labels. | Never replace this with a confident guess to complete a dataset. |

A minimap-only case can have a known direction and unknown phase. The guide permits uncertainty; it does not guarantee that all seven classes will be reliably learnable. Merge or remove ambiguous classes only through a documented development-set revision applied to both test conditions.

## 3. Evidence record

For speed, direction and phase, record `status`, supporting `frame_ids` and a short reason:

- `clear`: the proposed raw observation has identifiable support.
- `ambiguous`: more than one interpretation remains plausible.
- `unavailable`: the necessary signal is not provided or readable.
- `unsupported`: the input/view is outside the pilot's documented scope.

Every non-null speed and every non-unknown direction/phase needs actual supporting frame IDs. IDs must exist inside the case interval. `clear` is a reviewer/teacher judgment, not a calibrated probability. A valid evidence link proves only provenance; humans still need to inspect whether it supports the claim.

Partial fields are allowed: clear digits with an unknown unit, or a visible next bend with unknown current phase. Explain the missing component rather than marking all fields clear by association. Invalid or conflicting evidence must never be repaired by a literature citation.

## 4. Recommendation boundary

For **every case in this pilot**, the recommendation is:

```json
{
  "acceptable_actions": ["abstain"],
  "cue_interval_s": null,
  "target_speed_range_kph": null,
  "reason": "Action labels are disabled in this perception-only pilot."
}
```

This is a test-scope restriction, not a human judgment that no intervention was needed. Do not use these repeated abstentions as targets when later training an action model. Score no action accuracy, recall or timing from them.

Keep the eventual distinctions: `maintain` means an evidence-supported affirmative instruction; `no_cue` means a reviewer judged intervention unnecessary; `abstain` means no justified advice is issued. None may substitute for another. Brake/lift/acceleration, target speed and exact steering require a separate reviewed action dataset and evaluation.

## 5. Worked review decisions—synthetic, not training data

| Situation | Labeling decision |
| --- | --- |
| Speed crop shows a possible trailing `14` but the leading digit touches the edge. | Speed `null`; explain clipping. Do not recover `114` by expectation. |
| `114` is completely readable; units cannot be determined. | Displayed value `114`, unit `unknown`, no conversion or action. |
| Upcoming right bend is visible in the minimap; road/car position is unclear. | Next-corner right if player heading and route are clear; phase may remain `unknown`. |
| Car slows while entering a left bend. | Label supported direction/phase and displayed speed. Do not label brake application or trail braking as observed facts. |
| An exit is visible, with no established traffic-clearance evidence. | Exit may be labeled. No acceleration or clear-road claim. |
| A crash occurs after the case's decision time. | Not part of causal evidence. Keep any retrospective analysis separate. |

## 6. Human sign-off

Reviewers first work without teacher proposals or condition labels. Record their identity, relevant driving/game experience, time spent, uncertainties and corrections. At least 20% of the pilot gets a second independent label, plus every serious disagreement. If expertise is insufficient for a phase judgment, retain `unknown`; do not certify it by model consensus.

Preserve original labels and all revisions. The [review protocol](REVIEW_AND_EVALUATION.md) defines how to compare conditions and decide whether to proceed.
