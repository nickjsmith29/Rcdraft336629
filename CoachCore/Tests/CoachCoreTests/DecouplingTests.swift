import XCTest
@testable import CoachCore

// All streams below are synthetic; nothing here is any real runner's data.
final class DecouplingTests: XCTestCase {

    /// One sample per second over `seconds` (inclusive of the end point), values
    /// as functions of elapsed time.
    private func stream(seconds: Int,
                        hr: (Double) -> Double? = { _ in 150 },
                        speed: (Double) -> Double? = { _ in 3.0 },
                        power: (Double) -> Double? = { _ in nil },
                        moving: (Double) -> Bool = { _ in true }) -> [StreamSample] {
        (0...seconds).map { i in
            let t = Double(i)
            return StreamSample(t: t, heartRate: hr(t), speed: speed(t), power: power(t), isMoving: moving(t))
        }
    }

    private func linearHR(_ t: Double) -> Double { 140 + 20 * t / 3600 }

    /// Expected decoupling for constant output and HR = linearHR on 1 s samples
    /// over the window [lo, hi) split at its midpoint: 1 - meanHR1 / meanHR2.
    private func expectedLinear(lo: Int, hi: Int) -> Double {
        let mid = lo + (hi - lo) / 2
        let h1 = (lo..<mid).map { linearHR(Double($0)) }.reduce(0, +) / Double(mid - lo)
        let h2 = (mid..<hi).map { linearHR(Double($0)) }.reduce(0, +) / Double(hi - mid)
        return (1 - h1 / h2) * 100
    }

    private let noWarmUp = DecouplingOptions(warmUpSeconds: 0)

    private func value(_ r: Result<DecouplingResult, DecouplingRefusal>,
                       file: StaticString = #filePath, line: UInt = #line) throws -> DecouplingResult {
        switch r {
        case .success(let v): return v
        case .failure(let e):
            XCTFail("unexpected refusal \(e)", file: file, line: line)
            throw e
        }
    }

    // MARK: Known drift

    func testConstantSpeedAndHRHasZeroDecoupling() throws {
        let r = try value(Decoupling.compute(stream(seconds: 3600)))
        XCTAssertEqual(r.percent, 0, accuracy: 1e-9)
        XCTAssertEqual(r.classification, .good)
        XCTAssertEqual(r.firstHalfEF, 3.0 / 150, accuracy: 1e-12)
        XCTAssertEqual(r.movingSeconds, 3600)
        XCTAssertEqual(r.analyzedSeconds, 3300)
        XCTAssertEqual(r.firstHalfHRCoverage, 1)
        XCTAssertEqual(r.secondHalfHRCoverage, 1)
        XCTAssertEqual(r.basis, .pace)
    }

    func testLinearHRDriftAtConstantSpeedWithoutWarmUp() throws {
        let r = try value(Decoupling.compute(stream(seconds: 3600, hr: linearHR), options: noWarmUp))
        XCTAssertEqual(r.percent, expectedLinear(lo: 0, hi: 3600), accuracy: 1e-9)
        // Closed form: 1 - 145/155 is about 6.45%.
        XCTAssertEqual(r.percent, 6.45, accuracy: 0.01)
        XCTAssertEqual(r.classification, .moderate)
    }

    func testDefaultWarmUpIsSkipped() throws {
        let r = try value(Decoupling.compute(stream(seconds: 3600, hr: linearHR)))
        XCTAssertEqual(r.percent, expectedLinear(lo: 300, hi: 3600), accuracy: 1e-9)
        // Closed form: halves [300, 1950) and [1950, 3600) have mean HR at their
        // midpoints, 146.25 and 155.42, so 1 - 146.25/155.42 is about 5.90%.
        XCTAssertEqual(r.percent, 5.90, accuracy: 0.01)
        XCTAssertEqual(r.analyzedSeconds, 3300)
    }

    func testWarmUpSpikeDoesNotCountWhenSkipped() throws {
        // HR climbs from 100 in the first 3 minutes, then is flat.
        let hr: (Double) -> Double? = { t in t < 180 ? 100 + t / 180 * 50 : 150 }
        let skipped = try value(Decoupling.compute(stream(seconds: 3600, hr: hr)))
        XCTAssertEqual(skipped.percent, 0, accuracy: 1e-9)
        let whole = try value(Decoupling.compute(stream(seconds: 3600, hr: hr), options: noWarmUp))
        XCTAssertGreaterThan(whole.percent, 0) // the low early HR flatters the first half's EF
    }

    func testFallingHRGivesNegativeDecouplingClassedGood() throws {
        let r = try value(Decoupling.compute(stream(seconds: 3600, hr: { 160 - 10 * $0 / 3600 })))
        XCTAssertLessThan(r.percent, 0)
        XCTAssertEqual(r.classification, .good)
    }

    func testFadingSpeedAtConstantHRDecouples() throws {
        // Speed falls 3.4 -> 2.6 m/s at a flat HR: EF falls in the second half.
        let r = try value(Decoupling.compute(stream(seconds: 3600, speed: { 3.4 - 0.8 * $0 / 3600 }), options: noWarmUp))
        let fade: (Int) -> Double = { i in 3.4 - 0.8 * Double(i) / 3600 }
        let v1: Double = (0..<1800).map(fade).reduce(0, +) / 1800
        let v2: Double = (1800..<3600).map(fade).reduce(0, +) / 1800
        XCTAssertEqual(r.percent, (v1 - v2) / v1 * 100, accuracy: 1e-9)
        XCTAssertEqual(r.classification, .aboveAerobicThreshold) // about 12.5%
    }

    func testUnsortedInputGivesSameResult() throws {
        let s = stream(seconds: 3600, hr: linearHR)
        let a = try value(Decoupling.compute(s))
        let b = try value(Decoupling.compute(s.reversed()))
        XCTAssertEqual(a, b)
    }

    // MARK: Classification

    func testClassificationBoundaries() {
        XCTAssertEqual(DecouplingClass(percent: -3), .good)
        XCTAssertEqual(DecouplingClass(percent: 4.999), .good)
        XCTAssertEqual(DecouplingClass(percent: 5), .moderate)
        XCTAssertEqual(DecouplingClass(percent: 10), .moderate)
        XCTAssertEqual(DecouplingClass(percent: 10.001), .aboveAerobicThreshold)
    }

    func testDriftSizesClassify() throws {
        // HR rise over the hour sets the drift: about 2%, 6.5%, 15%.
        let cases: [(Double, DecouplingClass)] = [(6, .good), (20, .moderate), (50, .aboveAerobicThreshold)]
        for (rise, expected) in cases {
            let r = try value(Decoupling.compute(stream(seconds: 3600, hr: { 140 + rise * $0 / 3600 }), options: noWarmUp))
            XCTAssertEqual(r.classification, expected, "rise \(rise): \(r.percent)%")
        }
    }

    // MARK: Duration

    func testRunUnderFortyMinutesIsRefused() {
        XCTAssertEqual(Decoupling.compute(stream(seconds: 39 * 60)),
                       .failure(.tooShort(movingSeconds: 39 * 60)))
    }

    func testFortyMinutesIsRefusedAndJustOverIsComputed() throws {
        // SPEC 3.3 says "over 40 minutes".
        XCTAssertEqual(Decoupling.compute(stream(seconds: 2400)), .failure(.tooShort(movingSeconds: 2400)))
        let r = try value(Decoupling.compute(stream(seconds: 2401)))
        XCTAssertEqual(r.movingSeconds, 2401)
    }

    func testEmptyAndSingleSampleAreRefused() {
        XCTAssertEqual(Decoupling.compute([]), .failure(.tooShort(movingSeconds: 0)))
        XCTAssertEqual(Decoupling.compute([StreamSample(t: 0, heartRate: 150, speed: 3)]),
                       .failure(.tooShort(movingSeconds: 0)))
    }

    func testLongElapsedButShortMovingIsRefused() {
        // 70 minutes elapsed, 35 of them paused.
        let s = stream(seconds: 70 * 60, moving: { $0 < 35 * 60 })
        XCTAssertEqual(Decoupling.compute(s), .failure(.tooShort(movingSeconds: 35 * 60)))
    }

    // MARK: Pauses

    func testPauseIsExcludedFromTimeAndRatios() throws {
        // 60 minutes moving with a 10-minute pause in the middle. Values during the
        // pause are wild and must not count; HR keeps the moving-time drift.
        let pauseStart = 1800.0, pauseEnd = 2400.0
        let movingT: (Double) -> Double = { t in t < pauseStart ? t : (t < pauseEnd ? pauseStart : t - 600) }
        let s = stream(seconds: 4200,
                       hr: { t in (pauseStart..<pauseEnd).contains(t) ? 95 : self.linearHR(movingT(t)) },
                       speed: { t in (pauseStart..<pauseEnd).contains(t) ? 0 : 3 },
                       moving: { t in !(pauseStart..<pauseEnd).contains(t) })
        let r = try value(Decoupling.compute(s, options: noWarmUp))
        XCTAssertEqual(r.movingSeconds, 3600)
        XCTAssertEqual(r.percent, expectedLinear(lo: 0, hi: 3600), accuracy: 1e-9)
        XCTAssertEqual(r.firstHalfHRCoverage, 1)
        XCTAssertEqual(r.secondHalfHRCoverage, 1)
    }

    // MARK: Gaps

    func testShortGapIsHeld() throws {
        // Drop 20 s of samples (under the 30 s hold): no coverage loss.
        let s = stream(seconds: 3600).filter { !(1001..<1021).contains($0.t) }
        let r = try value(Decoupling.compute(s))
        XCTAssertEqual(r.movingSeconds, 3600)
        XCTAssertEqual(r.firstHalfHRCoverage, 1)
    }

    func testLongGapCountsAsMovingTimeWithoutData() throws {
        // A 2-minute recording gap while moving: moving time is kept, coverage drops.
        let s = stream(seconds: 3600).filter { !(1001..<1121).contains($0.t) }
        let r = try value(Decoupling.compute(s))
        XCTAssertEqual(r.movingSeconds, 3600)
        // Gap is 121 s between samples; 30 s held, 91 s missing, in a 1650 s half.
        XCTAssertEqual(r.firstHalfHRCoverage, 1 - 91.0 / 1650, accuracy: 1e-9)
        XCTAssertEqual(r.secondHalfHRCoverage, 1)
    }

    func testBigGapIsRefused() {
        // A 15-minute recording gap in the second half.
        let s = stream(seconds: 3600).filter { !(2400..<3300).contains($0.t) }
        guard case .failure(.insufficientHeartRate(let c)) = Decoupling.compute(s) else {
            return XCTFail("expected insufficientHeartRate")
        }
        XCTAssertLessThan(c, 0.8)
    }

    func testGapIntoPauseIsNotMovingTime() throws {
        // Recording stops at 50 min, then a paused sample at 70 min, then 10 more
        // minutes moving. The silent stretch ends in a pause, so it isn't moving time.
        var s = stream(seconds: 3000)
        s.append(StreamSample(t: 4200, heartRate: 100, speed: 0, isMoving: false))
        s += (4260...4860).map { StreamSample(t: Double($0), heartRate: 150, speed: 3) }
        let r = try value(Decoupling.compute(s))
        XCTAssertEqual(r.movingSeconds, 3000 + 30 + 600)
    }

    // MARK: Streams at different rates

    func testHREveryFiveSecondsWithOneHertzSpeed() throws {
        // Watch HR every 5 s, nil between; speed every second.
        let mixed = stream(seconds: 3600, hr: { t in Int(t) % 5 == 0 ? self.linearHR(t) : nil })
        let aligned = stream(seconds: 3600, hr: linearHR).filter { Int($0.t) % 5 == 0 }
        let m = try value(Decoupling.compute(mixed))
        let a = try value(Decoupling.compute(aligned))
        XCTAssertEqual(m.firstHalfHRCoverage, 1)
        XCTAssertEqual(m.secondHalfHRCoverage, 1)
        XCTAssertEqual(m.percent, a.percent, accuracy: 1e-9)
        XCTAssertEqual(m.movingSeconds, 3600)
    }

    func testOffsetTimestampsLineUp() throws {
        // HR on whole seconds, speed half a second later, never on the same sample.
        var s = (0...3600).map { StreamSample(t: Double($0), heartRate: linearHR(Double($0))) }
        s += (0..<3600).map { StreamSample(t: Double($0) + 0.5, speed: 3) }
        let r = try value(Decoupling.compute(s))
        XCTAssertEqual(r.firstHalfHRCoverage, 1)
        XCTAssertEqual(r.secondHalfHRCoverage, 1)
        XCTAssertEqual(r.percent, expectedLinear(lo: 300, hi: 3600), accuracy: 1e-9)
    }

    func testOneStreamSilentWhileTheOtherContinues() throws {
        // HR silent for 2 minutes while speed keeps arriving at 1 Hz: HR is held
        // 30 s from its last reading, then missing until it returns.
        let s = stream(seconds: 3600, hr: { t in (1001...1120).contains(Int(t)) ? nil : 150 })
        let r = try value(Decoupling.compute(s))
        XCTAssertEqual(r.movingSeconds, 3600)
        XCTAssertEqual(r.firstHalfHRCoverage, 1 - 91.0 / 1650, accuracy: 1e-9)
        XCTAssertEqual(r.secondHalfHRCoverage, 1)

        // Speed silent for 15 minutes instead: HR coverage stays full, but the
        // paired coverage fails.
        let noSpeed = stream(seconds: 3600, speed: { t in (2400..<3300).contains(t) ? nil : 3 })
        guard case .failure(.insufficientOutput(let c)) = Decoupling.compute(noSpeed) else {
            return XCTFail("expected insufficientOutput")
        }
        XCTAssertEqual(c, 1 - 871.0 / 1650, accuracy: 1e-9)
    }

    func testDuplicateTimestampsMergeRegardlessOfOrder() throws {
        // A paused duplicate at t = 2000 wins over the moving sample there, in
        // either input order; its wild values are not used.
        let base = stream(seconds: 3600, hr: linearHR)
        let dup = StreamSample(t: 2000, heartRate: 90, speed: 0.5, isMoving: false)
        var before = base, after = base
        before.insert(dup, at: 2000)
        after.insert(dup, at: 2001)
        let a = try value(Decoupling.compute(before))
        let b = try value(Decoupling.compute(after))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.movingSeconds, 3599)

        // Two moving duplicates average their values.
        var two = stream(seconds: 3600)
        two.insert(StreamSample(t: 1000, heartRate: 170, speed: 3), at: 1000)
        let points = Decoupling.points(two, basis: .pace, options: .default)
        XCTAssertEqual(points.count, 3601)
        XCTAssertEqual(points[1000].heartRate, 160)
    }

    // MARK: Missing HR

    func testSomeMissingHRStillComputes() throws {
        // HR missing for 3 minutes of every 30: 90% coverage.
        let s = stream(seconds: 3600, hr: { t in t.truncatingRemainder(dividingBy: 1800) < 180 ? nil : 150 })
        let r = try value(Decoupling.compute(s, options: noWarmUp))
        XCTAssertEqual(r.firstHalfHRCoverage, 0.9, accuracy: 1e-9)
        XCTAssertEqual(r.percent, 0, accuracy: 1e-9)
    }

    func testTooMuchMissingHRInOneHalfIsRefused() {
        // HR missing for the last 25% of the run's first half only: the reading at
        // 1320 s is held to 1350 s, then nothing until 1800 s.
        let s = stream(seconds: 3600, hr: { t in (1321..<1800).contains(t) ? nil : 150 })
        XCTAssertEqual(Decoupling.compute(s, options: noWarmUp),
                       .failure(.insufficientHeartRate(coverage: 0.75)))
    }

    func testCoverageBoundaryIsInclusive() throws {
        // Exactly 80% coverage in the first half passes (reading at 1410 s held to 1440 s).
        let s = stream(seconds: 3600, hr: { t in (1411..<1800).contains(t) ? nil : 150 })
        let r = try value(Decoupling.compute(s, options: noWarmUp))
        XCTAssertEqual(r.firstHalfHRCoverage, 0.8, accuracy: 1e-12)
    }

    func testNoHRAtAllIsRefused() {
        XCTAssertEqual(Decoupling.compute(stream(seconds: 3600, hr: { _ in nil })),
                       .failure(.insufficientHeartRate(coverage: 0)))
    }

    func testMissingSpeedIsRefusedAsOutput() {
        XCTAssertEqual(Decoupling.compute(stream(seconds: 3600, speed: { _ in nil })),
                       .failure(.insufficientOutput(coverage: 0)))
    }

    // MARK: Bad values

    func testNonFiniteAndImplausibleValuesAreMissing() throws {
        // Every 10th second has a bad HR and every 10th (offset) a bad speed; the
        // neighbours' readings are held over them, so they cost no coverage and
        // never enter the ratio. A 100-second run of NaN HR does cost coverage.
        let badHR: [Double] = [.nan, .infinity, 0, 300]
        let s = stream(seconds: 3600,
                       hr: { t in
                           if (1000..<1100).contains(t) { return .nan }
                           return Int(t) % 10 == 0 ? badHR[Int(t) / 10 % 4] : 150 },
                       speed: { t in Int(t) % 10 == 5 ? (Int(t) % 20 == 5 ? -.infinity : .nan) : 3 })
        let r = try value(Decoupling.compute(s, options: noWarmUp))
        // Last good HR at 999 s, held to 1029 s; next good reading at 1101 s (72 s).
        // The bad reading at 0 s has nothing before it to hold (1 s).
        XCTAssertEqual(r.firstHalfHRCoverage, 1 - 73.0 / 1800, accuracy: 1e-9)
        XCTAssertEqual(r.secondHalfHRCoverage, 1)
        XCTAssertEqual(r.firstHalfEF, 3.0 / 150, accuracy: 1e-12)
        XCTAssertEqual(r.percent, 0, accuracy: 1e-9)
    }

    func testZeroSpeedWhileMovingIsNotUsable() {
        XCTAssertEqual(Decoupling.compute(stream(seconds: 3600, speed: { _ in 0 })),
                       .failure(.insufficientOutput(coverage: 0)))
    }

    func testNonFiniteTimestampsAreDropped() throws {
        var s = stream(seconds: 3600, hr: linearHR)
        s.insert(StreamSample(t: .nan, heartRate: 999, speed: 99), at: 500)
        s.append(StreamSample(t: .infinity, heartRate: 150, speed: 3))
        let r = try value(Decoupling.compute(s))
        XCTAssertEqual(r.percent, expectedLinear(lo: 300, hi: 3600), accuracy: 1e-9)
        XCTAssertEqual(r.movingSeconds, 3600)
    }

    func testInvalidOptionsAreRefused() {
        let bad: [DecouplingOptions] = [
            DecouplingOptions(minimumMovingSeconds: .nan),
            DecouplingOptions(warmUpSeconds: .infinity),
            DecouplingOptions(warmUpSeconds: .nan),
            DecouplingOptions(warmUpSeconds: -60),
            DecouplingOptions(minimumCoverage: 1.5),
            DecouplingOptions(maximumHoldSeconds: .nan),
            DecouplingOptions(maximumHoldSeconds: 0),
            DecouplingOptions(maximumHoldSeconds: -0.0),
            DecouplingOptions(maximumHoldSeconds: -5),
            DecouplingOptions(maximumHoldSeconds: .infinity),
            DecouplingOptions(maximumSpeedCV: .infinity),
        ]
        for opts in bad {
            XCTAssertFalse(opts.isValid)
            XCTAssertEqual(Decoupling.compute(stream(seconds: 3600), options: opts), .failure(.invalidOptions))
            XCTAssertNil(Decoupling.isSteady(stream(seconds: 3600), options: opts))
        }
        XCTAssertTrue(DecouplingOptions.default.isValid)
    }

    func testSmallestPositiveHoldIsValid() {
        let opts = DecouplingOptions(maximumHoldSeconds: 1e-3)
        XCTAssertTrue(opts.isValid)
        XCTAssertNotEqual(Decoupling.compute(stream(seconds: 3600), options: opts), .failure(.invalidOptions))
    }

    // MARK: Power-to-HR

    func testPowerToHRMatchesPaceForConstantOutput() throws {
        let s = stream(seconds: 3600, hr: linearHR, speed: { _ in nil }, power: { _ in 260 })
        let r = try value(Decoupling.compute(s, basis: .power))
        XCTAssertEqual(r.basis, .power)
        XCTAssertEqual(r.percent, expectedLinear(lo: 300, hi: 3600), accuracy: 1e-9)
        // The pace path has no speed here and refuses.
        XCTAssertEqual(Decoupling.compute(s, basis: .pace), .failure(.insufficientOutput(coverage: 0)))
    }

    func testPowerPathIgnoresSpeed() throws {
        // Speed fades (e.g. uphill finish) but power and HR are flat: no power decoupling.
        let s = stream(seconds: 3600, speed: { 3.3 - 0.6 * $0 / 3600 }, power: { _ in 250 })
        let p = try value(Decoupling.compute(s, basis: .power))
        XCTAssertEqual(p.percent, 0, accuracy: 1e-9)
        let v = try value(Decoupling.compute(s, basis: .pace))
        XCTAssertGreaterThan(v.percent, 5)
    }

    func testMissingPowerIsRefused() {
        XCTAssertEqual(Decoupling.compute(stream(seconds: 3600), basis: .power),
                       .failure(.insufficientOutput(coverage: 0)))
    }

    // MARK: Steady-run check

    func testResultCarriesSteadyFlag() throws {
        let steady = try value(Decoupling.compute(stream(seconds: 3600)))
        XCTAssertEqual(steady.isSteady, true)
        XCTAssertEqual(try XCTUnwrap(steady.speedCoefficientOfVariation), 0, accuracy: 1e-12)
        // Intervals still compute (no refusal) but are flagged as not steady.
        let reps = try value(Decoupling.compute(stream(seconds: 3600, speed: { Int($0) / 120 % 2 == 0 ? 2.5 : 4.5 })))
        XCTAssertEqual(reps.isSteady, false)
        // Power basis still reports speed steadiness.
        let power = try value(Decoupling.compute(stream(seconds: 3600, power: { _ in 250 }), basis: .power))
        XCTAssertEqual(power.isSteady, true)
    }

    func testConstantSpeedIsSteady() throws {
        let cv = try XCTUnwrap(Decoupling.speedCoefficientOfVariation(stream(seconds: 3600)))
        XCTAssertEqual(cv, 0, accuracy: 1e-12)
        XCTAssertEqual(Decoupling.isSteady(stream(seconds: 3600)), true)
    }

    func testIntervalsAreNotSteady() throws {
        // Alternating 2 minutes at 2.5 m/s and 2 minutes at 4.5 m/s: CV = 1/3.5.
        let s = stream(seconds: 3600, speed: { Int($0) / 120 % 2 == 0 ? 2.5 : 4.5 })
        let cv = try XCTUnwrap(Decoupling.speedCoefficientOfVariation(s, options: noWarmUp))
        XCTAssertEqual(cv, 1 / 3.5, accuracy: 1e-9)
        XCTAssertEqual(Decoupling.isSteady(s), false)
    }

    func testGentleDriftIsSteady() {
        XCTAssertEqual(Decoupling.isSteady(stream(seconds: 3600, speed: { 3.1 - 0.2 * $0 / 3600 })), true)
    }

    func testSteadyCheckIgnoresPauses() {
        let s = stream(seconds: 4200,
                       speed: { (1800..<2400).contains($0) ? 0.2 : 3 },
                       moving: { !(1800..<2400).contains($0) })
        XCTAssertEqual(Decoupling.isSteady(s), true)
    }

    func testSteadyCheckNeedsSpeed() {
        XCTAssertNil(Decoupling.speedCoefficientOfVariation(stream(seconds: 3600, speed: { _ in nil })))
        XCTAssertNil(Decoupling.isSteady([]))
    }
}
