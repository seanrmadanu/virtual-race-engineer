import AVFoundation
import Combine
import Foundation

/// Feeds the real FrameAnalyzer at the video's own frame rate and measures how
/// often road lines are published and how old each one is when it arrives.
/// Usage: road-lag-benchmark VIDEO START SECONDS
@main struct RoadLagBenchmark {
    @MainActor static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3, let start = Double(args[1]), let seconds = Double(args[2]) else {
            print("Usage: road-lag-benchmark VIDEO START SECONDS"); exit(2)
        }
        UserDefaults.standard.setVolatileDomain(["guidance.hudProfile": "reference-video2-v1", "guidance.speedUnit": "km/h"],
                                               forName: UserDefaults.argumentDomain)
        let analyzer = FrameAnalyzer(targetSpeedAnalysisFPS: 15, targetMinimapAnalysisFPS: 30)
        analyzer.reset()
        var roadArrivals: [(arrived: Double, captured: Double)] = []
        var guidanceArrivals = 0
        let roadSink = analyzer.$roadLines.sink { road in
            guard road.capturedAt > 0 else { return }
            roadArrivals.append((ProcessInfo.processInfo.systemUptime, road.capturedAt))
        }
        let guidanceSink = analyzer.$turnGuidance.sink { _ in guidanceArrivals += 1 }
        defer { roadSink.cancel(); guidanceSink.cancel() }

        // Decode ahead so pacing measures the analyzer, not the decoder.
        let asset = AVURLAsset(url: URL(fileURLWithPath: args[0]))
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let fps = Double(try await track.load(.nominalFrameRate))
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000),
                                       duration: CMTime(seconds: seconds, preferredTimescale: 60000))
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); precondition(reader.startReading())
        var frames: [CVPixelBuffer] = []
        while let sample = output.copyNextSampleBuffer(), let pixels = CMSampleBufferGetImageBuffer(sample) { frames.append(pixels) }

        let began = ProcessInfo.processInfo.systemUptime
        for (index, pixels) in frames.enumerated() {
            let due = began + Double(index) / Double(fps)
            let wait = due - ProcessInfo.processInfo.systemUptime
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
            analyzer.receive(pixels)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let elapsed = Double(frames.count) / fps
        let ages = roadArrivals.map { ($0.arrived - $0.captured) * 1000 }.sorted()
        let gaps = zip(roadArrivals, roadArrivals.dropFirst()).map { ($1.arrived - $0.arrived) * 1000 }.sorted()
        func pct(_ v: [Double], _ p: Double) -> Double { v.isEmpty ? .nan : v[min(v.count - 1, Int(Double(v.count) * p))] }
        print(String(format: "input %.0f fps, %d frames | road updates %.1f/s, age ms median %.0f p95 %.0f, gap ms median %.0f p95 %.0f max %.0f | guidance updates %.1f/s",
                     fps, frames.count, Double(roadArrivals.count) / elapsed, pct(ages, 0.5), pct(ages, 0.95),
                     pct(gaps, 0.5), pct(gaps, 0.95), gaps.last ?? .nan, Double(guidanceArrivals) / elapsed))
    }
}
