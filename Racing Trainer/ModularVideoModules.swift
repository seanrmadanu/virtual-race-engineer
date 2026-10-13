import CoreVideo
import Foundation

/// Native module adapter used by offline replay and opt-in shadow capture. It never issues cues.
/// Own this object on one serial queue. No player-wheel inset enters any module.
nonisolated final class ModularVideoModules {
    private var detector = MinimapRouteDetector()
    private let geometry = MinimapGeometryAnalyzer()
    private var previousPath: [MinimapPoint] = []
    private var previousTime: Double?
    private var previousSession: Int?
    private var lastFingerprint: UInt64?
    private var unchangedSince: Double?
    private var previousSpeed: (Double, Double)?
    // Measured on uncropped Video 2. Kept separate from the legacy live HUD profile.
    private let speedCrop: CGRect?
    private let profileID: String
    private let camera: RoadCameraMode
    private let roadDetector = RoadLineDetector()

    init(profileID: String, camera: RoadCameraMode = .chase) {
        self.profileID = profileID
        self.camera = camera
        speedCrop = profileID == "reference-video2-v1" ? CGRect(x: 0.075, y: 0.854, width: 0.070, height: 0.073)
            : profileID == "motorfest-standard-v1" ? MotorfestHUDLayout.speedOCR.normalizedRect : nil
    }

    func reset() {
        detector = MinimapRouteDetector(); previousPath = []; previousTime = nil
        previousSession = nil; lastFingerprint = nil; unchangedSince = nil; previousSpeed = nil
    }

    func analyze(pixelBuffer: CVPixelBuffer, capturedAt: Double, startedAt: Double,
                 session: Int, confirmedSpeedUnit: String?) -> [String: CoachModuleObservation] {
        if previousSession != session || previousTime.map({ capturedAt <= $0 || capturedAt - $0 > 0.75 }) == true {
            reset()
        }
        previousTime = capturedAt; previousSession = session
        let wallStart = ProcessInfo.processInfo.systemUptime
        func observation(_ name: String, value: CoachModuleValue?, state: PerceptionState, confidence: Float,
                         units: String?, reason: String?, evidence: [String: String]) -> CoachModuleObservation {
            CoachModuleObservation(value: value, state: state, confidence: confidence,
                                   capturedAt: capturedAt,
                                   completedAt: startedAt + ProcessInfo.processInfo.systemUptime - wallStart,
                                   sourceSessionID: session, implementation: name, version: "2",
                                   failureReason: reason, units: units, evidence: evidence,
                                   confidenceKind: name == "speed-ocr" ? "vision_score_uncalibrated" : "heuristic_not_probability")
        }
        let speed = MotorfestSpeedRecognizer.recognize(in: pixelBuffer,
            region: speedCrop ?? MotorfestHUDLayout.speedOCR.normalizedRect, rejectEdgePixels: true)
        var speedReason: String? = speed.speed == nil ? "digits_missing_or_clipped" : nil
        if speedCrop == nil { speedReason = "hud_profile_unconfirmed" }
        if let value = speed.speed, let previous = previousSpeed, capturedAt > previous.1,
           abs(Double(value) - previous.0) / (capturedAt - previous.1) > 100 {
            speedReason = "implausible_speed_change"
        }
        if let value = speed.speed { previousSpeed = (Double(value), capturedAt) } else { previousSpeed = nil }
        let speedOutput = observation("speed-ocr", value: speed.speed.map { CoachModuleValue(number: Double($0)) },
                                      state: speedReason == nil ? .fresh : (speed.speed == nil ? .missing : .uncertain),
                                      confidence: speed.confidence, units: confirmedSpeedUnit,
                                      reason: speedReason, evidence: ["rawText": speed.rawText, "cropProfile": profileID,
                                                                   "unitSource": confirmedSpeedUnit == nil ? "unconfirmed" : "explicit_source_setting"])
        let map = detector.analyze(pixelBuffer: pixelBuffer,
                                   normalizedCropRect: MotorfestHUDLayout.minimapAnalysisRect, includeTrainingMask: true)
        let mapOutput = observation("minimap-detector", value: CoachModuleValue(flag: map.minimapVisible),
                                    state: map.minimapVisible ? .fresh : .missing,
                                    confidence: map.minimapConfidence, units: "normalized_map",
                                    reason: map.minimapVisible ? nil : map.diagnostic.rawValue,
                                    evidence: ["diagnostic": map.diagnostic.rawValue, "routeSource": map.routeSource.rawValue,
                                               "routePixels": String(map.routeMaskPixelCount),
                                               "playerConfidence": String(map.playerDetectionConfidence),
                                               "routeConfidence": String(map.routeConfidence)])
        let route: MinimapGeometryResult
        if map.routeDetected, let mask = map.routeMask, let anchor = map.playerAnchor {
            route = geometry.analyze(mask: mask, playerAnchor: anchor, previousPath: previousPath)
        } else { route = .invalid("missing_route_or_player_anchor") }
        previousPath = route.isValid ? route.orderedPath : []
        let selected = RouteTurnSelector.select(route.orderedPath)
        let hasRoute = route.isValid && selected.direction != "unknown"
        let routeValue = hasRoute ? CoachModuleValue(direction: selected.direction,
            severity: selected.severity, timing: selected.target == "near_route" ? "now" : selected.direction == "straight" ? "none" : "later",
            turnDistance: selected.distance,
            path: route.orderedPath.map { [$0.x, $0.y] }, target: selected.target) : nil
        let geometryOutput = observation("route-geometry", value: routeValue,
            state: hasRoute ? .fresh : .missing, confidence: min(route.geometryConfidence, route.forwardPathConfidence),
            units: "normalized_map", reason: hasRoute ? nil : route.reason,
            evidence: ["reason": route.reason, "branches": String(route.branchPointCount),
                       "selection": selected.reason, "target": selected.target,
                       "scope": "selected_route_geometry_not_vehicle_steering",
                       "legacyDirection": route.direction.rawValue,
                       "geometryConfidence": String(route.geometryConfidence),
                       "forwardPathConfidence": String(route.forwardPathConfidence)])
        let fingerprint = Self.fingerprint(pixelBuffer)
        if fingerprint != lastFingerprint { unchangedSince = capturedAt }
        lastFingerprint = fingerprint
        let stalled = capturedAt - (unchangedSince ?? capturedAt) >= 0.75
        let ratio = Double(CVPixelBufferGetWidth(pixelBuffer)) / Double(max(1, CVPixelBufferGetHeight(pixelBuffer)))
        let valid = abs(ratio - 16.0 / 9.0) < 0.025 && map.minimapVisible && !stalled
        let validityOutput = observation("input-validity", value: CoachModuleValue(flag: valid),
            state: valid ? .fresh : .uncertain, confidence: valid ? 1 : 0, units: "boolean",
            reason: valid ? nil : (stalled ? "stalled_video" : "hud_missing_or_layout_mismatch"),
            evidence: ["cameraStatus": "unverified", "scope": "layout_hud_and_duplicate_frame_checks_only",
                       "fingerprintRegion": "central_gameplay_excluding_upper_left_wheel_inset",
                       "fingerprint": String(fingerprint)])
        let road = roadDetector.analyze(pixelBuffer, at: capturedAt, camera: camera)
        let roadOutput = observation("white-road-lines", value: CoachModuleValue(direction: road.roadDirection,
            flag: road.hasCorridor, road: road), state: road.hasCorridor ? .fresh : .uncertain,
            confidence: Float(road.confidence), units: "normalized_frame", reason: road.hasCorridor ? nil : road.reason,
            evidence: ["reason": road.reason, "camera": camera.rawValue, "scope": "visible_white_line_bounds_not_optimal_path"])
        return ["speed": speedOutput, "minimap": mapOutput, "geometry": geometryOutput, "validity": validityOutput, "road": roadOutput]
    }

    private static func fingerprint(_ buffer: CVPixelBuffer) -> UInt64 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        var hash: UInt64 = 1469598103934665603
        // A moving wheel-camera inset must not make frozen gameplay look fresh.
        for y in Swift.stride(from: height / 3, to: height * 3 / 4, by: max(1, height / 24)) {
            for x in Swift.stride(from: width / 3 * 4, to: width * 3 / 4 * 4, by: max(4, width / 32 * 4)) {
                hash = (hash ^ UInt64(bytes[y * stride + x])) &* 1099511628211
            }
        }
        return hash
    }
}
