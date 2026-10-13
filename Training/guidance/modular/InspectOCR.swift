import Foundation
import Vision

@main enum InspectOCR {
    static func main() throws {
        for rect in [CGRect(x: 0.052, y: 0.073, width: 0.076, height: 0.073),
                     CGRect(x: 0.075, y: 0.073, width: 0.070, height: 0.073)] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast; request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.025; request.regionOfInterest = rect
            try VNImageRequestHandler(url: URL(fileURLWithPath: CommandLine.arguments[1])).perform([request])
            print("ROI", rect)
            for item in request.results ?? [] { print(item.boundingBox, item.topCandidates(3).map { ($0.string, $0.confidence) }) }
        }
    }
}
