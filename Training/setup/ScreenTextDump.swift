import AVFoundation
import Foundation

/// Prints every line of text the setup reader finds in one video frame or image,
/// with its position, and what the matcher makes of it. Usage: dump VIDEO SECONDS | dump IMAGE
@main
enum ScreenTextDump {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 2 else { fatalError("usage: dump VIDEO SECONDS | dump IMAGE.png") }
        let url = URL(fileURLWithPath: args[1])
        var lines: [ScreenTextLine] = []
        let start = ProcessInfo.processInfo.systemUptime
        if args.count >= 3, let seconds = Double(args[2]) {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { fatalError("no video track") }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings:
                [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: seconds, preferredTimescale: 600),
                                           duration: CMTime(seconds: 1, preferredTimescale: 600))
            reader.startReading()
            guard let sample = output.copyNextSampleBuffer(), let pixels = CMSampleBufferGetImageBuffer(sample) else {
                fatalError("no frame")
            }
            let decoded = ProcessInfo.processInfo.systemUptime
            lines = SetupScreenReader.lines(in: pixels)
            print(String(format: "read in %.0f ms", (ProcessInfo.processInfo.systemUptime - decoded) * 1000))
        } else {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("unreadable image") }
            lines = SetupScreenReader.lines(in: image)
            print(String(format: "read in %.0f ms", (ProcessInfo.processInfo.systemUptime - start) * 1000))
        }
        for line in lines.sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
            print(String(format: "x %.3f y %.3f w %.3f h %.3f  %@", line.x, line.y, line.width, line.height, line.text))
        }
        let found = SetupScreenMatcher.read(lines)
        print("matched:", found.isEmpty ? "nothing" : found.map { "\($0.key.rawValue)=\($0.value.value)" }.sorted().joined(separator: ", "))
    }
}
