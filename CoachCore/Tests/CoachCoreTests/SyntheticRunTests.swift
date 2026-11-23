import XCTest
@testable import CoachCore

final class SyntheticRunTests: XCTestCase {
    private let mile = UnitFormatting.metersPerMile

    func testSplitMix64KnownSequence() {
        var g = SplitMix64(seed: 0)
        XCTAssertEqual(g.next(), 0xE220_A839_7B1D_CDAF)
        var a = SplitMix64(seed: 42), b = SplitMix64(seed: 42)
        for _ in 0..<10 { XCTAssertEqual(a.next(), b.next()) }
        var u = SplitMix64(seed: 7)
        for _ in 0..<1000 { let x = u.unit(); XCTAssertTrue(x >= 0 && x < 1) }
    }

    func testSameSeedGivesIdenticalReadings() {
        let a = SyntheticRun.hilly(basePaceSecondsPerMile: 540, hillSeconds: 120, hills: 6, grade: 0.05, seed: 11)
        let b = SyntheticRun.hilly(basePaceSecondsPerMile: 540, hillSeconds: 120, hills: 6, grade: 0.05, seed: 11)
        let c = SyntheticRun.hilly(basePaceSecondsPerMile: 540, hillSeconds: 120, hills: 6, grade: 0.05, seed: 12)
        XCTAssertEqual(a.readings, b.readings)
        XCTAssertEqual(a.truth, b.truth)
        XCTAssertEqual(a.mileEndTimes, b.mileEndTimes)
        XCTAssertNotEqual(a.readings, c.readings)
    }

    func testReadingsAreAboutOneHertzAndIncreasing() {
        let run = SyntheticRun.steady(secondsPerMile: 540, minutes: 10, seed: 3)
        XCTAssertEqual(run.readings.count, run.truth.count)
        XCTAssertEqual(Double(run.readings.count), 600, accuracy: 5)
        for (a, b) in zip(run.readings, run.readings.dropFirst()) { XCTAssertGreaterThan(b.time, a.time) }
        // Noise is present: GPS speeds are not all the true speed.
        let truthSpeed = run.truth[0].speed
        XCTAssertTrue(run.readings.compactMap(\.gpsSpeed).contains { abs($0 - truthSpeed) > 0.01 })
    }

    func testCleanRunHasExactTruthAndLaps() {
        let run = SyntheticRun(segments: [.atMilePace(480, duration: 1000), .atMilePace(360, duration: 1000)],
                               seed: 1, noise: .clean)
        // First 1000 s at 480 s/mile covers 2.083 miles; then 360 s/mile.
        XCTAssertEqual(run.lapPaces.count, 4)
        XCTAssertEqual(run.lapPaces[0], 480, accuracy: 1e-6)
        XCTAssertEqual(run.lapPaces[1], 480, accuracy: 1e-6)
        // Third lap: 0.0833 mi at 480 (40 s) then 0.9167 mi at 360 (330 s).
        XCTAssertEqual(run.lapPaces[2], 40 + 330, accuracy: 1e-6)
        XCTAssertEqual(run.lapPaces[3], 360, accuracy: 1e-6)
        let last = run.truth.last!
        XCTAssertEqual(last.distance, 1000 * mile / 480 + last.time.rounded(.down) * 0 + (last.time - 1000) * mile / 360, accuracy: 0.5)
        // Clean readings carry the truth exactly.
        for (r, t) in zip(run.readings, run.truth) {
            XCTAssertEqual(r.gpsSpeed!, t.speed, accuracy: 1e-9)
            XCTAssertEqual(r.watchSpeed!, t.speed, accuracy: 1e-9)
        }
    }

    func testStoppedSegmentAndInvalidSegments() {
        let run = SyntheticRun(segments: [.atMilePace(540, duration: 60), .stopped(duration: 30),
                                          SyntheticSegment(duration: -5, paceSecondsPerKm: 300),
                                          SyntheticSegment(duration: .nan, paceSecondsPerKm: 300),
                                          .atMilePace(540, duration: 60)], seed: 5, noise: .clean)
        XCTAssertEqual(run.segments.count, 3)
        XCTAssertEqual(run.duration, 150)
        let stopped = zip(run.readings, run.truth).filter { $0.1.time > 62 && $0.1.time < 88 }
        XCTAssertFalse(stopped.isEmpty)
        for (r, t) in stopped {
            XCTAssertEqual(t.speed, 0)
            XCTAssertNil(r.cadence)
        }
        // Distance does not grow while stopped.
        let d1 = run.truth.first { $0.time >= 65 }!.distance
        let d2 = run.truth.first { $0.time >= 85 }!.distance
        XCTAssertEqual(d1, d2, accuracy: 1e-9)
    }

    func testEmptyRun() {
        let run = SyntheticRun(segments: [], seed: 1)
        XCTAssertTrue(run.readings.isEmpty)
        XCTAssertTrue(run.lapPaces.isEmpty)
        XCTAssertEqual(run.duration, 0)
    }

    func testNoiseFeaturesAppear() {
        let run = SyntheticRun.hilly(basePaceSecondsPerMile: 540, hillSeconds: 150, hills: 14, grade: 0.05, seed: 2)
        XCTAssertTrue(run.readings.contains { $0.gpsSpeed == nil }, "dropouts")
        XCTAssertTrue(run.readings.contains { ($0.gpsAccuracy ?? 0) > 30 }, "bad-accuracy fixes")
        // Altitude follows the grade: net gain over an up segment.
        let alt = run.readings.compactMap(\.altitude)
        XCTAssertGreaterThan((alt.max() ?? 0) - (alt.min() ?? 0), 5)
    }

    func testChronologicalSortsAndDedupes() {
        let rs = [LiveReading(time: 3, gpsSpeed: 3), LiveReading(time: 1, gpsSpeed: 1), LiveReading(time: .nan),
                  LiveReading(time: 3, gpsSpeed: 9), LiveReading(time: 2, gpsSpeed: 2)]
        let out = LiveReading.chronological(rs)
        XCTAssertEqual(out.map(\.time), [1, 2, 3])
        XCTAssertEqual(out.last?.gpsSpeed, 3)
    }
}
