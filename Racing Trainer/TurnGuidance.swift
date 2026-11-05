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
    // Optional for backward compatibility with frozen review bundles. New cues
    // explicitly separate the near route from the bend farther ahead.
    var currentDirection: String? = nil
    var currentManeuver: String? = nil
    var upcomingDirection: String? = nil
    // Retained presentation never renews the age of its supporting frame.
    var evidenceCapturedAt: Double? = nil
    var validUntil: Double? = nil

    var primaryDirection: String {
        if [.preview, .headsUp].contains(stage), let currentDirection { return currentDirection }
        return direction
    }

    var upcomingTitle: String? {
        if let upcomingDirection {
            guard ["straight", "left", "right"].contains(upcomingDirection) else { return nil }
            return "Next: \(upcomingDirection.capitalized)"
        }
        guard currentDirection != nil, [.preview, .headsUp].contains(stage),
              ["left", "right"].contains(direction) else { return nil }
        return "Next: \(direction.capitalized)"
    }

    var title: String {
        switch stage {
        case .unavailable: return "Guidance unavailable"
        case .straight: return "Go straight"
        case .preview, .headsUp:
            guard let currentDirection else { return "\(direction.capitalized) turn ahead" }
            return currentDirection == "straight" ? "Go straight" : "Follow the road"
        case .turnNow: return "Turn \(direction)"
        case .following: return currentManeuver == "turn" ? "Turn \(direction)" : "Follow the \(direction) bend"
        }
    }

    func validate() throws {
        guard time.isFinite, time >= 0,
              (stage == .unavailable ? direction == "unknown" : stage == .straight ? direction == "straight" : ["left", "right"].contains(direction)),
              secondsToTurn == nil || (secondsToTurn!.isFinite && secondsToTurn! >= 0),
              currentDirection == nil || ["unknown", "straight", "left", "right"].contains(currentDirection!),
              currentManeuver == nil || ["turn", "bend"].contains(currentManeuver!),
              upcomingDirection == nil || ["unknown", "straight", "left", "right"].contains(upcomingDirection!),
              evidenceCapturedAt == nil || (evidenceCapturedAt!.isFinite && evidenceCapturedAt! >= 0 && evidenceCapturedAt! <= time),
              validUntil == nil || (validUntil!.isFinite && validUntil! >= time),
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
