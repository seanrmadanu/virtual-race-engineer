import AppKit
import Combine
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum RouteMaskReviewStatus: String, Codable, CaseIterable, Identifiable {
    case pending
    case accepted
    case corrected
    case rejected

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pending:
            return "Pending"
        case .accepted:
            return "Accepted"
        case .corrected:
            return "Corrected"
        case .rejected:
            return "Rejected"
        }
    }
}

enum RouteMaskSourceKind: String, Codable {
    case liveCapture
    case videoFile
    case legacyImport
}

struct RouteMaskSourceDescriptor {
    let kind: RouteMaskSourceKind
    let displayName: String
    let stableIdentifier: String

    static let liveCapture = RouteMaskSourceDescriptor(
        kind: .liveCapture,
        displayName: "Live Capture",
        stableIdentifier: "live-capture"
    )
}

struct RouteMaskSampleRecord: Codable, Identifiable {
    let schemaVersion: Int
    let id: String
    let imageFileName: String
    let predictedMaskFileName: String?
    var correctedMaskFileName: String?
    var reviewStatus: RouteMaskReviewStatus
    let capturedAt: Date
    var reviewedAt: Date?
    let sourceKind: RouteMaskSourceKind
    let sourceName: String
    let sourceGroupID: String
    let captureSessionID: String
    let sourceTimeSeconds: Double?
    let width: Int
    let height: Int
    let minimapVisible: Bool
    let minimapConfidence: Float
    let routeDetected: Bool
    let routeConfidence: Float
    let routeMaskPixelCount: Int

    init(
        id: String,
        imageFileName: String,
        predictedMaskFileName: String?,
        correctedMaskFileName: String? = nil,
        reviewStatus: RouteMaskReviewStatus = .pending,
        capturedAt: Date = Date(),
        reviewedAt: Date? = nil,
        sourceKind: RouteMaskSourceKind,
        sourceName: String,
        sourceGroupID: String,
        captureSessionID: String,
        sourceTimeSeconds: Double?,
        width: Int,
        height: Int,
        minimapVisible: Bool,
        minimapConfidence: Float,
        routeDetected: Bool,
        routeConfidence: Float,
        routeMaskPixelCount: Int
    ) {
        self.schemaVersion = 1
        self.id = id
        self.imageFileName = imageFileName
        self.predictedMaskFileName = predictedMaskFileName
        self.correctedMaskFileName = correctedMaskFileName
        self.reviewStatus = reviewStatus
        self.capturedAt = capturedAt
        self.reviewedAt = reviewedAt
        self.sourceKind = sourceKind
        self.sourceName = sourceName
        self.sourceGroupID = sourceGroupID
        self.captureSessionID = captureSessionID
        self.sourceTimeSeconds = sourceTimeSeconds
        self.width = width
        self.height = height
        self.minimapVisible = minimapVisible
        self.minimapConfidence = minimapConfidence
        self.routeDetected = routeDetected
        self.routeConfidence = routeConfidence
        self.routeMaskPixelCount = routeMaskPixelCount
    }
}

struct RouteMaskDatasetSample: Identifiable {
    var record: RouteMaskSampleRecord
    let imageURL: URL
    let predictedMaskURL: URL?
    let correctedMaskURL: URL?

    var id: String { record.id }

    var effectiveMaskURL: URL? {
        if record.reviewStatus == .corrected {
            return correctedMaskURL
        }

        return predictedMaskURL
    }
}

private struct RouteMaskExportItem: Codable {
    let sampleID: String
    let split: String
    let imagePath: String
    let maskPath: String
    let sourceGroupID: String
    let sourceName: String
    let reviewStatus: RouteMaskReviewStatus
    let routeDetectedByBootstrap: Bool
    let routeConfidence: Float
}

private struct RouteMaskExportManifest: Codable {
    let schemaVersion: Int
    let generatedAt: Date
    let trainingSampleCount: Int
    let validationSampleCount: Int
    let splitRule: String
    let samples: [RouteMaskExportItem]
}

final class RouteMaskDatasetStore: ObservableObject {
    @Published private(set) var rawImageCount = 0
    @Published private(set) var pendingCount = 0
    @Published private(set) var acceptedCount = 0
    @Published private(set) var correctedCount = 0
    @Published private(set) var rejectedCount = 0
    @Published private(set) var missingPredictionCount = 0
    @Published private(set) var isGeneratingPredictions = false
    @Published private(set) var generatedPredictionCount = 0
    @Published private(set) var predictionGenerationTotal = 0
    @Published private(set) var isExporting = false
    @Published private(set) var lastExportURL: URL?
    @Published private(set) var lastErrorMessage: String?

    let rootFolderURL: URL
    let rawFolderURL: URL
    let predictedFolderURL: URL
    let correctedFolderURL: URL
    let reviewFolderURL: URL
    let exportFolderURL: URL

    var reviewedCount: Int {
        acceptedCount + correctedCount + rejectedCount
    }

    var trainingReadyCount: Int {
        acceptedCount + correctedCount
    }

    private let ioQueue = DispatchQueue(
        label: "com.racingtrainer.route-mask-dataset-store",
        qos: .utility
    )

    private let bootstrapDetector = MinimapRouteDetector()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(rawFolderURL: URL) {
        let datasetRootURL = rawFolderURL.deletingLastPathComponent()

        self.rawFolderURL = rawFolderURL
        self.rootFolderURL = datasetRootURL
        self.predictedFolderURL = datasetRootURL.appendingPathComponent(
            "predicted_masks",
            isDirectory: true
        )
        self.correctedFolderURL = datasetRootURL.appendingPathComponent(
            "corrected_masks",
            isDirectory: true
        )
        self.reviewFolderURL = datasetRootURL.appendingPathComponent(
            "route_mask_reviews",
            isDirectory: true
        )
        self.exportFolderURL = datasetRootURL.appendingPathComponent(
            "exports",
            isDirectory: true
        )

        do {
            try createFoldersIfNeeded()
        } catch {
            lastErrorMessage = error.localizedDescription
        }

        refresh()
    }

    func refresh() {
        ioQueue.async { [weak self] in
            guard let self else { return }

            do {
                let samples = try self.loadSamplesOnQueue()
                self.publishCounts(samples: samples, error: nil)
            } catch {
                self.publishCounts(samples: [], error: error.localizedDescription)
            }
        }
    }

    func loadSamples() throws -> [RouteMaskDatasetSample] {
        try ioQueue.sync {
            try loadSamplesOnQueue()
        }
    }

    func registerCapturedSample(
        _ record: RouteMaskSampleRecord
    ) {
        ioQueue.async { [weak self] in
            guard let self else { return }

            do {
                try self.createFoldersIfNeeded()
                try self.writeRecord(record)
                let samples = try self.loadSamplesOnQueue()
                self.publishCounts(samples: samples, error: nil)
            } catch {
                self.publishError(error.localizedDescription)
            }
        }
    }

    func saveReview(
        sample: RouteMaskDatasetSample,
        status: RouteMaskReviewStatus,
        correctedMask: Data? = nil,
        maskWidth: Int? = nil,
        maskHeight: Int? = nil
    ) throws {
        try ioQueue.sync {
            var updatedRecord = sample.record

            if status == .corrected {
                guard let correctedMask,
                      let maskWidth,
                      let maskHeight,
                      correctedMask.count == maskWidth * maskHeight else {
                    throw RouteMaskDatasetError(
                        message: "The corrected mask dimensions are invalid."
                    )
                }

                let correctedFileName = "\(sample.id).png"
                let correctedURL = correctedFolderURL.appendingPathComponent(
                    correctedFileName
                )

                try writeMaskPNG(
                    pixels: correctedMask,
                    width: maskWidth,
                    height: maskHeight,
                    to: correctedURL
                )

                updatedRecord.correctedMaskFileName = correctedFileName
            } else {
                updatedRecord.correctedMaskFileName = nil
            }

            updatedRecord.reviewStatus = status
            updatedRecord.reviewedAt = Date()
            try writeRecord(updatedRecord)

            let samples = try loadSamplesOnQueue()
            publishCounts(samples: samples, error: nil)
        }
    }

    func generateMissingPredictions() {
        generatePredictions(replacingPendingPredictions: false)
    }

    func regeneratePendingPredictions() {
        generatePredictions(replacingPendingPredictions: true)
    }

    private func generatePredictions(
        replacingPendingPredictions: Bool
    ) {
        guard !isGeneratingPredictions else { return }

        DispatchQueue.main.async { [weak self] in
            self?.isGeneratingPredictions = true
            self?.generatedPredictionCount = 0
            self?.predictionGenerationTotal = 0
            self?.lastErrorMessage = nil
        }

        ioQueue.async { [weak self] in
            guard let self else { return }

            do {
                try self.createFoldersIfNeeded()
                let samples = try self.loadSamplesOnQueue()
                let samplesToGenerate = replacingPendingPredictions
                    ? samples.filter { $0.record.reviewStatus == .pending }
                    : samples.filter { $0.predictedMaskURL == nil }

                DispatchQueue.main.async {
                    self.predictionGenerationTotal = samplesToGenerate.count
                }

                var generated = 0

                for sample in samplesToGenerate {
                    try autoreleasepool {
                        try self.generatePrediction(for: sample)
                    }

                    generated += 1

                    DispatchQueue.main.async {
                        self.generatedPredictionCount = generated
                    }
                }

                let refreshed = try self.loadSamplesOnQueue()
                self.publishCounts(samples: refreshed, error: nil)

                DispatchQueue.main.async {
                    self.isGeneratingPredictions = false
                }
            } catch {
                self.publishError(error.localizedDescription)

                DispatchQueue.main.async {
                    self.isGeneratingPredictions = false
                }
            }
        }
    }

    func exportReviewedDataset() {
        guard !isExporting else { return }

        DispatchQueue.main.async { [weak self] in
            self?.isExporting = true
            self?.lastExportURL = nil
            self?.lastErrorMessage = nil
        }

        ioQueue.async { [weak self] in
            guard let self else { return }

            do {
                let outputURL = try self.exportReviewedDatasetOnQueue()

                DispatchQueue.main.async {
                    self.lastExportURL = outputURL
                    self.isExporting = false
                }
            } catch {
                self.publishError(error.localizedDescription)

                DispatchQueue.main.async {
                    self.isExporting = false
                }
            }
        }
    }

    func revealDatasetFolder() {
        do {
            try createFoldersIfNeeded()
            NSWorkspace.shared.open(rootFolderURL)
        } catch {
            publishError(error.localizedDescription)
        }
    }

    func revealLastExport() {
        guard let lastExportURL else { return }
        NSWorkspace.shared.open(lastExportURL)
    }

    func readMask(
        from url: URL,
        expectedWidth: Int,
        expectedHeight: Int
    ) throws -> Data {
        try ioQueue.sync {
            try readMaskOnQueue(
                from: url,
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight
            )
        }
    }

    private func loadSamplesOnQueue() throws -> [RouteMaskDatasetSample] {
        try createFoldersIfNeeded()

        let imageURLs = try FileManager.default.contentsOfDirectory(
            at: rawFolderURL,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "png" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return imageURLs.map { imageURL in
            let sampleID = imageURL.deletingPathExtension().lastPathComponent
            let recordURL = reviewURL(sampleID: sampleID)
            let record: RouteMaskSampleRecord

            if let data = try? Data(contentsOf: recordURL),
               let decoded = try? decoder.decode(RouteMaskSampleRecord.self, from: data) {
                record = decoded
            } else {
                let dimensions = imageDimensions(url: imageURL)
                let predictedName = "\(sampleID).png"
                let predictedURL = predictedFolderURL.appendingPathComponent(predictedName)

                record = RouteMaskSampleRecord(
                    id: sampleID,
                    imageFileName: imageURL.lastPathComponent,
                    predictedMaskFileName: FileManager.default.fileExists(atPath: predictedURL.path)
                        ? predictedName
                        : nil,
                    sourceKind: .legacyImport,
                    sourceName: "Legacy Dataset",
                    sourceGroupID: "legacy-unknown",
                    captureSessionID: "legacy-unknown",
                    sourceTimeSeconds: nil,
                    width: dimensions.width,
                    height: dimensions.height,
                    minimapVisible: false,
                    minimapConfidence: 0,
                    routeDetected: false,
                    routeConfidence: 0,
                    routeMaskPixelCount: 0
                )
            }

            let predictedURL = record.predictedMaskFileName.map {
                predictedFolderURL.appendingPathComponent($0)
            }
            .flatMap {
                FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
            }

            let correctedURL = record.correctedMaskFileName.map {
                correctedFolderURL.appendingPathComponent($0)
            }
            .flatMap {
                FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
            }

            return RouteMaskDatasetSample(
                record: record,
                imageURL: imageURL,
                predictedMaskURL: predictedURL,
                correctedMaskURL: correctedURL
            )
        }
    }

    private func generatePrediction(
        for sample: RouteMaskDatasetSample
    ) throws {
        guard let source = CGImageSourceCreateWithURL(sample.imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw RouteMaskDatasetError(
                message: "Could not read \(sample.imageURL.lastPathComponent)."
            )
        }

        guard let pixelBuffer = makePixelBuffer(
            from: image,
            applyingVerticalFlip: false
        ) else {
            throw RouteMaskDatasetError(
                message: "Could not decode \(sample.imageURL.lastPathComponent) for route analysis."
            )
        }

        var analysis = bootstrapDetector.analyze(
            pixelBuffer: pixelBuffer,
            normalizedCropRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            includeTrainingMask: true
        )

        // Legacy PNG crops and live CVPixelBuffers do not always share the
        // same row orientation. Retry the other Core Graphics orientation
        // only when the first pass cannot find the cyan player anchor.
        if !analysis.minimapVisible,
           let alternatePixelBuffer = makePixelBuffer(
               from: image,
               applyingVerticalFlip: true
           ) {
            let alternateAnalysis = bootstrapDetector.analyze(
                pixelBuffer: alternatePixelBuffer,
                normalizedCropRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                includeTrainingMask: true
            )

            if alternateAnalysis.minimapVisible {
                analysis = alternateAnalysis
            }
        }

        guard let routeMask = analysis.routeMask else {
            throw RouteMaskDatasetError(
                message: "The detector could not create a mask for \(sample.imageURL.lastPathComponent)."
            )
        }

        let maskFileName = "\(sample.id).png"
        let maskURL = predictedFolderURL.appendingPathComponent(maskFileName)

        try writeMaskPNG(
            pixels: routeMask.pixels,
            width: routeMask.width,
            height: routeMask.height,
            to: maskURL
        )

        var record = sample.record
        record = RouteMaskSampleRecord(
            id: record.id,
            imageFileName: record.imageFileName,
            predictedMaskFileName: maskFileName,
            correctedMaskFileName: record.correctedMaskFileName,
            reviewStatus: record.reviewStatus,
            capturedAt: record.capturedAt,
            reviewedAt: record.reviewedAt,
            sourceKind: record.sourceKind,
            sourceName: record.sourceName,
            sourceGroupID: record.sourceGroupID,
            captureSessionID: record.captureSessionID,
            sourceTimeSeconds: record.sourceTimeSeconds,
            width: routeMask.width,
            height: routeMask.height,
            minimapVisible: analysis.minimapVisible,
            minimapConfidence: analysis.minimapConfidence,
            routeDetected: analysis.routeDetected,
            routeConfidence: analysis.routeConfidence,
            routeMaskPixelCount: analysis.routeMaskPixelCount
        )

        try writeRecord(record)
    }

    private func exportReviewedDatasetOnQueue() throws -> URL {
        try createFoldersIfNeeded()
        let samples = try loadSamplesOnQueue().filter {
            $0.record.reviewStatus == .accepted ||
            $0.record.reviewStatus == .corrected
        }

        guard !samples.isEmpty else {
            throw RouteMaskDatasetError(
                message: "Review at least one sample before exporting."
            )
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        let folderName = "route_masks_\(formatter.string(from: Date()))"
        let outputURL = exportFolderURL.appendingPathComponent(folderName, isDirectory: true)

        let validationGroups = validationGroupIDs(for: samples)
        let fileManager = FileManager.default
        var manifestItems: [RouteMaskExportItem] = []
        var trainingCount = 0
        var validationCount = 0

        for split in ["train", "validation"] {
            try fileManager.createDirectory(
                at: outputURL.appendingPathComponent("\(split)/images", isDirectory: true),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: outputURL.appendingPathComponent("\(split)/masks", isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        for sample in samples {
            guard let maskURL = sample.effectiveMaskURL,
                  fileManager.fileExists(atPath: maskURL.path) else {
                continue
            }

            let split = validationGroups.contains(sample.record.sourceGroupID)
                ? "validation"
                : "train"
            let imageRelativePath = "\(split)/images/\(sample.record.imageFileName)"
            let maskRelativePath = "\(split)/masks/\(sample.id).png"
            let destinationImageURL = outputURL.appendingPathComponent(imageRelativePath)
            let destinationMaskURL = outputURL.appendingPathComponent(maskRelativePath)

            try fileManager.copyItem(at: sample.imageURL, to: destinationImageURL)
            try fileManager.copyItem(at: maskURL, to: destinationMaskURL)

            if split == "validation" {
                validationCount += 1
            } else {
                trainingCount += 1
            }

            manifestItems.append(
                RouteMaskExportItem(
                    sampleID: sample.id,
                    split: split,
                    imagePath: imageRelativePath,
                    maskPath: maskRelativePath,
                    sourceGroupID: sample.record.sourceGroupID,
                    sourceName: sample.record.sourceName,
                    reviewStatus: sample.record.reviewStatus,
                    routeDetectedByBootstrap: sample.record.routeDetected,
                    routeConfidence: sample.record.routeConfidence
                )
            )
        }

        guard !manifestItems.isEmpty else {
            throw RouteMaskDatasetError(
                message: "Reviewed records were found, but their mask files are missing."
            )
        }

        let manifest = RouteMaskExportManifest(
            schemaVersion: 1,
            generatedAt: Date(),
            trainingSampleCount: trainingCount,
            validationSampleCount: validationCount,
            splitRule: "Samples from one sourceGroupID stay in one split. Validation chooses the non-empty group subset closest to 20% while keeping training non-empty.",
            samples: manifestItems
        )

        let manifestData = try encoder.encode(manifest)
        try manifestData.write(
            to: outputURL.appendingPathComponent("manifest.json"),
            options: .atomic
        )

        return outputURL
    }

    private func validationGroupIDs(
        for samples: [RouteMaskDatasetSample]
    ) -> Set<String> {
        let grouped = Dictionary(grouping: samples) { $0.record.sourceGroupID }
        let groups = grouped.keys.sorted {
            stableHash($0) < stableHash($1)
        }

        guard groups.count >= 2 else { return [] }

        let target = max(Int((Double(samples.count) * 0.20).rounded()), 1)
        var bestGroups: Set<String> = []
        var bestDistance = Int.max
        var bestSampleCount = 0

        func consider(_ candidateGroups: Set<String>) {
            guard !candidateGroups.isEmpty,
                  candidateGroups.count < groups.count else {
                return
            }

            let count = candidateGroups.reduce(0) {
                $0 + (grouped[$1]?.count ?? 0)
            }
            let distance = abs(count - target)
            let candidateOvershoots = count > target
            let bestOvershoots = bestSampleCount > target

            if distance < bestDistance ||
                (distance == bestDistance && bestOvershoots && !candidateOvershoots) ||
                (distance == bestDistance && candidateOvershoots == bestOvershoots &&
                    count > bestSampleCount) {
                bestGroups = candidateGroups
                bestDistance = distance
                bestSampleCount = count
            }
        }

        // Exact selection is cheap for the normal number of source videos and
        // prevents one large legacy group from swallowing the validation set.
        if groups.count <= 16 {
            let upperBound = 1 << groups.count
            for bitMask in 1..<(upperBound - 1) {
                var candidate: Set<String> = []
                for index in groups.indices
                where bitMask & (1 << index) != 0 {
                    candidate.insert(groups[index])
                }
                consider(candidate)
            }
        } else {
            // For unusually large libraries, deterministic greedy selection
            // avoids exponential work while preserving source grouping.
            let bySize = groups.sorted {
                let firstCount = grouped[$0]?.count ?? 0
                let secondCount = grouped[$1]?.count ?? 0
                if firstCount == secondCount {
                    return stableHash($0) < stableHash($1)
                }
                return firstCount < secondCount
            }
            var candidate: Set<String> = []
            for group in bySize.dropLast() {
                let expanded = candidate.union([group])
                let currentCount = candidate.reduce(0) {
                    $0 + (grouped[$1]?.count ?? 0)
                }
                let expandedCount = expanded.reduce(0) {
                    $0 + (grouped[$1]?.count ?? 0)
                }
                if candidate.isEmpty ||
                    abs(expandedCount - target) < abs(currentCount - target) {
                    candidate = expanded
                }
            }
            consider(candidate)
            for group in bySize { consider([group]) }
        }

        return bestGroups
    }

    private func writeRecord(
        _ record: RouteMaskSampleRecord
    ) throws {
        let data = try encoder.encode(record)
        try data.write(to: reviewURL(sampleID: record.id), options: .atomic)
    }

    private func reviewURL(sampleID: String) -> URL {
        reviewFolderURL.appendingPathComponent("\(sampleID).json")
    }

    private func createFoldersIfNeeded() throws {
        for folder in [
            rawFolderURL,
            predictedFolderURL,
            correctedFolderURL,
            reviewFolderURL,
            exportFolderURL
        ] {
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true
            )
        }
    }

    private func imageDimensions(url: URL) -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return (0, 0)
        }

        return (width, height)
    }

    private func makePixelBuffer(
        from image: CGImage,
        applyingVerticalFlip: Bool
    ) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            image.width,
            image.height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess,
              let pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])

        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                data: baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                    CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else {
            return nil
        }

        context.interpolationQuality = .none

        if applyingVerticalFlip {
            context.translateBy(x: 0, y: CGFloat(image.height))
            context.scaleBy(x: 1, y: -1)
        }

        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        return pixelBuffer
    }

    private func writeMaskPNG(
        pixels: Data,
        width: Int,
        height: Int,
        to url: URL
    ) throws {
        guard width > 0,
              height > 0,
              pixels.count == width * height,
              let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
              ) else {
            throw RouteMaskDatasetError(message: "Could not create a mask PNG.")
        }

        CGImageDestinationAddImage(destination, image, nil)

        guard CGImageDestinationFinalize(destination) else {
            throw RouteMaskDatasetError(message: "Could not save \(url.lastPathComponent).")
        }
    }

    private func readMaskOnQueue(
        from url: URL,
        expectedWidth: Int,
        expectedHeight: Int
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw RouteMaskDatasetError(message: "Could not read \(url.lastPathComponent).")
        }

        guard image.width == expectedWidth,
              image.height == expectedHeight else {
            throw RouteMaskDatasetError(
                message: "Mask size \(image.width)×\(image.height) does not match image size \(expectedWidth)×\(expectedHeight)."
            )
        }

        guard image.bitsPerComponent == 8,
              image.bitsPerPixel == 8,
              image.bytesPerRow >= expectedWidth,
              let providerData = image.dataProvider?.data else {
            throw RouteMaskDatasetError(message: "Could not decode mask pixels.")
        }

        let sourceBytes = providerData as Data
        guard sourceBytes.count >= image.bytesPerRow * expectedHeight else {
            throw RouteMaskDatasetError(message: "Mask pixel data is incomplete.")
        }

        var pixels = [UInt8](repeating: 0, count: expectedWidth * expectedHeight)
        sourceBytes.withUnsafeBytes { sourceBuffer in
            guard let sourceAddress = sourceBuffer.baseAddress?
                .assumingMemoryBound(to: UInt8.self) else {
                return
            }

            for y in 0..<expectedHeight {
                let sourceRow = y * image.bytesPerRow
                let destinationRow = y * expectedWidth
                for x in 0..<expectedWidth {
                    pixels[destinationRow + x] = sourceAddress[sourceRow + x]
                }
            }
        }

        for index in pixels.indices {
            pixels[index] = pixels[index] >= 128 ? 255 : 0
        }

        return Data(pixels)
    }

    private func publishCounts(
        samples: [RouteMaskDatasetSample],
        error: String?
    ) {
        let pending = samples.filter { $0.record.reviewStatus == .pending }.count
        let accepted = samples.filter { $0.record.reviewStatus == .accepted }.count
        let corrected = samples.filter { $0.record.reviewStatus == .corrected }.count
        let rejected = samples.filter { $0.record.reviewStatus == .rejected }.count
        let missing = samples.filter { $0.predictedMaskURL == nil }.count

        DispatchQueue.main.async {
            self.rawImageCount = samples.count
            self.pendingCount = pending
            self.acceptedCount = accepted
            self.correctedCount = corrected
            self.rejectedCount = rejected
            self.missingPredictionCount = missing
            self.lastErrorMessage = error
        }
    }

    private func publishError(_ message: String) {
        DispatchQueue.main.async {
            self.lastErrorMessage = message
        }
    }

    private func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

struct RouteMaskDatasetError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}
