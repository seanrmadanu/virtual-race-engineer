import CoreGraphics
import CoreVideo
import Foundation

// MARK: - Minimap Route Analysis

nonisolated struct MinimapRouteAnalysis {

    let minimapVisible:
        Bool

    let minimapConfidence:
        Float

    let routeDetected:
        Bool

    let routeConfidence:
        Float

    let cyanPlayerPixelCount:
        Int

    let yellowCandidatePixelCount:
        Int

    let routeMaskPixelCount:
        Int

    let routeComponentCount:
        Int

    let ignoredYellowComponentCount:
        Int

    let routeMaskImage:
        CGImage?

    static let empty =
        MinimapRouteAnalysis(
            minimapVisible:
                false,
            minimapConfidence:
                0,
            routeDetected:
                false,
            routeConfidence:
                0,
            cyanPlayerPixelCount:
                0,
            yellowCandidatePixelCount:
                0,
            routeMaskPixelCount:
                0,
            routeComponentCount:
                0,
            ignoredYellowComponentCount:
                0,
            routeMaskImage:
                nil
        )
}


// MARK: - Minimap Route Detector

/// First-pass Motorfest route-mask detector.
///
/// This detector deliberately separates three visually similar things:
///
/// - the bright cyan local-player arrow;
/// - the long yellow GPS trail;
/// - compact yellow player arrows and unrelated yellow scenery.
///
/// It is a deterministic bootstrap detector, not the final trained model.
/// Its generated masks can later be reviewed and used to train the small
/// segmentation model without manually tracing every frame from scratch.
nonisolated final class MinimapRouteDetector {

    // MARK: - Analyze

    func analyze(
        pixelBuffer:
            CVPixelBuffer,
        normalizedCropRect:
            CGRect
    ) -> MinimapRouteAnalysis {

        guard CVPixelBufferGetPixelFormatType(
            pixelBuffer
        ) == kCVPixelFormatType_32BGRA else {

            return .empty
        }

        let frameWidth =
            CVPixelBufferGetWidth(
                pixelBuffer
            )

        let frameHeight =
            CVPixelBufferGetHeight(
                pixelBuffer
            )

        let cropRect =
            pixelRect(
                normalizedRect:
                    normalizedCropRect,
                frameWidth:
                    frameWidth,
                frameHeight:
                    frameHeight
            )

        guard cropRect.width > 0,
              cropRect.height > 0 else {

            return .empty
        }

        CVPixelBufferLockBaseAddress(
            pixelBuffer,
            .readOnly
        )

        defer {
            CVPixelBufferUnlockBaseAddress(
                pixelBuffer,
                .readOnly
            )
        }

        guard let baseAddress =
                CVPixelBufferGetBaseAddress(
                    pixelBuffer
                ) else {

            return .empty
        }

        let bytesPerRow =
            CVPixelBufferGetBytesPerRow(
                pixelBuffer
            )

        let pixels =
            baseAddress.assumingMemoryBound(
                to:
                    UInt8.self
            )

        let minX =
            max(
                Int(cropRect.minX),
                0
            )

        let minY =
            max(
                Int(cropRect.minY),
                0
            )

        let maxX =
            min(
                Int(cropRect.maxX),
                frameWidth
            )

        let maxY =
            min(
                Int(cropRect.maxY),
                frameHeight
            )

        let cropWidth =
            maxX -
            minX

        let cropHeight =
            maxY -
            minY

        guard cropWidth > 0,
              cropHeight > 0 else {

            return .empty
        }

        let pixelCount =
            cropWidth *
            cropHeight

        var yellowMask =
            [UInt8](
                repeating:
                    0,
                count:
                    pixelCount
            )

        var cyanPixelCount =
            0

        var cyanXTotal =
            0.0

        var cyanYTotal =
            0.0

        var yellowCandidatePixelCount =
            0

        for localY in 0..<cropHeight {
            let relativeY =
                (
                    Double(localY) +
                    0.5
                ) /
                Double(cropHeight)

            let normalizedY =
                (
                    relativeY -
                    0.5
                ) /
                0.5

            let frameY =
                minY +
                localY

            for localX in 0..<cropWidth {
                let relativeX =
                    (
                        Double(localX) +
                        0.5
                    ) /
                    Double(cropWidth)

                let normalizedX =
                    (
                        relativeX -
                        0.5
                    ) /
                    0.5

                let radiusSquared =
                    normalizedX *
                    normalizedX +
                    normalizedY *
                    normalizedY

                let frameX =
                    minX +
                    localX

                let pixelOffset =
                    frameY *
                    bytesPerRow +
                    frameX *
                    4

                let blue =
                    Int(
                        pixels[
                            pixelOffset
                        ]
                    )

                let green =
                    Int(
                        pixels[
                            pixelOffset +
                            1
                        ]
                    )

                let red =
                    Int(
                        pixels[
                            pixelOffset +
                            2
                        ]
                    )

                // The local player stays near the center/lower portion
                // of Motorfest's rotating minimap. A tighter cyan test
                // prevents blue water or UI scenery from becoming the
                // player anchor.
                let insidePlayerSearchRegion =
                    relativeX >= 0.30 &&
                    relativeX <= 0.70 &&
                    relativeY >= 0.53 &&
                    relativeY <= 0.90 &&
                    radiusSquared <=
                        0.92 *
                        0.92

                if insidePlayerSearchRegion,
                   isCyanPlayerPixel(
                    red:
                        red,
                    green:
                        green,
                    blue:
                        blue
                   ) {

                    cyanPixelCount +=
                        1

                    cyanXTotal +=
                        Double(localX)

                    cyanYTotal +=
                        Double(localY)
                }

                // The route may touch much of the minimap, but the
                // circular boundary and lower OPEN CARA prompt are not
                // route evidence. The inner-radius rule also rejects the
                // bright yellow ring seen in the no-waypoint recording.
                let insideRouteSearchRegion =
                    radiusSquared <=
                        0.88 *
                        0.88 &&
                    relativeY <=
                        0.89

                if insideRouteSearchRegion,
                   isBrightYellowRoutePixel(
                    red:
                        red,
                    green:
                        green,
                    blue:
                        blue
                   ) {

                    let maskIndex =
                        localY *
                        cropWidth +
                        localX

                    yellowMask[
                        maskIndex
                    ] =
                        1

                    yellowCandidatePixelCount +=
                        1
                }
            }
        }

        let minimumCyanPixelCount =
            max(
                35,
                Int(
                    Double(pixelCount) *
                    0.00045
                )
            )

        let minimapVisible =
            cyanPixelCount >=
            minimumCyanPixelCount

        let cyanRatio =
            Double(cyanPixelCount) /
            Double(
                max(
                    pixelCount,
                    1
                )
            )

        let minimapConfidence =
            scaledConfidence(
                value:
                    cyanRatio,
                low:
                    0.00035,
                high:
                    0.0030
            )

        let playerCenter:
            PixelPoint

        if minimapVisible,
           cyanPixelCount > 0 {

            playerCenter =
                PixelPoint(
                    x:
                        cyanXTotal /
                        Double(cyanPixelCount),
                    y:
                        cyanYTotal /
                        Double(cyanPixelCount)
                )

        } else {
            // Used only for stable component statistics. Route output is
            // still forced off whenever the minimap itself is missing.
            playerCenter =
                PixelPoint(
                    x:
                        Double(cropWidth) *
                        0.52,
                    y:
                        Double(cropHeight) *
                        0.76
                )
        }

        let connectedMask =
            closeSmallGaps(
                in:
                    yellowMask,
                width:
                    cropWidth,
                height:
                    cropHeight
            )

        let componentResult =
            connectedComponents(
                mask:
                    connectedMask,
                width:
                    cropWidth,
                height:
                    cropHeight,
                playerCenter:
                    playerCenter
            )

        let minimumDimension =
            Double(
                min(
                    cropWidth,
                    cropHeight
                )
            )

        let minimumRouteArea =
            max(
                35,
                Int(
                    Double(pixelCount) *
                    0.00055
                )
            )

        let minimumRouteSpan =
            max(
                16.0,
                minimumDimension *
                0.10
            )

        let minimumRouteReach =
            max(
                12.0,
                minimumDimension *
                0.065
            )

        let maximumPlayerGap =
            minimumDimension *
            0.34

        let maximumChainGap =
            minimumDimension *
            0.16

        let routeLikeComponents =
            componentResult
                .components
                .filter { component in

                    component.pixelCount >=
                        minimumRouteArea &&
                    component.maximumSpan >=
                        minimumRouteSpan &&
                    component.radialReach >=
                        minimumRouteReach
                }

        var selectedComponents =
            minimapVisible
            ? routeLikeComponents.filter {
                $0.minimumPlayerDistance <=
                    maximumPlayerGap
            }
            : []

        var selectedLabels =
            Set(
                selectedComponents.map(
                    \.label
                )
            )

        // A white checkpoint circle can temporarily split one GPS route
        // into two or more yellow components. Starting at the component
        // nearest the cyan player, follow only other route-shaped pieces
        // separated by a small gap. This recovers the trail beyond the
        // checkpoint without accepting isolated yellow player arrows.
        if !selectedComponents.isEmpty {
            var addedComponent =
                true

            while addedComponent {
                addedComponent =
                    false

                for component in
                    routeLikeComponents {

                    guard !selectedLabels.contains(
                        component.label
                    ) else {

                        continue
                    }

                    let connectsToRoute =
                        selectedComponents.contains {
                            selectedComponent in

                            componentGap(
                                component,
                                selectedComponent
                            ) <=
                            maximumChainGap
                        }

                    if connectsToRoute {
                        selectedComponents.append(
                            component
                        )

                        selectedLabels.insert(
                            component.label
                        )

                        addedComponent =
                            true
                    }
                }
            }
        }

        let routeDetected =
            minimapVisible &&
            !selectedComponents.isEmpty

        let routeConfidence:
            Float

        if routeDetected,
           let bestComponent =
            selectedComponents.max(
                by: {
                    componentScore(
                        $0,
                        minimumDimension:
                            minimumDimension
                    ) <
                    componentScore(
                        $1,
                        minimumDimension:
                            minimumDimension
                    )
                }
           ) {

            routeConfidence =
                Float(
                    componentScore(
                        bestComponent,
                        minimumDimension:
                            minimumDimension
                    )
                )

        } else {
            routeConfidence =
                0
        }

        var routeMask =
            [UInt8](
                repeating:
                    0,
                count:
                    pixelCount
            )

        var routeMaskPixelCount =
            0

        if routeDetected {
            for index in
                componentResult.labels.indices {

                if selectedLabels.contains(
                    componentResult.labels[
                        index
                    ]
                ) {

                    routeMask[
                        index
                    ] =
                        1

                    routeMaskPixelCount +=
                        1
                }
            }
        }

        let ignoredYellowComponentCount =
            componentResult
                .components
                .filter {
                    $0.pixelCount >=
                        10 &&
                    !selectedLabels.contains(
                        $0.label
                    )
                }
                .count

        let visibleRouteMask =
            routeDetected
            ? dilate(
                mask:
                    routeMask,
                width:
                    cropWidth,
                height:
                    cropHeight,
                radius:
                    2
            )
            : routeMask

        return MinimapRouteAnalysis(
            minimapVisible:
                minimapVisible,
            minimapConfidence:
                minimapVisible
                ? minimapConfidence
                : 0,
            routeDetected:
                routeDetected,
            routeConfidence:
                routeConfidence,
            cyanPlayerPixelCount:
                cyanPixelCount,
            yellowCandidatePixelCount:
                yellowCandidatePixelCount,
            routeMaskPixelCount:
                routeMaskPixelCount,
            routeComponentCount:
                routeDetected
                ? selectedComponents.count
                : 0,
            ignoredYellowComponentCount:
                ignoredYellowComponentCount,
            routeMaskImage:
                routeDetected
                ? makeRouteMaskImage(
                    mask:
                        visibleRouteMask,
                    width:
                        cropWidth,
                    height:
                        cropHeight
                )
                : nil
        )
    }


    // MARK: - Pixel Classification

    private func isCyanPlayerPixel(
        red:
            Int,
        green:
            Int,
        blue:
            Int
    ) -> Bool {

        guard green >= 175,
              blue >= 175,
              red <= 125 else {

            return false
        }

        guard green - red >= 50,
              blue - red >= 50 else {

            return false
        }

        return abs(
            green -
            blue
        ) <= 55
    }

    private func isBrightYellowRoutePixel(
        red:
            Int,
        green:
            Int,
        blue:
            Int
    ) -> Bool {

        guard red >= 185,
              green >= 170,
              blue <= 115 else {

            return false
        }

        guard red - blue >= 65,
              green - blue >= 55 else {

            return false
        }

        // Gameplay road paint in the supplied clips is less saturated
        // and darker than Motorfest's neon GPS trail.
        return abs(
            red -
            green
        ) <= 75
    }


    // MARK: - Binary Morphology

    private func closeSmallGaps(
        in mask:
            [UInt8],
        width:
            Int,
        height:
            Int
    ) -> [UInt8] {

        let expanded =
            dilate(
                mask:
                    mask,
                width:
                    width,
                height:
                    height,
                radius:
                    1
            )

        return erode(
            mask:
                expanded,
            width:
                width,
            height:
                height,
            radius:
                1
        )
    }

    private func dilate(
        mask:
            [UInt8],
        width:
            Int,
        height:
            Int,
        radius:
            Int
    ) -> [UInt8] {

        guard radius > 0,
              width > 0,
              height > 0 else {

            return mask
        }

        var result =
            [UInt8](
                repeating:
                    0,
                count:
                    mask.count
            )

        for y in 0..<height {
            for x in 0..<width {
                let index =
                    y *
                    width +
                    x

                guard mask[
                    index
                ] != 0 else {

                    continue
                }

                let startY =
                    max(
                        y -
                        radius,
                        0
                    )

                let endY =
                    min(
                        y +
                        radius,
                        height -
                        1
                    )

                let startX =
                    max(
                        x -
                        radius,
                        0
                    )

                let endX =
                    min(
                        x +
                        radius,
                        width -
                        1
                    )

                for neighborY in
                    startY...endY {

                    let rowOffset =
                        neighborY *
                        width

                    for neighborX in
                        startX...endX {

                        result[
                            rowOffset +
                            neighborX
                        ] =
                            1
                    }
                }
            }
        }

        return result
    }

    private func erode(
        mask:
            [UInt8],
        width:
            Int,
        height:
            Int,
        radius:
            Int
    ) -> [UInt8] {

        guard radius > 0,
              width > 0,
              height > 0 else {

            return mask
        }

        var result =
            [UInt8](
                repeating:
                    0,
                count:
                    mask.count
            )

        for y in 0..<height {
            for x in 0..<width {
                let startY =
                    max(
                        y -
                        radius,
                        0
                    )

                let endY =
                    min(
                        y +
                        radius,
                        height -
                        1
                    )

                let startX =
                    max(
                        x -
                        radius,
                        0
                    )

                let endX =
                    min(
                        x +
                        radius,
                        width -
                        1
                    )

                var everyNeighborIsSet =
                    true

                neighborLoop:
                for neighborY in
                    startY...endY {

                    let rowOffset =
                        neighborY *
                        width

                    for neighborX in
                        startX...endX {

                        if mask[
                            rowOffset +
                            neighborX
                        ] == 0 {

                            everyNeighborIsSet =
                                false

                            break neighborLoop
                        }
                    }
                }

                if everyNeighborIsSet {
                    result[
                        y *
                        width +
                        x
                    ] =
                        1
                }
            }
        }

        return result
    }


    // MARK: - Connected Components

    private func connectedComponents(
        mask:
            [UInt8],
        width:
            Int,
        height:
            Int,
        playerCenter:
            PixelPoint
    ) -> ConnectedComponentResult {

        guard width > 0,
              height > 0,
              mask.count ==
                width *
                height else {

            return ConnectedComponentResult(
                labels:
                    [],
                components:
                    []
            )
        }

        var labels =
            [Int](
                repeating:
                    0,
                count:
                    mask.count
            )

        var components:
            [YellowComponent] = []

        var nextLabel =
            0

        var stack:
            [Int] = []

        for startIndex in
            mask.indices {

            guard mask[
                startIndex
            ] != 0,
            labels[
                startIndex
            ] == 0 else {

                continue
            }

            nextLabel +=
                1

            labels[
                startIndex
            ] =
                nextLabel

            stack.removeAll(
                keepingCapacity:
                    true
            )

            stack.append(
                startIndex
            )

            var component =
                YellowComponent(
                    label:
                        nextLabel,
                    pixelCount:
                        0,
                    minX:
                        width,
                    maxX:
                        0,
                    minY:
                        height,
                    maxY:
                        0,
                    minimumPlayerDistance:
                        .greatestFiniteMagnitude,
                    maximumPlayerDistance:
                        0
                )

            while let index =
                stack.popLast() {

                let y =
                    index /
                    width

                let x =
                    index -
                    y *
                    width

                component.pixelCount +=
                    1

                component.minX =
                    min(
                        component.minX,
                        x
                    )

                component.maxX =
                    max(
                        component.maxX,
                        x
                    )

                component.minY =
                    min(
                        component.minY,
                        y
                    )

                component.maxY =
                    max(
                        component.maxY,
                        y
                    )

                let deltaX =
                    Double(x) -
                    playerCenter.x

                let deltaY =
                    Double(y) -
                    playerCenter.y

                let playerDistance =
                    sqrt(
                        deltaX *
                        deltaX +
                        deltaY *
                        deltaY
                    )

                component.minimumPlayerDistance =
                    min(
                        component.minimumPlayerDistance,
                        playerDistance
                    )

                component.maximumPlayerDistance =
                    max(
                        component.maximumPlayerDistance,
                        playerDistance
                    )

                let startNeighborY =
                    max(
                        y -
                        1,
                        0
                    )

                let endNeighborY =
                    min(
                        y +
                        1,
                        height -
                        1
                    )

                let startNeighborX =
                    max(
                        x -
                        1,
                        0
                    )

                let endNeighborX =
                    min(
                        x +
                        1,
                        width -
                        1
                    )

                for neighborY in
                    startNeighborY...endNeighborY {

                    let rowOffset =
                        neighborY *
                        width

                    for neighborX in
                        startNeighborX...endNeighborX {

                        let neighborIndex =
                            rowOffset +
                            neighborX

                        guard mask[
                            neighborIndex
                        ] != 0,
                        labels[
                            neighborIndex
                        ] == 0 else {

                            continue
                        }

                        labels[
                            neighborIndex
                        ] =
                            nextLabel

                        stack.append(
                            neighborIndex
                        )
                    }
                }
            }

            components.append(
                component
            )
        }

        return ConnectedComponentResult(
            labels:
                labels,
            components:
                components
        )
    }

    private func componentGap(
        _ first:
            YellowComponent,
        _ second:
            YellowComponent
    ) -> Double {

        let horizontalGap:
            Int

        if first.maxX <
            second.minX {

            horizontalGap =
                second.minX -
                first.maxX

        } else if second.maxX <
                    first.minX {

            horizontalGap =
                first.minX -
                second.maxX

        } else {
            horizontalGap =
                0
        }

        let verticalGap:
            Int

        if first.maxY <
            second.minY {

            verticalGap =
                second.minY -
                first.maxY

        } else if second.maxY <
                    first.minY {

            verticalGap =
                first.minY -
                second.maxY

        } else {
            verticalGap =
                0
        }

        let deltaX =
            Double(
                horizontalGap
            )

        let deltaY =
            Double(
                verticalGap
            )

        return sqrt(
            deltaX *
            deltaX +
            deltaY *
            deltaY
        )
    }

    private func componentScore(
        _ component:
            YellowComponent,
        minimumDimension:
            Double
    ) -> Double {

        guard minimumDimension > 0 else {
            return 0
        }

        let spanScore =
            clampedUnit(
                component.maximumSpan /
                (
                    minimumDimension *
                    0.28
                )
            )

        let reachScore =
            clampedUnit(
                component.radialReach /
                (
                    minimumDimension *
                    0.25
                )
            )

        let proximityScore =
            1.0 -
            clampedUnit(
                component.minimumPlayerDistance /
                (
                    minimumDimension *
                    0.34
                )
            )

        return clampedUnit(
            0.45 *
            spanScore +
            0.35 *
            reachScore +
            0.20 *
            proximityScore
        )
    }


    // MARK: - Mask Image

    private func makeRouteMaskImage(
        mask:
            [UInt8],
        width:
            Int,
        height:
            Int
    ) -> CGImage? {

        guard width > 0,
              height > 0,
              mask.count ==
                width *
                height else {

            return nil
        }

        let bytesPerPixel =
            4

        let bytesPerRow =
            width *
            bytesPerPixel

        let overlayAlpha:
            UInt8 = 210

        var rgba =
            [UInt8](
                repeating:
                    0,
                count:
                    width *
                    height *
                    bytesPerPixel
            )

        for index in
            mask.indices where
            mask[
                index
            ] != 0 {

            let outputIndex =
                index *
                bytesPerPixel

            // Premultiplied magenta. It is intentionally different from
            // every Motorfest HUD color so false masks are obvious.
            rgba[
                outputIndex
            ] =
                overlayAlpha

            rgba[
                outputIndex +
                1
            ] =
                25

            rgba[
                outputIndex +
                2
            ] =
                150

            rgba[
                outputIndex +
                3
            ] =
                overlayAlpha
        }

        let data =
            Data(
                rgba
            )

        guard let provider =
                CGDataProvider(
                    data:
                        data as CFData
                ) else {

            return nil
        }

        let bitmapInfo =
            CGBitmapInfo
                .byteOrder32Big
                .union(
                    CGBitmapInfo(
                        rawValue:
                            CGImageAlphaInfo
                                .premultipliedLast
                                .rawValue
                    )
                )

        return CGImage(
            width:
                width,
            height:
                height,
            bitsPerComponent:
                8,
            bitsPerPixel:
                32,
            bytesPerRow:
                bytesPerRow,
            space:
                CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:
                bitmapInfo,
            provider:
                provider,
            decode:
                nil,
            shouldInterpolate:
                false,
            intent:
                .defaultIntent
        )
    }


    // MARK: - Geometry and Confidence

    private func pixelRect(
        normalizedRect:
            CGRect,
        frameWidth:
            Int,
        frameHeight:
            Int
    ) -> CGRect {

        let frameBounds =
            CGRect(
                x:
                    0,
                y:
                    0,
                width:
                    frameWidth,
                height:
                    frameHeight
            )

        let requestedRect =
            CGRect(
                x:
                    normalizedRect.minX *
                    CGFloat(frameWidth),
                y:
                    normalizedRect.minY *
                    CGFloat(frameHeight),
                width:
                    normalizedRect.width *
                    CGFloat(frameWidth),
                height:
                    normalizedRect.height *
                    CGFloat(frameHeight)
            )
            .integral

        return requestedRect
            .intersection(
                frameBounds
            )
    }

    private func scaledConfidence(
        value:
            Double,
        low:
            Double,
        high:
            Double
    ) -> Float {

        guard high > low else {
            return 0
        }

        return Float(
            clampedUnit(
                (
                    value -
                    low
                ) /
                (
                    high -
                    low
                )
            )
        )
    }

    private func clampedUnit(
        _ value:
            Double
    ) -> Double {

        min(
            max(
                value,
                0
            ),
            1
        )
    }
}


// MARK: - Component Data

nonisolated private struct ConnectedComponentResult {

    let labels:
        [Int]

    let components:
        [YellowComponent]
}

nonisolated private struct PixelPoint {

    let x:
        Double

    let y:
        Double
}

nonisolated private struct YellowComponent {

    let label:
        Int

    var pixelCount:
        Int

    var minX:
        Int

    var maxX:
        Int

    var minY:
        Int

    var maxY:
        Int

    var minimumPlayerDistance:
        Double

    var maximumPlayerDistance:
        Double

    var width:
        Int {

        maxX -
        minX +
        1
    }

    var height:
        Int {

        maxY -
        minY +
        1
    }

    var maximumSpan:
        Double {

        Double(
            max(
                width,
                height
            )
        )
    }

    var radialReach:
        Double {

        max(
            maximumPlayerDistance -
            minimumPlayerDistance,
            0
        )
    }
}
