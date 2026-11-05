import Foundation

/// Versioned, video-derived measurements. These are not game telemetry.
nonisolated enum CoachModule: String, Codable, CaseIterable, Sendable {
    case speed, minimap, geometry, validity, road
}

nonisolated struct CoachModuleValue: Codable, Sendable {
    var number: Double? = nil
    var direction: String? = nil
    var severity: String? = nil
    var timing: String? = nil
    var turnDistance: Double? = nil
    var path: [[Double]]? = nil
    var flag: Bool? = nil
    var target: String? = nil
    var road: RoadLineObservation? = nil
    var playerAnchor: [Double]? = nil
}

typealias CoachModuleObservation = PerceptionObservation<CoachModuleValue>

nonisolated struct CoachHistoryRow: Codable, Sendable {
    let time: Double
    let observations: [String: CoachModuleObservation]
    let ages: [String: Double]
}

/// One serial owner per source. The grid covers (t - 2, t] at 10 Hz.
/// Completion time is part of causality: a slow result cannot rewrite an earlier row.
nonisolated struct CoachObservationHistory {
    private(set) var sessionID: Int?
    private(set) var lastFrameTime: Double?
    private(set) var resetReason = "initial"
    private var records: [String: [CoachModuleObservation]] = [:]

    mutating func reset(reason: String) {
        records.removeAll(); lastFrameTime = nil; sessionID = nil; resetReason = reason
    }

    mutating func append(_ observations: [String: CoachModuleObservation], frameTime: Double, session: Int) {
        guard frameTime.isFinite, frameTime >= 0 else { reset(reason: "invalid_clock"); return }
        if let previous = lastFrameTime {
            if sessionID != session { reset(reason: "source_change") }
            else if frameTime <= previous { reset(reason: "seek_or_duplicate_frame") }
            else if frameTime - previous > 0.75 { reset(reason: "interruption") }
        }
        sessionID = session; lastFrameTime = frameTime
        for module in CoachModule.allCases {
            guard let item = observations[module.rawValue], item.sourceSessionID == session,
                  item.capturedAt.isFinite, item.completedAt.isFinite,
                  item.capturedAt >= 0, item.capturedAt <= frameTime,
                  item.completedAt >= item.capturedAt else { continue }
            records[module.rawValue, default: []].append(item)
            records[module.rawValue]?.removeAll { $0.capturedAt < frameTime - 3 }
        }
    }

    func sample(at time: Double) -> [CoachHistoryRow] {
        guard time.isFinite, time >= 0 else { return [] }
        return (0..<20).map { index in
            let tick = time - Double(19 - index) / 10
            var items: [String: CoachModuleObservation] = [:]
            var ages: [String: Double] = [:]
            for module in CoachModule.allCases {
                // Keep the latest failed observation; never fall back to an older success.
                if let item = records[module.rawValue]?.last(where: {
                    $0.capturedAt <= tick + 1e-9 && $0.completedAt <= tick + 1e-9
                }) {
                    var aged = item
                    let age = max(0, tick - item.capturedAt)
                    let limit = module == .speed ? 0.75 : 0.65
                    if age > limit { aged = item.withState(.stale, reason: "age_limit") }
                    items[module.rawValue] = aged; ages[module.rawValue] = age
                }
            }
            return CoachHistoryRow(time: tick, observations: items, ages: ages)
        }
    }
}

nonisolated extension PerceptionObservation {
    func withState(_ state: PerceptionState, reason: String) -> Self {
        Self(value: value, state: state, confidence: confidence, capturedAt: capturedAt,
             completedAt: completedAt, sourceSessionID: sourceSessionID,
             implementation: implementation, version: version, failureReason: reason,
             units: units, evidence: evidence, confidenceKind: confidenceKind)
    }
}

nonisolated enum SlowdownCue: String, Codable, CaseIterable, Sendable {
    case advanceWarning = "advance_warning", lift, brake, noCue = "no_cue", cannotJudge = "cannot_judge"
    var needsSpeed: Bool { self == .lift || self == .brake || self == .noCue }
}

nonisolated struct SlowdownProposal: Codable, Sendable {
    let cue: SlowdownCue
    let origin: String
    let confidence: Double? // nil for deterministic rules; not a manufactured probability
    let reason: String
}

nonisolated struct SlowdownDecision: Codable, Sendable {
    let proposal: SlowdownProposal
    let acceptedCue: SlowdownCue
    let suppressionReasons: [String]
    // Deliberately not configurable until qualification is implemented and reviewed.
    let learnedLiveEnabled = false
}

nonisolated struct SlowdownCalibration: Codable, Sendable {
    let carSetupID: String
    let hudProfile: String
    let speedUnit: String
    let metersPerMapUnit: Double
    let brakingDeceleration: Double
    let liftDeceleration: Double
    let warningDelaySeconds: Double
    let minimumSpeedKPH: Double
    let maximumSpeedKPH: Double
    let targetSpeedKPH: [String: Double]
    let reviewedBy: String
    let evidence: [String]

    func supports(carSetup: String, hud: String) -> Bool {
        carSetupID == carSetup && !carSetup.isEmpty && hudProfile == hud && speedUnit == "km/h" &&
        !reviewedBy.trimmingCharacters(in: .whitespaces).isEmpty && !evidence.isEmpty &&
        [metersPerMapUnit, brakingDeceleration, liftDeceleration, maximumSpeedKPH].allSatisfy { $0.isFinite && $0 > 0 } &&
        liftDeceleration < brakingDeceleration && warningDelaySeconds.isFinite && warningDelaySeconds >= 0 &&
        minimumSpeedKPH.isFinite && minimumSpeedKPH >= 0 && maximumSpeedKPH > minimumSpeedKPH &&
        !targetSpeedKPH.isEmpty && targetSpeedKPH.values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= maximumSpeedKPH }
    }
}

nonisolated enum SlowdownRules {
    static func propose(row: CoachHistoryRow, calibration: SlowdownCalibration?, carSetup: String,
                        hud: String) -> SlowdownProposal {
        func result(_ cue: SlowdownCue, _ reason: String) -> SlowdownProposal {
            SlowdownProposal(cue: cue, origin: "rules-route-v2", confidence: nil, reason: reason)
        }
        if let speed = row.observations["speed"],
           speed.isUsable(at: row.time, sessionID: speed.sourceSessionID, maximumAge: 0.75, minimumConfidence: 0.30),
           ["km/h", "mph"].contains(speed.units ?? ""), let value = speed.value?.number, value <= 1, value >= 0 {
            return result(.cannotJudge, "stationary_route_preview")
        }
        guard let geometry = row.observations["geometry"]?.value,
              let direction = geometry.direction, direction != "unknown" else {
            return result(.cannotJudge, "route_unavailable")
        }
        if geometry.target == "near_route" {
            return result(.cannotJudge, "near_bend_warning_timing_unresolved")
        }
        if direction == "straight", row.observations["road"]?.value?.road?.roadDirection == "straight" {
            return result(.noCue, "visible_straight_route")
        }
        guard let calibration, calibration.supports(carSetup: carSetup, hud: hud),
              let speed = row.observations["speed"]?.value?.number,
              speed >= calibration.minimumSpeedKPH, speed <= calibration.maximumSpeedKPH,
              let target = calibration.targetSpeedKPH[geometry.severity ?? ""] else {
            return result(direction == "straight" ? .cannotJudge : .advanceWarning,
                          "uncalibrated_direction_only")
        }
        if direction == "straight" { return result(.noCue, "no_corner_slowdown_in_visible_route") }
        guard let normalizedDistance = geometry.turnDistance, normalizedDistance.isFinite, normalizedDistance >= 0 else {
            return result(.cannotJudge, "distance_unavailable")
        }
        let distance = normalizedDistance * calibration.metersPerMapUnit
        let velocity = speed / 3.6, targetVelocity = target / 3.6
        let energy = max(0, velocity * velocity - targetVelocity * targetVelocity)
        let delayDistance = velocity * calibration.warningDelaySeconds
        if energy == 0 { return result(.noCue, "below_calibrated_target") }
        if distance <= energy / (2 * calibration.brakingDeceleration) + delayDistance {
            return result(.brake, "calibrated_braking_distance")
        }
        if distance <= energy / (2 * calibration.liftDeceleration) + delayDistance {
            return result(.lift, "calibrated_lift_distance")
        }
        return result(.advanceWarning, "corner_ahead")
    }
}

/// Independent evidence guards apply identically to rule and learned proposals.
nonisolated enum SlowdownEvidenceGuard {
    static func apply(_ proposal: SlowdownProposal, row: CoachHistoryRow, session: Int,
                      calibration: SlowdownCalibration?, carSetup: String, hud: String,
                      cameraVerified: Bool = false) -> SlowdownDecision {
        var reasons: [String] = []
        func usable(_ key: String, age: Double, confidence: Float) -> Bool {
            row.observations[key]?.isUsable(at: row.time, sessionID: session,
                                            maximumAge: age, minimumConfidence: confidence) == true
        }
        if !usable("validity", age: 0.65, confidence: 0) || row.observations["validity"]?.value?.flag != true {
            reasons.append("invalid_or_stalled_input")
        }
        if !usable("minimap", age: 0.65, confidence: 0.52) { reasons.append("minimap_unreliable") }
        if !usable("geometry", age: 0.65, confidence: 0.52) { reasons.append("geometry_unreliable") }
        if !["straight", "left", "right", "uTurnLeft", "uTurnRight"].contains(row.observations["geometry"]?.value?.direction ?? "") {
            reasons.append("direction_unknown")
        }
        if proposal.cue.needsSpeed {
            if !usable("speed", age: 0.75, confidence: 0.30) { reasons.append("speed_missing_stale_or_unreliable") }
            if row.observations["speed"]?.units != "km/h" { reasons.append("speed_unit_unconfirmed") }
            if let speed = row.observations["speed"], let route = row.observations["geometry"],
               abs(speed.capturedAt - route.capturedAt) > 0.75 { reasons.append("timestamp_skew") }
            if let value = row.observations["speed"]?.value?.number {
                if !value.isFinite || value < 0 || value > 500 { reasons.append("speed_out_of_range") }
            } else { reasons.append("speed_value_missing") }
            if proposal.cue == .brake || proposal.cue == .lift {
                if let distance = row.observations["geometry"]?.value?.turnDistance {
                    if !distance.isFinite || distance < 0 { reasons.append("distance_invalid") }
                } else { reasons.append("distance_missing") }
            }
            let observedStraight = proposal.cue == .noCue && proposal.reason == "visible_straight_route"
                && row.observations["geometry"]?.value?.direction == "straight"
                && usable("road", age: 0.65, confidence: 0.55)
                && row.observations["road"]?.value?.road?.roadDirection == "straight"
            if !observedStraight && calibration?.supports(carSetup: carSetup, hud: hud) != true { reasons.append("calibration_missing_or_mismatched") }
            else if let value = row.observations["speed"]?.value?.number, let calibration,
                    !(calibration.minimumSpeedKPH...calibration.maximumSpeedKPH).contains(value) {
                reasons.append("speed_outside_calibration")
            }
            if !cameraVerified && !observedStraight { reasons.append("camera_not_verified") }
        }
        if proposal.origin.hasPrefix("learned") { reasons.append("learned_shadow_only") }
        if proposal.cue == .cannotJudge { reasons.append(proposal.reason) }
        return SlowdownDecision(proposal: proposal, acceptedCue: reasons.isEmpty ? proposal.cue : .cannotJudge,
                                suppressionReasons: reasons)
    }
}
