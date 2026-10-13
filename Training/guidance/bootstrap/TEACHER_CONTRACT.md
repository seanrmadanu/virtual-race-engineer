# Provisional bootstrap annotation contract

30 September 2026. Sean explicitly chose **training now with AI-generated labels;
human testing later on other recordings/live gameplay**. This is a separate
experimental path, not completion of the independently reviewed teacher pilot.

Use the observable direction/target/phase definitions in
`../teacher/ANNOTATION_HANDBOOK.md`. Literature cards RC01 (phases), RC02 (context),
RC07 (anticipation) and project safeguards PR01-PR03 inform terminology and limits;
their effect is not measured in this run. There is no with/without-literature claim.

For each row, use only its named first/middle/final causal frames and its final
minimap crop. Other rows are different cases, never evidence for this row. Ignore
future outcomes and later rows when assigning a current label. The three displayed
frames are a subset of the five causal student inputs, not extra future information.
The contact-sheet format is convenience for weak-label authoring, **not a blinded
or formally isolated teacher experiment**. Temporal context from other rows is a
potential annotation-bias limitation; these are not independent reference labels.

Return one explicit raw JSON object per case with event integer, direction, target,
phase and a case-specific reason. Unknown is permitted and must not be filled by
a guessed class. Current negotiated corners take priority over a different next
bend. A minimap may support direction without proving the current phase.

V1 supports stable third-person forward chase view with the documented 1080p HUD.
Exclude title/black frames, stationary camera orbits, cinematic shots, cockpit views,
view changes, unclear current/next boundaries and off-road parking maneuvers.
In-game rendered steering wheels, real wheel-camera inputs, driver intent and
pedal controls are not training inputs for this prototype. All-unknown excluded
windows must also be excluded from normalization statistics and supervised losses.

Do not propose speed, braking/throttle, exact steering, target speed, grip, ideal
line or traffic clearance. Do not mark labels as human-reviewed or calibrated.
The v1 teacher is the image-capable assistant inspecting the prepared images in
this conversation. No separate local VLM, external batch API, automatic label
propagation, paid compute, or fine-tuning of a language model was used.

The materializer records image/feature/source/prompt hashes and checks evidence
identities. This establishes provenance and format consistency, **not correctness**.
