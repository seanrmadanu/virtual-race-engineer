import Foundation

// MARK: - Geometry Result

nonisolated struct MinimapGeometryResult:
    Sendable {

    let isValid: Bool
    let orderedPath: [MinimapPoint]
    let direction: RouteTurnDirection
    let severity: TurnSeverity
    let timing: TurnTiming
    let turnStartPoint: MinimapPoint?
    let turnStartNormalizedDistance: Double?
    let forwardPathConfidence: Float
    let geometryConfidence: Float
    let branchPointCount: Int
    let startDistance: Double
    let pathLength: Double
    let reason: String

    static func invalid(
        _ reason: String
    ) -> MinimapGeometryResult {
        MinimapGeometryResult(
            isValid: false,
            orderedPath: [],
            direction: .unknown,
            severity: .unknown,
            timing: .unknown,
            turnStartPoint: nil,
            turnStartNormalizedDistance: nil,
            forwardPathConfidence: 0,
            geometryConfidence: 0,
            branchPointCount: 0,
            startDistance: .infinity,
            pathLength: 0,
            reason: reason
        )
    }
}

// MARK: - Geometry Analyzer

/// Converts the detector's thick binary mask into one ordered route path.
/// The analyzer intentionally rejects ambiguous geometry instead of guessing.
nonisolated final class MinimapGeometryAnalyzer {

    private let maximumWorkingDimension = 128
    private let minimumUsablePathLength = 0.14
    private let preferredPathLength = 0.48
    private let maximumStartDistance = 0.18
    private let resampleSpacing = 0.018

    private let neighborOffsets: [(x: Int, y: Int)] = [
        (-1, -1), (0, -1), (1, -1),
        (-1, 0),             (1, 0),
        (-1, 1),  (0, 1),   (1, 1)
    ]

    // MARK: Analyze Mask

    func analyze(
        mask: MinimapRouteMask,
        playerAnchor: MinimapPoint,
        previousPath: [MinimapPoint]
    ) -> MinimapGeometryResult {
        guard mask.width > 0,
              mask.height > 0,
              mask.pixels.count == mask.width * mask.height else {
            return .invalid("Route mask dimensions are invalid.")
        }

        let coarse = makeCoarseMask(mask)

        guard coarse.pixels.contains(1) else {
            return .invalid("The route mask is empty after noise removal.")
        }

        let initialSkeleton = thin(
            coarse.pixels,
            width: coarse.width,
            height: coarse.height
        )

        guard initialSkeleton.contains(1) else {
            return .invalid("Centerline extraction produced no usable pixels.")
        }

        let anchorX =
            playerAnchor.x * Double(max(coarse.width - 1, 1))
        let anchorY =
            playerAnchor.y * Double(max(coarse.height - 1, 1))

        let bridgedSkeleton = bridgeAlignedGaps(
            in: initialSkeleton,
            width: coarse.width,
            height: coarse.height,
            anchorX: anchorX,
            anchorY: anchorY
        )
        let skeleton = bridgedSkeleton.pixels

        guard let startIndex = nearestSkeletonIndex(
            toX: anchorX,
            y: anchorY,
            skeleton: skeleton,
            width: coarse.width,
            height: coarse.height
        ) else {
            return .invalid("No centerline exists close enough to the player marker.")
        }

        let startX = startIndex % coarse.width
        let startY = startIndex / coarse.width
        let gridMinimumDimension = Double(min(coarse.width, coarse.height))
        let startDistance = hypot(
            Double(startX) - anchorX,
            Double(startY) - anchorY
        ) / max(gridMinimumDimension, 1)

        guard startDistance <= maximumStartDistance else {
            return .invalid("The detected route does not connect closely enough to the player.")
        }

        let traversal = traverseSkeleton(
            from: startIndex,
            skeleton: skeleton,
            width: coarse.width,
            height: coarse.height
        )

        guard traversal.reachableCount >= 8 else {
            return .invalid("The route centerline is too short to analyze.")
        }

        let endpointCandidates = candidateEndpoints(
            traversal: traversal,
            skeleton: skeleton,
            width: coarse.width,
            height: coarse.height
        )

        guard !endpointCandidates.isEmpty else {
            return .invalid("No forward route endpoint could be found.")
        }

        var candidates: [PathCandidate] = []

        for endpoint in endpointCandidates.prefix(24) {
            let gridPath = reconstructPath(
                endpoint: endpoint,
                start: startIndex,
                predecessors: traversal.predecessors
            )

            guard gridPath.count >= 6 else {
                continue
            }

            let normalizedPath = gridPath.map { index in
                let x = index % coarse.width
                let y = index / coarse.width

                return MinimapPoint(
                    x: (Double(x) + 0.5) / Double(coarse.width),
                    y: (Double(y) + 0.5) / Double(coarse.height)
                )
            }

            let smoothed = smoothPath(normalizedPath, passes: 2)
            let resampled = resample(
                smoothed,
                width: coarse.width,
                height: coarse.height,
                spacing: resampleSpacing
            )

            guard resampled.count >= 6 else {
                continue
            }

            let length = pathLength(
                resampled,
                width: coarse.width,
                height: coarse.height
            )

            let score = scorePathCandidate(
                resampled,
                length: length,
                width: coarse.width,
                height: coarse.height,
                previousPath: previousPath
            )

            candidates.append(
                PathCandidate(
                    points: resampled,
                    score: score,
                    length: length
                )
            )
        }

        candidates.sort { $0.score > $1.score }

        guard let best = candidates.first,
              best.length >= minimumUsablePathLength else {
            return .invalid("The ordered forward path is not long enough for turn analysis.")
        }

        let secondCandidate = candidates.dropFirst().first
        let secondScore = secondCandidate?.score ?? 0
        let scoreMargin = max(best.score - secondScore, 0)
        let followsSameBranch = secondCandidate.map {
            pathSimilarity(best.points, $0.points) >= 0.72
        } ?? false
        let marginConfidence = followsSameBranch
            ? 1
            : clamped(scoreMargin / 0.16)
        let startConfidence = 1 - clamped(
            startDistance / maximumStartDistance
        )
        let lengthConfidence = clamped(
            (best.length - minimumUsablePathLength) /
            (preferredPathLength - minimumUsablePathLength)
        )

        let branchCount = traversal.reachableIndices.reduce(0) {
            partial, index in
            partial + (effectiveDegree(
                at: index,
                mask: skeleton,
                width: coarse.width,
                height: coarse.height
            ) >= 3 ? 1 : 0)
        }

        let branchPenalty = clamped(
            1 - Double(max(branchCount - 2, 0)) / 10
        )
        let bridgePenalty = clamped(
            1 - Double(bridgedSkeleton.bridgeCount) * 0.16
        )

        let forwardConfidence = Float(clamped(
            0.30 * startConfidence +
            0.30 * lengthConfidence +
            0.22 * marginConfidence +
            0.10 * branchPenalty +
            0.08 * bridgePenalty
        ))

        return describeOrderedPath(
            best.points,
            width: coarse.width,
            height: coarse.height,
            forwardPathConfidence: forwardConfidence,
            branchPointCount: branchCount,
            startDistance: startDistance,
            fallbackReason: "Ordered route centerline extracted."
        )
    }

    // MARK: Describe Tracked Path

    /// Recomputes turn geometry after the lightweight tracker rotates or
    /// translates the last verified centerline onto a newer video frame.
    func describeTrackedPath(
        _ path: [MinimapPoint],
        forwardPathConfidence: Float,
        branchPointCount: Int
    ) -> MinimapGeometryResult {
        let normalized = resample(
            smoothPath(path.map { $0.clamped() }, passes: 1),
            width: 1,
            height: 1,
            spacing: resampleSpacing
        )

        return describeOrderedPath(
            normalized,
            width: 1,
            height: 1,
            forwardPathConfidence: forwardPathConfidence,
            branchPointCount: branchPointCount,
            startDistance: 0,
            fallbackReason: "Centerline updated by minimap motion tracking."
        )
    }

    // MARK: Coarse Mask

    private func makeCoarseMask(
        _ mask: MinimapRouteMask
    ) -> BinaryGrid {
        let scale = max(
            1,
            Int(ceil(
                Double(max(mask.width, mask.height)) /
                Double(maximumWorkingDimension)
            ))
        )

        let width = (mask.width + scale - 1) / scale
        let height = (mask.height + scale - 1) / scale
        var counts = [Int](repeating: 0, count: width * height)

        mask.pixels.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return
            }

            for y in 0..<mask.height {
                let coarseY = y / scale
                let sourceRow = y * mask.width
                let coarseRow = coarseY * width

                for x in 0..<mask.width where source[sourceRow + x] != 0 {
                    counts[coarseRow + x / scale] += 1
                }
            }
        }

        let minimumOccupancy = max(1, (scale * scale) / 6)
        var pixels = counts.map { $0 >= minimumOccupancy ? UInt8(1) : UInt8(0) }

        // Remove truly isolated cells while preserving one-cell endpoints.
        var cleaned = pixels
        for index in pixels.indices where pixels[index] != 0 {
            if neighborCount(
                at: index,
                mask: pixels,
                width: width,
                height: height
            ) == 0 {
                cleaned[index] = 0
            }
        }
        pixels = cleaned

        return BinaryGrid(width: width, height: height, pixels: pixels)
    }

    // MARK: Skeletonization

    private func thin(
        _ source: [UInt8],
        width: Int,
        height: Int
    ) -> [UInt8] {
        guard width >= 3, height >= 3 else {
            return source
        }

        var result = source
        var changed = true
        var iteration = 0

        while changed && iteration < 48 {
            changed = false
            iteration += 1

            for subiteration in 0..<2 {
                var removals: [Int] = []

                for y in 1..<(height - 1) {
                    for x in 1..<(width - 1) {
                        let index = y * width + x
                        guard result[index] != 0 else {
                            continue
                        }

                        let p2 = result[(y - 1) * width + x]
                        let p3 = result[(y - 1) * width + x + 1]
                        let p4 = result[y * width + x + 1]
                        let p5 = result[(y + 1) * width + x + 1]
                        let p6 = result[(y + 1) * width + x]
                        let p7 = result[(y + 1) * width + x - 1]
                        let p8 = result[y * width + x - 1]
                        let p9 = result[(y - 1) * width + x - 1]
                        let neighbors = [p2, p3, p4, p5, p6, p7, p8, p9]
                        let count = neighbors.reduce(0) { $0 + Int($1) }

                        guard count >= 2, count <= 6 else {
                            continue
                        }

                        var transitions = 0
                        for neighborIndex in 0..<neighbors.count {
                            let current = neighbors[neighborIndex]
                            let next = neighbors[(neighborIndex + 1) % neighbors.count]
                            if current == 0 && next != 0 {
                                transitions += 1
                            }
                        }

                        guard transitions == 1 else {
                            continue
                        }

                        if subiteration == 0 {
                            guard p2 * p4 * p6 == 0,
                                  p4 * p6 * p8 == 0 else {
                                continue
                            }
                        } else {
                            guard p2 * p4 * p8 == 0,
                                  p2 * p6 * p8 == 0 else {
                                continue
                            }
                        }

                        removals.append(index)
                    }
                }

                if !removals.isEmpty {
                    changed = true
                    for index in removals {
                        result[index] = 0
                    }
                }
            }
        }

        return result
    }

    // MARK: Conservative Gap Bridging

    /// Reconnects only short, endpoint-to-endpoint gaps whose tangents agree.
    /// This is intended for checkpoint circles that temporarily cover the GPS
    /// trail. Ambiguous gaps remain disconnected and lower path confidence.
    private func bridgeAlignedGaps(
        in source: [UInt8],
        width: Int,
        height: Int,
        anchorX: Double,
        anchorY: Double
    ) -> BridgedSkeleton {
        guard let startIndex = nearestSkeletonIndex(
            toX: anchorX,
            y: anchorY,
            skeleton: source,
            width: width,
            height: height
        ) else {
            return BridgedSkeleton(pixels: source, bridgeCount: 0)
        }

        var result = source
        var bridgeCount = 0
        let minimumDimension = Double(max(min(width, height), 1))
        let maximumGap = minimumDimension * 0.16
        let protectedStartRadius = minimumDimension * 0.055

        for _ in 0..<3 {
            let components = labelSkeletonComponents(
                result,
                width: width,
                height: height
            )
            let primaryLabel = components.labels[startIndex]

            guard primaryLabel > 0,
                  components.sizes.count > 1 else {
                break
            }

            let primaryEndpoints = result.indices.filter { index in
                components.labels[index] == primaryLabel &&
                effectiveDegree(
                    at: index,
                    mask: result,
                    width: width,
                    height: height
                ) <= 1
            }
            let otherEndpoints = result.indices.filter { index in
                let label = components.labels[index]
                return label > 0 &&
                    label != primaryLabel &&
                    (components.sizes[label] ?? 0) >= 5 &&
                    effectiveDegree(
                        at: index,
                        mask: result,
                        width: width,
                        height: height
                    ) <= 1
            }

            var bestCandidate: GapBridgeCandidate?

            for first in primaryEndpoints {
                let firstX = Double(first % width)
                let firstY = Double(first / width)
                let anchorDistance = hypot(firstX - anchorX, firstY - anchorY)

                guard anchorDistance > protectedStartRadius,
                      let firstTangent = endpointOutwardTangent(
                        endpoint: first,
                        label: primaryLabel,
                        components: components,
                        width: width,
                        height: height
                      ) else {
                    continue
                }

                for second in otherEndpoints {
                    let secondLabel = components.labels[second]
                    guard let secondTangent = endpointOutwardTangent(
                        endpoint: second,
                        label: secondLabel,
                        components: components,
                        width: width,
                        height: height
                    ) else {
                        continue
                    }

                    let deltaX = Double(second % width) - firstX
                    let deltaY = Double(second / width) - firstY
                    let distance = hypot(deltaX, deltaY)

                    guard distance >= 2,
                          distance <= maximumGap else {
                        continue
                    }

                    let directionX = deltaX / distance
                    let directionY = deltaY / distance
                    let firstAlignment =
                        firstTangent.x * directionX +
                        firstTangent.y * directionY
                    let secondAlignment =
                        secondTangent.x * -directionX +
                        secondTangent.y * -directionY

                    guard firstAlignment >= 0.15,
                          secondAlignment >= 0.15 else {
                        continue
                    }

                    let otherSize = Double(components.sizes[secondLabel] ?? 0)
                    let sizeReward = min(otherSize / minimumDimension, 1)
                    let score =
                        distance / maximumGap -
                        0.16 * firstAlignment -
                        0.16 * secondAlignment -
                        0.08 * sizeReward

                    if bestCandidate == nil ||
                       score < (bestCandidate?.score ?? Double.greatestFiniteMagnitude) {
                        bestCandidate = GapBridgeCandidate(
                            first: first,
                            second: second,
                            score: score
                        )
                    }
                }
            }

            guard let bestCandidate else {
                break
            }

            drawLine(
                from: bestCandidate.first,
                to: bestCandidate.second,
                in: &result,
                width: width,
                height: height
            )
            bridgeCount += 1
        }

        return BridgedSkeleton(
            pixels: result,
            bridgeCount: bridgeCount
        )
    }

    private func labelSkeletonComponents(
        _ mask: [UInt8],
        width: Int,
        height: Int
    ) -> SkeletonComponents {
        var labels = [Int](repeating: 0, count: mask.count)
        var sizes: [Int: Int] = [:]
        var nextLabel = 0

        for start in mask.indices where mask[start] != 0 && labels[start] == 0 {
            nextLabel += 1
            var queue = [start]
            var head = 0
            var count = 0
            labels[start] = nextLabel

            while head < queue.count {
                let index = queue[head]
                head += 1
                count += 1

                for neighbor in neighborIndices(
                    at: index,
                    width: width,
                    height: height
                ) where mask[neighbor] != 0 && labels[neighbor] == 0 {
                    labels[neighbor] = nextLabel
                    queue.append(neighbor)
                }
            }

            sizes[nextLabel] = count
        }

        return SkeletonComponents(labels: labels, sizes: sizes)
    }

    private func endpointOutwardTangent(
        endpoint: Int,
        label: Int,
        components: SkeletonComponents,
        width: Int,
        height: Int
    ) -> (x: Double, y: Double)? {
        var queue = [endpoint]
        var distances = [Int: Int](minimumCapacity: 20)
        var head = 0
        distances[endpoint] = 0
        var interior = endpoint
        var interiorDistance = 0

        while head < queue.count {
            let index = queue[head]
            head += 1
            let distance = distances[index] ?? 0

            if distance > interiorDistance {
                interior = index
                interiorDistance = distance
            }

            guard distance < 6 else {
                continue
            }

            for neighbor in neighborIndices(
                at: index,
                width: width,
                height: height
            ) where components.labels[neighbor] == label && distances[neighbor] == nil {
                distances[neighbor] = distance + 1
                queue.append(neighbor)
            }
        }

        guard interior != endpoint else {
            return nil
        }

        let deltaX = Double(endpoint % width - interior % width)
        let deltaY = Double(endpoint / width - interior / width)
        let magnitude = hypot(deltaX, deltaY)
        guard magnitude > 0 else {
            return nil
        }

        return (deltaX / magnitude, deltaY / magnitude)
    }

    private func drawLine(
        from start: Int,
        to end: Int,
        in mask: inout [UInt8],
        width: Int,
        height: Int
    ) {
        var x0 = start % width
        var y0 = start / width
        let x1 = end % width
        let y1 = end / width
        let deltaX = abs(x1 - x0)
        let stepX = x0 < x1 ? 1 : -1
        let deltaY = -abs(y1 - y0)
        let stepY = y0 < y1 ? 1 : -1
        var error = deltaX + deltaY

        while true {
            if x0 >= 0, x0 < width, y0 >= 0, y0 < height {
                mask[y0 * width + x0] = 1
            }

            if x0 == x1 && y0 == y1 {
                break
            }

            let doubledError = 2 * error
            if doubledError >= deltaY {
                error += deltaY
                x0 += stepX
            }
            if doubledError <= deltaX {
                error += deltaX
                y0 += stepY
            }
        }
    }

    // MARK: Graph Traversal

    private func nearestSkeletonIndex(
        toX anchorX: Double,
        y anchorY: Double,
        skeleton: [UInt8],
        width: Int,
        height: Int
    ) -> Int? {
        var bestIndex: Int?
        var bestDistance = Double.greatestFiniteMagnitude

        for index in skeleton.indices where skeleton[index] != 0 {
            let x = Double(index % width)
            let y = Double(index / width)
            let distance = hypot(x - anchorX, y - anchorY)

            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }

        return bestIndex
    }

    private func traverseSkeleton(
        from start: Int,
        skeleton: [UInt8],
        width: Int,
        height: Int
    ) -> SkeletonTraversal {
        var distances = [Int](repeating: -1, count: skeleton.count)
        var predecessors = [Int](repeating: -1, count: skeleton.count)
        var queue: [Int] = [start]
        var head = 0
        var reachable: [Int] = []
        distances[start] = 0

        while head < queue.count {
            let index = queue[head]
            head += 1
            reachable.append(index)

            for neighbor in neighborIndices(
                at: index,
                width: width,
                height: height
            ) where skeleton[neighbor] != 0 && distances[neighbor] < 0 {
                distances[neighbor] = distances[index] + 1
                predecessors[neighbor] = index
                queue.append(neighbor)
            }
        }

        return SkeletonTraversal(
            distances: distances,
            predecessors: predecessors,
            reachableIndices: reachable
        )
    }

    private func candidateEndpoints(
        traversal: SkeletonTraversal,
        skeleton: [UInt8],
        width: Int,
        height: Int
    ) -> [Int] {
        var endpoints = traversal.reachableIndices.filter { index in
            traversal.distances[index] >= 4 &&
            effectiveDegree(
                at: index,
                mask: skeleton,
                width: width,
                height: height
            ) <= 1
        }

        endpoints.sort {
            traversal.distances[$0] > traversal.distances[$1]
        }

        if endpoints.count < 2 {
            let farthest = traversal.reachableIndices
                .filter { traversal.distances[$0] >= 4 }
                .sorted { traversal.distances[$0] > traversal.distances[$1] }

            for index in farthest.prefix(12) where !endpoints.contains(index) {
                endpoints.append(index)
            }
        }

        return endpoints
    }

    private func reconstructPath(
        endpoint: Int,
        start: Int,
        predecessors: [Int]
    ) -> [Int] {
        var reversed: [Int] = []
        var current = endpoint
        var safety = 0

        while current >= 0 && safety <= predecessors.count {
            reversed.append(current)
            if current == start {
                break
            }
            current = predecessors[current]
            safety += 1
        }

        guard reversed.last == start else {
            return []
        }

        return reversed.reversed()
    }

    // MARK: Candidate Scoring

    private func scorePathCandidate(
        _ path: [MinimapPoint],
        length: Double,
        width: Int,
        height: Int,
        previousPath: [MinimapPoint]
    ) -> Double {
        let lengthScore = clamped(
            length / preferredPathLength
        )

        let start = path[0]
        let end = path[path.count - 1]
        let reachScore = clamped(
            isotropicDistance(
                start,
                end,
                width: width,
                height: height
            ) / 0.42
        )

        let headingPoint = point(
            on: path,
            atDistance: min(0.075, length * 0.45),
            width: width,
            height: height
        ) ?? path[min(path.count - 1, 3)]

        let heading = isotropicVector(
            from: start,
            to: headingPoint,
            width: width,
            height: height
        )
        let headingMagnitude = max(hypot(heading.x, heading.y), 0.0001)
        let forwardDot = -heading.y / headingMagnitude
        let headingScore = clamped((forwardDot + 1) / 2)
        let smoothness = pathSmoothness(
            path,
            width: width,
            height: height
        )
        let continuity = previousPath.isEmpty
            ? 0.65
            : pathSimilarity(path, previousPath)

        return clamped(
            0.30 * lengthScore +
            0.20 * reachScore +
            0.22 * headingScore +
            0.13 * smoothness +
            0.15 * continuity
        )
    }

    // MARK: Turn Geometry

    private func describeOrderedPath(
        _ path: [MinimapPoint],
        width: Int,
        height: Int,
        forwardPathConfidence: Float,
        branchPointCount: Int,
        startDistance: Double,
        fallbackReason: String
    ) -> MinimapGeometryResult {
        guard path.count >= 6 else {
            return .invalid("Too few ordered centerline points remain after smoothing.")
        }

        let length = pathLength(path, width: width, height: height)
        guard length >= minimumUsablePathLength else {
            return .invalid("The visible route is too short to classify safely.")
        }

        let headingSamples = makeHeadingSamples(
            path,
            width: width,
            height: height
        )

        guard headingSamples.count >= 4 else {
            return .invalid("The centerline does not contain enough heading samples.")
        }

        let deviations = unwrappedDeviations(headingSamples.map(\.angle))
        let smoothedDeviations = movingAverage(deviations, radius: 1)
        let turnThreshold = degreesToRadians(14)
        let releaseThreshold = degreesToRadians(8)
        var onsetIndex: Int?

        if smoothedDeviations.count >= 3 {
            for index in 0..<(smoothedDeviations.count - 2) {
                let window = smoothedDeviations[index...(index + 2)]
                let positives = window.filter { $0 >= turnThreshold }.count
                let negatives = window.filter { $0 <= -turnThreshold }.count

                if positives >= 2 || negatives >= 2 {
                    onsetIndex = index
                    break
                }
            }
        }

        let smoothness = pathSmoothness(path, width: width, height: height)
        let sampleScore = clamped(Double(path.count - 5) / 25)
        let lengthScore = clamped(
            (length - minimumUsablePathLength) /
            (preferredPathLength - minimumUsablePathLength)
        )
        let branchScore = clamped(
            1 - Double(max(branchPointCount - 2, 0)) / 10
        )
        let geometryConfidence = Float(clamped(
            0.35 * lengthScore +
            0.30 * smoothness +
            0.20 * sampleScore +
            0.15 * branchScore
        ))

        guard let onsetIndex else {
            return MinimapGeometryResult(
                isValid: true,
                orderedPath: path,
                direction: .straight,
                severity: .straight,
                timing: .none,
                turnStartPoint: nil,
                turnStartNormalizedDistance: nil,
                forwardPathConfidence: forwardPathConfidence,
                geometryConfidence: geometryConfidence,
                branchPointCount: branchPointCount,
                startDistance: startDistance,
                pathLength: length,
                reason: "No significant turn is visible on the ordered route."
            )
        }

        let initialSign = smoothedDeviations[onsetIndex] >= 0 ? 1.0 : -1.0
        var peakIndex = onsetIndex
        var peakMagnitude = abs(smoothedDeviations[onsetIndex])
        var hasEstablishedTurn = false

        for index in onsetIndex..<smoothedDeviations.count {
            let deviation = smoothedDeviations[index]
            let signMatches = deviation == 0 || (deviation > 0) == (initialSign > 0)

            if abs(deviation) >= turnThreshold {
                hasEstablishedTurn = true
            }

            if hasEstablishedTurn,
               (!signMatches || abs(deviation) < releaseThreshold),
               index > onsetIndex + 2 {
                break
            }

            if signMatches && abs(deviation) > peakMagnitude {
                peakMagnitude = abs(deviation)
                peakIndex = index
            }
        }

        let peakDegrees = radiansToDegrees(peakMagnitude)
        let onsetDistance = headingSamples[onsetIndex].distance
        let peakDistance = headingSamples[min(peakIndex, headingSamples.count - 1)].distance
        let developmentDistance = max(peakDistance - onsetDistance, 0.045)
        let turnRate = peakDegrees / developmentDistance

        let severity: TurnSeverity
        if peakDegrees >= 135 {
            severity = .uTurn
        } else if peakDegrees < 34 && turnRate < 430 {
            severity = .gentle
        } else if peakDegrees < 72 && turnRate < 760 {
            severity = .medium
        } else {
            severity = .sharp
        }

        let direction: RouteTurnDirection
        if severity == .uTurn {
            direction = initialSign < 0 ? .uTurnLeft : .uTurnRight
        } else {
            direction = initialSign < 0 ? .left : .right
        }

        let timing: TurnTiming
        if onsetDistance <= 0.10 {
            timing = .now
        } else if onsetDistance <= 0.25 {
            timing = .soon
        } else {
            timing = .later
        }

        let turnStartPoint = point(
            on: path,
            atDistance: onsetDistance,
            width: width,
            height: height
        )

        return MinimapGeometryResult(
            isValid: true,
            orderedPath: path,
            direction: direction,
            severity: severity,
            timing: timing,
            turnStartPoint: turnStartPoint,
            turnStartNormalizedDistance: onsetDistance,
            forwardPathConfidence: forwardPathConfidence,
            geometryConfidence: geometryConfidence,
            branchPointCount: branchPointCount,
            startDistance: startDistance,
            pathLength: length,
            reason: fallbackReason
        )
    }

    private func makeHeadingSamples(
        _ path: [MinimapPoint],
        width: Int,
        height: Int
    ) -> [HeadingSample] {
        let distances = cumulativeDistances(path, width: width, height: height)
        var samples: [HeadingSample] = []
        let headingLookahead = 0.040

        for index in 0..<(path.count - 1) {
            var endIndex = index + 1
            while endIndex < path.count - 1 &&
                  distances[endIndex] - distances[index] < headingLookahead {
                endIndex += 1
            }

            let vector = isotropicVector(
                from: path[index],
                to: path[endIndex],
                width: width,
                height: height
            )

            guard hypot(vector.x, vector.y) > 0.0001 else {
                continue
            }

            samples.append(
                HeadingSample(
                    distance: distances[index],
                    angle: atan2(vector.y, vector.x)
                )
            )
        }

        return samples
    }

    private func unwrappedDeviations(
        _ headings: [Double]
    ) -> [Double] {
        guard !headings.isEmpty else {
            return []
        }

        let playerForward = -Double.pi / 2
        var previous = playerForward
        var accumulated = 0.0
        var deviations: [Double] = []

        for heading in headings {
            accumulated += signedAngleDifference(heading, previous)
            deviations.append(accumulated)
            previous = heading
        }

        return deviations
    }

    // MARK: Path Utilities

    private func smoothPath(
        _ path: [MinimapPoint],
        passes: Int
    ) -> [MinimapPoint] {
        guard path.count >= 5, passes > 0 else {
            return path
        }

        var result = path
        for _ in 0..<passes {
            var next = result
            for index in 1..<(result.count - 1) {
                let start = max(0, index - 2)
                let end = min(result.count - 1, index + 2)
                let count = Double(end - start + 1)
                var x = 0.0
                var y = 0.0

                for sampleIndex in start...end {
                    x += result[sampleIndex].x
                    y += result[sampleIndex].y
                }

                next[index] = MinimapPoint(x: x / count, y: y / count)
            }
            result = next
        }

        return result
    }

    private func resample(
        _ path: [MinimapPoint],
        width: Int,
        height: Int,
        spacing: Double
    ) -> [MinimapPoint] {
        guard path.count >= 2, spacing > 0 else {
            return path
        }

        let total = pathLength(path, width: width, height: height)
        guard total > 0 else {
            return [path[0]]
        }

        var result: [MinimapPoint] = [path[0]]
        var targetDistance = spacing
        var traversed = 0.0
        var segmentIndex = 0

        while targetDistance < total && segmentIndex < path.count - 1 {
            let start = path[segmentIndex]
            let end = path[segmentIndex + 1]
            let segmentLength = isotropicDistance(
                start,
                end,
                width: width,
                height: height
            )

            if traversed + segmentLength >= targetDistance,
               segmentLength > 0 {
                let t = (targetDistance - traversed) / segmentLength
                result.append(
                    MinimapPoint(
                        x: start.x + (end.x - start.x) * t,
                        y: start.y + (end.y - start.y) * t
                    )
                )
                targetDistance += spacing
            } else {
                traversed += segmentLength
                segmentIndex += 1
            }
        }

        if result.last != path.last {
            result.append(path[path.count - 1])
        }

        return result
    }

    private func pathLength(
        _ path: [MinimapPoint],
        width: Int,
        height: Int
    ) -> Double {
        guard path.count >= 2 else {
            return 0
        }

        return zip(path, path.dropFirst()).reduce(0) { partial, pair in
            partial + isotropicDistance(
                pair.0,
                pair.1,
                width: width,
                height: height
            )
        }
    }

    private func cumulativeDistances(
        _ path: [MinimapPoint],
        width: Int,
        height: Int
    ) -> [Double] {
        guard !path.isEmpty else {
            return []
        }

        var result = [Double](repeating: 0, count: path.count)
        for index in 1..<path.count {
            result[index] = result[index - 1] + isotropicDistance(
                path[index - 1],
                path[index],
                width: width,
                height: height
            )
        }
        return result
    }

    private func point(
        on path: [MinimapPoint],
        atDistance target: Double,
        width: Int,
        height: Int
    ) -> MinimapPoint? {
        guard !path.isEmpty else {
            return nil
        }

        if target <= 0 {
            return path[0]
        }

        var traversed = 0.0
        for index in 1..<path.count {
            let segment = isotropicDistance(
                path[index - 1],
                path[index],
                width: width,
                height: height
            )

            if traversed + segment >= target, segment > 0 {
                let t = (target - traversed) / segment
                return MinimapPoint(
                    x: path[index - 1].x + (path[index].x - path[index - 1].x) * t,
                    y: path[index - 1].y + (path[index].y - path[index - 1].y) * t
                )
            }

            traversed += segment
        }

        return path.last
    }

    private func pathSmoothness(
        _ path: [MinimapPoint],
        width: Int,
        height: Int
    ) -> Double {
        guard path.count >= 5 else {
            return 0.4
        }

        var headingChanges: [Double] = []
        var previousHeading: Double?

        for index in 1..<path.count {
            let vector = isotropicVector(
                from: path[index - 1],
                to: path[index],
                width: width,
                height: height
            )
            guard hypot(vector.x, vector.y) > 0.0001 else {
                continue
            }

            let heading = atan2(vector.y, vector.x)
            if let previousHeading {
                headingChanges.append(abs(signedAngleDifference(heading, previousHeading)))
            }
            previousHeading = heading
        }

        guard !headingChanges.isEmpty else {
            return 0.4
        }

        let mean = headingChanges.reduce(0, +) / Double(headingChanges.count)
        return clamped(1 - mean / degreesToRadians(42))
    }

    private func pathSimilarity(
        _ first: [MinimapPoint],
        _ second: [MinimapPoint]
    ) -> Double {
        guard first.count >= 2, second.count >= 2 else {
            return 0
        }

        let sampleCount = min(20, min(first.count, second.count))
        var total = 0.0

        for sample in 0..<sampleCount {
            let fraction = Double(sample) / Double(max(sampleCount - 1, 1))
            let firstIndex = Int((Double(first.count - 1) * fraction).rounded())
            let secondIndex = Int((Double(second.count - 1) * fraction).rounded())
            total += hypot(
                first[firstIndex].x - second[secondIndex].x,
                first[firstIndex].y - second[secondIndex].y
            )
        }

        let mean = total / Double(sampleCount)
        return clamped(1 - mean / 0.18)
    }

    private func movingAverage(
        _ values: [Double],
        radius: Int
    ) -> [Double] {
        guard values.count > 2, radius > 0 else {
            return values
        }

        return values.indices.map { index in
            let start = max(0, index - radius)
            let end = min(values.count - 1, index + radius)
            let sum = values[start...end].reduce(0, +)
            return sum / Double(end - start + 1)
        }
    }

    // MARK: Grid Utilities

    private func neighborIndices(
        at index: Int,
        width: Int,
        height: Int
    ) -> [Int] {
        let x = index % width
        let y = index / width
        var result: [Int] = []
        result.reserveCapacity(8)

        for offset in neighborOffsets {
            let neighborX = x + offset.x
            let neighborY = y + offset.y
            if neighborX >= 0,
               neighborX < width,
               neighborY >= 0,
               neighborY < height {
                result.append(neighborY * width + neighborX)
            }
        }

        return result
    }

    private func neighborCount(
        at index: Int,
        mask: [UInt8],
        width: Int,
        height: Int
    ) -> Int {
        neighborIndices(at: index, width: width, height: height)
            .filter { mask[$0] != 0 }
            .count
    }

    /// Diagonal neighbors that merely round a corner do not count as an
    /// independent branch. This keeps normal bends from looking ambiguous.
    private func effectiveDegree(
        at index: Int,
        mask: [UInt8],
        width: Int,
        height: Int
    ) -> Int {
        let x = index % width
        let y = index / width

        func isSet(_ offsetX: Int, _ offsetY: Int) -> Bool {
            let testX = x + offsetX
            let testY = y + offsetY
            guard testX >= 0, testX < width, testY >= 0, testY < height else {
                return false
            }
            return mask[testY * width + testX] != 0
        }

        var degree = 0
        let cardinal = [(0, -1), (1, 0), (0, 1), (-1, 0)]
        for offset in cardinal where isSet(offset.0, offset.1) {
            degree += 1
        }

        let diagonals = [
            (-1, -1, -1, 0, 0, -1),
            (1, -1, 1, 0, 0, -1),
            (1, 1, 1, 0, 0, 1),
            (-1, 1, -1, 0, 0, 1)
        ]

        for diagonal in diagonals {
            if isSet(diagonal.0, diagonal.1),
               !isSet(diagonal.2, diagonal.3),
               !isSet(diagonal.4, diagonal.5) {
                degree += 1
            }
        }

        return degree
    }

    // MARK: Math

    private func isotropicDistance(
        _ first: MinimapPoint,
        _ second: MinimapPoint,
        width: Int,
        height: Int
    ) -> Double {
        let vector = isotropicVector(
            from: first,
            to: second,
            width: width,
            height: height
        )
        return hypot(vector.x, vector.y)
    }

    private func isotropicVector(
        from first: MinimapPoint,
        to second: MinimapPoint,
        width: Int,
        height: Int
    ) -> (x: Double, y: Double) {
        let minimumDimension = Double(max(min(width, height), 1))
        return (
            (second.x - first.x) * Double(max(width, 1)) / minimumDimension,
            (second.y - first.y) * Double(max(height, 1)) / minimumDimension
        )
    }

    private func signedAngleDifference(
        _ first: Double,
        _ second: Double
    ) -> Double {
        var difference = first - second
        while difference > Double.pi {
            difference -= 2 * Double.pi
        }
        while difference < -Double.pi {
            difference += 2 * Double.pi
        }
        return difference
    }

    private func degreesToRadians(_ degrees: Double) -> Double {
        degrees * Double.pi / 180
    }

    private func radiansToDegrees(_ radians: Double) -> Double {
        radians * 180 / Double.pi
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

// MARK: - Private Geometry Types

nonisolated private struct BinaryGrid {
    let width: Int
    let height: Int
    let pixels: [UInt8]
}

nonisolated private struct BridgedSkeleton {
    let pixels: [UInt8]
    let bridgeCount: Int
}

nonisolated private struct SkeletonComponents {
    let labels: [Int]
    let sizes: [Int: Int]
}

nonisolated private struct GapBridgeCandidate {
    let first: Int
    let second: Int
    let score: Double
}

nonisolated private struct SkeletonTraversal {
    let distances: [Int]
    let predecessors: [Int]
    let reachableIndices: [Int]

    var reachableCount: Int {
        reachableIndices.count
    }
}

nonisolated private struct PathCandidate {
    let points: [MinimapPoint]
    let score: Double
    let length: Double
}

nonisolated private struct HeadingSample {
    let distance: Double
    let angle: Double
}
