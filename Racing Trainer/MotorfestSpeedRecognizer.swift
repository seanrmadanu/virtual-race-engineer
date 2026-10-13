import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Raw OCR only. A successful observation is not a reviewed training label.
nonisolated struct SpeedOCRResult: Sendable {
    let speed: Int?
    /// Legacy live HUD configuration, not a unit recognized from the image.
    let unit: String?
    let confidence: Float
    let rawText: String
}

/// The same fixed Motorfest HUD crop and candidate ranking used by live capture.
/// Offline callers must validate layout and explicitly supply the source unit.
/// There is deliberately no temporal smoothing or carry-forward in this layer.
nonisolated enum MotorfestSpeedRecognizer {
    private static let speedOCREdgeTolerance: CGFloat = 0.01
    private static let maximumReasonableSpeed = 650

    static func recognize(in pixelBuffer: CVPixelBuffer, region: CGRect = MotorfestHUDLayout.speedOCR.normalizedRect,
                          rejectEdgePixels: Bool = false) -> SpeedOCRResult {
        if rejectEdgePixels && cropCutsBrightPixels(pixelBuffer, region: region) {
            return unknown(rawText: "crop_edge_pixels")
        }
        return recognize(using: VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]), region: region)
    }

    /// Vision can omit a partial digit from its text box. Check actual crop-edge pixels too.
    /// This conservative profile check can reject glare; it must never fill in a missing digit.
    static func cropCutsBrightPixels(_ buffer: CVPixelBuffer, region: CGRect) -> Bool {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              region.minX >= 0, region.minY >= 0, region.maxX <= 1, region.maxY <= 1,
              region.width > 0, region.height > 0 else { return true }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return true }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let left = Int(region.minX * Double(width)), right = min(width - 1, Int(region.maxX * Double(width)) - 1)
        let top = Int(region.minY * Double(height)), bottom = min(height, Int(region.maxY * Double(height)))
        var bright = 0
        for y in top..<bottom {
            for x in [left, min(right, left + 1), max(left, right - 1), right] {
                let offset = y * stride + x * 4
                let channels = [Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2])]
                if channels.min()! >= 190 && channels.max()! - channels.min()! <= 45 { bright += 1 }
            }
        }
        return bright >= 2
    }

    static func recognize(in image: CGImage) -> SpeedOCRResult {
        recognize(using: VNImageRequestHandler(cgImage: image, options: [:]), region: MotorfestHUDLayout.speedOCR.normalizedRect)
    }

    private static func recognize(using handler: VNImageRequestHandler, region: CGRect) -> SpeedOCRResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.minimumTextHeight = 0.025
        request.usesLanguageCorrection = false
        request.regionOfInterest = visionRegion(
            fromTopLeftRegion: region
        )

        do {
            try handler.perform([request])
        } catch {
            return unknown()
        }

        guard let observations = request.results, !observations.isEmpty else {
            return unknown()
        }

        var displayedNumericFragments: [String] = []
        var speedCandidates: [SpeedCandidate] = []

        for observation in observations {
            let topCandidates = observation.topCandidates(3)
            // A digit cut off at the crop edge can turn 114 into 14.
            let isClippedHorizontally =
                observation.boundingBox.minX < speedOCREdgeTolerance ||
                observation.boundingBox.maxX > 1 - speedOCREdgeTolerance
            if isClippedHorizontally { continue }

            if let primaryCandidate = topCandidates.first {
                let normalizedPrimary = normalizedNumericOCRText(primaryCandidate.string)
                if !normalizedPrimary.isEmpty {
                    displayedNumericFragments.append(normalizedPrimary)
                }
            }

            for recognizedText in topCandidates {
                let normalizedText = normalizedNumericOCRText(recognizedText.string)
                guard !normalizedText.isEmpty,
                      normalizedText.count <= 3,
                      let value = Int(normalizedText),
                      value >= 0, value <= maximumReasonableSpeed else {
                    continue
                }

                let score = speedCandidateScore(
                    value: value,
                    confidence: recognizedText.confidence,
                    boundingBox: observation.boundingBox
                )
                speedCandidates.append(SpeedCandidate(
                    value: value, confidence: recognizedText.confidence, score: score
                ))
            }
        }

        let numericDebugText = displayedNumericFragments.joined(separator: " | ")
        guard let bestCandidate = speedCandidates.max(by: { $0.score < $1.score }) else {
            return unknown(rawText: numericDebugText)
        }
        return SpeedOCRResult(
            speed: bestCandidate.value,
            unit: MotorfestHUDLayout.speedUnit,
            confidence: bestCandidate.confidence,
            rawText: numericDebugText
        )
    }

    private static func unknown(rawText: String = "") -> SpeedOCRResult {
        SpeedOCRResult(
            speed: nil, unit: MotorfestHUDLayout.speedUnit,
            confidence: 0, rawText: rawText
        )
    }

    private static func normalizedNumericOCRText(_ text: String) -> String {
        var result = ""
        for character in text {
            if character.isNumber {
                result.append(character)
                continue
            }
            switch character {
            case "O", "o", "Q": result.append("0")
            case "I", "i", "l", "|": result.append("1")
            case "Z", "z": result.append("2")
            case "S", "s": result.append("5")
            case "B": result.append("8")
            default: break
            }
        }
        return result
    }

    private static func visionRegion(fromTopLeftRegion region: CGRect) -> CGRect {
        CGRect(x: region.minX, y: 1.0 - region.maxY, width: region.width, height: region.height)
    }

    private static func speedCandidateScore(
        value: Int, confidence: VNConfidence, boundingBox: CGRect
    ) -> Double {
        var score = Double(confidence) * 2.0
        score += Double(String(value).count) * 0.18
        score += Double(boundingBox.width * boundingBox.height) * 80.0
        if value < 10 { score -= 0.12 }
        return score
    }

    private struct SpeedCandidate {
        let value: Int
        let confidence: Float
        let score: Double
    }
}
