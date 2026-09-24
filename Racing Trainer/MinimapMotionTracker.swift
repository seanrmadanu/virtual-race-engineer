import CoreGraphics
import CoreVideo
import Foundation

nonisolated struct MinimapMotionTrackingResult:
    Sendable {

    let succeeded: Bool
    let transformedPath: [MinimapPoint]
    let confidence: Float
    let rotationDegrees: Double
    let translationX: Double
    let translationY: Double
    let reason: String

    static func failed(
        _ reason: String
    ) -> MinimapMotionTrackingResult {
        MinimapMotionTrackingResult(
            succeeded: false,
            transformedPath: [],
            confidence: 0,
            rotationDegrees: 0,
            translationX: 0,
            translationY: 0,
            reason: reason
        )
    }
}

/// Fast correction used after a slower full route detection. It searches for
/// the small rotation/translation that best aligns the verified centerline
/// with yellow route pixels in the newest frame. It never invents a new path.
nonisolated final class MinimapMotionTracker {

    private let gridWidth = 84
    private let gridHeight = 84
    private let maximumRotationDegrees = 18
    private let rotationStepDegrees = 2
    private let translations = [-0.012, 0.0, 0.012]

    func track(
        pixelBuffer: CVPixelBuffer,
        normalizedCropRect: CGRect,
        path: [MinimapPoint],
        playerAnchor: MinimapPoint
    ) -> MinimapMotionTrackingResult {
        guard path.count >= 6 else {
            return .failed("No ordered centerline is available for motion tracking.")
        }

        guard let yellowGrid = makeYellowGrid(
            pixelBuffer: pixelBuffer,
            normalizedCropRect: normalizedCropRect
        ) else {
            return .failed("The newest frame could not be sampled for route motion.")
        }

        var candidates: [TrackingCandidate] = []

        for rotation in stride(
            from: -maximumRotationDegrees,
            through: maximumRotationDegrees,
            by: rotationStepDegrees
        ) {
            for translationX in translations {
                for translationY in translations {
                    let transformed = transform(
                        path,
                        around: playerAnchor,
                        rotationDegrees: Double(rotation),
                        translationX: translationX,
                        translationY: translationY
                    )

                    let coverage = routeCoverage(
                        transformed,
                        yellowGrid: yellowGrid
                    )

                    candidates.append(
                        TrackingCandidate(
                            path: transformed,
                            coverage: coverage,
                            rotationDegrees: Double(rotation),
                            translationX: translationX,
                            translationY: translationY
                        )
                    )
                }
            }
        }

        candidates.sort { $0.coverage > $1.coverage }

        guard let best = candidates.first else {
            return .failed("No motion candidate was produced.")
        }

        let secondCoverage = candidates.dropFirst().first?.coverage ?? 0
        let margin = max(best.coverage - secondCoverage, 0)
        let boundaryPenalty = abs(best.rotationDegrees) >= Double(maximumRotationDegrees)
            ? 0.78
            : 1.0
        let confidence = Float(clamped(
            (0.82 * best.coverage + 0.18 * clamped(margin / 0.08)) *
            boundaryPenalty
        ))

        guard best.coverage >= 0.38,
              confidence >= 0.42 else {
            return .failed("The old centerline did not align reliably with the newest frame.")
        }

        return MinimapMotionTrackingResult(
            succeeded: true,
            transformedPath: best.path,
            confidence: confidence,
            rotationDegrees: best.rotationDegrees,
            translationX: best.translationX,
            translationY: best.translationY,
            reason: "Tracked route motion onto the newest available frame."
        )
    }

    // MARK: Yellow Sampling

    private func makeYellowGrid(
        pixelBuffer: CVPixelBuffer,
        normalizedCropRect: CGRect
    ) -> [UInt8]? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) ==
                kCVPixelFormatType_32BGRA else {
            return nil
        }

        let frameWidth = CVPixelBufferGetWidth(pixelBuffer)
        let frameHeight = CVPixelBufferGetHeight(pixelBuffer)
        let frameBounds = CGRect(
            x: 0,
            y: 0,
            width: frameWidth,
            height: frameHeight
        )
        let requestedCrop = CGRect(
            x: normalizedCropRect.minX * CGFloat(frameWidth),
            y: normalizedCropRect.minY * CGFloat(frameHeight),
            width: normalizedCropRect.width * CGFloat(frameWidth),
            height: normalizedCropRect.height * CGFloat(frameHeight)
        )
        .integral
        let crop = requestedCrop.intersection(frameBounds)

        guard crop.width > 0, crop.height > 0 else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let pixels = baseAddress.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let minX = max(Int(crop.minX), 0)
        let minY = max(Int(crop.minY), 0)
        let cropWidth = min(Int(crop.maxX), frameWidth) - minX
        let cropHeight = min(Int(crop.maxY), frameHeight) - minY
        var grid = [UInt8](repeating: 0, count: gridWidth * gridHeight)

        for gridY in 0..<gridHeight {
            let relativeY = (Double(gridY) + 0.5) / Double(gridHeight)
            let sourceY = minY + min(
                max(Int(relativeY * Double(cropHeight)), 0),
                cropHeight - 1
            )

            for gridX in 0..<gridWidth {
                let relativeX = (Double(gridX) + 0.5) / Double(gridWidth)
                let normalizedX = (relativeX - 0.5) / 0.5
                let normalizedY = (relativeY - 0.5) / 0.5

                guard normalizedX * normalizedX + normalizedY * normalizedY <= 0.88 * 0.88,
                      relativeY <= 0.89 else {
                    continue
                }

                let sourceX = minX + min(
                    max(Int(relativeX * Double(cropWidth)), 0),
                    cropWidth - 1
                )

                var foundYellow = false
                for offsetY in -2...2 where !foundYellow {
                    let testY = min(max(sourceY + offsetY, minY), minY + cropHeight - 1)
                    for offsetX in -2...2 {
                        let testX = min(max(sourceX + offsetX, minX), minX + cropWidth - 1)
                        let offset = testY * bytesPerRow + testX * 4
                        let blue = Int(pixels[offset])
                        let green = Int(pixels[offset + 1])
                        let red = Int(pixels[offset + 2])

                        if isBrightYellow(red: red, green: green, blue: blue) {
                            foundYellow = true
                            break
                        }
                    }
                }

                if foundYellow {
                    grid[gridY * gridWidth + gridX] = 1
                }
            }
        }

        return grid
    }

    private func isBrightYellow(
        red: Int,
        green: Int,
        blue: Int
    ) -> Bool {
        // Tracking already has a verified route path, so it can use a wider
        // yellow gate than first-pass detection. This retains pale/blurred
        // route pixels after capture-card scaling without inventing a path.
        red >= 155 &&
        green >= 145 &&
        blue <= 145 &&
        red - blue >= 35 &&
        green - blue >= 28 &&
        abs(red - green) <= 95
    }

    // MARK: Candidate Scoring

    private func routeCoverage(
        _ path: [MinimapPoint],
        yellowGrid: [UInt8]
    ) -> Double {
        guard !path.isEmpty else {
            return 0
        }

        let strideAmount = max(1, path.count / 72)
        var matchedWeight = 0.0
        var totalWeight = 0.0

        for pathIndex in stride(
            from: min(2, path.count - 1),
            to: path.count,
            by: strideAmount
        ) {
            let point = path[pathIndex]
            guard point.x >= 0, point.x <= 1, point.y >= 0, point.y <= 1 else {
                continue
            }

            let gridX = min(max(Int(point.x * Double(gridWidth)), 0), gridWidth - 1)
            let gridY = min(max(Int(point.y * Double(gridHeight)), 0), gridHeight - 1)
            let progress = Double(pathIndex) / Double(max(path.count - 1, 1))
            let weight = 1.25 - 0.35 * progress
            totalWeight += weight

            var matched = false
            for offsetY in -1...1 where !matched {
                let testY = gridY + offsetY
                guard testY >= 0, testY < gridHeight else {
                    continue
                }

                for offsetX in -1...1 {
                    let testX = gridX + offsetX
                    guard testX >= 0, testX < gridWidth else {
                        continue
                    }

                    if yellowGrid[testY * gridWidth + testX] != 0 {
                        matched = true
                        break
                    }
                }
            }

            if matched {
                matchedWeight += weight
            }
        }

        return totalWeight > 0 ? matchedWeight / totalWeight : 0
    }

    private func transform(
        _ path: [MinimapPoint],
        around anchor: MinimapPoint,
        rotationDegrees: Double,
        translationX: Double,
        translationY: Double
    ) -> [MinimapPoint] {
        let radians = rotationDegrees * Double.pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)

        return path.map { point in
            let deltaX = point.x - anchor.x
            let deltaY = point.y - anchor.y
            return MinimapPoint(
                x: anchor.x + deltaX * cosine - deltaY * sine + translationX,
                y: anchor.y + deltaX * sine + deltaY * cosine + translationY
            )
        }
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

nonisolated private struct TrackingCandidate {
    let path: [MinimapPoint]
    let coverage: Double
    let rotationDegrees: Double
    let translationX: Double
    let translationY: Double
}
