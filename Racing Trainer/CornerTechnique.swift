import Foundation

nonisolated enum CornerTechniquePhase: String, Codable, CaseIterable, Sendable {
    case unavailable = "unknown", straight, approach, entry, cornering, exit

    var title: String {
        switch self {
        case .unavailable: return "Phase unavailable"
        case .straight: return "Straight"
        case .approach: return "Approach"
        case .entry: return "Entry"
        case .cornering: return "In bend"
        case .exit: return "Exit"
        }
    }
}

/// A causal estimate of progress along the visible route, not a steering cue,
/// measured vehicle phase, apex, racing line, or pedal recommendation.
nonisolated struct CornerTechniqueSample: Codable, Equatable, Sendable {
    let time: Double
    let phase: CornerTechniquePhase
    let direction: String
    let upcomingDirection: String
    let reason: String
    let evidenceCapturedAt: Double?
    let validUntil: Double?
    let isPhaseStart: Bool
    static let implementationVersion = "corner-technique-v1-route-phase"
    var version = Self.implementationVersion

    var title: String {
        ["left", "right"].contains(direction) ? "\(phase.title) · \(direction.capitalized)" : phase.title
    }

    func validate() throws {
        let supported = phase != .unavailable
        let validDirection = phase == .unavailable ? direction == "unknown"
            : phase == .straight ? direction == "straight" : ["left", "right"].contains(direction)
        guard time.isFinite, time >= 0, validDirection,
              ["unknown", "left", "right"].contains(upcomingDirection),
              !reason.isEmpty, version == Self.implementationVersion,
              !isPhaseStart || supported else {
            throw ModelReviewError.invalid("Invalid corner technique sample.")
        }
        if supported {
            guard let capture = evidenceCapturedAt, let expiry = validUntil,
                  capture.isFinite, expiry.isFinite, capture >= 0, capture <= time,
                  expiry >= time, expiry <= capture + 0.65 + 1e-9 else {
                throw ModelReviewError.invalid("Corner phase lacks fresh causal evidence.")
            }
        } else if evidenceCapturedAt != nil || validUntil != nil {
            throw ModelReviewError.invalid("Unavailable corner phase cannot retain supporting evidence.")
        }
    }
}

