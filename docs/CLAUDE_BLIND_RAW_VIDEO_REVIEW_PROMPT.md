# Claude task: Independent raw-video review

## 1. Your assignment

I am Sean. I am building Racing Trainer, a native macOS racing coach for The Crew Motorfest.
Codex has helped build the system. I now need your own assessment of the raw gameplay footage.

**Review the video, not Codex's review. Do not read or verify Codex's answers.**
Do not seek agreement with another reviewer. Produce your own observations before any comparison.
I will compare the separate reviews later and make the final human decisions.

Use this reviewer name exactly: **Claude — Independent Raw-Video Review**.

This is an annotation task. Do not train, fine-tune, deploy, change application code, or adjust safety thresholds.
Do not modify existing reviews. Write new review artifacts in a separate folder.

## 2. Allowed inputs and strict blinding

Start in a fresh Claude conversation that has not seen Codex's conclusions or the pipeline's event outputs.
If this conversation already contains them, tell me. Do not claim that this pass is blind.

For this task, read only:

1. This prompt, including the neutral project report below.
2. The label-free event list:
   `/Users/sean/Documents/Projects/Racing Trainer/Racing Trainer-3/data/guidance/modular/blind-review-input/video2-v4.events.json`
3. The original video:
   `/Users/sean/Documents/Projects/Racing Trainer/Training Video/Video 2.mp4`
4. Clips or frames that you extract yourself from that video for this task.

Do not search the repository for labels, diagnoses, example answers, or prior reviews.
Do not open any of these during this task:

- Codex review files, comparison reports, summaries, or the previous `CLAUDE_HANDOFF.md`.
- The `data/guidance/modular/ai-reviews/` directory.
- Sean's files under `data/guidance/modular/user-reviews/`.
- `pilot.review.json`, its summary, `observations.jsonl`, or model prediction files.
- The existing model-review app. It displays proposed labels and pipeline answers.
- Other project documents, source tests, or regression reports. Some reveal answers for these exact timestamps.

Treat these restrictions as a review protocol, not merely a suggestion.
Use a plain video player or your own extraction tools instead of the model-review screen.
If you accidentally see a prohibited output, record what you saw and when. Never reset that disclosure to false.
Do not upload footage to additional services or install paid tools without asking me.

If you cannot access or inspect video/images, stop and state the limitation.
Do not infer labels from filenames, timestamps, architecture descriptions, or existing model output.

## 3. Project progress report — October 6, 2026

This report gives system context without event-specific findings or expected labels.
The repository is:
`/Users/sean/Documents/Projects/Racing Trainer/Racing Trainer-3`

### Product and input constraints

- The intended live source is PS4 Pro gameplay through a capture card. Saved recordings also work as development inputs.
- Video is the only required input. We do not have synchronized game telemetry or controller/pedal inputs.
- Speed and route information come from visible HUD pixels. These are measurements with possible errors, not direct telemetry.
- Development recordings do not automatically prove performance on the intended live hardware, car, setup, camera, or HUD.
- Swift handles native app analysis. Python handles data preparation, training infrastructure, and offline evaluation.

### Original learning approach and literature

- The original approach uses a pretrained vision-language model as an offline annotation teacher.
- Racing literature supplies concepts and vocabulary, not game-specific ground truth or verified braking constants.
- A free-source reference catalog, draft concept cards, and annotation instructions were prepared.
- A controlled comparison of annotations with versus without literature has not established a benefit yet.
- We have not trained a language model on racing books.
- The intended workflow remains: observations and candidate labels, independent checking, human approval, training, evaluation, then deployment gates.

### Earlier trained perception baseline

- A separate experimental perception classifier was trained on provisional assistant labels from one source recording.
- It uses fixed image features with trained classification heads and simple temporal summaries.
- It produces basic direction/current-versus-upcoming classifications and coarse corner phases.
- It is not a trained brake/lift coach, an end-to-end video model, or a fine-tuned vision-language model.
- Its provisional labels and fitted results do not establish independent accuracy or reliable generalization.
- The old weights and outputs remain available as a baseline. They are not the new modular slowdown model.

### Current modular approach

We now separate perception from guidance:

```text
Gameplay pixels
  -> speed reading / minimap detection / route geometry / input-validity checks
  -> timestamped observations with uncertainty and missingness
  -> causal observation history
  -> rule or learned guidance proposal
  -> independent evidence checks
  -> supported advice, no cue, or cannot judge
```

- Swift modules reuse existing speed recognition, minimap detection, and geometry code.
- Each observation carries its value, units, source, timestamps, validity, confidence kind, module version, failure reason, and raw evidence.
- Confidence values are diagnostic scores. They are not calibrated probabilities of correctness.
- The history contains 20 rows at 10 Hz over the preceding two seconds.
- Inputs preserve missing values and observation ages. Future observations cannot enter a decision.
- Seeks, source changes, gaps, and interruptions reset history.
- Route geometry supplies turn direction. It does not by itself prove actual vehicle steering or the current corner phase.
- A recorded turn direction can exist even when there is insufficient evidence for an actionable coaching cue.
- Basic direction and slowdown timing are separate targets. Do not collapse them into one label.

### Rules, calibration, and safety

- Rule-based proposals and independent evidence checks are implemented separately.
- Missing, stale, unreliable, wrong-source, or mismatched speed must block speed-dependent advice.
- The system distinguishes `no_cue` from `cannot_judge`.
- There is no completed physical calibration for the supported car/setup yet.
- Map scale, suitable corner speeds, brake/lift deceleration, and actual warning delay still need measurements and review.
- Normalized map geometry is not automatically meters or time-to-turn.
- Camera/menu handling remains incomplete. Supported-view assumptions still need validation.
- Agreement between modules does not prove correctness. Their scores should not be averaged into an accuracy claim.
- New learned live cues remain disabled. The preserved legacy coach is a separate system, not proof of validated learned guidance.

### Data and review tools

- The complete modular Video 2 replay contains 6,194 observation samples.
- A frozen development pilot contains 30 selected moments from that recording.
- Native review tools provide timestamp seeking, playback-synchronized highlighting, diagnostics, and saved review notes.
- Timing reviews support correct, early, late, wrong, missed, uncertain, and unusable cases after outputs are revealed.
- Those verdicts judge a displayed system answer. They are not suitable for your blinded first pass.
- The current app stores one review per event/category. It does not yet merge independent reviewers safely.
- Keep your review outside its human journal.
- Codex has completed a separate preliminary pass. Its conclusions, counts, and event-specific findings are intentionally withheld here.

### New structured-input model: infrastructure, not trained gameplay weights

- A small causal temporal network and training pipeline are implemented in Python/NumPy.
- The input is 20 time rows with 26 structured features, including missingness, freshness, ages, values, and separate module scores.
- The network uses a causal convolution, tanh, history pooling, and a four-class head.
- The intended classes are advance warning, lift, brake, and no cue.
- Uncertain/cannot-judge examples remain excluded rather than becoming invented no-cue labels.
- The new model will use actual module outputs, including their errors. It will not reuse the old image-classifier weights.
- **No gameplay slowdown model has been trained with this new pipeline yet.**
- Training gates require explicit human-reviewed labels, source identity, valid intervals, adequate class coverage, and separate recording groups.
- Video 1 and Video 2 are development footage. Neither is an untouched final test.
- AI review files are not automatically accepted as human training labels.

### Evaluation and deployment infrastructure

- Offline benchmark code supports identical-recording comparisons, missed/false cues, early/late timing, answer coverage, and separate confidence checks.
- Core ML export and prediction-parity tooling is prepared, but has not qualified a real trained slowdown model.
- Opt-in shadow analysis is connected to live capture and local playback.
- Shadow mode records proposals and evidence without delivering its own voice or HUD cues.
- State checks cover old-source callbacks, seeks, resets, repeated/stale frames, interruptions, and bounded processing.
- Calibration tools produce local evidence reports and blank measurement templates. They do not invent calibration values.
- Completed checks include 71 native tests, 24 Python tests, seven native regression groups, and a 120-frame real-pixel replay smoke test.
- These are software/regression results, not coaching accuracy, a live capture trial, or proof of calibrated confidence.
- The replay smoke test used simulated receipt timing. End-to-end live warning delay is not established.
- Physical capture tests, live overhead checks, real-model parity, untouched-recording evaluation, and three reviewed 20-minute shadow sessions remain pending.
- Apex optimization, advanced technique, traffic awareness, acceleration advice, and exact steering commands remain deferred.

## 4. Raw-data review procedure

1. Open the label-free event list. Confirm it contains 30 unique event IDs and source times.
2. Verify the original video's SHA-256 against that list, if your tools support hashing.
3. Use the exact event IDs and times. Do not substitute visually similar scenes.
4. For each event at time `t`, first inspect the raw interval `[t - 2 seconds, t]`.
5. Prefer continuous playback when available. Otherwise inspect a sufficient frame sequence and disclose its actual source timestamps.
6. Do not describe sampled frames as watching a complete clip. Record your inspection method per event.
7. Mask or ignore the physical steering-wheel inset. Do not use pedals, hands, physical controls, or cockpit-wheel angle to infer driver input.
8. Use road pixels, the HUD, the minimap, and their changes over time.
9. Do not view frames after `t` while deciding what could be known at `t`.
10. If earlier context is necessary, use only additional past footage. Record its range and why it was needed.
11. Review in timestamp order. Save each initial decision before moving to later footage. Do not revise earlier labels using later outcomes.
12. Record an observation, uncertainty, and evidence for every event, including unusable events.

The timestamps were selected for development using an earlier pipeline run. They are not a random evaluation sample.
Blinding your answers reduces anchoring. It does not remove selection bias or make this an independent human accuracy study.

## 5. What to label

For each moment, distinguish these questions:

- **Visibility:** Is the road, HUD, and minimap usable? Is there a menu, camera change, occlusion, or other limitation?
- **Speed:** What number and unit are actually readable? Record null when unreadable. Do not guess missing digits.
- **Current road situation:** Is the vehicle on a straight section, entering/following/exiting a left or right bend, or uncertain?
- **Upcoming route:** What is the next established route direction relative to vehicle heading? Is forward route continuity visible?
- **Relationship:** Does the road support the route interpretation, contradict it, or leave it unresolved?
- **Phase:** Record approach, entry, apex region, exit, transition, straight, or unknown only where the evidence supports it.
- **Cue:** Is an advance warning, lift, brake, no cue, or inability to judge defensible from available evidence?
- **Timing:** Can you justify a useful cue interval? If not, leave the interval null even when the direction is clear.

Do not force a single direction to represent both a current bend and a different upcoming bend.
Distinguish the selected route from the car's observed path. An arrow's screen position alone is not a steering label.
Do not infer optimal apex, grip, target speed, pedal input, or collision clearance from a route line.
Visible deceleration alone does not establish braking or lifting. High speed alone does not establish a brake requirement.
`no_cue` means there is positive support for no corner/slowdown cue during a stated interval.
`cannot_judge` means usable evidence is insufficient. `uncertain` records an unresolved reviewer judgment.
Neither means that the road is safe or that acceleration is allowed.

You may propose brake or lift only with a clear, stated basis for the recommendation.
Separate a suggested action from a claim that the driver actually performed that action.
Without enough evidence, use uncertain. Do not manufacture examples to balance the training classes.

Use qualitative confidence separately for speed, current situation, upcoming route, and cue judgment.
Do not invent calibrated percentage confidence or combine these fields into one score.

Cue interval rules:

- Use seconds from video start, not seconds before the turn.
- Do not automatically copy the inspected two-second clip bounds into the acceptable cue interval.
- State what evidence supports each boundary. Leave boundaries unknown if they cannot be justified.
- Never label an earlier warning using a fact first visible later.
- You cannot score the model's cue as early/late/wrong without seeing its answer. Do not do that in this blind pass.

## 6. Output format and storage

Create a new folder under:
`/Users/sean/Documents/Projects/Racing Trainer/Racing Trainer-3/data/guidance/modular/independent-reviews/`

Suggested name: `claude-raw-video-pass1`. If it exists, use a new version. Never overwrite it.
If local files are unavailable, return the same artifacts as downloadable files or structured text.

Use a separate schema named `racing-trainer-blind-ai-review-v1`.
This is a review artifact, not a file that the current trainer or app should ingest directly.

At the review-set level, include:

- Reviewer name and `reviewerType: "ai"`.
- `origin: "ai_raw_video_blind"` only if no previous answers were seen. Otherwise use `ai_raw_video_exposed`.
- Actual review date and model/version if available. Do not guess a model version.
- The source and run fingerprints copied from the label-free event list.
- The label-free event-list file's SHA-256, if supported.
- Truthful `sawCodexReviews`, `sawModelOutputs`, and `sawHumanReviews` values.
- `humanApproved: false` and `trainingEligible: false`.
- Any accidental exposure, tool limitations, or additional context used.

For every event, include:

```text
eventID, time, reviewStatus
inspectionMethod, inspectedSourceRanges, sampledFrameTimes
sourceEvidenceFilesAndHashes (if extracted files exist)
viewValidity and limitations
observedSpeed: value, unit, confidence, evidenceTime
currentSituation: direction, cornerTarget, phase, confidence
upcomingRoute: direction, routeContinuity, confidence
roadRouteRelationship
proposedCue: action, acceptableIntervalSeconds or null, confidence
timingRationale and evidenceAvailableBy
directObservations
inferencesAndAssumptions
uncertainties
needsHumanDecision
```

Use null for missing measurements and unknown for unresolved categories. Do not fill a template with invented evidence.
An inspected uncertain event may be marked reviewed. A frame you could not access must remain unreviewed.
Leave model verdicts and Codex agreement fields absent. Those belong to a later comparison, not this task.

## 7. Freeze the independent result and stop

Deliver:

1. `claude.raw-review.json`: all 30 events, with honest completeness and uncertainty.
2. `claude.raw-review.md`: concise timestamped observations and evidence limitations.
3. An evidence manifest for any clips or frames you extracted.
4. A SHA-256 fingerprint of the completed JSON, if your tools support it.
5. A short list of events requiring my final judgment, without guessing another reviewer's answer.

Freeze the initial review before any later model-output comparison. Keep revisions as new files with reasons.
Do not open Codex's review after finishing this pass. Stop and return your independent artifacts.
I will decide when and how to compare the reviews and make the final human labels.

Do not claim model accuracy, successful training, or agreement with Codex from this work.
Your goal is a useful independent annotation set, not a reassuring verdict about the project.
