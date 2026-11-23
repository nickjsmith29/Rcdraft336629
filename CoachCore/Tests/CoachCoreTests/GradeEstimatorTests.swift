import XCTest
@testable import CoachCore

final class GradeEstimatorTests: XCTestCase {
    /// Run `seconds` seconds at `speed` m/s on `grade`, one reading per second,
    /// from (time, distance, altitude) given; returns the end state and the estimates.
    private func run(_ e: inout GradeEstimator, from start: (t: Double, d: Double, a: Double), seconds: Int,
                     speed: Double = 3, grade: Double, noise: Double = 0, rng: inout SplitMix64)
        -> (end: (t: Double, d: Double, a: Double), estimates: [GradeEstimate?]) {
        var s = start
        var out: [GradeEstimate?] = []
        for _ in 0..<seconds {
            s.t += 1
            s.d += speed
            s.a += speed * grade
            out.append(e.ingest(time: s.t, distance: s.d, altitude: s.a + noise * rng.gaussian()))
        }
        return (s, out)
    }

    func testCleanSlopeIsRecoveredAfterEnoughRun() {
        var rng = SplitMix64(seed: 1)
        for grade in [0.05, -0.04, 0, 0.08, -0.12] {
            var e = GradeEstimator()
            let r = run(&e, from: (0, 0, 100), seconds: 60, grade: grade, rng: &rng)
            XCTAssertEqual(r.estimates.last??.grade ?? .nan, grade, accuracy: 1e-9, "grade \(grade)")
        }
    }

    func testNilUntilEnoughSpanAndSamples() {
        var rng = SplitMix64(seed: 1)
        var e = GradeEstimator()
        let r = run(&e, from: (0, 0, 0), seconds: 30, grade: 0.05, rng: &rng)
        // 3 m/s: 45 m span needs 15 s and the 8-sample minimum is met before that.
        XCTAssertNil(r.estimates[10])
        XCTAssertNotNil(r.estimates[20])
        XCTAssertEqual(r.estimates[20]!.spanMeters, 57, accuracy: 6)
    }

    func testMissingAltitudeGivesNilAndRecovers() {
        var rng = SplitMix64(seed: 1)
        var e = GradeEstimator()
        var s = run(&e, from: (0, 0, 0), seconds: 40, grade: 0.05, rng: &rng).end
        XCTAssertNotNil(e.estimate)
        // No altitude for 9 s: still held; at 11 s: nil.
        for i in 1...12 {
            s.t += 1; s.d += 3; s.a += 0.15
            let g = e.ingest(time: s.t, distance: s.d, altitude: nil)
            if i <= 9 { XCTAssertNotNil(g, "held at \(i) s") }
            if i >= 11 { XCTAssertNil(g, "stale at \(i) s") }
        }
        // It comes back once altitude returns (and there is a span again).
        let back = run(&e, from: s, seconds: 30, grade: 0.05, rng: &rng)
        XCTAssertEqual(back.estimates.last??.grade ?? .nan, 0.05, accuracy: 0.002)
    }

    func testNonFiniteValuesAreIgnored() {
        var e = GradeEstimator()
        XCTAssertNil(e.ingest(time: 1, distance: 3, altitude: .nan))
        XCTAssertNil(e.ingest(time: 2, distance: 6, altitude: .infinity))
        XCTAssertNil(e.ingest(time: .nan, distance: 9, altitude: 1))
        XCTAssertNil(e.ingest(time: 3, distance: .nan, altitude: 1))
        XCTAssertNil(e.estimate)
    }

    func testNoDistanceNoSlope() {
        var e = GradeEstimator()
        for t in 1...60 { XCTAssertNil(e.ingest(time: Double(t), distance: 100, altitude: Double(t % 3))) }
    }

    func testOutOfOrderTimesChangeNothing() {
        var rng = SplitMix64(seed: 1)
        var e = GradeEstimator()
        let r = run(&e, from: (0, 0, 0), seconds: 40, grade: 0.05, rng: &rng)
        let before = e.estimate
        XCTAssertEqual(e.ingest(time: 10, distance: 500, altitude: 9999), before)
        XCTAssertEqual(e.estimate, before)
        XCTAssertNotNil(r.end.t)
    }

    func testGradeIsClamped() {
        var rng = SplitMix64(seed: 1)
        var e = GradeEstimator()
        let r = run(&e, from: (0, 0, 0), seconds: 30, grade: 2.0, rng: &rng)
        XCTAssertEqual(r.estimates.last??.grade ?? .nan, 0.45, accuracy: 1e-12)
    }

    func testDistanceGoingBackwardsRestartsTheFit() {
        var rng = SplitMix64(seed: 1)
        var e = GradeEstimator()
        _ = run(&e, from: (0, 0, 0), seconds: 40, grade: 0.05, rng: &rng)
        // The old samples are gone after the restart: too few for a fit.
        XCTAssertNil(e.ingest(time: 41, distance: 0, altitude: 500))
    }

    /// With realistic noise (0.4 m white, 0.3 m drift is nearly constant over a
    /// window) the fitted grade on a steady 5% climb stays within 1.5 percentage points.
    func testNoiseDoesNotFlipTheSign() {
        var rng = SplitMix64(seed: 99)
        var worst = 0.0
        for _ in 0..<50 {
            var e = GradeEstimator()
            let r = run(&e, from: (0, 0, 0), seconds: 120, grade: 0.05, noise: 0.4, rng: &rng)
            for est in r.estimates.dropFirst(30) {
                worst = max(worst, abs((est?.grade ?? .nan) - 0.05))
            }
        }
        XCTAssertLessThan(worst, 0.015)
    }

    func testFollowsAHillChangeWithinTheWindow() {
        var rng = SplitMix64(seed: 1)
        var e = GradeEstimator()
        let up = run(&e, from: (0, 0, 0), seconds: 60, grade: 0.06, rng: &rng)
        let down = run(&e, from: up.end, seconds: 60, grade: -0.06, rng: &rng)
        // The window is 90 m: at 3 m/s a full turn takes 30 s; the sign flips in about half of that.
        XCTAssertGreaterThan(down.estimates[5]!.grade, 0)
        XCTAssertLessThan(down.estimates[20]!.grade, 0)
        XCTAssertEqual(down.estimates[40]!.grade, -0.06, accuracy: 1e-9)
    }

    func testResetForgetsEverything() {
        var rng = SplitMix64(seed: 1)
        var e = GradeEstimator()
        _ = run(&e, from: (0, 0, 0), seconds: 40, grade: 0.05, rng: &rng)
        e.reset()
        XCTAssertNil(e.estimate)
    }
}
