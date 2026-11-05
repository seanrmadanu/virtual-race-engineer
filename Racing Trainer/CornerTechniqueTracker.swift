import Foundation

/// Category 2 prototype. Own on one serial analysis queue. Confirmation and
/// transitions advance only on distinct fresh captures; seeks/gaps reset them.
nonisolated struct CornerTechniqueTracker {
    static let version = CornerTechniqueSample.implementationVersion
    private var session: Int?
    private var lastTime: Double?
    private var lastCapture: Double?
    private var current = Confirmation()
    private var upcoming = Confirmation(retainsAccepted: true)
    private var angles: [(time: Double, angle: Double)] = []
    private var activeDirection: String?
    private var entryAt: Double?
    private var exitAt: Double?
    private var easingSince: Double?
    private var tighteningSince: Double?
    private var exiting = false
    private var peakAngle = 0.0
    private var lastSample: CornerTechniqueSample?

    mutating func reset() { self = Self() }

    mutating func update(row: CoachHistoryRow, session: Int) -> CornerTechniqueSample {
        let time = row.time
        if self.session != session || lastTime.map({ time <= $0 || time - $0 > 0.75 }) == true { reset() }
        self.session = session; lastTime = time
        func usable(_ key: String, age: Double, confidence: Float) -> Bool {
            row.observations[key]?.isUsable(at: time, sessionID: session,
                maximumAge: age, minimumConfidence: confidence) == true
        }
        guard time.isFinite, time >= 0,
              usable("validity", age: 0.65, confidence: 0), row.observations["validity"]?.value?.flag == true,
              usable("minimap", age: 0.65, confidence: 0.52), row.observations["minimap"]?.value?.flag == true,
              usable("geometry", age: 0.65, confidence: 0.52),
              let geometry = row.observations["geometry"], let points = geometry.value?.path,
              points.count >= 6, points.count <= 4096,
              points.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isFinite && (0...1).contains($0) } }),
              let anchor = geometry.value?.playerAnchor, anchor.count == 2,
              anchor.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              ["minimap", "validity"].allSatisfy({ abs(row.observations[$0]!.capturedAt - geometry.capturedAt) <= 0.25 }) else {
            return unavailable(at: time, reason: "Fresh route and player position are needed")
        }
        guard usable("speed", age: 0.75, confidence: 0.30), let speed = row.observations["speed"],
              let value = speed.value?.number, value.isFinite, (0...500).contains(value),
              ["km/h", "mph"].contains(speed.units ?? ""),
              abs(speed.capturedAt - geometry.capturedAt) <= 0.75 else {
            return unavailable(at: time, reason: "Fresh speed with a known unit is needed to track progress")
        }
        guard value * (speed.units == "mph" ? 1.609344 : 1) > 3 else {
            return unavailable(at: time, reason: "Vehicle is stopped")
        }
        let path = points.map { MinimapPoint(x: $0[0], y: $0[1]) }
        guard let near = RouteTurnSelector.nearRoute(path, anchor: MinimapPoint(x: anchor[0], y: anchor[1])) else {
            return unavailable(at: time, reason: "The visible route is not connected to the player")
        }
        let capture = geometry.capturedAt
        if let lastCapture, capture < lastCapture {
            return unavailable(at: time, reason: "Route frames arrived out of order")
        }
        if capture == lastCapture, let sample = lastSample {
            if let expiry = sample.validUntil, time > expiry {
                return unavailable(at: time, reason: "The last phase evidence has expired")
            }
            // A display tick is not fresh supporting evidence or a new transition.
            return CornerTechniqueSample(time: time, phase: sample.phase, direction: sample.direction,
                upcomingDirection: sample.upcomingDirection, reason: sample.reason,
                evidenceCapturedAt: sample.evidenceCapturedAt, validUntil: sample.validUntil, isPhaseStart: false)
        }
        lastCapture = capture
        let previousDirection = current.accepted
        angles.append((capture, near.tangent))
        angles.removeAll { $0.time < capture - 0.25 }
        let sorted = angles.map(\.angle).sorted()
        let tangent = sorted[sorted.count / 2]
        let magnitude = abs(tangent)
        let side = tangent < 0 ? "left" : "right"
        let raw = magnitude <= 9 ? "straight" : magnitude >= 14 ? side
            : current.accepted == side || current.accepted == "straight" ? current.accepted : "unknown"
        let resolved = current.update(raw, at: capture)
        let next = RouteTurnSelector.select(path, preferUpcoming: resolved != "straight", minimumChange: 16)
        let nextSide = ["left", "right"].contains(next.direction)
            && (resolved == "straight" || (next.direction != resolved && (next.distance ?? 0) >= 0.08))
            ? next.direction : "unknown"
        let future = upcoming.update(nextSide, at: capture)
        guard resolved != "unknown" else {
            // Keep only confirmation history. Do not claim a phase on contradictory frames.
            return publish(at: time, phase: .unavailable, direction: "unknown", future: future,
                           reason: "Confirming the near-route direction", capture: nil, expiry: nil)
        }
        let phase: CornerTechniquePhase
        let direction: String
        let reason: String
        if resolved == "straight" {
            if let activeDirection {
                if exitAt == nil { exitAt = capture }
                if capture - exitAt! < 0.60 {
                    phase = .exit; direction = activeDirection
                    reason = "The near route has straightened after the \(activeDirection) bend"
                } else {
                    self.activeDirection = nil; entryAt = nil; exitAt = nil; easingSince = nil; peakAngle = 0
                    exiting = false; tighteningSince = nil
                    phase = future == "unknown" ? .straight : .approach
                    direction = future == "unknown" ? "straight" : future
                    reason = "The near route is straight; the previous bend has ended"
                }
            } else {
                phase = future == "unknown" ? .straight : .approach
                direction = future == "unknown" ? "straight" : future
                reason = future == "unknown" ? "The near route is straight" : "A \(future) bend is visible ahead of the straight near route"
            }
        } else {
            if activeDirection != resolved {
                activeDirection = resolved; exitAt = nil; easingSince = nil; peakAngle = magnitude
                exiting = false; tighteningSince = nil
                // Starting in a bend never fabricates an observed entry.
                entryAt = previousDirection != "unknown" && previousDirection != resolved ? capture : nil
            }
            peakAngle = max(peakAngle, magnitude)
            if magnitude <= peakAngle * 0.6 && peakAngle - magnitude >= 12 {
                if easingSince == nil { easingSince = capture }
                if capture - easingSince! >= 0.30 - 1e-9 { exiting = true }
            } else { easingSince = nil }
            if exiting && magnitude >= peakAngle * 0.8 {
                if tighteningSince == nil { tighteningSince = capture }
                if capture - tighteningSince! >= 0.30 - 1e-9 { exiting = false; exitAt = nil }
            } else { tighteningSince = nil }
            if let entryAt, capture - entryAt < 0.60 {
                phase = .entry; reason = "The near route changed from \(previousDirection == "straight" ? "straight" : "the previous direction") into this bend"
            } else if exiting {
                phase = .exit; reason = "The near-route angle is easing after a sustained bend"
            } else {
                phase = .cornering; reason = "The near route continues through this bend"
            }
            direction = resolved
        }
        let expiry = min(capture + 0.65, speed.capturedAt + 0.75,
                         row.observations["validity"]!.capturedAt + 0.65,
                         row.observations["minimap"]!.capturedAt + 0.65)
        return publish(at: time, phase: phase, direction: direction, future: future,
                       reason: reason, capture: capture, expiry: expiry)
    }

    private mutating func unavailable(at time: Double, reason: String) -> CornerTechniqueSample {
        current = Confirmation(); upcoming = Confirmation(retainsAccepted: true); activeDirection = nil
        entryAt = nil; exitAt = nil; easingSince = nil; peakAngle = 0; lastCapture = nil
        angles = []; tighteningSince = nil; exiting = false
        return publish(at: time, phase: .unavailable, direction: "unknown", future: "unknown",
                       reason: reason, capture: nil, expiry: nil)
    }

    private mutating func publish(at time: Double, phase: CornerTechniquePhase, direction: String,
                                 future: String, reason: String, capture: Double?, expiry: Double?) -> CornerTechniqueSample {
        let sample = CornerTechniqueSample(time: time, phase: phase, direction: direction,
            upcomingDirection: future, reason: reason, evidenceCapturedAt: capture, validUntil: expiry,
            isPhaseStart: phase != .unavailable && (lastSample?.phase != phase || lastSample?.direction != direction))
        lastSample = sample
        return sample
    }

    private struct Confirmation {
        var retainsAccepted = false
        var accepted = "unknown"
        var candidate = "unknown"
        var since: Double?
        var count = 0
        var supportedAt = -Double.infinity

        mutating func update(_ value: String, at time: Double) -> String {
            if value == "unknown" {
                candidate = value; since = nil; count = 0
                return retainsAccepted && time - supportedAt <= 0.25 ? accepted : "unknown"
            }
            if candidate != value { candidate = value; since = time; count = 0 }
            count += 1
            if value == accepted { supportedAt = time; return accepted }
            if count >= 3, time - (since ?? time) >= 0.25 - 1e-9 {
                accepted = value; supportedAt = time; return value
            }
            return retainsAccepted && time - supportedAt <= 0.25 ? accepted : "unknown"
        }
    }
}
