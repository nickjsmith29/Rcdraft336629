import XCTest
@testable import CoachCore

final class SyntheticCorrelatedNoiseTests: XCTestCase {
    private func gpsErrors(_ run: SyntheticRun, trueSpeed: Double) -> [Double] {
        run.readings.compactMap { r in
            guard let g = r.gpsSpeed, let a = r.gpsAccuracy, a < 20 else { return nil }
            return g - trueSpeed
        }
    }

    func testOffByDefaultAndDrawsNothing() {
        let n = SyntheticNoise()
        XCTAssertEqual(n.gpsCorrelatedSigma, 0)
        XCTAssertEqual(n.altitudeDriftSigma, 0)
        XCTAssertEqual(SyntheticNoise.forCueTests.gpsCorrelatedSigma, 0.06)
        XCTAssertEqual(SyntheticNoise.forCueTests.gpsCorrelationTime, 15)
        // Turning the AR(1) error on changes the readings; leaving it off is the pre-existing stream.
        let a = SyntheticRun.steady(secondsPerMile: 540, minutes: 5, seed: 9)
        var on = SyntheticNoise(); on.gpsCorrelatedSigma = 0.1
        let b = SyntheticRun.steady(secondsPerMile: 540, minutes: 5, seed: 9, noise: on)
        XCTAssertNotEqual(a.readings, b.readings)
        XCTAssertEqual(a.readings, SyntheticRun.steady(secondsPerMile: 540, minutes: 5, seed: 9, noise: SyntheticNoise()).readings)
    }

    func testSameSeedSameCorrelatedReadings() {
        let n = SyntheticNoise.forCueTests
        let a = SyntheticRun.steady(secondsPerMile: 540, minutes: 5, seed: 5, noise: n)
        let b = SyntheticRun.steady(secondsPerMile: 540, minutes: 5, seed: 5, noise: n)
        XCTAssertEqual(a.readings, b.readings)
    }

    /// Stationary spread and the lag correlation of the AR(1) error match its settings.
    func testAR1ErrorHasTheStatedSpreadAndCorrelationTime() {
        var n = SyntheticNoise.clean
        n.gpsCorrelatedSigma = 0.2
        n.gpsCorrelationTime = 20
        // Clean noise has no jitter, dropouts or white noise: GPS speed minus truth is the AR(1) error alone.
        var sumSq = 0.0, sumLag = 0.0, count = 0.0
        var lagCount = 0.0, lagLimit = 0.0
        for seed in 1...40 as ClosedRange<UInt64> {
            let run = SyntheticRun.steady(secondsPerMile: 540, minutes: 60, seed: seed, noise: n)
            let truth = run.truth[0].speed
            let e = run.readings.map { ($0.gpsSpeed ?? truth) - truth }
            for i in 0..<e.count { sumSq += e[i] * e[i]; count += 1 }
            for i in 0..<(e.count - 20) { sumLag += e[i] * e[i + 20]; lagCount += 1 }
            lagLimit += 0
        }
        let variance = sumSq / count
        XCTAssertEqual(variance.squareRoot(), 0.2, accuracy: 0.02)
        // Correlation at a 20 s lag is exp(-1) = 0.37.
        XCTAssertEqual((sumLag / lagCount) / variance, exp(-1), accuracy: 0.06)
    }

    func testErrorIsSharedAcrossNeighbouringReadings() {
        var n = SyntheticNoise.clean
        n.gpsCorrelatedSigma = 0.2
        n.gpsCorrelationTime = 30
        let run = SyntheticRun.steady(secondsPerMile: 540, minutes: 30, seed: 3, noise: n)
        let e = gpsErrors(run, trueSpeed: run.truth[0].speed)
        var same = 0
        for (a, b) in zip(e, e.dropFirst()) where (a >= 0) == (b >= 0) { same += 1 }
        XCTAssertGreaterThan(Double(same) / Double(e.count - 1), 0.9, "neighbouring errors share a sign")
    }

    func testAltitudeDriftIsSlowAndAddsToTheTruth() {
        var n = SyntheticNoise.clean
        n.altitudeDriftSigma = 1
        n.altitudeDriftTime = 120
        let run = SyntheticRun.steady(secondsPerMile: 540, minutes: 30, seed: 4, noise: n)
        let alt = run.readings.compactMap(\.altitude)
        XCTAssertEqual(alt.count, run.readings.count)
        // Flat truth: altitude is the drift alone, which moves little from one second to the next.
        let steps = zip(alt, alt.dropFirst()).map { abs($1 - $0) }
        XCTAssertLessThan(steps.max() ?? 99, 0.5)
        XCTAssertGreaterThan((alt.max() ?? 0) - (alt.min() ?? 0), 0.5)
    }

    func testAltitudeTruthFollowsSegmentGrades() {
        let target = PaceTarget(fastestSecondsPerKm: 330, slowestSecondsPerKm: 340)
        let run = SyntheticRun.holdingTarget(target, stretches: [GradeStretch(seconds: 120, grade: 0.05), GradeStretch(seconds: 120, grade: -0.05)],
                                             seed: 1, noise: .clean)
        let up = run.segments[0]
        let rise = up.speed * up.duration * 0.05
        let alts = run.readings.compactMap(\.altitude)
        XCTAssertEqual(alts.first ?? .nan, 0, accuracy: 1e-9)
        XCTAssertEqual(zip(run.readings, alts).first { $0.0.time >= 120 }?.1 ?? .nan, rise, accuracy: 0.5)
        // Down the second stretch it comes back down by (speed ratio) x the rise.
        let down = run.segments[1]
        XCTAssertEqual(alts.last ?? .nan, rise - down.speed * down.duration * 0.05, accuracy: 0.5)
    }

    func testHoldingTargetPutsTheTruePaceInsideTheGradeAdjustedBand() {
        let target = PaceTarget(fastestSecondsPerKm: 327, slowestSecondsPerKm: 337)
        let curve = DefaultGradePaceCurve()
        let stretches = SyntheticRun.rollingGrades(totalSeconds: 900, seed: 12)
        for position in [0.0, 0.3, 0.5, 1.0] {
            let run = SyntheticRun.holdingTarget(target, bandPosition: position, stretches: stretches, seed: 12, noise: .clean)
            for (seg, stretch) in zip(run.segments, stretches) {
                let f = curve.factor(grade: stretch.grade)
                let pace = seg.paceSecondsPerKm ?? .nan
                XCTAssertEqual(pace, (327 + position * 10) * f, accuracy: 1e-9)
                XCTAssertGreaterThanOrEqual(pace, 327 * f - 1e-9)
                XCTAssertLessThanOrEqual(pace, 337 * f + 1e-9)
                XCTAssertEqual(seg.grade, stretch.grade)
            }
        }
        // Positions outside 0...1 are clamped to the band.
        let low = SyntheticRun.holdingTarget(target, bandPosition: -3, stretches: [GradeStretch(seconds: 10, grade: 0)], seed: 1, noise: .clean)
        XCTAssertEqual(low.segments[0].paceSecondsPerKm ?? .nan, 327, accuracy: 1e-9)
    }

    func testRollingGrades() {
        let a = SyntheticRun.rollingGrades(totalSeconds: 1000, seed: 5)
        XCTAssertEqual(a, SyntheticRun.rollingGrades(totalSeconds: 1000, seed: 5))
        XCTAssertNotEqual(a, SyntheticRun.rollingGrades(totalSeconds: 1000, seed: 6))
        XCTAssertEqual(a.reduce(0) { $0 + $1.seconds }, 1000, accuracy: 1e-9)
        for (x, y) in zip(a, a.dropFirst()) { XCTAssertLessThan(x.grade * y.grade, 0, "climbs and descents alternate") }
        for s in a {
            XCTAssertTrue((0.03...0.08).contains(abs(s.grade)))
            XCTAssertLessThanOrEqual(s.seconds, 120)
        }
        XCTAssertTrue(SyntheticRun.rollingGrades(totalSeconds: 0, seed: 1).isEmpty)
        XCTAssertTrue(SyntheticRun.rollingGrades(totalSeconds: 500, gradeRange: 0.05...0.05, seed: 1).allSatisfy { abs($0.grade) == 0.05 })
    }
}
