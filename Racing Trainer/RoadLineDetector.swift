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

nonisolated enum RoadMarkingColor: String, Codable, Sendable {
    case white, yellow
}

/// One painted line fitted from current-frame pixels, sampled over the rows
/// where it had support. Not a lane assignment by itself.
nonisolated struct RoadMarking: Codable, Equatable, Sendable {
    let color: RoadMarkingColor
    let points: [RoadPoint]
}

nonisolated struct RoadLineObservation: Codable, Equatable, Sendable {
    let capturedAt: Double
    /// Nearest supported marking left of the car (the lane's left boundary).
    let left: [RoadPoint]
    /// Nearest supported marking right of the car (the lane's right boundary).
    let right: [RoadPoint]
    let confidence: Double
    let reason: String
    var availableAt: Double? = nil
    /// Every marking found in this frame, including ones beyond the lane.
    /// Optional so older review bundles still decode.
    var markings: [RoadMarking]? = nil

    static func unavailable(at time: Double, reason: String) -> Self {
        Self(capturedAt: time, left: [], right: [], confidence: 0, reason: reason)
    }
    static let empty = unavailable(at: 0, reason: "Waiting for visible road markings")
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

    /// Lane centre x at `y`, interpolated between paired samples.
    func corridorCenter(at y: Double) -> Double? {
        guard hasCorridor else { return nil }
        for i in 1..<left.count where left[i-1].y <= y && left[i].y >= y {
            let span = left[i].y - left[i-1].y
            guard span > 0 else { return nil }
            let fraction = (y - left[i-1].y) / span
            let a = (left[i-1].x + right[i-1].x) / 2
            let b = (left[i].x + right[i].x) / 2
            return a + fraction * (b - a)
        }
        return nil
    }

    /// Near-road curvature, rejecting a merely slanted straight perspective.
    /// Wide, paired paint support is required; a single line cannot confirm entry.
    var currentBendDirection: String {
        guard hasCorridor, let first = left.first, let last = left.last,
              first.y <= 0.50, last.y >= 0.70 else { return "unknown" }
        guard let far = corridorCenter(at: 0.50), let middle = corridorCenter(at: 0.60),
              let near = corridorCenter(at: 0.70) else { return "unknown" }
        let curvature = far - 2 * middle + near
        if abs(curvature) <= 0.004 { return "straight" }
        guard abs(curvature) >= 0.008 else { return "unknown" }
        return curvature < 0 ? "left" : "right"
    }

}

/// A pixel that looks like paint: brighter than the road on both sides at the
/// width a marking has at that distance, and white or yellow in colour.
nonisolated struct RoadPaintCandidate: Equatable, Sendable {
    let x: Double
    let y: Double
    let color: RoadMarkingColor
    let strength: Double
}

/// Finds painted lane markings (white edge lines and yellow centre lines) in
/// the road region of a single frame, fits each as a smooth curve, and pairs
/// the nearest marking on each side of the car as the lane boundaries.
/// No minimap, wheel, pedal, inferred map scale, earlier or future frame is used.
nonisolated struct RoadLineDetector {
    func analyze(_ buffer: CVPixelBuffer, at time: Double, camera: RoadCameraMode) -> RoadLineObservation {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
            return .unavailable(at: time, reason: "Unsupported road image format")
        }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width >= 160, height >= 90, abs(Double(width) / Double(height) - 16 / 9.0) < 0.03 else {
            return .unavailable(at: time, reason: "Road detection needs uncropped 16:9 footage")
        }
        guard let candidates = candidates(in: buffer, camera: camera) else {
            return .unavailable(at: time, reason: "Road pixels unavailable")
        }
        return estimate(candidates: candidates, at: time)
    }

    // MARK: Paint candidates

    /// Rows where the road is normally visible, as fractions of frame height.
    static func searchBand(_ camera: RoadCameraMode) -> ClosedRange<Double> {
        camera == .chase ? 0.41...0.86 : 0.38...0.60
    }

    /// The player's car and its shadow in the chase camera, in frame fractions.
    static let chaseCarRegion = CGRect(x: 0.315, y: 0.45, width: 0.37, height: 0.55)

    /// HUD, wheel inset and (chase camera) the player's car never contain road paint.
    static func isExcluded(x nx: Double, y ny: Double, camera: RoadCameraMode) -> Bool {
        if nx < 0.32 && ny < 0.34 { return true }                    // physical-wheel inset
        // Speedometer and minimap dials (circles on a 16:9 frame), with margin.
        func inDial(_ cx: Double, _ cy: Double) -> Bool {
            let dx = (nx - cx) * 16 / 9, dy = ny - cy
            return dx * dx + dy * dy < 0.170 * 0.170
        }
        if inDial(0.112, 0.815) || inDial(0.894, 0.800) { return true }
        if ny > 0.58 && nx > 0.84 { return true }                   // distance label above the minimap
        if camera == .chase && chaseCarRegion.contains(CGPoint(x: nx, y: ny)) { return true }
        return false
    }

    /// The same regions as `isExcluded`, as x ranges for one row.
    static func excludedRanges(y ny: Double, camera: RoadCameraMode) -> [ClosedRange<Double>] {
        var ranges: [ClosedRange<Double>] = []
        if ny < 0.34 { ranges.append(0...0.32) }
        for (cx, cy) in [(0.112, 0.815), (0.894, 0.800)] {
            let dy = ny - cy, radius = 0.170
            guard abs(dy) < radius else { continue }
            let half = (radius * radius - dy * dy).squareRoot() * 9 / 16
            ranges.append((cx - half)...(cx + half))
        }
        if ny > 0.58 { ranges.append(0.84...1) }
        let car = chaseCarRegion
        if camera == .chase && ny >= car.minY && ny <= car.maxY { ranges.append(car.minX...car.maxX) }
        return ranges
    }

    func candidates(in buffer: CVPixelBuffer, camera: RoadCameraMode) -> [RoadPaintCandidate]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        // About 960 columns and 200 rows regardless of input size: paint stays
        // several samples wide, and every frame can be searched.
        let step = max(1, width / 960), rowStep = max(1, height / 200)
        let columns = width / step
        let band = Self.searchBand(camera)
        // Raw buffers keep the per-pixel loops fast in unoptimised builds too.
        let floats = UnsafeMutablePointer<Float>.allocate(capacity: columns * 6 + 2)
        let flags = UnsafeMutablePointer<Int32>.allocate(capacity: columns * 3)
        defer { floats.deallocate(); flags.deallocate() }
        let lum = floats, yel = floats + columns, sat = floats + 2 * columns
        let lumSum = floats + 3 * columns, yelSum = floats + 4 * columns + 1
        let response = floats + 5 * columns + 2
        let excluded = flags, kind = flags + columns, reach = flags + 2 * columns
        var result: [RoadPaintCandidate] = []
        result.reserveCapacity(1024)

        for y in Swift.stride(from: Int(band.lowerBound * Double(height)), to: Int(band.upperBound * Double(height)), by: rowStep) {
            let ny = Double(y) / Double(height)
            let row = bytes + y * rowBytes
            lumSum[0] = 0; yelSum[0] = 0
            for c in 0..<columns {
                let p = row + c * step * 4
                let b = Float(p[0]), g = Float(p[1]), r = Float(p[2])
                lum[c] = 0.2126 * r + 0.7152 * g + 0.0722 * b
                yel[c] = (r + g) / 2 - b
                sat[c] = max(r, g, b) - min(r, g, b)
                lumSum[c + 1] = lumSum[c] + lum[c]
                yelSum[c + 1] = yelSum[c] + yel[c]
                excluded[c] = 0
                response[c] = 0
            }
            for range in Self.excludedRanges(y: ny, camera: camera) {
                let first = max(0, Int((range.lowerBound * Double(columns) - 0.5).rounded(.up)))
                let last = min(columns - 1, Int((range.upperBound * Double(columns) - 0.5).rounded(.down)))
                if first <= last { for c in first...last { excluded[c] = 1 } }
            }
            // Expected paint width grows below the horizon; slanted lines cross
            // a row more widely, so several widths are tried.
            let paint = max(1.0, (ny - 0.395) * 0.030 * Double(columns))
            let gap = max(1, Int((paint * 0.5).rounded()))
            let flank = max(2, Int((paint * 1.2).rounded()))
            let flankScale = 1 / Float(flank)
            for scale in [1.0, 2.0, 3.5] {
                let half = max(1, Int((paint * scale / 2).rounded()))
                let centerScale = 1 / Float(2 * half + 1)
                let margin = half + gap + flank
                guard columns > 2 * margin + 1 else { continue }
                for c in margin..<(columns - margin) where excluded[c] == 0 {
                    let centerL = (lumSum[c + half + 1] - lumSum[c - half]) * centerScale
                    guard centerL >= 110 else { continue }
                    let l0 = c - margin, l1 = c - half - gap, r0 = c + half + gap + 1, r1 = r0 + flank
                    let leftL = (lumSum[l1] - lumSum[l0]) * flankScale
                    let rightL = (lumSum[r1] - lumSum[r0]) * flankScale
                    let leftY = (yelSum[l1] - yelSum[l0]) * flankScale
                    let rightY = (yelSum[r1] - yelSum[r0]) * flankScale
                    let leftRoad = Self.roadLike(lum: leftL, yel: leftY)
                    let rightRoad = Self.roadLike(lum: rightL, yel: rightY)
                    guard leftRoad || rightRoad else { continue }
                    let centerY = (yelSum[c + half + 1] - yelSum[c - half]) * centerScale
                    let lumContrast = centerL - max(leftL, rightL)
                    // Paint is compared with the asphalt beside it.
                    let roadY = leftRoad && rightRoad ? max(leftY, rightY) : (leftRoad ? leftY : rightY)
                    let yelContrast = centerY - roadY
                    var strength: Float = 0
                    var color: Int32 = 0
                    // Colour comes from the centre pixel itself; a wide window
                    // beside grass would otherwise make white paint look yellow.
                    if sat[c] < 48, yel[c] < 26, centerY < 30, lumContrast >= max(16, centerL * 0.09) {
                        strength = lumContrast
                    } else if yel[c] >= 18, sat[c] < 150, centerY >= 22, yelContrast >= 22,
                              lum[c] - min(leftL, rightL) >= 8 {
                        // The paint pixel itself must be brighter than its darker side;
                        // grass just outside a white line is not.
                        color = 1; strength = yelContrast + max(0, lumContrast)
                    }
                    if strength > response[c] { response[c] = strength; kind[c] = color; reach[c] = Int32(half * 2 + 1) }
                }
            }
            // Keep one candidate per painted stripe: strongest first.
            var found: [Int] = []
            for c in 0..<columns where response[c] > 0 { found.append(c) }
            found.sort { response[$0] > response[$1] }
            for c in found where response[c] > 0 {
                let r = Int(reach[c])
                result.append(RoadPaintCandidate(x: (Double(c) + 0.5) / Double(columns), y: ny,
                                                 color: kind[c] == 1 ? .yellow : .white, strength: Double(response[c])))
                for k in max(0, c - r)...min(columns - 1, c + r) { response[k] = 0 }
            }
        }
        return result
    }

    /// Asphalt is grey to warm grey; grass and foliage are strongly yellow-green,
    /// and sky is strongly blue (bright sky beside a palm trunk is not road).
    private static func roadLike(lum: Float, yel: Float) -> Bool {
        (55...205).contains(lum) && yel < 26 && yel > -30
    }

    // MARK: Fitting

    /// Quadratic in y, centred at y = 0.6 for conditioning.
    struct Curve: Equatable {
        let a: Double, b: Double, c: Double
        let minY: Double, maxY: Double
        let rows: Int
        let color: RoadMarkingColor
        func x(_ y: Double) -> Double { let t = y - 0.6; return a + b * t + c * t * t }
        func slope(_ y: Double) -> Double { b + 2 * c * (y - 0.6) }
    }

    private static func tolerance(_ y: Double) -> Double { 0.004 + max(0, y - 0.40) * 0.022 }
    private static func rowBin(_ y: Double) -> Int { Int((y * 200).rounded()) }

    /// Sequential RANSAC: repeatedly take the best-supported curve and remove its
    /// pixels. Hypotheses come from two nearby paint pixels, refined to a
    /// quadratic. Deterministic sampling keeps results reproducible.
    /// `priors` (usually last frame's lines) are tried as hypotheses in every
    /// round before random ones, so a line seen a moment ago is found again
    /// whenever this frame's paint still supports it.
    func fitMarkings(_ points: [RoadPaintCandidate], priors: [Curve] = []) -> [Curve] {
        let sorted = points.sorted { $0.y < $1.y }
        let n = sorted.count
        guard n >= 8 else { return [] }
        let xs = sorted.map(\.x), ys = sorted.map(\.y)
        let bins = ys.map(Self.rowBin), tolerances = ys.map(Self.tolerance)
        var alive = [Bool](repeating: true, count: n)
        var curves: [Curve] = []
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next(_ count: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(count))
        }
        var failures = 0
        while curves.count < 7, failures < 5 {
            let pool = (0..<n).filter { alive[$0] }
            guard pool.count >= 8 else { break }
            var bestScore = 0.0, bestModel: Quadratic?, bestRun = (start: 0.0, end: 0.0), bestFromPrior = false
            xs.withUnsafeBufferPointer { xs in ys.withUnsafeBufferPointer { ys in
            bins.withUnsafeBufferPointer { bins in tolerances.withUnsafeBufferPointer { tolerances in
            pool.withUnsafeBufferPointer { pool in
                for k in 0..<(priors.count + 160) {
                    let model: Quadratic
                    if k < priors.count {
                        model = Quadratic(a: priors[k].a, b: priors[k].b, c: priors[k].c)
                    } else {
                        let p = pool[next(pool.count)]
                        var q = p
                        for _ in 0..<6 {
                            let candidate = pool[next(pool.count)]
                            let dy = abs(ys[candidate] - ys[p])
                            if dy >= 0.025 && dy <= 0.20 { q = candidate; break }
                        }
                        guard q != p else { continue }
                        let slope = (xs[q] - xs[p]) / (ys[q] - ys[p])
                        guard abs(slope) < 4 else { continue }
                        var sums = QuadraticSums()
                        for i in pool where abs(xs[i] - (xs[p] + slope * (ys[i] - ys[p]))) <= tolerances[i] * 2.5 {
                            sums.add(x: xs[i], y: ys[i])
                        }
                        guard sums.count >= 6, let solved = sums.solve() else { continue }
                        model = solved
                    }
                    // Perspective: paint heads toward the horizon, never sideways.
                    guard abs(model.b) < 4, abs(model.c) < 12 else { continue }
                    // Longest stretch of inliers without a gap longer than dashed-line spacing.
                    var runBins = 0, runStart = 0.0, lastY = 0.0, lastBin = Int.min
                    var bestBins = 0, bestStart = 0.0, bestEnd = 0.0
                    for i in pool where abs(xs[i] - model.x(ys[i])) <= tolerances[i] {
                        if runBins > 0 && ys[i] - lastY > 0.09 {
                            if runBins > bestBins { bestBins = runBins; bestStart = runStart; bestEnd = lastY }
                            runBins = 0
                        }
                        if runBins == 0 { runStart = ys[i]; runBins = 1; lastBin = bins[i] }
                        else if bins[i] != lastBin { runBins += 1; lastBin = bins[i] }
                        lastY = ys[i]
                    }
                    if runBins > bestBins { bestBins = runBins; bestStart = runStart; bestEnd = lastY }
                    // A line seen a moment ago needs less paint to be found again.
                    guard bestBins >= (k < priors.count ? Self.priorRows : 8) else { continue }
                    // Favour many supported rows packed densely, over long sparse alignments.
                    let spanned = Double(Self.rowBin(bestEnd) - Self.rowBin(bestStart) + 1)
                    let score = Double(bestBins) * min(1, Double(bestBins) / spanned / 0.6)
                    if score > bestScore {
                        bestScore = score; bestModel = model; bestRun = (bestStart, bestEnd); bestFromPrior = k < priors.count
                    }
                }
            }}}}}
            guard let model = bestModel else { break }
            let support = pool.filter {
                abs(xs[$0] - model.x(ys[$0])) <= tolerances[$0] && ys[$0] >= bestRun.start && ys[$0] <= bestRun.end
            }
            guard let curve = refine(support.map { sorted[$0] }, minimumRows: bestFromPrior ? Self.priorRows : 8) else {
                // Discard this support and keep looking for other stripes.
                failures += 1
                for i in support { alive[i] = false }
                continue
            }
            for i in pool where abs(xs[i] - curve.x(ys[i])) <= tolerances[i] * 1.6
                && ys[i] >= curve.minY - 0.02 && ys[i] <= curve.maxY + 0.02 { alive[i] = false }
            curves.append(curve)
        }
        return curves
    }

    /// Running sums for a least-squares quadratic x(y), centred at y = 0.6.
    private struct QuadraticSums {
        var count = 0
        var s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0, x0 = 0.0, x1 = 0.0, x2 = 0.0
        mutating func add(x: Double, y: Double) {
            let t = y - 0.6, t2 = t * t
            count += 1; s1 += t; s2 += t2; s3 += t2 * t; s4 += t2 * t2
            x0 += x; x1 += x * t; x2 += x * t2
        }
        /// Cramer's rule on the 3×3 normal equations.
        func solve() -> Quadratic? {
            let s0 = Double(count)
            let det = s0 * (s2 * s4 - s3 * s3) - s1 * (s1 * s4 - s3 * s2) + s2 * (s1 * s3 - s2 * s2)
            guard abs(det) > 1e-14 else { return nil }
            let a = (x0 * (s2 * s4 - s3 * s3) - s1 * (x1 * s4 - s3 * x2) + s2 * (x1 * s3 - s2 * x2)) / det
            let b = (s0 * (x1 * s4 - x2 * s3) - x0 * (s1 * s4 - s3 * s2) + s2 * (s1 * x2 - x1 * s2)) / det
            let c = (s0 * (s2 * x2 - s3 * x1) - s1 * (s1 * x2 - s2 * x1) + x0 * (s1 * s3 - s2 * s2)) / det
            guard a.isFinite, b.isFinite, c.isFinite else { return nil }
            return Quadratic(a: a, b: b, c: c)
        }
    }

    /// Rows of paint needed to re-find a line that was seen on the previous frame.
    static let priorRows = 5

    private func refine(_ inliers: [RoadPaintCandidate], minimumRows: Int = 8) -> Curve? {
        // One median per image row prevents a bright patch dominating the fit.
        let grouped = Dictionary(grouping: inliers, by: { Self.rowBin($0.y) })
        let medians = grouped.values.map { group -> RoadPaintCandidate in
            let sorted = group.sorted { $0.x < $1.x }; return sorted[sorted.count / 2]
        }.sorted { $0.y < $1.y }
        guard medians.count >= minimumRows, let first = medians.first, let last = medians.last,
              last.y - first.y >= (minimumRows < 8 ? 0.04 : 0.06) else { return nil }
        guard let model = Self.leastSquares(medians) else { return nil }
        guard abs(model.b) < 4, abs(model.c) < 12 else { return nil }
        // Lane paint heads toward the horizon along its whole length; the game's
        // floating GPS ribbon and shadows across the road run nearly sideways.
        let steepest = [first.y, (first.y + last.y) / 2, last.y].map { abs(model.b + 2 * model.c * ($0 - 0.6)) }.max()!
        guard steepest < 3 else { return nil }
        // Paint support must be spread along the curve, not one clump, and
        // dense enough for a solid or dashed stripe rather than scattered glints.
        let covered = Set(medians.map { Int(($0.y - first.y) / (last.y - first.y) * 4.999) })
        guard covered.count >= 3 else { return nil }
        let spannedRows = Double(Self.rowBin(last.y) - Self.rowBin(first.y) + 1)
        guard Double(medians.count) / spannedRows >= 0.40 else { return nil }
        let residual = medians.reduce(0.0) { $0 + abs($1.x - model.x($1.y)) / Self.tolerance($1.y) } / Double(medians.count)
        guard residual <= 0.45 else { return nil }
        // Near the car, paint heads toward the horizon: a stripe left of the
        // car runs down-left, one on the right runs down-right.
        let nearX = model.x(last.y), nearSlope = model.b + 2 * model.c * (last.y - 0.6)
        if abs(nearX - 0.5) >= 0.06 {
            guard nearSlope * (nearX - 0.5) > 0, abs(nearSlope) >= 0.15 else { return nil }
            let horizonX = nearX + nearSlope * (0.40 - last.y)
            guard abs(horizonX - 0.5) <= 0.32 else { return nil }
        }
        let yellow = medians.filter { $0.color == .yellow }.count
        return Curve(a: model.a, b: model.b, c: model.c, minY: first.y, maxY: last.y, rows: medians.count,
                     color: yellow * 3 >= medians.count ? .yellow : .white)
    }

    private struct Quadratic {
        let a: Double, b: Double, c: Double
        func x(_ y: Double) -> Double { let t = y - 0.6; return a + b * t + c * t * t }
    }

    private static func leastSquares(_ points: [RoadPaintCandidate]) -> Quadratic? {
        var sums = QuadraticSums()
        for point in points { sums.add(x: point.x, y: point.y) }
        return sums.solve()
    }

    // MARK: Lane assembly

    /// Pure geometry stage, also used by synthetic regression checks.
    func estimate(candidates: [RoadPaintCandidate], at time: Double) -> RoadLineObservation {
        guard candidates.count >= 10 else {
            return .unavailable(at: time, reason: "Road markings are not sufficiently visible")
        }
        guard candidates.count <= 6000 else {
            return .unavailable(at: time, reason: "Too many bright edges to isolate road paint")
        }
        let usable = markingCurves(candidates)
        guard !usable.isEmpty else {
            return .unavailable(at: time, reason: "Road markings are not established")
        }
        let sides = laneSides(usable)
        return lane(markings: usable, left: sides.left.first, right: sides.right.first, at: time)
    }

    /// Fitted paint lines worth showing: duplicates (double centre lines) merged,
    /// and only curves that stay inside the frame.
    func markingCurves(_ candidates: [RoadPaintCandidate], priors: [Curve] = []) -> [Curve] {
        guard (10...6000).contains(candidates.count) else { return [] }
        var curves = fitMarkings(candidates, priors: priors)
        // A double centre line is one boundary: keep the stronger of near-parallel twins.
        curves.sort { $0.rows > $1.rows }
        var kept: [Curve] = []
        for curve in curves {
            let lo = max(curve.minY, 0.45), hi = min(curve.maxY, 0.80)
            let duplicate = kept.contains { other in
                let a = max(lo, other.minY), b = min(hi, other.maxY)
                guard b - a >= 0.03 else { return false }
                return stride(from: a, through: b, by: (b - a) / 4).allSatisfy {
                    abs(curve.x($0) - other.x($0)) <= 0.012 + max(0, $0 - 0.4) * 0.05
                }
            }
            if !duplicate { kept.append(curve) }
        }
        return kept.filter { curve in
            stride(from: curve.minY, through: curve.maxY, by: (curve.maxY - curve.minY) / 8)
                .allSatisfy { (0.0...1.0).contains(curve.x($0)) }
        }
    }

    /// Where a line passes the car's row, extrapolating only linearly from its
    /// nearest supported row.
    static func sideX(_ curve: Curve) -> Double {
        let reference = 0.72, y = min(reference, curve.maxY)
        return curve.x(y) + curve.slope(y) * (reference - y)
    }

    /// Lines that can bound the car's lane, nearest to the car first. A
    /// boundary converges toward the horizon: left markings run down-left.
    func laneSides(_ curves: [Curve]) -> (left: [Curve], right: [Curve]) {
        let carX = 0.5, reference = 0.72
        // Short fragments (car body edges, patches) can be drawn but never bound the lane.
        let long = curves.filter { $0.maxY - $0.minY >= 0.10 }
        let left = long.filter { Self.sideX($0) < carX - 0.02 && $0.slope(min(reference, $0.maxY)) < -0.05 }
            .sorted { Self.sideX($0) > Self.sideX($1) }
        let right = long.filter { Self.sideX($0) > carX + 0.02 && $0.slope(min(reference, $0.maxY)) > 0.05 }
            .sorted { Self.sideX($0) < Self.sideX($1) }
        return (left, right)
    }

    /// Builds the observation from chosen lane boundaries; every curve is listed as a marking.
    /// `keepPaired`: these two lines formed the lane on the previous frame, so a
    /// shorter overlap is enough to keep them paired (hysteresis).
    func lane(markings usable: [Curve], left: Curve?, right: Curve?, at time: Double,
              keepPaired: Bool = false) -> RoadLineObservation {
        let markings = usable.map { curve in
            RoadMarking(color: curve.color, points: (0..<16).map { i -> RoadPoint in
                let y = curve.minY + Double(i) / 15 * (curve.maxY - curve.minY)
                return RoadPoint(x: curve.x(y), y: y)
            })
        }
        guard !usable.isEmpty else {
            return .unavailable(at: time, reason: "Road markings are not established")
        }
        func sampled(_ curve: Curve, from start: Double, to end: Double) -> [RoadPoint] {
            (0..<16).map { i -> RoadPoint in
                let y = start + Double(i) / 15 * (end - start)
                return RoadPoint(x: curve.x(y), y: y)
            }
        }
        let rowConfidence = { (curve: Curve) in min(0.20, Double(curve.rows) / 150) }

        guard let left, let right else {
            guard let only = left ?? right else {
                return RoadLineObservation(capturedAt: time, left: [], right: [], confidence: 0.5,
                    reason: "Road markings found · lane sides unresolved", markings: markings)
            }
            let edge = sampled(only, from: only.minY, to: only.maxY)
            let confidence = min(0.75, 0.45 + min(only.maxY - only.minY, 0.2) + rowConfidence(only))
            return RoadLineObservation(capturedAt: time, left: left == nil ? [] : edge,
                right: right == nil ? [] : edge, confidence: confidence,
                reason: "One lane boundary · lane width unresolved", markings: markings)
        }
        let start = max(left.minY, right.minY), end = min(left.maxY, right.maxY)
        // Both boundaries stay visible even when they cannot be paired into a
        // lane; each is sampled over its own rows, so `hasCorridor` stays false.
        func single(_ reason: String) -> RoadLineObservation {
            RoadLineObservation(capturedAt: time, left: sampled(left, from: left.minY, to: left.maxY),
                right: sampled(right, from: right.minY, to: right.maxY), confidence: 0.6, reason: reason,
                markings: markings)
        }
        guard end - start >= (keepPaired ? 0.035 : 0.07) else { return single("Lane boundaries do not overlap enough") }
        var l: [RoadPoint] = [], r: [RoadPoint] = []
        for index in 0..<16 {
            let y = start + Double(index) / 15 * (end - start)
            let lx = left.x(y), rx = right.x(y)
            guard rx - lx >= 0.02, rx - lx <= 0.95 else {
                return single("Lane boundaries cross or have implausible width")
            }
            l.append(RoadPoint(x: lx, y: y)); r.append(RoadPoint(x: rx, y: y))
        }
        let nearWidth = r.last!.x - l.last!.x, farWidth = r[0].x - l[0].x
        guard nearWidth > farWidth * (keepPaired ? 1.05 : 1.15) else { return single("Lane does not widen toward the car") }
        let confidence = min(0.92, 0.50 + min(end - start, 0.22) + min(rowConfidence(left), rowConfidence(right)))
        return RoadLineObservation(capturedAt: time, left: l, right: r, confidence: confidence,
            reason: "Lane boundaries from road paint · experimental, not a racing line", markings: markings)
    }
}
