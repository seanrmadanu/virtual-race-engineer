import Foundation

nonisolated enum TurnGuidanceStage: String, Codable, CaseIterable, Sendable {
    case unavailable, straight, preview, headsUp = "heads_up", turnNow = "turn_now", following
}

/// A navigation cue, independent of slowdown advice and observed corner phase.
nonisolated struct TurnGuidanceSample: Codable, Equatable, Sendable {
    let time: Double
    let stage: TurnGuidanceStage
    let direction: String
    let reason: String
    var secondsToTurn: Double? = nil
    var isCueStart = false

    var title: String {
        switch stage {
        case .unavailable: return "Guidance unavailable"
        case .straight: return "Continue straight"
        case .preview, .headsUp: return "\(direction.capitalized) turn ahead"
        case .turnNow: return "Turn \(direction) now"
        case .following: return "Keep turning \(direction)"
        }
    }

    func validate() throws {
        guard time.isFinite, time >= 0,
              (stage == .unavailable ? direction == "unknown" : stage == .straight ? direction == "straight" : ["left", "right"].contains(direction)),
              secondsToTurn == nil || (secondsToTurn!.isFinite && secondsToTurn! >= 0),
              !isCueStart || stage == .headsUp || stage == .turnNow else {
            throw ModelReviewError.invalid("Invalid turn guidance sample.")
        }
    }
}

nonisolated struct TurnTimingReview: Codable, Equatable {
    // Strings retain partially typed drafts. Empty fields are never zero seconds.
    var cue = "turn_now"
    var verdict: ReviewVerdict = .pending
    var start = ""
    var end = ""
    static let cues = ["heads_up", "turn_now", "no_cue", "uncertain"]
    var hasInterval: Bool { !start.isEmpty || !end.isEmpty }
    var isValid: Bool {
        guard Self.cues.contains(cue) else { return false }
        if !hasInterval { return true }
        guard let start = Double(start), let end = Double(end) else { return false }
        return start.isFinite && end.isFinite && start >= 0 && end >= start
    }
    var isComplete: Bool {
        isValid && verdict != .pending && ([.unclear, .unusable].contains(verdict) || hasInterval)
    }
}
