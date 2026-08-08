# Racing Trainer — Phase 1B Route-Mask Test Build

## Files

- `FrameAnalyzer.swift` — new file
- `CaptureSessionManager.swift` — replace the existing file
- `ContentView.swift` — replace the existing file

## Xcode steps

1. In the **Racing Trainer** group, create a new Swift file named `FrameAnalyzer.swift`.
2. Replace its contents with the provided `FrameAnalyzer.swift`.
3. Replace the full contents of `CaptureSessionManager.swift`.
4. Replace the full contents of `ContentView.swift`.
5. Confirm all three files have **Racing Trainer** checked under **Target Membership**.
6. Build with **Command-B**, then run.

## Expected behavior

- Live video and audio continue working normally.
- A **Frame Debug** switch appears beside Settings.
- The debug card appears in the upper-left of the windowed video preview.
- Video-only fullscreen hides the debug card.
- `Frame Count` increases with incoming capture frames.
- `Analyzed` increases at roughly three frames per second.
- `Analysis FPS` settles near `3.0`.
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
