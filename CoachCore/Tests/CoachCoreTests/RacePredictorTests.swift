import XCTest
@testable import CoachCore

final class RacePredictorTests: XCTestCase {
    func testSameDistanceReturnsSameTime() throws {
        let t = try XCTUnwrap(RacePredictor.riegel(knownMeters: Distance.tenK, knownSeconds: 3000, targetMeters: Distance.tenK))
        XCTAssertEqual(t, 3000, accuracy: 0.001)
    }

    func testTenKToTenMiles() throws {
        // Synthetic runner: 10K in 50:00 (3000 s) -> 10 miles with k = 1.07.
        // Worked out independently: 3000 * 1.609344^1.07 = 4991.55 s (1:23:12).
        let t = try XCTUnwrap(RacePredictor.riegel(knownMeters: Distance.tenK, knownSeconds: 3000, targetMeters: Distance.tenMiles))
        XCTAssertEqual(t, 4991.55, accuracy: 0.01)
    }

    func testLongerRaceIsSlowerPerMeter() throws {
        let short = try XCTUnwrap(RacePredictor.riegel(knownMeters: Distance.fiveK, knownSeconds: 1500, targetMeters: Distance.fiveK))
        let long = try XCTUnwrap(RacePredictor.riegel(knownMeters: Distance.fiveK, knownSeconds: 1500, targetMeters: Distance.halfMarathon))
        XCTAssertGreaterThan(long / Distance.halfMarathon, short / Distance.fiveK)
    }

    func testRejectsNonPositiveInputs() {
        XCTAssertNil(RacePredictor.riegel(knownMeters: 0, knownSeconds: 100, targetMeters: 5000))
        XCTAssertNil(RacePredictor.riegel(knownMeters: 5000, knownSeconds: -1, targetMeters: 5000))
        XCTAssertNil(RacePredictor.riegel(knownMeters: 5000, knownSeconds: 100, targetMeters: 0))
        XCTAssertNil(RacePredictor.riegel(knownMeters: 5000, knownSeconds: 0, targetMeters: 10000))
        XCTAssertNil(RacePredictor.riegel(knownMeters: -5000, knownSeconds: 100, targetMeters: 10000))
        XCTAssertNil(RacePredictor.riegel(knownMeters: 5000, knownSeconds: 100, targetMeters: -10000))
        XCTAssertNil(RacePredictor.riegel(knownMeters: 5000, knownSeconds: 100, targetMeters: 10000, exponent: 0))
        XCTAssertNil(RacePredictor.riegel(knownMeters: 5000, knownSeconds: 100, targetMeters: 10000, exponent: -1.07))
    }

    func testRejectsNonFiniteInputs() {
        XCTAssertNil(RacePredictor.riegel(knownMeters: .infinity, knownSeconds: 100, targetMeters: 10000))
        XCTAssertNil(RacePredictor.riegel(knownMeters: 5000, knownSeconds: .nan, targetMeters: 10000))
        XCTAssertNil(RacePredictor.riegel(knownMeters: 5000, knownSeconds: 100, targetMeters: .infinity))
    }
}
