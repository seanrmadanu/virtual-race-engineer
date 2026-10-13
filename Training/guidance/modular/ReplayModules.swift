import AVFoundation
import CryptoKit
import Foundation

@main
enum ReplayModules {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.count == 2, args[0] == "--self-test" {
            try runNativeModuleChecks(imageURL: URL(fileURLWithPath: args[1])); return
        }
        guard args.count == 4, ["km/h", "mph", "unknown"].contains(args[2]), ["reference-video2-v1", "unconfirmed"].contains(args[3]) else {
            throw Failure(message: "Usage: replay-modules.sh VIDEO NEW_OUTPUT_DIRECTORY km/h|mph|unknown reference-video2-v1|unconfirmed")
        }
        let input = URL(fileURLWithPath: args[0]), output = URL(fileURLWithPath: args[1])
        let sourceBefore = try input.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let pipelineHash = ProcessInfo.processInfo.environment["RACING_MODULE_PIPELINE_SHA256"] ?? ""
        guard pipelineHash.count == 64 else { throw Failure(message: "Run through replay-modules.sh to record the compiled source identity.") }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw Failure(message: "Output exists; use a new directory.") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let sourceHandle = try FileHandle(forReadingFrom: input)
        var hasher = SHA256()
        while let chunk = try sourceHandle.read(upToCount: 1048576), !chunk.isEmpty { hasher.update(data: chunk) }
        try sourceHandle.close()
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration < 10800,
              let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure(message: "Invalid source.") }
        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        trackOutput.alwaysCopiesSampleData = false
        reader.add(trackOutput)
        guard reader.startReading() else { throw reader.error ?? Failure(message: "Cannot read recording.") }
        let traceURL = output.appendingPathComponent("observations.jsonl")
        FileManager.default.createFile(atPath: traceURL.path, contents: nil)
        let file = try FileHandle(forWritingTo: traceURL)
        defer { try? file.close() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let modules = ModularVideoModules(profileID: args[3])
        var history = CoachObservationHistory()
        var last: CMSampleBuffer?
        var tick = 0, availableAt = 0.0, processedPTS = -1.0, count = 0
        var stableStraight = 0
        func process(_ sample: CMSampleBuffer, at time: Double) throws {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard let pixels = CMSampleBufferGetImageBuffer(sample), pts <= time + 1e-9 else { return }
            if pts > processedPTS {
                let values = modules.analyze(pixelBuffer: pixels, capturedAt: pts, startedAt: max(time, availableAt),
                                             session: 1, confirmedSpeedUnit: args[2] == "unknown" ? nil : args[2])
                history.append(values, frameTime: pts, session: 1)
                availableAt = values.values.map(\.completedAt).max() ?? time
                processedPTS = pts
            }
            let rows = history.sample(at: time)
            guard let row = rows.last else { return }
            let proposed = SlowdownRules.propose(row: row, calibration: nil, carSetup: "", hud: "motorfest-standard-v1")
            let decision = SlowdownEvidenceGuard.apply(proposed, row: row, session: 1, calibration: nil,
                                                       carSetup: "", hud: "motorfest-standard-v1")
            let legacy: String
            if let route = row.observations["geometry"], let value = route.value,
               let direction = RouteTurnDirection(rawValue: value.direction ?? ""),
               let severity = TurnSeverity(rawValue: value.severity ?? ""), let timing = TurnTiming(rawValue: value.timing ?? "") {
                stableStraight = direction == .straight ? stableStraight + 1 : 0
                let legacyRoute = PerceptionObservation(value: RouteGuidance(direction: direction, severity: severity, timing: timing),
                    state: route.state, confidence: route.confidence, capturedAt: route.capturedAt, completedAt: route.completedAt,
                    sourceSessionID: 1, implementation: route.implementation, version: route.version, failureReason: route.failureReason)
                let speed = row.observations["speed"].map { speed in
                    PerceptionObservation(value: speed.value?.number.map(Int.init), state: speed.state, confidence: speed.confidence,
                        capturedAt: speed.capturedAt, completedAt: speed.completedAt, sourceSessionID: 1,
                        implementation: speed.implementation, version: speed.version, failureReason: speed.failureReason)
                }
                legacy = CoachSafetyPolicy.decide(route: legacyRoute, speed: args[2] == "km/h" ? speed : nil,
                    stableStraightFrames: stableStraight, sessionID: 1, now: time).action.rawValue
            } else { legacy = "UNAVAILABLE"; stableStraight = 0 }
            // The current image classifier remains a separate, preserved baseline.
            let record = Record(time: time, sourcePTS: pts, session: 1, modules: row.observations, ages: row.ages,
                                history: rows, decision: decision, legacyPolicy: legacy)
            try file.write(contentsOf: encoder.encode(record)); try file.write(contentsOf: Data([10]))
            count += 1
            if count % 300 == 0 { print("\(count) samples; \(Int(time))/\(Int(duration)) seconds") ; fflush(stdout) }
        }
        while let sample = trackOutput.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts.isFinite else { continue }
            while Double(tick) / 10 < pts, Double(tick) / 10 < duration {
                if let last { try autoreleasepool { try process(last, at: Double(tick) / 10) } }
                tick += 1
            }
            last = sample
        }
        guard reader.status == .completed else { throw reader.error ?? Failure(message: "Decode interrupted.") }
        while Double(tick) / 10 < duration {
            if let last { try process(last, at: Double(tick) / 10) }; tick += 1
        }
        let metadata = Metadata(schema: "modular-observations-v1", filename: input.lastPathComponent,
            sha256: hash, duration: duration, sampleCount: count, unit: args[2], samplingHz: 10,
            legacyBaselineScope: "CoachSafetyPolicy on modular measurements, not full tracked live engine",
            status: "development_only_unreviewed_uncalibrated", hudProfile: args[3], pipelineSHA256: pipelineHash)
        let sourceAfter = try input.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard sourceBefore.fileSize == sourceAfter.fileSize,
              sourceBefore.contentModificationDate == sourceAfter.contentModificationDate else {
            throw Failure(message: "Source changed during replay. Incomplete output must not be used.")
        }
        try encoder.encode(metadata).write(to: output.appendingPathComponent("manifest.json"), options: .atomic)
        print("Saved \(count) causal module rows. No model trained. No live advice enabled.")
    }
    struct Failure: Error { let message: String }
    struct Record: Encodable {
        let time: Double, sourcePTS: Double
        let session: Int
        let modules: [String: CoachModuleObservation]
        let ages: [String: Double]
        let history: [CoachHistoryRow]
        let decision: SlowdownDecision
        let legacyPolicy: String
    }
    struct Metadata: Encodable {
        let schema: String, filename: String, sha256: String
        let duration: Double
        let sampleCount: Int
        let unit: String
        let samplingHz: Int
        let legacyBaselineScope: String, status: String
        let hudProfile: String
        let pipelineSHA256: String
    }
}
