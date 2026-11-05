import AppKit
import AVFoundation
import SwiftUI

/// Paced native frames, real analyzer output, and off-screen wheel rendering.
@main struct SteeringWheelChecks {
    @MainActor static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 5, let start = Double(args[1]), let end = Double(args[2]), end > start else {
            throw ModelReviewError.invalid("Usage: check-steering-wheel.sh VIDEO START END PROFILE OUTPUT")
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        UserDefaults.standard.setVolatileDomain(["guidance.hudProfile": args[3], "guidance.speedUnit": "km/h"],
                                               forName: UserDefaults.argumentDomain)
        let directory = URL(fileURLWithPath: args[4], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if ProcessInfo.processInfo.environment["RACING_WHEEL_RENDER_ONLY"] != nil {
            try render(directory: directory)
            return
        }
        let analyzer = FrameAnalyzer(targetSpeedAnalysisFPS: 15, targetMinimapAnalysisFPS: 30)
        analyzer.reset()
        let asset = AVURLAsset(url: URL(fileURLWithPath: args[0]))
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000),
                                      end: CMTime(seconds: end, preferredTimescale: 60000))
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); precondition(reader.startReading())
        let motion = SteeringWheelMotion()
        #if WHEEL_BASELINE
        let baselineMotion = BaselineWheelMotion()
        #endif
        var trace: [[String: Any]] = [], nextTime = start, lastTitle = "", lastTarget: Double?
        var activeFrames = 0, sameCueTargetChanges = 0
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts + 0.001 >= nextTime, let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            nextTime = pts + 1.0 / 30
            analyzer.receive(pixels)
            try await Task.sleep(nanoseconds: 33_333_333)
            let now = ProcessInfo.processInfo.systemUptime, cue = analyzer.turnGuidance
            let target = SteeringWheelTarget.degrees(turn: cue, at: now)
            let angle = motion.advance(toward: target, at: now, reduceMotion: false, session: cue.sourceSessionID)
            if let target, target != 0 { activeFrames += 1 }
            if cue.cue.title == lastTitle, let target, let lastTarget, target != lastTarget { sameCueTargetChanges += 1 }
            lastTitle = cue.cue.title; lastTarget = target
            var row: [String: Any] = ["time": pts, "title": cue.cue.title, "stage": cue.cue.stage.rawValue,
                "target": target as Any? ?? NSNull(), "angle": angle, "reason": cue.cue.reason]
            #if WHEEL_BASELINE
            let old = BaselineWheelTarget.degrees(turn: cue, route: analyzer.coachSnapshot, at: now)
            row["baselineTarget"] = old as Any? ?? NSNull()
            row["baselineAngle"] = baselineMotion.advance(toward: old, at: now, reduceMotion: false)
            #endif
            trace.append(row)
            precondition(analyzer.coachSnapshot.action != .brake && analyzer.coachSnapshot.action != .accelerateIfClear)
            if [.headsUp, .preview].contains(cue.cue.stage) { precondition(target == nil || target == 0) }
        }
        precondition(reader.status == .completed)
        precondition(activeFrames > 20, "No sustained steering cue exercised")
        precondition(sameCueTargetChanges == 0, "Stable cue changed wheel target")
        try JSONSerialization.data(withJSONObject: trace, options: [.sortedKeys, .prettyPrinted])
            .write(to: directory.appendingPathComponent("wheel-trace.json"))
        try await Task.sleep(nanoseconds: 800_000_000)
        precondition(SteeringWheelTarget.degrees(turn: analyzer.turnGuidance,
            at: ProcessInfo.processInfo.systemUptime) == nil)
        analyzer.reset()
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(analyzer.turnGuidance.cue.stage == .unavailable)
        print("PASS \(trace.count) native frames; \(activeFrames) active steering frames; zero same-cue target changes; stale/source reset; no pedal commands")

        try render(directory: directory)
    }

    @MainActor static func render(directory: URL) throws {
        precondition(NSImage(named: "SteeringWheel") != nil, "The compiled wheel asset is missing")
        let preview = HStack(spacing: 16) {
            ForEach(Array([0.0, 45, -45, 120].enumerated()), id: \.offset) { _, angle in
                VStack {
                    Text(angle == 0 ? "Go straight" : abs(angle) == 120 ? "Turn right" : angle < 0 ? "Follow the left bend" : "Follow the right bend")
                        .font(.headline)
                    SteeringWheelArtwork(rotation: angle, accent: .orange, diameter: 190, isAvailable: true)
                }
            }
        }.padding(24).background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: preview)
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("wheel-poses.png"))
        let sidebar = TrainerSidebar(gameVolume: .constant(0.8), gameMuted: .constant(false),
            gameAudioAvailable: true, gameAudioStatus: "Playing audio from Video 1.mp4",
            onReviewTurns: {}, onReviewTechnique: {}, onDiagnostics: {})
            .frame(width: 320, height: 650, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        let panel = NSHostingView(rootView: sidebar)
        window.contentView = panel
        panel.frame = CGRect(x: 0, y: 0, width: 320, height: 650)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            panel.appearance = NSAppearance(named: appearance)
            panel.layoutSubtreeIfNeeded()
            let bitmap = panel.bitmapImageRepForCachingDisplay(in: panel.bounds)!
            panel.cacheDisplay(in: panel.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("sidebar-\(name).png"))
        }
        print("Rendered actual wheel and sidebar views off screen; sidebar controls use preview values")
    }
}
