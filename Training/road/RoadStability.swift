import AVFoundation
import Foundation

/// Runs the detector on every frame of a clip and reports how steady the lane
/// boundaries are: how often they drop out and how much they jump per frame.
/// Usage: road-stability VIDEO START SECONDS
@main struct RoadStability {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3, let start = Double(args[1]), let seconds = Double(args[2]) else {
            print("Usage: road-stability VIDEO START SECONDS"); exit(2)
        }
        let asset = AVURLAsset(url: URL(fileURLWithPath: args[0]))
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000),
                                       duration: CMTime(seconds: seconds, preferredTimescale: 60000))
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); precondition(reader.startReading())
        let detector = RoadLineDetector()
        var tracker = RoadLineTracker()
        var observations: [RoadLineObservation] = [], tracked: [RoadLineObservation] = [], shown: [RoadLineObservation] = []
        var total = 0.0, trackedTotal = 0.0
        let animator = RoadOverlayAnimator()
        var drawn: [RoadOverlayFrame] = []
        while let sample = output.copyNextSampleBuffer(), let pixels = CMSampleBufferGetImageBuffer(sample) {
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let began = Date()
            observations.append(detector.analyze(pixels, at: time, camera: .chase))
            total += Date().timeIntervalSince(began)
            let trackBegan = Date()
            let result = tracker.update(pixels, at: time, camera: .chase)
            trackedTotal += Date().timeIntervalSince(trackBegan)
            tracked.append(result.observation); shown.append(result.display)
            var display = result.display
            display.availableAt = time
            drawn.append(animator.frame(for: display, at: time))
        }
        let n = Double(observations.count)
        if ProcessInfo.processInfo.environment["ROAD_RAW"] != nil {
            print("  raw     " + RoadStabilityReport(observations).summary + String(format: " | %.2f ms/frame", total / n * 1000))
        }
        print("  display " + RoadStabilityReport(shown).summary + String(format: " | %.2f ms/frame", trackedTotal / n * 1000))
        print("  drawn   " + DrawnReport(drawn).summary)
    }
}

/// x of a boundary at row y, if the boundary covers that row.
func boundaryX(_ edge: [RoadPoint], at y: Double) -> Double? {
    for (a, b) in zip(edge, edge.dropFirst()) where a.y <= y && b.y >= y && b.y > a.y {
        return a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x)
    }
    return nil
}

struct RoadStabilityReport {
    let summary: String
    init(_ observations: [RoadLineObservation]) {
        var present = [0, 0], flips = [0, 0], corridorFlips = 0
        var jumps: [[Double]] = [[], []], ends: [[Double]] = [[], []]
        var previousCorridor: Bool?
        for o in observations {
            if let previousCorridor, previousCorridor != o.hasCorridor { corridorFlips += 1 }
            previousCorridor = o.hasCorridor
        }
        for side in 0..<2 {
            var previous: [RoadPoint]? = nil
            for o in observations {
                let edge = side == 0 ? o.left : o.right
                let has = edge.count >= 6
                if has { present[side] += 1 }
                if let previous {
                    if (previous.count >= 6) != has { flips[side] += 1 }
                    if previous.count >= 6 && has {
                        // Movement where the line is drawn, at its middle and both ends.
                        let rows = [0.25, 0.5, 0.75].map { edge[0].y + (edge[edge.count - 1].y - edge[0].y) * $0 }
                        for y in rows {
                            if let a = boundaryX(previous, at: y), let b = boundaryX(edge, at: y) { jumps[side].append(abs(b - a) * 1920) }
                        }
                        ends[side].append(abs(edge[0].y - previous[0].y) * 1080)
                        ends[side].append(abs(edge[edge.count - 1].y - previous[previous.count - 1].y) * 1080)
                    }
                }
                previous = has ? edge : []
            }
        }
        func median(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.sorted()[v.count / 2] }
        func p95(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.sorted()[min(v.count - 1, Int(Double(v.count) * 0.95))] }
        let n = observations.count
        let corridor = observations.filter(\.hasCorridor).count
        let markingsPerFrame = Double(observations.reduce(0) { $0 + ($1.markings?.count ?? 0) }) / Double(max(1, n))
        summary = String(format: "lines/frame %.1f | lane fill %.0f%% (%d blinks) | left %.0f%% (%d blinks) right %.0f%% (%d blinks) | sideways px med/p95 L %.1f/%.1f R %.1f/%.1f | ends px med/p95 L %.1f/%.1f R %.1f/%.1f",
            markingsPerFrame, Double(corridor) / Double(n) * 100, corridorFlips,
            Double(present[0]) / Double(n) * 100, flips[0], Double(present[1]) / Double(n) * 100, flips[1],
            median(jumps[0]), p95(jumps[0]), median(jumps[1]), p95(jumps[1]),
            median(ends[0]), p95(ends[0]), median(ends[1]), p95(ends[1]))
    }
}

/// What reaches the screen after the animator: how often the lane fill or the
/// boundary lines visibly come and go (opacity crossing 50%), and the largest
/// single-frame opacity change (a pop would be close to 1).
struct DrawnReport {
    let summary: String
    init(_ frames: [RoadOverlayFrame]) {
        func crossings(_ values: [Double]) -> Int {
            zip(values, values.dropFirst()).filter { ($0 >= 0.5) != ($1 >= 0.5) }.count
        }
        func changes(_ values: [Double]) -> Int { zip(values, values.dropFirst()).filter { $0 != $1 }.count }
        let fill = frames.map { min(1, $0.corridors.reduce(0) { $0 + $1.opacity }) }
        // Visible boundary lines per frame (0, 1 or 2); a change is a line coming or going.
        let lines = frames.map { Double($0.strokes.filter { $0.isBoundary && $0.opacity >= 0.5 }.count) }
        var biggest = 0.0
        for (a, b) in zip(frames, frames.dropFirst()) {
            let fa = a.corridors.reduce(0) { $0 + $1.opacity }, fb = b.corridors.reduce(0) { $0 + $1.opacity }
            biggest = max(biggest, abs(fb - fa))
        }
        summary = String(format: "lane fill shown %.0f%% (%d fades) | boundaries shown %.0f%% (%d fades) | biggest 1-frame fill change %.2f",
            fill.reduce(0, +) / Double(max(1, frames.count)) * 100, crossings(fill),
            lines.reduce(0, +) / Double(max(1, frames.count)) / 2 * 100, changes(lines), biggest)
    }
}
