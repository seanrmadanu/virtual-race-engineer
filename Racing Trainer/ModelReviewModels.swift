import Foundation

nonisolated enum ReviewSkillCategory: String, Codable, CaseIterable, Identifiable {
    case basicTurns = "basic_turns"
    case cornerTechnique = "corner_technique"
    case advanced = "advanced"
    case slowdownTiming = "slowdown_timing"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .basicTurns: return "1 · Turns & Timing"
        case .cornerTechnique: return "2 · Corner Technique"
        case .advanced: return "3 · Advanced Driving"
        case .slowdownTiming: return "Slowdown Timing"
        }
    }
    var detail: String {
        switch self {
        case .basicTurns: return "Left, right and straight · upcoming-turn heads-up, then turn now. Review direction and timing separately."
        case .cornerTechnique: return "Approach, entry and exit are experimental. Apex and racing line are not trained yet."
        case .advanced: return "Planned: braking technique, linked corners, grip and traffic decisions. No trained outputs yet."
        case .slowdownTiming: return "Review proposed warnings, lift, brake and no-cue intervals. These are unreviewed proposals, not trained advice."
        }
    }
}

nonisolated enum ReviewVerdict: String, Codable, CaseIterable, Identifiable {
    case pending, correct, early, late, wrong, missed, unclear, unusable
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pending: return "Not Reviewed"
        case .correct: return "Correct"
        case .wrong: return "Wrong / Missed"
        case .early: return "Early"
        case .late: return "Late"
        case .missed: return "Missed Cue"
        case .unclear: return "Unsure"
        case .unusable: return "Unusable View"
        }
    }
}

nonisolated enum ModelReviewError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

nonisolated struct ModelReviewSource: Codable, Equatable {
    let filename: String
    let sha256: String
    let duration: Double
}

nonisolated struct ModelReviewEvent: Codable, Identifiable, Equatable {
    let id: String
    let time: Double
    let direction: String
    let target: String
    let phase: String
    let reasons: [String]
    var diagnostics: ModuleReviewDiagnostics? = nil
    var roadLines: RoadLineObservation? = nil
    var turnGuidance: TurnGuidanceSample? = nil

    func hasAnswer(in category: ReviewSkillCategory) -> Bool {
        switch category {
        case .basicTurns: return (turnGuidance?.direction ?? direction) != "unknown"
        case .cornerTechnique: return phase != "unknown"
        case .advanced: return false
        case .slowdownTiming: return diagnostics?.cue != nil && diagnostics?.cue != "cannot_judge"
        }
    }
    func summary(in category: ReviewSkillCategory) -> String {
        switch category {
        case .basicTurns:
            if let turnGuidance { return turnGuidance.title }
            return direction == "unknown" ? "Unknown" : "\(reviewLabel(direction)) · \(reviewLabel(target))"
        case .cornerTechnique: return reviewLabel(phase)
        case .advanced: return "Not trained"
        case .slowdownTiming: return reviewLabel(diagnostics?.cue ?? "cannot_judge")
        }
    }
}

nonisolated struct ModelReviewBundle: Codable, Equatable {
    let schemaVersion: String
    let title: String
    let source: ModelReviewSource
    let modelSHA256: String
    let predictionsSHA256: String
    let events: [ModelReviewEvent]
    var roadObservations: [RoadLineObservation]? = nil
    var turnGuidanceSamples: [TurnGuidanceSample]? = nil

    static let directions = ["unknown", "left", "right", "straight"]
    static let targets = ["unknown", "current_corner", "next_corner", "straight_segment"]
    static let phases = ["unknown", "approach", "entry", "apex_region", "exit", "transition", "straight"]

    static func decode(_ data: Data) throws -> Self {
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate()
        return result
    }

    func validate() throws {
        guard ["racing-trainer-review-v1", "racing-trainer-review-v2"].contains(schemaVersion), !title.isEmpty,
              !source.filename.isEmpty, source.duration.isFinite, source.duration > 0,
              validHash(source.sha256), validHash(modelSHA256), validHash(predictionsSHA256),
              !events.isEmpty, events.count <= 100_000 else {
            throw ModelReviewError.invalid("This test file is incomplete or uses an unsupported format.")
        }
        var ids = Set<String>()
        var previous = -Double.infinity
        for event in events {
            guard !event.id.isEmpty, ids.insert(event.id).inserted,
                  event.time.isFinite, event.time >= 0, event.time < source.duration, event.time > previous,
                  Self.directions.contains(event.direction), Self.targets.contains(event.target),
                  Self.phases.contains(event.phase) else {
                throw ModelReviewError.invalid("The test contains an invalid or duplicate timestamp or label.")
            }
            let validPair = (event.direction == "unknown" && event.target == "unknown")
                || (event.direction == "straight" && event.target == "straight_segment")
                || (["left", "right"].contains(event.direction) && ["current_corner", "next_corner"].contains(event.target))
            let validPhase = event.phase == "unknown"
                || (event.phase == "straight" && event.target == "straight_segment")
                || (event.phase == "approach" && event.target == "next_corner")
                || (["entry", "apex_region", "exit", "transition"].contains(event.phase) && event.target == "current_corner")
            guard validPair && validPhase else {
                throw ModelReviewError.invalid("The test has contradictory final model outputs.")
            }
            if schemaVersion == "racing-trainer-review-v2" {
                guard let diagnostics = event.diagnostics else { throw ModelReviewError.invalid("Module evidence is missing.") }
                try diagnostics.validate(at: event.time)
            }
            if let cue = event.turnGuidance {
                try cue.validate()
                guard cue.time == event.time else { throw ModelReviewError.invalid("Turn cue belongs to a different timestamp.") }
            }
            previous = event.time
        }
        var previousRoadTime = -Double.infinity
        var previousRoadAvailability = -Double.infinity
        for road in roadObservations ?? [] {
            guard road.capturedAt.isFinite, road.capturedAt >= 0, road.capturedAt < source.duration,
                  road.capturedAt > previousRoadTime, road.confidence.isFinite, (0...1).contains(road.confidence),
                  (road.availableAt ?? road.capturedAt).isFinite,
                  (road.availableAt ?? road.capturedAt) >= road.capturedAt,
                  (road.availableAt ?? road.capturedAt) >= previousRoadAvailability,
                  road.left.count <= 128, road.right.count <= 128,
                  (road.left + road.right).allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else {
                throw ModelReviewError.invalid("Road observations contain invalid coordinates or timestamps.")
            }
            previousRoadTime = road.capturedAt
            previousRoadAvailability = road.availableAt ?? road.capturedAt
        }
        var previousCueTime = -Double.infinity
        for cue in turnGuidanceSamples ?? [] {
            try cue.validate()
            guard cue.time > previousCueTime, cue.time < source.duration else {
                throw ModelReviewError.invalid("Turn guidance contains unordered or out-of-range timestamps.")
            }
            previousCueTime = cue.time
        }
    }

    // Includes the recording, model version AND exact replay: notes cannot drift to a new run.
    var storageKey: String { "\(source.sha256)-\(modelSHA256)-\(predictionsSHA256)" }

    /// Never selects an output from the future. Drives the readout and synced log highlight, not the editor.
    func event(atPlaybackTime time: Double) -> ModelReviewEvent? {
        guard time.isFinite, time >= 0, time <= source.duration else { return nil }
        return events.last { $0.time <= time + 0.000001 }
    }

    func road(atPlaybackTime time: Double) -> RoadLineObservation? {
        guard time.isFinite, let observations = roadObservations, !observations.isEmpty else { return nil }
        var low = 0, high = observations.count
        while low < high {
            let middle = (low + high) / 2
            if (observations[middle].availableAt ?? observations[middle].capturedAt) <= time { low = middle + 1 } else { high = middle }
        }
        return low > 0 ? observations[low - 1] : nil
    }

    func turnGuidance(atPlaybackTime time: Double) -> TurnGuidanceSample? {
        guard time.isFinite, time >= 0, time < source.duration, let samples = turnGuidanceSamples else { return nil }
        var low = 0, high = samples.count
        while low < high {
            let middle = (low + high) / 2
            if samples[middle].time <= time { low = middle + 1 } else { high = middle }
        }
        guard low > 0, time - samples[low - 1].time <= 0.25 else { return nil }
        return samples[low - 1]
    }
}

nonisolated struct ModelReviewNote: Codable, Equatable {
    let eventID: String
    let time: Double
    let category: ReviewSkillCategory
    var reviewer = ""
    var verdict: ReviewVerdict = .pending
    var direction = ""
    var target = ""
    var phase = ""
    var text = ""
    var reviewed = false
    var updatedAt = Date()
    // These are feedback after showing model answers, never blind test ground truth.
    private(set) var origin = "human_after_model_output"
    private(set) var sawModelAnswers = true
    var slowdown: SlowdownReview? = nil
    var aiReviewSHA256: [String: String]? = nil
    var turnTiming: TurnTimingReview? = nil

    var key: String { "\(eventID)|\(category.rawValue)" }
    var canComplete: Bool {
        !reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && verdict != .pending &&
        (category != .slowdownTiming || slowdown?.isComplete == true) &&
        (category != .basicTurns || turnTiming == nil || turnTiming?.isComplete == true)
    }
    func validate(in bundle: ModelReviewBundle) throws {
        guard let event = bundle.events.first(where: { $0.id == eventID }), event.time == time,
              category != .advanced, origin == "human_after_model_output", sawModelAnswers,
              ([""] + ModelReviewBundle.directions).contains(direction),
              ([""] + ModelReviewBundle.targets).contains(target),
              ([""] + ModelReviewBundle.phases).contains(phase),
              !reviewed || canComplete else {
            throw ModelReviewError.invalid("Saved feedback does not match this test.")
        }
        if let turnTiming {
            guard category == .basicTurns, !reviewed || turnTiming.isComplete,
                  !reviewed || !turnTiming.hasInterval || Double(turnTiming.end).map({ $0 < bundle.source.duration }) == true else {
                throw ModelReviewError.invalid("Enter a timing verdict and an interval inside this recording, or mark timing unsure.")
            }
        }
        if category == .slowdownTiming {
            guard bundle.schemaVersion == "racing-trainer-review-v2" else { throw ModelReviewError.invalid("This test has no timing pilot.") }
            if reviewed, let slowdown, !["uncertain", "cannot_judge"].contains(slowdown.action) {
                guard let end = Double(slowdown.end), end < bundle.source.duration else {
                    throw ModelReviewError.invalid("The timing interval must stay inside this recording.")
                }
            }
        }
    }
}

nonisolated struct ModelReviewJournal: Codable {
    var schemaVersion = "racing-trainer-feedback-v1"
    let sourceSHA256: String
    let modelSHA256: String
    let predictionsSHA256: String
    var notes: [ModelReviewNote]

    func validate(in bundle: ModelReviewBundle) throws {
        guard ["racing-trainer-feedback-v1", "racing-trainer-feedback-v2"].contains(schemaVersion), sourceSHA256 == bundle.source.sha256,
              modelSHA256 == bundle.modelSHA256, predictionsSHA256 == bundle.predictionsSHA256,
              Set(notes.map(\.key)).count == notes.count else {
            throw ModelReviewError.invalid("Feedback belongs to a different recording or model run.")
        }
        for note in notes { try note.validate(in: bundle) }
    }
}

nonisolated struct ModuleReviewDiagnostic: Codable, Equatable, Identifiable {
    let name: String
    let value: String
    let units: String
    let state: String
    let confidence: Double
    let confidenceKind: String
    let age: Double?
    let capturedAt: Double?
    let version: String
    let failure: String?
    let evidence: [String: String]
    var id: String { name }
}

nonisolated struct ModuleReviewDiagnostics: Codable, Equatable {
    let cue: String
    let proposedCue: String
    let proposalReason: String
    let origin: String
    let suppressionReasons: [String]
    let legacyPolicy: String
    let modules: [ModuleReviewDiagnostic]
    var suggestedLabel: String? = nil
    var suggestedRationale: String? = nil
    func validate(at time: Double) throws {
        guard SlowdownReview.actions.contains(cue), SlowdownReview.actions.contains(proposedCue),
              suggestedLabel == nil || SlowdownReview.actions.contains(suggestedLabel!),
              !origin.isEmpty, Set(modules.map(\.name)).count == modules.count,
              Set(["speed", "minimap", "geometry", "validity"]).isSubset(of: Set(modules.map(\.name))),
              Set(modules.map(\.name)).isSubset(of: Set(["speed", "minimap", "geometry", "validity", "road"])),
              modules.allSatisfy({ $0.confidence.isFinite && (0...1).contains($0.confidence) &&
                  ($0.age == nil || ($0.age!.isFinite && $0.age! >= 0)) &&
                  ($0.capturedAt == nil || ($0.capturedAt!.isFinite && $0.capturedAt! <= time && $0.capturedAt! >= 0)) }) else {
            throw ModelReviewError.invalid("Invalid module diagnostics or future evidence.")
        }
    }
}

nonisolated struct SlowdownReview: Codable, Equatable {
    static let actions = ["advance_warning", "lift", "brake", "no_cue", "cannot_judge", "uncertain"]
    var action = ""
    // Text preserves incomplete drafts without silently substituting zero.
    var start = ""
    var end = ""
    var isComplete: Bool {
        if action == "uncertain" || action == "cannot_judge" { return true }
        guard Self.actions.contains(action), let start = Double(start), let end = Double(end) else { return false }
        return start.isFinite && end.isFinite && start >= 0 && end >= start
    }
}

nonisolated func reviewLabel(_ value: String) -> String {
    switch value {
    case "current_corner": return "Current corner"
    case "next_corner": return "Upcoming corner"
    case "straight_segment": return "Straight segment"
    case "apex_region": return "Apex region"
    case "advance_warning": return "Advance warning"
    case "no_cue": return "No cue needed"
    case "cannot_judge": return "Cannot judge"
    case "": return "Not specified"
    default: return value.capitalized
    }
}

nonisolated func reviewTimestamp(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "--:--" }
    let whole = Int(seconds)
    return whole >= 3600
        ? String(format: "%02d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
        : String(format: "%02d:%02d", whole / 60, whole % 60)
}

nonisolated func reviewPreciseTimestamp(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let tenths = floor(seconds * 10 + 0.000001)
    guard tenths < Double(Int.max) else { return "--:--" }
    return reviewTimestamp(tenths / 10) + String(format: ".%01d", Int(tenths) % 10)
}

nonisolated private func validHash(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
}
