import XCTest
@testable import CoachCore

final class PaceEstimatorTests: XCTestCase {
    private let mile = UnitFormatting.metersPerMile

    private func gps(_ t: Double, _ v: Double, acc: Double = 5) -> LiveReading {
        LiveReading(time: t, gpsSpeed: v, gpsAccuracy: acc)
    }

    // MARK: No usable input

    func testAllNilReadingsGiveNil() {
        var e = PaceEstimator()
        for t in 0..<20 { XCTAssertNil(e.ingest(LiveReading(time: Double(t)))) }
        XCTAssertNil(e.estimate)
        XCTAssertNil(e.strideLength)
        XCTAssertNil(e.watchSpeedScale)
    }

    func testEmptyInput() {
        XCTAssertTrue(PaceEstimator.run([]).isEmpty)
    }

    func testNonFiniteAndInvalidValuesAreIgnored() {
        var e = PaceEstimator()
        let bad = LiveReading(time: 1, gpsSpeed: .nan, gpsAccuracy: .infinity, watchSpeed: .infinity,
                              cadence: .nan, heartRate: .nan, altitude: .infinity)
        XCTAssertNil(e.ingest(bad))
        XCTAssertNil(e.ingest(LiveReading(time: 2, gpsSpeed: -1, gpsAccuracy: 5)))        // CoreLocation invalid speed
        XCTAssertNil(e.ingest(LiveReading(time: 3, gpsSpeed: 3, gpsAccuracy: -1)))        // invalid accuracy
        XCTAssertNil(e.ingest(LiveReading(time: 4, gpsSpeed: 3, gpsAccuracy: 80)))        // past the accuracy limit
        XCTAssertNil(e.ingest(LiveReading(time: 5, gpsSpeed: .infinity, gpsAccuracy: 5)))
        XCTAssertNil(e.ingest(LiveReading(time: .nan, gpsSpeed: 3, gpsAccuracy: 5)))
        XCTAssertNil(e.ingest(LiveReading(time: .infinity, gpsSpeed: 3, gpsAccuracy: 5)))
        XCTAssertNil(e.ingest(LiveReading(time: 6, cadence: 0)))
        XCTAssertNil(e.ingest(LiveReading(time: 7, cadence: 500)))
        // A good reading still works after all that.
        let est = e.ingest(gps(8, 3.0))
        XCTAssertEqual(est?.speed ?? 0, 3.0, accuracy: 1e-9)
    }

    func testNonFiniteReadingsDoNotCorruptARunningEstimate() {
        var e = PaceEstimator()
        for t in 0..<30 { e.ingest(gps(Double(t), 3.0)) }
        let before = e.estimate!
        e.ingest(LiveReading(time: 30, gpsSpeed: .nan, gpsAccuracy: 5, watchSpeed: .infinity, cadence: .nan))
        let after = e.estimate!
        XCTAssertTrue(after.speed.isFinite && after.speedSigma.isFinite)
        XCTAssertEqual(after.speed, before.speed, accuracy: 1e-6)
    }

    // MARK: Single-source input

    func testGPSOnlyGivesFiniteEstimate() {
        var e = PaceEstimator()
        var last: PaceEstimate?
        for t in 0..<60 { last = e.ingest(gps(Double(t), 3.2)) }
        XCTAssertEqual(last!.speed, 3.2, accuracy: 0.01)
        XCTAssertTrue(last!.speedSigma > 0 && last!.speedSigma.isFinite)
        XCTAssertNil(e.strideLength, "no cadence, so no stride")
    }

    func testGPSWithoutAccuracyUsesAssumedAccuracy() {
        var e = PaceEstimator()
        let est = e.ingest(LiveReading(time: 0, gpsSpeed: 3))
        XCTAssertEqual(est?.speed ?? 0, 3, accuracy: 1e-9)
    }

    func testWatchSpeedOnlyGivesFiniteEstimate() {
        var e = PaceEstimator()
        var last: PaceEstimate?
        for t in 0..<60 { last = e.ingest(LiveReading(time: Double(t), watchSpeed: 2.8)) }
        XCTAssertEqual(last!.speed, 2.8, accuracy: 0.01)
        XCTAssertNil(e.watchSpeedScale, "no GPS, so no calibration")
    }

    func testCadenceOnlyBeforeStrideIsLearnedGivesNil() {
        var e = PaceEstimator()
        for t in 0..<60 { XCTAssertNil(e.ingest(LiveReading(time: Double(t), cadence: 170))) }
    }

    func testCadenceOnlyAfterGPSLearnedStrideIsFinite() {
        var e = PaceEstimator()
        // 3.0 m/s at 170 steps/min is a stride of 1.0588 m.
        for t in 0..<60 { e.ingest(LiveReading(time: Double(t), gpsSpeed: 3.0, gpsAccuracy: 5, cadence: 170)) }
        XCTAssertEqual(e.strideLength ?? 0, 3.0 * 60 / 170, accuracy: 0.01)
        // GPS is gone for a while; cadence alone keeps the estimate.
        var last: PaceEstimate?
        for t in 60..<90 { last = e.ingest(LiveReading(time: Double(t), cadence: 170)) }
        XCTAssertEqual(last!.speed, 3.0, accuracy: 0.1)
        XCTAssertTrue(last!.speedSigma.isFinite)
    }

    func testStrideNotLearnedFromPoorGPSOrFromWalkingSpeeds() {
        var e = PaceEstimator()
        for t in 0..<60 { e.ingest(LiveReading(time: Double(t), gpsSpeed: 3.0, gpsAccuracy: 25, cadence: 170)) }
        XCTAssertNil(e.strideLength, "accuracy 25 m is not good enough to learn from")
        var w = PaceEstimator()
        for t in 0..<60 { w.ingest(LiveReading(time: Double(t), gpsSpeed: 1.0, gpsAccuracy: 5, cadence: 110)) }
        XCTAssertNil(w.strideLength, "walking speed teaches nothing")
    }

    func testWatchScaleIsLearnedFromGPS() {
        var e = PaceEstimator()
        // The watch reads 4% low.
        for t in 0..<90 {
            e.ingest(LiveReading(time: Double(t), gpsSpeed: 3.0, gpsAccuracy: 5, watchSpeed: 3.0 * 0.96))
        }
        XCTAssertEqual(e.watchSpeedScale ?? 0, 1 / 0.96, accuracy: 0.01)
        // GPS lost: the calibrated watch speed keeps the estimate on the truth.
        var last: PaceEstimate?
        for t in 90..<150 { last = e.ingest(LiveReading(time: Double(t), watchSpeed: 3.0 * 0.96)) }
        XCTAssertEqual(last!.speed, 3.0, accuracy: 0.02)
    }

    // MARK: Ordering and intervals

    func testOutOfOrderAndDuplicateReadingsAreDropped() {
        var e = PaceEstimator()
        for t in 0..<20 { e.ingest(gps(Double(t), 3.0)) }
        let before = e.estimate
        XCTAssertEqual(e.ingest(gps(5, 6.0)), before, "an old reading must not move the estimate")
        XCTAssertEqual(e.ingest(gps(19, 6.0)), before, "a duplicate time is dropped")
        XCTAssertNotEqual(e.ingest(gps(20, 3.0))?.time, before?.time)
    }

    func testUnevenIntervalsStillConverge() {
        var e = PaceEstimator()
        var t = 0.0
        var rng = SplitMix64(seed: 99)
        var last: PaceEstimate?
        while t < 120 {
            last = e.ingest(gps(t, 3.0))
            t += rng.uniform(0.2, 3.0)
        }
        XCTAssertEqual(last!.speed, 3.0, accuracy: 0.02)
    }

    func testRunSortsBatchInput() {
        let shuffled = [gps(3, 3), gps(1, 3), gps(2, 3), gps(0, 3)]
        let out = PaceEstimator.run(shuffled)
        XCTAssertEqual(out.compactMap { $0?.time }, [0, 1, 2, 3])
    }

    // MARK: Pace output

    func testPaceConversions() {
        var e = PaceEstimator()
        let est = e.ingest(gps(0, 3.0))!
        XCTAssertEqual(est.secondsPerKm!, 1000 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(est.secondsPerMile!, mile / 3.0, accuracy: 1e-9)
        XCTAssertEqual(est.pace(in: .metric)!, 1000 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(est.pace(in: .imperial)!, mile / 3.0, accuracy: 1e-9)
        XCTAssertGreaterThan(est.secondsPerKmSigma!, 0)
    }

    func testStoppedHasNoPace() {
        var e = PaceEstimator()
        for t in 0..<30 { e.ingest(gps(Double(t), 0.0)) }
        let est = e.estimate!
        XCTAssertEqual(est.speed, 0, accuracy: 1e-9)
        XCTAssertNil(est.secondsPerKm)
        XCTAssertNil(est.secondsPerMile)
        XCTAssertNil(est.secondsPerKmSigma)
    }

    func testUncertaintyShrinksWithData() {
        var e = PaceEstimator()
        let first = e.ingest(gps(0, 3.0, acc: 10))!
        var last = first
        for t in 1..<40 { last = e.ingest(gps(Double(t), 3.0, acc: 10))! }
        XCTAssertLessThan(last.speedSigma, first.speedSigma)
    }

    func testPoorAccuracyIsTrustedLessThanGoodAccuracy() {
        var good = PaceEstimator(), poor = PaceEstimator()
        for t in 0..<20 { good.ingest(gps(Double(t), 3.0, acc: 4)); poor.ingest(gps(Double(t), 3.0, acc: 25)) }
        good.ingest(gps(20, 4.0, acc: 4))
        poor.ingest(gps(20, 4.0, acc: 25))
        XCTAssertGreaterThan(good.estimate!.speed, poor.estimate!.speed)
    }

    func testResetForgetsEverything() {
        var e = PaceEstimator()
        for t in 0..<30 { e.ingest(LiveReading(time: Double(t), gpsSpeed: 3, gpsAccuracy: 5, cadence: 170)) }
        e.reset()
        XCTAssertNil(e.estimate)
        XCTAssertNil(e.strideLength)
        XCTAssertNotNil(e.ingest(gps(0, 2.0)), "time may restart from 0 after a reset")
    }

    // MARK: Pause and resume

    /// Longest amount by which the estimate's pace is faster than the true
    /// pace, in s/mile, over readings after `from`.
    private func worstOvershoot(_ run: SyntheticRun, from: Double, readings: [LiveReading]) -> Double {
        var e = PaceEstimator()
        var worst = 0.0
        for r in readings {
            let est = e.ingest(r)
            guard r.time >= from, let s = est?.speed, s > 0.5,
                  let truth = run.truth.min(by: { abs($0.time - r.time) < abs($1.time - r.time) }),
                  truth.speed > 1 else { continue }
            worst = max(worst, mile / truth.speed - mile / s)
        }
        return worst
    }

    func testPauseThenResumeGivesNoSpike() {
        // Low sensor noise so the test sees the pause artifact, not the filter's
        // ordinary steady-state jitter (which reaches about 15 to 20 s/mile on
        // the default noise; see the acceptance tests for those numbers).
        var noise = SyntheticNoise()
        noise.dropoutProbability = 0
        noise.spikeProbability = 0
        noise.gpsSigmaBase = 0.03
        noise.gpsSigmaPerMeter = 0.004
        noise.watchSigma = 0.04
        noise.cadenceSigma = 0.5
        noise.watchBiasFraction = 0.01
        for seed in 1...6 as ClosedRange<UInt64> {
            let run = SyntheticRun(segments: [.atMilePace(540, duration: 300), .stopped(duration: 60),
                                              .atMilePace(540, duration: 300)], seed: seed, noise: noise)
            // (a) The watch stops sending anything during the pause.
            let silent = run.readings.filter { $0.time < 300 || $0.time >= 360 }
            XCTAssertLessThanOrEqual(worstOvershoot(run, from: 360, readings: silent), 15, "silent pause, seed \(seed)")
            // (b) Readings keep coming and read standing still.
            XCTAssertLessThanOrEqual(worstOvershoot(run, from: 360, readings: run.readings), 15, "zero-speed pause, seed \(seed)")
        }
    }

    func testStandingStillReadsAsStoppedThenRecovers() {
        let run = SyntheticRun(segments: [.atMilePace(540, duration: 120), .stopped(duration: 60),
                                          .atMilePace(540, duration: 120)], seed: 4, noise: .clean)
        var e = PaceEstimator()
        var duringPause: PaceEstimate?
        var final: PaceEstimate?
        for r in run.readings {
            let est = e.ingest(r)
            if r.time > 170 && r.time < 178 { duringPause = est }
            final = est
        }
        XCTAssertNil(duringPause?.secondsPerKm)
        XCTAssertEqual(final!.speed, 1000 / (540 * 1000 / mile), accuracy: 0.05)
    }

    func testLongGapDoesNotTrustOneReadingCompletely() {
        var e = PaceEstimator()
        for t in 0..<60 { e.ingest(gps(Double(t), 3.0)) }
        // 10 minutes of nothing, then one wild-but-accurate-looking reading.
        e.ingest(gps(660, 5.0, acc: 8))
        XCTAssertLessThan(e.estimate!.speed, 5.0)
        XCTAssertGreaterThan(e.estimate!.speed, 3.0)
    }
}
