import Foundation

/// Provenance is deliberately separate from the file name. Clips cut from one
/// recording keep the same sourceGroupID when preparing train/test splits.
nonisolated struct ReplayMetadata: Codable, Equatable, Sendable {
    var routeID: String
    var cornerID: String
    var setupID: String
    var sourceGroupID: String

    static let empty = ReplayMetadata()

    init(routeID: String = "", cornerID: String = "", setupID: String = "",
         sourceGroupID: String = "") {
        self.routeID = routeID
        self.cornerID = cornerID
        self.setupID = setupID
        self.sourceGroupID = sourceGroupID
    }
}

nonisolated struct ReplayLandmark: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var time: Double
}

nonisolated struct ReplaySpeedSample: Codable, Equatable, Identifiable, Sendable {
    var time: Double
    var speedKPH: Double?
    var confidence: Double
    var reviewed: Bool
    var id: Double { time }

    init(time: Double, speedKPH: Double? = nil, confidence: Double = 0,
         reviewed: Bool = false) {
        self.time = time
        self.speedKPH = speedKPH
        self.confidence = confidence
        self.reviewed = reviewed
    }
}

nonisolated struct ReplayValidationError: Error, LocalizedError, Equatable, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// An editable draft can be incomplete in memory. Imports and exports must pass
/// validate(); an empty landmark/sample collection remains a valid draft dataset,
/// but is not sufficient for a comparison.
nonisolated struct ReplaySession: Codable, Equatable, Sendable {
    static let supportedSchemaVersion = 1
    static let speedRangeKPH = 0.0...500.0

    var schemaVersion: Int
    var sourceFileName: String
    var duration: Double
    var metadata: ReplayMetadata
    var landmarks: [ReplayLandmark]
    var samples: [ReplaySpeedSample]

    init(schemaVersion: Int = 1, sourceFileName: String = "", duration: Double = 0,
         metadata: ReplayMetadata = .empty, landmarks: [ReplayLandmark] = [],
         samples: [ReplaySpeedSample] = []) {
        self.schemaVersion = schemaVersion
        self.sourceFileName = sourceFileName
        self.duration = duration
        self.metadata = metadata
        self.landmarks = landmarks
        self.samples = samples
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sourceFileName, duration, metadata, landmarks, samples
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        sourceFileName = try container.decode(String.self, forKey: .sourceFileName)
        duration = try container.decode(Double.self, forKey: .duration)
        metadata = try container.decode(ReplayMetadata.self, forKey: .metadata)
        landmarks = try container.decode([ReplayLandmark].self, forKey: .landmarks)
        samples = try container.decode([ReplaySpeedSample].self, forKey: .samples)
        try validate()
    }

    func validate() throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw ReplayValidationError(message: message) }
        }
        func nonblank(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        try require(schemaVersion == Self.supportedSchemaVersion,
                    "Unsupported replay schema version \(schemaVersion).")
        try require(nonblank(sourceFileName), "The source file name is required.")
        try require(duration.isFinite && duration > 0,
                    "Duration must be a finite positive number of seconds.")
        for (name, value) in [("route", metadata.routeID), ("corner", metadata.cornerID),
                              ("setup", metadata.setupID), ("source group", metadata.sourceGroupID)] {
            try require(nonblank(value), "The \(name) ID is required.")
        }

        var previousSampleTime: Double?
        for (index, sample) in samples.enumerated() {
            try require(sample.time.isFinite && (0...duration).contains(sample.time),
                        "Sample \(index + 1) has a timestamp outside the recording.")
            if let previousSampleTime {
                try require(sample.time > previousSampleTime,
                            "Sample timestamps must be unique and strictly increasing.")
            }
            try require(sample.confidence.isFinite && (0...1).contains(sample.confidence),
                        "Sample \(index + 1) confidence must be finite and between 0 and 1.")
            if let speed = sample.speedKPH {
                try require(speed.isFinite && Self.speedRangeKPH.contains(speed),
                            "Sample \(index + 1) speed must be finite and between 0 and 500 km/h.")
            }
            previousSampleTime = sample.time
        }

        var previousLandmarkTime: Double?
        var identifiers = Set<String>()
        for landmark in landmarks {
            try require(nonblank(landmark.id), "Every landmark needs an ID.")
            try require(identifiers.insert(landmark.id).inserted, "Landmark IDs must be unique.")
            try require(landmark.time.isFinite && (0...duration).contains(landmark.time),
                        "Landmark \(landmark.id) has a timestamp outside the recording.")
            if let previousLandmarkTime {
                try require(landmark.time > previousLandmarkTime,
                            "Landmark timestamps must be unique and strictly increasing.")
            }
            previousLandmarkTime = landmark.time
        }
    }
}

nonisolated enum ReplayComparisonStatus: String, Codable, CaseIterable, Sendable {
    case withheld, aboveReference, belowReference, nearReference
}

nonisolated struct ReplayComparison: Codable, Equatable, Identifiable, Sendable {
    var time: Double
    var referenceTime: Double?
    var playerKPH: Double?
    var referenceKPH: Double?
    /// Positive means the player was faster than the reference, not that the
    /// player should brake. Negative is never an instruction to accelerate.
    var deltaKPH: Double?
    var status: ReplayComparisonStatus
    var reason: String
    var id: Double { time }
}

nonisolated struct ReplaySummary: Codable, Equatable, Sendable {
    var comparableCount: Int
    var totalCount: Int
    var meanAbsoluteSpeedGapKPH: Double?
}

nonisolated struct ReplayReport: Codable, Equatable, Sendable {
    var rows: [ReplayComparison]
    var summary: ReplaySummary
    var notes: [String]
}

/// Offline description of two recordings. This does not authorize or alter any
/// live coaching action. It estimates neither an optimal speed nor causality.
nonisolated enum ReplayEvaluator {
    static let minimumConfidence = 0.8
    static let maximumInterpolationGap = 0.6
    static let comparisonBandKPH = 10.0
    static let comparisonNotes = [
        "Manual landmark time alignment is approximate; equal aligned times do not prove equal track position or vehicle state.",
        "The ±10 km/h band is a provisional descriptive comparison, not an optimal speed envelope or a driving command.",
        "Below-reference speed never means accelerate. These results provide no causal or live driving guidance."
    ]

    static func evaluate(player: ReplaySession, reference: ReplaySession) -> ReplayReport {
        var notes = comparisonNotes
        var problems: [String] = []
        do { try player.validate() } catch { problems.append("Player recording: \(error.localizedDescription)") }
        do { try reference.validate() } catch { problems.append("Reference recording: \(error.localizedDescription)") }

        if problems.isEmpty {
            if player.metadata.routeID != reference.metadata.routeID ||
                player.metadata.cornerID != reference.metadata.cornerID ||
                player.metadata.setupID != reference.metadata.setupID {
                problems.append("Route, corner and setup IDs must match exactly.")
            }
            if player.landmarks.count < 2 || reference.landmarks.count < 2 {
                problems.append("At least two matching landmarks are required for alignment.")
            } else if player.landmarks.map(\.id) != reference.landmarks.map(\.id) {
                problems.append("Both recordings must have the exact same ordered landmark IDs.")
            }
            if player.metadata.sourceGroupID == reference.metadata.sourceGroupID {
                notes.append("Both recordings belong to the same source group; this comparison is not independent validation.")
            }
        }

        if !problems.isEmpty {
            notes.append(contentsOf: problems)
            let reason = "Comparison withheld. " + problems.joined(separator: " ")
            let rows = player.samples.map { sample in
                ReplayComparison(time: sample.time.isFinite ? sample.time : 0,
                                 referenceTime: nil, playerKPH: nil, referenceKPH: nil,
                                 deltaKPH: nil, status: .withheld,
                                 reason: sample.time.isFinite ? reason :
                                    reason + " Invalid source timestamp; 0 is only an export placeholder.")
            }
            return report(rows: rows, notes: notes)
        }

        let rows = player.samples.map { sample -> ReplayComparison in
            guard let referenceTime = alignedTime(sample.time, from: player.landmarks,
                                                 to: reference.landmarks) else {
                return withheld(sample, reason: "Outside the landmark interval; extrapolation is disabled.")
            }
            guard let playerSpeed = usableSpeed(sample) else {
                return withheld(sample, referenceTime: referenceTime,
                                reason: "Player speed is missing, unreviewed, or below 0.8 confidence.")
            }
            guard let referenceSpeed = speed(at: referenceTime, in: reference.samples) else {
                return withheld(sample, referenceTime: referenceTime,
                                reason: "Reference speed is missing, unreviewed, low confidence, or separated by a gap greater than 0.6 seconds.")
            }
            let delta = playerSpeed - referenceSpeed
            let status: ReplayComparisonStatus = delta > comparisonBandKPH ? .aboveReference :
                delta < -comparisonBandKPH ? .belowReference : .nearReference
            let reason: String
            switch status {
            case .aboveReference:
                reason = "Observed speed is above the reference band; this is not a braking instruction."
            case .belowReference:
                reason = "Observed speed is below the reference band; this is not an acceleration instruction."
            case .nearReference:
                reason = "Observed speed is within the provisional ±10 km/h reference band."
            case .withheld:
                reason = "Comparison withheld."
            }
            return ReplayComparison(time: sample.time, referenceTime: referenceTime,
                                    playerKPH: playerSpeed, referenceKPH: referenceSpeed,
                                    deltaKPH: delta, status: status, reason: reason)
        }
        return report(rows: rows, notes: notes)
    }

    private static func report(rows: [ReplayComparison], notes: [String]) -> ReplayReport {
        let gaps = rows.compactMap(\.deltaKPH)
        let average = gaps.isEmpty ? nil : gaps.reduce(0) { $0 + abs($1) } / Double(gaps.count)
        return ReplayReport(rows: rows,
                            summary: ReplaySummary(comparableCount: gaps.count, totalCount: rows.count,
                                                   meanAbsoluteSpeedGapKPH: average), notes: notes)
    }

    private static func withheld(_ sample: ReplaySpeedSample, referenceTime: Double? = nil,
                                 reason: String) -> ReplayComparison {
        ReplayComparison(time: sample.time, referenceTime: referenceTime,
                         playerKPH: usableSpeed(sample), referenceKPH: nil, deltaKPH: nil,
                         status: .withheld, reason: reason)
    }

    private static func usableSpeed(_ sample: ReplaySpeedSample) -> Double? {
        guard sample.reviewed, sample.confidence.isFinite,
              (minimumConfidence...1).contains(sample.confidence),
              let speed = sample.speedKPH, speed.isFinite,
              ReplaySession.speedRangeKPH.contains(speed) else { return nil }
        return speed
    }

    private static func alignedTime(_ time: Double, from player: [ReplayLandmark],
                                    to reference: [ReplayLandmark]) -> Double? {
        guard let first = player.first, let last = player.last,
              time >= first.time, time <= last.time else { return nil }
        // Exact anchor hits retain their exact reference timestamps.
        if let anchor = player.firstIndex(where: { $0.time == time }) {
            return reference[anchor].time
        }
        guard let upper = player.firstIndex(where: { $0.time > time }), upper > 0 else { return nil }
        let lower = upper - 1
        let fraction = (time - player[lower].time) / (player[upper].time - player[lower].time)
        return reference[lower].time + fraction * (reference[upper].time - reference[lower].time)
    }

    private static func speed(at time: Double, in samples: [ReplaySpeedSample]) -> Double? {
        // Binary search keeps replay evaluation inexpensive for long recordings.
        var lowerIndex = 0
        var upperIndex = samples.count
        while lowerIndex < upperIndex {
            let middle = lowerIndex + (upperIndex - lowerIndex) / 2
            if samples[middle].time < time { lowerIndex = middle + 1 }
            else { upperIndex = middle }
        }
        if lowerIndex < samples.count, samples[lowerIndex].time == time {
            return usableSpeed(samples[lowerIndex])
        }
        guard lowerIndex > 0, lowerIndex < samples.count else { return nil }
        let previous = samples[lowerIndex - 1]
        let next = samples[lowerIndex]
        let gap = next.time - previous.time
        // Adjacent samples only: a rejected/missing observation cannot be skipped
        // to bridge two more distant usable observations.
        guard gap > 0, gap <= maximumInterpolationGap + 1e-9,
              let previousSpeed = usableSpeed(previous), let nextSpeed = usableSpeed(next) else { return nil }
        let fraction = (time - previous.time) / gap
        return previousSpeed + fraction * (nextSpeed - previousSpeed)
    }
}
