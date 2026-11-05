import AVFoundation
import CoreGraphics
import Foundation

/// Writes raw BGRA frames with the tracked road lines drawn on, for piping into
/// ffmpeg. Left half of the drawing logic mirrors RoadLineOverlay.
/// Usage: road-overlay-video VIDEO START SECONDS [raw] | ffmpeg -f rawvideo -pix_fmt bgra -s 1920x1080 -r 60 -i - out.mp4
@main struct RoadOverlayVideo {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let asset = AVURLAsset(url: URL(fileURLWithPath: args[0]))
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: Double(args[1])!, preferredTimescale: 600),
                                       duration: CMTime(seconds: Double(args[2])!, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); precondition(reader.startReading())
        let rawMode = args.count > 3 && args[3] == "raw"
        var tracker = RoadLineTracker()
        let detector = RoadLineDetector()
        let animator = RoadOverlayAnimator()
        let stdout = FileHandle.standardOutput
        while let sample = output.copyNextSampleBuffer(), let pixels = CMSampleBufferGetImageBuffer(sample) {
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let road = rawMode ? detector.analyze(pixels, at: time, camera: .chase)
                : tracker.update(pixels, at: time, camera: .chase).display
            CVPixelBufferLockBaseAddress(pixels, [])
            let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels), row = CVPixelBufferGetBytesPerRow(pixels)
            let base = CVPixelBufferGetBaseAddress(pixels)!
            let context = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: row,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            context.translateBy(x: 0, y: CGFloat(h)); context.scaleBy(x: 1, y: -1)
            func point(_ p: RoadPoint) -> CGPoint { CGPoint(x: p.x * Double(w), y: p.y * Double(h)) }
            var drawn: RoadOverlayFrame
            if rawMode {
                drawn = RoadOverlayFrame()
                if road.hasCorridor { drawn.corridors = [.init(left: road.left, right: road.right, opacity: 1)] }
                drawn.strokes = (road.markings ?? []).map { .init(points: $0.points, color: $0.color, opacity: 1, isBoundary: false) }
                    + [road.left, road.right].filter { $0.count >= 2 }.map { .init(points: $0, color: .white, opacity: 1, isBoundary: true) }
            } else {
                var shown = road; shown.availableAt = time
                drawn = animator.frame(for: shown, at: time)
            }
            for corridor in drawn.corridors {
                context.addLines(between: corridor.left.map(point) + corridor.right.reversed().map(point)); context.closePath()
                context.setFillColor(CGColor(red: 0, green: 0.9, blue: 1, alpha: 0.18 * corridor.opacity)); context.fillPath()
            }
            context.setLineCap(.round); context.setLineJoin(.round)
            for stroke in drawn.strokes {
                let base = stroke.color == .yellow ? (1.0, 0.84, 0.25) : (1.0, 1.0, 1.0)
                if stroke.isBoundary {
                    context.setStrokeColor(CGColor(gray: 0, alpha: 0.6 * stroke.opacity)); context.setLineWidth(10)
                    context.addLines(between: stroke.points.map(point)); context.strokePath()
                    context.setStrokeColor(CGColor(red: base.0, green: base.1, blue: base.2, alpha: stroke.opacity)); context.setLineWidth(5)
                } else {
                    context.setStrokeColor(CGColor(red: base.0, green: base.1, blue: base.2, alpha: 0.45 * stroke.opacity)); context.setLineWidth(3)
                }
                context.addLines(between: stroke.points.map(point)); context.strokePath()
            }
            for y in 0..<h { stdout.write(Data(bytes: base + y * row, count: w * 4)) }
            CVPixelBufferUnlockBaseAddress(pixels, [])
        }
    }
}
