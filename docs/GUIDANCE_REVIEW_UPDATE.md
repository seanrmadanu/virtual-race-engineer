# Guidance testing and review update — October 8, 2026

Requested outcome: analyze other Motorfest recordings inside the native app, inspect guidance and road markings during playback, and review timestamped ChatGPT and Claude responses beside the user's own verdict.

Implemented:

1. Add source-bound AI review records and import support. Preserve source hashes, provenance, unknown intervals, and a clear empty state for videos the AIs have not reviewed. Keep user feedback in its existing journal.
2. Extend the timestamp log with ChatGPT and Claude columns. Preserve the separate playback highlight and selected review; playback must not move the user's draft.
3. Add cancellable native video analysis with explicit HUD profile, camera and speed-unit settings, causal sampling, progress, and a saved per-run review bundle.
4. Refine experimental route selection and stationary/near-turn handling without treating unapproved AI suggestions as training labels or inventing vehicle calibration.
5. Detect candidate white road markings from gameplay pixels. Draw only observed supported boundaries, exclude HUD/control regions, and expire missing/stale detections. Remove the uncalibrated minimap projection from the road highlight.
6. Validate source identity, timing, missing evidence, cancellation and synthetic road markings; build the actual application. Earlier review-window inspection was limited by the computer-control failures documented below; the integrated main app was subsequently visually verified.

The macOS interface uses semantic system colors, standard controls, persistent row selection, an additional “Now” marker for playback, and readable AI summaries with full details on selection. The detector estimates visible road bounds; it does not establish an optimal line, metric map scale or collision clearance. The guidance remains experimental until human-reviewed data and recording-separated evaluation support a trained model.

Existing source files were preserved under `data/guidance/app-update-20261008/baseline/` before this update. The frozen independent reviews remain the input references.

## Open and use

Double-click `Open Racing Trainer.command` for the main app, or run `bash scripts/open-racing-trainer.sh --test` to start the Video 2 guidance test at 01:34. Choose the source menu to use Live Capture or another Test Video. The **Guidance** menu selects the HUD layout and speed unit.

Double-click `Open Guidance Review.command`, or run `bash scripts/open-guidance-review.sh` for timestamp review. Both launchers use the packaged Release app at `data/guidance/modular/verified-app-20261013-simple-guidance/Racing Trainer.app`. In a normal app launch, choose **Model Review → Show Model Review**.

- **Analyze Video…** selects a recording and runs the native pipeline. Set the start/end range, HUD layout, speed unit and road camera. Use Reference Recording HUD for Video 2 and Standard Motorfest HUD for Video 1. Analyze separate ranges when the camera changes. Other layouts remain unsupported unless calibrated; Unconfirmed Layout keeps speed evidence uncertain.
- The timestamp log contains **Time, App, ChatGPT, Claude**. For the new turn-timing run it opens Category 1 and **All Moments**, selecting the first proposed Turn Now cue. Older direction-only bundles default to **AI Reviewed** when matching responses exist. The header shows loaded counts for each reviewer. **All Moments** also includes timestamps without an AI review, explicitly labeled **No review at this time**. Import AI Review accepts the original frozen Claude/Codex JSON files or the normalized column format; source mismatches are rejected.
- Playback highlights its current row with **Now**. The selected review and draft stay on the moment being edited. Select a row for AI details, module evidence and your verdict. Replay 2 Seconds stops at the selected timestamp.
- Drafts and completed reviews remain in separate per-source/per-analysis journals. The launcher uses `data/guidance/modular/user-reviews`; a normal app launch uses Application Support/RacingTrainer/ModelReview. AI exposure hashes are recorded with edited human notes.
- **Open Test…** reopens an earlier saved analysis. `bash scripts/open-modular-pilot.sh` opens the unchanged 30-event baseline in the updated app.

## Guidance and road limits

Native video analysis writes causal module samples at 10 Hz, one review moment per second, source/pipeline/output hashes and road observations. Runs have unique directories; cancellation or a failed decode does not publish a completed review bundle. Source size/mtime are checked again before publication. Supported recordings are uncropped, unrotated 16:9 footage up to two hours.

Route selection measures sustained heading changes relative to the initial local route tangent. It separates a near bend from a subsequent bend and avoids classifying a slightly angled straight as a turn. A confirmed stationary reading or unresolved near-bend warning timing suppresses an advance warning. A no-cue observation requires fresh speed, route and paired straight-road evidence; missing calibration still blocks brake/lift. Learned live output remains disabled.

These changes run through **Model Review → Analyze Video** and the shared modular replay adapter. The main app now also uses the same turn-timing tracker through the live integration described below. Freshness and source checks still apply; no learned braking coach is enabled. Its road highlight uses the new pixel detector.

The detector searches for locally contrasting white ridges, masks HUD/wheel/car regions, fits candidate markings and clips car occlusions. A single marking draws one line. Paired bounds can draw a faint corridor; missing or stale evidence clears it. Road observations retain capture and completion times, so replay does not display an inference before it was available. This is an experimental image-space overlay, not a metric map, lane-occupancy guarantee, optimal racing line or collision-clearance judgment. Lighting, yellow paint, wide curves and camera changes limit coverage; false candidates remain possible.

## Verification

- Release app built successfully; **79 native tests passed, zero failures**. The packaged Swift sources match the tested copy. Build output and source hashes are in `data/guidance/app-update-20261008/`.
- Both original AI files and both packaged column files decoded and validated with 30 records each. Claude's original SHA-256 remains `7014332accfa2d3e86c67a970d0d5b29cf4205510be3c396f5aa88e426360cf8`. Neither AI set is human-approved or training-eligible.
- The app's native analyzer completed an eight-second smoke range from each video. A cancellation check left an INCOMPLETE marker and trace, with no completed review bundle.
- The prepared Video 2 run covers seconds 0–619: **6,190 causal samples, 619 review moments**. All source frames and module completion timestamps precede their decision times; the output SHA matches the trace. All 30 AI source timestamps exist in the new run. This is development data, not independent accuracy evaluation.
- Real frame overlays were inspected, including positive white-marking candidates and rejection of earlier scenery/car-reflection mistakes. The final run has 1,587 observations with line candidates and only 49 paired candidates among 6,189 road observations. These are availability counts, not mapping accuracy. Guidance accepted 2,457 warnings, 1 no-cue observation and 3,732 cannot-judge outcomes; none were brake/lift.
- The packaged app was launched and loaded the new 619-event bundle and source bookmark. The computer-control tool repeatedly failed with `Sky Computer Use native pipe closed before response` on the new review window, so final visual layout, clicking, live capture and end-to-end in-window analysis have **not** been visually verified. Native analysis, model contracts, saved artifacts and build checks were verified separately.

Reproduce the build with `RACING_BUILD_CONFIGURATION=Release bash scripts/check-modular-local.sh`. `scripts/analyze-video.sh VIDEO NEW_OUTPUT START END HUD_PROFILE` uses the exact native analyzer behind the app; macOS decoding/Swift compiler plugins need an unrestricted local developer session.

Frozen AI reviews and original pilot outputs remain unchanged. No model weights were trained from these AI opinions.

## October 9 visibility fix

The initial 619-row view hid the sparse AI responses among unreviewed seconds. At the reported 01:43 timestamp neither AI had a review; both had responses at 01:35 and 01:45. The new default opens the 30 AI-reviewed moments, displays each reviewer's loaded count, and seeks playback to the selected first review when the video becomes ready. A Show AI Reviews action navigates from the full log to a reviewed timestamp. Loading failures now have a visible explanation.

All 79 native tests passed. `scripts/check-review-visibility.sh APP VIDEO_REVIEW NEW_QA_DIRECTORY` also exercised the actual ModelReviewStore against packaged resources: both 30-record sets load, all 30 default rows contain both responses, 01:43 remains empty, 01:45 has both, and a different video hash defaults to All Moments without borrowing responses. Evidence is saved under `data/guidance/ai-review-visibility-20261009/`. The native computer-control tool still failed to inspect the window, so these are build and store-integration checks, not a claim of final visual verification.

## October 9 comparison-label fix

AI table cells previously showed the same cue summary in every skill category and silently preferred the upcoming direction over the current one. This made different targets appear directly comparable. Basic Turns now shows separate **Now** and **Next** directions. Corner Technique shows the labeled current phase or explicitly says it is unlabeled. Slowdown Timing shows the proposed cue and marks intervals that end before the event timestamp. Original AI labels remain unchanged.

For example, at 02:20 the app labels the upcoming turn left, ChatGPT labels the current bend right without a separate upcoming label, and Claude labels the current bend right and upcoming turn left. These fields do not establish a same-target direction disagreement. Other timestamps, including 01:35, contain actual upcoming-direction disagreements that must be adjudicated from video, not majority vote. The specific moment reported by the user has not yet been identified or adjudicated.

The Release build passed **81 native tests**, including separate-current/next, category, missing-phase and earlier-interval regressions. Evidence is in `data/guidance/ai-comparison-20261009/`. Visual verification retains the tool limitation above.


## October 9 Category 1 turn timing

Category 1 is now **Turns & Timing**: direction plus a maps-style upcoming-turn heads-up and a separate Turn Now cue. This is a causal, deterministic prototype, not trained or calibrated turn-in guidance. This initial review implementation was subsequently connected to the main app as described below.

Open `Open Guidance Review.command`. The packaged app loads `data/guidance/turn-timing-20261009/video2-final/video.review.json`. This run reuses the verified original Video 2 perception trace and recomputes timing; provenance records the original source, perception and observation hashes. The full replay contains 6,190 samples, 709 review moments, 67 heads-up cue onsets and 31 Turn Now cue onsets. These are output counts, not accuracy figures. Analyze Video runs the same tracker on new native perception samples.

Review workflow:

1. Select Category 1 and **Turn Cues**, or use **Next Cue**. **AI Reviewed** still opens the exact original comparison timestamps.
2. **Replay Turn** plays six seconds before and two after the selected cue. Use the 0.1-second buttons to inspect its timing. Playback changes the cue display and row highlight while preserving the selected draft.
3. Judge direction and turn timing separately. Choose heads-up, Turn Now, no cue, or uncertain, then mark early/correct/late/missed/unsure. Set the acceptable start/end interval using **Use Playhead**. Feedback remains per source and analysis run.

Design: route geometry → closest forward bend → causal approach tracker → preview / heads-up / Turn Now / following → 10 Hz playback and review. The existing route direction selector still supports a separate upcoming bend; timing follows the closest bend rather than silently skipping to the next one. The tracker requires fresh route, validity and synchronized speed evidence, confirms the same bend over several samples, estimates approach from a robust slope in normalized map coordinates, and issues a short turn-in proposal only near the onset after a tracked approach. It clears approach state after gaps, seeks, source changes, stale or future evidence, direction changes and large distance jumps. Stopped, snapshot-only and nonapproaching cases cannot issue Turn Now. Cue delivery suppression survives short evidence dropouts; it resets on a source/clock reset.

Limitations: map onset is not a physical steering point. Occlusion by the player marker, smoothing, zoom, lane position, route noise and camera changes affect timing. A still-frame spot check at 85/87/89 seconds found the 86.9-second Turn Now cue early: the junction is still ahead at 87 seconds. Its exact acceptable turn-in interval has not been approved. The conservative four-second same-direction repeat suppression can also hide closely linked turns. Correct next steps are reviewed turn-in intervals, explicit player-to-route onset distance, and evaluation on separate videos—not calling these proposals perfect or copying AI slowdown intervals into turn labels. Road markings remain a separate experimental visible-boundary overlay; they do not yet calibrate turn-in timing.

Verification: 88 Release native tests passed, including approach sequencing, deduplication, stopped/static inputs, route jumps, stale/future evidence, seeks/source resets, playback causality and feedback persistence. The packaged ModelReviewStore integration check passed: Category 1 defaults, Turn Cues filtering, separate direction/timing draft persistence, 30 ChatGPT plus 30 Claude records, exact-time matching, and different-source isolation. Fresh native analysis produced 80 samples for Video 2 (84–92 s) and 40 for Video 1 (80–84 s). Evidence is under `data/guidance/turn-timing-20261009/`.

The app launch command succeeded, but native UI inspection returned `timeoutReached`; final window layout and button interaction are not visually verified. Original frozen AI review SHA-256 values remain unchanged. No model weights were trained and no AI review was promoted to human approval.

## Main-app guidance integration — verified October 13

The main app's live frame analyzer now feeds its existing minimap route and speed observations into the same Category 1 turn tracker used in review. Both test-video playback and live capture use this shared analyzer. The navigation banner shows the tracker stage, and the animated wheel stays centered during preview/heads-up before rotating left or right during Turn Now and bend-following. Missing or expired evidence suppresses the target. Source changes and video seeks reset approach history.

The wheel is an illustrative direction target (currently ±54 degrees), not a measured or calibrated physical steering angle. Pedal guidance is shown as uncalibrated; legacy brake/accelerate commands are not displayed by this integration. Exact turn-in timing, road boundaries, and physical capture-card behavior still need validation. No model weights were trained.

Verification:

- The packaged build passed **91 native tests, zero failures**. Build evidence: `data/guidance/live-integration-20261009/build-and-tests-final.log`.
- A native check drove the actual `FrameAnalyzer` through **160 frames** from Video 2, including preview, heads-up, Turn Now and following. It verified centered heads-up targets, no pedal commands, expiry and reset behavior. Evidence: `data/guidance/live-integration-20261009/native-frame-smoke.log`. These are integration checks, not driving-accuracy measurements.
- The packaged executable hash was rechecked October 13 against `executable.sha256`: `901e974fc0cee51e51ee59bf8f28fbe42c647813d573da6b7262a7be98fb65c5`.
- The integrated main window was visually inspected with Video 2 playing. Earlier inspection showed the right-turn cue with clockwise wheel rotation and the preview with a centered wheel. October 13 inspection confirmed the main app was playing the test video, displaying the upcoming-turn banner and centered wheel. The app was left open for testing. This resolves the main-window inspection limitation; it does not establish capture-card or review-window end-to-end validation.

Reproduce the native playback check with `bash scripts/check-live-guidance.sh`. The launcher selects Reference Recording HUD and km/h for the supplied Video 2 test. For other supported inputs, select the matching layout and unit in **Guidance**; changing either clears prior guidance.

## October 13 simpler driving panels

The turn card now displays one arrow and one instruction. Preview and heads-up both say **Left/right turn ahead**. The other instructions are **Turn left/right now**, **Keep turning left/right**, **Continue straight**, and **Guidance unavailable**. Turn Now uses amber text and a border as additional emphasis; its words carry the timing meaning. The extra timing badges, captions, progress bar, and footer strip were removed.

The session panel now contains only elapsed time. Its separately computed Upcoming turn list, readiness label and confidence percentage were removed, along with the unused alternate list extractor and fallback turn vocabulary in the HUD. The banner and wheel use the same live cue. Existing detailed analysis remains in Tools & Diagnostics and Model Review. The Guidance menu identifies turn timing and wheel angles as experimental.

This is a presentation cleanup: it removes competing panel directions and preview/heads-up wording changes. It does not change route perception, tracker resets, evidence freshness requirements, or turn-in calibration. Direction switching and missed/early cues identified in `TURN_CUE_AUDIT_20261013.md` still require tracker work and evaluation.

The Release build passed **91 native tests, zero failures**. Changed source files match the tested copy. Logs and hashes are in `data/guidance/simplified-hud-20261013/`, and the executable hash is beside the packaged app. The main app was opened with Video 2 and visually inspected during playback: a single **Left turn ahead** instruction, compact session timer, and wheel were visible; the conflicting turn list and timing tags were absent. The updated app was left open.
