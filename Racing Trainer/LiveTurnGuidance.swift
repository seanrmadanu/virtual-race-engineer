import Foundation

nonisolated struct LiveTurnGuidanceSnapshot: Sendable {
    let cue: TurnGuidanceSample
    let sourceFrameUptime: Double
    let expiresAt: Double
    let sourceSessionID: Int

    func isFresh(at time: Double) -> Bool {
        time.isFinite && time >= cue.time && time >= sourceFrameUptime && time <= expiresAt
    }

    func steering(at time: Double) -> SteeringGuidance {
        guard isFresh(at: time) else { return .unavailable }
        switch cue.stage {
        case .turnNow, .following: return cue.direction == "left" ? .left : .right
        case .headsUp, .preview, .straight: return .center
        case .unavailable: return .unavailable
        }
    }

    static let empty = Self(cue: TurnGuidanceSample(time: 0, stage: .unavailable, direction: "unknown",
        reason: "Waiting for gameplay"), sourceFrameUptime: 0, expiresAt: 0, sourceSessionID: -1)
}

/// Reuses the main app's existing perception results. No second OCR or minimap
/// detector is run. One instance belongs to the serial minimap analysis queue.
nonisolated struct LiveTurnGuidancePipeline {
    private var tracker = TurnGuidanceTracker()

    mutating func reset() { tracker.reset() }

    mutating func process(coach: MinimapCoachSnapshot, minimapVisible: Bool, minimapConfidence: Float,
                          speed: MinimapSpeedSample?, speedUnit: String?, session: Int,
                          completedAt time: Double) -> LiveTurnGuidanceSnapshot {
        let capture = coach.sourceFrameUptime
        let selected = RouteTurnSelector.select(coach.orderedPath)
        func observation(_ name: String, value: CoachModuleValue, confidence: Float,
                         fresh: Bool, units: String? = nil) -> CoachModuleObservation {
            CoachModuleObservation(value: value, state: fresh ? .fresh : .uncertain, confidence: confidence,
                capturedAt: capture, completedAt: time, sourceSessionID: session, implementation: name,
                version: "live-turn-guidance-v1", failureReason: fresh ? nil : coach.reason, units: units)
        }
        let routeFresh = coach.displayedState(at: time) == .ready
        var observations: [String: CoachModuleObservation] = [
            "validity": observation("live-input", value: CoachModuleValue(flag: routeFresh), confidence: routeFresh ? 1 : 0,
                                     fresh: routeFresh),
            "minimap": observation("live-minimap", value: CoachModuleValue(flag: minimapVisible),
                                    confidence: minimapConfidence, fresh: minimapVisible),
            "geometry": observation("live-route", value: CoachModuleValue(direction: selected.direction,
                severity: selected.severity, turnDistance: selected.distance,
                path: coach.orderedPath.map { [$0.x, $0.y] }, target: selected.target),
                confidence: min(coach.confidence.geometry, coach.confidence.forwardPath), fresh: routeFresh,
                units: "normalized_map")
        ]
        if let speed {
            observations["speed"] = CoachModuleObservation(value: CoachModuleValue(number: Double(speed.value)),
                state: .fresh, confidence: speed.confidence, capturedAt: speed.sourceFrameUptime,
                completedAt: speed.completionUptime, sourceSessionID: speed.sourceSessionID,
                implementation: "live-speed-ocr", version: "1", failureReason: nil, units: speedUnit)
        }
        let cue = tracker.update(row: CoachHistoryRow(time: time, observations: observations, ages: [:]), session: session)
        return LiveTurnGuidanceSnapshot(cue: cue, sourceFrameUptime: capture,
                                       expiresAt: capture + CoachSafetyPolicy.maximumRouteAge, sourceSessionID: session)
    }
}

nonisolated extension MinimapCoachSnapshot {
    /// Keep perception diagnostics while replacing the legacy timing/steering
    /// actions with Category 1 navigation. No uncalibrated pedal command escapes.
    func applying(_ guidance: LiveTurnGuidanceSnapshot, at time: Double) -> Self {
        let steering = guidance.steering(at: time)
        let timing: TurnTiming
        switch guidance.cue.stage {
        case .turnNow: timing = .now
        case .headsUp: timing = .soon
        case .preview: timing = .later
        case .straight, .following: timing = .none
        case .unavailable: timing = .unknown
        }
        let selected = RouteTurnSelector.select(orderedPath)
        return Self(state: state, confidence: confidence,
            direction: RouteTurnDirection(rawValue: selected.direction) ?? .unknown,
            severity: TurnSeverity(rawValue: selected.severity) ?? .unknown,
            timing: timing, action: steering == .unavailable ? .unavailable : .hold, steering: steering,
            orderedPath: orderedPath, turnStartPoint: turnStartPoint, turnStartNormalizedDistance: turnStartNormalizedDistance,
            pathPointCount: pathPointCount, branchPointCount: branchPointCount, speedUsed: speedUsed,
            speedAgeMilliseconds: speedAgeMilliseconds, sourceFrameUptime: sourceFrameUptime,
            processingLatencyMilliseconds: processingLatencyMilliseconds, trackingApplied: trackingApplied,
            reason: guidance.cue.reason, guidanceExpiresAt: min(guidanceExpiresAt ?? .infinity, guidance.expiresAt))
    }
}
