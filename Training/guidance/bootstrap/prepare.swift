// Local, causal, source-specific 1080p data preparation and frozen Vision encoding.
// Usage: swift prepare.swift source.mp4 NEW-output-dir [start=10] [end=duration-5] [step=5]
import Foundation
import AVFoundation
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Vision

func fail(_ message: String) -> NSError {
    NSError(domain: "GuidanceBootstrap", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func json(_ object: Any, to url: URL) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        .write(to: url, options: .withoutOverwriting)
}
func run() async throws {
    let args = CommandLine.arguments
    guard (3...6).contains(args.count) else { throw fail("Expected source, NEW output, optional start/end/step") }
    let source = URL(fileURLWithPath: args[1]).standardizedFileURL
    let output = URL(fileURLWithPath: args[2], isDirectory: true).standardizedFileURL
    guard !FileManager.default.fileExists(atPath: output.path) else { throw fail("Refusing to overwrite existing output") }
    let asset = AVURLAsset(url: source)
    let duration = CMTimeGetSeconds(try await asset.load(.duration))
    let start = args.count > 3 ? Double(args[3]) ?? .nan : 10
    let end = args.count > 4 ? Double(args[4]) ?? .nan : duration - 5
    let step = args.count > 5 ? Double(args[5]) ?? .nan : 5
    guard start.isFinite, end.isFinite, step.isFinite, start >= 2.1,
          end >= start, end < duration, step >= 2.5 else { throw fail("Invalid sampling range") }
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw fail("No video track") }
    let size = try await track.load(.naturalSize)
    let transform = try await track.load(.preferredTransform)
    guard size.width == 1920, size.height == 1080, transform.isIdentity else {
        throw fail("This HUD profile requires unrotated 1920x1080 video; calibrate other layouts separately")
    }
    let sourceHash = digest(try Data(contentsOf: source, options: .mappedIfSafe))
    let group = "sha256-" + sourceHash
    let fm = FileManager.default
    for name in ["frames", "features"] {
        try fm.createDirectory(at: output.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    // CGImage cropping uses top-left image coordinates. Order is part of the encoder contract.
    let cropBoxes = [[384, 344, 1152, 576], [1536, 688, 384, 352]]
    let encoder: [String: Any] = [
        "name": "apple-vision-featureprint", "revision": 2, "elements_per_view": 768,
        "view_names": ["road", "minimap"], "crop_xywh": cropBoxes,
        "crop_and_scale": "scaleFit", "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "frame_count": 5, "nominal_hz": 2, "dtype": "little-endian-float32",
        "mask_top_left_xywh": [0, 0, 520, 344], "jpeg_quality": 0.97,
        "profile": "motorfest-1080p-reference-v1"
    ]
    var cases: [[String: Any]] = []
    var decision = start
    let overallStart = Date()
    while decision <= end + 0.000001 {
        let id = String(format: "event-%04d", cases.count + 1)
        var frames: [[String: Any]] = []
        var featureBytes = Data()
        var previous = -Double.infinity
        var encodeSeconds = 0.0
        for index in 0..<5 {
            let requested = decision - 2 + Double(index) * 0.5
            let decoded = try await generator.image(at: CMTime(seconds: requested, preferredTimescale: 60000))
            let pts = CMTimeGetSeconds(decoded.actualTime)
            guard pts.isFinite, pts > previous, pts >= decision - 2.1, pts <= requested + 0.000001,
                  requested - pts <= 0.05, decoded.image.width == 1920, decoded.image.height == 1080 else {
                throw fail("Invalid/duplicate/future/gapped frame: \(id) \(pts)")
            }
            previous = pts
            guard let context = CGContext(data: nil, width: 1920, height: 1080, bitsPerComponent: 8,
                bytesPerRow: 1920 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw fail("Bitmap allocation failed") }
            context.draw(decoded.image, in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 1080 - 344, width: 520, height: 344))
            guard let masked = context.makeImage() else { throw fail("Mask failed") }
            let frameID = "\(id)-f\(index + 1)"
            let path = "frames/\(frameID).jpg"
            let fileURL = output.appendingPathComponent(path)
            guard let destination = CGImageDestinationCreateWithURL(fileURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw fail("JPEG destination failed") }
            CGImageDestinationAddImage(destination, masked, [kCGImageDestinationLossyCompressionQuality: 0.97] as CFDictionary)
            guard CGImageDestinationFinalize(destination),
                  let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
                  let stored = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { throw fail("JPEG roundtrip failed") }
            // Encode the exact saved pixels viewed by the annotation teacher, not pre-JPEG pixels.
            let before = Date()
            for box in cropBoxes {
                guard let crop = stored.cropping(to: CGRect(x: box[0], y: box[1], width: box[2], height: box[3])) else { throw fail("Crop failed") }
                let request = VNGenerateImageFeaturePrintRequest()
                request.revision = VNGenerateImageFeaturePrintRequestRevision2
                request.imageCropAndScaleOption = .scaleFit
                try VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
                guard let result = request.results?.first, result.elementType == .float,
                      result.elementCount == 768, result.data.count == 3072 else { throw fail("Encoder contract changed") }
                featureBytes.append(result.data)
            }
            encodeSeconds += Date().timeIntervalSince(before)
            frames.append(["frame_id": frameID, "source_time_s": pts, "requested_time_s": requested,
                           "path": path, "sha256": digest(try Data(contentsOf: fileURL))])
        }
        let featurePath = "features/\(id).f32"
        try featureBytes.write(to: output.appendingPathComponent(featurePath), options: .withoutOverwriting)
        cases.append(["event_id": id, "source_group_id": group, "recording_id": group,
                      "decision_time_s": decision, "input_interval_s": [decision - 2.1, decision],
                      "frames": frames, "teacher_frame_ids": [frames[0]["frame_id"]!, frames[2]["frame_id"]!, frames[4]["frame_id"]!],
                      "features_path": featurePath, "features_sha256": digest(featureBytes),
                      "encoding_seconds": encodeSeconds])
        print("\(id) t=\(decision): 5 masked causal frames + features, encode=\(String(format: "%.3f", encodeSeconds))s")
        fflush(stdout)
        decision += step
    }
    try json(["schema_version": "bootstrap-batch-v1", "purpose": "unreviewed_ai_bootstrap_not_validation",
              "created_at": ISO8601DateFormatter().string(from: Date()), "encoder": encoder,
              "source": ["filename": source.lastPathComponent, "sha256": sourceHash, "duration_s": duration,
                         "width": 1920, "height": 1080, "platform": "unknown", "camera": "requires_visual_check",
                         "provenance": "user_supplied_local_file"],
              "action_labels_enabled": false, "audio_included": false,
              "elapsed_seconds": Date().timeIntervalSince(overallStart), "cases": cases],
             to: output.appendingPathComponent("manifest.json"))
    print("READY \(output.path)")
}
do { try await run() }
catch {
    FileHandle.standardError.write(Data("FAILED: \(error.localizedDescription)\nPartial output is not a ready batch. Retry in a NEW directory.\n".utf8))
    exit(1)
}
