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

    static func recognize(in pixelBuffer: CVPixelBuffer) -> SpeedOCRResult {
        recognize(using: VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]))
    }

    static func recognize(in image: CGImage) -> SpeedOCRResult {
        recognize(using: VNImageRequestHandler(cgImage: image, options: [:]))
    }

    private static func recognize(using handler: VNImageRequestHandler) -> SpeedOCRResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.minimumTextHeight = 0.025
        request.usesLanguageCorrection = false
        request.regionOfInterest = visionRegion(
            fromTopLeftRegion: MotorfestHUDLayout.speedOCR.normalizedRect
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
