# Free-reference annotation pilot

Version 1 | 30 September 2026 | **Prepared, not executed**

**1 October update:** Sean chose a separate **train-first, test-later** bootstrap.
An [experimental perception classifier](../bootstrap/README.md) is now trained on
unreviewed assistant labels. This does not complete this pack's independently
audited teacher comparison or validate coaching actions. Its distinct contracts,
data and checkpoints live under `bootstrap/`; the original pilot below is unchanged.

This pack turns the existing free literature notes into a concrete first annotation experiment. It does not require a paid book. It is a manual-ready specification and prompt template, not an implemented teacher runner, validator, dataset or trained model.

**Human-review tooling update:** a [local review lab](../review/README.md) now prepares and serves ten development-practice moments from the supplied video, with masked frames, causal timestamps, label validation and local revision history. Use it for the initial human-labeling dry run. The teacher output validator/runner and the full 100–300-event comparison remain unimplemented.

## Start here

1. Read the [annotation handbook](ANNOTATION_HANDBOOK.md) before assigning labels.
2. Register recordings and causal frame windows using the [implementation plan](../../../docs/GUIDANCE_MODEL_IMPLEMENTATION.md#51-recording-manifest). Do not send private footage to an external service without an agreed upload scope.
3. Have humans independently label the selected development cases before seeing model answers.
4. Follow the [comparison and review protocol](REVIEW_AND_EVALUATION.md), using the [shared prompt](teacher_prompt.md) and [pilot configuration](pilot_config.json).
5. Store actual proposals and reviews under ignored `data/guidance/`, not beside these templates.

The [illustrative output](example_output.json) contains **no real gameplay observation**. It demonstrates an unavailable-input response only and must never become a training example.

## What the first experiment can answer

Does a small amount of cited racing context improve a teacher's **visible-state labels**, or reduce human correction work, compared with the same teacher without that context?

It cannot establish correct braking/throttle actions, optimal target speeds, lap-time improvement, live latency or the quality of a future student model. Action output is deliberately fixed to `abstain` in both conditions. This is a narrower experiment than the eventual coaching system, not a replacement for it.

## What we use from the free sources

The source material is documented in the [research report](../../../docs/RACING_LITERATURE_RESEARCH.md) and [source catalog](../literature/source_catalog.json). The [concept cards](../literature/concept_cards.jsonl) distinguish source paraphrases (`RC`) from project safeguards (`PR`).

| Material | Role now |
| --- | --- |
| RC01 / L01: corner phases | Context for the coarse phase-label experiment. |
| RC02 / L02: line choices | Context for distinguishing visible geometry from claims of optimality. |
| RC07 / L07: anticipation | Context for separating current and upcoming route features. |
| PR01–PR03: project safeguards | Identical in both conditions; never removed from the control. |
| RC03–RC06, RC08–RC09 | Retained for a later action-review experiment. No current game-specific action labels can be derived from them alone. |
| L10, R01, paid-book descriptions and further-reading leads | Background only; not teacher annotation context. |

Only each selected RC card's `id`, `source_ids`, `source_locator` and `principle` belong in the variable literature block. Its project-application suggestions must not introduce extra rules in just one condition. All required evidence and inference restrictions belong in the common handbook/prompt.

All cards remain draft and not expert-approved. Have a driving/game-experienced reviewer examine the selected concepts and these operational label definitions before the pilot. A source citation is provenance, not approval.

## Files and readiness

| File | Status |
| --- | --- |
| `ANNOTATION_HANDBOOK.md` | Draft observable-label definitions and review boundaries. |
| `teacher_prompt.md` | Shared instructions with explicit input/context placeholders. |
| `pilot_config.json` | Proposed fixed experiment settings; a future runner must implement them. |
| `example_output.json` | Synthetic format illustration, not measured data or a formal schema. |
| `REVIEW_AND_EVALUATION.md` | Independent-label, comparison and failure-check protocol. |

Remaining work includes source inventory/clip registration, an output schema and working validator, actual teacher execution, independent review, and a measured report. This pack does not complete the implementation plan's first milestone. Paid sources can extend a later version; freeze and hash this version before running a comparison so the test does not change halfway through.
