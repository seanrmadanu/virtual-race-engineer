import AppKit
import Foundation
import SwiftUI

// MARK: - Dataset Labeler Launcher

struct DatasetLabelerLaunchButton:
    View {

    @ObservedObject var store:
        DatasetMetadataStore

    var body:
        some View {

        Button {

            DatasetLabelerWindowController
                .shared
                .open(
                    store:
                        store
                )

        } label: {

            Image(
                systemName:
                    "tag"
            )
            .font(
                .system(
                    size: 10,
                    weight: .semibold
                )
            )
        }
        .buttonStyle(
            .plain
        )
        .help(
            "Open Dataset Labeler"
        )
    }
}


// MARK: - Dataset Labeler Window

final class DatasetLabelerWindowController {

    static let shared =
        DatasetLabelerWindowController()

    private var windowController:
        NSWindowController?

    private init() {}

    func open(
        store:
            DatasetMetadataStore
    ) {

        if let window =
                windowController?
                    .window {

            window.makeKeyAndOrderFront(
                nil
            )

            NSApp.activate(
                ignoringOtherApps:
                    true
            )

            return
        }

        let labelerView =
            DatasetLabelerView(
                store:
                    store
            )

        let hostingController =
            NSHostingController(
                rootView:
                    labelerView
            )

        let window =
            NSWindow(
                contentViewController:
                    hostingController
            )

        window.title =
            "Racing Trainer — Dataset Labeler"

        window.styleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable
        ]

        window.setContentSize(
            NSSize(
                width: 1240,
                height: 800
            )
        )

        window.minSize =
            NSSize(
                width: 960,
                height: 650
            )

        window.isReleasedWhenClosed =
            false

        window.setFrameAutosaveName(
            "RacingTrainerDatasetLabeler"
        )

        window.center()

        let controller =
            NSWindowController(
                window:
                    window
            )

        windowController =
            controller

        controller.showWindow(
            nil
        )

        NSApp.activate(
            ignoringOtherApps:
                true
        )
    }
}


// MARK: - Dataset Labeler

struct DatasetLabelerView:
    View {

    @ObservedObject var store:
        DatasetMetadataStore

    @AppStorage(
        "racingTrainer.datasetLabeler.resumeImageName"
    )
    private var resumeImageName =
        ""

    // MARK: Images

    @State private var imageURLs:
        [URL] = []

    @State private var currentIndex =
        0

    @State private var currentImage:
        NSImage?

    // MARK: Labels

    @State private var selectedMinimapState:
        DatasetMinimapState?

    @State private var selectedRouteState:
        DatasetRouteState?

    @State private var selectedRouteCategory:
        DatasetRouteCategory?

    @State private var selectedConditions:
        Set<DatasetConditionCategory> = []

    // MARK: Status

    @State private var currentHasSavedMetadata =
        false

    @State private var hasUnsavedChanges =
        false

    @State private var statusMessage =
        "Loading dataset…"

    // MARK: Current Image

    private var currentURL:
        URL? {

        guard currentIndex >= 0,
              currentIndex <
                imageURLs.count else {

            return nil
        }

        return imageURLs[
            currentIndex
        ]
    }

    private var currentImageName:
        String {

        currentURL?
            .lastPathComponent ??
        "No image"
    }

    private var progressText:
        String {

        guard !imageURLs
            .isEmpty else {

            return "0 / 0"
        }

        return
            "\(currentIndex + 1) / \(imageURLs.count)"
    }

    // MARK: Body

    var body:
        some View {

        VStack(
            spacing: 0
        ) {

            header

            Divider()

            HStack(
                spacing: 0
            ) {

                imagePanel

                Divider()

                controlsPanel
                    .frame(
                        width: 390
                    )
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity
            )

            Divider()

            footer
        }
        .frame(
            minWidth: 960,
            minHeight: 650
        )
        .background(
            Color(
                nsColor:
                    .windowBackgroundColor
            )
        )
        .onAppear {

            loadDataset()
        }
    }

    // MARK: Header

    private var header:
        some View {

        HStack(
            spacing: 16
        ) {

            VStack(
                alignment: .leading,
                spacing: 3
            ) {

                Text(
                    "MINIMAP DATASET LABELER"
                )
                .font(
                    .system(
                        size: 15,
                        weight: .bold,
                        design: .monospaced
                    )
                )

                Text(
                    currentImageName
                )
                .font(
                    .system(
                        size: 11,
                        design: .monospaced
                    )
                )
                .foregroundStyle(
                    .secondary
                )
            }

            Spacer()

            VStack(
                alignment: .trailing,
                spacing: 4
            ) {

                HStack(
                    spacing: 12
                ) {

                    Text(
                        progressText
                    )

                    Text(
                        "Labeled \(store.labeledImageCount)"
                    )

                    Text(
                        "Unlabeled \(store.unlabeledImageCount)"
                    )
                }
                .font(
                    .system(
                        size: 11,
                        weight: .medium,
                        design: .monospaced
                    )
                )
                .monospacedDigit()

                ProgressView(
                    value:
                        Double(
                            store
                                .labeledImageCount
                        ),
                    total:
                        Double(
                            max(
                                store
                                    .rawImageCount,
                                1
                            )
                        )
                )
                .frame(
                    width: 260
                )
            }

            Button {

                loadDataset()

            } label: {

                Label(
                    "Reload",
                    systemImage:
                        "arrow.clockwise"
                )
            }
            .buttonStyle(
                .bordered
            )
        }
        .padding(
            .horizontal,
            20
        )
        .padding(
            .vertical,
            14
        )
    }

    // MARK: Image Panel

    private var imagePanel:
        some View {

        VStack(
            spacing: 12
        ) {

            ZStack {

                RoundedRectangle(
                    cornerRadius: 12
                )
                .fill(
                    Color.black
                )

                if let currentImage {

                    Image(
                        nsImage:
                            currentImage
                    )
                    .resizable()
                    .interpolation(
                        .high
                    )
                    .scaledToFit()
                    .padding(
                        24
                    )

                } else {

                    VStack(
                        spacing: 12
                    ) {

                        Image(
                            systemName:
                                "photo"
                        )
                        .font(
                            .system(
                                size: 40
                            )
                        )

                        Text(
                            imageURLs.isEmpty
                            ? "No minimap images found"
                            : "Unable to load image"
                        )
                    }
                    .foregroundStyle(
                        .secondary
                    )
                }
            }
            .overlay(
                alignment:
                    .topLeading
            ) {

                HStack(
                    spacing: 7
                ) {

                    Circle()
                        .fill(
                            currentHasSavedMetadata
                            ? Color.green
                            : Color.orange
                        )
                        .frame(
                            width: 8,
                            height: 8
                        )

                    Text(
                        currentHasSavedMetadata
                        ? "LABELED"
                        : "UNLABELED"
                    )
                    .font(
                        .system(
                            size: 10,
                            weight: .bold,
                            design: .monospaced
                        )
                    )

                    if hasUnsavedChanges {

                        Text(
                            "• MODIFIED"
                        )
                        .font(
                            .system(
                                size: 10,
                                weight: .bold,
                                design: .monospaced
                            )
                        )
                        .foregroundStyle(
                            .orange
                        )
                    }
                }
                .foregroundStyle(
                    .white
                )
                .padding(
                    .horizontal,
                    10
                )
                .padding(
                    .vertical,
                    7
                )
                .background(
                    Color.black
                        .opacity(
                            0.72
                        )
                )
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 6
                    )
                )
                .padding(
                    14
                )
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity
            )

            Text(
                statusMessage
            )
            .font(
                .system(
                    size: 11,
                    design: .monospaced
                )
            )
            .foregroundStyle(
                .secondary
            )
            .frame(
                maxWidth: .infinity,
                alignment: .leading
            )
        }
        .padding(
            20
        )
    }

    // MARK: Controls

    private var controlsPanel:
        some View {

        ScrollView(
            .vertical,
            showsIndicators:
                true
        ) {

            VStack(
                alignment: .leading,
                spacing: 18
            ) {

                minimapStateSection

                Divider()

                routeStateSection

                Divider()

                routeShapeSection

                Divider()

                conditionSection

                Divider()

                shortcutHelp

                if let error =
                        store
                            .lastErrorMessage {

                    Divider()

                    Text(
                        error
                    )
                    .font(
                        .caption
                    )
                    .foregroundStyle(
                        .red
                    )
                    .textSelection(
                        .enabled
                    )
                }
            }
            .padding(
                20
            )
        }
        .background(
            Color(
                nsColor:
                    .controlBackgroundColor
            )
        )
    }

    // MARK: Minimap State Section

    private var minimapStateSection:
        some View {

        VStack(
            alignment: .leading,
            spacing: 10
        ) {

            Text(
                "MINIMAP STATE"
            )
            .font(
                sectionTitleFont
            )

            Text(
                "Is the expected Motorfest minimap actually visible?"
            )
            .font(
                .caption
            )
            .foregroundStyle(
                .secondary
            )

            minimapStateButton(
                .visible,
                shortcut:
                    "1",
                shortcutText:
                    "1"
            )

            minimapStateButton(
                .missing,
                shortcut:
                    "2",
                shortcutText:
                    "2"
            )

            minimapStateButton(
                .partialOrObstructed,
                shortcut:
                    "3",
                shortcutText:
                    "3"
            )

            minimapStateButton(
                .invalidFrame,
                shortcut:
                    "4",
                shortcutText:
                    "4"
            )
        }
    }

    // MARK: Route State Section

    private var routeStateSection:
        some View {

        VStack(
            alignment: .leading,
            spacing: 10
        ) {

            Text(
                "ROUTE STATE"
            )
            .font(
                sectionTitleFont
            )

            Text(
                "Only describes GPS-route availability."
            )
            .font(
                .caption
            )
            .foregroundStyle(
                .secondary
            )

            routeStateButton(
                .routeVisible,
                shortcut:
                    "5",
                shortcutText:
                    "5"
            )

            routeStateButton(
                .noGPSRoute,
                shortcut:
                    "6",
                shortcutText:
                    "6"
            )

            routeStateButton(
                .unknown,
                shortcut:
                    "7",
                shortcutText:
                    "7"
            )
        }
    }

    // MARK: Route Shape Section

    private var routeShapeSection:
        some View {

        VStack(
            alignment: .leading,
            spacing: 10
        ) {

            Text(
                "ROUTE SHAPE"
            )
            .font(
                sectionTitleFont
            )

            Text(
                "Selecting a shape automatically marks the minimap and GPS route as visible."
            )
            .font(
                .caption
            )
            .foregroundStyle(
                .secondary
            )

            routeShapeButton(
                .straight,
                shortcut:
                    "8",
                shortcutText:
                    "8"
            )

            routeShapeButton(
                .leftTurn,
                shortcut:
                    "9",
                shortcutText:
                    "9"
            )

            routeShapeButton(
                .rightTurn,
                shortcut:
                    "0",
                shortcutText:
                    "0"
            )

            routeShapeButton(
                .sharpOrComplex,
                shortcut:
                    "q",
                shortcutText:
                    "Q"
            )

            routeShapeButton(
                .sCurveOrIntersection,
                shortcut:
                    "w",
                shortcutText:
                    "W"
            )

            routeShapeButton(
                .uTurnOrReverseDirection,
                shortcut:
                    "u",
                shortcutText:
                    "U"
            )
        }
    }

    // MARK: Conditions

    private var conditionSection:
        some View {

        VStack(
            alignment: .leading,
            spacing: 10
        ) {

            Text(
                "SCENE CONDITIONS"
            )
            .font(
                sectionTitleFont
            )

            Text(
                "These may contain multiple labels."
            )
            .font(
                .caption
            )
            .foregroundStyle(
                .secondary
            )

            conditionButton(
                .day,
                shortcut:
                    "d",
                shortcutText:
                    "D"
            )

            conditionButton(
                .night,
                shortcut:
                    "n",
                shortcutText:
                    "N"
            )

            conditionButton(
                .rain,
                shortcut:
                    "r",
                shortcutText:
                    "R"
            )

            conditionButton(
                .city,
                shortcut:
                    "c",
                shortcutText:
                    "C"
            )

            conditionButton(
                .openRoad,
                shortcut:
                    "o",
                shortcutText:
                    "O"
            )

            conditionButton(
                .heavyInterference,
                shortcut:
                    "i",
                shortcutText:
                    "I"
            )

            Button(
                "Clear Conditions"
            ) {

                selectedConditions
                    .removeAll()

                hasUnsavedChanges =
                    true
            }
            .buttonStyle(
                .borderless
            )
            .font(
                .caption
            )
        }
    }

    // MARK: Keyboard Help

    private var shortcutHelp:
        some View {

        VStack(
            alignment: .leading,
            spacing: 7
        ) {

            Text(
                "KEYBOARD"
            )
            .font(
                .system(
                    size: 11,
                    weight: .bold,
                    design: .monospaced
                )
            )

            shortcutRow(
                key:
                    "1–4",
                action:
                    "Minimap state"
            )

            shortcutRow(
                key:
                    "5–7",
                action:
                    "Route state"
            )

            shortcutRow(
                key:
                    "8 9 0",
                action:
                    "Straight / Left / Right"
            )

            shortcutRow(
                key:
                    "Q / W",
                action:
                    "Complex / S-curve"
            )

            shortcutRow(
                key:
                    "U",
                action:
                    "U-Turn / Reverse"
            )

            shortcutRow(
                key:
                    "D N R",
                action:
                    "Day / Night / Rain"
            )

            shortcutRow(
                key:
                    "C O I",
                action:
                    "City / Open / Interference"
            )

            shortcutRow(
                key:
                    "Return",
                action:
                    "Save + Next"
            )

            shortcutRow(
                key:
                    "⌘S",
                action:
                    "Save"
            )

            shortcutRow(
                key:
                    "←",
                action:
                    "Previous"
            )
        }
    }

    // MARK: Footer

    private var footer:
        some View {

        HStack(
            spacing: 12
        ) {

            Button {

                goToPreviousImage()

            } label: {

                Label(
                    "Previous",
                    systemImage:
                        "chevron.left"
                )
            }
            .buttonStyle(
                .bordered
            )
            .keyboardShortcut(
                .leftArrow,
                modifiers:
                    []
            )
            .disabled(
                currentIndex <= 0 ||
                imageURLs.isEmpty
            )

            Button {

                goToFirstUnlabeledImage()

            } label: {

                Label(
                    "First Unlabeled",
                    systemImage:
                        "forward.end"
                )
            }
            .buttonStyle(
                .bordered
            )
            .disabled(
                imageURLs.isEmpty
            )

            Spacer()

            Button {

                clearCurrentLabels()

            } label: {

                Label(
                    "Clear",
                    systemImage:
                        "eraser"
                )
            }
            .buttonStyle(
                .bordered
            )
            .disabled(
                currentURL == nil
            )

            Button {

                saveCurrentMetadata(
                    advance:
                        false
                )

            } label: {

                Label(
                    "Save",
                    systemImage:
                        "square.and.arrow.down"
                )
            }
            .buttonStyle(
                .bordered
            )
            .keyboardShortcut(
                "s",
                modifiers:
                    [.command]
            )
            .disabled(
                currentURL == nil
            )

            Button {

                saveCurrentMetadata(
                    advance:
                        true
                )

            } label: {

                Label(
                    "Save + Next",
                    systemImage:
                        "arrow.right.circle.fill"
                )
            }
            .buttonStyle(
                .borderedProminent
            )
            .keyboardShortcut(
                .return,
                modifiers:
                    []
            )
            .disabled(
                currentURL == nil
            )
        }
        .padding(
            .horizontal,
            20
        )
        .padding(
            .vertical,
            14
        )
    }

    // MARK: Section Font

    private var sectionTitleFont:
        Font {

        .system(
            size: 12,
            weight: .bold,
            design: .monospaced
        )
    }

    // MARK: Minimap State Button

    private func minimapStateButton(
        _ state:
            DatasetMinimapState,
        shortcut:
            KeyEquivalent,
        shortcutText:
            String
    ) -> some View {

        Button {

            selectMinimapState(
                state
            )

        } label: {

            labelButtonContent(
                title:
                    state
                        .displayName,
                shortcutText:
                    shortcutText,
                selected:
                    selectedMinimapState ==
                    state
            )
        }
        .buttonStyle(
            .plain
        )
        .keyboardShortcut(
            shortcut,
            modifiers:
                []
        )
    }

    // MARK: Route State Button

    private func routeStateButton(
        _ state:
            DatasetRouteState,
        shortcut:
            KeyEquivalent,
        shortcutText:
            String
    ) -> some View {

        Button {

            selectRouteState(
                state
            )

        } label: {

            labelButtonContent(
                title:
                    state
                        .displayName,
                shortcutText:
                    shortcutText,
                selected:
                    selectedRouteState ==
                    state
            )
        }
        .buttonStyle(
            .plain
        )
        .keyboardShortcut(
            shortcut,
            modifiers:
                []
        )
    }

    // MARK: Route Shape Button

    private func routeShapeButton(
        _ category:
            DatasetRouteCategory,
        shortcut:
            KeyEquivalent,
        shortcutText:
            String
    ) -> some View {

        Button {

            selectRouteCategory(
                category
            )

        } label: {

            labelButtonContent(
                title:
                    category
                        .displayName,
                shortcutText:
                    shortcutText,
                selected:
                    selectedRouteCategory ==
                    category
            )
        }
        .buttonStyle(
            .plain
        )
        .keyboardShortcut(
            shortcut,
            modifiers:
                []
        )
    }

    // MARK: Condition Button

    private func conditionButton(
        _ category:
            DatasetConditionCategory,
        shortcut:
            KeyEquivalent,
        shortcutText:
            String
    ) -> some View {

        Button {

            toggleCondition(
                category
            )

        } label: {

            labelButtonContent(
                title:
                    category
                        .displayName,
                shortcutText:
                    shortcutText,
                selected:
                    selectedConditions
                        .contains(
                            category
                        )
            )
        }
        .buttonStyle(
            .plain
        )
        .keyboardShortcut(
            shortcut,
            modifiers:
                []
        )
    }

    // MARK: Shared Button UI

    private func labelButtonContent(
        title:
            String,
        shortcutText:
            String,
        selected:
            Bool
    ) -> some View {

        HStack(
            spacing: 10
        ) {

            Text(
                shortcutText
            )
            .font(
                .system(
                    size: 10,
                    weight: .bold,
                    design: .monospaced
                )
            )
            .frame(
                width: 24,
                height: 24
            )
            .background(
                Color.primary
                    .opacity(
                        0.08
                    )
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 5
                )
            )

            Text(
                title
            )
            .font(
                .system(
                    size: 12,
                    weight:
                        selected
                        ? .semibold
                        : .regular
                )
            )

            Spacer()

            if selected {

                Image(
                    systemName:
                        "checkmark.circle.fill"
                )
                .foregroundStyle(
                    Color.accentColor
                )
            }
        }
        .padding(
            .horizontal,
            10
        )
        .padding(
            .vertical,
            7
        )
        .background(
            selected
            ? Color.accentColor
                .opacity(
                    0.14
                )
            : Color.primary
                .opacity(
                    0.035
                )
        )
        .overlay {

            RoundedRectangle(
                cornerRadius: 7
            )
            .stroke(
                selected
                ? Color.accentColor
                : Color.primary
                    .opacity(
                        0.10
                    ),
                lineWidth:
                    selected
                    ? 1.4
                    : 1
            )
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: 7
            )
        )
        .contentShape(
            Rectangle()
        )
    }

    // MARK: Shortcut Row

    private func shortcutRow(
        key:
            String,
        action:
            String
    ) -> some View {

        HStack {

            Text(
                key
            )
            .font(
                .system(
                    size: 10,
                    weight: .semibold,
                    design: .monospaced
                )
            )
            .frame(
                width: 70,
                alignment: .leading
            )

            Text(
                action
            )
            .font(
                .system(
                    size: 10
                )
            )
            .foregroundStyle(
                .secondary
            )
        }
    }

    // MARK: Minimap Selection

    private func selectMinimapState(
        _ state:
            DatasetMinimapState
    ) {

        selectedMinimapState =
            state

        switch state {

        case .visible:

            /*
             Keep the current route state
             if one was already selected.
             */

            break

        case .partialOrObstructed:

            /*
             Keep route state if visible
             information can still be seen.
             */

            break

        case .missing:

            selectedRouteState =
                .unknown

            selectedRouteCategory =
                nil

        case .invalidFrame:

            selectedRouteState =
                .unknown

            selectedRouteCategory =
                nil

            selectedConditions
                .removeAll()
        }

        hasUnsavedChanges =
            true
    }

    // MARK: Route State Selection

    private func selectRouteState(
        _ state:
            DatasetRouteState
    ) {

        switch state {

        case .routeVisible:

            /*
             If a GPS route exists then a
             minimap must exist too.

             Do not override Partial /
             Obstructed if the user already
             selected it.
             */

            if selectedMinimapState ==
                nil ||
                selectedMinimapState ==
                .missing ||
                selectedMinimapState ==
                .invalidFrame {

                selectedMinimapState =
                    .visible
            }

            selectedRouteState =
                .routeVisible

        case .noGPSRoute:

            if selectedMinimapState ==
                nil ||
                selectedMinimapState ==
                .missing ||
                selectedMinimapState ==
                .invalidFrame {

                selectedMinimapState =
                    .visible
            }

            selectedRouteState =
                .noGPSRoute

            selectedRouteCategory =
                nil

        case .unknown:

            selectedRouteState =
                .unknown

            selectedRouteCategory =
                nil
        }

        hasUnsavedChanges =
            true
    }

    // MARK: Route Shape Selection

    private func selectRouteCategory(
        _ category:
            DatasetRouteCategory
    ) {

        /*
         Choosing a route shape implies:
         - minimap exists
         - GPS route exists
         */

        if selectedMinimapState !=
            .partialOrObstructed {

            selectedMinimapState =
                .visible
        }

        selectedRouteState =
            .routeVisible

        selectedRouteCategory =
            category

        hasUnsavedChanges =
            true
    }

    // MARK: Conditions

    private func toggleCondition(
        _ category:
            DatasetConditionCategory
    ) {

        if selectedConditions
            .contains(
                category
            ) {

            selectedConditions
                .remove(
                    category
                )

            hasUnsavedChanges =
                true

            return
        }

        switch category {

        case .day:

            selectedConditions
                .remove(
                    .night
                )

        case .night:

            selectedConditions
                .remove(
                    .day
                )

        case .city:

            selectedConditions
                .remove(
                    .openRoad
                )

        case .openRoad:

            selectedConditions
                .remove(
                    .city
                )

        case .rain,
             .heavyInterference:

            break
        }

        selectedConditions
            .insert(
                category
            )

        hasUnsavedChanges =
            true
    }

    // MARK: Clear Labels

    private func clearCurrentLabels() {

        selectedMinimapState =
            nil

        selectedRouteState =
            nil

        selectedRouteCategory =
            nil

        selectedConditions
            .removeAll()

        hasUnsavedChanges =
            true

        statusMessage =
            "Current selections cleared. Save to overwrite existing metadata."
    }

    // MARK: Validation

    private func validationError() -> String? {

        guard let minimapState =
                selectedMinimapState else {

            return
                "Choose a Minimap State before saving."
        }

        switch minimapState {

        case .missing,
             .invalidFrame:

            return nil

        case .partialOrObstructed:

            guard selectedRouteState !=
                    nil else {

                return
                    "Choose a Route State for the partial / obstructed minimap."
            }

            return nil

        case .visible:

            guard let routeState =
                    selectedRouteState else {

                return
                    "Choose a Route State before saving."
            }

            if routeState ==
                .routeVisible,
               selectedRouteCategory ==
                nil {

                return
                    "GPS route is visible. Choose a Route Shape."
            }

            return nil
        }
    }

    // MARK: Dataset Loading

    private func loadDataset() {

        do {

            let files =
                try FileManager.default
                    .contentsOfDirectory(
                        at:
                            store.rawFolderURL,
                        includingPropertiesForKeys:
                            nil,
                        options:
                            [
                                .skipsHiddenFiles
                            ]
                    )

            let pngFiles =
                files
                    .filter {

                        $0
                            .pathExtension
                            .lowercased() ==
                            "png"
                    }
                    .sorted {

                        $0
                            .lastPathComponent
                            .localizedStandardCompare(
                                $1
                                    .lastPathComponent
                            ) ==
                            .orderedAscending
                    }

            imageURLs =
                pngFiles

            guard !pngFiles
                .isEmpty else {

                currentIndex =
                    0

                currentImage =
                    nil

                clearLoadedSelection()

                statusMessage =
                    "No PNG images were found in the minimap/raw folder."

                return
            }

            if !resumeImageName
                .isEmpty,
               let resumeIndex =
                    pngFiles
                        .firstIndex(
                            where: {

                                $0
                                    .lastPathComponent ==
                                    resumeImageName
                            }
                        ) {

                currentIndex =
                    resumeIndex

            } else {

                currentIndex =
                    0
            }

            loadCurrentImage()

            store.refresh()

        } catch {

            imageURLs =
                []

            currentImage =
                nil

            statusMessage =
                "Dataset load failed: \(error.localizedDescription)"
        }
    }

    // MARK: Load Current Image

    private func loadCurrentImage() {

        guard let url =
                currentURL else {

            currentImage =
                nil

            return
        }

        currentImage =
            NSImage(
                contentsOf:
                    url
            )

        if let metadata =
                store.metadata(
                    forImageName:
                        url
                            .lastPathComponent
                ) {

            selectedMinimapState =
                metadata
                    .minimapState

            selectedRouteState =
                metadata
                    .routeState

            selectedRouteCategory =
                metadata
                    .routeCategory

            selectedConditions =
                metadata
                    .conditions

            currentHasSavedMetadata =
                metadata
                    .isLabelComplete

            statusMessage =
                metadata
                    .isLabelComplete
                ? "Existing metadata loaded."
                : "Existing metadata is incomplete. Finish labeling this image."

        } else {

            clearLoadedSelection()

            currentHasSavedMetadata =
                false

            statusMessage =
                "Ready to label."
        }

        hasUnsavedChanges =
            false

        resumeImageName =
            url
                .lastPathComponent
    }

    private func clearLoadedSelection() {

        selectedMinimapState =
            nil

        selectedRouteState =
            nil

        selectedRouteCategory =
            nil

        selectedConditions
            .removeAll()
    }

    // MARK: Navigation

    private func goToPreviousImage() {

        guard currentIndex > 0 else {
            return
        }

        currentIndex -=
            1

        loadCurrentImage()
    }

    private func goToNextImage() {

        guard currentIndex + 1 <
                imageURLs.count else {

            statusMessage =
                "Reached the final image."

            return
        }

        currentIndex +=
            1

        loadCurrentImage()
    }

    private func goToFirstUnlabeledImage() {

        guard !imageURLs
            .isEmpty else {

            return
        }

        if let index =
                imageURLs
                    .firstIndex(
                        where: {

                            let metadata =
                                store.metadata(
                                    forImageName:
                                        $0
                                            .lastPathComponent
                                )

                            return metadata?
                                .isLabelComplete !=
                                true
                        }
                    ) {

            currentIndex =
                index

            loadCurrentImage()

            statusMessage =
                "Jumped to first unlabeled image."

        } else {

            statusMessage =
                "Every image currently has a complete metadata label."
        }
    }

    // MARK: Save

    private func saveCurrentMetadata(
        advance:
            Bool
    ) {

        guard let url =
                currentURL else {

            statusMessage =
                "No image selected."

            return
        }

        if let validationError =
                validationError() {

            statusMessage =
                validationError

            NSSound.beep()

            return
        }

        let metadata =
            DatasetImageMetadata(
                imageName:
                    url
                        .lastPathComponent,
                minimapState:
                    selectedMinimapState,
                routeState:
                    selectedRouteState,
                routeCategory:
                    selectedRouteCategory,
                conditions:
                    selectedConditions
            )

        store.saveMetadata(
            metadata
        )

        currentHasSavedMetadata =
            true

        hasUnsavedChanges =
            false

        let savedName =
            url
                .lastPathComponent

        if advance {

            if currentIndex + 1 <
                imageURLs.count {

                goToNextImage()

                statusMessage =
                    "Saved \(savedName). Next image loaded."

            } else {

                resumeImageName =
                    savedName

                statusMessage =
                    "Saved \(savedName). Final image reached."
            }

        } else {

            statusMessage =
                "Saved \(savedName)."
        }
    }
}
