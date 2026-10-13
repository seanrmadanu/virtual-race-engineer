// Usage: swift extract_frames.swift <source.mp4> <new-output-directory>
// This prepares one development-only practice batch, not an evaluation split.
import Foundation
import AVFoundation
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func prepare() async throws {
    guard CommandLine.arguments.count == 3 else {
        throw NSError(domain: "ReviewBatch", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected source video and NEW output directory"])
    }
    let source = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).standardizedFileURL
    let fm = FileManager.default
    guard !fm.fileExists(atPath: output.path) else {
        throw NSError(domain: "ReviewBatch", code: 2, userInfo: [NSLocalizedDescriptionKey: "Output already exists; refusing to overwrite"])
    }
    let sourceData = try Data(contentsOf: source, options: .mappedIfSafe)
    let sourceHash = sha256(sourceData)
    let asset = AVURLAsset(url: source)
    let duration = CMTimeGetSeconds(try await asset.load(.duration))
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        throw NSError(domain: "ReviewBatch", code: 3, userInfo: [NSLocalizedDescriptionKey: "Video track missing"])
    }
    let size = try await track.load(.naturalSize)
    let fps = try await track.load(.nominalFrameRate)
    guard size.width == 1920, size.height == 1080, duration > 592 else {
        throw NSError(domain: "ReviewBatch", code: 4, userInfo: [NSLocalizedDescriptionKey: "This reviewed mask/sampling recipe expects 1920x1080 and at least 592 seconds"])
    }
    // Fixed temporal sampling, chosen without speed, direction or phase labels.
    let decisions: [Double] = [95, 150, 205, 260, 315, 370, 425, 480, 535, 590]
    let recordingID = "video1-" + sourceHash.prefix(12)
    let batchID = "practice-" + sourceHash.prefix(12) + "-v1"
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let framesDir = output.appendingPathComponent("frames", isDirectory: true)
    try fm.createDirectory(at: framesDir, withIntermediateDirectories: true)
    var cases: [[String: Any]] = []
    for (caseIndex, decision) in decisions.enumerated() {
        let eventID = String(format: "case-%02d", caseIndex + 1)
        var frames: [[String: Any]] = []
        var lastTime = -Double.infinity
        for index in 0..<20 {
            // Start 0.1s inside the two-second window to allow preceding source PTS.
            let requested = decision - 1.9 + Double(index) / 10.0
            let result = try await generator.image(at: CMTime(seconds: requested, preferredTimescale: 60000))
            let actual = CMTimeGetSeconds(result.actualTime)
            guard actual.isFinite, actual >= decision - 2, actual <= decision, actual > lastTime,
                  actual <= requested + 0.000001 else {
                throw NSError(domain: "ReviewBatch", code: 5, userInfo: [NSLocalizedDescriptionKey: "Out-of-window, duplicate or future frame at \(eventID)/\(index): \(actual)"])
            }
            lastTime = actual
            let width = result.image.width, height = result.image.height
            guard width == 1920, height == 1080,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw NSError(domain: "ReviewBatch", code: 6, userInfo: [NSLocalizedDescriptionKey: "Unexpected decoded dimensions or bitmap allocation failure"])
            }
            context.draw(result.image, in: CGRect(x: 0, y: 0, width: width, height: height))
            // Burn the inset mask into the pixels; never serve an unmasked source frame.
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: height - 344, width: 520, height: 344))
            guard let image = context.makeImage() else { throw NSError(domain: "ReviewBatch", code: 7) }
            let frameID = String(format: "%@-f%02d", eventID, index + 1)
            let file = "frames/\(frameID).jpg"
            let imageURL = output.appendingPathComponent(file)
            guard let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw NSError(domain: "ReviewBatch", code: 8)
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.97] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "ReviewBatch", code: 9) }
            frames.append(["frame_id": frameID, "source_time_s": actual, "requested_time_s": requested,
                           "path": file, "sha256": sha256(try Data(contentsOf: imageURL))])
        }
        cases.append(["event_id": eventID, "recording_id": recordingID, "source_group_id": recordingID,
                      "decision_time_s": decision, "input_interval_s": [decision - 2, decision], "frames": frames])
        print("Prepared \(eventID): \(frames.count) causal, masked frames")
    }
    let manifest: [String: Any] = [
        "schema_version": "review-batch-v1", "batch_id": batchID,
        "purpose": "development_practice_only", "action_labels_enabled": false,
        "created_at": ISO8601DateFormatter().string(from: Date()),
        "source": ["filename": source.lastPathComponent, "sha256": sourceHash,
                   "duration_s": duration, "width": size.width, "height": size.height, "nominal_fps": fps,
                   "platform": "unknown", "car_setup": "unknown", "provenance": "user_supplied_local_file"],
        "preprocessing": ["version": "masked-causal-jpeg-v1", "mask_top_left_xywh": [0, 0, 520, 344],
                          "output_width": 1920, "output_height": 1080, "jpeg_quality": 0.97,
                          "nominal_sample_hz": 10, "audio_included": false],
        "selection": "Ten fixed, widely spaced times; not selected by labels, not independent test sessions.",
        "cases": cases
    ]
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: output.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
    print("READY: \(output.path)")
}

do { try await prepare() }
catch {
    FileHandle.standardError.write(Data("Extraction failed: \(error.localizedDescription)\nPartial output is not a ready batch. Use a new directory on retry.\n".utf8))
    exit(1)
}
