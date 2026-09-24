import Foundation

nonisolated struct LearnedRouteSegmentation {

    let mask: [UInt8]
    let candidatePixelCount: Int
    let meanCandidateProbability: Float
    let maximumProbability: Float

    static func empty(pixelCount: Int) -> LearnedRouteSegmentation {
        LearnedRouteSegmentation(
            mask: [UInt8](repeating: 0, count: max(pixelCount, 0)),
            candidatePixelCount: 0,
            meanCandidateProbability: 0,
            maximumProbability: 0
        )
    }
}

/// Offline fallback segmenter trained from the reviewed Motorfest masks.
///
/// The network is a 3x3 RGB convolution with 20 learned ReLU channels and a
/// learned 1x1 sigmoid output. The deterministic color/geometry detector stays
/// primary because it generalized best to the source-holdout recording. This
/// model runs only when that primary path cannot form a valid route.
nonisolated final class LearnedRouteSegmenter {

    func segment(
        pixels: UnsafePointer<UInt8>,
        bytesPerRow: Int,
        minX: Int,
        minY: Int,
        cropWidth: Int,
        cropHeight: Int
    ) -> LearnedRouteSegmentation {

        guard cropWidth > 0,
              cropHeight > 0,
              bytesPerRow > 0 else {
            return .empty(pixelCount: 0)
        }

        let modelWidth = LearnedRouteSegmenterWeights.inputWidth
        let modelHeight = LearnedRouteSegmenterWeights.inputHeight
        let hiddenCount = LearnedRouteSegmenterWeights.hiddenChannels
        let inputChannelCount = LearnedRouteSegmenterWeights.inputChannels
        let featureCount =
            LearnedRouteSegmenterWeights.patchSize *
            LearnedRouteSegmenterWeights.patchSize *
            inputChannelCount

        guard modelWidth > 0,
              modelHeight > 0,
              inputChannelCount == 3,
              LearnedRouteSegmenterWeights.patchSize == 3,
              LearnedRouteSegmenterWeights.firstLayerWeights.count ==
                featureCount * hiddenCount,
              LearnedRouteSegmenterWeights.firstLayerBias.count == hiddenCount,
              LearnedRouteSegmenterWeights.outputWeights.count == hiddenCount else {
            return .empty(pixelCount: cropWidth * cropHeight)
        }

        let modelPixelCount = modelWidth * modelHeight
        let sourceOffsets = [2, 1, 0]
        var input = [Float](
            repeating: 0,
            count: modelPixelCount * inputChannelCount
        )

        // Bilinear scaling matches the preprocessing used during training.
        for modelY in 0..<modelHeight {
            let sourceY =
                (Double(modelY) + 0.5) * Double(cropHeight) /
                Double(modelHeight) - 0.5
            let lowerY = min(max(Int(floor(sourceY)), 0), cropHeight - 1)
            let upperY = min(lowerY + 1, cropHeight - 1)
            let yFraction = Float(min(max(sourceY - Double(lowerY), 0), 1))

            for modelX in 0..<modelWidth {
                let sourceX =
                    (Double(modelX) + 0.5) * Double(cropWidth) /
                    Double(modelWidth) - 0.5
                let lowerX = min(max(Int(floor(sourceX)), 0), cropWidth - 1)
                let upperX = min(lowerX + 1, cropWidth - 1)
                let xFraction = Float(min(max(sourceX - Double(lowerX), 0), 1))

                let topLeft =
                    (minY + lowerY) * bytesPerRow +
                    (minX + lowerX) * 4
                let topRight =
                    (minY + lowerY) * bytesPerRow +
                    (minX + upperX) * 4
                let bottomLeft =
                    (minY + upperY) * bytesPerRow +
                    (minX + lowerX) * 4
                let bottomRight =
                    (minY + upperY) * bytesPerRow +
                    (minX + upperX) * 4
                let outputIndex =
                    (modelY * modelWidth + modelX) * inputChannelCount

                // Pixel buffers are BGRA; training features are RGB.
                for channel in 0..<inputChannelCount {
                    let channelOffset = sourceOffsets[channel]
                    let top =
                        Float(pixels[topLeft + channelOffset]) * (1 - xFraction) +
                        Float(pixels[topRight + channelOffset]) * xFraction
                    let bottom =
                        Float(pixels[bottomLeft + channelOffset]) * (1 - xFraction) +
                        Float(pixels[bottomRight + channelOffset]) * xFraction
                    input[outputIndex + channel] =
                        (top * (1 - yFraction) + bottom * yFraction) / 255
                }
            }
        }

        var modelProbabilities = [Float](repeating: 0, count: modelPixelCount)
        var hidden = [Float](repeating: 0, count: hiddenCount)
        var maximumProbability: Float = 0

        for modelY in 0..<modelHeight {
            for modelX in 0..<modelWidth {
                for hiddenIndex in 0..<hiddenCount {
                    hidden[hiddenIndex] =
                        LearnedRouteSegmenterWeights.firstLayerBias[hiddenIndex]
                }

                var featureIndex = 0
                for offsetY in -1...1 {
                    let sampleY = min(max(modelY + offsetY, 0), modelHeight - 1)
                    for offsetX in -1...1 {
                        let sampleX = min(max(modelX + offsetX, 0), modelWidth - 1)
                        let inputIndex =
                            (sampleY * modelWidth + sampleX) * inputChannelCount

                        for channel in 0..<inputChannelCount {
                            let value = input[inputIndex + channel]
                            let weightOffset = featureIndex * hiddenCount
                            for hiddenIndex in 0..<hiddenCount {
                                hidden[hiddenIndex] +=
                                    value *
                                    LearnedRouteSegmenterWeights
                                        .firstLayerWeights[weightOffset + hiddenIndex]
                            }
                            featureIndex += 1
                        }
                    }
                }

                var logit = LearnedRouteSegmenterWeights.outputBias
                for hiddenIndex in 0..<hiddenCount {
                    logit +=
                        max(hidden[hiddenIndex], 0) *
                        LearnedRouteSegmenterWeights.outputWeights[hiddenIndex]
                }

                let probability = Float(
                    1.0 /
                    (1.0 + exp(-Double(min(max(logit, -30), 30))))
                )
                maximumProbability = max(maximumProbability, probability)
                modelProbabilities[modelY * modelWidth + modelX] = probability
            }
        }

        var fullResolutionMask = [UInt8](
            repeating: 0,
            count: cropWidth * cropHeight
        )
        var fullResolutionCount = 0
        var candidateProbabilityTotal: Double = 0

        // Bilinear probability upscaling mirrors the Pillow preprocessing used
        // by the component verifier. Thresholding after interpolation also
        // avoids blocky nearest-neighbor route masks at capture resolution.
        for localY in 0..<cropHeight {
            let sourceY =
                (Double(localY) + 0.5) * Double(modelHeight) /
                Double(cropHeight) - 0.5
            let lowerY = min(max(Int(floor(sourceY)), 0), modelHeight - 1)
            let upperY = min(lowerY + 1, modelHeight - 1)
            let yFraction = Float(min(max(sourceY - Double(lowerY), 0), 1))

            for localX in 0..<cropWidth {
                let sourceX =
                    (Double(localX) + 0.5) * Double(modelWidth) /
                    Double(cropWidth) - 0.5
                let lowerX = min(max(Int(floor(sourceX)), 0), modelWidth - 1)
                let upperX = min(lowerX + 1, modelWidth - 1)
                let xFraction = Float(min(max(sourceX - Double(lowerX), 0), 1))
                let topLeft = modelProbabilities[lowerY * modelWidth + lowerX]
                let topRight = modelProbabilities[lowerY * modelWidth + upperX]
                let bottomLeft = modelProbabilities[upperY * modelWidth + lowerX]
                let bottomRight = modelProbabilities[upperY * modelWidth + upperX]
                let top = topLeft * (1 - xFraction) + topRight * xFraction
                let bottom = bottomLeft * (1 - xFraction) + bottomRight * xFraction
                let probability = top * (1 - yFraction) + bottom * yFraction
                let index = localY * cropWidth + localX

                guard probability >=
                        LearnedRouteSegmenterWeights.probabilityThreshold else {
                    continue
                }
                fullResolutionMask[index] = 1
                fullResolutionCount += 1
                candidateProbabilityTotal += Double(probability)
            }
        }

        return LearnedRouteSegmentation(
            mask: fullResolutionMask,
            candidatePixelCount: fullResolutionCount,
            meanCandidateProbability: fullResolutionCount > 0
                ? Float(candidateProbabilityTotal / Double(fullResolutionCount))
                : 0,
            maximumProbability: maximumProbability
        )
    }
}
