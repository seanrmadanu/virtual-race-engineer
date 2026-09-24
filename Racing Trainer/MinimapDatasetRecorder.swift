import AppKit
import AVFoundation
import Combine
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class MinimapDatasetRecorder:
    ObservableObject {

    // MARK: - Published State

    @Published private(set)
    var isRecording = false

    @Published private(set)
    var savedImageCount = 0

    @Published private(set)
    var skippedDuplicateCount = 0

    @Published private(set)
    var lastSavedImageName:
        String?

    @Published private(set)
    var lastErrorMessage:
        String?

    // MARK: - Recording Settings

    let sampleInterval:
        TimeInterval

    let minimumFrameDifference:
        Double

    // MARK: - Storage

    let datasetFolderURL:
        URL

    let metadataStore:
        DatasetMetadataStore

    let routeMaskDatasetStore:
        RouteMaskDatasetStore

    var datasetFolderPath:
        String {

        datasetFolderURL.path
    }

    // MARK: - Worker Queue

    private let recorderQueue =
        DispatchQueue(
            label:
                "com.racingtrainer.minimap-dataset-recorder",
            qos:
                .utility
        )

    private let ciContext =
        CIContext(
            options:
                nil
        )

    private let routeDetector =
        MinimapRouteDetector()

    // MARK: - Thread State

    private let stateLock =
        NSLock()

    private var recordingStorage =
        false

    private var writeInProgress =
        false

    private var lastAcceptedFrameUptime =
        0.0

    private var previousSavedSignature:
        [UInt8]?

    private var recordingGeneration =
        0

    private var sourceDescriptor =
        RouteMaskSourceDescriptor
            .liveCapture

    private var captureSessionID =
        UUID()
            .uuidString

    // Only accessed from recorderQueue.
    private var nextImageIndex =
        1

    // MARK: - Init

    init(
        sampleInterval:
            TimeInterval = 1.0,
        minimumFrameDifference:
            Double = 0.015
    ) {
        self.sampleInterval =
            max(
                sampleInterval,
                0.20
            )

        self.minimumFrameDifference =
            min(
                max(
                    minimumFrameDifference,
                    0
                ),
                1
            )

        let fileManager =
            FileManager.default

        let applicationSupportURL =
            fileManager.urls(
                for:
                    .applicationSupportDirectory,
                in:
                    .userDomainMask
            )
            .first!

        let rawFolderURL =
            applicationSupportURL
                .appendingPathComponent(
                    "Racing Trainer",
                    isDirectory: true
                )
                .appendingPathComponent(
                    "Dataset",
                    isDirectory: true
                )
                .appendingPathComponent(
                    "minimap",
                    isDirectory: true
                )
                .appendingPathComponent(
                    "raw",
                    isDirectory: true
                )

        datasetFolderURL =
            rawFolderURL

        metadataStore =
            DatasetMetadataStore(
                rawFolderURL:
                    rawFolderURL
            )

        routeMaskDatasetStore =
            RouteMaskDatasetStore(
                rawFolderURL:
                    rawFolderURL
            )

        do {
            try fileManager.createDirectory(
                at:
                    datasetFolderURL,
                withIntermediateDirectories:
                    true
            )

            let existingCount =
                Self.existingPNGCount(
                    in:
                        datasetFolderURL
                )

            savedImageCount =
                existingCount

            nextImageIndex =
                Self.nextAvailableIndex(
                    in:
                        datasetFolderURL
                )

        } catch {
            lastErrorMessage =
                error.localizedDescription
        }
    }

    // MARK: - Recording Controls

    func startRecording() {
        recorderQueue.async {
            [weak self] in

            guard let self else {
                return
            }

            do {
                try FileManager.default
                    .createDirectory(
                        at:
                            self.datasetFolderURL,
                        withIntermediateDirectories:
                            true
                    )
            } catch {
                DispatchQueue.main.async {
                    self.lastErrorMessage =
                        error.localizedDescription
                }

                return
            }

            let existingCount =
                Self.existingPNGCount(
                    in:
                        self.datasetFolderURL
                )

            self.nextImageIndex =
                Self.nextAvailableIndex(
                    in:
                        self.datasetFolderURL
                )

            self.metadataStore.refresh()

            self.routeMaskDatasetStore
                .refresh()

            self.stateLock.lock()

            self.recordingGeneration +=
                1

            self.captureSessionID =
                UUID()
                    .uuidString

            self.recordingStorage =
                true

            self.lastAcceptedFrameUptime =
                0

            self.previousSavedSignature =
                nil

            self.writeInProgress =
                false

            self.stateLock.unlock()

            DispatchQueue.main.async {
                self.savedImageCount =
                    existingCount

                self.skippedDuplicateCount =
                    0

                self.lastSavedImageName =
                    nil

                self.lastErrorMessage =
                    nil

                self.isRecording =
                    true
            }
        }
    }

    func stopRecording() {
        stateLock.lock()

        recordingGeneration +=
            1

        recordingStorage =
            false

        lastAcceptedFrameUptime =
            0

        stateLock.unlock()

        DispatchQueue.main.async {
            [weak self] in

            self?.isRecording =
                false
        }
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    // MARK: - Source Metadata

    func setSource(
        kind:
            RouteMaskSourceKind,
        displayName:
            String,
        stableIdentifier:
            String
    ) {
        let trimmedName =
            displayName
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )

        let trimmedIdentifier =
            stableIdentifier
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )

        stateLock.lock()

        sourceDescriptor =
            RouteMaskSourceDescriptor(
                kind:
                    kind,
                displayName:
                    trimmedName.isEmpty
                    ? "Unknown Source"
                    : trimmedName,
                stableIdentifier:
                    trimmedIdentifier.isEmpty
                    ? UUID().uuidString
                    : trimmedIdentifier
            )

        captureSessionID =
            UUID()
                .uuidString

        stateLock.unlock()
    }

    func useLiveCaptureSource() {
        setSource(
            kind:
                .liveCapture,
            displayName:
                "Live Capture",
            stableIdentifier:
                "live-\(UUID().uuidString)"
        )
    }

    // MARK: - Receive Frame

    func receive(
        _ sampleBuffer:
            CMSampleBuffer
    ) {
        guard CMSampleBufferDataIsReady(
            sampleBuffer
        ),
        let pixelBuffer =
            CMSampleBufferGetImageBuffer(
                sampleBuffer
            ) else {

            return
        }

        let presentationTime =
            CMSampleBufferGetPresentationTimeStamp(
                sampleBuffer
            )

        let timeSeconds =
            presentationTime
                .isValid &&
            presentationTime
                .isNumeric
            ? presentationTime.seconds
            : nil

        receive(
            pixelBuffer,
            sourceTimeSeconds:
                timeSeconds
        )
    }

    func receive(
        _ pixelBuffer:
            CVPixelBuffer,
        sourceTimeSeconds:
            Double? = nil
    ) {

        let currentUptime =
            ProcessInfo
                .processInfo
                .systemUptime

        stateLock.lock()

        guard recordingStorage else {
            stateLock.unlock()
            return
        }

        guard !writeInProgress else {
            stateLock.unlock()
            return
        }

        let timeSinceLastAcceptedFrame =
            currentUptime -
            lastAcceptedFrameUptime

        guard timeSinceLastAcceptedFrame >=
                sampleInterval else {

            stateLock.unlock()
            return
        }

        lastAcceptedFrameUptime =
            currentUptime

        writeInProgress =
            true

        let currentGeneration =
            recordingGeneration

        let currentSource =
            sourceDescriptor

        let currentCaptureSessionID =
            captureSessionID

        stateLock.unlock()

        recorderQueue.async {
            [weak self, pixelBuffer] in

            self?.processFrame(
                pixelBuffer,
                generation:
                    currentGeneration,
                source:
                    currentSource,
                captureSessionID:
                    currentCaptureSessionID,
                sourceTimeSeconds:
                    sourceTimeSeconds
            )
        }
    }

    // MARK: - Process Frame

    private func processFrame(
        _ pixelBuffer:
            CVPixelBuffer,
        generation:
            Int,
        source:
            RouteMaskSourceDescriptor,
        captureSessionID:
            String,
        sourceTimeSeconds:
            Double?
    ) {
        autoreleasepool {
            guard isGenerationActive(
                generation
            ) else {

                finishWrite()
                return
            }

            let frameWidth =
                CVPixelBufferGetWidth(
                    pixelBuffer
                )

            let frameHeight =
                CVPixelBufferGetHeight(
                    pixelBuffer
                )

            guard frameWidth > 0,
                  frameHeight > 0 else {

                finishWrite()
                return
            }

            let topLeftCropRect =
                pixelRect(
                    normalizedRect:
                        MotorfestHUDLayout
                            .minimapAnalysisRect,
                    frameWidth:
                        frameWidth,
                    frameHeight:
                        frameHeight
                )

            guard topLeftCropRect.width > 0,
                  topLeftCropRect.height > 0 else {

                finishWrite()
                return
            }

            guard let signature =
                    makeSignature(
                        pixelBuffer:
                            pixelBuffer,
                        cropRect:
                            topLeftCropRect
                    ) else {

                publishError(
                    "Dataset recorder expected a BGRA video frame."
                )

                finishWrite()
                return
            }

            if let previousSavedSignature {
                let difference =
                    meanAbsoluteDifference(
                        first:
                            previousSavedSignature,
                        second:
                            signature
                    )

                if difference <
                    minimumFrameDifference {

                    publishDuplicateSkip()

                    finishWrite()
                    return
                }
            }

            guard isGenerationActive(
                generation
            ) else {

                finishWrite()
                return
            }

            guard let croppedImage =
                    createMinimapImage(
                        from:
                            pixelBuffer,
                        topLeftCropRect:
                            topLeftCropRect
                    ) else {

                publishError(
                    "Could not create minimap crop."
                )

                finishWrite()
                return
            }

            let routeAnalysis =
                routeDetector
                    .analyze(
                        pixelBuffer:
                            pixelBuffer,
                        normalizedCropRect:
                            MotorfestHUDLayout
                                .minimapAnalysisRect,
                        includeTrainingMask:
                            true
                    )

            guard let routeMask =
                    routeAnalysis
                        .routeMask else {

                publishError(
                    "Could not create the automatic route mask."
                )

                finishWrite()
                return
            }

            guard isGenerationActive(
                generation
            ) else {

                finishWrite()
                return
            }

            let imageIndex =
                nextImageIndex

            nextImageIndex +=
                1

            let filename =
                String(
                    format:
                        "map_%06d.png",
                    imageIndex
                )

            let outputURL =
                datasetFolderURL
                    .appendingPathComponent(
                        filename
                    )

            let predictedMaskURL =
                routeMaskDatasetStore
                    .predictedFolderURL
                    .appendingPathComponent(
                        filename
                    )

            do {
                try writePNG(
                    croppedImage,
                    to:
                        outputURL
                )

                try writeMaskPNG(
                    routeMask,
                    to:
                        predictedMaskURL
                )

                let sampleID =
                    outputURL
                        .deletingPathExtension()
                        .lastPathComponent

                let sourceGroupID =
                    Self.sourceGroupID(
                        for:
                            source,
                        captureSessionID:
                            captureSessionID
                    )

                let record =
                    RouteMaskSampleRecord(
                        id:
                            sampleID,
                        imageFileName:
                            filename,
                        predictedMaskFileName:
                            filename,
                        sourceKind:
                            source.kind,
                        sourceName:
                            source.displayName,
                        sourceGroupID:
                            sourceGroupID,
                        captureSessionID:
                            captureSessionID,
                        sourceTimeSeconds:
                            sourceTimeSeconds,
                        width:
                            routeMask.width,
                        height:
                            routeMask.height,
                        minimapVisible:
                            routeAnalysis
                                .minimapVisible,
                        minimapConfidence:
                            routeAnalysis
                                .minimapConfidence,
                        routeDetected:
                            routeAnalysis
                                .routeDetected,
                        routeConfidence:
                            routeAnalysis
                                .routeConfidence,
                        routeMaskPixelCount:
                            routeAnalysis
                                .routeMaskPixelCount
                    )

                routeMaskDatasetStore
                    .registerCapturedSample(
                        record
                    )

                previousSavedSignature =
                    signature

                publishSuccessfulSave(
                    filename:
                        filename
                )

            } catch {
                publishError(
                    error.localizedDescription
                )
            }

            finishWrite()
        }
    }

    // MARK: - Crop

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
                x: 0,
                y: 0,
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

    private func createMinimapImage(
        from pixelBuffer:
            CVPixelBuffer,
        topLeftCropRect:
            CGRect
    ) -> CGImage? {

        let frameHeight =
            CGFloat(
                CVPixelBufferGetHeight(
                    pixelBuffer
                )
            )

        let coreImageCropRect =
            CGRect(
                x:
                    topLeftCropRect.minX,

                y:
                    frameHeight -
                    topLeftCropRect.maxY,

                width:
                    topLeftCropRect.width,

                height:
                    topLeftCropRect.height
            )

        let sourceImage =
            CIImage(
                cvPixelBuffer:
                    pixelBuffer
            )

        return ciContext.createCGImage(
            sourceImage,
            from:
                coreImageCropRect
        )
    }

    // MARK: - Duplicate Detection

    private func makeSignature(
        pixelBuffer:
            CVPixelBuffer,
        cropRect:
            CGRect
    ) -> [UInt8]? {

        let pixelFormat =
            CVPixelBufferGetPixelFormatType(
                pixelBuffer
            )

        guard pixelFormat ==
                kCVPixelFormatType_32BGRA else {

            return nil
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

            return nil
        }

        let bytesPerRow =
            CVPixelBufferGetBytesPerRow(
                pixelBuffer
            )

        let frameWidth =
            CVPixelBufferGetWidth(
                pixelBuffer
            )

        let frameHeight =
            CVPixelBufferGetHeight(
                pixelBuffer
            )

        let pixels =
            baseAddress
                .assumingMemoryBound(
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

            return nil
        }

        let gridSize =
            24

        var signature:
            [UInt8] = []

        signature.reserveCapacity(
            gridSize *
            gridSize
        )

        for gridY in 0..<gridSize {

            let sampleY =
                minY +
                Int(
                    (
                        Double(gridY) +
                        0.5
                    ) /
                    Double(gridSize) *
                    Double(cropHeight)
                )

            let safeY =
                min(
                    max(
                        sampleY,
                        minY
                    ),
                    maxY - 1
                )

            for gridX in 0..<gridSize {

                let sampleX =
                    minX +
                    Int(
                        (
                            Double(gridX) +
                            0.5
                        ) /
                    Double(gridSize) *
                    Double(cropWidth)
                )

                let safeX =
                    min(
                        max(
                            sampleX,
                            minX
                        ),
                        maxX - 1
                    )

                let pixelOffset =
                    safeY *
                    bytesPerRow +
                    safeX *
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

                let luminance =
                    (
                        red *
                        54 +
                        green *
                        183 +
                        blue *
                        19
                    ) >>
                    8

                signature.append(
                    UInt8(
                        min(
                            max(
                                luminance,
                                0
                            ),
                            255
                        )
                    )
                )
            }
        }

        return signature
    }

    private func meanAbsoluteDifference(
        first:
            [UInt8],
        second:
            [UInt8]
    ) -> Double {

        guard first.count ==
                second.count,
              !first.isEmpty else {

            return 1
        }

        var totalDifference =
            0

        for index in
            first.indices {

            totalDifference +=
                abs(
                    Int(
                        first[index]
                    ) -
                    Int(
                        second[index]
                    )
                )
        }

        let maximumDifference =
            Double(
                first.count *
                255
            )

        guard maximumDifference > 0 else {
            return 1
        }

        return Double(
            totalDifference
        ) /
        maximumDifference
    }

    // MARK: - PNG Writing

    private func writePNG(
        _ image:
            CGImage,
        to url:
            URL
    ) throws {

        guard let destination =
                CGImageDestinationCreateWithURL(
                    url as CFURL,
                    UTType.png.identifier
                        as CFString,
                    1,
                    nil
                ) else {

            throw MinimapDatasetRecorderError(
                message:
                    "Could not create PNG destination."
            )
        }

        CGImageDestinationAddImage(
            destination,
            image,
            nil
        )

        guard CGImageDestinationFinalize(
            destination
        ) else {

            throw MinimapDatasetRecorderError(
                message:
                    "Could not save minimap PNG."
            )
        }
    }

    private func writeMaskPNG(
        _ mask:
            MinimapRouteMask,
        to url:
            URL
    ) throws {

        guard mask.width > 0,
              mask.height > 0,
              mask.pixels.count ==
                mask.width *
                mask.height,
              let provider =
                CGDataProvider(
                    data:
                        mask.pixels
                        as CFData
                ),
              let image =
                CGImage(
                    width:
                        mask.width,
                    height:
                        mask.height,
                    bitsPerComponent:
                        8,
                    bitsPerPixel:
                        8,
                    bytesPerRow:
                        mask.width,
                    space:
                        CGColorSpaceCreateDeviceGray(),
                    bitmapInfo:
                        CGBitmapInfo(
                            rawValue:
                                CGImageAlphaInfo
                                    .none
                                    .rawValue
                        ),
                    provider:
                        provider,
                    decode:
                        nil,
                    shouldInterpolate:
                        false,
                    intent:
                        .defaultIntent
                ),
              let destination =
                CGImageDestinationCreateWithURL(
                    url as CFURL,
                    UTType.png.identifier
                        as CFString,
                    1,
                    nil
                ) else {

            throw MinimapDatasetRecorderError(
                message:
                    "Could not create predicted mask PNG."
            )
        }

        CGImageDestinationAddImage(
            destination,
            image,
            nil
        )

        guard CGImageDestinationFinalize(
            destination
        ) else {

            throw MinimapDatasetRecorderError(
                message:
                    "Could not save predicted route mask."
            )
        }
    }

    // MARK: - Folder

    func revealDatasetFolder() {
        recorderQueue.async {
            [weak self] in

            guard let self else {
                return
            }

            do {
                try FileManager.default
                    .createDirectory(
                        at:
                            self.datasetFolderURL,
                        withIntermediateDirectories:
                            true
                    )

                self.metadataStore.refresh()

                self.routeMaskDatasetStore
                    .refresh()

                DispatchQueue.main.async {
                    NSWorkspace.shared.open(
                        self.datasetFolderURL
                    )
                }

            } catch {
                self.publishError(
                    error.localizedDescription
                )
            }
        }
    }

    // MARK: - State Helpers

    private func isGenerationActive(
        _ expectedGeneration:
            Int
    ) -> Bool {

        stateLock.lock()

        let active =
            recordingStorage &&
            recordingGeneration ==
            expectedGeneration

        stateLock.unlock()

        return active
    }

    private func finishWrite() {
        stateLock.lock()

        writeInProgress =
            false

        stateLock.unlock()
    }

    // MARK: - UI Publishing

    private func publishSuccessfulSave(
        filename:
            String
    ) {
        DispatchQueue.main.async {
            [weak self] in

            guard let self else {
                return
            }

            self.savedImageCount +=
                1

            self.lastSavedImageName =
                filename

            self.lastErrorMessage =
                nil

            self.metadataStore
                .rawImageWasAdded()
        }
    }

    private func publishDuplicateSkip() {
        DispatchQueue.main.async {
            [weak self] in

            guard let self else {
                return
            }

            self.skippedDuplicateCount +=
                1
        }
    }

    private func publishError(
        _ message:
            String
    ) {
        DispatchQueue.main.async {
            [weak self] in

            self?.lastErrorMessage =
                message
        }
    }

    // MARK: - Existing Dataset

    private static func existingPNGCount(
        in folderURL:
            URL
    ) -> Int {

        guard let files =
                try? FileManager.default
                    .contentsOfDirectory(
                        at:
                            folderURL,
                        includingPropertiesForKeys:
                            nil,
                        options:
                            [
                                .skipsHiddenFiles
                            ]
                    ) else {

            return 0
        }

        return files.filter {
            $0.pathExtension
                .lowercased() ==
                "png"
        }
        .count
    }

    private static func nextAvailableIndex(
        in folderURL:
            URL
    ) -> Int {

        guard let files =
                try? FileManager.default
                    .contentsOfDirectory(
                        at:
                            folderURL,
                        includingPropertiesForKeys:
                            nil,
                        options:
                            [
                                .skipsHiddenFiles
                            ]
                    ) else {

            return 1
        }

        var largestIndex =
            0

        for fileURL in files {

            guard fileURL.pathExtension
                    .lowercased() ==
                    "png" else {

                continue
            }

            let filename =
                fileURL
                    .deletingPathExtension()
                    .lastPathComponent

            guard filename.hasPrefix(
                "map_"
            ) else {

                continue
            }

            let numberString =
                String(
                    filename.dropFirst(
                        4
                    )
                )

            guard let imageIndex =
                    Int(
                        numberString
                    ) else {

                continue
            }

            largestIndex =
                max(
                    largestIndex,
                    imageIndex
                )
        }

        return largestIndex +
            1
    }

    private static func sourceGroupID(
        for source:
            RouteMaskSourceDescriptor,
        captureSessionID:
            String
    ) -> String {

        var hash:
            UInt64 =
                14_695_981_039_346_656_037

        let groupIdentifier =
            source.kind ==
                .liveCapture
            ? captureSessionID
            : source.stableIdentifier

        let value =
            "\(source.kind.rawValue):\(groupIdentifier)"

        for byte in value.utf8 {
            hash ^=
                UInt64(
                    byte
                )

            hash &*=
                1_099_511_628_211
        }

        let hashText =
            String(
                hash,
                radix:
                    16
            )

        let padding =
            String(
                repeating:
                    "0",
                count:
                    max(
                        16 -
                        hashText.count,
                        0
                    )
            )

        return "source_\(padding)\(hashText)"
    }
}

// MARK: - Error

private struct MinimapDatasetRecorderError:
    LocalizedError {

    let message:
        String

    var errorDescription:
        String? {

        message
    }
}
