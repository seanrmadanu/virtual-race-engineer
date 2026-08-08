RACING TRAINER - DATASET AUDIT UPDATE

Replace / add these files in Xcode:

REPLACE:
- CaptureSessionManager.swift
- ContentView.swift
- MinimapDatasetRecorder.swift

ADD:
- DatasetMetadataStore.swift

IMPORTANT:
- Make sure all four files have "Racing Trainer" checked under Target Membership.
- DO NOT replace MotorfestHUDLayout.swift. Keep your current crop:
    x: 0.780
    y: 0.620
    width: 0.180
    height: 0.325

What changes:
- Microphone slider is removed.
- Dataset Audit appears in the right sidebar under the audio controls.
- Fullscreen shows Dataset Audit as a floating card in the top-right.
- The existing Analyzer "i" button hides/shows BOTH Frame Analyzer and Dataset Audit in fullscreen.
- Raw image total is read from your existing minimap/raw folder.
- Category counts come from metadata JSON files. Until we build the labeler, they will correctly show 0 and the Raw/Labeled/Unlabeled totals will show what is actually on disk.

Build:
1. Product > Clean Build Folder (Shift-Command-K)
2. Command-B
3. Run


RACING TRAINER - GPS ROUTE MASK V1

NEW:
- MinimapRouteDetector.swift

UPDATED:
- FrameAnalyzer.swift
- ContentView.swift

What it does:
- Finds the bright cyan local-player arrow.
- Detects long, connected yellow GPS-trail pieces.
- Rejects compact yellow in-game player arrows.
- Rejects the yellow minimap ring, OPEN CARA text, and darker road paint.
- Reconnects route pieces separated by the white checkpoint circle.
- Draws the accepted route mask in magenta when Analyzer is enabled.
- Reports route confidence, candidate pixels, mask pixels, route parts,
  and rejected parts in Frame Analyzer.

Expected test results:
- Waypoint set: GPS Route = YES and the yellow trail receives a magenta mask.
- Minimap visible with no waypoint: GPS Route = NO and no magenta mask.
- HUD hidden: Minimap = HIDDEN and GPS Route = NO.

Important:
- This is the deterministic bootstrap detector used to generate first-pass
  masks. It is not yet the final trained segmentation model.
- Because the Xcode project uses a synchronized source folder, the new Swift
  file is discovered by the target automatically.
- Build this exact project with Command-B. If Xcode reports an error, send a
  screenshot of the full Issue Navigator message, not only the highlighted line.


RACING TRAINER - LOCAL TEST VIDEO UPDATE

NEW:
- VideoFilePlaybackController.swift

UPDATED:
- CaptureSessionManager.swift
- ContentView.swift
- FrameAnalyzer.swift
- MinimapDatasetRecorder.swift

How to test without the console:
1. Run the app.
2. Open the Live Input menu in the bottom bar.
3. Choose Open Video File.
4. Select an uncropped 16:9 Motorfest gameplay recording.
5. Leave Analyzer enabled.

How to read the result:
- GPS ROUTE DETECTED + a magenta highlight over the yellow trail = working.
- NO GPS ROUTE + no magenta highlight = minimap found, no usable waypoint trail.
- MINIMAP NOT FOUND = the HUD is hidden, cropped, moved, or not Motorfest.

Playback controls:
- Play/pause, jump backward/forward 10 seconds, scrub, and loop.
- The refresh button restarts the selected test video.
- Choose Use Live Capture to return to the capture card.

Video requirements:
- Use the complete gameplay image, not a minimap-only crop.
- Use 16:9 footage with the default Motorfest HUD layout.
- Browser chrome, black borders, editing crops, relocated HUD elements, and
  YouTube overlays can move the minimap outside the calibrated detector box.
- A YouTube watch URL cannot be decoded by AVPlayer into analyzer frames.
  Use a local video you own, a permitted clean screen recording, or capture a
  full-screen browser window through OBS Virtual Camera and use Live Capture.


RACING TRAINER - SMOOTH ROUTE OVERLAY UPDATE

UPDATED:
- FrameAnalyzer.swift
- CaptureSessionManager.swift
- ContentView.swift
- VideoFilePlaybackController.swift

What changed:
- Minimap analysis ceiling increased from 4 FPS to 30 FPS.
- Local video frame delivery increased from 15 FPS to 30 FPS.
- The analyzer still permits only one minimap job at a time, so old frames
  cannot accumulate in a processing queue.
- If the main UI falls behind, stale completed masks are skipped.
- All minimap values and the mask now publish as one atomic SwiftUI update.
- Route-mask scaling uses smoother interpolation.

How to verify:
- Play the same rotating-minimap video with Analyzer enabled.
- Frame Analyzer's Map FPS row should end in / 30.0.
- Compare the actual Map FPS and Map Time. Performance depends on the Mac.
- The magenta mask should follow rotation with much smaller visible jumps.
