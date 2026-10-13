import AVFoundation
import Combine
import CoreGraphics
import CoreVideo
import Foundation

private struct MinimapAnalyzerSnapshot {
    let analyzedFrameCount:
        Int

    let analysisFPS:
        Double

    let analysisMilliseconds:
        Double

    let minimapVisible:
        Bool

    let minimapConfidence:
        Float

    let playerDetectionConfidence:
        Float

    let rimStructureConfidence:
        Float

    let routeDetected:
        Bool

    let routeConfidence:
        Float

    let routeSource:
        MinimapRouteSource

    let diagnostic:
        MinimapDetectionDiagnostic

    let cyanMarkerPixelCount:
        Int

    let routeMaskPixelCount:
        Int

    let yellowCandidatePixelCount:
        Int

    let learnedCandidatePixelCount:
        Int

    let shortRouteCandidateFound:
        Bool

    let shortRouteVerifierConfidence:
        Float

    let routeComponentCount:
        Int

    let ignoredYellowComponentCount:
        Int

    let routeMaskImage:
        CGImage?

    let coach:
        MinimapCoachSnapshot

    static let empty =
        MinimapAnalyzerSnapshot(
            analyzedFrameCount:
                0,
            analysisFPS:
                0,
            analysisMilliseconds:
                0,
            minimapVisible:
                false,
            minimapConfidence:
                0,
            playerDetectionConfidence:
                0,
            rimStructureConfidence:
                0,
            routeDetected:
                false,
            routeConfidence:
                0,
            routeSource:
                .none,
            diagnostic:
                .waiting,
            cyanMarkerPixelCount:
                0,
            routeMaskPixelCount:
                0,
            yellowCandidatePixelCount:
                0,
            learnedCandidatePixelCount:
                0,
            shortRouteCandidateFound:
                false,
            shortRouteVerifierConfidence:
                0,
            routeComponentCount:
                0,
            ignoredYellowComponentCount:
                0,
            routeMaskImage:
                nil,
            coach:
                .empty
        )
}

final class FrameAnalyzer:
    ObservableObject {

    // MARK: - Frame Information

    @Published private(set)
    var frameWidth = 0

    @Published private(set)
    var frameHeight = 0

    @Published private(set)
    var capturedFrameCount = 0

    @Published private(set)
    var lastFrameDate: Date?

    // MARK: - Speed Analyzer Statistics

    @Published private(set)
    var speedAnalyzedFrameCount = 0

    @Published private(set)
    var speedAnalysisFPS = 0.0

    // Backwards compatibility.
    @Published private(set)
    var analyzedFrameCount = 0

    @Published private(set)
    var analysisFPS = 0.0

    // MARK: - Minimap Analyzer Statistics

    @Published private var minimapSnapshot =
        MinimapAnalyzerSnapshot.empty

    @Published private(set) var roadLines = RoadLineObservation.empty
    @Published private(set) var turnGuidance = LiveTurnGuidanceSnapshot.empty
    private var liveTurnPipeline = LiveTurnGuidancePipeline()
    private let roadLineDetector = RoadLineDetector()

    var minimapAnalyzedFrameCount:
        Int {

        minimapSnapshot
            .analyzedFrameCount
    }

    var minimapAnalysisFPS:
        Double {

        minimapSnapshot
            .analysisFPS
    }

    var minimapAnalysisMilliseconds:
        Double {

        minimapSnapshot
            .analysisMilliseconds
    }

    // MARK: - Minimap Detection

    var minimapVisible:
        Bool {

        minimapSnapshot
            .minimapVisible
    }

    var minimapConfidence:
        Float {

        minimapSnapshot
            .minimapConfidence
    }

    var yellowRouteDetected:
        Bool {

        minimapSnapshot
            .routeDetected
    }

    var yellowRouteConfidence:
        Float {

        minimapSnapshot
            .routeConfidence
    }

    var playerDetectionConfidence:
        Float {

        minimapSnapshot
            .playerDetectionConfidence
    }

    var rimStructureConfidence:
        Float {

        minimapSnapshot
            .rimStructureConfidence
    }

    var minimapRouteSource:
        MinimapRouteSource {

        minimapSnapshot
            .routeSource
    }

    var minimapDiagnostic:
        MinimapDetectionDiagnostic {

        minimapSnapshot
            .diagnostic
    }

    var cyanMarkerPixelCount:
        Int {

        minimapSnapshot
            .cyanMarkerPixelCount
    }

    var yellowRoutePixelCount:
        Int {

        minimapSnapshot
            .routeMaskPixelCount
    }

    var yellowCandidatePixelCount:
        Int {

        minimapSnapshot
            .yellowCandidatePixelCount
    }

    var learnedCandidatePixelCount:
        Int {

        minimapSnapshot
            .learnedCandidatePixelCount
    }

    var shortRouteCandidateFound:
        Bool {

        minimapSnapshot
            .shortRouteCandidateFound
    }

    var shortRouteVerifierConfidence:
        Float {

        minimapSnapshot
            .shortRouteVerifierConfidence
    }

    var routeComponentCount:
        Int {

        minimapSnapshot
            .routeComponentCount
    }

    var ignoredYellowComponentCount:
        Int {

        minimapSnapshot
            .ignoredYellowComponentCount
    }

    var routeMaskImage:
        CGImage? {

        minimapSnapshot
            .routeMaskImage
    }

    var coachSnapshot:
        MinimapCoachSnapshot {

        minimapSnapshot
            .coach
    }

    // MARK: - Speed OCR

    @Published private(set)
    var detectedSpeed: Int?

    @Published private(set)
    var rawDetectedSpeed: Int?

    @Published private(set)
    var detectedSpeedUnit: String?

    @Published private(set)
    var speedConfidence: Float = 0

    @Published private(set)
    var rawSpeedOCRText = ""

    @Published private(set)
    var speedOCRMilliseconds = 0.0

    // MARK: - Analyzer Rates

    let targetSpeedAnalysisFPS:
        Double

    let targetMinimapAnalysisFPS:
        Double

    var targetAnalysisFPS:
        Double {

        targetSpeedAnalysisFPS
    }

    // MARK: - Queues

    private let speedAnalysisQueue =
        DispatchQueue(
            label:
                "com.racingtrainer.speed-analysis",
            qos:
                .userInitiated
        )

    private let minimapAnalysisQueue =
        DispatchQueue(
            label:
                "com.racingtrainer.minimap-analysis",
            qos:
                .userInitiated
        )

    private let minimapRouteDetector =
        MinimapRouteDetector()

    private let minimapCoachEngine =
        MinimapDrivingCoachEngine()

    // MARK: - Shared State

    private let stateLock =
        NSLock()

    private var capturedFrameCountStorage =
        0

    private var generation =
        0

    // MARK: - Speed Scheduler

    private var speedAnalyzedFrameCountStorage =
        0

    private var speedAnalysisInProgress =
        false

    private var lastSpeedAcceptedFrameUptime =
        0.0

    private var speedCompletionTimes:
        [TimeInterval] = []

    private var recentSpeedSamples:
        [MinimapSpeedSample] = []

    // MARK: - Minimap Scheduler

    private var minimapAnalyzedFrameCountStorage =
        0

    private var minimapAnalysisInProgress =
        false

    private var lastMinimapAcceptedFrameUptime =
        0.0

    private var minimapCompletionTimes:
        [TimeInterval] = []

    private var latestCompletedMinimapResultSequence =
        0

    // While the full detector is busy, retain only the newest frame. After
    // detection finishes, the lightweight tracker aligns the verified path
    // to this frame instead of processing a queue of stale video frames.
    private var pendingTrackingPixelBuffer:
        CVPixelBuffer?

    private var pendingTrackingFrameUptime =
        0.0

    // A small tolerance prevents 30 FPS input timestamps that arrive a
    // fraction early from being needlessly cut down to 15 FPS.
    private let schedulerIntervalTolerance =
        0.90

    // MARK: - Speed Filter

    private var stableSpeedStorage:
        Int?

    private var pendingJumpSpeedStorage:
        Int?

    private var consecutiveSpeedMissesStorage =
        0

    private var detectedSpeedUnitStorage:
        String? =
            MotorfestHUDLayout.speedUnit

    private let maximumSingleFrameSpeedChange =
        40

    private let matchingJumpTolerance =
        20

    private let missesBeforeClearingSpeed =
        3

    // MARK: - Init

    init(
        targetSpeedAnalysisFPS:
            Double = 15.0,
        targetMinimapAnalysisFPS:
            Double = 30.0
    ) {
        self.targetSpeedAnalysisFPS =
            max(
                targetSpeedAnalysisFPS,
                0.5
            )

        self.targetMinimapAnalysisFPS =
            max(
                targetMinimapAnalysisFPS,
                0.5
            )
        detectedSpeedUnitStorage = confirmedGuidanceSpeedUnit()?.uppercased()
    }

    // MARK: - Receive Frame

    func receive(
        _ sampleBuffer:
            CMSampleBuffer
    ) {
        guard let pixelBuffer =
                CMSampleBufferGetImageBuffer(
                    sampleBuffer
                ) else {
            return
        }

        receive(
            pixelBuffer
        )
    }

    func receive(
        _ pixelBuffer:
            CVPixelBuffer
    ) {

        let currentUptime =
            ProcessInfo
                .processInfo
                .systemUptime

        let speedMinimumInterval =
            1.0 /
            targetSpeedAnalysisFPS *
            schedulerIntervalTolerance

        let minimapMinimumInterval =
            1.0 /
            targetMinimapAnalysisFPS *
            schedulerIntervalTolerance

        stateLock.lock()

        capturedFrameCountStorage +=
            1

        let currentCapturedFrameCount =
            capturedFrameCountStorage

        let currentGeneration =
            generation

        // MARK: Speed Scheduling

        let speedTimePassed =
            currentUptime -
            lastSpeedAcceptedFrameUptime >=
            speedMinimumInterval

        let shouldAnalyzeSpeed =
            speedTimePassed &&
            !speedAnalysisInProgress

        if shouldAnalyzeSpeed {
            lastSpeedAcceptedFrameUptime =
                currentUptime

            speedAnalysisInProgress =
                true
        }

        // MARK: Minimap Scheduling

        let minimapTimePassed =
            currentUptime -
            lastMinimapAcceptedFrameUptime >=
            minimapMinimumInterval

        let shouldAnalyzeMinimap =
            minimapTimePassed &&
            !minimapAnalysisInProgress

        if shouldAnalyzeMinimap {
            lastMinimapAcceptedFrameUptime =
                currentUptime

            minimapAnalysisInProgress =
                true

            pendingTrackingPixelBuffer =
                nil

            pendingTrackingFrameUptime =
                0

        } else if minimapAnalysisInProgress {
            pendingTrackingPixelBuffer =
                pixelBuffer

            pendingTrackingFrameUptime =
                currentUptime
        }

        stateLock.unlock()

        if shouldAnalyzeSpeed {
            speedAnalysisQueue.async {
                [weak self, pixelBuffer] in

                self?.analyzeSpeed(
                    pixelBuffer:
                        pixelBuffer,
                    capturedFrameCount:
                        currentCapturedFrameCount,
                    sourceFrameUptime:
                        currentUptime,
                    generation:
                        currentGeneration
                )
            }
        }

        if shouldAnalyzeMinimap {
            minimapAnalysisQueue.async {
                [weak self, pixelBuffer] in

                self?.analyzeMinimap(
                    pixelBuffer:
                        pixelBuffer,
                    sourceFrameUptime:
                        currentUptime,
                    generation:
                        currentGeneration
                )
            }
        }
    }

    // MARK: - Reset

    func reset() {
        stateLock.lock()

        generation +=
            1

        let currentGeneration =
            generation

        capturedFrameCountStorage =
            0

        speedAnalyzedFrameCountStorage =
            0

        speedAnalysisInProgress =
            false

        lastSpeedAcceptedFrameUptime =
            0

        speedCompletionTimes =
            []

        recentSpeedSamples =
            []

        minimapAnalyzedFrameCountStorage =
            0

        minimapAnalysisInProgress =
            false

        lastMinimapAcceptedFrameUptime =
            0

        minimapCompletionTimes =
            []

        latestCompletedMinimapResultSequence =
            0

        pendingTrackingPixelBuffer =
            nil

        pendingTrackingFrameUptime =
            0

        stableSpeedStorage =
            nil

        pendingJumpSpeedStorage =
            nil

        consecutiveSpeedMissesStorage =
            0

        detectedSpeedUnitStorage = confirmedGuidanceSpeedUnit()?.uppercased()

        stateLock.unlock()

        minimapAnalysisQueue.async {
            [weak self] in

            self?.minimapCoachEngine.reset()
            self?.liveTurnPipeline.reset()
        }

        DispatchQueue.main.async {
            [weak self] in

            guard let self,
                  self.isCurrentGeneration(
                    currentGeneration
                  ) else {
                return
            }

            self.frameWidth = 0
            self.frameHeight = 0

            self.capturedFrameCount = 0

            self.lastFrameDate = nil

            self.speedAnalyzedFrameCount = 0
            self.speedAnalysisFPS = 0

            self.analyzedFrameCount = 0
            self.analysisFPS = 0

            self.minimapSnapshot =
                .empty

            self.roadLines = .empty
            self.turnGuidance = .empty

            self.detectedSpeed = nil
            self.rawDetectedSpeed = nil
            self.detectedSpeedUnit = nil

            self.speedConfidence = 0

            self.rawSpeedOCRText = ""

            self.speedOCRMilliseconds = 0
        }
    }

    // MARK: - Speed Analysis

    private func analyzeSpeed(
        pixelBuffer:
            CVPixelBuffer,
        capturedFrameCount:
            Int,
        sourceFrameUptime:
            TimeInterval,
        generation currentGeneration:
            Int
    ) {
        autoreleasepool {
            let width =
                CVPixelBufferGetWidth(
                    pixelBuffer
                )

            let height =
                CVPixelBufferGetHeight(
                    pixelBuffer
                )

            let startUptime =
                ProcessInfo
                    .processInfo
                    .systemUptime

            let speedOCRResult =
                recognizeSpeed(
                    in:
                        pixelBuffer
                )

            let completionUptime =
                ProcessInfo
                    .processInfo
                    .systemUptime

            let speedOCRMilliseconds =
                (completionUptime -
                 startUptime) *
                1000.0

            let frameDate =
                Date()

            stateLock.lock()

            guard currentGeneration ==
                    generation else {

                stateLock.unlock()
                return
            }

            speedAnalyzedFrameCountStorage +=
                1

            let analyzedCount =
                speedAnalyzedFrameCountStorage

            let measuredFPS =
                rollingFPS(
                    completionTime:
                        completionUptime,
                    times:
                        &speedCompletionTimes
                )

            let stabilizedSpeed =
                updateSpeedFilterLocked(
                    rawSpeed:
                        speedOCRResult.speed
                )

            let stabilizedUnit =
                detectedSpeedUnitStorage

            // A rejected jump retains the display value, but must not renew
            // the timestamp of that old value as fresh coaching evidence.
            if let rawSpeed = speedOCRResult.speed,
               let stabilizedSpeed, rawSpeed == stabilizedSpeed {

                recentSpeedSamples.append(
                    MinimapSpeedSample(
                        value:
                            stabilizedSpeed,
                        confidence:
                            speedOCRResult.confidence,
                        sourceFrameUptime:
                            sourceFrameUptime,
                        completionUptime: completionUptime,
                        sourceSessionID: currentGeneration
                    )
                )

                recentSpeedSamples.removeAll {
                    sourceFrameUptime -
                    $0.sourceFrameUptime >
                    2.0
                }

                if recentSpeedSamples.count > 24 {
                    recentSpeedSamples.removeFirst(
                        recentSpeedSamples.count - 24
                    )
                }
            }

            speedAnalysisInProgress =
                false

            stateLock.unlock()

            DispatchQueue.main.async {
                [weak self] in

                guard let self,
                      self.isCurrentGeneration(
                        currentGeneration
                      ) else {
                    return
                }

                self.frameWidth =
                    width

                self.frameHeight =
                    height

                self.capturedFrameCount =
                    capturedFrameCount

                self.lastFrameDate =
                    frameDate

                self.speedAnalyzedFrameCount =
                    analyzedCount

                self.speedAnalysisFPS =
                    measuredFPS

                self.analyzedFrameCount =
                    analyzedCount

                self.analysisFPS =
                    measuredFPS

                self.detectedSpeed =
                    stabilizedSpeed

                self.rawDetectedSpeed =
                    speedOCRResult.speed

                self.detectedSpeedUnit =
                    stabilizedUnit

                self.speedConfidence =
                    speedOCRResult.confidence

                self.rawSpeedOCRText =
                    speedOCRResult.rawText

                self.speedOCRMilliseconds =
                    speedOCRMilliseconds
            }
        }
    }

    // MARK: - Minimap Analysis

    private func analyzeMinimap(
        pixelBuffer:
            CVPixelBuffer,
        sourceFrameUptime:
            TimeInterval,
        generation currentGeneration:
            Int
    ) {
        autoreleasepool {
            let road = roadLineDetector.analyze(pixelBuffer, at: sourceFrameUptime,
                camera: RoadCameraMode(rawValue: UserDefaults.standard.string(forKey: "hud.pathRibbonCamera") ?? "chase") ?? .chase)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentGeneration(currentGeneration) else { return }
                self.roadLines = road
            }
            let startUptime =
                ProcessInfo
                    .processInfo
                    .systemUptime

            let result =
                detectMinimapElements(
                    in:
                        pixelBuffer
                )

            let detectionCompletionUptime =
                ProcessInfo
                    .processInfo
                    .systemUptime

            stateLock.lock()

            guard currentGeneration ==
                    generation else {

                stateLock.unlock()
                return
            }

            let fullSpeedSample =
                closestSpeedSampleLocked(
                    to:
                        sourceFrameUptime
                )

            stateLock.unlock()

            var coachResult =
                minimapCoachEngine
                    .processFullDetection(
                        result,
                        sourceFrameUptime:
                            sourceFrameUptime,
                        completionUptime:
                            detectionCompletionUptime,
                        speedSample:
                            fullSpeedSample,
                        sourceSessionID: currentGeneration
                    )

            // Pull the newest frame only after the expensive detector and
            // centerline work finish. This skips every stale frame in between.
            stateLock.lock()

            guard currentGeneration ==
                    generation else {

                stateLock.unlock()
                return
            }

            let trackingPixelBuffer =
                pendingTrackingFrameUptime >
                    sourceFrameUptime
                ? pendingTrackingPixelBuffer
                : nil

            let trackingFrameUptime =
                pendingTrackingFrameUptime

            let trackingSpeedSample =
                closestSpeedSampleLocked(
                    to:
                        trackingFrameUptime
                )

            pendingTrackingPixelBuffer =
                nil

            pendingTrackingFrameUptime =
                0

            stateLock.unlock()

            if let trackingPixelBuffer,
               trackingFrameUptime >
                sourceFrameUptime {

                let trackedResult =
                    minimapCoachEngine
                        .processTrackedFrame(
                            pixelBuffer:
                                trackingPixelBuffer,
                            sourceFrameUptime:
                                trackingFrameUptime,
                            completionUptime:
                                ProcessInfo
                                    .processInfo
                                    .systemUptime,
                            speedSample:
                                trackingSpeedSample,
                            sourceSessionID: currentGeneration
                        )

                if let trackedResult {
                    coachResult =
                        trackedResult

                } else if coachResult.state ==
                            .ready {

                    coachResult =
                        minimapCoachEngine
                            .suppressGuidanceAfterTrackingFailure(
                                coachResult,
                                latestFrameUptime:
                                    trackingFrameUptime
                            )
                }
            }

            let completionUptime =
                ProcessInfo
                    .processInfo
                    .systemUptime

            let milliseconds =
                (completionUptime -
                 startUptime) *
                1000.0

            stateLock.lock()

            guard currentGeneration ==
                    generation else {

                stateLock.unlock()
                return
            }

            minimapAnalyzedFrameCountStorage +=
                1

            let analyzedCount =
                minimapAnalyzedFrameCountStorage

            let measuredFPS =
                rollingFPS(
                    completionTime:
                        completionUptime,
                    times:
                        &minimapCompletionTimes
                )

            latestCompletedMinimapResultSequence +=
                1

            let currentSpeed = closestSpeedSampleLocked(to: coachResult.sourceFrameUptime)
            let confirmedUnit = detectedSpeedUnitStorage?.lowercased()
            let liveGuidance = liveTurnPipeline.process(coach: coachResult,
                minimapVisible: result.minimapVisible, minimapConfidence: result.minimapConfidence,
                speed: currentSpeed, speedUnit: confirmedUnit, session: currentGeneration, completedAt: completionUptime)
            coachResult = coachResult.applying(liveGuidance, at: completionUptime)

            let resultSequence =
                latestCompletedMinimapResultSequence

            minimapAnalysisInProgress =
                false

            // A frame may have arrived during the very short tracking pass.
            // It is intentionally discarded; the next accepted frame starts a
            // fresh full detection rather than extending a stale work queue.
            pendingTrackingPixelBuffer =
                nil

            pendingTrackingFrameUptime =
                0

            stateLock.unlock()

            DispatchQueue.main.async {
                [weak self] in

                guard let self,
                      self.shouldPublishMinimapResult(
                        sequence:
                            resultSequence,
                        generation:
                            currentGeneration
                      ) else {
                    return
                }

                // One published assignment keeps the badge, confidence,
                // statistics, and image in sync and avoids a burst of
                // separate SwiftUI redraws for every analyzed frame.
                self.minimapSnapshot =
                    MinimapAnalyzerSnapshot(
                        analyzedFrameCount:
                            analyzedCount,
                        analysisFPS:
                            measuredFPS,
                        analysisMilliseconds:
                            milliseconds,
                        minimapVisible:
                            result.minimapVisible,
                        minimapConfidence:
                            result.minimapConfidence,
                        playerDetectionConfidence:
                            result.playerDetectionConfidence,
                        rimStructureConfidence:
                            result.rimStructureConfidence,
                        routeDetected:
                            result.routeDetected,
                        routeConfidence:
                            result.routeConfidence,
                        routeSource:
                            result.routeSource,
                        diagnostic:
                            result.diagnostic,
                        cyanMarkerPixelCount:
                            result.cyanPlayerPixelCount,
                        routeMaskPixelCount:
                            result.routeMaskPixelCount,
                        yellowCandidatePixelCount:
                            result.yellowCandidatePixelCount,
                        learnedCandidatePixelCount:
                            result.learnedCandidatePixelCount,
                        shortRouteCandidateFound:
                            result.shortRouteCandidateFound,
                        shortRouteVerifierConfidence:
                            result.shortRouteVerifierConfidence,
                        routeComponentCount:
                            result.routeComponentCount,
                        ignoredYellowComponentCount:
                            result.ignoredYellowComponentCount,
                        routeMaskImage:
                            result.routeMaskImage,
                        coach:
                            coachResult
                    )
                self.turnGuidance = liveGuidance
            }
        }
    }

    private func detectMinimapElements(
        in pixelBuffer:
            CVPixelBuffer
    ) -> MinimapRouteAnalysis {

        minimapRouteDetector.analyze(
            pixelBuffer:
                pixelBuffer,
            normalizedCropRect:
                MotorfestHUDLayout
                    .minimapAnalysisRect,
            includeTrainingMask:
                true
        )
    }

    /// Call only while `stateLock` is held.
    private func closestSpeedSampleLocked(
        to sourceFrameUptime:
            TimeInterval
    ) -> MinimapSpeedSample? {

        recentSpeedSamples.min {
            abs(
                $0.sourceFrameUptime -
                sourceFrameUptime
            ) <
            abs(
                $1.sourceFrameUptime -
                sourceFrameUptime
            )
        }
    }

    // MARK: - Rolling FPS

    private func rollingFPS(
        completionTime:
            TimeInterval,
        times:
            inout [TimeInterval]
    ) -> Double {

        times.append(
            completionTime
        )

        let windowStart =
            completionTime -
            2.0

        times.removeAll {
            $0 < windowStart
        }

        guard let firstTime =
                times.first,
              let lastTime =
                times.last,
              times.count > 1,
              lastTime > firstTime else {

            return 0
        }

        return Double(
            times.count -
            1
        ) /
        (lastTime -
         firstTime)
    }

    // MARK: - Vision Speed OCR

    private func recognizeSpeed(in pixelBuffer: CVPixelBuffer) -> SpeedOCRResult {
        let reference = UserDefaults.standard.string(forKey: "guidance.hudProfile") == "reference-video2-v1"
        let crop = reference ? CGRect(x: 0.075, y: 0.854, width: 0.070, height: 0.073) : MotorfestHUDLayout.speedOCR.normalizedRect
        return MotorfestSpeedRecognizer.recognize(in: pixelBuffer, region: crop, rejectEdgePixels: true)
    }

    private func confirmedGuidanceSpeedUnit() -> String? {
        let unit = UserDefaults.standard.string(forKey: "guidance.speedUnit") ?? "km/h"
        return ["km/h", "mph"].contains(unit) ? unit : nil
    }

    // MARK: - Speed Stabilization

    private func updateSpeedFilterLocked(
        rawSpeed:
            Int?
    ) -> Int? {

        guard let rawSpeed else {

            consecutiveSpeedMissesStorage +=
                1

            pendingJumpSpeedStorage =
                nil

            if consecutiveSpeedMissesStorage >=
                missesBeforeClearingSpeed {

                stableSpeedStorage =
                    nil
            }

            return stableSpeedStorage
        }

        consecutiveSpeedMissesStorage =
            0

        guard let stableSpeed =
                stableSpeedStorage else {

            stableSpeedStorage =
                rawSpeed

            pendingJumpSpeedStorage =
                nil

            return rawSpeed
        }

        let difference =
            abs(
                rawSpeed -
                stableSpeed
            )

        if difference <=
            maximumSingleFrameSpeedChange {

            stableSpeedStorage =
                rawSpeed

            pendingJumpSpeedStorage =
                nil

            return rawSpeed
        }

        if let pendingJumpSpeed =
                pendingJumpSpeedStorage,
           abs(
                rawSpeed -
                pendingJumpSpeed
           ) <=
            matchingJumpTolerance {

            stableSpeedStorage =
                rawSpeed

            pendingJumpSpeedStorage =
                nil

            return rawSpeed
        }

        pendingJumpSpeedStorage =
            rawSpeed

        return stableSpeed
    }

    // MARK: - Generation

    private func isCurrentGeneration(
        _ expectedGeneration:
            Int
    ) -> Bool {

        stateLock.lock()

        let isCurrent =
            generation ==
            expectedGeneration

        stateLock.unlock()

        return isCurrent
    }

    private func shouldPublishMinimapResult(
        sequence:
            Int,
        generation expectedGeneration:
            Int
    ) -> Bool {

        stateLock.lock()

        let shouldPublish =
            generation ==
                expectedGeneration &&
            latestCompletedMinimapResultSequence ==
                sequence

        stateLock.unlock()

        return shouldPublish
    }
}
