# Teacher comparison and human-review protocol

Version 1 | Design targets only: **no cases labeled or model results measured yet**

## Question and scope

Compare one fixed teacher on the same causal clips with and without the selected free literature concepts. The primary question is whether the context reduces **human time to an acceptable observable-state annotation without worsening label quality**. Secondary measures are speed/direction/phase quality, unsupported claims, unknown rates and formatting failures.

This is a development experiment, not the final locked replay exam. Action fields remain disabled and are not scored as successful coaching. Do not use a perfect abstention rate to claim useful action performance.

## 1. Prepare and freeze

1. Have a game/driving-experienced reviewer approve or revise the [handbook](ANNOTATION_HANDBOOK.md) and selected source concepts. Record unresolved disagreements. If necessary, reduce the phase vocabulary before running either condition.
2. Register original recordings and source groups. Keep related clips, alternative encodes and derivatives together. Use development footage only; reserve separate sources for a later locked evaluation.
3. Select 100–300 distinct events, including ordinary driving, with one primary decision time per event for the initial comparison. If using multiple times, group them by event and never report adjacent frames as independent trials.
4. Create a separate challenge set for malformed, missing and ambiguous inputs. Keep its deliberately altered prevalence separate from ordinary-case performance.
5. Freeze case IDs, frame manifests, preprocessing, selected concepts, prompt, output format and teacher/settings. Record hashes. Keep the same causal images and metadata in both conditions.
6. Check the local teacher's image/sequence and context limits on throwaway development cases. If it cannot accept the planned input, revise the design before freezing; do not silently drop frames or truncate literature in one condition.

The counts are initial design targets from the implementation plan, not a power calculation or a claim that 100 cases establish reliability.

## 2. Establish independent human references

Reviewers see the causal clips and handbook, not teacher outputs, condition identities, later outcomes or existing coach answers. Store a record for each case containing:

- Case ID, reviewer ID, review timestamp and relevant experience.
- Speed value/unit/frame, direction/target and phase, each with evidence and uncertainty.
- Time spent on manual labeling and whether the source/view is supported.
- Disagreements and an adjudicated reference, or an explicit unresolved/unknown status.

Independently double-label at least 20% of the pilot and all serious disagreements. Preserve both original answers before adjudication. Later inspection of a full clip must not silently turn future evidence into an earlier causal reference.

If a qualified reviewer cannot identify a phase consistently, that field is not ready for automatic supervision. Continue with supported fields rather than forcing a complete answer. A consensus of two models is not an independent human reference.

## 3. Run paired teacher conditions

Use the same [prompt](teacher_prompt.md) in fresh, independent sessions. Control receives an empty literature block. Literature receives the configured principle-only RC records. Both receive identical PR01–PR03 safeguards and the same input restrictions.

Randomize condition execution order within cases to reduce order/service effects. Record model/version, decoding settings, request IDs, raw response, parse status, elapsed time and retries. Do not run the second condition inside a conversation containing the first answer. No feedback or corrected answer may enter either prompt.

Before the run, choose a fixed retry policy. Preserve malformed responses and count them; do not retry until one condition looks correct. Repeat a fixed 10% subset three times per condition with settings and any supported seed recorded. All repeats remain grouped under their original case for uncertainty reporting.

No actual model/provider has been selected by these documents. Default to local processing; an external API requires a separate agreement on uploaded footage, cost and data handling.

## 4. Review outputs without creating a memory advantage

Compare both conditions with the independently established references. Strip condition labels and source-citation fields from blinded review copies while retaining the originals for provenance. Reviewer blindness is imperfect if wording reveals the condition; record that limitation.

For correction-time measurement, have different reviewers correct the two variants of a case where possible, balancing condition assignments across reviewers and cases. Never let a reviewer correct one variant immediately after seeing the other or the gold answer. If only one reviewer is available, report quality measurements, but treat correction-time differences as exploratory and potentially confounded by familiarity.

Keep manual-from-scratch time separate from correction time. If teacher-assisted review is slower or unreliable, manual annotation remains a valid outcome.

Suggested review record fields:

```text
case_id, anonymous_variant_id, reviewer_id, review_started_at,
review_elapsed_seconds, parse_valid, unsupported_claims,
field_corrections, corrected_record, evidence_notes,
review_status (pending/reviewed/rejected), adjudication_notes
```

The operator maintains the private mapping from variant IDs to conditions. Corrected labels do not overwrite raw proposals.

## 5. Measurements and denominators

| Measure | Report it as |
| --- | --- |
| Displayed speed | Exact-value agreement among independently readable cases; accepted-value error rate and coverage; unit errors separately. |
| Direction | Per-class precision/recall and confusion matrix; current-vs-next target errors separately. |
| Phase | Per-class precision/recall and confusion matrix, plus human disagreement rates and unknown coverage. |
| Unsupported assertion | Count and rate of non-unknown answers on human-unknown/unsupported fields; manually inspect disagreements. |
| Output validity | Parse/contract failures, invalid evidence IDs, future-frame use, invented metadata and unwanted action advice per attempted case. |
| Review effort | Median and spread of correction time by condition and reviewer, plus the separate manual-labeling reference. |
| Stability | Differences across repeated runs on the same case, grouped by field; no inflation of sample count. |

Report raw counts and denominators, not just percentages. An abstention on a readable field is reduced coverage, not a correct positive label; an unknown on genuinely unsupported evidence can be appropriate. Report disputed/unresolved references separately instead of pretending they are ground truth.

Compare matched cases at similar coverage and summarize uncertainty grouped by source recording/session. With very few source groups, report that limitation rather than narrow frame-level confidence intervals. Do not pool the challenge set into ordinary-case accuracy.

Before execution, record what improvement would justify using literature and what error changes are unacceptable. Do not select these criteria after looking at the results. There is no measured acceptance threshold in this document.

## 6. Required checks and coverage

All cases below must appear in the challenge checklist. They are specifications for future contract tests and manual review, **not tests that have already run**.

| Case | Type | Required behavior |
| --- | --- | --- |
| Missing metadata, duplicate frame IDs, non-finite/non-monotonic timestamps, reversed interval | Input contract | Operator/runner rejects before model invocation. Teacher error response is a secondary safeguard. |
| Frame after decision time or outside the interval | Causal contract | Reject the case; no future frame can support a label. |
| Frame attachment count/order differs from manifest | Input integration | Reject or mark evidence unavailable; no silent reassignment. |
| Clipped or obscured leading speed digit | Perception challenge | No guessed numeric speed from the affected observation. |
| Readable digits, unknown unit | Perception challenge | Preserve raw value if justified, unit unknown; no conversion or action. |
| Valid earlier speed followed by missing/frozen frames | Temporal/provenance | Preserve the actual old observation time; never retimestamp old pixels as current. |
| Current left corner, next right corner | Label semantics | Separate target selection from direction; do not substitute next bend for established current corner. |
| Minimap route visible but phase unclear | Partial observability | Direction may be known while phase stays unknown. |
| Unsupported camera, route absent, map/road conflict, menu/loading frame | Coverage challenge | Mark unsupported/unknown fields rather than inventing a complete scene. |
| Speed decreases while turning | Inference boundary | No observed brake/trail-brake claim from that fact alone. |
| Clear-looking corner exit | Action contract | Fixed abstention; no target speed, pedal advice or traffic-clearance claim. |
| Teacher invents a frame ID or source card | Output contract | Reject the unsupported reference; preserve the raw failure for reporting. |
| Teacher returns `maintain`, `no_cue`, brake or accelerate | Output contract | Reject: every pilot recommendation must match the fixed abstention object. |
| Same event/session accidentally appears in development and locked test | Dataset integrity | Reject the split; regroup before evaluation. |
| Synthetic format example enters actual dataset | Dataset integrity | Reject; illustrations are not gameplay labels. |

The current pack does not implement these checks. Build and test the validator before batch annotation; a syntactically valid JSON object alone does not establish evidence validity.

## 7. Exit decision

Write one of: **keep selected context**, **revise and rerun**, **use teacher without context**, or **label manually**. State which fields are supported, which remain unknown, how much review they need, and the tested views/routes/cars. No result is filled in ahead of time.

Only reviewed perception labels may advance to perception training. No action model may learn from this pack's forced abstention field. A later coaching-action pilot needs qualified reviewers, game-specific action evidence, causal cue windows and its own comparison. The paid books can help refine that later rubric, but do not automatically solve those requirements.
