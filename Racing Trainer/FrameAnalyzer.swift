import AVFoundation
import Combine
import CoreGraphics
import CoreVideo
import Foundation
import Vision

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

    let routeDetected:
        Bool

    let routeConfidence:
        Float

    let cyanMarkerPixelCount:
        Int

    let routeMaskPixelCount:
        Int

    let yellowCandidatePixelCount:
        Int

    let routeComponentCount:
        Int

    let ignoredYellowComponentCount:
        Int

    let routeMaskImage:
        CGImage?

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
            routeDetected:
                false,
            routeConfidence:
                0,
            cyanMarkerPixelCount:
                0,
            routeMaskPixelCount:
                0,
            yellowCandidatePixelCount:
                0,
            routeComponentCount:
                0,
            ignoredYellowComponentCount:
                0,
            routeMaskImage:
                nil
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

    private let maximumReasonableSpeed =
        650

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

        stableSpeedStorage =
            nil

        pendingJumpSpeedStorage =
            nil

        consecutiveSpeedMissesStorage =
            0

        detectedSpeedUnitStorage =
            MotorfestHUDLayout.speedUnit

        stateLock.unlock()

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
        generation currentGeneration:
            Int
    ) {
        autoreleasepool {
            let startUptime =
                ProcessInfo
                    .processInfo
                    .systemUptime

            let result =
                detectMinimapElements(
                    in:
                        pixelBuffer
                )

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

            let resultSequence =
                latestCompletedMinimapResultSequence

            minimapAnalysisInProgress =
                false

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
                        routeDetected:
                            result.routeDetected,
                        routeConfidence:
                            result.routeConfidence,
                        cyanMarkerPixelCount:
                            result.cyanPlayerPixelCount,
                        routeMaskPixelCount:
                            result.routeMaskPixelCount,
                        yellowCandidatePixelCount:
                            result.yellowCandidatePixelCount,
                        routeComponentCount:
                            result.routeComponentCount,
                        ignoredYellowComponentCount:
                            result.ignoredYellowComponentCount,
                        routeMaskImage:
                            result.routeMaskImage
                    )
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
                    .minimapAnalysisRect
        )
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

    private func recognizeSpeed(
        in pixelBuffer:
            CVPixelBuffer
    ) -> SpeedOCRResult {

        let request =
            VNRecognizeTextRequest()

        request.recognitionLevel =
            .fast

        request.minimumTextHeight =
            0.025

        request.usesLanguageCorrection =
            false

        request.regionOfInterest =
            visionRegion(
                fromTopLeftRegion:
                    MotorfestHUDLayout
                        .speedOCR
                        .normalizedRect
            )

        let handler =
            VNImageRequestHandler(
                cvPixelBuffer:
                    pixelBuffer,
                options:
                    [:]
            )

        do {
            try handler.perform(
                [request]
            )
        } catch {
            return SpeedOCRResult(
                speed:
                    nil,
                unit:
                    MotorfestHUDLayout
                        .speedUnit,
                confidence:
                    0,
                rawText:
                    ""
            )
        }

        guard let observations =
                request.results,
              !observations.isEmpty else {

            return SpeedOCRResult(
                speed:
                    nil,
                unit:
                    MotorfestHUDLayout
                        .speedUnit,
                confidence:
                    0,
                rawText:
                    ""
            )
        }

        var displayedNumericFragments:
            [String] = []

        var speedCandidates:
            [SpeedCandidate] = []

        for observation in observations {

            let topCandidates =
                observation.topCandidates(
                    3
                )

            if let primaryCandidate =
                    topCandidates.first {

                let normalizedPrimary =
                    normalizedNumericOCRText(
                        primaryCandidate.string
                    )

                if !normalizedPrimary.isEmpty {

                    displayedNumericFragments.append(
                        normalizedPrimary
                    )
                }
            }

            for recognizedText in
                topCandidates {

                let normalizedText =
                    normalizedNumericOCRText(
                        recognizedText.string
                    )

                guard !normalizedText.isEmpty,
                      normalizedText.count <= 3,
                      let value =
                        Int(
                            normalizedText
                        ),
                      value >= 0,
                      value <=
                        maximumReasonableSpeed else {

                    continue
                }

                let score =
                    speedCandidateScore(
                        value:
                            value,
                        confidence:
                            recognizedText
                                .confidence,
                        boundingBox:
                            observation
                                .boundingBox
                    )

                speedCandidates.append(
                    SpeedCandidate(
                        value:
                            value,
                        confidence:
                            recognizedText
                                .confidence,
                        score:
                            score
                    )
                )
            }
        }

        let numericDebugText =
            displayedNumericFragments
                .joined(
                    separator:
                        " | "
                )

        guard let bestCandidate =
                speedCandidates.max(
                    by: {
                        $0.score <
                        $1.score
                    }
                ) else {

            return SpeedOCRResult(
                speed:
                    nil,
                unit:
                    MotorfestHUDLayout
                        .speedUnit,
                confidence:
                    0,
                rawText:
                    numericDebugText
            )
        }

        return SpeedOCRResult(
            speed:
                bestCandidate.value,
            unit:
                MotorfestHUDLayout
                    .speedUnit,
            confidence:
                bestCandidate.confidence,
            rawText:
                numericDebugText
        )
    }

    private func normalizedNumericOCRText(
        _ text:
            String
    ) -> String {

        var result =
            ""

        for character in text {

            if character.isNumber {

                result.append(
                    character
                )

                continue
            }

            switch character {

            case "O", "o", "Q":

                result.append(
                    "0"
                )

            case "I", "i", "l", "|":

                result.append(
                    "1"
                )

            case "Z", "z":

                result.append(
                    "2"
                )

            case "S", "s":

                result.append(
                    "5"
                )

            case "B":

                result.append(
                    "8"
                )

            default:

                break
            }
        }

        return result
    }

    private func visionRegion(
        fromTopLeftRegion region:
            CGRect
    ) -> CGRect {

        CGRect(
            x:
                region.minX,
            y:
                1.0 -
                region.maxY,
            width:
                region.width,
            height:
                region.height
        )
    }

    private func speedCandidateScore(
        value:
            Int,
        confidence:
            VNConfidence,
        boundingBox:
            CGRect
    ) -> Double {

        var score =
            Double(
                confidence
            ) *
            2.0

        let digitCount =
            String(
                value
            )
            .count

        score +=
            Double(
                digitCount
            ) *
            0.18

        let textArea =
            Double(
                boundingBox.width *
                boundingBox.height
            )

        score +=
            textArea *
            80.0

        if value < 10 {
            score -=
                0.12
        }

        return score
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

// MARK: - OCR Result

private struct SpeedOCRResult {

    let speed:
        Int?

    let unit:
        String?

    let confidence:
        Float

    let rawText:
        String
}

// MARK: - Speed Candidate

private struct SpeedCandidate {

    let value:
        Int

    let confidence:
        Float

    let score:
        Double
}
