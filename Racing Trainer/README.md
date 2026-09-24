# Racing Trainer — Phase 1B Confidence-Gated Minimap Coach

## Current coaching pipeline

The live analyzer now runs this guarded path:

1. validate the minimap from the connected cyan player shape or circular rim;
2. find the GPS route with primary color geometry, verified short-route
   recovery, and a reviewed-mask-trained fallback;
3. thin the mask and select one ordered forward centerline;
4. classify direction, severity, and NOW/SOON/LATER timing;
5. smooth results across full detections;
6. synchronize against the closest timestamped speed OCR result;
7. track the verified centerline onto the newest retained frame;
8. publish guidance only when every critical confidence score passes.

The Frame Analyzer reports the route source, explicit detector failure reason,
player/rim confidence, learned candidates, and short-route verifier confidence.
The normal HUD displays conservative **BRAKE**, **HOLD**, or **ACCELERATE IF
CLEAR** guidance and categorical steering. Analyzer mode adds the magenta raw
mask, green ordered centerline, orange turn-onset point, and confidence values.

This is an MVP for validation. It does not claim exact steering-wheel degrees,
an ideal racing line, lane position, obstacle awareness, or vehicle-specific
braking performance.

## Current dataset workflow

The red minimap recording control saves paired data under Application Support:

- `minimap/raw/map_XXXXXX.png` — original minimap crop
- `minimap/predicted_masks/map_XXXXXX.png` — automatic black/white route mask
- `minimap/route_mask_reviews/map_XXXXXX.json` — source and review metadata
- `minimap/corrected_masks/map_XXXXXX.png` — human correction, when needed
- `minimap/exports/` — reviewed training/validation pairs

Use the paintbrush button in **Route Mask Dataset** to review the masks. Accept
clean predictions, correct mistakes with Brush/Eraser, approve visible
no-waypoint frames as No Route, and reject unusable minimaps.

## Expected behavior

- Live video and audio continue working normally.
- A **Frame Debug** switch appears beside Settings.
- The debug card appears in the upper-left of the windowed video preview.
- Video-only fullscreen hides the debug card.
- `Frame Count` increases with incoming capture frames.
- `Map FPS` reports the actual minimap analysis rate and the 30 FPS ceiling.
- Resolution and last-frame time update from sampled gameplay frames.
- Switching or refreshing the video source resets the counters.

## Local test-video mode

The input menu can switch between the capture card and a user-selected local
movie. Local playback feeds decoded BGRA frames through the same
`FrameAnalyzer` and `MinimapDatasetRecorder` used by live capture.

- Supported through the macOS file picker: AVFoundation-compatible movie files.
- Required test layout: uncropped 16:9 Motorfest gameplay with the default HUD.
- Controls: play/pause, ±10 seconds, timeline scrubbing, looping, and restart.
- Detector feedback: a status badge plus a magenta mask over an accepted yellow
  GPS route.

YouTube watch-page URLs are intentionally not treated as direct media URLs.
Their embedded web player does not expose decoded frames to the app's
`AVPlayerItemVideoOutput`, so accepting one would play a video without actually
testing the analyzer.

## Performance design

- AVFoundation still owns the smooth preview path.
- The video-output callback remains lightweight.
- Local test-video frames are offered to the analyzer at up to 30 FPS.
- Minimap analysis has a 30 FPS ceiling; measured performance depends on the
  Mac and is shown in Frame Analyzer.
- Only one analysis task can be active at a time.
- Excess frames are skipped instead of queued.
- Minimap analysis runs on a separate user-initiated queue.
- Stale completed results are discarded if the UI falls behind.
- Each minimap result and mask is published as one atomic UI update.
- Binary route-mask data is now also supplied to the live geometry analyzer.
  The mask is coarse-sampled before skeletonization to keep this bounded; Map
  Time in Frame Analyzer shows the actual cost on the current Mac.
