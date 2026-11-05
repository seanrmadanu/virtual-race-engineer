import AVFoundation
import CryptoKit
import Foundation

nonisolated struct GuidanceAnalysisConfiguration: Codable, Sendable {
    var start = 0.0
    var end: Double? = nil
    var hudProfile = "motorfest-standard-v1"
    var speedUnit = "km/h"
    var camera = RoadCameraMode.chase
}

nonisolated enum ReviewFileIdentity {
    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 2 * 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation(); hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// Native offline analysis, owned serially by this actor. UI never shells out
/// to Python or reuses predictions from a different recording.
actor GuidanceVideoAnalyzer {
    static let version = "guidance-route-v3-road-lines-v1-turn-timing-v4-corner-technique-v1"

    func analyze(url: URL, output: URL, configuration config: GuidanceAnalysisConfiguration,
                 progress: @Sendable (Double, String) async -> Void) async throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        let before = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        await progress(0, "Checking video identity…")
        let sourceHash = try ReviewFileIdentity.hash(url)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let end = min(config.end ?? duration, duration)
        guard duration.isFinite, duration > 0, duration <= 7200,
              config.start.isFinite, config.start >= 0, end.isFinite, end > config.start,
              config.end == nil || config.end! <= duration,
              ["motorfest-standard-v1", "reference-video2-v1", "unconfirmed"].contains(config.hudProfile),
              ["km/h", "mph", "unknown"].contains(config.speedUnit),
              let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ModelReviewError.invalid("Choose a valid range inside a Motorfest recording of up to two hours.")
        }
        let transform = try await track.load(.preferredTransform)
        guard abs(transform.b) < 0.001, abs(transform.c) < 0.001, transform.a > 0, transform.d > 0 else {
            throw ModelReviewError.invalid("Use an unrotated, uncropped gameplay recording for this HUD profile.")
        }
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)
        let historyStart = max(0, config.start - 2)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: historyStart, preferredTimescale: 60000),
                                       end: CMTime(seconds: end, preferredTimescale: 60000))
        guard reader.startReading() else { throw reader.error ?? ModelReviewError.invalid("This video cannot be decoded.") }
        defer { reader.cancelReading() }
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw ModelReviewError.invalid("This analysis folder already exists. Start a new run.")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var finished = false
        defer {
            if !finished { try? Data("Analysis incomplete or cancelled. No review bundle was published.\n".utf8).write(to: output.appendingPathComponent("INCOMPLETE.txt")) }
        }
        let trace = output.appendingPathComponent("observations.jsonl")
        FileManager.default.createFile(atPath: trace.path, contents: nil)
        let handle = try FileHandle(forWritingTo: trace)
        defer { try? handle.close() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let executableHash = try Bundle.main.executableURL.map { try ReviewFileIdentity.hash($0) } ?? Self.version
        let pipelineHash = ReviewFileIdentity.hash(Data((Self.version + executableHash).utf8) + (try encoder.encode(config)))
        let modules = ModularVideoModules(profileID: config.hudProfile, camera: config.camera)
        var history = CoachObservationHistory()
        var last: CMSampleBuffer?, tick = Int(ceil(historyStart * 10))
        var availableAt = historyStart, processedPTS = -1.0, events: [ModelReviewEvent] = [], sampleCount = 0
        var turnTracker = TurnGuidanceTracker()
        var turnSamples: [TurnGuidanceSample] = []
        var cornerTracker = CornerTechniqueTracker()
        var cornerSamples: [CornerTechniqueSample] = []
        var roadObservations: [RoadLineObservation] = []

        func process(_ sample: CMSampleBuffer, time: Double) throws {
            try Task.checkCancellation()
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts <= time + 1e-9, let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
            let ratio = Double(CVPixelBufferGetWidth(pixels)) / Double(CVPixelBufferGetHeight(pixels))
            guard abs(ratio - 16 / 9.0) < 0.025 else {
                throw ModelReviewError.invalid("This profile needs uncropped 16:9 Motorfest footage.")
            }
            if pts > processedPTS {
                let observations = modules.analyze(pixelBuffer: pixels, capturedAt: pts,
                    startedAt: max(time, availableAt), session: 1, confirmedSpeedUnit: config.speedUnit == "unknown" ? nil : config.speedUnit)
                history.append(observations, frameTime: pts, session: 1)
                availableAt = observations.values.map(\.completedAt).max() ?? time
                processedPTS = pts
            }
            guard let row = history.sample(at: time).last else { return }
            // Warm the phase tracker with the causal lead-in, without publishing
            // pre-range samples or changing Category 1's existing initialization.
            let corner = cornerTracker.update(row: row, session: 1)
            guard time >= config.start else { return }
            let proposal = SlowdownRules.propose(row: row, calibration: nil, carSetup: "", hud: config.hudProfile)
            let decision = SlowdownEvidenceGuard.apply(proposal, row: row, session: 1, calibration: nil,
                                                       carSetup: "", hud: config.hudProfile)
            let turn = turnTracker.update(row: row, session: 1)
            turnSamples.append(turn)
            cornerSamples.append(corner)
            let record = TraceRow(time: time, sourcePTS: pts, observations: row.observations, ages: row.ages,
                                  decision: decision, turnGuidance: turn, cornerTechnique: corner)
            try handle.write(contentsOf: encoder.encode(record)); try handle.write(contentsOf: Data([10]))
            sampleCount += 1
            if let item = row.observations["road"], var road = item.value?.road,
               road.capturedAt > (roadObservations.last?.capturedAt ?? -1) {
                road.availableAt = item.completedAt
                roadObservations.append(road)
            }
            // Keep integer moments for AI comparisons and exact cue onset moments.
            guard events.isEmpty || tick % 10 == 0 || turn.isCueStart || corner.isPhaseStart else { return }
            events.append(Self.reviewEvent(row: row, decision: decision, turn: turn, corner: corner))
        }

        while let sample = readerOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts.isFinite else { continue }
            while Double(tick) / 10 < pts && Double(tick) / 10 < end {
                let time = Double(tick) / 10
                if let last { try autoreleasepool { try process(last, time: time) } }
                if tick % 10 == 0 {
                    await progress(max(0, (time - config.start) / (end - config.start)), "Analyzing \(Int(max(0, time - config.start))) / \(Int(end - config.start)) seconds…")
                }
                tick += 1
            }
            last = sample
        }
        guard reader.status == .completed else { throw reader.error ?? ModelReviewError.invalid("Video decoding stopped before completion.") }
        while Double(tick) / 10 < end {
            if let last { try autoreleasepool { try process(last, time: Double(tick) / 10) } }
            tick += 1
        }
        try Task.checkCancellation()
        try handle.synchronize()
        let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else {
            throw ModelReviewError.invalid("The recording changed during analysis. Run it again on the unchanged file.")
        }
        let bundle = ModelReviewBundle(schemaVersion: "racing-trainer-review-v2", title: "\(url.deletingPathExtension().lastPathComponent) · Guidance Test",
            source: ModelReviewSource(filename: url.lastPathComponent, sha256: sourceHash, duration: duration),
            modelSHA256: pipelineHash, predictionsSHA256: try ReviewFileIdentity.hash(trace), events: events,
            roadObservations: roadObservations, turnGuidanceSamples: turnSamples, cornerTechniqueSamples: cornerSamples)
        try bundle.validate()
        let bundleURL = output.appendingPathComponent("video.review.json")
        try encoder.encode(config).write(to: output.appendingPathComponent("configuration.json"), options: .atomic)
        try encoder.encode(bundle).write(to: bundleURL, options: .atomic)
        finished = true
        await progress(1, "Analyzed \(sampleCount) samples. \(events.count) review moments are ready.")
        return bundleURL
    }

    nonisolated static func reviewEvent(row: CoachHistoryRow, decision: SlowdownDecision,
                                        turn: TurnGuidanceSample, corner: CornerTechniqueSample? = nil) -> ModelReviewEvent {
        let time = row.time
        let route = row.observations["geometry"]?.value
        let rawDirection = route?.direction ?? "unknown"
        let direction = ["left", "right", "straight"].contains(rawDirection) ? rawDirection : "unknown"
        let target = direction == "unknown" ? "unknown" : direction == "straight" ? "straight_segment" : "next_corner"
        let diagnostics = CoachModule.allCases.map { key -> ModuleReviewDiagnostic in
            guard let item = row.observations[key.rawValue] else {
                return ModuleReviewDiagnostic(name: key.rawValue, value: "Missing", units: "unknown", state: "missing",
                    confidence: 0, confidenceKind: "heuristic_not_probability", age: nil, capturedAt: nil, version: "2", failure: "No causal sample yet", evidence: [:])
            }
            let value = item.value?.number.map { String(format: "%.0f", $0) }
                ?? item.value?.direction ?? item.value?.flag.map { $0 ? "Available" : "Unavailable" } ?? "Missing"
            return ModuleReviewDiagnostic(name: key.rawValue, value: value, units: item.units ?? "unknown",
                state: item.state.rawValue, confidence: Double(item.confidence), confidenceKind: item.confidenceKind ?? "heuristic_not_probability",
                age: row.ages[key.rawValue], capturedAt: item.capturedAt, version: item.version,
                failure: item.failureReason, evidence: item.evidence ?? [:])
        }
        return ModelReviewEvent(id: String(format: "modular-%07.1f", time), time: time,
            direction: direction, target: target, phase: "unknown",
            reasons: ["Route direction is separate from vehicle steering", "Experimental video analysis"],
            diagnostics: ModuleReviewDiagnostics(cue: decision.acceptedCue.rawValue, proposedCue: decision.proposal.cue.rawValue,
                proposalReason: decision.proposal.reason, origin: decision.proposal.origin, suppressionReasons: decision.suppressionReasons,
                legacyPolicy: "Not evaluated in this run", modules: diagnostics),
            roadLines: row.observations["road"]?.value?.road, turnGuidance: turn, cornerTechnique: corner)
    }

    private struct TraceRow: Encodable {
        let time: Double
        let sourcePTS: Double
        let observations: [String: CoachModuleObservation]
        let ages: [String: Double]
        let decision: SlowdownDecision
        let turnGuidance: TurnGuidanceSample
        let cornerTechnique: CornerTechniqueSample
    }
}
