import XCTest
@testable import CoachCore

/// SPEC.md 3.9 / F13. All runners here are synthetic; expected values were
/// worked out independently (by hand / a separate script), not from this code.
final class BlendedPredictorTests: XCTestCase {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func effort(_ meters: Double, _ seconds: Double, daysAgo: Double = 10) -> BestEffort {
        BestEffort(distanceMeters: meters, seconds: seconds, date: now.addingTimeInterval(-daysAgo * 86_400))
    }

    func estimate(_ p: BlendedPrediction, _ method: PredictionMethod) -> MethodEstimate? {
        p.estimates.first { $0.method == method }
    }

    func reason(_ p: BlendedPrediction, _ method: PredictionMethod) -> SkipReason? {
        p.skipped.first { $0.method == method }?.reason
    }

    // MARK: Riegel

    func testRiegelUsesEffortClosestToTarget() throws {
        // 10K in 52:30 (3150 s) -> 10 miles: 3150 * 1.609344^1.07 = 5241.13 s.
        let p = BlendedPredictor.predict(targetMeters: Distance.tenMiles,
                                         efforts: [effort(Distance.fiveK, 1500), effort(Distance.tenK, 3150)],
                                         asOf: now)
        let e = try XCTUnwrap(estimate(p, .riegel))
        XCTAssertEqual(e.seconds, 5241.13, accuracy: 0.01)
        XCTAssertEqual(e.evidence.map(\.distanceMeters), [Distance.tenK])
    }

    func testRiegelIgnoresEffortsShorterThan3KAndLongerThanHalf() {
        let p = BlendedPredictor.predict(targetMeters: Distance.tenK,
                                         efforts: [effort(Distance.mile, 400), effort(Distance.marathon, 14_000)],
                                         asOf: now)
        XCTAssertNil(estimate(p, .riegel))
        XCTAssertEqual(reason(p, .riegel), .noQualifyingEfforts)
    }

    // MARK: Critical speed

    func testCriticalSpeedExactTwoPointFit() throws {
        // d = 4 t + 200: 1000 m in 200 s, 3000 m in 700 s -> CS 4 m/s, D′ 200 m; 5K = 4800 / 4 = 1200 s.
        let fit = try BlendedPredictor.fitCriticalSpeed([effort(1000, 200), effort(3000, 700)]).get()
        XCTAssertEqual(fit.metersPerSecond, 4, accuracy: 1e-9)
        XCTAssertEqual(fit.dPrimeMeters, 200, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(fit.predictedSeconds(meters: 5000)), 1200, accuracy: 1e-6)
        XCTAssertNil(fit.predictedSeconds(meters: 150))
        XCTAssertNil(fit.predictedSeconds(meters: .nan))
    }

    func testCriticalSpeedLeastSquaresFit() throws {
        // Mile 6:00, 2 miles 12:30, 5K 20:00. Least squares by hand:
        // CS = 4.034508 m/s, D′ = 169.439 m, 10K = (10000 - 169.439) / 4.034508 = 2436.62 s.
        let fit = try BlendedPredictor.fitCriticalSpeed([
            effort(Distance.mile, 360), effort(2 * Distance.mile, 750), effort(Distance.fiveK, 1200),
        ]).get()
        XCTAssertEqual(fit.metersPerSecond, 4.034508, accuracy: 1e-6)
        XCTAssertEqual(fit.dPrimeMeters, 169.439, accuracy: 1e-3)
        XCTAssertEqual(try XCTUnwrap(fit.predictedSeconds(meters: Distance.tenK)), 2436.62, accuracy: 0.01)
    }

    func testCriticalSpeedNeedsTwoDistancesWithDurationSpread() {
        XCTAssertEqual(failure(BlendedPredictor.fitCriticalSpeed([])), .noQualifyingEfforts)
        XCTAssertEqual(failure(BlendedPredictor.fitCriticalSpeed([effort(Distance.fiveK, 1200)])), .needsTwoDistances)
        // Same distance twice counts once.
        XCTAssertEqual(failure(BlendedPredictor.fitCriticalSpeed([effort(3000, 700), effort(3000, 720)])),
                       .needsTwoDistances)
        // 600 s and 800 s: ratio 1.33 < 1.5.
        XCTAssertEqual(failure(BlendedPredictor.fitCriticalSpeed([effort(2500, 600), effort(3200, 800)])),
                       .needsTwoDistances)
        // Outside the 2 to 30 minute window: a 1:00 400 m and a 50:00 10K don't count.
        XCTAssertEqual(failure(BlendedPredictor.fitCriticalSpeed([effort(400, 60), effort(Distance.tenK, 3000)])),
                       .noQualifyingEfforts)
    }

    func testCriticalSpeedRejectsNegativeDPrime() {
        // 1000 m in 300 s, 2000 m in 500 s: slope 5 m/s, D′ = -500 m.
        XCTAssertEqual(failure(BlendedPredictor.fitCriticalSpeed([effort(1000, 300), effort(2000, 500)])),
                       .implausibleFit)
    }

    func testCriticalSpeedSkipsTargetsBeyondAnHour() {
        // CS 4 m/s, D′ 200 m: half marathon = 5224 s, beyond the 60-minute limit.
        let p = BlendedPredictor.predict(targetMeters: Distance.halfMarathon,
                                         efforts: [effort(1000, 200), effort(3000, 700)], asOf: now)
        XCTAssertEqual(reason(p, .criticalSpeed), .targetOutOfRange)
    }

    // MARK: Threshold

    func testThresholdTreatsLTHRPaceAsOneHourRacePace() throws {
        // 0.25 s/m at LTHR -> 14.4 km in an hour. 10K: 3600 * (10000/14400)^1.07 = 2436.99 s;
        // half: 3600 * (21097.5/14400)^1.07 = 5417.29 s.
        let tenK = BlendedPredictor.predict(targetMeters: Distance.tenK, efforts: [], asOf: now, secondsPerMeterAtLTHR: 0.25)
        XCTAssertEqual(try XCTUnwrap(estimate(tenK, .threshold)).seconds, 2436.99, accuracy: 0.01)
        let half = BlendedPredictor.predict(targetMeters: Distance.halfMarathon, efforts: [], asOf: now, secondsPerMeterAtLTHR: 0.25)
        XCTAssertEqual(try XCTUnwrap(estimate(half, .threshold)).seconds, 5417.29, accuracy: 0.01)
    }

    func testThresholdRejectsMissingOrBadPace() {
        for pace in [nil, .nan, .infinity, -.infinity, 0, -0.25, 5.0] as [Double?] {
            let p = BlendedPredictor.predict(targetMeters: Distance.tenK, efforts: [], asOf: now, secondsPerMeterAtLTHR: pace)
            XCTAssertEqual(reason(p, .threshold), .missingInput, "pace \(String(describing: pace))")
        }
    }

    // MARK: Blend

    func testBlendOfThreeMethodsUsesMedianAndExtremes() throws {
        // Riegel from the 5K: 1200 * 2^1.07 = 2519.32; CS: 2436.62; threshold: 2436.99.
        // Median 2436.99; low = min(2436.62, 0.98 * 2436.99 = 2388.26); high = max(2519.32, 1.02 * 2436.99).
        let p = BlendedPredictor.predict(
            targetMeters: Distance.tenK,
            efforts: [effort(Distance.mile, 360), effort(2 * Distance.mile, 750), effort(Distance.fiveK, 1200)],
            asOf: now, secondsPerMeterAtLTHR: 0.25)
        XCTAssertEqual(Set(p.estimates.map(\.method)), [.riegel, .criticalSpeed, .threshold])
        XCTAssertEqual(p.skipped, [SkippedMethod(method: .vickersVertosick, reason: .targetOutOfRange)])
        let r = try XCTUnwrap(p.range)
        XCTAssertEqual(r.central, 2436.99, accuracy: 0.01)
        XCTAssertEqual(r.low, 2388.26, accuracy: 0.01)
        XCTAssertEqual(r.high, 2519.32, accuracy: 0.01)
    }

    func testBlendOfTwoMethodsUsesMeanAndMinimumSpread() throws {
        // Riegel from 3000 m in 700 s: 700 * (5/3)^1.07 = 1209.14; CS (d = 4t + 200): 1200.
        // Central = 1204.57; low = min(1200, 0.98 * 1204.57 = 1180.48); high = max(1209.14, 1.02 * 1204.57 = 1228.66).
        let p = BlendedPredictor.predict(targetMeters: Distance.fiveK,
                                         efforts: [effort(1000, 200), effort(3000, 700)], asOf: now)
        XCTAssertEqual(reason(p, .threshold), .missingInput)
        let r = try XCTUnwrap(p.range)
        XCTAssertEqual(r.central, 1204.57, accuracy: 0.01)
        XCTAssertEqual(r.low, 1180.48, accuracy: 0.01)
        XCTAssertEqual(r.high, 1228.66, accuracy: 0.01)
        XCTAssertLessThan(r.low, r.central)
        XCTAssertGreaterThan(r.high, r.central)
    }

    // MARK: Marathon

    func testMarathonUsesVickersVertosickModel1() throws {
        // Half in 1:45:00 (6300 s), 30 miles a week. Riegel marathon = 6300 * 2^1.07 = 13226.43 s,
        // speed 3.19020 m/s; corrected speed = 0.16018617 + 0.83076202 * 3.19020 + 0.06423826 * 3
        // = 3.003272 m/s -> 14050.01 s (3:54:10), about 14 minutes slower than plain Riegel.
        let weekly = 30 * Distance.mile
        let p = BlendedPredictor.predict(targetMeters: Distance.marathon,
                                         efforts: [effort(Distance.tenK, 2900), effort(Distance.halfMarathon, 6300)],
                                         asOf: now, secondsPerMeterAtLTHR: 0.3, typicalWeeklyMeters: weekly)
        let e = try XCTUnwrap(estimate(p, .vickersVertosick))
        XCTAssertEqual(e.seconds, 14050.01, accuracy: 0.01)
        XCTAssertEqual(e.evidence.map(\.distanceMeters), [Distance.halfMarathon], "Model 1 uses the longest race")
        XCTAssertEqual(p.estimates.count, 1)
        for method in [PredictionMethod.riegel, .criticalSpeed, .threshold] {
            XCTAssertEqual(reason(p, method), .notUsedForMarathon)
        }
        // Range half-width = sqrt(227.6 min²) = 905.19 s.
        let r = try XCTUnwrap(p.range)
        XCTAssertEqual(r.central, 14050.01, accuracy: 0.01)
        XCTAssertEqual(r.low, 14050.01 - 905.19, accuracy: 0.01)
        XCTAssertEqual(r.high, 14050.01 + 905.19, accuracy: 0.01)
    }

    func testMarathonFromTenK() throws {
        // 10K in 45:00, 40 miles a week: Riegel 12600.65 s -> corrected 13189.82 s.
        let t = try XCTUnwrap(VickersVertosick.marathonSeconds(raceMeters: Distance.tenK, raceSeconds: 2700, weeklyMiles: 40))
        XCTAssertEqual(t, 13189.82, accuracy: 0.01)
    }

    func testMarathonNeverReturnsPlainRiegel() throws {
        // Model 1 can only coincide with Riegel at one weekly volume per runner (for a 2:30 half
        // near 34 mi/week; for a 1:30 half near 73). Check a grid of 1:30 to 2:30 halves at 5 to 30
        // mi/week, plus high-volume cases on both sides of that crossover.
        var cases: [(Double, Double)] = []
        for halfSeconds in stride(from: 5400.0, through: 9000, by: 600) {
            for miles in stride(from: 5.0, through: 30, by: 5) { cases.append((halfSeconds, miles)) }
        }
        cases += [(5400, 50), (9000, 50), (7200, 60)]
        for (halfSeconds, miles) in cases {
            let plain = try XCTUnwrap(RacePredictor.riegel(knownMeters: Distance.halfMarathon, knownSeconds: halfSeconds,
                                                           targetMeters: Distance.marathon))
            let p = BlendedPredictor.predict(targetMeters: Distance.marathon,
                                             efforts: [effort(Distance.halfMarathon, halfSeconds)],
                                             asOf: now, typicalWeeklyMeters: miles * Distance.mile)
            let r = try XCTUnwrap(p.range)
            XCTAssertGreaterThan(abs(r.central - plain), 60, "half \(halfSeconds) s, \(miles) mi/week")
            XCTAssertFalse(p.estimates.contains { $0.method == .riegel })
        }
    }

    func testMarathonWithoutVolumeOrRaceHasNoRange() {
        let noVolume = BlendedPredictor.predict(targetMeters: Distance.marathon,
                                                efforts: [effort(Distance.halfMarathon, 6300)], asOf: now)
        XCTAssertNil(noVolume.range)
        XCTAssertEqual(reason(noVolume, .vickersVertosick), .missingInput)
        for bad in [Double.nan, .infinity, 0, -100] {
            let p = BlendedPredictor.predict(targetMeters: Distance.marathon, efforts: [effort(Distance.halfMarathon, 6300)],
                                             asOf: now, typicalWeeklyMeters: bad)
            XCTAssertNil(p.range)
        }
        // Only a 3K: below the 5K the model was built on.
        let shortOnly = BlendedPredictor.predict(targetMeters: Distance.marathon, efforts: [effort(3000, 720)],
                                                 asOf: now, typicalWeeklyMeters: 50_000)
        XCTAssertNil(shortOnly.range)
        XCTAssertEqual(reason(shortOnly, .vickersVertosick), .noQualifyingEfforts)
    }

    func testVickersVertosickRejectsBadInputs() {
        XCTAssertNil(VickersVertosick.marathonSeconds(raceMeters: 3000, raceSeconds: 720, weeklyMiles: 30))
        XCTAssertNil(VickersVertosick.marathonSeconds(raceMeters: Distance.marathon, raceSeconds: 14_000, weeklyMiles: 30))
        XCTAssertNil(VickersVertosick.marathonSeconds(raceMeters: Distance.tenK, raceSeconds: .nan, weeklyMiles: 30))
        XCTAssertNil(VickersVertosick.marathonSeconds(raceMeters: Distance.tenK, raceSeconds: 2700, weeklyMiles: .infinity))
        XCTAssertNil(VickersVertosick.marathonSeconds(raceMeters: .nan, raceSeconds: 2700, weeklyMiles: 30))
    }

    // MARK: Targets and inputs

    func testUnsupportedTargets() {
        let efforts = [effort(1000, 200), effort(3000, 700), effort(Distance.halfMarathon, 6300)]
        for target in [30_000.0, 50_000, .nan, .infinity, 0, -5000] {
            let p = BlendedPredictor.predict(targetMeters: target, efforts: efforts, asOf: now,
                                             secondsPerMeterAtLTHR: 0.25, typicalWeeklyMeters: 50_000)
            XCTAssertNil(p.range, "target \(target)")
            XCTAssertTrue(p.estimates.isEmpty)
            XCTAssertEqual(p.skipped.count, PredictionMethod.allCases.count)
            XCTAssertTrue(p.skipped.allSatisfy { $0.reason == .targetOutOfRange })
        }
    }

    func testNoDataExplainsEveryMethod() {
        let p = BlendedPredictor.predict(targetMeters: Distance.tenK, efforts: [], asOf: now)
        XCTAssertNil(p.range)
        XCTAssertEqual(p.skipped, [
            SkippedMethod(method: .riegel, reason: .noQualifyingEfforts),
            SkippedMethod(method: .criticalSpeed, reason: .noQualifyingEfforts),
            SkippedMethod(method: .threshold, reason: .missingInput),
            SkippedMethod(method: .vickersVertosick, reason: .targetOutOfRange),
        ])
    }

    func testIgnoresNonFiniteImplausibleStaleAndFutureEfforts() {
        let bad = [
            effort(.nan, 1200), effort(Distance.fiveK, .nan), effort(.infinity, 1200), effort(Distance.fiveK, .infinity),
            effort(Distance.fiveK, 0), effort(-5000, 1200),
            effort(Distance.fiveK, 300),           // 16.7 m/s: not running
            effort(Distance.fiveK, 10_000),        // 0.5 m/s: not running
            effort(Distance.fiveK, 1200, daysAgo: 121),
            effort(Distance.fiveK, 1200, daysAgo: -1),
        ]
        let p = BlendedPredictor.predict(targetMeters: Distance.tenK, efforts: bad, asOf: now)
        XCTAssertNil(p.range)
        XCTAssertEqual(reason(p, .riegel), .noQualifyingEfforts)
        XCTAssertEqual(reason(p, .criticalSpeed), .noQualifyingEfforts)
    }

    func testZeroLookbackIgnoresEverything() {
        let p = BlendedPredictor.predict(targetMeters: Distance.tenK, efforts: [effort(Distance.fiveK, 1200, daysAgo: 0)],
                                         asOf: now, lookbackDays: 0)
        XCTAssertNil(p.range)
    }

    func testKeepsFastestEffortAtEachDistance() throws {
        // A slower 5K (and one 0.5% long) must not replace the 20:00 one.
        let p = BlendedPredictor.predict(targetMeters: Distance.tenK,
                                         efforts: [effort(Distance.fiveK, 1320), effort(Distance.fiveK, 1200), effort(5025, 1290)],
                                         asOf: now)
        let e = try XCTUnwrap(estimate(p, .riegel))
        XCTAssertEqual(e.evidence.first?.seconds, 1200)
        XCTAssertEqual(e.seconds, 2519.32, accuracy: 0.01)
    }

    private func failure(_ result: Result<CriticalSpeedFit, SkipReason>) -> SkipReason? {
        if case .failure(let reason) = result { return reason }
        return nil
    }

    // MARK: Inputs, short targets, recency boundary (#9)

    func testEveryMethodReportsItsInputs() throws {
        let efforts = [effort(1000, 200), effort(3000, 700), effort(Distance.tenK, 3150)]
        let short = BlendedPredictor.predict(targetMeters: 5000, efforts: efforts, asOf: now, secondsPerMeterAtLTHR: 0.25)
        let riegel = try XCTUnwrap(estimate(short, .riegel))
        XCTAssertEqual(riegel.inputs, MethodInputs(riegelExponent: 1.07))
        let cs = try XCTUnwrap(estimate(short, .criticalSpeed))
        XCTAssertEqual(try XCTUnwrap(cs.inputs.criticalSpeedMetersPerSecond), 4, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(cs.inputs.dPrimeMeters), 200, accuracy: 1e-6)
        let threshold = try XCTUnwrap(estimate(short, .threshold))
        XCTAssertEqual(threshold.inputs, MethodInputs(secondsPerMeterAtLTHR: 0.25, riegelExponent: 1.07))

        let marathon = BlendedPredictor.predict(targetMeters: Distance.marathon, efforts: [effort(Distance.tenK, 2700)],
                                                asOf: now, typicalWeeklyMeters: 50_000)
        let vv = try XCTUnwrap(estimate(marathon, .vickersVertosick))
        XCTAssertEqual(vv.inputs, MethodInputs(weeklyMeters: 50_000, riegelExponent: 1.07))
    }

    func testTargetsBelowOneMileAreRefused() throws {
        XCTAssertEqual(BlendedPredictor.minimumTargetMeters, 1609.344)
        let efforts = [effort(3000, 700), effort(Distance.fiveK, 1200)]
        let short = BlendedPredictor.predict(targetMeters: 800, efforts: efforts, asOf: now, secondsPerMeterAtLTHR: 0.25)
        XCTAssertNil(short.range)
        XCTAssertTrue(short.estimates.isEmpty)
        XCTAssertEqual(short.skipped.count, PredictionMethod.allCases.count)
        XCTAssertTrue(short.skipped.allSatisfy { $0.reason == .targetOutOfRange })
        let justBelow = BlendedPredictor.predict(targetMeters: Distance.mile - 0.001, efforts: efforts, asOf: now)
        XCTAssertNil(justBelow.range)
        let mile = BlendedPredictor.predict(targetMeters: Distance.mile, efforts: efforts, asOf: now)
        XCTAssertNotNil(mile.range)
        XCTAssertNotNil(estimate(mile, .riegel))
    }

    func testSingleMethodBlendForShortTargetIsPlusMinusTwoPercent() throws {
        // One 5K in 20:00 only: Riegel is the sole method. 3000 m: 1200 * 0.6^1.07 = 694.71 s (checked in Python).
        let p = BlendedPredictor.predict(targetMeters: 3000, efforts: [effort(Distance.fiveK, 1200)], asOf: now)
        XCTAssertEqual(p.estimates.map(\.method), [.riegel])
        let range = try XCTUnwrap(p.range)
        let expected = 1200 * pow(0.6, 1.07)
        XCTAssertEqual(range.central, expected, accuracy: 1e-6)
        XCTAssertEqual(range.low, expected * 0.98, accuracy: 1e-6)
        XCTAssertEqual(range.high, expected * 1.02, accuracy: 1e-6)
        // One mile from the same effort: the same rule at the lower bound.
        let mile = try XCTUnwrap(BlendedPredictor.predict(targetMeters: Distance.mile, efforts: [effort(Distance.fiveK, 1200)],
                                                          asOf: now).range)
        XCTAssertEqual(mile.low, mile.central * 0.98, accuracy: 1e-6)
        XCTAssertEqual(mile.high, mile.central * 1.02, accuracy: 1e-6)
    }

    func testEffortExactlyAtLookbackLimitIsIncluded() throws {
        let p = BlendedPredictor.predict(targetMeters: Distance.tenK, efforts: [effort(Distance.fiveK, 1200, daysAgo: 120)], asOf: now)
        XCTAssertNotNil(estimate(p, .riegel))
        let older = BlendedPredictor.predict(targetMeters: Distance.tenK, efforts: [effort(Distance.fiveK, 1200, daysAgo: 120.01)], asOf: now)
        XCTAssertNil(estimate(older, .riegel))
    }
}
