import AVFoundation
import Foundation

/// Drives the real FrameAnalyzer at the video's frame rate and records, every
/// frame, the wheel target (SteeringWheelTarget) and the drawn angle
/// (SteeringWheelMotion). Prints motion-quality numbers and writes a CSV.
/// Usage: wheel-trace VIDEO START SECONDS OUT.csv
@main struct WheelTrace {
    @MainActor static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        UserDefaults.standard.setVolatileDomain(["guidance.hudProfile": "reference-video2-v1", "guidance.speedUnit": "km/h"],
                                               forName: UserDefaults.argumentDomain)
        let analyzer = FrameAnalyzer(targetSpeedAnalysisFPS: 15, targetMinimapAnalysisFPS: 30)
        analyzer.reset()
        let asset = AVURLAsset(url: URL(fileURLWithPath: args[0]))
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let fps = Double(try await track.load(.nominalFrameRate))
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: Double(args[1])!, preferredTimescale: 60000),
                                       duration: CMTime(seconds: Double(args[2])!, preferredTimescale: 60000))
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); precondition(reader.startReading())
        var frames: [(CVPixelBuffer, Double)] = []
        while let sample = output.copyNextSampleBuffer(), let pixels = CMSampleBufferGetImageBuffer(sample) {
            frames.append((pixels, CMSampleBufferGetPresentationTimeStamp(sample).seconds))
        }
        let motion = SteeringWheelMotion()
        let filter = SteeringWheelTargetFilter()
        var rows: [(video: Double, target: Double?, angle: Double, title: String)] = []
        let began = ProcessInfo.processInfo.systemUptime
        for (index, (pixels, pts)) in frames.enumerated() {
            let due = began + Double(index) / fps
            let wait = due - ProcessInfo.processInfo.systemUptime
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
            analyzer.receive(pixels)
            let now = ProcessInfo.processInfo.systemUptime
            let target = filter.degrees(turn: analyzer.turnGuidance, route: analyzer.coachSnapshot, at: now)
            let angle = motion.advance(toward: target, at: now, reduceMotion: false)
            let fresh = analyzer.turnGuidance.isFresh(at: now)
            rows.append((pts, target, angle, fresh ? analyzer.turnGuidance.cue.title : "Guidance unavailable"))
        }
        var csv = "video_time,target,angle,title\n"
        for r in rows { csv += String(format: "%.3f,%@,%.2f,%@\n", r.video, r.target.map { String(format: "%.1f", $0) } ?? "", r.angle, r.title) }
        try csv.write(toFile: args[3], atomically: true, encoding: .utf8)

        // Quality numbers.
        let angles = rows.map(\.angle)
        let targets = rows.map { $0.target ?? .nan }
        var targetChanges = 0, bigTargetJumps = 0, reversals = 0, missing = 0
        for (a, b) in zip(targets, targets.dropFirst()) {
            if a.isNaN != b.isNaN || (!a.isNaN && abs(a - b) > 0.5) { targetChanges += 1 }
            if !a.isNaN, !b.isNaN, abs(a - b) > 30 { bigTargetJumps += 1 }
        }
        missing = targets.filter(\.isNaN).count
        var lastDirection = 0.0
        for (a, b) in zip(angles, angles.dropFirst()) where abs(b - a) > 0.05 {
            let direction = b > a ? 1.0 : -1.0
            if lastDirection != 0, direction != lastDirection { reversals += 1 }
            lastDirection = direction
        }
        let speeds = zip(angles, angles.dropFirst()).map { abs($1 - $0) * fps }
        let titles = zip(rows, rows.dropFirst()).filter { $0.title != $1.title }.count
        print(String(format: "%d frames | target changes %d (jumps >30° %d, missing %.0f%%) | wheel direction reversals %d | max wheel speed %.0f°/s | instruction changes %d",
                     rows.count, targetChanges, bigTargetJumps, Double(missing) / Double(rows.count) * 100, reversals, speeds.max() ?? 0, titles))
    }
}
