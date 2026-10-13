import AVFoundation
import Foundation

/// Exercise the actual main-app FrameAnalyzer with paced native video frames.
@main struct LiveGuidanceSmoke {
    @MainActor static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3, let start = Double(args[1]), let end = Double(args[2]) else {
            throw ModelReviewError.invalid("Usage: check-live-guidance.sh VIDEO START END")
        }
        UserDefaults.standard.setVolatileDomain(["guidance.hudProfile": "reference-video2-v1", "guidance.speedUnit": "km/h"],
                                               forName: UserDefaults.argumentDomain)
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
        var nextTime = start, frames = 0, lastPublishedTime = -Double.infinity
        var stages: [String: Int] = [:]
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts >= nextTime, let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            nextTime = pts + 0.095
            analyzer.receive(pixels); frames += 1
            try await Task.sleep(nanoseconds: 100_000_000)
            let result = analyzer.turnGuidance
            if result.cue.time > lastPublishedTime {
                lastPublishedTime = result.cue.time
                stages[result.cue.stage.rawValue, default: 0] += 1
                let now = ProcessInfo.processInfo.systemUptime
                let steering = result.steering(at: now)
                precondition(analyzer.coachSnapshot.action != .brake && analyzer.coachSnapshot.action != .accelerateIfClear)
                if result.cue.stage == .headsUp { precondition(steering == .center || steering == .unavailable) }
                print(String(format: "%.2f", pts), result.cue.stage.rawValue, result.cue.direction,
                      steering.rawValue, "speed=\(analyzer.detectedSpeed.map(String.init) ?? "missing")")
            }
        }
        precondition(reader.status == .completed)
        try await Task.sleep(nanoseconds: 800_000_000)
        precondition(analyzer.turnGuidance.steering(at: ProcessInfo.processInfo.systemUptime) == .unavailable)
        precondition(stages["heads_up", default: 0] > 0, "No upcoming cue was published")
        analyzer.reset()
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(analyzer.turnGuidance.cue.stage == .unavailable)
        print("PASS main FrameAnalyzer: \(frames) frames; \(stages); centered heads-up, no pedal commands, stale/reset suppression")
    }
}
