import Foundation

nonisolated enum PerceptionState: String, CaseIterable, Sendable {
    case fresh, stale, uncertain, missing
}

/// All timestamps use one monotonic clock. Replay will supply a virtual clock.
/// A value retained for diagnostics is not necessarily usable evidence.
nonisolated struct PerceptionObservation<Value: Sendable>: Sendable {
    let value: Value?
    let state: PerceptionState
    let confidence: Float
    let capturedAt: TimeInterval
    let completedAt: TimeInterval
    let sourceSessionID: Int
    let implementation: String
    let version: String
    let failureReason: String?

    func isUsable(at now: TimeInterval, sessionID: Int,
                  maximumAge: TimeInterval, minimumConfidence: Float) -> Bool {
        state == .fresh && value != nil && sourceSessionID == sessionID &&
        now.isFinite && capturedAt.isFinite && completedAt.isFinite &&
        capturedAt >= 0 && completedAt >= capturedAt && completedAt <= now &&
        now - capturedAt <= maximumAge &&
        confidence.isFinite && confidence >= minimumConfidence && confidence <= 1
    }
}

nonisolated struct RouteGuidance: Sendable {
    let direction: RouteTurnDirection
    let severity: TurnSeverity
    let timing: TurnTiming
}

nonisolated struct CoachDecision: Sendable {
    let action: DrivingCoachAction
    let explanation: String
    let requiredEvidence: [String]
    let confidence: Float
    let issuedAt: TimeInterval
    let expiresAt: TimeInterval
    let speedUsed: Int?
}

/// Pure policy shared by full detection and tracked frames. These limits preserve
/// the prototype's thresholds; their calibration belongs to replay evaluation.
nonisolated enum CoachSafetyPolicy {
    static let maximumRouteAge: TimeInterval = 0.65
    static let maximumSpeedAge: TimeInterval = 0.75
    static let maximumTimestampSkew: TimeInterval = 0.75

    static func decide(
        route: PerceptionObservation<RouteGuidance>,
        speed: PerceptionObservation<Int>?,
        stableStraightFrames: Int,
        sessionID: Int,
        now: TimeInterval
    ) -> CoachDecision {
        guard route.isUsable(at: now, sessionID: sessionID,
                             maximumAge: maximumRouteAge, minimumConfidence: 0.52),
              let description = route.value,
              description.direction != .unknown,
              description.severity != .unknown,
              description.timing != .unknown else {
            return CoachDecision(action: .unavailable,
                                 explanation: "Fresh, confident route evidence is unavailable.",
                                 requiredEvidence: ["route"], confidence: 0,
                                 issuedAt: now, expiresAt: now, speedUsed: nil)
        }

        guard let speed,
              speed.isUsable(at: now, sessionID: sessionID,
                             maximumAge: maximumSpeedAge, minimumConfidence: 0.30),
              let value = speed.value, (0...500).contains(value),
              abs(speed.capturedAt - route.capturedAt) <= maximumTimestampSkew else {
            return CoachDecision(action: .hold,
                                 explanation: "Direction only: fresh synchronized speed is unavailable.",
                                 requiredEvidence: ["route"], confidence: route.confidence,
                                 issuedAt: now, expiresAt: route.capturedAt + maximumRouteAge,
                                 speedUsed: nil)
        }

        let action: DrivingCoachAction
        switch (description.severity, description.timing) {
        case (.uTurn, .soon) where value >= 30,
             (.uTurn, .now) where value >= 30:
            action = .brake
        case (.sharp, .now) where value >= 45,
             (.sharp, .soon) where value >= 80,
             (.medium, .now) where value >= 85,
             (.medium, .soon) where value >= 135,
             (.gentle, .now) where value >= 170:
            action = .brake
        default:
            action = description.direction == .straight &&
                description.severity == .straight && description.timing == .none &&
                stableStraightFrames >= 4 ? .accelerateIfClear : .hold
        }
        return CoachDecision(action: action,
                             explanation: "Fresh synchronized route and speed evidence passed policy gates.",
                             requiredEvidence: ["route", "speed"],
                             confidence: min(route.confidence, speed.confidence),
                             issuedAt: now,
                             expiresAt: min(route.capturedAt + maximumRouteAge,
                                            speed.capturedAt + maximumSpeedAge),
                             speedUsed: value)
    }
}
