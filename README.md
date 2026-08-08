# Virtual Race Engineer

Virtual Race Engineer is an early-stage macOS racing coach for **The Crew
Motorfest**. It accepts gameplay from a capture card or a local video file,
reads HUD information locally, and is being developed toward real-time braking,
acceleration, and steering guidance.

## Current phase

Phase 1B currently provides:

- live capture-card video and game-audio preview;
- local `.mov` and `.mp4` playback for testing without a console;
- speedometer OCR diagnostics;
- Motorfest minimap and cyan local-player detection;
- a deterministic yellow GPS-route detector;
- a magenta route-mask overlay with confidence and performance statistics;
- dataset recording and auditing tools for the future learned model.

The route detector is a bootstrap computer-vision system used to create and
review first-pass masks. It is **not yet the final Core ML segmentation model**.

## Requirements

- macOS and Xcode
- a complete, uncropped 16:9 Motorfest gameplay feed
- the default Motorfest HUD position
- a capture card for live console input, or a local AVFoundation-compatible
  gameplay video for offline testing

## Build and test

1. Open `Racing Trainer.xcodeproj`.
2. Choose **Product > Clean Build Folder** (`Shift-Command-K`).
3. Build with `Command-B`, then run.
4. Open the **Live Input** menu.
5. Select the capture card or **Open Video File…**.
6. Keep **Analyzer** enabled.

Expected route states:

- **GPS ROUTE DETECTED**: the accepted yellow trail is covered by magenta.
- **NO GPS ROUTE**: the minimap exists, but no usable waypoint trail was found.
- **MINIMAP NOT FOUND**: the HUD is hidden, moved, cropped, or incompatible.

## Route-overlay performance

The minimap pipeline has a 30 FPS analysis ceiling and never queues a backlog
of old frames. When analysis or UI rendering falls behind, intermediate frames
and stale completed results are discarded so the overlay stays close to the
current gameplay frame. Each completed minimap result is published to SwiftUI
as one atomic state update.

The **Frame Analyzer** panel displays both:

- **Map FPS**: the actual rate followed by the configured ceiling (for example,
  `27.5 / 30.0`);
- **Map Time**: the processing time actually reached on the current Mac.

## Local processing and YouTube

Frame analysis is performed locally; the current pipeline does not require a
paid API. A normal YouTube watch-page URL cannot provide decoded pixel buffers
to `AVPlayerItemVideoOutput`. Use a permitted local recording or send a
full-screen browser source through OBS Virtual Camera.

## Known limitations

- HUD crop coordinates are currently calibrated for default 16:9 Motorfest
  footage.
- The deterministic detector still needs testing across more cars, weather,
  regions, display modes, and capture devices.
- The minimap can estimate route direction and curvature, but it cannot produce
  an exact steering-wheel angle by itself.
- App icon, bundle identity, signing, sandbox entitlements, privacy text, and
  release testing still need to be completed before App Store distribution.

## Roadmap

1. Generate and correct route masks from diverse recordings.
2. Train and evaluate a small Core ML route-segmentation model.
3. Convert route masks into a centerline, lookahead, and signed curvature.
4. Classify upcoming turn direction, distance, and severity.
5. Combine the route with speed and the main road view.
6. Calibrate and validate braking, acceleration, and steering guidance.

## Licensing

A license has not yet been selected. Adding code to a public repository does
not by itself make the project open source; choose a license before presenting
it as an open-source release.
