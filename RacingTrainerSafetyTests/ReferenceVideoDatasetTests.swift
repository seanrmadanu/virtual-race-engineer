import XCTest

final class ReferenceVideoDatasetTests: XCTestCase {
    private func dataset() -> ReferenceVideoDataset {
        ReferenceVideoDataset(
            sourceFileName: "reference.mp4", duration: 120, sourceSpeedUnit: "kmh",
            rangeStart: 10, rangeEnd: 20,
            samples: [ReplaySpeedSample(time: 10, speedKPH: 96, confidence: 0.8),
                      ReplaySpeedSample(time: 10.2)]
        )
    }

    private func assertInvalid(_ invalid: ReferenceVideoDataset,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try invalid.validate(), file: file, line: line)
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        XCTAssertThrowsError(try decoder.decode(ReferenceVideoDataset.self, from: encoder.encode(invalid)),
                            file: file, line: line)
    }

    func testReferenceWithoutPlayerOrRouteMetadataRoundTrips() throws {
        let original = dataset()
        XCTAssertNoThrow(try original.validate())
        XCTAssertNil(original.sourceSHA256)
        XCTAssertNil(original.sourceGroupID)
        let data = try JSONEncoder().encode(original)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["player"])
        XCTAssertNil(json["metadata"])
        XCTAssertNil(json["routeID"])
        XCTAssertEqual(try JSONDecoder().decode(ReferenceVideoDataset.self, from: data), original)
    }

    func testMissingSpeedAndHumanReviewStatusSurviveExport() throws {
        var original = dataset()
        original.samples.append(ReplaySpeedSample(time: 10.4, speedKPH: 101, confidence: 1, reviewed: true))
        original.samples.append(ReplaySpeedSample(time: 10.6, reviewed: true))
        let decoded = try JSONDecoder().decode(ReferenceVideoDataset.self,
                                               from: JSONEncoder().encode(original))
        XCTAssertFalse(decoded.samples[0].reviewed)
        XCTAssertFalse(decoded.samples[1].reviewed)
        XCTAssertNil(decoded.samples[1].speedKPH)
        XCTAssertTrue(decoded.samples[2].reviewed)
        XCTAssertEqual(decoded.samples[2].speedKPH, 101)
        XCTAssertTrue(decoded.samples[3].reviewed)
        XCTAssertNil(decoded.samples[3].speedKPH)
    }

    func testSourceUnitsMustBeExplicitAndKnown() {
        for unit in ["", " ", "kph", "MPH", "unknown", "auto"] {
            var invalid = dataset()
            invalid.sourceSpeedUnit = unit
            assertInvalid(invalid)
        }
        var mph = dataset()
        mph.sourceSpeedUnit = "mph"
        XCTAssertNoThrow(try mph.validate())
    }

    func testUnsupportedSchemaIsRejected() {
        for version in [-1, 0, 2, Int.max] {
            var invalid = dataset()
            invalid.schemaVersion = version
            assertInvalid(invalid)
        }
    }

    func testOptionalSHA256IsValidatedWhenPresent() throws {
        var original = dataset()
        original.sourceSHA256 = String(repeating: "a", count: 64)
        original.sourceGroupID = "sha256:" + original.sourceSHA256!
        XCTAssertNoThrow(try original.validate())
        XCTAssertEqual(try JSONDecoder().decode(ReferenceVideoDataset.self,
                                                from: JSONEncoder().encode(original)), original)
        for hash in ["", "a", String(repeating: "a", count: 63),
                     String(repeating: "a", count: 65), String(repeating: "z", count: 64)] {
            var invalid = dataset()
            invalid.sourceSHA256 = hash
            assertInvalid(invalid)
        }
        var blankGroup = dataset()
        blankGroup.sourceGroupID = " \n"
        assertInvalid(blankGroup)
    }

    func testInvalidRangesAndRatesAreRejected() {
        for (start, end) in [(-1.0, 20.0), (20, 20), (21, 20), (10, 121), (.nan, 20), (10, .infinity)] {
            var invalid = dataset()
            invalid.rangeStart = start
            invalid.rangeEnd = end
            assertInvalid(invalid)
        }
        for rate in [0.0, -1, 5.01, .nan, .infinity] {
            var invalid = dataset()
            invalid.samplingHz = rate
            assertInvalid(invalid)
        }
        for duration in [0.0, -1, 19, .nan, .infinity] {
            var invalid = dataset()
            invalid.duration = duration
            assertInvalid(invalid)
        }
    }

    func testSampleTimeOrderAndNumericValuesAreValidated() {
        for time in [9.9, 20.1, .nan, .infinity] {
            var invalid = dataset()
            invalid.samples[0].time = time
            assertInvalid(invalid)
        }
        var duplicate = dataset()
        duplicate.samples[1].time = duplicate.samples[0].time
        assertInvalid(duplicate)
        var reverse = dataset()
        reverse.samples.reverse()
        assertInvalid(reverse)
        for confidence in [-0.01, 1.01, .nan, .infinity] {
            var invalid = dataset()
            invalid.samples[0].confidence = confidence
            assertInvalid(invalid)
        }
        for speed in [-0.01, 500.01, .nan, .infinity] {
            var invalid = dataset()
            invalid.samples[0].speedKPH = speed
            assertInvalid(invalid)
        }
    }

    func testRequiredIdentityAndExtractionFieldsAreValidated() throws {
        var blankName = dataset()
        blankName.sourceFileName = " "
        assertInvalid(blankName)
        var blankVersion = dataset()
        blankVersion.extractionVersion = "\n"
        assertInvalid(blankVersion)
        let encoded = try JSONEncoder().encode(dataset())
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["schemaVersion", "extractionVersion", "sourceFileName", "duration", "sourceSpeedUnit",
                    "samplingHz", "rangeStart", "rangeEnd", "samples"] {
            var missing = original
            missing.removeValue(forKey: key)
            XCTAssertThrowsError(try JSONDecoder().decode(ReferenceVideoDataset.self,
                                     from: JSONSerialization.data(withJSONObject: missing)), key)
        }
    }
}
