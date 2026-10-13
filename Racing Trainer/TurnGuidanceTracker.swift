import Foundation

/// Causal prototype: follow the closest bend's onset in map coordinates. Its
/// approach rate gives a scale-free ETA; speed OCR only establishes movement.
/// No meters, braking targets, future frames or wheel inputs are used.
nonisolated struct TurnGuidanceTracker {
    static let version = "turn-guidance-v1"
    private var session: Int?
    private var lastTime: Double?
    private var lastCapture: Double?
    private var direction: String?
    private var track: [(time: Double, distance: Double)] = []
    private var announced = false
    private var firedAt: Double?
    // Keep delivery suppression through short perception dropouts. Source/time
    // resets clear it, so a video seek can replay the same cue normally.
    private var delivered: [String: Double] = [:]

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
              usable("minimap", age: 0.65, confidence: 0.52), usable("geometry", age: 0.65, confidence: 0.52),
              let geometry = row.observations["geometry"], let points = geometry.value?.path,
              points.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else {
            clearBend()
            return sample(time, .unavailable, "unknown", "Fresh route evidence is missing")
        }
        let selection = RouteTurnSelector.select(points.map { MinimapPoint(x: $0[0], y: $0[1]) }, preferUpcoming: false)
        guard ["left", "right"].contains(selection.direction), let distance = selection.distance else {
            clearBend()
            return sample(time, selection.direction == "straight" ? .straight : .unavailable,
                          selection.direction == "straight" ? "straight" : "unknown", "No established nearby bend")
        }
        let moving = usable("speed", age: 0.75, confidence: 0.30)
            && ["km/h", "mph"].contains(row.observations["speed"]?.units ?? "")
            && (row.observations["speed"]?.value?.number).map({ $0.isFinite && $0 > 3 && $0 <= 500 }) == true
            && abs((row.observations["speed"]?.capturedAt ?? -10) - geometry.capturedAt) <= 0.75
        guard moving else {
            clearBend()
            return sample(time, .preview, selection.direction, "Waiting for fresh movement evidence")
        }
        // A direction change or a discontinuous onset must establish a new approach.
        // A fixed near-distance threshold by itself never authorizes Turn Now.
        if direction != selection.direction || track.last.map({ abs(distance - $0.distance) > 0.075 }) == true {
            clearBend(); direction = selection.direction
        }
        if let firedAt, time - firedAt > 1.2, distance > 0.16 {
            clearBend(); direction = selection.direction
        }
        if lastCapture != geometry.capturedAt {
            track.append((geometry.capturedAt, distance)); lastCapture = geometry.capturedAt
            track.removeAll { $0.time < time - 1.5 }
        }
        guard let first = track.first, let last = track.last, track.count >= 4,
              last.time - first.time >= 0.4 else {
            return sample(time, .preview, selection.direction, "Confirming the same bend across frames")
        }
        // Robust pairwise slope tolerates pixel quantization without interpreting
        // a single distance jump as a rapidly approaching turn.
        var rates: [Double] = []
        for i in track.indices {
            for j in track.indices where j > i && track[j].time - track[i].time >= 0.3 {
                rates.append((track[i].distance - track[j].distance) / (track[j].time - track[i].time))
            }
        }
        rates.sort()
        let rate = rates.isEmpty ? 0 : rates[rates.count / 2]
        let approaching = rate >= 0.015 && rate <= 0.6 && first.distance - last.distance >= 0.025
        let eta = approaching ? distance / rate : nil
        if let firedAt {
            return sample(time, time - firedAt <= 1.2 ? .turnNow : .following, selection.direction,
                          "Turn-in cue already issued for this approach", eta: eta)
        }
        // Turn-in lead is deliberately short. Require a tracked approach from
        // outside the near zone; starting playback mid-bend cannot trigger it.
        if approaching, track.contains(where: { $0.distance >= 0.08 }),
           last.time - first.time >= 0.7, distance <= 0.035, let eta, eta <= 0.6 {
            if time - (delivered["turn_now|\(selection.direction)"] ?? -.infinity) < 4 {
                return sample(time, .following, selection.direction, "Recent turn-in cue; suppressing a repeated cue", eta: eta)
            }
            firedAt = time
            return sample(time, .turnNow, selection.direction, "Tracked bend onset has reached the near zone", eta: eta, cue: true)
        }
        if (eta.map { $0 <= 6 } == true || distance <= 0.30) && distance > 0.035 {
            let cue = !announced; announced = true
            return sample(time, .headsUp, selection.direction, "Established bend ahead; turn-in point has not been reached", eta: eta, cue: cue)
        }
        return sample(time, .preview, selection.direction, "Approach timing is not established", eta: eta)
    }

    private mutating func clearBend() {
        track = []; direction = nil; lastCapture = nil; announced = false; firedAt = nil
    }

    private mutating func sample(_ time: Double, _ stage: TurnGuidanceStage, _ direction: String,
                                 _ reason: String, eta: Double? = nil, cue: Bool = false) -> TurnGuidanceSample {
        let key = "\(stage.rawValue)|\(direction)"
        let freshCue = cue && time - (delivered[key] ?? -.infinity) >= (stage == .headsUp ? 6 : 4)
        if freshCue { delivered[key] = time }
        return TurnGuidanceSample(time: time, stage: stage, direction: direction, reason: reason,
                                  secondsToTurn: eta, isCueStart: freshCue)
    }
}
