# Development history

This records what was built, when, and why. Each date comes from a named
source:

- **git**: a commit in this repository.
- **doc**: a dated header or section in `docs/` or `Training/`.
- **local evidence**: dated build logs, test logs or snapshots in the
  git-ignored `data/guidance/` folder on the development Mac. These are not in
  the repository.

Work from September 29 to October 13, 2026 was not committed as it happened. It
entered git on October 13, 2026 in three commits dated that day. Those commit
dates are therefore the date of committing, not of the work. The per-feature
dates below come from the docs and local evidence instead.

Most work from late September onward was done with AI coding assistants
(ChatGPT/Codex, with Claude used for reviews and for the October 13 sync).

## Phase 1A — capture (August 2026)

| Date | Work | Source |
| --- | --- | --- |
| Aug 4 | Initial Xcode project | git `3faa788` |
| Aug 5 | Capture-card video and audio system; Xcode user files removed from git | git `c6440da`, `e67e214` |
| Aug 6–10 | Iterations v0.1–v0.6, kept as folder copies outside this repository | folder copies |

**Decision:** A USB capture card and pixel analysis, because this PS4 Pro setup
offers no game telemetry and no wheel or pedal data. See the
[README](../README.md#why-the-app-reads-video-instead-of-telemetry).

## Phase 1B — minimap route perception (August 2026)

| Date | Work | Source |
| --- | --- | --- |
| Aug 8 | Minimap dataset recorder, route-mask reviewer, real-time route tracing | git `3efb4b0` |
| Aug 10 | Route segmenter and component verifier trained on 582 reviewed image/mask pairs; hybrid detector audit (524/526 route frames, 56/56 no-route frames) | file dates of `Training/*`; committed in git `ec804eb` |

**Decisions:**

- **Deterministic first.** Yellow color/geometry detection stays primary because
  it generalized best to a held-out recording. The learned models are fallbacks
  only.
- **Recording-grouped splits.** Training and validation are split by source
  video, so adjacent frames can't inflate accuracy.

## Roadmap v2 and safety baseline (September 24, 2026)

| Date | Work | Source |
| --- | --- | --- |
| Sep 24 | System design and roadmap v2 written (kept outside the repository) | file dates |
| Sep 24 | Baseline commit before roadmap work | git `ec804eb` |
| Sep 24 | Timestamped evidence contract, `CoachSafetyPolicy` and hostless XCTest target (11 tests); removed BRAKE advice given without a speed reading | git `981afae`; [implementation status](IMPLEMENTATION_STATUS.md) |

**Decision:** Guidance must never run on stale, uncertain or mismatched
evidence. Missing speed now means direction-only advice, not a guessed BRAKE.

Note on hashes: these commits were first made locally as `c2dbacf`…`ccd12a3`. On
September 29 they were replayed onto the existing GitHub history with identical
file trees and dates, producing `ec804eb`…`185f33d`. The local tag
`baseline-v2` still points at the pre-replay `c2dbacf`, which has the same tree
as `ec804eb`.

## HUD and replay groundwork (September 28–29, 2026)

| Date | Work | Source |
| --- | --- | --- |
| Sep 28 | Steering-wheel artwork; speed OCR crop fix | git `0c3c7ae` |
| Sep 28 | Corner Replay Lab draft; `MotorfestSpeedRecognizer` | git `c092b40` |
| Sep 29 | Coaching HUD and main window redesign | git `185f33d` |
| Sep 29 | Guidance model implementation plan v1.0 | doc: [GUIDANCE_MODEL_IMPLEMENTATION.md](GUIDANCE_MODEL_IMPLEMENTATION.md) |

A separate Codex copy was made on September 29 to develop a "Reference Video
Lab". Its source snapshot is available on the
[Reference Video Lab experiment branch](https://github.com/seanrmadanu/virtual-race-engineer/tree/experiments/reference-video-lab).

## Guidance research and offline tooling (September 30 – October 1, 2026)

| Date | Work | Source |
| --- | --- | --- |
| Sep 30 | Racing-literature research (Driver61, Ross Bentley) with source catalog and concept cards | doc: [RACING_LITERATURE_RESEARCH.md](RACING_LITERATURE_RESEARCH.md) |
| Sep 30 | Local browser review tool (`Training/guidance/review`) and AI-teacher annotation handbook (prepared, not run) | doc: review and teacher READMEs |
| Oct 1 | Bootstrap temporal perception classifier trained on 78 unreviewed AI-proposed labels from one recording; offline only | doc: [bootstrap README](../Training/guidance/bootstrap/README.md) |

**Decisions:**

- **Literature gives vocabulary, not thresholds.** It supplies corner-phase
  terms and a review rubric. It doesn't supply Motorfest numbers.
- **Train-first was the user's choice.** The user asked to train first and test
  on other footage afterwards. The result is labeled provisional, kept apart
  from reviewed data, and not connected to the app.

## Model Review, modular coach and shadow capture (October 2–6, 2026)

| Date | Work | Source |
| --- | --- | --- |
| Oct 2 | Model Review window: skill categories, timestamped verdicts, export | doc: [MODEL_REVIEW.md](MODEL_REVIEW.md); local evidence |
| Oct 3–4 | Modular coach: native module adapters, 2 s / 10 Hz causal history, independent evidence guard, 30-event Video 2 pilot; 59 tests | doc: [MODULAR_COACH.md](MODULAR_COACH.md) |
| Oct 5 | Shadow capture: opt-in local evidence recording with no cue delivery; calibration-report tools | doc: [SHADOW_CAPTURE.md](SHADOW_CAPTURE.md) |
| Oct 5–6 | Codex preliminary AI review of the 30 pilot moments; blind-review prompt for Claude | doc: [AI_REVIEW_HANDOFF.md](AI_REVIEW_HANDOFF.md), [CLAUDE_BLIND_RAW_VIDEO_REVIEW_PROMPT.md](CLAUDE_BLIND_RAW_VIDEO_REVIEW_PROMPT.md) |

**Decisions:**

- **Causal replay.** Each decision uses only observations that were captured and
  completed before it, measured on a virtual processing clock.
- **Learned live output stays off.** It is hard-disabled
  (`learnedLiveEnabled = false`). A no-cue result is never treated as
  acceleration advice.
- **AI reviews are not labels.** They carry their own schema bound to the exact
  recording and pipeline hashes, and the training pipeline rejects them.

## Video analysis and Category 1 turn guidance (October 8–9, 2026)

| Date | Work | Source |
| --- | --- | --- |
| Oct 8 | In-app Analyze Video, ChatGPT/Claude review columns, white road-marking detector; 79 tests | doc: [GUIDANCE_REVIEW_UPDATE.md](GUIDANCE_REVIEW_UPDATE.md); local evidence |
| Oct 9 | AI-review visibility fix; separate *Now*/*Next* comparison labels; 81 tests | same doc |
| Oct 9 | Category 1 "Turns & Timing": heads-up and *Turn now* cue tracker in review; 88 tests. A spot check found the *Turn now* cue at Video 2, 86.9 s, early | same doc |
| Oct 9 | Same tracker connected to the main app's live analyzer and wheel; 91 tests | same doc; local evidence |

**Decision:** Timing follows the closest bend instead of skipping ahead to the
next one. *Turn now* requires a tracked approach, so a direction alone can never
trigger it.

## Turn cue audit and simpler HUD (October 13, 2026)

| Date | Work | Source |
| --- | --- | --- |
| Oct 13 | Audit of a 63-second user screen recording: missed or intermittent cues, direction switching, conflicting panels, and the tracker reset causes in code | doc: [TURN_CUE_AUDIT_20261013.md](TURN_CUE_AUDIT_20261013.md) |
| Oct 13 | HUD simplified to one instruction and arrow; Upcoming list, readiness score and timing badges removed; 91 tests | same docs; local evidence |
| Oct 13 | Committed and pushed to GitHub | git |

At the time of the October 13 commits:

- **Tests:** 91 XCTest tests and 66 Python tests (bootstrap 27, modular 24,
  review 15) passed. The app source matched the tree Codex tested at 12:59 that
  day.
- **Excluded:** Afternoon edits that pass the player's minimap position into
  route snapshots were left uncommitted. They are the start of the tracker fix
  and were unfinished.

## Local guidance improvements — October 13–21, 2026

These dates come from the dated change logs and saved replay evidence. The
source snapshots were published on November 5, 2026.

| Date | Work | Source |
| --- | --- | --- |
| Oct 13–14 | Accounted for the gap between the player marker and the first visible route point. Separated the current road instruction from the upcoming bend and improved recovery when the minimap zooms out. | [Guidance review update](GUIDANCE_REVIEW_UPDATE.md) |
| Oct 14–15 | Added white/yellow paint detection and smoother illustrative steering. Category 1 held confirmed instructions briefly through uncertainty and distinguished turning, following a bend, and going straight. | [Guidance review update](GUIDANCE_REVIEW_UPDATE.md), [Claude change log](CLAUDE_CHANGELOG.md) |
| Oct 15 | Added Category 2 corner-phase review, separated practice, review, and diagnostics, and renamed the local app `chatgpt`. Added Category 3 linked-turn review. The linked-turn build passed 151 Release XCTest tests. Both new categories run on recorded video. | [Shared change log](AGENT_CHANGELOG.md), [Corner Technique](CORNER_TECHNIQUE.md), [Linked Turns](LINKED_TURNS.md) |
| Oct 15 | Claude developed frame-to-frame road-marking tracking, smoother lane fill, and wheel stabilization in a separate prototype. | [Claude change log](CLAUDE_CHANGELOG.md), [road-tracking experiment branch](https://github.com/seanrmadanu/virtual-race-engineer/tree/experiments/claude-road-tracking) |
| Oct 18 | Improved Category 1 confirmation, kept upcoming directions stable through small route kinks, and added clearer unavailable reasons. The local package passed 155 Release XCTest tests. | Saved local comparison and test logs under `data/guidance/category1-reliability-20261018/` |
| Oct 20–21 | Reviewed the remaining coverage gap and opened the local package with OBS Virtual Camera. The app was waiting for minimap input. | Project status review and local launch check |

On October 18, instruction changes fell from 14 to 6 in the Video 2 clip and
from 17 to 8 in the Video 1 clip. The full Video 2 replay had 2,052 unavailable
samples out of 6,193 and zero *Turn Now* cue starts. These results measure
stability and coverage. Exact timing still needs independently reviewed
intervals and a live capture-card evaluation.

## Open problems

- **Turn tracker.** Needs a persistent bend identity, direction confirmation
  across frames, and approach tracking that survives brief glitches.
- **Turn-in timing.** Needs reviewed acceptable intervals, then scoring of
  missed, false, early and late cues on separate recordings.
- **Calibration.** OCR accuracy, map scale and capture delay haven't been
  measured.
- **Live validation.** No full live capture-card session has been validated.
