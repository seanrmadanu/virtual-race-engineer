import CoreVideo
import XCTest

final class GuidanceReviewUpdateTests: XCTestCase {
    private func mapFrame(centerY: Double, arrowHeight: Double, rectangle: Bool = false,
                          eventOverlay: Bool = false, hasRoute: Bool = true) -> CVPixelBuffer {
        var result: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 320, kCVPixelFormatType_32BGRA, nil, &result)
        let buffer = result!
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<320 { for x in 0..<320 {
            let nx = Double(x) / 320, ny = Double(y) / 320
            let fy = (ny - (centerY - arrowHeight * 0.60)) / arrowHeight
            let dx = abs(nx - 0.63)
            let marker = rectangle ? (abs(ny - centerY) < arrowHeight / 2 && dx < arrowHeight / 2)
                : ((0...1).contains(fy) && dx < arrowHeight * 0.48 * fy
                   && !(fy > 0.72 && dx < (fy - 0.72) * arrowHeight * 0.65))
            let route = hasRoute && ny > 0.14 && ny < centerY - arrowHeight * 0.60 && dx < 0.007
            let red = eventOverlay && ny > centerY + arrowHeight * 0.55
                && ny < centerY + arrowHeight * 1.2 && dx < arrowHeight * 0.5
            let i = y * stride + x * 4
            bytes[i] = marker ? 230 : 30
            bytes[i+1] = marker ? 220 : route ? 230 : 30
            bytes[i+2] = route || red ? 240 : 30
            bytes[i+3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    func testPlayerArrowSurvivesMinimapZoomAndPositionChange() {
        for (y, height) in [(0.80, 0.105), (0.56, 0.055)] {
            let result = MinimapRouteDetector().analyze(pixelBuffer: mapFrame(centerY: y, arrowHeight: height),
                normalizedCropRect: CGRect(x: 0, y: 0, width: 1, height: 1))
            XCTAssertTrue(result.minimapVisible)
            XCTAssertGreaterThanOrEqual(result.minimapConfidence, 0.52)
            XCTAssertEqual(result.playerAnchor?.x ?? 0, 0.63, accuracy: 0.02)
            XCTAssertEqual(result.playerAnchor?.y ?? 0, y, accuracy: 0.03)
        }
    }

    func testSmallCyanRectangleDoesNotReceiveArrowConfidence() {
        let result = MinimapRouteDetector().analyze(pixelBuffer: mapFrame(centerY: 0.56, arrowHeight: 0.035, rectangle: true),
            normalizedCropRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertLessThan(result.minimapConfidence, 0.52)
    }

    func testOccludedMarkerRequiresBothCurrentRouteAndEventPixels() {
        for (red, route) in [(true, true), (false, true), (true, false)] {
            let result = MinimapRouteDetector().analyze(pixelBuffer:
                mapFrame(centerY: 0.56, arrowHeight: 0.035, rectangle: true, eventOverlay: red, hasRoute: route),
                normalizedCropRect: CGRect(x: 0, y: 0, width: 1, height: 1))
            if red && route { XCTAssertGreaterThanOrEqual(result.minimapConfidence, 0.52) }
            else { XCTAssertLessThan(result.minimapConfidence, 0.52) }
        }
    }

    private func paintedFrame(left: Bool, right: Bool, hudOnly: Bool = false) -> CVPixelBuffer {
        var result: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, nil, &result)
        let buffer = result!
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<360 {
            for x in 0..<640 {
                let ny = Double(y) / 360, nx = Double(x) / 640
                let lx = 0.50 - 1.50 * (ny - 0.39), rx = 0.50 + 1.50 * (ny - 0.39)
                let paint = hudOnly ? (nx > 0.80 && ny > 0.65)
                    : ((0.40...0.73).contains(ny) && ((left && abs(nx-lx) < 0.004) || (right && abs(nx-rx) < 0.004)))
                let value: UInt8 = paint ? 235 : 65
                let i = y * stride + x * 4
                bytes[i] = value; bytes[i+1] = value; bytes[i+2] = value; bytes[i+3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    func testRoadCorridorFollowsPixelPaintAndExpires() {
        let road = RoadLineDetector().analyze(paintedFrame(left: true, right: true), at: 10, camera: .chase)
        XCTAssertTrue(road.hasCorridor, road.reason)
        XCTAssertEqual(road.roadDirection, "straight")
        XCTAssertTrue(road.isFresh(at: 10.4))
        XCTAssertFalse(road.isFresh(at: 9.9))
        XCTAssertFalse(road.isFresh(at: 10.7))
        for (l, r) in zip(road.left, road.right) {
            XCTAssertEqual(l.x, 0.50 - 1.50 * (l.y - 0.39), accuracy: 0.015)
            XCTAssertEqual(r.x, 0.50 + 1.50 * (r.y - 0.39), accuracy: 0.015)
        }
    }

    func testMissingOneBoundaryAndWhiteHUDDoNotInventCorridor() {
        for buffer in [paintedFrame(left: false, right: false), paintedFrame(left: true, right: false),
                       paintedFrame(left: true, right: true, hudOnly: true)] {
            XCTAssertFalse(RoadLineDetector().analyze(buffer, at: 10, camera: .chase).hasCorridor)
        }
    }

    func testTiltedStraightIsNotTurnAndBackwardRouteIsUnknown() {
        let tilted = (0..<40).map { i in MinimapPoint(x: 0.48 + Double(i) * 0.002, y: 0.85 - Double(i) * 0.012) }
        XCTAssertEqual(RouteTurnSelector.select(tilted).direction, "straight")
        XCTAssertEqual(RouteTurnSelector.select(Array(tilted.reversed())).direction, "unknown")
    }

    func testLeftAfterSmallRightLeadInSelectsLeft() {
        var path = (0..<20).map { i in MinimapPoint(x: 0.50 + Double(i) * 0.002, y: 0.85 - Double(i) * 0.016) }
        let corner = path.last!
        for i in 1...18 { path.append(MinimapPoint(x: corner.x - Double(i) * 0.018, y: corner.y - Double(i) * 0.003)) }
        let result = RouteTurnSelector.select(path)
        XCTAssertEqual(result.direction, "left")
        XCTAssertEqual(result.target, "upcoming_route")
    }

    private func aiSet() -> AIReviewSet {
        AIReviewSet(schema: "racing-trainer-ai-columns-v1", reviewer: .claude,
            sourceSHA256: String(repeating: "a", count: 64), originalReviewSHA256: String(repeating: "b", count: 64),
            reviewedPipelineSHA256: String(repeating: "c", count: 64), origin: "ai_raw_video_blind",
            humanApproved: false, trainingEligible: false,
            responses: [AIReviewResponse(eventID: "event", time: 455, action: "brake", confidence: "low",
                current: "left", upcoming: "left", observation: "fixture", rationale: "Earlier approach only",
                questions: [], intervalStart: nil, intervalEnd: 452)])
    }

    func testAIResponsesAreBoundToExactSourceAndTimeAndKeepUnknownIntervals() throws {
        let set = aiSet()
        try set.validate()
        XCTAssertNotNil(set.response(at: 455, source: String(repeating: "a", count: 64)))
        XCTAssertNil(set.response(at: 455.1, source: set.sourceSHA256))
        XCTAssertNil(set.response(at: 455, source: String(repeating: "d", count: 64)))
        let decoded = try AIReviewSet.decode(JSONEncoder().encode(set))
        XCTAssertNil(decoded.responses[0].intervalStart)
        XCTAssertEqual(decoded.responses[0].intervalEnd, 452)
        XCTAssertFalse(decoded.trainingEligible)
    }

    func testAIDirectionComparisonSeparatesCurrentBendFromNextTurn() {
        let response = AIReviewResponse(eventID: "opposite-bends", time: 140,
            action: "advance_warning", confidence: "medium", current: "right · apex_region",
            upcoming: "left · visible_continuous", observation: "fixture", rationale: "fixture",
            questions: [], intervalStart: nil, intervalEnd: nil)
        XCTAssertEqual(response.summary(in: .basicTurns), "Now: Right\nNext: Left")
        XCTAssertEqual(response.summary(in: .cornerTechnique), "Apex region")
        XCTAssertEqual(response.summary(in: .slowdownTiming), "Advance warning")
    }

    func testMissingAIJudgmentsAreNotFilledFromAnotherTarget() {
        let response = AIReviewResponse(eventID: "next-only", time: 105,
            action: "advance_warning", confidence: "medium", current: "Not separately labeled",
            upcoming: "right", observation: "fixture", rationale: "fixture",
            questions: [], intervalStart: 103, intervalEnd: 104)
        XCTAssertEqual(response.summary(in: .basicTurns), "Now: Unlabeled\nNext: Right")
        XCTAssertEqual(response.summary(in: .cornerTechnique), "Phase unlabeled")
        XCTAssertEqual(response.summary(in: .slowdownTiming), "Advance warning · earlier interval")
    }

    func testRoadPlaybackNeverUsesFutureObservation() throws {
        let bundle = ModelReviewBundle(schemaVersion: "racing-trainer-review-v1", title: "Fixture",
            source: ModelReviewSource(filename: "fixture.mp4", sha256: String(repeating: "a", count: 64), duration: 20),
            modelSHA256: String(repeating: "b", count: 64), predictionsSHA256: String(repeating: "c", count: 64),
            events: [ModelReviewEvent(id: "one", time: 10, direction: "unknown", target: "unknown", phase: "unknown", reasons: [])],
            roadObservations: [.unavailable(at: 9.9, reason: "past"), .unavailable(at: 10.1, reason: "future")])
        try bundle.validate()
        XCTAssertNil(bundle.road(atPlaybackTime: 9.8))
        XCTAssertEqual(bundle.road(atPlaybackTime: 10)?.reason, "past")
        XCTAssertEqual(bundle.road(atPlaybackTime: 10.1)?.reason, "future")
        var delayed = bundle
        var road = RoadLineObservation.unavailable(at: 10, reason: "delayed")
        road.availableAt = 10.3
        delayed.roadObservations = [road]
        XCTAssertNil(delayed.road(atPlaybackTime: 10.2))
        XCTAssertEqual(delayed.road(atPlaybackTime: 10.3)?.reason, "delayed")
    }
}
