import XCTest

final class CornerReplayTests: XCTestCase {
    private func sample(_ time: Double, _ speed: Double? = 100,
                        confidence: Double = 0.9, reviewed: Bool = true) -> ReplaySpeedSample {
        ReplaySpeedSample(time: time, speedKPH: speed, confidence: confidence, reviewed: reviewed)
    }

    private func session(samples: [ReplaySpeedSample]? = nil, source: String = "player") -> ReplaySession {
        ReplaySession(sourceFileName: "\(source).mov", duration: 2,
                      metadata: ReplayMetadata(routeID: "route-1", cornerID: "corner-1",
                                               setupID: "car-camera-assists-1", sourceGroupID: source),
                      landmarks: [ReplayLandmark(id: "entry", time: 0), ReplayLandmark(id: "exit", time: 2)],
                      samples: samples ?? [sample(0), sample(0.5), sample(1), sample(1.5), sample(2)])
    }

    private func compare(_ player: ReplaySession, _ reference: ReplaySession? = nil) -> ReplayReport {
        ReplayEvaluator.evaluate(player: player, reference: reference ?? session(source: "reference"))
    }

    private func assertInvalid(_ invalid: ReplaySession, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try invalid.validate(), file: file, line: line)
        for report in [compare(invalid), compare(session(), invalid)] {
            XCTAssertEqual(report.summary.comparableCount, 0, file: file, line: line)
            XCTAssertNil(report.summary.meanAbsoluteSpeedGapKPH, file: file, line: line)
            XCTAssertTrue(report.rows.allSatisfy { $0.status == .withheld && $0.deltaKPH == nil },
                          file: file, line: line)
        }
    }

    func testValidSessionAndReportJSONRoundTrip() throws {
        let original = session(samples: [sample(0), sample(0.5, nil), sample(1, 120, reviewed: false)])
        let decoded = try JSONDecoder().decode(ReplaySession.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        let report = compare(original)
        XCTAssertEqual(try JSONDecoder().decode(ReplayReport.self, from: JSONEncoder().encode(report)), report)
    }

    func testDraftDefaultsAreEditableButCannotImportUntilValid() throws {
        var draft = ReplaySession()
        XCTAssertEqual(draft.schemaVersion, 1)
        XCTAssertEqual(draft.metadata, .empty)
        XCTAssertTrue(draft.landmarks.isEmpty)
        XCTAssertTrue(draft.samples.isEmpty)
        XCTAssertThrowsError(try draft.validate())
        XCTAssertThrowsError(try JSONDecoder().decode(ReplaySession.self, from: JSONEncoder().encode(draft)))
        draft.sourceFileName = "draft.mov"
        draft.duration = 1
        draft.metadata = session().metadata
        XCTAssertNoThrow(try draft.validate())
        let report = compare(draft)
        XCTAssertEqual(report.summary.totalCount, 0)
        XCTAssertTrue(report.notes.contains { $0.contains("two matching landmarks") })
    }

    func testUnsupportedSchemaRejectedInMemoryAndOnImport() throws {
        for version in [0, 2, -1, Int.max] {
            var invalid = session()
            invalid.schemaVersion = version
            assertInvalid(invalid)
            XCTAssertThrowsError(try JSONDecoder().decode(ReplaySession.self, from: JSONEncoder().encode(invalid)))
        }
    }

    func testMissingFieldsAndWrongJSONTypesAreRejected() throws {
        let valid = try JSONEncoder().encode(session())
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        for key in ["schemaVersion", "sourceFileName", "duration", "metadata", "landmarks", "samples"] {
            var missing = original
            missing.removeValue(forKey: key)
            XCTAssertThrowsError(try JSONDecoder().decode(ReplaySession.self,
                                                         from: JSONSerialization.data(withJSONObject: missing)), key)
            var wrongType = original
            wrongType[key] = NSNull()
            XCTAssertThrowsError(try JSONDecoder().decode(ReplaySession.self,
                                                         from: JSONSerialization.data(withJSONObject: wrongType)), key)
        }
    }

    func testNonFiniteJSONImportsRejectedEvenWithPermissiveNumberDecoder() throws {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity",
                                                                      negativeInfinity: "-Infinity", nan: "NaN")
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity",
                                                                        negativeInfinity: "-Infinity", nan: "NaN")
        for value in [Double.nan, .infinity, -.infinity] {
            var invalids: [ReplaySession] = []
            var duration = session(); duration.duration = value; invalids.append(duration)
            var time = session(); time.samples[0].time = value; invalids.append(time)
            var speed = session(); speed.samples[0].speedKPH = value; invalids.append(speed)
            var confidence = session(); confidence.samples[0].confidence = value; invalids.append(confidence)
            var landmark = session(); landmark.landmarks[0].time = value; invalids.append(landmark)
            for invalid in invalids {
                XCTAssertThrowsError(try decoder.decode(ReplaySession.self, from: encoder.encode(invalid)))
                assertInvalid(invalid)
                // Even invalid in-memory timestamps produce an exportable, withheld report.
                XCTAssertNoThrow(try JSONEncoder().encode(compare(invalid)))
            }
        }
    }

    func testInvalidDurationsRejected() {
        for duration in [0, -1, Double.nan, .infinity, -.infinity] {
            var invalid = session(); invalid.duration = duration
            assertInvalid(invalid)
        }
    }

    func testBlankMetadataAndFileNamesRejected() {
        for blank in ["", " ", "\n\t"] {
            var invalid = session(); invalid.sourceFileName = blank; assertInvalid(invalid)
            invalid = session(); invalid.metadata.routeID = blank; assertInvalid(invalid)
            invalid = session(); invalid.metadata.cornerID = blank; assertInvalid(invalid)
            invalid = session(); invalid.metadata.setupID = blank; assertInvalid(invalid)
            invalid = session(); invalid.metadata.sourceGroupID = blank; assertInvalid(invalid)
        }
    }

    func testInvalidSampleValuesRejected() {
        for time in [-0.001, 2.001, Double.nan, .infinity, -.infinity] {
            var invalid = session(); invalid.samples = [sample(time)]
            assertInvalid(invalid)
        }
        for speed in [-0.001, 500.001, Double.nan, .infinity, -.infinity] {
            var invalid = session(); invalid.samples = [sample(1, speed)]
            assertInvalid(invalid)
        }
        for confidence in [-0.001, 1.001, Double.nan, .infinity, -.infinity] {
            var invalid = session(); invalid.samples = [sample(1, confidence: confidence)]
            assertInvalid(invalid)
        }
    }

    func testValidZeroSpeedAndMaximumSpeedArePreserved() throws {
        let player = session(samples: [sample(0, 0, confidence: 0.8), sample(2, 500, confidence: 1)])
        try player.validate()
        let report = compare(player, session(samples: [sample(0, 0), sample(2, 500)], source: "reference"))
        XCTAssertEqual(report.summary.comparableCount, 2)
        XCTAssertEqual(report.rows.map(\.playerKPH), [0, 500])
        XCTAssertEqual(report.summary.meanAbsoluteSpeedGapKPH, 0)
    }

    func testDuplicateOrReversedSamplesRejectedWithoutSortingThem() {
        for samples in [[sample(1), sample(1)], [sample(1), sample(0.5)]] {
            let invalid = session(samples: samples)
            assertInvalid(invalid)
            XCTAssertEqual(invalid.samples, samples)
        }
    }

    func testInvalidLandmarksRejected() {
        let invalidLists: [[ReplayLandmark]] = [
            [.init(id: "", time: 0), .init(id: "end", time: 2)],
            [.init(id: " \n", time: 0), .init(id: "end", time: 2)],
            [.init(id: "same", time: 0), .init(id: "same", time: 2)],
            [.init(id: "start", time: 1), .init(id: "end", time: 1)],
            [.init(id: "start", time: 2), .init(id: "end", time: 1)],
            [.init(id: "start", time: -0.1), .init(id: "end", time: 2)],
            [.init(id: "start", time: 0), .init(id: "end", time: 2.1)],
            [.init(id: "start", time: .nan), .init(id: "end", time: 2)]
        ]
        for landmarks in invalidLists {
            var invalid = session(); invalid.landmarks = landmarks
            assertInvalid(invalid)
        }
    }

    func testMetadataMismatchWithholdsEveryRow() {
        for field in [0, 1, 2] {
            var reference = session(source: "reference")
            if field == 0 { reference.metadata.routeID += "-different" }
            if field == 1 { reference.metadata.cornerID += "-different" }
            if field == 2 { reference.metadata.setupID += "-different" }
            let report = compare(session(), reference)
            XCTAssertEqual(report.summary.totalCount, 5)
            XCTAssertEqual(report.summary.comparableCount, 0)
            XCTAssertTrue(report.rows.allSatisfy { $0.status == .withheld && $0.referenceTime == nil })
        }
    }

    func testSameSourceGroupWarnsWithoutClaimingIndependentValidation() {
        let report = compare(session(), session())
        XCTAssertEqual(report.summary.comparableCount, 5)
        XCTAssertTrue(report.notes.contains { $0.contains("not independent validation") })
        XCTAssertFalse(compare(session()).notes.contains { $0.contains("not independent validation") })
    }

    func testAtLeastTwoExactOrderedLandmarkNamesAreRequired() {
        let lists: [[ReplayLandmark]] = [[], [.init(id: "entry", time: 0)],
            [.init(id: "entry", time: 0), .init(id: "other", time: 2)],
            [.init(id: "exit", time: 0), .init(id: "entry", time: 2)],
            [.init(id: "entry", time: 0), .init(id: "apex", time: 1), .init(id: "exit", time: 2)]]
        for landmarks in lists {
            var reference = session(source: "reference"); reference.landmarks = landmarks
            XCTAssertNoThrow(try reference.validate())
            let report = compare(session(), reference)
            XCTAssertEqual(report.summary.comparableCount, 0)
            XCTAssertTrue(report.rows.allSatisfy { $0.status == .withheld })
        }
    }

    func testPiecewiseAlignmentHonorsIntermediateLandmarksAndEndpoints() throws {
        var player = session(samples: [sample(0), sample(0.5), sample(1), sample(1.5), sample(2)])
        player.landmarks = [.init(id: "entry", time: 0), .init(id: "apex", time: 1), .init(id: "exit", time: 2)]
        var reference = session(samples: [sample(0), sample(0.25), sample(0.5), sample(1), sample(1.25), sample(1.5), sample(2)], source: "reference")
        reference.landmarks = [.init(id: "entry", time: 0), .init(id: "apex", time: 0.5), .init(id: "exit", time: 2)]
        let report = compare(player, reference)
        XCTAssertEqual(report.summary.comparableCount, 5)
        XCTAssertEqual(report.rows.map(\.referenceTime), [0, 0.25, 0.5, 1.25, 2])
    }

    func testNoAlignmentExtrapolationBeforeOrAfterLandmarks() {
        var player = session()
        player.landmarks = [.init(id: "entry", time: 0.5), .init(id: "exit", time: 1.5)]
        let report = compare(player)
        XCTAssertEqual(report.rows.first?.status, .withheld)
        XCTAssertEqual(report.rows.last?.status, .withheld)
        XCTAssertNil(report.rows.first?.referenceTime)
        XCTAssertNil(report.rows.last?.referenceTime)
        XCTAssertEqual(report.summary.comparableCount, 3)
    }

    func testInterpolationProducesCorrectReferenceValueAndSignedGap() throws {
        let reference = session(samples: [sample(0, 80), sample(0.4, 120)], source: "reference")
        let report = compare(session(samples: [sample(0.2, 125)]), reference)
        let row = try XCTUnwrap(report.rows.first)
        XCTAssertEqual(try XCTUnwrap(row.referenceKPH), 100, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(row.deltaKPH), 25, accuracy: 0.000001)
        XCTAssertEqual(row.status, .aboveReference)
    }

    func testComparisonBandBoundariesAreInclusiveAndNeverCommands() {
        let speeds: [Double] = [89.99, 90, 100, 110, 110.01]
        let times: [Double] = [0, 0.5, 1, 1.5, 2]
        let report = compare(session(samples: zip(times, speeds).map { sample($0.0, $0.1) }))
        XCTAssertEqual(report.rows.map(\.status), [.belowReference, .nearReference, .nearReference, .nearReference, .aboveReference])
        XCTAssertTrue(report.rows[0].reason.contains("not an acceleration instruction"))
        XCTAssertTrue(report.rows[4].reason.contains("not a braking instruction"))
        XCTAssertTrue(report.notes.contains { $0.contains("no causal or live driving guidance") })
        XCTAssertTrue(report.notes.contains { $0.contains("alignment is approximate") })
    }

    func testConfidenceThresholdAndReviewGateForBothRecordings() {
        for bad in [sample(1, nil), sample(1, confidence: 0.7999), sample(1, reviewed: false)] {
            XCTAssertEqual(compare(session(samples: [bad])).rows[0].status, .withheld)
            XCTAssertEqual(compare(session(samples: [sample(1)]), session(samples: [bad], source: "reference")).rows[0].status, .withheld)
        }
        XCTAssertEqual(compare(session(samples: [sample(1, confidence: 0.8)]),
                               session(samples: [sample(1, confidence: 0.8)], source: "reference")).summary.comparableCount, 1)
    }

    func testInterpolationGapLimitAndExactSampleException() {
        let player = session(samples: [sample(0.3)])
        XCTAssertEqual(compare(player, session(samples: [sample(0), sample(0.6)], source: "reference")).summary.comparableCount, 1)
        XCTAssertEqual(compare(player, session(samples: [sample(0), sample(0.601)], source: "reference")).summary.comparableCount, 0)
        // An exact observed value needs no interpolation even if surrounding data are sparse.
        XCTAssertEqual(compare(player, session(samples: [sample(0), sample(0.3), sample(2)], source: "reference")).summary.comparableCount, 1)
    }

    func testInterpolationNeverSkipsRejectedIntermediateSamples() {
        for rejected in [sample(0.2, nil), sample(0.2, reviewed: false), sample(0.2, confidence: 0.2)] {
            let reference = session(samples: [sample(0), rejected, sample(0.4)], source: "reference")
            let report = compare(session(samples: [sample(0.1), sample(0.2), sample(0.3)]), reference)
            XCTAssertEqual(report.summary.comparableCount, 0)
            XCTAssertTrue(report.rows.allSatisfy { $0.status == .withheld && $0.referenceKPH == nil })
        }
    }

    func testReferenceSamplesAreNeverExtrapolated() {
        let report = compare(session(samples: [sample(0), sample(1), sample(2)]),
                             session(samples: [sample(0.5), sample(1), sample(1.5)], source: "reference"))
        XCTAssertEqual(report.rows.map(\.status), [.withheld, .nearReference, .withheld])
    }

    func testEmptyAndSingleSampleReferencesAreHandled() {
        let player = session(samples: [sample(0.5), sample(1), sample(1.5)])
        XCTAssertEqual(compare(player, session(samples: [], source: "reference")).summary.comparableCount, 0)
        let one = compare(player, session(samples: [sample(1)], source: "reference"))
        XCTAssertEqual(one.rows.map(\.status), [.withheld, .nearReference, .withheld])
        let none = compare(session(samples: []))
        XCTAssertEqual(none.summary.totalCount, 0)
        XCTAssertNil(none.summary.meanAbsoluteSpeedGapKPH)
    }

    func testSummaryUsesOnlyComparableRowsAndAbsoluteGaps() throws {
        let report = compare(session(samples: [sample(0, 120), sample(0.5, nil), sample(1, 70), sample(1.5, 100, reviewed: false)]))
        XCTAssertEqual(report.summary.totalCount, 4)
        XCTAssertEqual(report.summary.comparableCount, 2)
        XCTAssertEqual(try XCTUnwrap(report.summary.meanAbsoluteSpeedGapKPH), 25, accuracy: 0.000001)
        XCTAssertEqual(report.rows.compactMap(\.deltaKPH), [20, -30])
    }

    func testInvalidFiniteImportedValuesCannotSneakThroughCodable() throws {
        var invalids: [ReplaySession] = []
        var duplicate = session(); duplicate.samples[1].time = duplicate.samples[0].time; invalids.append(duplicate)
        var badSpeed = session(); badSpeed.samples[0].speedKPH = -1; invalids.append(badSpeed)
        var badConfidence = session(); badConfidence.samples[0].confidence = 2; invalids.append(badConfidence)
        var badLandmark = session(); badLandmark.landmarks[1].id = "entry"; invalids.append(badLandmark)
        for invalid in invalids {
            XCTAssertThrowsError(try JSONDecoder().decode(ReplaySession.self, from: JSONEncoder().encode(invalid)))
        }
    }
}
