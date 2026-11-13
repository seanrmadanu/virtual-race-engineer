import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Reads all the text on one game frame with Apple Vision. Used only by the
/// setup checklist, a few times a second at most and never on the analyzer's
/// queues. Its output is not guidance evidence.
nonisolated enum SetupScreenReader {
    static func lines(in pixelBuffer: CVPixelBuffer) -> [ScreenTextLine] {
        lines(using: VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]))
    }

    static func lines(in image: CGImage) -> [ScreenTextLine] {
        lines(using: VNImageRequestHandler(cgImage: image, options: [:]))
    }

    private static func lines(using handler: VNImageRequestHandler) -> [ScreenTextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.012
        guard (try? handler.perform([request])) != nil, let results = request.results else { return [] }
        return results.compactMap { observation in
            guard let best = observation.topCandidates(1).first, best.confidence >= 0.3 else { return nil }
            // Vision's origin is bottom left; the checklist uses top left.
            let box = observation.boundingBox
            return ScreenTextLine(text: best.string, x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        }
    }
}
