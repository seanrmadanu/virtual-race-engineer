import Foundation

/// Illustrative wheel angle for the live cue, in degrees (negative = left).
/// Whether and which way to steer comes only from the cue, so the wheel
/// turns exactly when the instruction does. How far it turns follows how
/// sharply the minimap route bends just ahead of the player. No wheel or
/// vehicle calibration exists; these are not real steering angles.
nonisolated enum SteeringWheelTarget {
    /// Used when the route shape is missing, stale, or disagrees with the cue.
    static let fallbackBend = 45.0
    static let fallbackTurn = 120.0
    static let bendRange = 20.0...90.0
    static let turnRange = 100.0...180.0

    /// `nil` means no guidance: the wheel holds briefly, then recentres.
    static func degrees(turn: LiveTurnGuidanceSnapshot, route: MinimapCoachSnapshot, at time: Double) -> Double? {
        guard let normalized = turn.steering(at: time).normalizedTarget else { return nil }
        guard normalized != 0 else { return 0 }
        let sign = normalized < 0 ? -1.0 : 1.0
        let isTurn = turn.cue.stage == .turnNow || turn.cue.currentManeuver == "turn"
        let routeIsCurrent = abs(route.sourceFrameUptime - turn.sourceFrameUptime) <= 0.5
        guard routeIsCurrent, let bend = routeHeading(route.orderedPath, anchor: route.playerAnchor),
              bend * sign > 0 else {
            return sign * (isTurn ? fallbackTurn : fallbackBend)
        }
        let magnitude = isTurn ? clamp(60 + abs(bend) * 0.9, turnRange) : clamp(abs(bend) * 1.2, bendRange)
        return sign * magnitude
    }

    /// Heading of the route a short way ahead, relative to straight up on the
    /// heading-up minimap (positive = right), in degrees.
    static func routeHeading(_ path: [MinimapPoint], anchor: MinimapPoint?, ahead: Double = 0.12) -> Double? {
        guard path.count >= 4, path.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let start = anchor ?? path[0]
        var travelled = 0.0, previous = start
        for (index, point) in path.enumerated() {
            travelled += hypot(point.x - previous.x, point.y - previous.y)
            previous = point
            guard travelled >= ahead else { continue }
            // Average heading over the last stretch, not one noisy segment.
            let from = path[..<index].last { hypot($0.x - point.x, $0.y - point.y) >= 0.04 } ?? start
            let dx = point.x - from.x, dy = from.y - point.y
            guard hypot(dx, dy) > 0.02 else { return nil }
            return atan2(dx, dy) * 180 / .pi
        }
        return nil
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// Steadies `SteeringWheelTarget` over time: the route's bend reading is noisy
/// frame to frame, and briefly unusable now and then. The size of the turn is
/// smoothed, and a short route gap keeps the last good size instead of jumping
/// to the fallback. Direction and timing still come only from the cue.
nonisolated final class SteeringWheelTargetFilter {
    /// Time constant for the bend size, in seconds.
    static let smoothingTime = 0.35
    /// How long a missing route reading may reuse the last one.
    static let routeHold = 0.6

    private var bend: Double?
    private var sign = 0.0
    private var measuredAt = -Double.infinity
    private var lastTime: Double?

    func reset() { bend = nil; sign = 0; measuredAt = -.infinity; lastTime = nil }

    func degrees(turn: LiveTurnGuidanceSnapshot, route: MinimapCoachSnapshot, at time: Double) -> Double? {
        if let lastTime, time < lastTime { reset() }
        let dt = min(max(time - (lastTime ?? time), 0), 0.5)
        lastTime = time
        guard let normalized = turn.steering(at: time).normalizedTarget else { return nil }
        guard normalized != 0 else { sign = 0; return 0 }
        let direction = normalized < 0 ? -1.0 : 1.0
        let isTurn = turn.cue.stage == .turnNow || turn.cue.currentManeuver == "turn"
        let routeIsCurrent = abs(route.sourceFrameUptime - turn.sourceFrameUptime) <= 0.5
        let reading = routeIsCurrent
            ? SteeringWheelTarget.routeHeading(route.orderedPath, anchor: route.playerAnchor).flatMap { $0 * direction > 0 ? abs($0) : nil }
            : nil
        if direction != sign { bend = nil }
        sign = direction
        if let reading {
            bend = bend.map { $0 + (reading - $0) * (1 - exp(-dt / Self.smoothingTime)) } ?? reading
            measuredAt = time
        } else if time - measuredAt > Self.routeHold {
            bend = nil
        }
        let magnitude: Double
        if let bend {
            magnitude = isTurn ? min(max(60 + bend * 0.9, SteeringWheelTarget.turnRange.lowerBound), SteeringWheelTarget.turnRange.upperBound)
                : min(max(bend * 1.2, SteeringWheelTarget.bendRange.lowerBound), SteeringWheelTarget.bendRange.upperBound)
        } else {
            magnitude = isTurn ? SteeringWheelTarget.fallbackTurn : SteeringWheelTarget.fallbackBend
        }
        return direction * magnitude
    }
}

/// Moves the drawn wheel toward its target the way hands would: a critically
/// damped spring with a turning-speed limit, so new cues never snap the wheel
/// and a brief dropout does not throw it back to centre. Display only.
nonisolated final class SteeringWheelMotion {
    /// How long a lost target is held before the wheel recentres.
    static let holdAfterDropout = 0.4
    /// Degrees per second; about a brisk hand-over-hand turn.
    static let maximumSpeed = 420.0
    /// Spring stiffness (rad/s). Reaches a new target in roughly 0.6 s.
    static let responsiveness = 6.5

    private(set) var angle = 0.0
    private var velocity = 0.0
    private var lastUpdate: TimeInterval?
    private var heldTarget = 0.0
    private var heldAt = -Double.infinity

    func advance(toward target: Double?, at now: TimeInterval, reduceMotion: Bool) -> Double {
        let goal: Double
        if let target {
            heldTarget = target; heldAt = now; goal = target
        } else {
            goal = now - heldAt <= Self.holdAfterDropout ? heldTarget : 0
        }
        // Long gaps (window hidden, first frame) restart without a jump.
        let dt = min(max(now - (lastUpdate ?? now), 0), 1.0 / 20)
        lastUpdate = now
        guard !reduceMotion else {
            angle = goal; velocity = 0
            return angle
        }
        let omega = Self.responsiveness
        velocity += (omega * omega * (goal - angle) - 2 * omega * velocity) * dt
        velocity = min(max(velocity, -Self.maximumSpeed), Self.maximumSpeed)
        angle += velocity * dt
        if abs(goal - angle) < 0.05 && abs(velocity) < 0.5 { angle = goal; velocity = 0 }
        return angle
    }
}
