import Foundation

/// Rerun only turn timing against an immutable native observation trace.
/// The video/source identity and original perception run remain explicit.
@main struct ReplayTurnTiming {
    struct Row: Decodable {
        let time: Double
        let observations: [String: CoachModuleObservation]
        let ages: [String: Double]
        let decision: SlowdownDecision
    }
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3 else { throw ModelReviewError.invalid("Usage: replay-turn-timing.sh REVIEW_BUNDLE OBSERVATIONS NEW_OUTPUT") }
        let input = URL(fileURLWithPath: args[0]), traceURL = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[2])
        let base = try ModelReviewBundle.decode(Data(contentsOf: input))
        guard try ReviewFileIdentity.hash(traceURL) == base.predictionsSHA256,
              !FileManager.default.fileExists(atPath: output.path) else {
            throw ModelReviewError.invalid("Use the matching original trace and a new output directory.")
        }
        var tracker = TurnGuidanceTracker(), samples: [TurnGuidanceSample] = [], events: [ModelReviewEvent] = []
        let originalTimes = Set(base.events.map(\.time))
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for line in try Data(contentsOf: traceURL).split(separator: 10) {
            let row = try decoder.decode(Row.self, from: Data(line))
            let history = CoachHistoryRow(time: row.time, observations: row.observations, ages: row.ages)
            let cue = tracker.update(row: history, session: row.observations["geometry"]?.sourceSessionID ?? 1)
            samples.append(cue)
            if originalTimes.contains(row.time) || cue.isCueStart {
                events.append(GuidanceVideoAnalyzer.reviewEvent(row: history, decision: row.decision, turn: cue))
            }
        }
        let data = try encoder.encode(samples)
        let executableHash = try Bundle.main.executableURL.map { try ReviewFileIdentity.hash($0) } ?? TurnGuidanceTracker.version
        let modelHash = ReviewFileIdentity.hash(Data((base.modelSHA256 + TurnGuidanceTracker.version + executableHash).utf8))
        let predictionsHash = ReviewFileIdentity.hash(Data(base.predictionsSHA256.utf8) + data)
        let result = ModelReviewBundle(schemaVersion: base.schemaVersion, title: base.title, source: base.source,
            modelSHA256: modelHash, predictionsSHA256: predictionsHash, events: events,
            roadObservations: base.roadObservations, turnGuidanceSamples: samples)
        try result.validate()
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("turn-samples.json"), options: .atomic)
        try encoder.encode(result).write(to: output.appendingPathComponent("video.review.json"), options: .atomic)
        let provenance = ["version": TurnGuidanceTracker.version, "mode": "causal_timing_replay_of_saved_perception",
            "sourceSHA256": base.source.sha256, "perceptionModelSHA256": base.modelSHA256,
            "observationTraceSHA256": base.predictionsSHA256, "timingExecutableSHA256": executableHash,
            "originalReviewBundle": input.path, "originalObservationTrace": traceURL.path,
            "qualification": "experimental_unreviewed_no_timing_accuracy_claim"]
        try encoder.encode(provenance).write(to: output.appendingPathComponent("provenance.json"), options: .atomic)
        print("Samples: \(samples.count); events: \(events.count)")
        for stage in [TurnGuidanceStage.headsUp, .turnNow] {
            let cues = samples.filter { $0.stage == stage && $0.isCueStart }
            print("\(stage.rawValue): \(cues.count) cue onsets")
            print(cues.map { "\(reviewPreciseTimestamp($0.time)) \($0.direction)" }.joined(separator: ", "))
        }
        print("Saved: \(output.appendingPathComponent("video.review.json").path)")
    }
}
