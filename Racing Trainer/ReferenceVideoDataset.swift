import Foundation

/// Reference-only speed observations. Unknown route, car and setup information
/// stays unknown; this format makes no expert-driving or action-label claim.
/// SHA256 identifies identical source bytes, not different edits of one recording.
nonisolated struct ReferenceVideoDataset: Codable, Equatable, Sendable {
    static let supportedSchemaVersion = 1
    static let currentExtractionVersion = "motorfest-fixed-hud-speed-ocr-v1"
    static let maximumSampleCount = 100_000

    var schemaVersion: Int
    var extractionVersion: String
    var sourceFileName: String
    var sourceSHA256: String?
    var sourceGroupID: String?
    var duration: Double
    /// The explicit source HUD unit. All stored speed values are converted to km/h.
    var sourceSpeedUnit: String
    var samplingHz: Double
    var rangeStart: Double
    var rangeEnd: Double
    var samples: [ReplaySpeedSample]

    init(
        sourceFileName: String,
        duration: Double,
        sourceSpeedUnit: String,
        rangeStart: Double,
        rangeEnd: Double,
        sourceSHA256: String? = nil,
        sourceGroupID: String? = nil,
        samplingHz: Double = 5,
        samples: [ReplaySpeedSample] = [],
        schemaVersion: Int = Self.supportedSchemaVersion,
        extractionVersion: String = Self.currentExtractionVersion
    ) {
        self.schemaVersion = schemaVersion
        self.extractionVersion = extractionVersion
        self.sourceFileName = sourceFileName
        self.sourceSHA256 = sourceSHA256
        self.sourceGroupID = sourceGroupID
        self.duration = duration
        self.sourceSpeedUnit = sourceSpeedUnit
        self.samplingHz = samplingHz
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.samples = samples
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, extractionVersion, sourceFileName, sourceSHA256, sourceGroupID
        case duration, sourceSpeedUnit, samplingHz, rangeStart, rangeEnd, samples
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        extractionVersion = try values.decode(String.self, forKey: .extractionVersion)
        sourceFileName = try values.decode(String.self, forKey: .sourceFileName)
        sourceSHA256 = try values.decodeIfPresent(String.self, forKey: .sourceSHA256)
        sourceGroupID = try values.decodeIfPresent(String.self, forKey: .sourceGroupID)
        duration = try values.decode(Double.self, forKey: .duration)
        sourceSpeedUnit = try values.decode(String.self, forKey: .sourceSpeedUnit)
        samplingHz = try values.decode(Double.self, forKey: .samplingHz)
        rangeStart = try values.decode(Double.self, forKey: .rangeStart)
        rangeEnd = try values.decode(Double.self, forKey: .rangeEnd)
        samples = try values.decode([ReplaySpeedSample].self, forKey: .samples)
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
                    "Unsupported reference dataset schema version \(schemaVersion).")
        try require(nonblank(extractionVersion), "The extraction version is required.")
        try require(nonblank(sourceFileName), "The source file name is required.")
        try require(duration.isFinite && duration > 0, "The source duration must be finite and positive.")
        try require(sourceSpeedUnit == "kmh" || sourceSpeedUnit == "mph",
                    "The source unit must explicitly be kmh or mph.")
        try require(samplingHz.isFinite && samplingHz > 0 && samplingHz <= 5,
                    "The extraction rate must be finite and between 0 and 5 Hz.")
        try require(rangeStart.isFinite && rangeEnd.isFinite && rangeStart >= 0 &&
                    rangeEnd > rangeStart && rangeEnd <= duration,
                    "The extraction interval must lie within the source recording.")
        try require(samples.count <= Self.maximumSampleCount,
                    "The reference dataset exceeds the 100,000-sample limit.")
        if let sourceSHA256 {
            let hex = CharacterSet(charactersIn: "0123456789abcdef")
            try require(sourceSHA256.count == 64 && sourceSHA256.unicodeScalars.allSatisfy(hex.contains),
                        "Source SHA256 must contain exactly 64 lowercase hexadecimal characters.")
        }
        if let sourceGroupID {
            try require(nonblank(sourceGroupID), "An included source group ID cannot be blank.")
        }

        var previousTime: Double?
        for (index, sample) in samples.enumerated() {
            try require(sample.time.isFinite && (rangeStart...rangeEnd).contains(sample.time),
                        "Sample \(index + 1) is outside the extracted source interval.")
            if let previousTime {
                try require(sample.time > previousTime, "Sample timestamps must be unique and strictly increasing.")
            }
            try require(sample.confidence.isFinite && (0...1).contains(sample.confidence),
                        "Sample \(index + 1) confidence must be finite and between 0 and 1.")
            if let speed = sample.speedKPH {
                try require(speed.isFinite && ReplaySession.speedRangeKPH.contains(speed),
                            "Sample \(index + 1) speed must be finite and between 0 and 500 km/h.")
            }
            previousTime = sample.time
        }
    }
}
