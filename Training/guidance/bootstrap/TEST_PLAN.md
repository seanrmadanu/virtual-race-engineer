# Verification and remaining evaluation

Status: 1 October 2026. This plan separates software correctness from label/model
correctness. Human evaluation is intentionally **after training**, per Sean's choice.

| Layer | Type and current coverage | Target / examples |
| --- | --- | --- |
| Causal batch | Unit + complete 660-frame integrity pass | Reject future/duplicate/stale/gapped PTS, wrong source, crop/encoder changes, paths outside batch, damaged hashes, nonfinite features and missing burned masks. |
| Label contract | Unit + all 132 records validated | One label per case; no invented/unseen evidence; explicit unknowns; valid current/next/straight semantics; AI cannot self-certify human review. |
| Optimizer | Synthetic unit + actual fit | Loss decreases on a simple separable problem; finite outputs; real run uses only supported labels; save/load preserves exact numeric arrays. |
| Model package | Integration | Check code/data/label/weight hashes; the packaging refit has identical arrays to the first run; invalid weight shapes/checksums fail. |
| Replay | Full 132-window smoke + unit tests | No actions or speed estimates; incompatible phase suppressed; exact training source rejected as a new test; output directories never overwritten. |
| Evaluation scorer | Synthetic integration | Requires completed independent human references; identity consistency; separate coverage, accepted accuracy, confusion and unknown-reference assertions. |
| Existing review tool | Regression | All 15 existing tests, including localhost save/export/security. Use disposable fixtures, never the user's journals. |

27 bootstrap tests and 15 review-tool tests passed. A sandbox initially prevented
the localhost HTTP fixture from binding; the same suite passed with approved local
socket access. Native extraction/feature generation was executed on the real video
in the previous preparation run; resumption reused those immutable prepared frames.

## Known failures and unmeasured areas

- **9/54 excluded windows** still receive a non-unknown corner output at the
  uncalibrated threshold. Unsupported-view/ambiguity rejection is not qualified.
- Zero independent human-labeled test recordings. The 100% training-label agreement
  is resubstitution on provisional AI labels, not held-out accuracy.
- One source, one visible car, sparse classes (only five straight windows), mixed
  lighting and camera changes. No class-level generalization claim is supported.
- No controlled teacher repeatability or with/without-literature comparison.
- No proof of causal isolation across multi-row teacher contact sheets; field
  evidence references are causal, but contextual annotation bias remains possible.
- Native app integration, end-to-end live latency, capture interruptions,
  unsupported HUD/layout detection and game-specific action correctness are untested.
- Re-encoded/cropped copies must be grouped manually; file hashes alone do not
  establish independent sessions. Fixed five-second sampling can miss short events.

## Sean's next-video test

1. Freeze the checkpoint and pick a new original recording with the supported
   camera/HUD. Include ordinary straights, left/right corners and difficult cases;
   keep an extra challenge set separate from normal-case prevalence.
2. For independent scoring, save human observations before revealing the model
   answers. Existing assisted examples and Video 1 must not become the test set.
3. Run frozen inference, then inspect confusion by direction, current/next target
   and phase. Report raw counts, unknown coverage and wrong confident answers, not
   a single flattering accuracy percentage.
4. Log failures with frame/time IDs and causal evidence. Disputed ground truth stays
   unknown until resolved; do not use future outcomes to justify earlier cues.
5. Move used-to-fix cases into development/regression data. Evaluate the revised
   model on new untouched source groups. Live testing begins in shadow mode only
   after integration; no braking/throttle cues are authorized by this prototype.

No statistical acceptance threshold was selected or met in this bootstrap. Set
per-field error/coverage goals on development data before attempting a release gate.
