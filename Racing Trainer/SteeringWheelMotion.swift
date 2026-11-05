import Foundation

/// A visual restatement of the confirmed navigation instruction. The route's
/// pixel tangent is not a calibrated steering angle: feeding it to the wheel
/// made a steady "Follow the bend" cue twitch as its skeleton changed.
nonisolated enum SteeringWheelTarget {
    static let bend = 45.0
    static let turn = 120.0

    /// Negative = left; nil = unavailable. Upcoming turns never steer early.
    static func degrees(turn guidance: LiveTurnGuidanceSnapshot, at time: Double) -> Double? {
        guard guidance.isFresh(at: time) else { return nil }
        switch guidance.cue.stage {
        case .unavailable: return nil
        case .straight, .preview, .headsUp: return 0
        case .following, .turnNow:
            guard ["left", "right"].contains(guidance.cue.direction) else { return nil }
            let magnitude = guidance.cue.stage == .turnNow || guidance.cue.currentManeuver == "turn"
                ? turn : bend
            return guidance.cue.direction == "left" ? -magnitude : magnitude
        }
    }
}

/// Display-only, critically damped motion. A lost cue freezes the drawn angle
/// briefly (while the view dims), then returns to centre. No new instruction is
/// inferred from that hold. Exact spring integration is independent of redraw
/// rate; body evaluation itself must never advance this state.
nonisolated final class SteeringWheelMotion {
    static let holdAfterDropout = 0.4
    static let maximumSpeed = 420.0
    static let responsiveness = 8.0

    private(set) var angle = 0.0
    private var velocity = 0.0
    private var lastUpdate: TimeInterval?
    private var missingSince: TimeInterval?
    private var sessionID: Int?

    func advance(toward target: Double?, at now: TimeInterval, reduceMotion: Bool,
                 session: Int = 0) -> Double {
        guard now.isFinite else { return angle }
        if sessionID != session {
            angle = 0; velocity = 0; lastUpdate = nil; missingSince = nil
            sessionID = session
        }
        // Duplicate/backward display timestamps must not rewind the integrator.
        if let lastUpdate, now <= lastUpdate { return angle }
        let dt = min(now - (lastUpdate ?? now), 1.0 / 20)
        lastUpdate = now
        let goal: Double
        if let target, target.isFinite {
            missingSince = nil
            goal = min(max(target, -180), 180)
        } else {
            if missingSince == nil { missingSince = now }
            if now - missingSince! < Self.holdAfterDropout {
                velocity = 0
                return angle
            }
            goal = 0
        }
        guard !reduceMotion else {
            angle = goal; velocity = 0
            return angle
        }
        let omega = Self.responsiveness
        let displacement = angle - goal
        let coefficient = velocity + omega * displacement
        let decay = exp(-omega * dt)
        let proposed = goal + (displacement + coefficient * dt) * decay
        velocity = (velocity - omega * coefficient * dt) * decay
        let step = min(max(proposed - angle, -Self.maximumSpeed * dt), Self.maximumSpeed * dt)
        angle += step
        velocity = min(max(velocity, -Self.maximumSpeed), Self.maximumSpeed)
        if abs(goal - angle) < 0.05 && abs(velocity) < 0.5 { angle = goal; velocity = 0 }
        return angle
    }
}
