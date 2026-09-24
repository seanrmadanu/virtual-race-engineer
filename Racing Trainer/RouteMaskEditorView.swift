import AppKit
import Combine
import Foundation
import SwiftUI

enum RouteMaskEditingTool: String, CaseIterable, Identifiable {
    case brush
    case eraser

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .brush:
            return "Brush"
        case .eraser:
            return "Eraser"
        }
    }

    var systemImage: String {
        switch self {
        case .brush:
            return "paintbrush.fill"
        case .eraser:
            return "eraser.fill"
        }
    }
}

struct RouteMaskEditorLaunchButton: View {
    @ObservedObject var store: RouteMaskDatasetStore

    var body: some View {
        Button {
            RouteMaskEditorWindowController.shared.open(store: store)
        } label: {
            Image(systemName: "paintbrush")
                .font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.plain)
        .help("Review and correct automatic route masks")
    }
}

final class RouteMaskEditorWindowController {
    static let shared = RouteMaskEditorWindowController()

    private var windowController: NSWindowController?

    private init() {}

    func open(store: RouteMaskDatasetStore) {
        if let window = windowController?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(
            rootView: RouteMaskEditorView(store: store)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Racing Trainer — Route Mask Reviewer"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1260, height: 820))
        window.minSize = NSSize(width: 980, height: 680)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("RacingTrainerRouteMaskReviewer")
        window.center()

        let controller = NSWindowController(window: window)
        windowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class RouteMaskEditorModel: ObservableObject {
    @Published private(set) var overlayImage: CGImage?
    @Published private(set) var isDirty = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var routePixelCount = 0

    private(set) var width = 0
    private(set) var height = 0
    private var pixels: [UInt8] = []
    private var baselinePixels: [UInt8] = []
    private var undoStack: [[UInt8]] = []
    private var redoStack: [[UInt8]] = []
    private var lastStrokePoint: CGPoint?
    private var strokeIsActive = false

    var maskData: Data { Data(pixels) }

    func load(mask: Data, width: Int, height: Int) {
        guard width > 0,
              height > 0,
              mask.count == width * height else {
            self.width = 0
            self.height = 0
            pixels = []
            baselinePixels = []
            undoStack = []
            redoStack = []
            overlayImage = nil
            isDirty = false
            updateHistoryState()
            return
        }

        self.width = width
        self.height = height
        pixels = mask.map { $0 >= 128 ? 255 : 0 }
        baselinePixels = pixels
        undoStack = []
        redoStack = []
        strokeIsActive = false
        lastStrokePoint = nil
        isDirty = false
        rebuildOverlay()
        updateHistoryState()
    }

    func beginStroke(
        at point: CGPoint,
        tool: RouteMaskEditingTool,
        radius: Int
    ) {
        guard width > 0, height > 0 else { return }
        pushUndoSnapshot()
        redoStack.removeAll()
        strokeIsActive = true
        lastStrokePoint = point
        applyCircle(at: point, tool: tool, radius: radius)
        finishPixelMutation()
    }

    func continueStroke(
        at point: CGPoint,
        tool: RouteMaskEditingTool,
        radius: Int
    ) {
        guard strokeIsActive else {
            beginStroke(at: point, tool: tool, radius: radius)
            return
        }

        if let lastStrokePoint {
            applyLine(
                from: lastStrokePoint,
                to: point,
                tool: tool,
                radius: radius
            )
        } else {
            applyCircle(at: point, tool: tool, radius: radius)
        }

        lastStrokePoint = point
        finishPixelMutation()
    }

    func endStroke() {
        strokeIsActive = false
        lastStrokePoint = nil
    }

    func clearMask() {
        guard !pixels.isEmpty else { return }
        pushUndoSnapshot()
        redoStack.removeAll()
        pixels = [UInt8](repeating: 0, count: pixels.count)
        finishPixelMutation()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(pixels)
        pixels = previous
        isDirty = pixels != baselinePixels
        rebuildOverlay()
        updateHistoryState()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(pixels)
        pixels = next
        isDirty = pixels != baselinePixels
        rebuildOverlay()
        updateHistoryState()
    }

    private func applyLine(
        from start: CGPoint,
        to end: CGPoint,
        tool: RouteMaskEditingTool,
        radius: Int
    ) {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let distance = hypot(deltaX, deltaY)
        let stepLength = CGFloat(max(radius, 1)) * 0.35
        let steps = max(Int(ceil(distance / max(stepLength, 1))), 1)

        for step in 1...steps {
            let fraction = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(
                x: start.x + deltaX * fraction,
                y: start.y + deltaY * fraction
            )
            applyCircle(at: point, tool: tool, radius: radius)
        }
    }

    private func applyCircle(
        at point: CGPoint,
        tool: RouteMaskEditingTool,
        radius: Int
    ) {
        let safeRadius = max(radius, 1)
        let centerX = Int(point.x.rounded())
        let centerY = Int(point.y.rounded())
        let minX = max(centerX - safeRadius, 0)
        let maxX = min(centerX + safeRadius, width - 1)
        let minY = max(centerY - safeRadius, 0)
        let maxY = min(centerY + safeRadius, height - 1)
        let radiusSquared = safeRadius * safeRadius
        let value: UInt8 = tool == .brush ? 255 : 0

        guard minX <= maxX, minY <= maxY else { return }

        for y in minY...maxY {
            let deltaY = y - centerY
            for x in minX...maxX {
                let deltaX = x - centerX
                guard deltaX * deltaX + deltaY * deltaY <= radiusSquared else {
                    continue
                }
                pixels[y * width + x] = value
            }
        }
    }

    private func pushUndoSnapshot() {
        undoStack.append(pixels)
        if undoStack.count > 20 {
            undoStack.removeFirst(undoStack.count - 20)
        }
        updateHistoryState()
    }

    private func finishPixelMutation() {
        isDirty = pixels != baselinePixels
        rebuildOverlay()
        updateHistoryState()
    }

    private func rebuildOverlay() {
        routePixelCount = pixels.reduce(into: 0) { count, value in
            if value != 0 { count += 1 }
        }

        guard width > 0,
              height > 0,
              pixels.count == width * height else {
            overlayImage = nil
            return
        }

        let alpha: UInt8 = 210
        var rgba = [UInt8](repeating: 0, count: width * height * 4)

        for index in pixels.indices where pixels[index] != 0 {
            let output = index * 4
            rgba[output] = alpha
            rgba[output + 1] = 25
            rgba[output + 2] = 150
            rgba[output + 3] = alpha
        }

        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData) else {
            overlayImage = nil
            return
        }

        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )

        overlayImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func updateHistoryState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }
}

struct RouteMaskEditorCanvas: View {
    let sourceImage: NSImage
    let overlayImage: CGImage?
    let maskWidth: Int
    let maskHeight: Int
    let tool: RouteMaskEditingTool
    let brushRadius: Int
    let overlayOpacity: Double
    let showsMask: Bool
    let beginStroke: (CGPoint) -> Void
    let continueStroke: (CGPoint) -> Void
    let endStroke: () -> Void

    @State private var drawing = false

    var body: some View {
        GeometryReader { geometry in
            let fittedRect = aspectFitRect(
                imageSize: sourceImage.size,
                containerSize: geometry.size
            )

            ZStack(alignment: .topLeading) {
                Color.black

                Image(nsImage: sourceImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fittedRect.width, height: fittedRect.height)
                    .offset(x: fittedRect.minX, y: fittedRect.minY)

                if showsMask, let overlayImage {
                    Image(decorative: overlayImage, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .opacity(overlayOpacity)
                        .frame(width: fittedRect.width, height: fittedRect.height)
                        .offset(x: fittedRect.minX, y: fittedRect.minY)
                        .allowsHitTesting(false)
                }

            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard drawing || fittedRect.contains(value.location),
                              let point = maskPoint(
                                  from: value.location,
                                  in: fittedRect
                              ) else {
                            return
                        }

                        if drawing {
                            continueStroke(point)
                        } else {
                            drawing = true
                            beginStroke(point)
                        }
                    }
                    .onEnded { _ in
                        guard drawing else { return }
                        drawing = false
                        endStroke()
                    }
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func maskPoint(
        from canvasPoint: CGPoint,
        in fittedRect: CGRect
    ) -> CGPoint? {
        guard fittedRect.width > 0,
              fittedRect.height > 0,
              maskWidth > 0,
              maskHeight > 0 else {
            return nil
        }

        // DragGesture now reports in the complete canvas coordinate space.
        // Remove the aspect-fit offset before converting to mask pixels.
        let imageX = min(
            max(canvasPoint.x - fittedRect.minX, 0),
            fittedRect.width
        )
        let imageY = min(
            max(canvasPoint.y - fittedRect.minY, 0),
            fittedRect.height
        )

        let pixelX = min(
            imageX / fittedRect.width * CGFloat(maskWidth),
            CGFloat(maskWidth - 1)
        )
        let pixelY = min(
            imageY / fittedRect.height * CGFloat(maskHeight),
            CGFloat(maskHeight - 1)
        )

        return CGPoint(x: pixelX, y: pixelY)
    }

    private func aspectFitRect(
        imageSize: CGSize,
        containerSize: CGSize
    ) -> CGRect {
        guard imageSize.width > 0,
              imageSize.height > 0,
              containerSize.width > 0,
              containerSize.height > 0 else {
            return .zero
        }

        let scale = min(
            containerSize.width / imageSize.width,
            containerSize.height / imageSize.height
        )
        let size = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )

        return CGRect(
            x: (containerSize.width - size.width) / 2,
            y: (containerSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

struct RouteMaskEditorView: View {
    @ObservedObject var store: RouteMaskDatasetStore
    @StateObject private var editor = RouteMaskEditorModel()

    @State private var samples: [RouteMaskDatasetSample] = []
    @State private var currentIndex = 0
    @State private var currentImage: NSImage?
    @State private var baselineMask = Data()
    @State private var hasPrediction = false
    @State private var currentWidth = 0
    @State private var currentHeight = 0
    @State private var selectedTool = RouteMaskEditingTool.brush
    @State private var brushRadius = 6.0
    @State private var overlayOpacity = 0.82
    @State private var showsMask = true
    @State private var statusMessage = "Loading route-mask dataset…"

    private var currentSample: RouteMaskDatasetSample? {
        guard samples.indices.contains(currentIndex) else { return nil }
        return samples[currentIndex]
    }

    private var progressText: String {
        guard !samples.isEmpty else { return "0 / 0" }
        return "\(currentIndex + 1) / \(samples.count)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HStack(spacing: 0) {
                imagePanel
                Divider()
                controlsPanel
                    .frame(width: 390)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(minWidth: 980, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            loadDataset()
        }
        .onChange(of: store.isGeneratingPredictions) { _, generating in
            if !generating {
                loadDataset(preservingSampleID: currentSample?.id)
            }
        }
        .onChange(of: store.lastExportURL) { _, url in
            if let url {
                statusMessage = "Exported reviewed pairs to \(url.lastPathComponent)."
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("ROUTE MASK REVIEWER")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))

                Text(currentSample?.record.imageFileName ?? "No image")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 12) {
                countBadge("Pending", value: store.pendingCount, color: .orange)
                countBadge("Accepted", value: store.acceptedCount, color: .green)
                countBadge("Corrected", value: store.correctedCount, color: .cyan)
                countBadge("Rejected", value: store.rejectedCount, color: .red)
            }

            Text(progressText)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .monospacedDigit()

            Button {
                if store.missingPredictionCount > 0 {
                    store.generateMissingPredictions()
                } else {
                    store.regeneratePendingPredictions()
                }
            } label: {
                Label(
                    store.isGeneratingPredictions
                        ? "\(store.generatedPredictionCount)/\(store.predictionGenerationTotal)"
                        : predictionGenerationButtonTitle,
                    systemImage: "wand.and.stars"
                )
            }
            .buttonStyle(.bordered)
            .disabled(
                store.isGeneratingPredictions ||
                editor.isDirty ||
                (store.missingPredictionCount == 0 && store.pendingCount == 0)
            )
            .help(predictionGenerationHelp)

            Button {
                loadDataset(preservingSampleID: currentSample?.id)
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var imagePanel: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black)

                if let currentImage {
                    RouteMaskEditorCanvas(
                        sourceImage: currentImage,
                        overlayImage: editor.overlayImage,
                        maskWidth: currentWidth,
                        maskHeight: currentHeight,
                        tool: selectedTool,
                        brushRadius: Int(brushRadius.rounded()),
                        overlayOpacity: overlayOpacity,
                        showsMask: showsMask,
                        beginStroke: { point in
                            editor.beginStroke(
                                at: point,
                                tool: selectedTool,
                                radius: Int(brushRadius.rounded())
                            )
                        },
                        continueStroke: { point in
                            editor.continueStroke(
                                at: point,
                                tool: selectedTool,
                                radius: Int(brushRadius.rounded())
                            )
                        },
                        endStroke: {
                            editor.endStroke()
                        }
                    )
                    .padding(20)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo")
                            .font(.system(size: 40))
                        Text(samples.isEmpty ? "No minimap images found" : "Unable to load image")
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .topLeading) {
                currentStatusBadge
                    .padding(14)
            }

            HStack {
                Text(statusMessage)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Spacer()

                Text("Mask pixels: \(editor.routePixelCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(20)
    }

    private var controlsPanel: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                predictionSection
                Divider()
                editingSection
                Divider()
                reviewSection
                Divider()
                exportSection

                if let error = store.lastErrorMessage {
                    Divider()
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var predictionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("BOOTSTRAP PREDICTION")

            if let record = currentSample?.record {
                informationRow("Minimap", record.minimapVisible ? "Visible" : "Not found")
                informationRow("GPS route", record.routeDetected ? "Detected" : "Not detected")
                informationRow(
                    "Confidence",
                    String(
                        format: "%.0f%%",
                        Double(record.routeConfidence) * 100
                    )
                )
                informationRow("Source", record.sourceName)
            }

            Toggle("Show magenta mask", isOn: $showsMask)

            HStack {
                Text("Opacity")
                    .font(.caption)
                Slider(value: $overlayOpacity, in: 0.20...1.0)
            }

            Text(
                "The automatic mask is only a starting guess. Accept it when it covers only the yellow GPS trail; fix it when it misses route pixels or includes scenery."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var editingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("MASK CORRECTION")

            Picker("Tool", selection: $selectedTool) {
                ForEach(RouteMaskEditingTool.allCases) { tool in
                    Label(tool.displayName, systemImage: tool.systemImage)
                        .tag(tool)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Brush size")
                    .font(.caption)
                Slider(value: $brushRadius, in: 1...24, step: 1)
                Text("\(Int(brushRadius))")
                    .font(.system(size: 10, design: .monospaced))
                    .frame(width: 24, alignment: .trailing)
            }

            HStack {
                Button {
                    editor.undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!editor.canUndo)

                Button {
                    editor.redo()
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!editor.canRedo)

                Button("Reset") {
                    editor.load(mask: baselineMask, width: currentWidth, height: currentHeight)
                    statusMessage = "Discarded unsaved mask edits."
                }
                .disabled(baselineMask.isEmpty || !editor.isDirty)
            }
            .buttonStyle(.bordered)

            HStack {
                Button("Brush (B)") {
                    selectedTool = .brush
                }
                .keyboardShortcut("b", modifiers: [])

                Button("Eraser (E)") {
                    selectedTool = .eraser
                }
                .keyboardShortcut("e", modifiers: [])

                Button("Clear") {
                    editor.clearMask()
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("REVIEW DECISION")

            Button {
                if editor.isDirty {
                    saveCorrectedMask()
                } else {
                    acceptPrediction()
                }
            } label: {
                Label(
                    primaryReviewButtonTitle,
                    systemImage: editor.isDirty ? "square.and.arrow.down" : "checkmark.circle.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(editor.isDirty ? .blue : .green)
            .keyboardShortcut("a", modifiers: [])
            .disabled(
                currentSample == nil ||
                (!hasPrediction && !editor.isDirty) ||
                (!editor.isDirty && currentSample?.record.reviewStatus == .accepted) ||
                (!editor.isDirty && currentSample?.record.reviewStatus == .corrected)
            )

            Button {
                approveNoRoute()
            } label: {
                Label("Approve as No Route", systemImage: "circle.slash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("n", modifiers: [])
            .disabled(currentSample == nil)

            Button(role: .destructive) {
                rejectSample()
            } label: {
                Label("Reject Sample", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("r", modifiers: [])
            .disabled(currentSample == nil)

            Text(
                "Reject frames with a missing, moved, obstructed, or unusable minimap. ‘No Route’ is a valid negative training example when the minimap is visible but no waypoint is set."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("TRAINING EXPORT")

            informationRow("Ready pairs", "\(store.trainingReadyCount)")
            informationRow("Still pending", "\(store.pendingCount)")

            Button {
                store.exportReviewedDataset()
            } label: {
                Label(
                    store.isExporting ? "Exporting…" : "Export Reviewed Pairs",
                    systemImage: "shippingbox"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(store.isExporting || store.trainingReadyCount == 0)

            if store.lastExportURL != nil {
                Button("Open Last Export") {
                    store.revealLastExport()
                }
                .buttonStyle(.borderless)
            }

            Text(
                "Exports paired images and masks. Frames from the same source video stay in the same train/validation split to prevent misleading accuracy."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                move(by: -1)
            } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .disabled(currentIndex <= 0 || samples.isEmpty)

            Button {
                move(by: 1)
            } label: {
                Label("Next", systemImage: "chevron.right")
            }
            .disabled(samples.isEmpty || currentIndex >= samples.count - 1)

            Button("Next Pending") {
                goToNextPending()
            }
            .disabled(store.pendingCount == 0)

            Spacer()

            if editor.isDirty {
                Label("Unsaved mask changes", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }

            Button {
                store.revealDatasetFolder()
            } label: {
                Label("Open Dataset Folder", systemImage: "folder")
            }
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var currentStatusBadge: some View {
        let status = currentSample?.record.reviewStatus ?? .pending

        return HStack(spacing: 7) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 8, height: 8)

            Text(status.displayName.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))

            if editor.isDirty {
                Text("• MODIFIED")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.orange)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var primaryReviewButtonTitle: String {
        if editor.isDirty {
            return "Save Corrected Mask"
        }

        switch currentSample?.record.reviewStatus {
        case .some(.accepted):
            return "Prediction Accepted"
        case .some(.corrected):
            return "Corrected Mask Saved"
        default:
            return "Accept Prediction"
        }
    }

    private var predictionGenerationButtonTitle: String {
        store.missingPredictionCount > 0
            ? "Generate Missing"
            : "Regenerate Pending"
    }

    private var predictionGenerationHelp: String {
        if store.missingPredictionCount > 0 {
            return "Create bootstrap masks for raw minimap images that do not have one yet."
        }

        return "Replace automatic masks for pending samples without changing accepted or corrected work."
    }

    private func countBadge(
        _ title: String,
        value: Int,
        color: Color
    ) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text("\(title) \(value)")
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .monospacedDigit()
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
    }

    private func informationRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 10, design: .monospaced))
    }

    private func statusColor(_ status: RouteMaskReviewStatus) -> Color {
        switch status {
        case .pending:
            return .orange
        case .accepted:
            return .green
        case .corrected:
            return .cyan
        case .rejected:
            return .red
        }
    }

    private func loadDataset(preservingSampleID: String? = nil) {
        do {
            let loaded = try store.loadSamples()
            samples = loaded

            if let preservingSampleID,
               let index = loaded.firstIndex(where: { $0.id == preservingSampleID }) {
                currentIndex = index
            } else {
                currentIndex = min(currentIndex, max(loaded.count - 1, 0))
            }

            loadCurrentSample()

            if store.missingPredictionCount > 0,
               !store.isGeneratingPredictions {
                statusMessage = "\(store.missingPredictionCount) older image(s) need automatic predictions. Click Generate Missing."
            }
        } catch {
            samples = []
            currentImage = nil
            statusMessage = "Dataset load failed: \(error.localizedDescription)"
        }
    }

    private func loadCurrentSample() {
        guard let sample = currentSample,
              let image = NSImage(contentsOf: sample.imageURL) else {
            currentImage = nil
            baselineMask = Data()
            hasPrediction = false
            currentWidth = 0
            currentHeight = 0
            editor.load(mask: Data(), width: 0, height: 0)
            statusMessage = samples.isEmpty
                ? "Record minimap samples from live input or a local gameplay video."
                : "Could not load the selected minimap image."
            return
        }

        guard let representation = image.representations.first else {
            currentImage = nil
            baselineMask = Data()
            hasPrediction = false
            currentWidth = 0
            currentHeight = 0
            editor.load(mask: Data(), width: 0, height: 0)
            statusMessage = "The selected image has no bitmap representation."
            return
        }

        let width = representation.pixelsWide
        let height = representation.pixelsHigh
        currentImage = image
        currentWidth = width
        currentHeight = height

        let maskURL = sample.record.reviewStatus == .corrected
            ? (sample.correctedMaskURL ?? sample.predictedMaskURL)
            : sample.predictedMaskURL

        guard let maskURL else {
            let blankMask = Data(repeating: 0, count: max(width * height, 0))
            baselineMask = blankMask
            hasPrediction = false
            editor.load(mask: blankMask, width: width, height: height)
            statusMessage = "No prediction exists yet. Generate missing predictions before reviewing."
            return
        }

        do {
            let loadedMask = try store.readMask(
                from: maskURL,
                expectedWidth: width,
                expectedHeight: height
            )
            baselineMask = loadedMask
            hasPrediction = true
            editor.load(mask: loadedMask, width: width, height: height)
            statusMessage = reviewHint(for: sample)
        } catch {
            baselineMask = Data()
            hasPrediction = false
            editor.load(mask: Data(), width: 0, height: 0)
            statusMessage = "Mask load failed: \(error.localizedDescription)"
        }
    }

    private func reviewHint(for sample: RouteMaskDatasetSample) -> String {
        if !sample.record.minimapVisible {
            return "The bootstrap detector could not find the cyan player arrow. Reject this if the minimap is missing or misplaced."
        }

        if sample.record.routeDetected {
            return "Check that magenta covers only the connected yellow GPS trail, then accept or correct it."
        }

        return "No route was predicted. If the minimap is visible and no waypoint exists, accept this blank mask."
    }

    private func move(by offset: Int) {
        guard !editor.isDirty else {
            statusMessage = "Save the correction or Reset it before changing images."
            return
        }

        let next = currentIndex + offset
        guard samples.indices.contains(next) else { return }
        currentIndex = next
        loadCurrentSample()
    }

    private func goToNextPending() {
        guard !editor.isDirty else {
            statusMessage = "Save the correction or Reset it before changing images."
            return
        }

        guard !samples.isEmpty else { return }

        let indices = Array((currentIndex + 1)..<samples.count) + Array(0...currentIndex)
        guard let next = indices.first(where: {
            samples[$0].record.reviewStatus == .pending
        }) else {
            statusMessage = "No pending samples remain."
            return
        }

        currentIndex = next
        loadCurrentSample()
    }

    private func acceptPrediction() {
        guard let sample = currentSample else { return }

        do {
            try store.saveReview(sample: sample, status: .accepted)
            completeReview(message: "Accepted \(sample.id).")
        } catch {
            statusMessage = "Accept failed: \(error.localizedDescription)"
        }
    }

    private func saveCorrectedMask() {
        guard let sample = currentSample,
              currentWidth > 0,
              currentHeight > 0 else { return }

        do {
            try store.saveReview(
                sample: sample,
                status: .corrected,
                correctedMask: editor.maskData,
                maskWidth: currentWidth,
                maskHeight: currentHeight
            )
            completeReview(message: "Saved corrected mask for \(sample.id).")
        } catch {
            statusMessage = "Correction save failed: \(error.localizedDescription)"
        }
    }

    private func approveNoRoute() {
        guard let sample = currentSample,
              currentWidth > 0,
              currentHeight > 0 else { return }

        let blank = Data(repeating: 0, count: currentWidth * currentHeight)

        do {
            try store.saveReview(
                sample: sample,
                status: .corrected,
                correctedMask: blank,
                maskWidth: currentWidth,
                maskHeight: currentHeight
            )
            completeReview(message: "Approved \(sample.id) as a no-route negative sample.")
        } catch {
            statusMessage = "No-route save failed: \(error.localizedDescription)"
        }
    }

    private func rejectSample() {
        guard let sample = currentSample else { return }

        do {
            try store.saveReview(sample: sample, status: .rejected)
            completeReview(message: "Rejected \(sample.id); it will not be exported.")
        } catch {
            statusMessage = "Reject failed: \(error.localizedDescription)"
        }
    }

    private func completeReview(message: String) {
        let completedID = currentSample?.id
        loadDataset(preservingSampleID: completedID)
        goToNextPending()
        statusMessage = "\(message) \(statusMessage)"
    }
}
