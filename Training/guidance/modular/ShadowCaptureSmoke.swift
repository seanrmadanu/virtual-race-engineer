import AVFoundation
import Foundation

/// Exercises the native worker and recorder with real pixels. This is NOT a live shadow session.
@main
enum ShadowCaptureSmoke {
    final class Clock {
        private let lock = NSLock()
        private var time = 10.0
        func now() -> Double { lock.lock(); defer { lock.unlock() }; return time }
        func set(_ time: Double) { lock.lock(); self.time = time; lock.unlock() }
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw ShadowSessionRecorder.Failure(message: "Usage: smoke VIDEO OUTPUT_ROOT")
        }
        let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ShadowSessionRecorder.Failure(message: "No video track.")
        }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: 95, preferredTimescale: 600), duration: CMTime(seconds: 12, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ShadowSessionRecorder.Failure(message: "Cannot decode.") }
        var config = ShadowRunConfiguration()
        config.hudProfile = "reference-video2-v1"; config.speedUnit = "km/h"; config.recordHUDImages = true
        config.carSetupID = "UNCONFIRMED_smoke_test_not_live"
        let clock = Clock()
        let sink = try ShadowSessionRecorder(root: URL(fileURLWithPath: CommandLine.arguments[2]), configuration: config)
        let modules = ModularVideoModules(profileID: config.hudProfile)
        let pipeline = ShadowCapturePipeline(configuration: config, sink: sink, clock: clock.now, startWatchdog: false,
            resetModules: { modules.reset() }, analyze: { buffer, ticket, start in
                let values = modules.analyze(pixelBuffer: buffer, capturedAt: ticket.receivedAt, startedAt: start,
                    session: ticket.generation, confirmedSpeedUnit: "km/h")
                clock.set(max(start, values.values.map(\.completedAt).max() ?? start))
                return values
            })
        let source = ShadowSource(kind: .syntheticTest, identifier: "accelerated-replay-virtual-clock",
            name: "Video 2 real pixels; synthetic receipt clock; NOT live")
        var token = pipeline.begin(source), nextPTS = 95.0, count = 0
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts >= nextPTS, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            clock.set(10 + pts - 95)
            if count == 50 { pipeline.invalidate("smoke_seek_reset"); token = pipeline.begin(source) }
            pipeline.receive(buffer, sourcePTS: pts, receivedAt: clock.now(), sourceToken: token)
            pipeline.flush()
            if let failure = pipeline.lastError { throw ShadowSessionRecorder.Failure(message: failure) }
            nextPTS = pts + 0.1 - 1e-5; count += 1
        }
        guard reader.status == .completed else { throw reader.error ?? ShadowSessionRecorder.Failure(message: "Incomplete decode.") }
        clock.set(clock.now() + 1); pipeline.poll(); pipeline.flush()
        pipeline.stop(reason: "accelerated_smoke_test_finished"); pipeline.flush()
        print("SMOKE_SESSION=\(sink.directory.path)")
        print("Fed \(count) real decoded frames. No live session, training labels, or calibration created.")
    }
}
