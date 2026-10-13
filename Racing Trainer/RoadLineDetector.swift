import CoreGraphics
import CoreVideo
import Foundation

nonisolated enum RoadCameraMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case chase, cockpit
    var id: String { rawValue }
    var title: String { self == .chase ? "Chase Camera" : "Cockpit Camera" }
}

/// Coordinates are fractions of the full input frame, with a top-left origin.
nonisolated struct RoadPoint: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
}

nonisolated struct RoadLineObservation: Codable, Equatable, Sendable {
    let capturedAt: Double
    let left: [RoadPoint]
    let right: [RoadPoint]
    let confidence: Double
    let reason: String
    var availableAt: Double? = nil

    static func unavailable(at time: Double, reason: String) -> Self {
        Self(capturedAt: time, left: [], right: [], confidence: 0, reason: reason)
    }
    static let empty = unavailable(at: 0, reason: "Waiting for visible white road markings")
    var hasCorridor: Bool {
        left.count >= 6 && left.count == right.count && confidence >= 0.55
            && zip(left, right).allSatisfy { abs($0.y - $1.y) < 0.00001 && $0.x < $1.x }
    }
    var hasBoundary: Bool { max(left.count, right.count) >= 6 && confidence >= 0.55 }
    func isFresh(at time: Double) -> Bool {
        time.isFinite && capturedAt.isFinite && time >= (availableAt ?? capturedAt) && time - capturedAt <= 0.65
    }
    var roadDirection: String {
        guard hasCorridor, let l0 = left.first, let r0 = right.first,
              let ln = left.last, let rn = right.last else { return "unknown" }
        // Image-space bend indication only; not vehicle yaw or steering input.
        let shift = (l0.x + r0.x - ln.x - rn.x) / 2
        return abs(shift) < 0.035 ? "straight" : (shift < 0 ? "left" : "right")
    }
}

/// Finds narrow, locally contrasting white-paint ridges in the road region.
/// Two independently supported boundaries are required for a filled corridor.
/// No minimap, wheel, pedal, inferred map scale or future frame is used.
nonisolated struct RoadLineDetector {
    func analyze(_ buffer: CVPixelBuffer, at time: Double, camera: RoadCameraMode) -> RoadLineObservation {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
            return .unavailable(at: time, reason: "Unsupported road image format")
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            return .unavailable(at: time, reason: "Road pixels unavailable")
        }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width >= 160, height >= 90, abs(Double(width) / Double(height) - 16 / 9.0) < 0.03 else {
            return .unavailable(at: time, reason: "Road detection needs uncropped 16:9 footage")
        }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let step = max(1, width / 640), rowStep = max(2, height / 180)
        let startY = Int(Double(height) * (camera == .chase ? 0.39 : 0.36))
        let endY = Int(Double(height) * (camera == .chase ? 0.80 : 0.60))
        func luminance(_ x: Int, _ y: Int) -> Double {
            let i = y * stride + x * 4
            return 0.2126 * Double(bytes[i + 2]) + 0.7152 * Double(bytes[i + 1]) + 0.0722 * Double(bytes[i])
        }
        var points: [RoadPoint] = []
        for y in Swift.stride(from: startY, to: endY, by: rowStep) {
            var lastX = -100
            for x in Swift.stride(from: width / 12, to: width * 11 / 12, by: step) {
                let nx = Double(x) / Double(width), ny = Double(y) / Double(height)
                // Exclude the physical-wheel inset, HUD corners, and chase car.
                if nx < 0.32 && ny < 0.34 { continue }
                if ny > 0.60 && (nx < 0.245 || nx > 0.77) { continue }
                if camera == .chase && ny > 0.47 && (0.34...0.66).contains(nx) { continue }
                if x - lastX < step * 3 { continue }
                let i = y * stride + x * 4
                let b = Double(bytes[i]), g = Double(bytes[i + 1]), r = Double(bytes[i + 2])
                let high = max(r, g, b), low = min(r, g, b)
                guard low >= 115, high - low < 45, r - b < 40, g - b < 32 else { continue }
                let center = luminance(x, y)
                let flank = max(luminance(x - step * 7, y), luminance(x + step * 7, y))
                guard center >= 150, center - flank >= 18 else { continue }
                points.append(RoadPoint(x: nx, y: ny)); lastX = x
            }
        }
        guard points.count <= 4000 else {
            return .unavailable(at: time, reason: "Too many bright edges to isolate road paint")
        }
        let result = estimate(points: points, at: time)
        // Fitted curves must obey the same car exclusion as their support pixels.
        if camera == .chase && (result.left + result.right).contains(where: { $0.y > 0.47 && (0.34...0.66).contains($0.x) }) {
            func visiblePart(_ edge: [RoadPoint]) -> [RoadPoint] {
                var segments: [[RoadPoint]] = [[]]
                for point in edge {
                    if point.y > 0.47 && (0.34...0.66).contains(point.x) { segments.append([]) }
                    else { segments[segments.count-1].append(point) }
                }
                let longest = segments.max(by: { $0.count < $1.count }) ?? []
                return longest.count >= 6 ? longest : []
            }
            let left = visiblePart(result.left), right = visiblePart(result.right)
            guard !left.isEmpty || !right.isEmpty else {
                return .unavailable(at: time, reason: "White marking is obscured by the car")
            }
            return RoadLineObservation(capturedAt: time, left: left, right: right,
                confidence: result.confidence, reason: "Partial white-line candidates · car occludes the road")
        }
        return result
    }

    /// Pure geometry stage also used by synthetic regression checks.
    func estimate(points: [RoadPoint], at time: Double) -> RoadLineObservation {
        let finite = points.filter { $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0.34...0.82).contains($0.y) }
        guard finite.count >= 20 else {
            return .unavailable(at: time, reason: "White road markings are not sufficiently visible")
        }
        let left = fit(finite, side: -1), right = fit(finite, side: 1)
        guard let left, let right else {
            // A single supported marking is useful to inspect, but cannot
            // define a filled corridor or authorize a straight-road cue.
            guard let fit = left ?? right else {
                return .unavailable(at: time, reason: "White road markings are not established")
            }
            let edge = (0..<16).map { index -> RoadPoint in
                let y = fit.minY + Double(index) / 15 * (fit.maxY - fit.minY)
                return RoadPoint(x: fit.x(y), y: y)
            }
            guard edge.allSatisfy({ (0.04...0.96).contains($0.x) }) else {
                return .unavailable(at: time, reason: "White marking extends outside the road region")
            }
            return RoadLineObservation(capturedAt: time, left: left == nil ? [] : edge,
                right: right == nil ? [] : edge, confidence: min(0.75, 0.45 + fit.maxY - fit.minY),
                reason: "One white-line candidate · road width unresolved")
        }
        let start = max(left.minY, right.minY), end = min(left.maxY, right.maxY)
        guard end - start >= 0.09 else {
            return .unavailable(at: time, reason: "Road boundaries do not overlap enough")
        }
        var l: [RoadPoint] = [], r: [RoadPoint] = []
        for index in 0..<16 {
            let y = start + Double(index) / 15 * (end - start)
            let lx = left.x(y), rx = right.x(y)
            // Paint converges at the horizon. Start the overlay only where
            // its two independently detected edges are visibly separated.
            if l.isEmpty, rx > lx, rx - lx < 0.035 { continue }
            guard lx >= 0.04, rx <= 0.96, rx - lx >= 0.035, rx - lx <= 0.88 else {
                return .unavailable(at: time, reason: "Road edges cross or have implausible width")
            }
            l.append(RoadPoint(x: lx, y: y)); r.append(RoadPoint(x: rx, y: y))
        }
        guard l.count >= 6 else {
            return .unavailable(at: time, reason: "Road bounds are too distant to separate")
        }
        let nearWidth = r.last!.x - l.last!.x, farWidth = r[0].x - l[0].x
        guard nearWidth > farWidth * 1.15, l.last!.x < 0.54, r.last!.x > 0.46 else {
            return .unavailable(at: time, reason: "White edges do not form a forward road corridor")
        }
        let confidence = min(0.90, 0.45 + min(end - start, 0.25) + min(Double(min(left.bins, right.bins)) / 100, 0.20))
        return RoadLineObservation(capturedAt: time, left: l, right: r, confidence: confidence,
                                   reason: "Visible white-line bounds · experimental, not a racing line")
    }

    private struct Fit {
        let coefficients: [Double]
        let minY: Double
        let maxY: Double
        let bins: Int
        func x(_ y: Double) -> Double { coefficients[0] + coefficients[1] * y + coefficients[2] * y * y }
    }

    private func fit(_ points: [RoadPoint], side: Double) -> Fit? {
        var best: [RoadPoint] = [], bestScore = 0.0
        for i in 0..<240 {
            let a = points[(i * 37 + 7) % points.count], b = points[(i * 91 + 29) % points.count]
            guard abs(b.y - a.y) >= 0.075 else { continue }
            let slope = (b.x - a.x) / (b.y - a.y), intercept = a.x - slope * a.y
            guard slope * side > 0.20, abs(slope) < 3.5 else { continue }
            let near = intercept + slope * 0.70, horizon = intercept + slope * 0.39
            guard (0.34...0.72).contains(horizon), side < 0 ? near < 0.49 : near > 0.51 else { continue }
            let inliers = points.filter { abs($0.x - (intercept + slope * $0.y)) <= 0.014 }
            let bins = Set(inliers.map { Int($0.y * 180) }).count
            let span = (inliers.map(\.y).max() ?? 0) - (inliers.map(\.y).min() ?? 0)
            let score = Double(bins) * min(span, 0.3)
            if bins >= 10, span >= 0.10, score > bestScore { best = inliers; bestScore = score }
        }
        guard !best.isEmpty else { return nil }
        // One median observation per image row prevents a bright patch dominating the fit.
        let grouped = Dictionary(grouping: best, by: { Int($0.y * 180) })
        let medians = grouped.values.map { group -> RoadPoint in
            let sorted = group.sorted { $0.x < $1.x }; return sorted[sorted.count / 2]
        }.sorted { $0.y < $1.y }
        guard let first = medians.first, let last = medians.last else { return nil }
        // Require continuing paint support, including dashed lines with bounded gaps.
        guard zip(medians, medians.dropFirst()).allSatisfy({ $1.y - $0.y <= 0.075 }) else { return nil }
        var matrix = Array(repeating: Array(repeating: 0.0, count: 4), count: 3)
        for p in medians {
            let powers = [1, p.y, p.y * p.y, pow(p.y, 3), pow(p.y, 4)]
            for row in 0..<3 {
                for column in 0..<3 { matrix[row][column] += powers[row + column] }
                matrix[row][3] += powers[row] * p.x
            }
        }
        for col in 0..<3 {
            let pivot = (col..<3).max { abs(matrix[$0][col]) < abs(matrix[$1][col]) }!
            matrix.swapAt(col, pivot)
            let divisor = matrix[col][col]
            guard abs(divisor) > 1e-9 else { return nil }
            for j in col..<4 { matrix[col][j] /= divisor }
            for row in 0..<3 where row != col {
                let scale = matrix[row][col]
                for j in col..<4 { matrix[row][j] -= scale * matrix[col][j] }
            }
        }
        let coefficients = matrix.map { $0[3] }
        guard coefficients.allSatisfy(\.isFinite), abs(coefficients[2]) < 8 else { return nil }
        return Fit(coefficients: coefficients, minY: first.y, maxY: last.y, bins: medians.count)
    }
}
