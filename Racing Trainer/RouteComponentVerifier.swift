import Foundation

nonisolated struct RouteComponentVerification {
    let probability: Float
    let accepted: Bool

    static let rejected = RouteComponentVerification(
        probability: 0,
        accepted: false
    )
}

/// Tiny offline neural verifier for ambiguous yellow components near the car.
///
/// The normal route path remains deterministic. This verifier is only used
/// after the normal geometry gate fails and a short, route-like component is
/// found. The endpoint-context gate rejects objective-ring connectors and the
/// yellow OPEN CARA HUD connector represented in the reviewed hard negatives.
nonisolated final class RouteComponentVerifier {

    func evaluate(features: [Float]) -> RouteComponentVerification {
        let featureCount = RouteComponentVerifierWeights.featureCount
        let hiddenCount = RouteComponentVerifierWeights.hiddenCount

        guard features.count == featureCount,
              featureCount > 21,
              hiddenCount > 0,
              RouteComponentVerifierWeights.firstWeights.count ==
                featureCount * hiddenCount,
              RouteComponentVerifierWeights.firstBias.count == hiddenCount,
              RouteComponentVerifierWeights.outputWeights.count == hiddenCount,
              features.allSatisfy({ $0.isFinite }) else {
            return .rejected
        }

        var hidden = RouteComponentVerifierWeights.firstBias
        for featureIndex in 0..<featureCount {
            let value = features[featureIndex]
            let weightOffset = featureIndex * hiddenCount
            for hiddenIndex in 0..<hiddenCount {
                hidden[hiddenIndex] +=
                    value *
                    RouteComponentVerifierWeights
                        .firstWeights[weightOffset + hiddenIndex]
            }
        }

        var logit = RouteComponentVerifierWeights.outputBias
        for hiddenIndex in 0..<hiddenCount {
            logit +=
                max(hidden[hiddenIndex], 0) *
                RouteComponentVerifierWeights.outputWeights[hiddenIndex]
        }
        let probability = Float(
            1.0 /
            (1.0 + exp(-Double(min(max(logit, -30), 30))))
        )

        // Feature 21 is the fraction of pale/white pixels around the far end
        // of the component. The reviewed false cases all terminate in a white
        // objective ring or bottom HUD text; verified short GPS stubs do not.
        let whiteEndpointFraction = features[21]
        let accepted =
            probability >= RouteComponentVerifierWeights.acceptanceThreshold &&
            whiteEndpointFraction <=
                RouteComponentVerifierWeights.maximumWhiteEndpointFraction

        return RouteComponentVerification(
            probability: probability,
            accepted: accepted
        )
    }
}
