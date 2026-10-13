import CoreImage
import CoreVideo
import CryptoKit
import Foundation
import ImageIO

/// Serial-worker-owned, bounded local evidence. Never writes into a review or training package.
nonisolated final class ShadowSessionRecorder: ShadowRecordingSink {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private struct Manifest: Encodable {
        let schema = "modular-shadow-session-v1"
        let runID: String
        let createdAt: Date
        let configuration: ShadowRunConfiguration
        let clock = "monotonic_receipt_uptime; sourcePTS retained separately; camera acquisition clock unverified"
        let role = "development_evidence_only_not_calibration_not_training"
        let cuesEmitted = false
        var status = "recording"
        var closeReason: String?
        var samples = 0
        var bytes = 0
        var traceSHA256: String?
    }
    private struct Event: Encodable {
        let type: String, reason: String
        let time: Double
        let generation: Int
    }
    let directory: URL
    private let file: FileHandle
    private let encoder = JSONEncoder()
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var manifest: Manifest
    private var hasher = SHA256()
    private var closed = false
    private var lastImageAt = -Double.infinity
    private var lastImageGeneration = -1
    private var lastSyncAt = -Double.infinity

    init(root: URL, configuration: ShadowRunConfiguration) throws {
        guard configuration.maximumBytes >= 1_048_576, configuration.maximumDuration.isFinite,
              configuration.maximumDuration > 0 else { throw Failure(message: "Invalid shadow recording limits.") }
        let id = UUID().uuidString
        directory = root.appendingPathComponent("shadow-" + id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        manifest = Manifest(runID: id, createdAt: Date(), configuration: configuration)
        encoder.outputFormatting = [.sortedKeys]
        let trace = directory.appendingPathComponent("observations.jsonl")
        guard FileManager.default.createFile(atPath: trace.path, contents: nil) else {
            throw Failure(message: "Cannot create the shadow trace.")
        }
        file = try FileHandle(forWritingTo: trace)
        try persistManifest()
    }

    func record(_ sample: ShadowSample, pixels: CVPixelBuffer) throws {
        guard !closed else { throw Failure(message: "Recording is closed.") }
        var record = sample
        if manifest.configuration.recordHUDImages,
           sample.generation != lastImageGeneration || sample.receivedAt - lastImageAt >= 1 {
            // Only HUD crops. No wheel inset, audio, or full-screen recording is stored.
            let image = CIImage(cvPixelBuffer: pixels)
            let rects: [(String, CGRect)] = [
                ("speed", CGRect(x: 0.015, y: 0.605, width: 0.225, height: 0.375)),
                ("minimap", CGRect(x: 0.780, y: 0.620, width: 0.180, height: 0.325))]
            for (name, normalized) in rects {
                let rect = CGRect(x: normalized.minX * image.extent.width,
                    y: (1 - normalized.maxY) * image.extent.height,
                    width: normalized.width * image.extent.width, height: normalized.height * image.extent.height).integral
                guard let crop = context.createCGImage(image, from: rect) else {
                    throw Failure(message: "HUD evidence crop failed.")
                }
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
                    throw Failure(message: "Cannot encode HUD evidence.")
                }
                CGImageDestinationAddImage(destination, crop, nil)
                guard CGImageDestinationFinalize(destination) else { throw Failure(message: "HUD encoding failed.") }
                try reserve(data.length)
                let filename = "g\(sample.generation)-f\(sample.sequence)-\(name).png"
                try (data as Data).write(to: directory.appendingPathComponent(filename), options: .withoutOverwriting)
                manifest.bytes += data.length; record.evidenceImages.append(filename)
                record.evidenceImageSHA256[filename] = SHA256.hash(data: data as Data).map { String(format: "%02x", $0) }.joined()
            }
            lastImageAt = sample.receivedAt; lastImageGeneration = sample.generation
        }
        try append(encoder.encode(record))
        manifest.samples += 1
        if sample.completedAt - lastSyncAt >= 1 {
            try file.synchronize(); try persistManifest(); lastSyncAt = sample.completedAt
        }
    }

    func event(_ type: String, at: Double, generation: Int, reason: String) throws {
        guard !closed else { return }
        try append(encoder.encode(Event(type: type, reason: reason, time: at, generation: generation)))
    }

    func close(reason: String) throws {
        guard !closed else { return }
        closed = true
        // A crash leaves status=recording and no final hash. It is never called a complete run.
        try file.synchronize(); try file.close()
        manifest.status = reason == "recording_failed" ? "failed" : "closed"
        manifest.closeReason = reason
        manifest.traceSHA256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        try persistManifest()
    }

    private func reserve(_ size: Int) throws {
        // Reserve room for manifests/error state. The cap includes trace and image bytes.
        guard manifest.bytes + size <= manifest.configuration.maximumBytes - 16_384 else {
            throw Failure(message: "Shadow recording reached its byte limit.")
        }
    }
    private func append(_ data: Data) throws {
        var line = data; line.append(10); try reserve(line.count)
        try file.write(contentsOf: line); hasher.update(data: line); manifest.bytes += line.count
    }
    private func persistManifest() throws {
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }
}
