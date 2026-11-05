import Foundation

/// Causal navigation with separate near-route direction and upcoming bend.
/// Map coordinates are not meters. An ETA alone never authorizes Turn Now.
nonisolated struct TurnGuidanceTracker {
    static let version = "turn-guidance-v5-player-relative-entry"
    private var session: Int?
    private var lastTime: Double?
    private var lastCapture: Double?
    private var lastValidCapture: Double?
    private var bearings: [(time: Double, value: Double)] = []
    private var currentFilter = DirectionConfirmation(retainsAccepted: true)
    private var nextFilter = DirectionConfirmation()
    private var upcomingFilter = UpcomingBendConfirmation()
    private var roadFilter = DirectionConfirmation()
    private var approachDirection: String?
    private var track: [(time: Double, distance: Double)] = []
    private var approachedFromOutside = false
    private var firedAt: Double?
    private var announced = false
    private var delivered: [String: Double] = [:]
    private var maneuverDirection: String?
    private var maneuver = "bend"
    private var completedTurn = false
    private var turnExitSince: Double?
    private var stableCue: TurnGuidanceSample?

    mutating func reset() { self = Self() }

    mutating func update(row: CoachHistoryRow, session: Int) -> TurnGuidanceSample {
        let time = row.time
        if self.session != session || lastTime.map({ time <= $0 || time - $0 > 0.75 }) == true { reset() }
        self.session = session; lastTime = time
        func usable(_ key: String, age: Double, confidence: Float) -> Bool {
            row.observations[key]?.isUsable(at: time, sessionID: session, maximumAge: age, minimumConfidence: confidence) == true
        }
        guard time.isFinite, time >= 0,
              usable("validity", age: 0.65, confidence: 0), row.observations["validity"]?.value?.flag == true,
              usable("minimap", age: 0.65, confidence: 0.52), row.observations["minimap"]?.value?.flag == true,
              usable("geometry", age: 0.65, confidence: 0.52),
              let geometry = row.observations["geometry"], let points = geometry.value?.path,
              points.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else {
            if time - (lastValidCapture ?? -.infinity) > 0.35 { clearApproach() }
            if let retained = retainDuringReconfirmation(row, session: session) { return retained }
            // Keep a short history for immediate reacquisition, but never publish
            // an expired, missing, malformed, or different-source observation.
            if time - (lastValidCapture ?? -.infinity) > 0.35 {
                currentFilter.reset(); bearings = []
                maneuverDirection = nil; maneuver = "bend"; completedTurn = false; turnExitSince = nil
            }
            let waitingFor: TurnGuidanceWaitReason
            if row.observations["minimap"]?.value?.flag != true { waitingFor = .minimap }
            else if !["validity", "minimap", "geometry"].allSatisfy({ key in
                guard let item = row.observations[key] else { return false }
                return item.sourceSessionID == session && item.capturedAt.isFinite && item.completedAt.isFinite
                    && item.capturedAt <= item.completedAt && item.completedAt <= time
                    && time - item.capturedAt <= 0.65 && item.state != .stale
            }) { waitingFor = .freshFrame }
            else { waitingFor = .route }
            return sample(time, .unavailable, "unknown", "Fresh route evidence is missing", waitingFor: waitingFor)
        }
        let capture = geometry.capturedAt
        let path = points.map { MinimapPoint(x: $0[0], y: $0[1]) }
        let anchor = geometry.value?.playerAnchor.flatMap { values -> MinimapPoint? in
            guard values.count == 2, values.allSatisfy(\.isFinite) else { return nil }
            return MinimapPoint(x: values[0], y: values[1])
        }
        let near = RouteTurnSelector.nearRoute(path, anchor: anchor)
        let selection = RouteTurnSelector.select(path, preferUpcoming: false)
        let speedUsable = usable("speed", age: 0.75, confidence: 0.30)
            && ["km/h", "mph"].contains(row.observations["speed"]?.units ?? "")
            && (row.observations["speed"]?.value?.number).map({ $0.isFinite && $0 >= 0 && $0 <= 500 }) == true
            && abs((row.observations["speed"]?.capturedAt ?? -10) - capture) <= 0.75
        let moving = speedUsable && (row.observations["speed"]?.value?.number ?? 0) > 3
        if speedUsable && !moving {
            clearApproach(); currentFilter.reset(); bearings = []; stableCue = nil
            return sample(time, .unavailable, "unknown", "Vehicle is stopped", waitingFor: .movement)
        }
        let isNewFrame = lastCapture != capture
        lastValidCapture = capture
        if isNewFrame {
            lastCapture = capture
            if let near {
                bearings.append((capture, near.currentHeading))
                bearings.removeAll { $0.time < capture - 0.25 }
            } else { bearings.removeAll { $0.time < capture - 0.25 } }
        }
        let sortedBearings = bearings.map(\.value).sorted()
        let bearing = sortedBearings.isEmpty ? nil : sortedBearings[sortedBearings.count / 2]
        var rawCurrent = "unknown"
        if let bearing, near != nil {
            if abs(bearing) <= 9 { rawCurrent = "straight" }
            else if abs(bearing) >= 14 { rawCurrent = bearing < 0 ? "left" : "right" }
            else if currentFilter.accepted == "straight" { rawCurrent = "straight" }
            else if currentFilter.accepted == (bearing < 0 ? "left" : "right") { rawCurrent = currentFilter.accepted }
        }
        let current = currentFilter.update(rawCurrent, at: capture)
        let next = nextFilter.update(selection.direction, at: capture)
        let matchedNext = next == selection.direction && ["left", "right"].contains(next)
        // Next includes gentle bends, not just the larger changes used by the
        // turn-in tracker. Otherwise a small left bend is skipped for a later right.
        // Use the committed maneuver, not a transient unknown classification,
        // to decide which bend has already become the current one.
        let committedCurrent = currentFilter.accepted
        let future = RouteTurnSelector.select(path, preferUpcoming: ["left", "right"].contains(committedCurrent), minimumChange: 16)
        // Do not repeat the same continuing bend as a supposed next action.
        let futureOutsideCurrent = !["left", "right"].contains(committedCurrent)
            || ((future.distance ?? 0) >= 0.08 && future.direction != committedCurrent)
        let futureDirection = upcomingFilter.update(futureOutsideCurrent ? future : nil,
                                                    current: committedCurrent, at: capture)
        // Explicit unknown prevents legacy display fallback from substituting
        // the timing tracker's farther bend while Next is still confirming.
        let upcoming: String? = ["left", "right"].contains(futureDirection) ? futureDirection : "unknown"
        let distance = selection.distance.map { $0 + (near?.startGap ?? .infinity) }

        var roadDirection = "unknown"
        if usable("road", age: 0.65, confidence: 0.65), let observation = row.observations["road"],
           abs(observation.capturedAt - capture) <= 0.25,
           let road = observation.value?.road, road.isFresh(at: time) {
            roadDirection = roadFilter.update(road.currentBendDirection, at: observation.capturedAt)
        } else { roadFilter.reset() }

        if matchedNext, let distance, distance.isFinite, isNewFrame {
            if approachDirection != next || track.last.map({ abs(distance - $0.distance) > 0.075 }) == true {
                clearApproach(); approachDirection = next
            }
            // A newly distant bend is a new approach, even if its direction is the same.
            if let previous = track.last, distance > 0.18, previous.distance < 0.08 {
                clearApproach(); approachDirection = next
            }
            track.append((capture, distance))
            approachedFromOutside = approachedFromOutside || distance >= 0.12
            track.removeAll { $0.time < capture - 1.5 }
        } else if isNewFrame, let last = track.last, capture - last.time > 0.35 {
            clearApproach()
        }
        var rates: [Double] = []
        for i in track.indices {
            for j in track.indices where j > i && track[j].time - track[i].time >= 0.3 {
                rates.append((track[i].distance - track[j].distance) / (track[j].time - track[i].time))
            }
        }
        rates.sort()
        let rate = rates.isEmpty ? 0 : rates[rates.count / 2]
        let approaching = rate >= 0.015 && rate <= 0.6
        let eta = approaching && matchedNext ? distance.map { $0 / rate } : nil

        let roadContradictsCurrent = roadDirection != "unknown" && roadDirection != current
        if current == "straight" { maneuverDirection = nil; maneuver = "bend"; completedTurn = false; turnExitSince = nil }
        if ["left", "right"].contains(current), !roadContradictsCurrent {
            if maneuverDirection != current {
                maneuver = "bend"; maneuverDirection = current; completedTurn = false; turnExitSince = nil
            }
            if !completedTurn, rawCurrent == current {
                if abs(bearing ?? 0) >= 45 { maneuver = "turn"; turnExitSince = nil }
                else if maneuver == "turn", abs(bearing ?? 0) < 30 {
                    if turnExitSince == nil { turnExitSince = capture }
                    if capture - turnExitSince! >= 0.20 - 1e-9 {
                        maneuver = "bend"; completedTurn = true
                    }
                } else { turnExitSince = nil }
            }
            // Turn Now needs a measured near-route connection AND independent
            // near-road curvature. Occlusion / a route-only ETA cannot issue it.
            if moving, currentFilter.supportedAt == capture, matchedNext, next == current, approachedFromOutside, approaching,
               let near, near.startGap <= 0.035, let distance, distance <= 0.035,
               let first = track.first, capture - first.time >= 0.7,
               roadDirection == current, firedAt == nil,
               time - (delivered["turn_now|\(current)"] ?? -.infinity) >= 4 {
                firedAt = time
                maneuver = "turn"; completedTurn = false; turnExitSince = nil
                return sample(time, .turnNow, current, "Near route and visible road agree at the tracked bend", cue: true, current: current, upcoming: upcoming)
            }
            if moving, !completedTurn, currentFilter.supportedAt == capture,
               let firedAt, time - firedAt <= 0.8, roadDirection == current,
               matchedNext, let distance, distance <= 0.05 {
                return sample(time, .turnNow, current, "Confirmed turn-in remains at the vehicle", current: current, upcoming: upcoming)
            }
            return sample(time, .following, current, "Stable nearby route tangent indicates the current bend",
                          current: current, maneuver: maneuver, upcoming: upcoming)
        }
        // A past Turn Now is never evidence that a bend is still in progress.
        let resolvedCurrent = roadDirection == "straight" ? "straight" : roadContradictsCurrent ? "unknown" : current
        if matchedNext, let distance, distance <= 0.30 || (eta.map { $0 <= 6 } == true) {
            let cue = !announced; announced = true
            return sample(time, .headsUp, next, "Upcoming bend is separate from the current path", eta: eta,
                          cue: cue, current: resolvedCurrent, upcoming: upcoming)
        }
        if resolvedCurrent == "straight" {
            return sample(time, .straight, "straight", "Stable near-route direction is straight", current: "straight", upcoming: upcoming)
        }
        if matchedNext {
            return sample(time, .preview, next, "Bend is visible but current turn-in is not established", current: "unknown", upcoming: upcoming)
        }
        return sample(time, .unavailable, "unknown", "Confirming the nearby route across frames", waitingFor: .confirmation)
    }

    private mutating func clearApproach() {
        approachDirection = nil; track = []; approachedFromOutside = false; firedAt = nil; announced = false
    }

    private func retainDuringReconfirmation(_ row: CoachHistoryRow, session: Int) -> TurnGuidanceSample? {
        // Only a confidence dip with a still-visible route gets a brief grace.
        // True loss, stale/future inputs, a stop, and a source change clear it.
        guard let prior = stableCue, prior.stage != .turnNow,
              row.time >= prior.time, row.time - prior.time <= 0.25,
              let expiry = prior.validUntil, row.time <= expiry,
              row.observations["minimap"]?.value?.flag == true,
              let geometry = row.observations["geometry"]?.value,
              let points = geometry.path, points.count >= 8,
              points.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }),
              let anchor = geometry.playerAnchor, anchor.count == 2,
              anchor.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        for key in ["validity", "minimap", "geometry"] {
            guard let item = row.observations[key], [.fresh, .uncertain].contains(item.state),
                  item.sourceSessionID == session, item.capturedAt.isFinite, item.completedAt.isFinite,
                  item.confidence.isFinite, (0...1).contains(item.confidence),
                  item.capturedAt >= 0, item.completedAt >= item.capturedAt, item.completedAt <= row.time,
                  row.time - item.capturedAt <= 0.65 else { return nil }
        }
        if let speed = row.observations["speed"],
           speed.isUsable(at: row.time, sessionID: session, maximumAge: 0.75, minimumConfidence: 0.30),
           let value = speed.value?.number, value <= 3 { return nil }
        if let road = row.observations["road"],
           road.isUsable(at: row.time, sessionID: session, maximumAge: 0.65, minimumConfidence: 0.65),
           let direction = road.value?.road?.currentBendDirection,
           direction != "unknown", direction != prior.currentDirection { return nil }
        return TurnGuidanceSample(time: row.time, stage: prior.stage, direction: prior.direction,
            reason: "Retaining still-fresh direction during brief route reconfirmation",
            currentDirection: prior.currentDirection, currentManeuver: prior.currentManeuver,
            upcomingDirection: prior.upcomingDirection, evidenceCapturedAt: prior.evidenceCapturedAt,
            validUntil: min(expiry, prior.time + 0.25))
    }

    private mutating func sample(_ time: Double, _ stage: TurnGuidanceStage, _ direction: String,
                                 _ reason: String, eta: Double? = nil, cue: Bool = false,
                                 current: String = "unknown", maneuver: String? = nil, upcoming: String? = nil,
                                 waitingFor: TurnGuidanceWaitReason? = nil) -> TurnGuidanceSample {
        let key = "\(stage.rawValue)|\(direction)"
        let freshCue = cue && time - (delivered[key] ?? -.infinity) >= (stage == .headsUp ? 6 : 4)
        if freshCue { delivered[key] = time }
        let evidence = current != "unknown" ? currentFilter.supportedAt ?? lastValidCapture : lastValidCapture
        let result = TurnGuidanceSample(time: time, stage: stage, direction: direction, reason: reason,
                                  secondsToTurn: eta?.isFinite == true ? eta : nil, isCueStart: freshCue,
                                  currentDirection: current, currentManeuver: maneuver, upcomingDirection: upcoming,
                                  evidenceCapturedAt: evidence, validUntil: stage == .unavailable ? time : evidence.map { $0 + 0.65 },
                                  waitingFor: waitingFor)
        if current != "unknown", stage != .unavailable, currentFilter.supportedAt == lastCapture {
            stableCue = result
        } else if stage == .unavailable { stableCue = nil }
        return result
    }
}

/// Counts distinct capture times, not redraws. The timing and road filters require
/// strict agreement. Current direction tolerates a short candidate transition,
/// bounded by the last frame that actually supported the accepted direction.
private nonisolated struct DirectionConfirmation {
    var retainsAccepted = false
    private var candidate = "unknown"
    private var since = 0.0
    private var lastCapture: Double?
    private var count = 0
    private(set) var accepted = "unknown"
    private(set) var supportedAt: Double?

    mutating func reset() { self = Self(retainsAccepted: retainsAccepted) }
    mutating func update(_ direction: String, at capture: Double) -> String {
        if lastCapture.map({ capture - $0 > 0.35 || capture < $0 }) == true { reset() }
        guard ["left", "right", "straight"].contains(direction) else {
            candidate = "unknown"; count = 0
            if retainsAccepted, capture - (supportedAt ?? -.infinity) <= 0.30 { return accepted }
            reset(); return "unknown"
        }
        if direction != candidate { candidate = direction; since = capture; count = 0 }
        if lastCapture != capture { count += 1; lastCapture = capture }
        if count >= 3 && capture - since >= 0.20 - 1e-9 { accepted = candidate }
        if direction == accepted { supportedAt = capture; return accepted }
        return retainsAccepted && capture - (supportedAt ?? -.infinity) <= 0.30 ? accepted : "unknown"
    }
}

/// Match the upcoming bend by side and onset distance across frames. Brief
/// selection noise cannot replace it; entering that bend consumes it once.
private nonisolated struct UpcomingBendConfirmation {
    private var accepted: RouteTurnSelector.Selection?
    private var candidate: RouteTurnSelector.Selection?
    private var since = 0.0
    private var count = 0
    private var lastCapture: Double?
    private var supportedAt = -Double.infinity

    mutating func update(_ selection: RouteTurnSelector.Selection?, current: String, at time: Double) -> String {
        if lastCapture.map({ time < $0 || time - $0 > 0.65 }) == true { self = Self() }
        let distinct = lastCapture != time
        lastCapture = time
        if accepted?.direction == current { accepted = nil; candidate = nil; count = 0 }
        if let selection, ["left", "right"].contains(selection.direction) {
            let sameCandidate = candidate?.direction == selection.direction
                && abs((candidate?.distance ?? 0) - (selection.distance ?? 0)) <= 0.12
            if !sameCandidate { candidate = selection; since = time; count = 0 }
            if distinct { count += 1 }
            candidate = selection
            let sameAccepted = accepted?.direction == selection.direction
                && abs((accepted?.distance ?? 0) - (selection.distance ?? 0)) <= 0.12
            if sameAccepted || (count >= 3 && time - since >= 0.30 - 1e-9) {
                accepted = selection; supportedAt = time
            }
        } else { candidate = nil; count = 0 }
        return time - supportedAt <= 0.35 ? accepted?.direction ?? "unknown" : "unknown"
    }
}
