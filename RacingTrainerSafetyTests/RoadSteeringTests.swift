import CoreVideo
import XCTest

/// Road-paint detection and the illustrative steering-wheel animation.
final class RoadSteeringTests: XCTestCase {
    // MARK: Synthetic road frames

    private typealias RGB = (r: UInt8, g: UInt8, b: UInt8)
    private static let asphalt: RGB = (108, 106, 104)
    private static let grass: RGB = (88, 128, 52)
    private static let yellowPaint: RGB = (226, 196, 92)
    private static let whitePaint: RGB = (226, 226, 222)

    /// Lines converge on (0.5, 0.40). Left boundary: yellow centre line.
    /// Right boundary: white edge line. Grass lies beyond the white line.
    private static func leftLine(_ y: Double) -> Double { 0.5 - 0.95 * (y - 0.40) }
    private static func rightLine(_ y: Double) -> Double { 0.5 + 1.15 * (y - 0.40) }

    private func frame(width: Int = 960, height: Int = 540,
                       pixel: (_ x: Double, _ y: Double) -> RGB) -> CVPixelBuffer {
        var result: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &result)
        let buffer = result!
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let color = pixel(Double(x) / Double(width), Double(y) / Double(height))
                let i = y * stride + x * 4
                bytes[i] = color.b; bytes[i+1] = color.g; bytes[i+2] = color.r; bytes[i+3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func laneFrame(yellow: Bool = true, white: Bool = true) -> CVPixelBuffer {
        frame { x, y in
            guard y >= 0.40 else { return (150, 170, 200) }
            let half = 0.002 + 0.012 * (y - 0.40)
            if yellow && abs(x - Self.leftLine(y)) < half { return Self.yellowPaint }
            if white && abs(x - Self.rightLine(y)) < half { return Self.whitePaint }
            // Dark car body in the middle, as in the chase camera.
            if y > 0.47 && abs(x - 0.5) < 0.13 { return (20, 18, 20) }
            return x > Self.rightLine(y) + half ? Self.grass : Self.asphalt
        }
    }

    func testFindsYellowCentreAndWhiteEdgeAsLaneBoundaries() {
        let road = RoadLineDetector().analyze(laneFrame(), at: 5, camera: .chase)
        XCTAssertTrue(road.hasCorridor, road.reason)
        XCTAssertEqual(road.roadDirection, "straight")
        for point in road.left { XCTAssertEqual(point.x, Self.leftLine(point.y), accuracy: 0.012) }
        for point in road.right { XCTAssertEqual(point.x, Self.rightLine(point.y), accuracy: 0.012) }
        let colors = Set((road.markings ?? []).map(\.color))
        XCTAssertEqual(colors, [.yellow, .white])
    }

    func testSingleBoundaryNeverBecomesACorridor() {
        let road = RoadLineDetector().analyze(laneFrame(white: false), at: 5, camera: .chase)
        XCTAssertFalse(road.hasCorridor)
        XCTAssertTrue(road.hasBoundary, road.reason)
        XCTAssertEqual(road.currentBendDirection, "unknown")
        XCTAssertFalse(road.left.isEmpty)
    }

    func testFoliageHighlightsAreNotPaint() {
        // Bright, nearly white glints scattered over vegetation.
        let foliage = frame { x, y in
            let glint = (Int(x * 960) * 7 + Int(y * 540) * 13) % 23 == 0
            return glint ? (232, 236, 226) : Self.grass
        }
        let road = RoadLineDetector().analyze(foliage, at: 5, camera: .chase)
        XCTAssertFalse(road.hasBoundary, road.reason)
        XCTAssertTrue((road.markings ?? []).isEmpty)
    }

    func testSunPatchesOnAsphaltDoNotFormALane() {
        // Wide, irregular light patches, like sun through trees.
        let dappled = frame { x, y in
            guard y >= 0.40 else { return (150, 170, 200) }
            let u = sin(x * 41 + y * 17) + sin(x * 23 - y * 37)
            return u > 1.2 ? (205, 200, 192) : Self.asphalt
        }
        let road = RoadLineDetector().analyze(dappled, at: 5, camera: .chase)
        XCTAssertFalse(road.hasCorridor, road.reason)
    }

    func testPaintUnderHUDDialsAndCarIsIgnored() {
        // White paint drawn only where the speedometer, minimap and car are.
        let hidden = frame { x, y in
            let inDial = { (cx: Double, cy: Double) in hypot((x - cx) * 16 / 9, y - cy) < 0.15 }
            let underCar = y > 0.50 && abs(x - 0.5) < 0.15
            let stripe = abs(x.truncatingRemainder(dividingBy: 0.05) - 0.025) < 0.004
            return stripe && (inDial(0.112, 0.815) || inDial(0.894, 0.800) || underCar)
                ? Self.whitePaint : Self.asphalt
        }
        XCTAssertTrue((RoadLineDetector().analyze(hidden, at: 5, camera: .chase).markings ?? []).isEmpty)
    }

    func testObservationsWithoutMarkingsStillDecode() throws {
        let legacy = #"{"capturedAt":1,"left":[],"right":[],"confidence":0,"reason":"old"}"#
        let decoded = try JSONDecoder().decode(RoadLineObservation.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.markings)
    }

    // MARK: Wheel target

    private func cue(_ stage: TurnGuidanceStage, _ direction: String, maneuver: String? = nil,
                     at time: Double = 10) -> LiveTurnGuidanceSnapshot {
        LiveTurnGuidanceSnapshot(cue: TurnGuidanceSample(time: time, stage: stage, direction: direction,
            reason: "fixture", currentManeuver: maneuver), sourceFrameUptime: time, expiresAt: time + 0.5,
            sourceSessionID: 1)
    }

    func testWheelRestatesTheConfirmedCueWithoutFollowingPixelNoise() {
        XCTAssertEqual(SteeringWheelTarget.degrees(turn: cue(.straight, "straight"), at: 10.1), 0)
        for stage in [TurnGuidanceStage.headsUp, .preview] {
            XCTAssertEqual(SteeringWheelTarget.degrees(turn: cue(stage, "left"), at: 10.1), 0)
        }
        for side in ["left", "right"] {
            let sign = side == "left" ? -1.0 : 1.0
            for frame in 0..<60 {
                let time = 10 + Double(frame) / 30
                XCTAssertEqual(SteeringWheelTarget.degrees(
                    turn: cue(.following, side, maneuver: "bend", at: time), at: time + 0.01), sign * 45)
            }
            XCTAssertEqual(SteeringWheelTarget.degrees(turn: cue(.turnNow, side), at: 10.1), sign * 120)
            XCTAssertEqual(SteeringWheelTarget.degrees(turn: cue(.following, side, maneuver: "turn"), at: 10.1), sign * 120)
        }
    }

    func testWheelRejectsUnavailableExpiredFutureOrInvalidDirection() {
        XCTAssertNil(SteeringWheelTarget.degrees(turn: cue(.unavailable, "unknown"), at: 10.1))
        XCTAssertNil(SteeringWheelTarget.degrees(turn: cue(.turnNow, "right"), at: 11))
        XCTAssertNil(SteeringWheelTarget.degrees(turn: cue(.following, "left"), at: 9))
        XCTAssertNil(SteeringWheelTarget.degrees(turn: cue(.following, "unknown"), at: 10.1))
        XCTAssertNil(SteeringWheelTarget.degrees(turn: cue(.following, "right"), at: .nan))
    }

    // MARK: Wheel motion

    private func run(_ motion: SteeringWheelMotion, toward target: Double?, from start: Double,
                     seconds: Double) -> [Double] {
        stride(from: start, to: start + seconds, by: 1.0 / 60).map {
            motion.advance(toward: target, at: $0, reduceMotion: false)
        }
    }

    func testWheelEasesToTargetWithoutSnappingOrOvershootingMuch() {
        let motion = SteeringWheelMotion()
        _ = motion.advance(toward: 0, at: 0, reduceMotion: false)
        let angles = run(motion, toward: 90, from: 1.0 / 60, seconds: 1.2)
        XCTAssertLessThan(angles[0], 5, "First frame must not jump")
        let steps = zip(angles, angles.dropFirst()).map { abs($1 - $0) }
        XCTAssertLessThanOrEqual(steps.max()!, SteeringWheelMotion.maximumSpeed / 60 + 0.001)
        XCTAssertEqual(angles.last!, 90, accuracy: 1)
        XCTAssertLessThan(angles.max()!, 92)
        // Reaches most of the way within half a second.
        XCTAssertGreaterThan(angles[29], 70)
    }

    func testWheelHoldsThroughBriefDropoutThenRecentres() {
        let motion = SteeringWheelMotion()
        _ = run(motion, toward: -60, from: 0, seconds: 1.5)
        let held = run(motion, toward: nil, from: 1.5, seconds: SteeringWheelMotion.holdAfterDropout - 0.05)
        XCTAssertEqual(held.last!, -60, accuracy: 1)
        let released = run(motion, toward: nil, from: 1.5 + SteeringWheelMotion.holdAfterDropout, seconds: 1.5)
        XCTAssertEqual(released.last!, 0, accuracy: 1)
    }

    func testReduceMotionMovesDirectlyAndLongGapsDoNotJump() {
        let motion = SteeringWheelMotion()
        XCTAssertEqual(motion.advance(toward: 45, at: 0, reduceMotion: true), 45)
        let animated = SteeringWheelMotion()
        _ = animated.advance(toward: 0, at: 0, reduceMotion: false)
        // A 10-second pause (window hidden) is treated as one short frame.
        XCTAssertLessThan(animated.advance(toward: 120, at: 10, reduceMotion: false), 25)
    }
    func testDropoutFreezesMidTurnAndReacquisitionDoesNotSnap() {
        let motion = SteeringWheelMotion()
        _ = run(motion, toward: 120, from: 0, seconds: 0.2)
        let frozen = motion.angle
        XCTAssertGreaterThan(frozen, 0)
        XCTAssertLessThan(frozen, 120)
        let held = run(motion, toward: nil, from: 0.2, seconds: 0.3)
        XCTAssertTrue(held.allSatisfy { $0 == frozen }, "Lost evidence must stop turning further")
        let resumed = motion.advance(toward: 120, at: 0.5, reduceMotion: false)
        XCTAssertGreaterThan(resumed, frozen)
        XCTAssertLessThan(resumed - frozen, 7)
    }

    func testSourceResetClearsPriorAngleAndDropoutHold() {
        let motion = SteeringWheelMotion()
        XCTAssertEqual(motion.advance(toward: 120, at: 0, reduceMotion: true, session: 1), 120)
        XCTAssertEqual(motion.advance(toward: nil, at: 1, reduceMotion: false, session: 2), 0)
        XCTAssertEqual(motion.advance(toward: -45, at: 2, reduceMotion: false, session: 3), 0)
        XCTAssertLessThan(motion.advance(toward: -45, at: 2.02, reduceMotion: false, session: 3), 0)
    }

    func testDuplicateBackwardAndNonFiniteTicksDoNotAdvanceMotion() {
        let motion = SteeringWheelMotion()
        _ = motion.advance(toward: 90, at: 1, reduceMotion: false)
        let angle = motion.advance(toward: 90, at: 1.02, reduceMotion: false)
        for time in [1.02, 0.5, .nan, .infinity] {
            XCTAssertEqual(motion.advance(toward: -90, at: time, reduceMotion: false), angle)
        }
        XCTAssertTrue(motion.advance(toward: .nan, at: 1.04, reduceMotion: false).isFinite)
    }

    func testMotionIsConsistentAcrossDisplayRatesAndCanReverseSmoothly() {
        func angle(fps: Int) -> Double {
            let motion = SteeringWheelMotion()
            for frame in 0...fps / 2 {
                _ = motion.advance(toward: 90, at: Double(frame) / Double(fps), reduceMotion: false)
            }
            return motion.angle
        }
        XCTAssertEqual(angle(fps: 30), angle(fps: 60), accuracy: 0.001)
        XCTAssertEqual(angle(fps: 60), angle(fps: 120), accuracy: 0.001)
        let motion = SteeringWheelMotion()
        _ = run(motion, toward: 120, from: 0, seconds: 1.5)
        let reversed = run(motion, toward: -120, from: 1.5, seconds: 1.5)
        XCTAssertEqual(reversed.last!, -120, accuracy: 1)
        XCTAssertTrue(zip(reversed, reversed.dropFirst()).allSatisfy { abs($1 - $0) <= 7.001 })
        XCTAssertGreaterThanOrEqual(reversed.min()!, -120.01)
    }

}
