# Local gameplay review lab

The first ten-moment practice batch is ready for **human labeling**, not model training. The app serves full-resolution masked frame sequences and saves independent labels locally. It contains no teacher answers, recommendation fields or external API calls.

## Open / restart

From the repository root:

```sh
/Users/sean/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 Training/guidance/review/server.py data/guidance/review/practice-30732c1a2691-v1 --port 8765
```

Open [the local review page](http://127.0.0.1:8765). Keep the command running while reviewing; Ctrl-C stops it. The tool binds only to `127.0.0.1`, not the local network. A restricted execution sandbox may require permission for a local listening socket. No installation is needed with the bundled Python runtime.

1. Enter a name or nickname. Use the same spelling later to resume your saved labels.
2. Play each short history or step through its frames. Playback stops at the last permitted frame. Full-size view lets you inspect the HUD; scroll within it as needed.
3. Enter displayed speed while its supporting frame is on screen; this automatically links that frame as evidence. Or explicitly choose speed unknown. Choose the unit, turn direction, current/next/straight target, and phase without guessing.
4. Mark other supporting frames, add a short evidence/uncertainty note and confirm that you have not seen AI answers. Click **Save & next**.
5. Return to any saved moment to revise it. **Export saved labels** writes a JSON snapshot containing the latest version of each of your records to the local `labels/exports/` folder and shows its full path. It does not include unsaved browser drafts or depend on browser-download support.

Saved labels live under `data/guidance/review/practice-30732c1a2691-v1/labels/` in one append-only JSONL journal per reviewer. Hashed filenames avoid interpreting nicknames as paths; the reviewer ID remains in each record. Every save records a new revision and the source-manifest hash. Browser drafts are a convenience, not the authoritative save. A failed disk save stays visibly unsaved.

Another reviewer should use a different nickname and label without seeing your answers. These are named local profiles, **not authenticated accounts** or a privacy boundary against someone with access to this Mac. Records remain `pending` for later review/adjudication. Do not present these labels as expert-validated ground truth.

## Prepared batch

- Source: `Training Video/Video 1.mp4` in the parent project directory; original unchanged.
- Source SHA-256: `30732c1a2691512111bd837616a0714609a2d3ffbb4e907a4ec268afb9d46a95`.
- Ten fixed decision times: 95, 150, 205, 260, 315, 370, 425, 480, 535 and 590 seconds. Selection is time-based, not based on generated answers or class labels.
- Each case has 20 frames sampled near 10 Hz inside the preceding two-second window. Actual source timestamps are retained; none is after its decision time. Playback is sampled history, **not a 60 FPS video clip**. No audio is included.
- Native 1920×1080 resolution; JPEG quality 0.97. The top-left wheel inset is blacked out in the actual pixels over a 520×344 rectangle. The page never serves raw/unmasked footage.
- All cases belong to the same source group. This is development practice, not ten independent recordings or a locked test set. Platform, game version and vehicle setup are not verified by this batch.
- The mask was checked across all 200 images; sample frames were visually inspected. Exact values and scene labels are deliberately not prefilled.

## Minimal architecture and boundaries

`Original video → Swift extraction + pixel mask → immutable manifest/frames → loopback review page → per-reviewer revision journal`

`extract_frames.swift` uses AVFoundation and fails if its source-specific format assumptions, causal times or output path are invalid. It refuses to overwrite an existing batch. The frame-selection/mask recipe is specific to this recording; inspect and version it before using another source. A failed extraction can leave a partial folder, but the server will not accept it without a complete valid manifest.

`server.py` validates source-frame hashes and timestamps before serving. Only the static app, explicitly listed frames and review endpoints are exposed. Writes require a same-origin loopback host and a per-process token. A stale label revision is rejected rather than silently replacing another session's edit. This small local tool is not a publicly deployable multi-user service.

`web/` contains the dependency-free player/form. It withholds saving when an image fails to load, provides explicit unknown choices, and requires evidence for known observations. It records what the reviewer entered; structural checks cannot establish whether the interpretation is correct.

Revisit reviewer authentication, formal dataset export/adjudication, schema migration, efficient video decoding and richer per-field evidence if the experiment grows. Neither the teacher runner nor the learned coach is implemented here.

## Verification and safe testing

```sh
cd Training/guidance/review
/Users/sean/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 -m unittest -v test_server
```

The tests use disposable fixtures, checking unknown versus zero, numeric/type restrictions, required evidence, label enums, current/straight target consistency, identity/confirmation, causal timestamps, duplicate IDs, path escapes, changed frame hashes, append-only revisions, reviewer separation, stale edits, HTTP saving and loopback/origin/token guards. The HTTP test requires permission to bind a loopback socket.

For browser QA, run a different port with `--labels-dir` pointing to a temporary directory. Do not insert synthetic test answers into the real label folder. A completed browser save is not a human reference label. Verify playback, save/next, reload/resume, revision, unknown handling and export there before handoff.

See the [annotation handbook](../teacher/ANNOTATION_HANDBOOK.md) for labeling conventions and the [review protocol](../teacher/REVIEW_AND_EVALUATION.md) for the later independent comparison. This practice tool does not authorize coaching actions, outside uploads, batch teacher execution or training.

### Verification record — 30 September 2026

- 15 automated tests passed, including HTTP save/export, revision conflicts, export snapshots and manifest-version isolation.
- All 200 images passed source-time, uniqueness, file-hash, 1920×1080 dimension and inset-mask checks; three final-frame samples were visually inspected.
- Browser checks confirmed history playback, unknown-label saving, reload/resume, revision saving and JSON export to disk. Browser QA used a separate temporary label folder; the real batch had zero labels at handoff.
- JavaScript syntax and local documentation links were checked. The narrow in-app browser layout was inspected and next-case navigation adjusted to return to the player.
- These checks validate the tool, not the accuracy of any human/model label or the usefulness of coaching. No teacher inference, guidance-model training or live app integration was performed.
