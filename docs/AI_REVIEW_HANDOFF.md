# Named AI review handoff

The first Codex pass covers all 30 moments in the frozen Video 2 modular pilot.
It inspected 120 sampled frames, not continuous playback.
The reviewer name is **Codex — AI preliminary review**.

## Files

- `data/guidance/modular/ai-reviews/codex-20261006/codex.review.json`: authored observations and tentative labels.
- `data/guidance/modular/ai-reviews/codex-20261006/evidence/manifest.json`: exact source timestamps and image fingerprints.
- `data/guidance/modular/ai-reviews/codex-20261006/handoff/CLAUDE_HANDOFF.md`: timestamp notes and instructions for Claude.
- The same handoff folder includes the frozen-output comparison and a blank Claude review template.

The proposals include six advance-warning candidates, six no-cue candidates, sixteen uncertain events,
and two cannot-judge events. No brake or lift timing was approved.
Confidence describes reviewer uncertainty. It is not a calibrated probability or measured accuracy.

## Review sequence

1. Claude inspects the original footage and writes **Claude — AI verification** into a separate file.
2. Claude records agreements, disagreements, viewed timestamps, and whether earlier answers were visible.
3. Sean makes the final review in the existing app under his own name.
4. Preserve all three records. Keep uncertain examples out of training.

If possible, Claude should inspect footage before reading Codex conclusions to reduce anchoring.
Once earlier answers are visible, this is development feedback, not blind evaluation.
Agreement between AI reviewers does not substitute for human approval.

The existing app's journal supports one review per event/category, not simultaneous authors.
For this pass, AI reviews remain separate files. They have **not** been imported into the app or Sean's journal.
Do not change an AI origin to human or rename its schema to bypass the trainer.
Multi-reviewer UI and promotion into final labels remain separate work.

## Evidence and safeguards

The review uses the road and HUD. The physical wheel inset is masked.
Cockpit wheel movement, future frames, and audio are not control-label evidence.
The four inspected frames end at the event timestamp. Candidate windows are limited to that two-second history.
Those windows are proposals, not measured earliest/latest acceptable cue boundaries.

Store visible direction separately from the need for advice. A stopped car can have a right bend ahead.
Also distinguish an active corner from the next corner. Slowing does not prove brake or lift input.
An unavailable forward route can justify abstention even when the road itself is visible.
Never weaken an evidence guard merely because a human or AI can interpret a frame it rejected.

The `racing-trainer-ai-review-v1` contract binds the author and every event to the recording, pipeline,
frozen replay and bundle hashes. The evidence manifest fingerprints all 120 images and 30 contact sheets.
This trades immediate in-app AI display for strict separation from the current human journal.
Revisit named layers and explicit approval references before adding automatic review merging.

Validate and generate a handoff in a new directory:

```sh
python3 Training/guidance/modular/ai_review_report.py \
  data/guidance/modular/ai-reviews/codex-20261006/codex.review.json \
  data/guidance/modular/video2-v4/pilot.review.json \
  /absolute/path/to/a-new-handoff-directory
```

The validator checks file identity, event completeness, causal evidence times, missingness and image integrity.
It does not validate the visual conclusions. It refuses to overwrite an existing handoff.
The training pipeline rejects this schema. Tests also reject AI origins disguised as completed v2 notes,
including one AI note mixed into an otherwise human journal.

No recording, frozen pilot, human review, model weight, native review UI, or learned-cue setting was changed by this pass.
Training still requires final reviewed labels, sufficient class coverage, separate recording groups and validation.
