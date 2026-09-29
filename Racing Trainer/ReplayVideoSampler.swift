import AVFoundation
import Foundation

nonisolated enum ReplaySpeedUnit: String, CaseIterable, Identifiable, Sendable {
    case kmh
    case mph

    var id: String { rawValue }
    var label: String { self == .kmh ? "km/h" : "mph" }

    func kilometersPerHour(from value: Double) -> Double {
        self == .mph ? value * 1.609344 : value
    }
}

nonisolated enum ReplayVideoSamplerError: LocalizedError {
    case invalidRange
    case unavailableDuration
    case rangeOutsideVideo
    case unsupportedAspectRatio
    case noFrames

    var errorDescription: String? {
        switch self {
        case .invalidRange:
            return "Choose a finite video range longer than 0 and no longer than 60 seconds."
        case .unavailableDuration:
            return "This video does not have a readable finite duration."
        case .rangeOutsideVideo:
            return "The selected range extends beyond this video."
        case .unsupportedAspectRatio:
            return "Speed extraction currently requires uncropped 16:9 Motorfest footage with the standard HUD."
        case .noFrames:
            return "No frames could be sampled inside the selected range."
        }
    }
}

/// Offline, bounded sampling. Decoded source presentation times are the only
/// timeline used here; neither playback position nor process uptime is a label.
/// A 16:9 image is necessary but cannot prove the HUD is standard or unobscured.
/// Every observation therefore remains unreviewed, including high-confidence OCR.
actor ReplayVideoSampler {
    static let maxDuration = 60.0
    static let sampleRate = 5.0
    static let maxSampleCount = 300

    func sample(
        url: URL,
        start: Double,
        end: Double,
        unit: ReplaySpeedUnit,
        progress: @Sendable (Double) async -> Void = { _ in }
    ) async throws -> [ReplaySpeedSample] {
        guard start.isFinite, end.isFinite, start >= 0, end > start,
              end - start <= Self.maxDuration else {
            throw ReplayVideoSamplerError.invalidRange
        }
        try Task.checkCancellation()
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { url.stopAccessingSecurityScopedResource() } }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw ReplayVideoSamplerError.unavailableDuration
        }
        guard end <= duration + 0.001 else {
            throw ReplayVideoSamplerError.rangeOutsideVideo
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        defer { generator.cancelAllCGImageGeneration() }

        let count = min(Self.maxSampleCount, Int(ceil((end - start) * Self.sampleRate)))
        var samples: [ReplaySpeedSample] = []
        samples.reserveCapacity(count)
        var seenTimes: Set<Double> = []
        await progress(0)

        for index in 0..<count {
            try Task.checkCancellation()
            let requestedSeconds = start + Double(index) / Self.sampleRate
            let requestedTime = CMTime(seconds: requestedSeconds, preferredTimescale: 60000)
            // The async API returns the decoded frame's actual source timestamp.
            let decoded = try await generator.image(at: requestedTime)
            try Task.checkCancellation()

            let aspectRatio = Double(decoded.image.width) / Double(decoded.image.height)
            guard abs(aspectRatio - 16.0 / 9.0) <= 0.01 else {
                throw ReplayVideoSamplerError.unsupportedAspectRatio
            }
            let sourceSeconds = decoded.actualTime.seconds
            if sourceSeconds.isFinite, sourceSeconds >= start, sourceSeconds < end,
               seenTimes.insert(sourceSeconds).inserted {
                let result = autoreleasepool {
                    MotorfestSpeedRecognizer.recognize(in: decoded.image)
                }
                // Never infer units from the recognizer's legacy live configuration.
                // Missing OCR remains missing; do not stabilize or carry it forward.
                let convertedSpeed = result.speed.map {
                    unit.kilometersPerHour(from: Double($0))
                }
                let speedKPH = convertedSpeed.flatMap {
                    ReplaySession.speedRangeKPH.contains($0) ? $0 : nil
                }
                samples.append(ReplaySpeedSample(
                    time: sourceSeconds,
                    speedKPH: speedKPH,
                    confidence: speedKPH == nil ? 0 : Double(result.confidence),
                    reviewed: false
                ))
            }
            await progress(Double(index + 1) / Double(count))
        }

        try Task.checkCancellation()
        guard !samples.isEmpty else { throw ReplayVideoSamplerError.noFrames }
        return samples.sorted { $0.time < $1.time }
    }
}
