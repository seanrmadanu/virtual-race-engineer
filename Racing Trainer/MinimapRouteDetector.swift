import CoreGraphics
import CoreVideo
import Foundation

// MARK: - Binary Training Mask

nonisolated struct MinimapRouteMask {
    let width: Int
    let height: Int
    let pixels: Data
}

// MARK: - Diagnostics

nonisolated enum MinimapRouteSource: String, Sendable {
    case none = "NONE"
    case colorGeometry = "COLOR + GEOMETRY"
    case shortRoute = "SHORT ROUTE · VERIFIED"
    case learnedFallback = "LEARNED FALLBACK"
}

nonisolated enum MinimapDetectionDiagnostic: String, Sendable {
    case waiting = "WAITING FOR FRAME"
    case ready = "READY"
    case readyShortRoute = "READY · SHORT ROUTE"
    case readyLearnedFallback = "READY · LEARNED FALLBACK"
    case readyRimFallback = "READY · RIM FALLBACK"
    case unsupportedPixelFormat = "UNSUPPORTED PIXEL FORMAT"
    case invalidCrop = "INVALID MINIMAP CROP"
    case playerShapeRejected = "PLAYER SHAPE REJECTED"
    case minimapStructureRejected = "MINIMAP STRUCTURE REJECTED"
    case routePixelsMissing = "ROUTE PIXELS NOT FOUND"
    case routeGeometryRejected = "ROUTE GEOMETRY REJECTED"
    case routeComponentRejected = "SHORT ROUTE VERIFIER REJECTED"
}

// MARK: - Minimap Route Analysis

nonisolated struct MinimapRouteAnalysis {
    let minimapVisible: Bool
    let minimapConfidence: Float
    let playerDetectionConfidence: Float
    let rimStructureConfidence: Float
    let playerAnchor: MinimapPoint?
    let routeDetected: Bool
    let routeConfidence: Float
    let routeSource: MinimapRouteSource
    let diagnostic: MinimapDetectionDiagnostic
    let cyanPlayerPixelCount: Int
    let yellowCandidatePixelCount: Int
    let learnedCandidatePixelCount: Int
    let shortRouteCandidateFound: Bool
    let shortRouteVerifierConfidence: Float
    let routeMaskPixelCount: Int
    let routeComponentCount: Int
    let ignoredYellowComponentCount: Int
    let routeMaskImage: CGImage?
    let routeMask: MinimapRouteMask?

    static let empty = MinimapRouteAnalysis(
        minimapVisible: false,
        minimapConfidence: 0,
        playerDetectionConfidence: 0,
        rimStructureConfidence: 0,
        playerAnchor: nil,
        routeDetected: false,
        routeConfidence: 0,
        routeSource: .none,
        diagnostic: .waiting,
        cyanPlayerPixelCount: 0,
        yellowCandidatePixelCount: 0,
        learnedCandidatePixelCount: 0,
        shortRouteCandidateFound: false,
        shortRouteVerifierConfidence: 0,
        routeMaskPixelCount: 0,
        routeComponentCount: 0,
        ignoredYellowComponentCount: 0,
        routeMaskImage: nil,
        routeMask: nil
    )
}

// MARK: - Detector

/// Hybrid Motorfest minimap detector.
///
/// 1. Validates a connected cyan player-arrow shape.
/// 2. Uses circular-rim evidence only when the arrow temporarily disappears.
/// 3. Runs the deterministic yellow detector and route geometry first.
/// 4. Recovers valid short route stubs with stricter near-player geometry.
/// 5. Runs the reviewed-mask-trained segmenter only if the primary path fails.
nonisolated final class MinimapRouteDetector {

    private let learnedSegmenter = LearnedRouteSegmenter()
    private let routeComponentVerifier = RouteComponentVerifier()
    private var learnedFallbackWasActive = false
    private var learnedFallbackProbeCounter = 0

    func analyze(
        pixelBuffer: CVPixelBuffer,
        normalizedCropRect: CGRect,
        includeTrainingMask: Bool = false
    ) -> MinimapRouteAnalysis {

        guard CVPixelBufferGetPixelFormatType(pixelBuffer) ==
                kCVPixelFormatType_32BGRA else {
            return failureAnalysis(
                diagnostic: .unsupportedPixelFormat,
                includeTrainingMask: includeTrainingMask
            )
        }

        let frameWidth = CVPixelBufferGetWidth(pixelBuffer)
        let frameHeight = CVPixelBufferGetHeight(pixelBuffer)
        let cropRect = pixelRect(
            normalizedRect: normalizedCropRect,
            frameWidth: frameWidth,
            frameHeight: frameHeight
        )

        guard cropRect.width > 0, cropRect.height > 0 else {
            return failureAnalysis(
                diagnostic: .invalidCrop,
                includeTrainingMask: includeTrainingMask
            )
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return failureAnalysis(
                diagnostic: .invalidCrop,
                includeTrainingMask: includeTrainingMask
            )
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pixels = baseAddress.assumingMemoryBound(to: UInt8.self)
        let minX = max(Int(cropRect.minX), 0)
        let minY = max(Int(cropRect.minY), 0)
        let maxX = min(Int(cropRect.maxX), frameWidth)
        let maxY = min(Int(cropRect.maxY), frameHeight)
        let cropWidth = maxX - minX
        let cropHeight = maxY - minY

        guard cropWidth > 0, cropHeight > 0 else {
            return failureAnalysis(
                diagnostic: .invalidCrop,
                includeTrainingMask: includeTrainingMask
            )
        }

        let pixelCount = cropWidth * cropHeight
        var yellowMask = [UInt8](repeating: 0, count: pixelCount)
        var unrestrictedYellowMask = [UInt8](repeating: 0, count: pixelCount)
        var cyanMask = [UInt8](repeating: 0, count: pixelCount)
        var cyanEvidenceMask = [UInt8](repeating: 0, count: pixelCount)
        var cyanCandidateCount = 0
        var yellowCandidateCount = 0

        for localY in 0..<cropHeight {
            let relativeY = (Double(localY) + 0.5) / Double(cropHeight)
            let normalizedY = (relativeY - 0.5) / 0.5
            let frameY = minY + localY

            for localX in 0..<cropWidth {
                let relativeX = (Double(localX) + 0.5) / Double(cropWidth)
                let normalizedX = (relativeX - 0.5) / 0.5
                let radiusSquared =
                    normalizedX * normalizedX + normalizedY * normalizedY
                let frameX = minX + localX
                let offset = frameY * bytesPerRow + frameX * 4
                let blue = Int(pixels[offset])
                let green = Int(pixels[offset + 1])
                let red = Int(pixels[offset + 2])
                let index = localY * cropWidth + localX

                if isCyanEvidencePixel(red: red, green: green, blue: blue) {
                    cyanEvidenceMask[index] = 1
                }

                let insidePlayerSearch =
                    relativeX >= 0.25 && relativeX <= 0.80 &&
                    relativeY >= 0.48 && relativeY <= 0.93 &&
                    radiusSquared <= 0.94 * 0.94

                if insidePlayerSearch,
                   isCyanPlayerPixel(red: red, green: green, blue: blue) {
                    cyanMask[index] = 1
                    cyanCandidateCount += 1
                }

                let insideRouteSearch =
                    radiusSquared <= 0.88 * 0.88 && relativeY <= 0.89

                if isBrightYellowRoutePixel(red: red, green: green, blue: blue) {
                    unrestrictedYellowMask[index] = 1
                    if insideRouteSearch {
                        yellowMask[index] = 1
                        yellowCandidateCount += 1
                    }
                }
            }
        }

        let expectedPlayerCenter = PixelPoint(
            x: Double(cropWidth) * 0.52,
            y: Double(cropHeight) * 0.76
        )
        let playerDetection = detectPlayer(
            cyanMask: cyanMask,
            width: cropWidth,
            height: cropHeight,
            expectedCenter: expectedPlayerCenter
        )
        let rimDetection = detectMinimapRim(
            pixels: pixels,
            bytesPerRow: bytesPerRow,
            minX: minX,
            minY: minY,
            width: cropWidth,
            height: cropHeight
        )
        let usesRimFallback =
            playerDetection == nil && rimDetection.edgeCoverage >= 0.68
        let minimapVisible = playerDetection != nil || usesRimFallback
        let playerCenter = playerDetection?.center ?? expectedPlayerCenter

        let minimapConfidence: Float
        if let playerDetection {
            minimapConfidence = Float(clampedUnit(
                0.80 * playerDetection.confidence +
                0.20 * max(rimDetection.confidence, 0.30)
            ))
        } else if usesRimFallback {
            minimapConfidence = Float(clampedUnit(
                0.48 + 0.30 * rimDetection.confidence
            ))
        } else {
            minimapConfidence = 0
        }

        guard minimapVisible else {
            learnedFallbackWasActive = false
            learnedFallbackProbeCounter = 0
            let diagnostic: MinimapDetectionDiagnostic =
                cyanCandidateCount > 0
                ? .playerShapeRejected
                : .minimapStructureRejected
            return MinimapRouteAnalysis(
                minimapVisible: false,
                minimapConfidence: 0,
                playerDetectionConfidence: Float(playerDetection?.confidence ?? 0),
                rimStructureConfidence: Float(rimDetection.confidence),
                playerAnchor: nil,
                routeDetected: false,
                routeConfidence: 0,
                routeSource: .none,
                diagnostic: diagnostic,
                cyanPlayerPixelCount: cyanCandidateCount,
                yellowCandidatePixelCount: yellowCandidateCount,
                learnedCandidatePixelCount: 0,
                shortRouteCandidateFound: false,
                shortRouteVerifierConfidence: 0,
                routeMaskPixelCount: 0,
                routeComponentCount: 0,
                ignoredYellowComponentCount: 0,
                routeMaskImage: nil,
                routeMask: includeTrainingMask
                    ? MinimapRouteMask(
                        width: cropWidth,
                        height: cropHeight,
                        pixels: Data(repeating: 0, count: pixelCount)
                    )
                    : nil
            )
        }

        var selection = selectRoute(
            rawMask: yellowMask,
            width: cropWidth,
            height: cropHeight,
            playerCenter: playerCenter,
            permitsShortRoute: false,
            evaluatesNormalRoute: true,
            shortRouteEvidence: nil
        )
        if !selection.detected && playerDetection != nil {
            selection = selectRoute(
                rawMask: unrestrictedYellowMask,
                width: cropWidth,
                height: cropHeight,
                playerCenter: playerCenter,
                permitsShortRoute: true,
                evaluatesNormalRoute: false,
                shortRouteEvidence: nil
            )
        }
        var routeSource: MinimapRouteSource = selection.detected
            ? .colorGeometry
            : .none
        var learnedResult = LearnedRouteSegmentation.empty(pixelCount: pixelCount)

        if selection.detected {
            learnedFallbackWasActive = false
            learnedFallbackProbeCounter = 0
        } else {
            let shouldRunModel =
                !selection.shortRouteCandidateFound &&
                shouldRunLearnedFallback()

            if shouldRunModel {
                learnedResult = learnedSegmenter.segment(
                    pixels: pixels,
                    bytesPerRow: bytesPerRow,
                    minX: minX,
                    minY: minY,
                    cropWidth: cropWidth,
                    cropHeight: cropHeight
                )
            }

            if selection.shortRouteCandidateFound {
                let evidence = ShortRouteEvidence(
                    pixels: pixels,
                    bytesPerRow: bytesPerRow,
                    minX: minX,
                    minY: minY,
                    cyanMask: cyanEvidenceMask
                )
                selection = selectRoute(
                    rawMask: unrestrictedYellowMask,
                    width: cropWidth,
                    height: cropHeight,
                    playerCenter: playerCenter,
                    permitsShortRoute: true,
                    evaluatesNormalRoute: false,
                    shortRouteEvidence: evidence
                )
                if selection.detected {
                    routeSource = .shortRoute
                    learnedFallbackWasActive = false
                    learnedFallbackProbeCounter = 0
                }
            }

            if !selection.detected &&
                shouldRunModel &&
                !selection.shortRouteCandidateFound {
                // The learned mask may recover a normal-length route, but it
                // cannot independently authorize a short route. Short routes
                // require the stricter color-component verifier above. A
                // rejected short component also blocks learned re-entry, so a
                // hard negative cannot be rejected and immediately reaccepted.
                let learnedSelection = selectRoute(
                    rawMask: learnedResult.mask,
                    width: cropWidth,
                    height: cropHeight,
                    playerCenter: playerCenter,
                    permitsShortRoute: false,
                    evaluatesNormalRoute: true,
                    shortRouteEvidence: nil
                )
                if learnedSelection.detected {
                    selection = learnedSelection
                    routeSource = .learnedFallback
                    learnedFallbackWasActive = true
                } else {
                    learnedFallbackWasActive = false
                }
            }
        }

        let routeDetected = selection.detected
        let pixelEvidence: Double
        switch routeSource {
        case .learnedFallback:
            pixelEvidence = Double(learnedResult.meanCandidateProbability)
        case .shortRoute:
            pixelEvidence = Double(selection.shortRouteVerifierProbability)
        case .colorGeometry:
            pixelEvidence = 0.90
        case .none:
            pixelEvidence = 0
        }
        let sourcePenalty = routeSource == .shortRoute ? 0.90 : 1.0
        let routeConfidence = routeDetected
            ? Float(clampedUnit(
                (
                    0.58 * selection.geometryConfidence +
                    0.22 * Double(minimapConfidence) +
                    0.20 * pixelEvidence
                ) * sourcePenalty
            ))
            : 0

        let diagnostic: MinimapDetectionDiagnostic
        if routeDetected {
            if usesRimFallback {
                diagnostic = .readyRimFallback
            } else if routeSource == .learnedFallback {
                diagnostic = .readyLearnedFallback
            } else if routeSource == .shortRoute {
                diagnostic = .readyShortRoute
            } else {
                diagnostic = .ready
            }
        } else if selection.shortRouteCandidateFound {
            diagnostic = .routeComponentRejected
        } else if yellowCandidateCount == 0 &&
                    learnedResult.candidatePixelCount == 0 {
            diagnostic = .routePixelsMissing
        } else {
            diagnostic = .routeGeometryRejected
        }

        let visibleMask = routeDetected
            ? dilate(
                mask: selection.mask,
                width: cropWidth,
                height: cropHeight,
                radius: 2
            )
            : selection.mask
        let playerAnchor = MinimapPoint(
            x: playerCenter.x / Double(max(cropWidth - 1, 1)),
            y: playerCenter.y / Double(max(cropHeight - 1, 1))
        ).clamped()

        return MinimapRouteAnalysis(
            minimapVisible: true,
            minimapConfidence: minimapConfidence,
            playerDetectionConfidence: Float(playerDetection?.confidence ?? 0),
            rimStructureConfidence: Float(rimDetection.confidence),
            playerAnchor: playerAnchor,
            routeDetected: routeDetected,
            routeConfidence: routeConfidence,
            routeSource: routeSource,
            diagnostic: diagnostic,
            cyanPlayerPixelCount: cyanCandidateCount,
            yellowCandidatePixelCount: yellowCandidateCount,
            learnedCandidatePixelCount: learnedResult.candidatePixelCount,
            shortRouteCandidateFound: selection.shortRouteCandidateFound,
            shortRouteVerifierConfidence:
                selection.shortRouteVerifierProbability,
            routeMaskPixelCount: selection.maskPixelCount,
            routeComponentCount: selection.selectedComponentCount,
            ignoredYellowComponentCount: selection.ignoredComponentCount,
            routeMaskImage: routeDetected
                ? makeRouteMaskImage(
                    mask: visibleMask,
                    width: cropWidth,
                    height: cropHeight
                )
                : nil,
            routeMask: includeTrainingMask
                ? MinimapRouteMask(
                    width: cropWidth,
                    height: cropHeight,
                    pixels: Data(selection.mask.map { $0 == 0 ? 0 : 255 })
                )
                : nil
        )
    }

    // MARK: - Player and Map Validation

    private func shouldRunLearnedFallback() -> Bool {
        if learnedFallbackWasActive {
            return true
        }
        let shouldProbe = learnedFallbackProbeCounter == 0
        learnedFallbackProbeCounter = (learnedFallbackProbeCounter + 1) % 8
        return shouldProbe
    }

    private func detectPlayer(
        cyanMask: [UInt8],
        width: Int,
        height: Int,
        expectedCenter: PixelPoint
    ) -> PlayerDetection? {

        let connected = connectedComponents(
            mask: closeSmallGaps(in: cyanMask, width: width, height: height),
            width: width,
            height: height,
            playerCenter: expectedCenter
        )
        let pixelCount = width * height
        let minimumDimension = Double(min(width, height))
        let minimumArea = max(8, Int(Double(pixelCount) * 0.00025))
        let maximumArea = max(minimumArea + 1, Int(Double(pixelCount) * 0.020))

        var best: PlayerDetection?
        for component in connected.components {
            guard component.pixelCount >= minimumArea,
                  component.pixelCount <= maximumArea,
                  component.maximumSpan <= minimumDimension * 0.24,
                  component.fillRatio >= 0.12 else {
                continue
            }

            let center = component.centroid
            let normalizedX = center.x / Double(max(width - 1, 1))
            let normalizedY = center.y / Double(max(height - 1, 1))
            let locationDistance = hypot(
                (normalizedX - 0.54) / 0.35,
                (normalizedY - 0.76) / 0.28
            )
            let targetArea = Double(pixelCount) * 0.0035
            let areaScore = exp(-abs(log(
                Double(max(component.pixelCount, 1)) / max(targetArea, 1)
            )))
            let fillScore = min(component.fillRatio / 0.35, 1)
            let locationScore = max(0, 1 - locationDistance)
            let confidence = clampedUnit(
                0.45 * areaScore +
                0.25 * fillScore +
                0.30 * locationScore
            )

            if best == nil || confidence > best!.confidence {
                best = PlayerDetection(center: center, confidence: confidence)
            }
        }
        return best
    }

    private func detectMinimapRim(
        pixels: UnsafePointer<UInt8>,
        bytesPerRow: Int,
        minX: Int,
        minY: Int,
        width: Int,
        height: Int
    ) -> RimDetection {

        guard width >= 3, height >= 3 else {
            return RimDetection(edgeCoverage: 0, confidence: 0)
        }

        let angleCount = 72
        let radiusCount = 11
        var edgeAngles = 0

        for angleIndex in 0..<angleCount {
            let angle = Double(angleIndex) * 2 * Double.pi / Double(angleCount)
            var strongestGradient = 0.0

            for radiusIndex in 0..<radiusCount {
                let radius = 0.78 +
                    0.16 * Double(radiusIndex) / Double(radiusCount - 1)
                let relativeX = 0.5 + 0.5 * radius * cos(angle)
                let relativeY = 0.5 + 0.5 * radius * sin(angle)
                let localX = min(max(Int(
                    (relativeX * Double(max(width - 1, 1))).rounded()
                ), 1), max(width - 2, 1))
                let localY = min(max(Int(
                    (relativeY * Double(max(height - 1, 1))).rounded()
                ), 1), max(height - 2, 1))

                let left = luma(
                    pixels: pixels,
                    offset: (minY + localY) * bytesPerRow +
                        (minX + localX - 1) * 4
                )
                let right = luma(
                    pixels: pixels,
                    offset: (minY + localY) * bytesPerRow +
                        (minX + localX + 1) * 4
                )
                let top = luma(
                    pixels: pixels,
                    offset: (minY + localY - 1) * bytesPerRow +
                        (minX + localX) * 4
                )
                let bottom = luma(
                    pixels: pixels,
                    offset: (minY + localY + 1) * bytesPerRow +
                        (minX + localX) * 4
                )
                let gradientX = (right - left) * 0.5
                let gradientY = (bottom - top) * 0.5
                strongestGradient = max(
                    strongestGradient,
                    hypot(gradientX, gradientY) / 255
                )
            }

            if strongestGradient >= 0.07 {
                edgeAngles += 1
            }
        }

        let coverage = Double(edgeAngles) / Double(angleCount)
        return RimDetection(
            edgeCoverage: coverage,
            confidence: scaledUnit(value: coverage, low: 0.50, high: 0.85)
        )
    }

    private func luma(
        pixels: UnsafePointer<UInt8>,
        offset: Int
    ) -> Double {
        let blue = Double(pixels[offset])
        let green = Double(pixels[offset + 1])
        let red = Double(pixels[offset + 2])
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    // MARK: - Route Selection

    private func selectRoute(
        rawMask: [UInt8],
        width: Int,
        height: Int,
        playerCenter: PixelPoint,
        permitsShortRoute: Bool,
        evaluatesNormalRoute: Bool,
        shortRouteEvidence: ShortRouteEvidence?
    ) -> RouteSelection {

        guard rawMask.count == width * height, width > 0, height > 0 else {
            return .empty(pixelCount: max(width * height, 0))
        }

        let normalMask = closeSmallGaps(in: rawMask, width: width, height: height)
        let normalComponents = connectedComponents(
            mask: normalMask,
            width: width,
            height: height,
            playerCenter: playerCenter
        )
        let pixelCount = width * height
        let minimumDimension = Double(min(width, height))
        let minimumArea = max(35, Int(Double(pixelCount) * 0.00055))
        let minimumSpan = max(16, minimumDimension * 0.10)
        let minimumReach = max(12, minimumDimension * 0.065)
        let maximumPlayerGap = minimumDimension * 0.34
        let maximumChainGap = minimumDimension * 0.16

        let routeLike = normalComponents.components.filter {
            $0.pixelCount >= minimumArea &&
            $0.maximumSpan >= minimumSpan &&
            $0.radialReach >= minimumReach
        }
        let seed = routeLike
            .filter { $0.minimumPlayerDistance <= maximumPlayerGap }
            .max {
                componentScore($0, minimumDimension: minimumDimension) <
                componentScore($1, minimumDimension: minimumDimension)
            }

        if evaluatesNormalRoute, let seed {
            var selected = [seed]
            var selectedLabels: Set<Int> = [seed.label]
            var changed = true
            while changed {
                changed = false
                for component in routeLike where !selectedLabels.contains(component.label) {
                    if selected.contains(where: {
                        componentGap(component, $0) <= maximumChainGap
                    }) {
                        selected.append(component)
                        selectedLabels.insert(component.label)
                        changed = true
                    }
                }
            }
            return makeSelection(
                componentResult: normalComponents,
                selected: selected,
                selectedLabels: selectedLabels,
                pixelCount: pixelCount,
                geometryConfidence: componentScore(
                    seed,
                    minimumDimension: minimumDimension
                ),
                isShortRoute: false
            )
        }

        guard permitsShortRoute else {
            return emptySelection(
                componentResult: normalComponents,
                pixelCount: pixelCount
            )
        }

        var nearPlayerMask = rawMask
        // Keep this identical to Training/train_route_component_classifier.py.
        // A tighter crop removes the far-end context that distinguishes the
        // OPEN CARA connector from a real short GPS stub.
        let maximumNearPlayerRadius = minimumDimension * 0.24
        for y in 0..<height {
            for x in 0..<width {
                let distance = hypot(
                    Double(x) - playerCenter.x,
                    Double(y) - playerCenter.y
                )
                if distance > maximumNearPlayerRadius {
                    nearPlayerMask[y * width + x] = 0
                }
            }
        }
        let shortClosingRadius = max(2, Int((minimumDimension * 0.009).rounded()))
        let shortMask = closeGaps(
            in: nearPlayerMask,
            width: width,
            height: height,
            radius: shortClosingRadius
        )
        let shortComponents = connectedComponents(
            mask: shortMask,
            width: width,
            height: height,
            playerCenter: playerCenter
        )
        let minimumShortArea = max(20, Int(Double(pixelCount) * 0.00020))
        let minimumShortSpan = max(9, minimumDimension * 0.035)
        let minimumShortReach = max(6, minimumDimension * 0.020)
        let maximumShortGap = minimumDimension * 0.14

        let shortSeed = shortComponents.components
            .filter {
                $0.pixelCount >= minimumShortArea &&
                $0.maximumSpan >= minimumShortSpan &&
                $0.radialReach >= minimumShortReach &&
                $0.minimumPlayerDistance <= maximumShortGap &&
                $0.principalAxisElongation >= 2.15
            }
            .max {
                shortComponentScore($0, minimumDimension: minimumDimension) <
                shortComponentScore($1, minimumDimension: minimumDimension)
            }

        guard let shortSeed else {
            return emptySelection(
                componentResult: normalComponents,
                pixelCount: pixelCount
            )
        }

        guard let shortRouteEvidence,
              let features = shortRouteFeatures(
                component: shortSeed,
                componentLabels: shortComponents.labels,
                width: width,
                height: height,
                playerCenter: playerCenter,
                evidence: shortRouteEvidence
              ) else {
            return emptySelection(
                componentResult: shortComponents,
                pixelCount: pixelCount,
                shortRouteCandidateFound: true
            )
        }
        let verification = routeComponentVerifier.evaluate(features: features)
        guard verification.accepted else {
            return emptySelection(
                componentResult: shortComponents,
                pixelCount: pixelCount,
                shortRouteCandidateFound: true,
                shortRouteVerifierProbability: verification.probability
            )
        }

        return makeSelection(
            componentResult: shortComponents,
            selected: [shortSeed],
            selectedLabels: [shortSeed.label],
            pixelCount: pixelCount,
            geometryConfidence: shortComponentScore(
                shortSeed,
                minimumDimension: minimumDimension
            ),
            isShortRoute: true,
            shortRouteCandidateFound: true,
            shortRouteVerifierProbability: verification.probability
        )
    }

    private func makeSelection(
        componentResult: ConnectedComponentResult,
        selected: [MaskComponent],
        selectedLabels: Set<Int>,
        pixelCount: Int,
        geometryConfidence: Double,
        isShortRoute: Bool,
        shortRouteCandidateFound: Bool = false,
        shortRouteVerifierProbability: Float = 0
    ) -> RouteSelection {

        var mask = [UInt8](repeating: 0, count: pixelCount)
        var maskPixelCount = 0
        for index in componentResult.labels.indices
        where selectedLabels.contains(componentResult.labels[index]) {
            mask[index] = 1
            maskPixelCount += 1
        }
        let ignored = componentResult.components.filter {
            $0.pixelCount >= 10 && !selectedLabels.contains($0.label)
        }.count
        return RouteSelection(
            detected: !selected.isEmpty,
            mask: mask,
            maskPixelCount: maskPixelCount,
            selectedComponentCount: selected.count,
            ignoredComponentCount: ignored,
            geometryConfidence: geometryConfidence,
            isShortRoute: isShortRoute,
            shortRouteCandidateFound: shortRouteCandidateFound,
            shortRouteVerifierProbability: shortRouteVerifierProbability
        )
    }

    private func emptySelection(
        componentResult: ConnectedComponentResult,
        pixelCount: Int,
        shortRouteCandidateFound: Bool = false,
        shortRouteVerifierProbability: Float = 0
    ) -> RouteSelection {
        RouteSelection(
            detected: false,
            mask: [UInt8](repeating: 0, count: pixelCount),
            maskPixelCount: 0,
            selectedComponentCount: 0,
            ignoredComponentCount: componentResult.components.filter {
                $0.pixelCount >= 10
            }.count,
            geometryConfidence: 0,
            isShortRoute: false,
            shortRouteCandidateFound: shortRouteCandidateFound,
            shortRouteVerifierProbability: shortRouteVerifierProbability
        )
    }

    // MARK: - Pixel Classification

    private func isCyanPlayerPixel(red: Int, green: Int, blue: Int) -> Bool {
        green >= 148 &&
        blue >= 148 &&
        min(green, blue) - red >= 41 &&
        abs(green - blue) <= 77
    }

    private func isCyanEvidencePixel(red: Int, green: Int, blue: Int) -> Bool {
        green >= 148 &&
        blue >= 148 &&
        min(green, blue) - red >= 41
    }

    private func isBrightYellowRoutePixel(red: Int, green: Int, blue: Int) -> Bool {
        red >= 185 &&
        green >= 170 &&
        blue <= 115 &&
        red - blue >= 65 &&
        green - blue >= 55 &&
        abs(red - green) <= 75
    }

    // MARK: - Morphology

    private func closeSmallGaps(
        in mask: [UInt8],
        width: Int,
        height: Int
    ) -> [UInt8] {
        closeGaps(in: mask, width: width, height: height, radius: 1)
    }

    private func closeGaps(
        in mask: [UInt8],
        width: Int,
        height: Int,
        radius: Int
    ) -> [UInt8] {
        erode(
            mask: dilate(mask: mask, width: width, height: height, radius: radius),
            width: width,
            height: height,
            radius: radius
        )
    }

    private func dilate(
        mask: [UInt8],
        width: Int,
        height: Int,
        radius: Int
    ) -> [UInt8] {
        guard radius > 0, width > 0, height > 0 else { return mask }
        var result = [UInt8](repeating: 0, count: mask.count)
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] != 0 {
                for neighborY in max(y - radius, 0)...min(y + radius, height - 1) {
                    let row = neighborY * width
                    for neighborX in max(x - radius, 0)...min(x + radius, width - 1) {
                        result[row + neighborX] = 1
                    }
                }
            }
        }
        return result
    }

    private func erode(
        mask: [UInt8],
        width: Int,
        height: Int,
        radius: Int
    ) -> [UInt8] {
        guard radius > 0, width > 0, height > 0 else { return mask }
        var result = [UInt8](repeating: 0, count: mask.count)
        for y in 0..<height {
            for x in 0..<width {
                var allSet = true
                neighborLoop: for neighborY in
                    max(y - radius, 0)...min(y + radius, height - 1) {
                    let row = neighborY * width
                    for neighborX in max(x - radius, 0)...min(x + radius, width - 1) {
                        if mask[row + neighborX] == 0 {
                            allSet = false
                            break neighborLoop
                        }
                    }
                }
                if allSet { result[y * width + x] = 1 }
            }
        }
        return result
    }

    // MARK: - Connected Components

    private func connectedComponents(
        mask: [UInt8],
        width: Int,
        height: Int,
        playerCenter: PixelPoint
    ) -> ConnectedComponentResult {

        guard width > 0, height > 0, mask.count == width * height else {
            return ConnectedComponentResult(labels: [], components: [])
        }
        var labels = [Int](repeating: 0, count: mask.count)
        var components: [MaskComponent] = []
        var nextLabel = 0
        var stack: [Int] = []

        for start in mask.indices where mask[start] != 0 && labels[start] == 0 {
            nextLabel += 1
            labels[start] = nextLabel
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            var component = MaskComponent(
                label: nextLabel,
                pixelCount: 0,
                minX: width,
                maxX: 0,
                minY: height,
                maxY: 0,
                minimumPlayerDistance: .greatestFiniteMagnitude,
                maximumPlayerDistance: 0,
                sumX: 0,
                sumY: 0,
                sumXX: 0,
                sumYY: 0,
                sumXY: 0
            )

            while let index = stack.popLast() {
                let y = index / width
                let x = index - y * width
                let doubleX = Double(x)
                let doubleY = Double(y)
                component.pixelCount += 1
                component.minX = min(component.minX, x)
                component.maxX = max(component.maxX, x)
                component.minY = min(component.minY, y)
                component.maxY = max(component.maxY, y)
                component.sumX += doubleX
                component.sumY += doubleY
                component.sumXX += doubleX * doubleX
                component.sumYY += doubleY * doubleY
                component.sumXY += doubleX * doubleY

                let distance = hypot(
                    doubleX - playerCenter.x,
                    doubleY - playerCenter.y
                )
                component.minimumPlayerDistance = min(
                    component.minimumPlayerDistance,
                    distance
                )
                component.maximumPlayerDistance = max(
                    component.maximumPlayerDistance,
                    distance
                )

                for neighborY in max(y - 1, 0)...min(y + 1, height - 1) {
                    let row = neighborY * width
                    for neighborX in max(x - 1, 0)...min(x + 1, width - 1) {
                        let neighbor = row + neighborX
                        if mask[neighbor] != 0 && labels[neighbor] == 0 {
                            labels[neighbor] = nextLabel
                            stack.append(neighbor)
                        }
                    }
                }
            }
            components.append(component)
        }
        return ConnectedComponentResult(labels: labels, components: components)
    }

    private func componentGap(_ first: MaskComponent, _ second: MaskComponent) -> Double {
        let horizontal: Int
        if first.maxX < second.minX {
            horizontal = second.minX - first.maxX
        } else if second.maxX < first.minX {
            horizontal = first.minX - second.maxX
        } else {
            horizontal = 0
        }
        let vertical: Int
        if first.maxY < second.minY {
            vertical = second.minY - first.maxY
        } else if second.maxY < first.minY {
            vertical = first.minY - second.maxY
        } else {
            vertical = 0
        }
        return hypot(Double(horizontal), Double(vertical))
    }

    private func componentScore(
        _ component: MaskComponent,
        minimumDimension: Double
    ) -> Double {
        guard minimumDimension > 0 else { return 0 }
        let span = clampedUnit(component.maximumSpan / (minimumDimension * 0.28))
        let reach = clampedUnit(component.radialReach / (minimumDimension * 0.25))
        let proximity = 1 - clampedUnit(
            component.minimumPlayerDistance / (minimumDimension * 0.34)
        )
        return clampedUnit(0.45 * span + 0.35 * reach + 0.20 * proximity)
    }

    private func shortComponentScore(
        _ component: MaskComponent,
        minimumDimension: Double
    ) -> Double {
        guard minimumDimension > 0 else { return 0 }
        let span = clampedUnit(component.maximumSpan / (minimumDimension * 0.09))
        let reach = clampedUnit(component.radialReach / (minimumDimension * 0.07))
        let proximity = 1 - clampedUnit(
            component.minimumPlayerDistance / (minimumDimension * 0.14)
        )
        let elongation = scaledUnit(
            value: component.principalAxisElongation,
            low: 2.15,
            high: 7.0
        )
        return clampedUnit(
            0.30 * span + 0.25 * reach + 0.30 * proximity + 0.15 * elongation
        )
    }

    // MARK: - Short Route Verification Features

    private func shortRouteFeatures(
        component: MaskComponent,
        componentLabels: [Int],
        width: Int,
        height: Int,
        playerCenter: PixelPoint,
        evidence: ShortRouteEvidence
    ) -> [Float]? {

        let pixelCount = width * height
        guard width > 0,
              height > 0,
              componentLabels.count == pixelCount,
              evidence.cyanMask.count == pixelCount,
              evidence.bytesPerRow > 0 else {
            return nil
        }

        let minimumDimension = Double(min(width, height))
        guard minimumDimension > 0 else { return nil }

        var area = 0
        var boundaryCount = 0
        var sumRed = 0.0
        var sumGreen = 0.0
        var sumBlue = 0.0
        var sumRedSquared = 0.0
        var sumGreenSquared = 0.0
        var sumBlueSquared = 0.0
        var yellowMarginTotal = 0.0
        var farthestDistance = -1.0
        var farthestX = 0
        var farthestY = 0
        var expandedMask = [UInt8](repeating: 0, count: pixelCount)

        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                guard componentLabels[index] == component.label else { continue }
                area += 1

                let frameOffset =
                    (evidence.minY + y) * evidence.bytesPerRow +
                    (evidence.minX + x) * 4
                let red = Double(evidence.pixels[frameOffset + 2]) / 255
                let green = Double(evidence.pixels[frameOffset + 1]) / 255
                let blue = Double(evidence.pixels[frameOffset]) / 255
                sumRed += red
                sumGreen += green
                sumBlue += blue
                sumRedSquared += red * red
                sumGreenSquared += green * green
                sumBlueSquared += blue * blue
                yellowMarginTotal += min(red, green) - blue

                let playerDistance = hypot(
                    Double(x) - playerCenter.x,
                    Double(y) - playerCenter.y
                )
                if playerDistance > farthestDistance {
                    farthestDistance = playerDistance
                    farthestX = x
                    farthestY = y
                }

                var isBoundary = false
                for neighborY in (y - 1)...(y + 1) {
                    for neighborX in (x - 1)...(x + 1) {
                        guard neighborX >= 0,
                              neighborX < width,
                              neighborY >= 0,
                              neighborY < height else {
                            isBoundary = true
                            continue
                        }
                        if componentLabels[neighborY * width + neighborX] !=
                            component.label {
                            isBoundary = true
                        }
                    }
                }
                if isBoundary { boundaryCount += 1 }

                // scipy's default three-iteration dilation uses a cross-shaped
                // kernel, which is a Manhattan-radius-three diamond.
                for deltaY in -3...3 {
                    let expandedY = y + deltaY
                    guard expandedY >= 0, expandedY < height else { continue }
                    let remainingRadius = 3 - abs(deltaY)
                    for deltaX in -remainingRadius...remainingRadius {
                        let expandedX = x + deltaX
                        guard expandedX >= 0, expandedX < width else { continue }
                        expandedMask[expandedY * width + expandedX] = 1
                    }
                }
            }
        }

        guard area > 0 else { return nil }
        let count = Double(area)
        let meanRed = sumRed / count
        let meanGreen = sumGreen / count
        let meanBlue = sumBlue / count
        let standardRed = sqrt(max(sumRedSquared / count - meanRed * meanRed, 0))
        let standardGreen = sqrt(
            max(sumGreenSquared / count - meanGreen * meanGreen, 0)
        )
        let standardBlue = sqrt(
            max(sumBlueSquared / count - meanBlue * meanBlue, 0)
        )

        let centroid = component.centroid
        let deltaX = (centroid.x - playerCenter.x) / minimumDimension
        let deltaY = (centroid.y - playerCenter.y) / minimumDimension
        let angle = atan2(deltaY, deltaX)

        let farRadius = minimumDimension * 0.065
        let farRadiusSquared = farRadius * farRadius
        let minimumFarX = max(Int(floor(Double(farthestX) - farRadius)), 0)
        let maximumFarX = min(Int(ceil(Double(farthestX) + farRadius)), width - 1)
        let minimumFarY = max(Int(floor(Double(farthestY) - farRadius)), 0)
        let maximumFarY = min(Int(ceil(Double(farthestY) + farRadius)), height - 1)
        var farPixelCount = 0
        var whiteFarPixelCount = 0
        if minimumFarX <= maximumFarX && minimumFarY <= maximumFarY {
            for y in minimumFarY...maximumFarY {
                for x in minimumFarX...maximumFarX {
                    let squaredDistance =
                        pow(Double(x - farthestX), 2) +
                        pow(Double(y - farthestY), 2)
                    guard squaredDistance <= farRadiusSquared else { continue }
                    farPixelCount += 1
                    let frameOffset =
                        (evidence.minY + y) * evidence.bytesPerRow +
                        (evidence.minX + x) * 4
                    let red = Double(evidence.pixels[frameOffset + 2]) / 255
                    let green = Double(evidence.pixels[frameOffset + 1]) / 255
                    let blue = Double(evidence.pixels[frameOffset]) / 255
                    let maximumChannel = max(red, max(green, blue))
                    let minimumChannel = min(red, min(green, blue))
                    let saturation =
                        (maximumChannel - minimumChannel) /
                        max(maximumChannel, 0.00001)
                    if maximumChannel >= 0.68 && saturation <= 0.28 {
                        whiteFarPixelCount += 1
                    }
                }
            }
        }

        var expandedPixelCount = 0
        var adjacentCyanPixelCount = 0
        for index in expandedMask.indices where expandedMask[index] != 0 {
            expandedPixelCount += 1
            if evidence.cyanMask[index] != 0 {
                adjacentCyanPixelCount += 1
            }
        }

        let whiteFarFraction =
            Double(whiteFarPixelCount) / Double(max(farPixelCount, 1))
        let cyanAdjacency =
            Double(adjacentCyanPixelCount) /
            Double(max(expandedPixelCount, 1))

        return [
            Float(log1p(count) / 10),
            Float(count / Double(pixelCount) * 1_000),
            Float(component.maximumSpan / minimumDimension),
            Float(Double(min(component.width, component.height)) / minimumDimension),
            Float(component.fillRatio),
            Float(log1p(component.principalAxisElongation) / 6),
            Float(component.minimumPlayerDistance / minimumDimension),
            Float(component.maximumPlayerDistance / minimumDimension),
            Float(component.radialReach / minimumDimension),
            Float(deltaX),
            Float(deltaY),
            Float(cos(angle)),
            Float(sin(angle)),
            Float(Double(boundaryCount) / max(sqrt(count), 1) / 10),
            Float(meanRed),
            Float(meanGreen),
            Float(meanBlue),
            Float(standardRed),
            Float(standardGreen),
            Float(standardBlue),
            Float(yellowMarginTotal / count),
            Float(whiteFarFraction),
            Float(cyanAdjacency)
        ]
    }

    // MARK: - Mask Image

    private func makeRouteMaskImage(
        mask: [UInt8],
        width: Int,
        height: Int
    ) -> CGImage? {
        guard width > 0, height > 0, mask.count == width * height else { return nil }
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let alpha: UInt8 = 210
        var rgba = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        for index in mask.indices where mask[index] != 0 {
            let output = index * bytesPerPixel
            rgba[output] = alpha
            rgba[output + 1] = 25
            rgba[output + 2] = 150
            rgba[output + 3] = alpha
        }
        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    // MARK: - Helpers

    private func pixelRect(
        normalizedRect: CGRect,
        frameWidth: Int,
        frameHeight: Int
    ) -> CGRect {
        let bounds = CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight)
        return CGRect(
            x: normalizedRect.minX * CGFloat(frameWidth),
            y: normalizedRect.minY * CGFloat(frameHeight),
            width: normalizedRect.width * CGFloat(frameWidth),
            height: normalizedRect.height * CGFloat(frameHeight)
        )
        .integral
        .intersection(bounds)
    }

    private func failureAnalysis(
        diagnostic: MinimapDetectionDiagnostic,
        includeTrainingMask: Bool
    ) -> MinimapRouteAnalysis {
        MinimapRouteAnalysis(
            minimapVisible: false,
            minimapConfidence: 0,
            playerDetectionConfidence: 0,
            rimStructureConfidence: 0,
            playerAnchor: nil,
            routeDetected: false,
            routeConfidence: 0,
            routeSource: .none,
            diagnostic: diagnostic,
            cyanPlayerPixelCount: 0,
            yellowCandidatePixelCount: 0,
            learnedCandidatePixelCount: 0,
            shortRouteCandidateFound: false,
            shortRouteVerifierConfidence: 0,
            routeMaskPixelCount: 0,
            routeComponentCount: 0,
            ignoredYellowComponentCount: 0,
            routeMaskImage: nil,
            routeMask: includeTrainingMask
                ? MinimapRouteMask(width: 0, height: 0, pixels: Data())
                : nil
        )
    }

    private func clampedUnit(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private func scaledUnit(value: Double, low: Double, high: Double) -> Double {
        guard high > low else { return 0 }
        return clampedUnit((value - low) / (high - low))
    }
}

// MARK: - Private Data

nonisolated private struct RouteSelection {
    let detected: Bool
    let mask: [UInt8]
    let maskPixelCount: Int
    let selectedComponentCount: Int
    let ignoredComponentCount: Int
    let geometryConfidence: Double
    let isShortRoute: Bool
    let shortRouteCandidateFound: Bool
    let shortRouteVerifierProbability: Float

    static func empty(pixelCount: Int) -> RouteSelection {
        RouteSelection(
            detected: false,
            mask: [UInt8](repeating: 0, count: max(pixelCount, 0)),
            maskPixelCount: 0,
            selectedComponentCount: 0,
            ignoredComponentCount: 0,
            geometryConfidence: 0,
            isShortRoute: false,
            shortRouteCandidateFound: false,
            shortRouteVerifierProbability: 0
        )
    }
}

nonisolated private struct PlayerDetection {
    let center: PixelPoint
    let confidence: Double
}

nonisolated private struct RimDetection {
    let edgeCoverage: Double
    let confidence: Double
}

nonisolated private struct ShortRouteEvidence {
    let pixels: UnsafePointer<UInt8>
    let bytesPerRow: Int
    let minX: Int
    let minY: Int
    let cyanMask: [UInt8]
}

nonisolated private struct ConnectedComponentResult {
    let labels: [Int]
    let components: [MaskComponent]
}

nonisolated private struct PixelPoint {
    let x: Double
    let y: Double
}

nonisolated private struct MaskComponent {
    let label: Int
    var pixelCount: Int
    var minX: Int
    var maxX: Int
    var minY: Int
    var maxY: Int
    var minimumPlayerDistance: Double
    var maximumPlayerDistance: Double
    var sumX: Double
    var sumY: Double
    var sumXX: Double
    var sumYY: Double
    var sumXY: Double

    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }
    var maximumSpan: Double { Double(max(width, height)) }
    var radialReach: Double {
        max(maximumPlayerDistance - minimumPlayerDistance, 0)
    }
    var fillRatio: Double {
        Double(pixelCount) / Double(max(width * height, 1))
    }
    var centroid: PixelPoint {
        PixelPoint(
            x: sumX / Double(max(pixelCount, 1)),
            y: sumY / Double(max(pixelCount, 1))
        )
    }
    var principalAxisElongation: Double {
        guard pixelCount > 1 else { return 1 }
        let count = Double(pixelCount)
        let meanX = sumX / count
        let meanY = sumY / count
        let covarianceXX = max(sumXX / count - meanX * meanX, 0)
        let covarianceYY = max(sumYY / count - meanY * meanY, 0)
        let covarianceXY = sumXY / count - meanX * meanY
        let trace = covarianceXX + covarianceYY
        let discriminant = sqrt(max(
            (covarianceXX - covarianceYY) * (covarianceXX - covarianceYY) +
            4 * covarianceXY * covarianceXY,
            0
        ))
        let major = max((trace + discriminant) * 0.5, 0)
        let minor = max((trace - discriminant) * 0.5, 0)
        return (major + 0.001) / (minor + 0.001)
    }
}
