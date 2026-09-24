import Combine
import Foundation

// MARK: - Minimap State

nonisolated enum DatasetMinimapState:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Identifiable {

    case visible
    case missing
    case partialOrObstructed
    case invalidFrame

    var id:
        String {

        rawValue
    }

    var displayName:
        String {

        switch self {

        case .visible:
            return "Visible"

        case .missing:
            return "Missing"

        case .partialOrObstructed:
            return "Partial / Obstructed"

        case .invalidFrame:
            return "Invalid Frame"
        }
    }

    var targetCount:
        Int {

        switch self {

        case .visible:
            return 20

        case .missing:
            return 20

        case .partialOrObstructed:
            return 20

        case .invalidFrame:
            return 10
        }
    }
}


// MARK: - Route State

nonisolated enum DatasetRouteState:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Identifiable {

    case routeVisible
    case noGPSRoute
    case unknown

    var id:
        String {

        rawValue
    }

    var displayName:
        String {

        switch self {

        case .routeVisible:
            return "Route Visible"

        case .noGPSRoute:
            return "No GPS Route"

        case .unknown:
            return "Unknown"
        }
    }

    var targetCount:
        Int? {

        switch self {

        case .routeVisible:
            return 20

        case .noGPSRoute:
            return 20

        case .unknown:
            return nil
        }
    }
}


// MARK: - Route Shape

nonisolated enum DatasetRouteCategory:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Identifiable {

    case straight
    case leftTurn
    case rightTurn
    case sharpOrComplex
    case sCurveOrIntersection
    case uTurnOrReverseDirection

    var id:
        String {

        rawValue
    }

    var displayName:
        String {

        switch self {

        case .straight:
            return "Straight"

        case .leftTurn:
            return "Left Turn"

        case .rightTurn:
            return "Right Turn"

        case .sharpOrComplex:
            return "Sharp / Complex"

        case .sCurveOrIntersection:
            return "S-Curve / Intersection"
            
        case .uTurnOrReverseDirection:
            return "U-Turn / Reverse Direction"
        }
    }

    var targetCount:
        Int {

        20
    }
}


// MARK: - Scene Conditions

nonisolated enum DatasetConditionCategory:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Identifiable {

    case day
    case night
    case rain
    case city
    case openRoad
    case heavyInterference

    var id:
        String {

        rawValue
    }

    var displayName:
        String {

        switch self {

        case .day:
            return "Day"

        case .night:
            return "Night"

        case .rain:
            return "Rain"

        case .city:
            return "City"

        case .openRoad:
            return "Open Road"

        case .heavyInterference:
            return "Heavy Interference"
        }
    }

    var targetCount:
        Int {

        20
    }
}


// MARK: - Image Metadata

nonisolated struct DatasetImageMetadata:
    Codable,
    Equatable {

    let imageName:
        String

    var minimapState:
        DatasetMinimapState?

    var routeState:
        DatasetRouteState?

    var routeCategory:
        DatasetRouteCategory?

    var conditions:
        Set<DatasetConditionCategory>

    init(
        imageName:
            String,
        minimapState:
            DatasetMinimapState? = nil,
        routeState:
            DatasetRouteState? = nil,
        routeCategory:
            DatasetRouteCategory? = nil,
        conditions:
            Set<DatasetConditionCategory> = []
    ) {

        self.imageName =
            imageName

        self.minimapState =
            minimapState

        self.routeState =
            routeState

        self.routeCategory =
            routeCategory

        self.conditions =
            conditions
    }

    // MARK: Label Completion

    var isLabelComplete:
        Bool {

        guard let minimapState else {
            return false
        }

        switch minimapState {

        case .missing,
             .invalidFrame:

            /*
             If the minimap does not exist,
             we already know enough to use
             this image as a negative example.
             */

            return true

        case .partialOrObstructed:

            /*
             Route information may genuinely
             be impossible to classify because
             the minimap is obstructed.
             */

            return routeState != nil

        case .visible:

            guard let routeState else {
                return false
            }

            switch routeState {

            case .routeVisible:

                /*
                 If the route is visible on a
                 normal minimap image, we also
                 want its route shape.
                 */

                return routeCategory != nil

            case .noGPSRoute,
                 .unknown:

                return true
            }
        }
    }

    // MARK: Codable Keys

    private enum CodingKeys:
        String,
        CodingKey {

        case imageName
        case minimapState
        case routeState
        case routeCategory
        case conditions

        /*
         Legacy key from the original
         Dataset Labeler format.
         */

        case routeCategories
    }

    // MARK: Decode

    init(
        from decoder:
            Decoder
    ) throws {

        let container =
            try decoder.container(
                keyedBy:
                    CodingKeys.self
            )

        imageName =
            try container.decode(
                String.self,
                forKey:
                    .imageName
            )

        conditions =
            try container.decodeIfPresent(
                Set<DatasetConditionCategory>.self,
                forKey:
                    .conditions
            ) ??
            []

        minimapState =
            try container.decodeIfPresent(
                DatasetMinimapState.self,
                forKey:
                    .minimapState
            )

        routeState =
            try container.decodeIfPresent(
                DatasetRouteState.self,
                forKey:
                    .routeState
            )

        routeCategory =
            try container.decodeIfPresent(
                DatasetRouteCategory.self,
                forKey:
                    .routeCategory
            )

        // MARK: Legacy Migration

        /*
         The first version of the labeler stored:

         routeCategories: [
             "straight"
         ]

         or:

         routeCategories: [
             "noGPSRoute"
         ]

         We migrate those values automatically
         when reading old JSON files.
         */

        if minimapState == nil,
           routeState == nil,
           routeCategory == nil {

            let legacyRouteCategories =
                try container.decodeIfPresent(
                    Set<String>.self,
                    forKey:
                        .routeCategories
                ) ??
                []

            if legacyRouteCategories
                .contains(
                    "noGPSRoute"
                ) {

                minimapState =
                    .visible

                routeState =
                    .noGPSRoute

                routeCategory =
                    nil

            } else {

                for rawValue in
                    legacyRouteCategories {

                    if let migratedCategory =
                            DatasetRouteCategory(
                                rawValue:
                                    rawValue
                            ) {

                        minimapState =
                            .visible

                        routeState =
                            .routeVisible

                        routeCategory =
                            migratedCategory

                        break
                    }
                }
            }
        }
    }

    // MARK: Encode

    func encode(
        to encoder:
            Encoder
    ) throws {

        var container =
            encoder.container(
                keyedBy:
                    CodingKeys.self
            )

        try container.encode(
            imageName,
            forKey:
                .imageName
        )

        try container.encodeIfPresent(
            minimapState,
            forKey:
                .minimapState
        )

        try container.encodeIfPresent(
            routeState,
            forKey:
                .routeState
        )

        try container.encodeIfPresent(
            routeCategory,
            forKey:
                .routeCategory
        )

        try container.encode(
            conditions,
            forKey:
                .conditions
        )
    }
}


// MARK: - Dataset Metadata Store

final class DatasetMetadataStore:
    ObservableObject {

    // MARK: Published Audit State

    @Published private(set)
    var rawImageCount =
        0

    @Published private(set)
    var labeledImageCount =
        0

    @Published private(set)
    var minimapStateCounts:
        [DatasetMinimapState: Int] = [:]

    @Published private(set)
    var routeStateCounts:
        [DatasetRouteState: Int] = [:]

    @Published private(set)
    var routeCounts:
        [DatasetRouteCategory: Int] = [:]

    @Published private(set)
    var conditionCounts:
        [DatasetConditionCategory: Int] = [:]

    @Published private(set)
    var lastErrorMessage:
        String?

    // MARK: Folder Locations

    let rawFolderURL:
        URL

    let metadataFolderURL:
        URL

    // MARK: Work Queue

    private let metadataQueue =
        DispatchQueue(
            label:
                "com.racingtrainer.dataset-metadata",
            qos:
                .utility
        )

    // MARK: Init

    init(
        rawFolderURL:
            URL
    ) {

        self.rawFolderURL =
            rawFolderURL

        self.metadataFolderURL =
            rawFolderURL
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "metadata",
                    isDirectory:
                        true
                )

        createMetadataFolderIfNeeded()

        refresh()
    }

    // MARK: General Counts

    var unlabeledImageCount:
        Int {

        max(
            rawImageCount -
            labeledImageCount,
            0
        )
    }

    // MARK: Minimap State Counts

    func count(
        for state:
            DatasetMinimapState
    ) -> Int {

        minimapStateCounts[
            state
        ] ??
        0
    }

    func missingCount(
        for state:
            DatasetMinimapState
    ) -> Int {

        max(
            state.targetCount -
            count(
                for:
                    state
            ),
            0
        )
    }

    // MARK: Route State Counts

    func count(
        for state:
            DatasetRouteState
    ) -> Int {

        routeStateCounts[
            state
        ] ??
        0
    }

    func missingCount(
        for state:
            DatasetRouteState
    ) -> Int {

        guard let target =
                state.targetCount else {

            return 0
        }

        return max(
            target -
            count(
                for:
                    state
            ),
            0
        )
    }

    // MARK: Route Shape Counts

    func count(
        for category:
            DatasetRouteCategory
    ) -> Int {

        routeCounts[
            category
        ] ??
        0
    }

    func missingCount(
        for category:
            DatasetRouteCategory
    ) -> Int {

        max(
            category.targetCount -
            count(
                for:
                    category
            ),
            0
        )
    }

    // MARK: Condition Counts

    func count(
        for category:
            DatasetConditionCategory
    ) -> Int {

        conditionCounts[
            category
        ] ??
        0
    }

    func missingCount(
        for category:
            DatasetConditionCategory
    ) -> Int {

        max(
            category.targetCount -
            count(
                for:
                    category
            ),
            0
        )
    }

    // MARK: Raw Dataset Updates

    func rawImageWasAdded() {

        DispatchQueue.main.async {
            [weak self] in

            self?
                .rawImageCount +=
                1
        }
    }

    // MARK: Save Metadata

    func saveMetadata(
        _ metadata:
            DatasetImageMetadata
    ) {

        metadataQueue.async {
            [weak self] in

            guard let self else {
                return
            }

            do {

                try FileManager.default
                    .createDirectory(
                        at:
                            self
                                .metadataFolderURL,
                        withIntermediateDirectories:
                            true
                    )

                let fileURL =
                    self.metadataFileURL(
                        forImageName:
                            metadata
                                .imageName
                    )

                let encoder =
                    JSONEncoder()

                encoder.outputFormatting = [
                    .prettyPrinted,
                    .sortedKeys
                ]

                let data =
                    try encoder.encode(
                        metadata
                    )

                try data.write(
                    to:
                        fileURL,
                    options:
                        .atomic
                )

                self.refresh()

            } catch {

                self.publishError(
                    error
                        .localizedDescription
                )
            }
        }
    }

    // MARK: Read Metadata

    func metadata(
        forImageName imageName:
            String
    ) -> DatasetImageMetadata? {

        let fileURL =
            metadataFileURL(
                forImageName:
                    imageName
            )

        guard let data =
                try? Data(
                    contentsOf:
                        fileURL
                ) else {

            return nil
        }

        return try?
            JSONDecoder()
                .decode(
                    DatasetImageMetadata.self,
                    from:
                        data
                )
    }

    // MARK: Audit Refresh

    func refresh() {

        metadataQueue.async {
            [weak self] in

            guard let self else {
                return
            }

            self
                .createMetadataFolderIfNeeded()

            let rawCount =
                self.countPNGFiles(
                    in:
                        self.rawFolderURL
                )

            let metadataFiles =
                self.jsonFiles(
                    in:
                        self.metadataFolderURL
                )

            var minimapCounts:
                [DatasetMinimapState: Int] = [:]

            var routeStateCounts:
                [DatasetRouteState: Int] = [:]

            var routeCounts:
                [DatasetRouteCategory: Int] = [:]

            var conditionCounts:
                [DatasetConditionCategory: Int] = [:]

            var labeledImages =
                Set<String>()

            let decoder =
                JSONDecoder()

            var firstDecodeError:
                String?

            for fileURL in
                metadataFiles {

                do {

                    let data =
                        try Data(
                            contentsOf:
                                fileURL
                        )

                    let metadata =
                        try decoder.decode(
                            DatasetImageMetadata.self,
                            from:
                                data
                        )

                    /*
                     A JSON file existing does not
                     automatically mean the image
                     has a complete usable label.
                     */

                    guard metadata
                        .isLabelComplete else {

                        continue
                    }

                    labeledImages.insert(
                        metadata
                            .imageName
                    )

                    if let minimapState =
                            metadata
                                .minimapState {

                        minimapCounts[
                            minimapState,
                            default:
                                0
                        ] += 1
                    }

                    if let routeState =
                            metadata
                                .routeState {

                        routeStateCounts[
                            routeState,
                            default:
                                0
                        ] += 1
                    }

                    if let routeCategory =
                            metadata
                                .routeCategory {

                        routeCounts[
                            routeCategory,
                            default:
                                0
                        ] += 1
                    }

                    for condition in
                        metadata
                            .conditions {

                        conditionCounts[
                            condition,
                            default:
                                0
                        ] += 1
                    }

                } catch {

                    if firstDecodeError ==
                        nil {

                        firstDecodeError =
                            "Could not read \(fileURL.lastPathComponent): \(error.localizedDescription)"
                    }
                }
            }

            DispatchQueue.main.async {

                self.rawImageCount =
                    rawCount

                self.labeledImageCount =
                    labeledImages
                        .count

                self.minimapStateCounts =
                    minimapCounts

                self.routeStateCounts =
                    routeStateCounts

                self.routeCounts =
                    routeCounts

                self.conditionCounts =
                    conditionCounts

                self.lastErrorMessage =
                    firstDecodeError
            }
        }
    }

    // MARK: Helpers

    private func createMetadataFolderIfNeeded() {

        do {

            try FileManager.default
                .createDirectory(
                    at:
                        metadataFolderURL,
                    withIntermediateDirectories:
                        true
                )

        } catch {

            publishError(
                error
                    .localizedDescription
            )
        }
    }

    private func metadataFileURL(
        forImageName imageName:
            String
    ) -> URL {

        let baseName =
            URL(
                fileURLWithPath:
                    imageName
            )
            .deletingPathExtension()
            .lastPathComponent

        return metadataFolderURL
            .appendingPathComponent(
                baseName
            )
            .appendingPathExtension(
                "json"
            )
    }

    private func countPNGFiles(
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

        return files
            .filter {

                $0
                    .pathExtension
                    .lowercased() ==
                    "png"
            }
            .count
    }

    private func jsonFiles(
        in folderURL:
            URL
    ) -> [URL] {

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

            return []
        }

        return files
            .filter {

                $0
                    .pathExtension
                    .lowercased() ==
                    "json"
            }
    }

    private func publishError(
        _ message:
            String
    ) {

        DispatchQueue.main.async {
            [weak self] in

            self?
                .lastErrorMessage =
                message
        }
    }
}
