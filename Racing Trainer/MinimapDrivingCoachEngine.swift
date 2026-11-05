import CoreGraphics
import CoreVideo
import Foundation

/// Stateful safety layer between raw minimap detections and user-facing
/// guidance. All methods are called from FrameAnalyzer's serial minimap queue.
nonisolated final class MinimapDrivingCoachEngine {

    private let geometryAnalyzer = MinimapGeometryAnalyzer()
    private let motionTracker = MinimapMotionTracker()

    private var history: [CoachObservation] = []
    private var previousPath: [MinimapPoint] = []
    private var trackingPath: [MinimapPoint] = []
    private var trackingAnchor: MinimapPoint?
    private var previousPlayerAnchor: MinimapPoint?
    private var previousPlayerAnchorUptime = 0.0
    private var lastFullSourceUptime = 0.0
    private var lastFullConfidence = MinimapConfidenceBreakdown.zero
    private var lastFullGeometry: MinimapGeometryResult?

    private var stableDirection: RouteTurnDirection = .unknown
    private var stableSeverity: TurnSeverity = .unknown
    private var stableTiming: TurnTiming = .unknown
    private var pendingDirection: RouteTurnDirection = .unknown
    private var pendingDirectionCount = 0
    private var pendingLowerSeverityCount = 0
    private var pendingFartherTimingCount = 0
    private var consecutiveStableStraightFrames = 0

    private let readyThreshold: Float = 0.52
    private let maximumFreshResultAge = 0.65

    // MARK: Reset

    func reset() {
        history.removeAll(keepingCapacity: false)
        previousPath.removeAll(keepingCapacity: false)
        trackingPath.removeAll(keepingCapacity: false)
        trackingAnchor = nil
        previousPlayerAnchor = nil
        previousPlayerAnchorUptime = 0
        lastFullSourceUptime = 0
        lastFullConfidence = .zero
        lastFullGeometry = nil
        stableDirection = .unknown
        stableSeverity = .unknown
        stableTiming = .unknown
        pendingDirection = .unknown
        pendingDirectionCount = 0
        pendingLowerSeverityCount = 0
        pendingFartherTimingCount = 0
        consecutiveStableStraightFrames = 0
    }

    // MARK: Full Detection

    func processFullDetection(
        _ analysis: MinimapRouteAnalysis,
        sourceFrameUptime: TimeInterval,
        completionUptime: TimeInterval,
        speedSample: MinimapSpeedSample?,
        sourceSessionID: Int
    ) -> MinimapCoachSnapshot {
        var latency = max(completionUptime - sourceFrameUptime, 0)
        var freshness = freshnessConfidence(forAge: latency)

        guard analysis.minimapVisible else {
            clearRouteState()
            return unavailableSnapshot(
                state: .minimapUnavailable,
                analysis: analysis,
                sourceFrameUptime: sourceFrameUptime,
                latency: latency,
                reason: "The cyan local-player marker was not found in the calibrated minimap crop."
            )
        }

        guard let playerAnchor = analysis.playerAnchor else {
            clearRouteState()
            return unavailableSnapshot(
                state: .routeUncertain,
                analysis: analysis,
                sourceFrameUptime: sourceFrameUptime,
                latency: latency,
                reason: "The minimap is visible, but the local-player anchor is ambiguous."
            )
        }

        let anchorConfidence = playerAnchorConfidence(
            analysis: analysis,
            anchor: playerAnchor,
            sourceFrameUptime: sourceFrameUptime
        )
        previousPlayerAnchor = playerAnchor
        previousPlayerAnchorUptime = sourceFrameUptime

        guard analysis.routeDetected,
              let routeMask = analysis.routeMask else {
            clearRouteState()
            let candidateLimit = max(
                300,
                Int(Double(routeMaskPixelCapacity(analysis)) * 0.010)
            )
            let looksLikeNoWaypoint =
                analysis.minimapConfidence >= 0.55 &&
                anchorConfidence >= 0.50 &&
                analysis.yellowCandidatePixelCount <= candidateLimit

            return unavailableSnapshot(
                state: looksLikeNoWaypoint ? .noWaypoint : .routeUncertain,
                analysis: analysis,
                sourceFrameUptime: sourceFrameUptime,
                latency: latency,
                playerAnchorConfidence: anchorConfidence,
                action: looksLikeNoWaypoint ? .setWaypoint : .unavailable,
                reason: looksLikeNoWaypoint
                    ? "The minimap is visible, but no connected GPS trail was found."
                    : "Yellow evidence exists, but it does not form a safe route path."
            )
        }

        let geometry = geometryAnalyzer.analyze(
            mask: routeMask,
            playerAnchor: playerAnchor,
            previousPath: previousPath
        )
        latency = max(
            max(
                completionUptime,
                ProcessInfo
                    .processInfo
                    .systemUptime
            ) -
            sourceFrameUptime,
            0
        )
        freshness = freshnessConfidence(forAge: latency)
        let maskConfidence = routeMaskConfidence(
            analysis: analysis,
            mask: routeMask,
            branchPointCount: geometry.branchPointCount
        )

        guard geometry.isValid else {
            trackingPath.removeAll(keepingCapacity: true)
            trackingAnchor = nil
            lastFullGeometry = nil

            return MinimapCoachSnapshot(
                state: .routeUncertain,
                confidence: MinimapConfidenceBreakdown(
                    minimap: analysis.minimapConfidence,
                    playerAnchor: anchorConfidence,
                    routeMask: maskConfidence,
                    forwardPath: geometry.forwardPathConfidence,
                    geometry: geometry.geometryConfidence,
                    temporalStability: temporalStability(
                        for: nil,
                        at: sourceFrameUptime
                    ),
                    freshness: freshness,
                    motionTracking: 1
                ),
                direction: .unknown,
                severity: .unknown,
                timing: .unknown,
                action: .unavailable,
                steering: .unavailable,
                orderedPath: [],
                turnStartPoint: nil,
                turnStartNormalizedDistance: nil,
                pathPointCount: 0,
                branchPointCount: geometry.branchPointCount,
                speedUsed: nil,
                speedAgeMilliseconds: nil,
                sourceFrameUptime: sourceFrameUptime,
                processingLatencyMilliseconds: latency * 1000,
                trackingApplied: false,
                reason: geometry.reason
            )
        }

        let rawCriticalConfidence = [
            analysis.minimapConfidence,
            anchorConfidence,
            maskConfidence,
            geometry.forwardPathConfidence,
            geometry.geometryConfidence,
            freshness
        ]
        .min() ?? 0
        let observation = CoachObservation(
            direction: geometry.direction,
            severity: geometry.severity,
            timing: geometry.timing,
            confidence: rawCriticalConfidence,
            sourceFrameUptime: sourceFrameUptime
        )

        appendObservation(observation)
        updateStableDescription(with: observation)
        let stability = temporalStability(
            for: observation,
            at: sourceFrameUptime
        )

        let confidence = MinimapConfidenceBreakdown(
            minimap: analysis.minimapConfidence,
            playerAnchor: anchorConfidence,
            routeMask: maskConfidence,
            forwardPath: geometry.forwardPathConfidence,
            geometry: geometry.geometryConfidence,
            temporalStability: stability,
            freshness: freshness,
            motionTracking: 1
        )

        let state: MinimapCoachState = confidence.criticalMinimum >= readyThreshold
            ? .ready
            : .routeUncertain
        let decision = safetyDecision(
            direction: stableDirection, severity: stableSeverity, timing: stableTiming,
            state: state, confidence: confidence.criticalMinimum,
            sourceFrameUptime: sourceFrameUptime, speed: speedSample,
            sourceSessionID: sourceSessionID
        )
        let steering = state == .ready
            ? steeringGuidance(
                direction: stableDirection,
                severity: stableSeverity
            )
            : .unavailable

        previousPath = geometry.orderedPath
        trackingPath = geometry.orderedPath
        trackingAnchor = playerAnchor
        lastFullSourceUptime = sourceFrameUptime
        lastFullConfidence = confidence
        lastFullGeometry = geometry

        return MinimapCoachSnapshot(
            state: state,
            confidence: confidence,
            direction: state == .ready ? stableDirection : geometry.direction,
            severity: state == .ready ? stableSeverity : geometry.severity,
            timing: state == .ready ? stableTiming : geometry.timing,
            action: decision.action,
            steering: steering,
            orderedPath: geometry.orderedPath,
            turnStartPoint: geometry.turnStartPoint,
            turnStartNormalizedDistance: geometry.turnStartNormalizedDistance,
            pathPointCount: geometry.orderedPath.count,
            branchPointCount: geometry.branchPointCount,
            speedUsed: decision.speedUsed,
            speedAgeMilliseconds: decision.speedUsed == nil ? nil : speedSample.map {
                (decision.issuedAt - $0.sourceFrameUptime) * 1000
            },
            sourceFrameUptime: sourceFrameUptime,
            processingLatencyMilliseconds: latency * 1000,
            trackingApplied: false,
            reason: state == .ready
                ? geometry.reason + " " + decision.explanation
                : "A route was found, but one or more critical confidence gates are still below the safe threshold.",
            guidanceExpiresAt: decision.expiresAt,
            playerAnchor: playerAnchor
        )
    }

    // MARK: Lightweight Latest-Frame Tracking

    func processTrackedFrame(
        pixelBuffer: CVPixelBuffer,
        sourceFrameUptime: TimeInterval,
        completionUptime: TimeInterval,
        speedSample: MinimapSpeedSample?,
        sourceSessionID: Int
    ) -> MinimapCoachSnapshot? {
        guard sourceFrameUptime > lastFullSourceUptime,
              sourceFrameUptime - lastFullSourceUptime <= 0.45,
              !trackingPath.isEmpty,
              let trackingAnchor,
              let lastFullGeometry else {
            return nil
        }

        let tracking = motionTracker.track(
            pixelBuffer: pixelBuffer,
            normalizedCropRect: MotorfestHUDLayout.minimapAnalysisRect,
            path: trackingPath,
            playerAnchor: trackingAnchor
        )

        guard tracking.succeeded else {
            return nil
        }

        let geometry = geometryAnalyzer.describeTrackedPath(
            tracking.transformedPath,
            forwardPathConfidence: lastFullGeometry.forwardPathConfidence,
            branchPointCount: lastFullGeometry.branchPointCount
        )

        guard geometry.isValid else {
            return nil
        }

        let latency = max(
            max(
                completionUptime,
                ProcessInfo
                    .processInfo
                    .systemUptime
            ) -
            sourceFrameUptime,
            0
        )
        let freshness = freshnessConfidence(forAge: latency)
        let descriptorAgreement = descriptionAgreement(
            direction: geometry.direction,
            severity: geometry.severity,
            timing: geometry.timing
        )
        let temporal = min(
            lastFullConfidence.temporalStability,
            Float(0.45 + 0.55 * descriptorAgreement)
        )
        let fullResultAge = sourceFrameUptime - lastFullSourceUptime
        let retainedMaskConfidence = lastFullConfidence.routeMask * Float(
            clamped(1 - fullResultAge / 0.65)
        )

        let confidence = MinimapConfidenceBreakdown(
            minimap: lastFullConfidence.minimap,
            playerAnchor: lastFullConfidence.playerAnchor,
            routeMask: retainedMaskConfidence,
            forwardPath: min(
                lastFullConfidence.forwardPath,
                tracking.confidence
            ),
            geometry: geometry.geometryConfidence,
            temporalStability: temporal,
            freshness: freshness,
            motionTracking: tracking.confidence
        )
        let state: MinimapCoachState = confidence.criticalMinimum >= readyThreshold
            ? .ready
            : .routeUncertain

        // Tracked frames may move a warning closer immediately. They are not
        // independent evidence, so they cannot relax an existing warning.
        let outputTiming = geometry.timing.urgencyRank > stableTiming.urgencyRank
            ? geometry.timing
            : stableTiming
        let outputSeverity = geometry.severity.urgencyRank > stableSeverity.urgencyRank
            ? geometry.severity
            : stableSeverity
        let outputDirection = descriptorAgreement >= 0.45
            ? stableDirection
            : geometry.direction
        let decision = safetyDecision(
            direction: outputDirection, severity: outputSeverity, timing: outputTiming,
            state: state, confidence: confidence.criticalMinimum,
            sourceFrameUptime: sourceFrameUptime, speed: speedSample,
            sourceSessionID: sourceSessionID
        )
        let steering = state == .ready
            ? steeringGuidance(
                direction: outputDirection,
                severity: outputSeverity
            )
            : .unavailable

        trackingPath = tracking.transformedPath
        self.trackingAnchor = MinimapPoint(
            x: trackingAnchor.x + tracking.translationX,
            y: trackingAnchor.y + tracking.translationY
        )

        return MinimapCoachSnapshot(
            state: state,
            confidence: confidence,
            direction: outputDirection,
            severity: outputSeverity,
            timing: outputTiming,
            action: decision.action,
            steering: steering,
            orderedPath: geometry.orderedPath,
            turnStartPoint: geometry.turnStartPoint,
            turnStartNormalizedDistance: geometry.turnStartNormalizedDistance,
            pathPointCount: geometry.orderedPath.count,
            branchPointCount: geometry.branchPointCount,
            speedUsed: decision.speedUsed,
            speedAgeMilliseconds: decision.speedUsed == nil ? nil : speedSample.map {
                (decision.issuedAt - $0.sourceFrameUptime) * 1000
            },
            sourceFrameUptime: sourceFrameUptime,
            processingLatencyMilliseconds: latency * 1000,
            trackingApplied: true,
            reason: "Latest-frame route tracking: \(Int(tracking.rotationDegrees))° correction. " + decision.explanation,
            guidanceExpiresAt: decision.expiresAt,
            playerAnchor: self.trackingAnchor
        )
    }

    func suppressGuidanceAfterTrackingFailure(
        _ snapshot: MinimapCoachSnapshot,
        latestFrameUptime: TimeInterval
    ) -> MinimapCoachSnapshot {
        let confidence = MinimapConfidenceBreakdown(
            minimap: snapshot.confidence.minimap,
            playerAnchor: snapshot.confidence.playerAnchor,
            routeMask: snapshot.confidence.routeMask,
            forwardPath: snapshot.confidence.forwardPath,
            geometry: snapshot.confidence.geometry,
            temporalStability: snapshot.confidence.temporalStability,
            freshness: freshnessConfidence(
                forAge: max(latestFrameUptime - snapshot.sourceFrameUptime, 0)
            ),
            motionTracking: 0
        )

        return MinimapCoachSnapshot(
            state: .routeUncertain,
            confidence: confidence,
            direction: snapshot.direction,
            severity: snapshot.severity,
            timing: snapshot.timing,
            action: .unavailable,
            steering: .unavailable,
            orderedPath: [],
            turnStartPoint: nil,
            turnStartNormalizedDistance: snapshot.turnStartNormalizedDistance,
            pathPointCount: 0,
            branchPointCount: snapshot.branchPointCount,
            speedUsed: snapshot.speedUsed,
            speedAgeMilliseconds: snapshot.speedAgeMilliseconds,
            sourceFrameUptime: snapshot.sourceFrameUptime,
            processingLatencyMilliseconds: snapshot.processingLatencyMilliseconds,
            trackingApplied: false,
            reason: "A newer frame arrived, but route motion could not be tracked safely."
        )
    }

    // MARK: State and Confidence

    private func clearRouteState() {
        history.removeAll(keepingCapacity: true)
        previousPath.removeAll(keepingCapacity: true)
        trackingPath.removeAll(keepingCapacity: true)
        trackingAnchor = nil
        lastFullGeometry = nil
        stableDirection = .unknown
        stableSeverity = .unknown
        stableTiming = .unknown
        pendingDirection = .unknown
        pendingDirectionCount = 0
        pendingLowerSeverityCount = 0
        pendingFartherTimingCount = 0
        consecutiveStableStraightFrames = 0
    }

    private func playerAnchorConfidence(
        analysis: MinimapRouteAnalysis,
        anchor: MinimapPoint,
        sourceFrameUptime: TimeInterval
    ) -> Float {
        let expected = MinimapPoint(x: 0.50, y: 0.72)
        let normalDistance = hypot(anchor.x - expected.x, anchor.y - expected.y)
        // Event/escape zoom moves a smaller arrow toward the map center.
        // Accept that position only after the detector verifies its shape.
        let compactDistance = analysis.playerDetectionConfidence >= 0.70
            ? hypot(anchor.x - 0.62, anchor.y - 0.56) : Double.infinity
        let distance = min(normalDistance, compactDistance)
        let positionScore = Float(clamped(1 - distance / 0.24))
        let pixelScore = Float(clamped(
            Double(analysis.cyanPlayerPixelCount - 30) / 240
        ))
        let temporalScore: Float

        if let previousPlayerAnchor,
           sourceFrameUptime - previousPlayerAnchorUptime <= 1.0 {
            let movement = hypot(
                anchor.x - previousPlayerAnchor.x,
                anchor.y - previousPlayerAnchor.y
            )
            temporalScore = Float(clamped(1 - movement / 0.10))
        } else {
            temporalScore = 0.62
        }

        return min(
            1,
            0.42 * analysis.minimapConfidence +
            0.25 * positionScore +
            0.15 * pixelScore +
            0.18 * temporalScore
        )
    }

    private func routeMaskConfidence(
        analysis: MinimapRouteAnalysis,
        mask: MinimapRouteMask,
        branchPointCount: Int
    ) -> Float {
        let pixelCapacity = max(mask.width * mask.height, 1)
        let ratio = Double(analysis.routeMaskPixelCount) / Double(pixelCapacity)
        let minimumDensityScore = clamped((ratio - 0.0008) / 0.0045)
        let overflowScore = 1 - clamped((ratio - 0.12) / 0.10)
        let componentScore = clamped(
            1 - Double(max(analysis.routeComponentCount - 3, 0)) / 6
        )
        let branchScore = clamped(
            1 - Double(max(branchPointCount - 3, 0)) / 12
        )

        return Float(clamped(
            0.48 * Double(analysis.routeConfidence) +
            0.17 * minimumDensityScore +
            0.15 * overflowScore +
            0.10 * componentScore +
            0.10 * branchScore
        ))
    }

    private func freshnessConfidence(
        forAge age: TimeInterval
    ) -> Float {
        if age <= 0.14 {
            return 1
        }

        return Float(clamped(
            1 - (age - 0.14) /
            (maximumFreshResultAge - 0.14)
        ))
    }

    private func routeMaskPixelCapacity(
        _ analysis: MinimapRouteAnalysis
    ) -> Int {
        if let mask = analysis.routeMask {
            return mask.width * mask.height
        }

        // The exact size is unavailable only in a failed detector state.
        // This fallback matches the current 1920 × 1080 calibrated crop.
        return 346 * 351
    }

    // MARK: Temporal Smoothing and Hysteresis

    private func appendObservation(
        _ observation: CoachObservation
    ) {
        history.append(observation)
        history.removeAll {
            observation.sourceFrameUptime - $0.sourceFrameUptime > 1.20
        }
        if history.count > 8 {
            history.removeFirst(history.count - 8)
        }
    }

    private func updateStableDescription(
        with observation: CoachObservation
    ) {
        if stableDirection == .unknown {
            if history.count >= 2 || observation.confidence >= 0.80 {
                stableDirection = observation.direction
                stableSeverity = observation.severity
                stableTiming = observation.timing
            }
        } else if observation.direction == stableDirection {
            pendingDirection = .unknown
            pendingDirectionCount = 0
        } else {
            if pendingDirection == observation.direction {
                pendingDirectionCount += 1
            } else {
                pendingDirection = observation.direction
                pendingDirectionCount = 1
            }

            let urgentChange =
                observation.severity.urgencyRank >= TurnSeverity.sharp.urgencyRank &&
                observation.timing.urgencyRank >= TurnTiming.soon.urgencyRank &&
                observation.confidence >= 0.68
            let requiredCount = urgentChange ? 1 : 2

            if pendingDirectionCount >= requiredCount {
                stableDirection = observation.direction
                stableSeverity = observation.severity
                stableTiming = observation.timing
                pendingDirection = .unknown
                pendingDirectionCount = 0
            }
        }

        if observation.direction == stableDirection {
            if observation.severity.urgencyRank > stableSeverity.urgencyRank,
               observation.confidence >= 0.62 {
                stableSeverity = observation.severity
                pendingLowerSeverityCount = 0
            } else if observation.severity.urgencyRank < stableSeverity.urgencyRank {
                pendingLowerSeverityCount += 1
                if pendingLowerSeverityCount >= 3 {
                    stableSeverity = observation.severity
                    pendingLowerSeverityCount = 0
                }
            } else {
                pendingLowerSeverityCount = 0
            }

            if observation.timing.urgencyRank > stableTiming.urgencyRank,
               observation.confidence >= 0.58 {
                stableTiming = observation.timing
                pendingFartherTimingCount = 0
            } else if observation.timing.urgencyRank < stableTiming.urgencyRank {
                pendingFartherTimingCount += 1
                if pendingFartherTimingCount >= 3 {
                    stableTiming = observation.timing
                    pendingFartherTimingCount = 0
                }
            } else {
                pendingFartherTimingCount = 0
            }
        }

        if stableDirection == .straight {
            consecutiveStableStraightFrames += 1
        } else {
            consecutiveStableStraightFrames = 0
        }
    }

    private func temporalStability(
        for current: CoachObservation?,
        at sourceUptime: TimeInterval
    ) -> Float {
        let recent = history.filter {
            sourceUptime - $0.sourceFrameUptime <= 1.0
        }

        guard !recent.isEmpty else {
            return current == nil ? 0 : 0.40
        }

        let reference = current ?? recent[recent.count - 1]
        var matchingWeight = 0.0
        var totalWeight = 0.0

        for observation in recent {
            let age = max(sourceUptime - observation.sourceFrameUptime, 0)
            let recency = max(1 - age / 1.0, 0.15)
            let weight = recency * Double(max(observation.confidence, 0.20))
            totalWeight += weight

            let agreement = observationAgreement(observation, reference)
            matchingWeight += weight * agreement
        }

        let agreement = totalWeight > 0 ? matchingWeight / totalWeight : 0
        let evidence = min(0.42 + 0.16 * Double(recent.count), 1)
        return Float(clamped(agreement * evidence))
    }

    private func observationAgreement(
        _ first: CoachObservation,
        _ second: CoachObservation
    ) -> Double {
        var score = 0.0
        score += first.direction == second.direction ? 0.55 : 0
        score += abs(first.severity.urgencyRank - second.severity.urgencyRank) <= 1 ? 0.25 : 0
        score += abs(first.timing.urgencyRank - second.timing.urgencyRank) <= 1 ? 0.20 : 0
        return score
    }

    private func descriptionAgreement(
        direction: RouteTurnDirection,
        severity: TurnSeverity,
        timing: TurnTiming
    ) -> Double {
        guard stableDirection != .unknown else {
            return 0
        }

        var score = direction == stableDirection ? 0.55 : 0
        if direction.sideSign != 0,
           direction.sideSign == stableDirection.sideSign {
            score = max(score, 0.42)
        }
        if abs(severity.urgencyRank - stableSeverity.urgencyRank) <= 1 {
            score += 0.25
        }
        if abs(timing.urgencyRank - stableTiming.urgencyRank) <= 1 {
            score += 0.20
        }
        return clamped(score)
    }

    // MARK: Speed and Guidance

    private func safetyDecision(
        direction: RouteTurnDirection,
        severity: TurnSeverity,
        timing: TurnTiming,
        state: MinimapCoachState,
        confidence: Float,
        sourceFrameUptime: TimeInterval,
        speed: MinimapSpeedSample?,
        sourceSessionID: Int
    ) -> CoachDecision {
        let now = ProcessInfo.processInfo.systemUptime
        let route = PerceptionObservation(
            value: RouteGuidance(direction: direction, severity: severity, timing: timing),
            state: state == .ready ? .fresh : .uncertain,
            confidence: confidence, capturedAt: sourceFrameUptime, completedAt: now,
            sourceSessionID: sourceSessionID, implementation: "minimap-hybrid", version: "1",
            failureReason: state == .ready ? nil : "Route confidence gate failed."
        )
        let speedObservation = speed.map {
            PerceptionObservation(value: $0.value, state: .fresh, confidence: $0.confidence,
                                  capturedAt: $0.sourceFrameUptime, completedAt: $0.completionUptime,
                                  sourceSessionID: $0.sourceSessionID,
                                  implementation: "vision-fast", version: "1", failureReason: nil)
        }
        return CoachSafetyPolicy.decide(route: route, speed: speedObservation,
                                        stableStraightFrames: consecutiveStableStraightFrames,
                                        sessionID: sourceSessionID, now: now)
    }

    private func steeringGuidance(
        direction: RouteTurnDirection,
        severity: TurnSeverity
    ) -> SteeringGuidance {
        switch direction {
        case .unknown:
            return .unavailable
        case .straight:
            return .center
        case .left, .uTurnLeft:
            switch severity {
            case .gentle:
                return .slightLeft
            case .medium:
                return .left
            case .sharp, .uTurn:
                return .hardLeft
            case .unknown, .straight:
                return .left
            }
        case .right, .uTurnRight:
            switch severity {
            case .gentle:
                return .slightRight
            case .medium:
                return .right
            case .sharp, .uTurn:
                return .hardRight
            case .unknown, .straight:
                return .right
            }
        }
    }

    // MARK: Invalid Snapshot

    private func unavailableSnapshot(
        state: MinimapCoachState,
        analysis: MinimapRouteAnalysis,
        sourceFrameUptime: TimeInterval,
        latency: TimeInterval,
        playerAnchorConfidence: Float = 0,
        action: DrivingCoachAction = .unavailable,
        reason: String
    ) -> MinimapCoachSnapshot {
        MinimapCoachSnapshot(
            state: state,
            confidence: MinimapConfidenceBreakdown(
                minimap: analysis.minimapConfidence,
                playerAnchor: playerAnchorConfidence,
                routeMask: 0,
                forwardPath: 0,
                geometry: 0,
                temporalStability: 0,
                freshness: freshnessConfidence(forAge: latency),
                motionTracking: 1
            ),
            direction: .unknown,
            severity: .unknown,
            timing: .unknown,
            action: action,
            steering: .unavailable,
            orderedPath: [],
            turnStartPoint: nil,
            turnStartNormalizedDistance: nil,
            pathPointCount: 0,
            branchPointCount: 0,
            speedUsed: nil,
            speedAgeMilliseconds: nil,
            sourceFrameUptime: sourceFrameUptime,
            processingLatencyMilliseconds: latency * 1000,
            trackingApplied: false,
            reason: reason
        )
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

nonisolated private struct CoachObservation {
    let direction: RouteTurnDirection
    let severity: TurnSeverity
    let timing: TurnTiming
    let confidence: Float
    let sourceFrameUptime: TimeInterval
}
