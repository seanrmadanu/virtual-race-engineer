import CoreImage
import CoreVideo
import Foundation

/// Local regression fixture is a frame extracted from the user's development video.
nonisolated func runNativeModuleChecks(imageURL: URL) throws {
    let image = CIImage(contentsOf: imageURL)!
    var optional: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, Int(image.extent.width), Int(image.extent.height),
                       kCVPixelFormatType_32BGRA, nil, &optional)
    let buffer = optional!
    CIContext().render(image, to: buffer)
    let old = MotorfestSpeedRecognizer.recognize(in: buffer)
    let new = MotorfestSpeedRecognizer.recognize(in: buffer,
        region: CGRect(x: 0.075, y: 0.854, width: 0.070, height: 0.073), rejectEdgePixels: true)
    precondition(new.speed == 151, "Known 01:45 Video 2 speed must read 151, not 15: \(new)")
    print("PASS speed fixture: legacy \(old.speed.map(String.init) ?? "missing") -> explicit profile 151")
    // A deliberately cut crop must abstain, not drop a digit.
    let clipped = MotorfestSpeedRecognizer.recognize(in: buffer,
        region: CGRect(x: 0.085, y: 0.854, width: 0.060, height: 0.073), rejectEdgePixels: true)
    precondition(clipped.speed == nil, "Clipped white digit must be rejected")
    print("PASS clipped digit rejection")
    for sign in [-1, 1] {
        var mask = [UInt8](repeating: 0, count: 128 * 128)
        func dot(_ x: Int, _ y: Int) {
            for dx in -2...2 { for dy in -2...2 {
                if (0..<128).contains(x + dx) && (0..<128).contains(y + dy) { mask[(y+dy)*128+x+dx] = 1 }
            } }
        }
        for y in 65...110 { dot(64, y) }
        for index in 0...45 { dot(64 + sign * index, 65 - index) }
        let result = MinimapGeometryAnalyzer().analyze(mask: MinimapRouteMask(width: 128, height: 128, pixels: Data(mask)),
            playerAnchor: MinimapPoint(x: 64.0/127, y: 110.0/127), previousPath: [])
        precondition(result.isValid && result.direction == (sign == 1 ? .right : .left), "Direction fixture failed: \(result.reason), \(result.direction)")
    }
    print("PASS left and right geometry fixtures")
    let modules = ModularVideoModules(profileID: "reference-video2-v1")
    for time in [100.0, 100.5, 101.0] {
        let observations = modules.analyze(pixelBuffer: buffer, capturedAt: time, startedAt: time, session: 1, confirmedSpeedUnit: "km/h")
        if time == 101 { precondition(observations["validity"]?.failureReason == "stalled_video") }
    }
    print("PASS stalled frame rejection")
    let restored = modules.analyze(pixelBuffer: buffer, capturedAt: 1, startedAt: 1, session: 2, confirmedSpeedUnit: "km/h")
    precondition(restored["validity"]?.failureReason != "stalled_video")
    print("PASS source reset clears stall history")
    modules.reset()
    for index in 0..<10 {
        CVPixelBufferLockBaseAddress(buffer, [])
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<(CVPixelBufferGetHeight(buffer) / 3) {
            memset(CVPixelBufferGetBaseAddress(buffer)!.advanced(by: y * stride), Int32(index * 20), CVPixelBufferGetWidth(buffer) / 3 * 4)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let time = 200 + Double(index) / 10
        let values = modules.analyze(pixelBuffer: buffer, capturedAt: time, startedAt: time, session: 3, confirmedSpeedUnit: "km/h")
        if index == 9 { precondition(values["validity"]?.failureReason == "stalled_video") }
    }
    print("PASS moving inset does not hide frozen gameplay")
    CVPixelBufferLockBaseAddress(buffer, [])
    memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let blank = modules.analyze(pixelBuffer: buffer, capturedAt: 1.1, startedAt: 1.1, session: 2, confirmedSpeedUnit: "km/h")
    precondition(blank["geometry"]?.value == nil && blank["validity"]?.value?.flag == false)
    print("PASS missing HUD and waypoint reject geometry")
}
