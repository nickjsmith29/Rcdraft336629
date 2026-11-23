import XCTest
@testable import CoachCore

/// SPEC.md 3.9 (threshold method), 3.2 (LTHR). Every run here is synthetic:
/// an invented runner with an invented LTHR, 1 Hz samples, and expected
/// values worked out by hand from the segment definitions.
final class PaceAtLTHRTests: XCTestCase {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let lthr = 165.0

    /// One run: `warmUp` s easy, `tempo` s at the tempo HR and speed, `coolDown`
    /// s easy. Functions take seconds since the tempo began.
    func makeRun(id: String = "r1",
             daysAgo: Double = 5,
             warmUp: Int = 600,
             tempo: Int = 1200,
             coolDown: Int = 600,
             hr: @escaping (Double) -> Double? = { _ in 165 },
             speed: @escaping (Double) -> Double? = { _ in 4.0 },
             altitude: @escaping (_ tempoSeconds: Double, _ tempoMeters: Double) -> Double? = { _, _ in 50 },
             moving: @escaping (Double) -> Bool = { _ in true },
             sport: Activity.Sport = .run,
             treadmill: Bool? = nil) -> Activity {
        let total = warmUp + tempo + coolDown
        var meters = 0.0
        let samples: [StreamSample] = (0...total).map { i in
            let t = Double(i)
            let inTempo = i >= warmUp && i < warmUp + tempo
            let k = t - Double(warmUp)
            let v = inTempo ? speed(k) : 3.0
            let sample = StreamSample(t: t,
                                      heartRate: inTempo ? hr(k) : 140,
                                      speed: v,
                                      altitude: inTempo ? altitude(k, meters) : 50,
                                      isMoving: inTempo ? moving(k) : true)
            if inTempo { meters += v ?? 0 }
            return sample
        }
        return Activity(id: id, source: .healthKit, sport: sport, start: now.addingTimeInterval(-daysAgo * 86_400),
                        durationSeconds: Double(total), sourceSaysTreadmill: treadmill, samples: samples)
    }

    func measure(_ runs: [Activity], options: PaceAtLTHROptions = .default) -> Result<PaceAtLTHR, PaceAtLTHRRefusal> {
        PaceAtLTHRMeter.measure(history: HistoryCleanup.clean(runs), lthr: lthr, asOf: now, options: options)
    }

    func scan(_ r: Result<PaceAtLTHR, PaceAtLTHRRefusal>, file: StaticString = #filePath, line: UInt = #line) -> LTHRPaceScan? {
        if case .failure(.noQualifyingStretch(let scan)) = r { return scan }
        XCTFail("expected noQualifyingStretch, got \(r)", file: file, line: line)
        return nil
    }

    // MARK: Qualifying stretches

    func testFlatSteadyTempoGivesItsPaceWithEvidence() throws {
        let r = try measure([makeRun()]).get()
        // Tempo [600, 1800) on the moving clock; the first 120 s settle, so 1080 s at 4 m/s.
        XCTAssertEqual(r.secondsPerMeter, 0.25, accuracy: 1e-12)
        XCTAssertEqual(r.stretches.count, 1)
        let s = try XCTUnwrap(r.stretches.first)
        XCTAssertEqual(s.activityID, "r1")
        XCTAssertEqual(s.seconds, 1080, accuracy: 1e-9)
        XCTAssertEqual(s.meters, 4320, accuracy: 1e-9)
        XCTAssertEqual(s.averageHeartRate, 165, accuracy: 1e-9)
        XCTAssertEqual(s.heartRateDrift, 0, accuracy: 1e-12)
        XCTAssertEqual(s.paceDrift, 0, accuracy: 1e-12)
        XCTAssertEqual(s.maximumAbsoluteGrade, 0, accuracy: 1e-12)
        XCTAssertEqual(s.start, now.addingTimeInterval(-5 * 86_400 + 720))
        XCTAssertEqual(r.totalSeconds, 1080, accuracy: 1e-9)
        XCTAssertEqual(r.totalMeters, 4320, accuracy: 1e-9)
        XCTAssertEqual(r.dateRange, s.start...s.start)
        XCTAssertEqual(r.paceSpread.lowerBound, 0.25, accuracy: 1e-12)
        XCTAssertEqual(r.paceSpread.upperBound, 0.25, accuracy: 1e-12)
        XCTAssertEqual(r.lthr, lthr)
        XCTAssertFalse(r.isCorroborated)
        XCTAssertEqual(r.scan.runsScanned, 1)
        XCTAssertEqual(r.scan.rejected, [])
    }

    func testTwoRunsArePooledByTimeAndCorroborate() throws {
        let a = makeRun(id: "a", daysAgo: 20)
        let b = makeRun(id: "b", daysAgo: 3, speed: { _ in 3.6 })
        let r = try measure([b, a]).get()
        // 1080 s at 4.0 m/s (4320 m) and 1080 s at 3.6 m/s (3888 m): 2160 / 8208.
        XCTAssertEqual(r.secondsPerMeter, 2160.0 / 8208.0, accuracy: 1e-12)
        XCTAssertEqual(r.activityIDs, ["a", "b"])
        XCTAssertTrue(r.isCorroborated)
        XCTAssertEqual(r.paceSpread.lowerBound, 0.25, accuracy: 1e-12)
        XCTAssertEqual(r.paceSpread.upperBound, 1 / 3.6, accuracy: 1e-12)
        XCTAssertEqual(r.dateRange.lowerBound, now.addingTimeInterval(-20 * 86_400 + 720))
        XCTAssertEqual(r.dateRange.upperBound, now.addingTimeInterval(-3 * 86_400 + 720))
    }

    func testDuplicateImportCountsOnceAndDoesNotCorroborate() throws {
        let watch = makeRun(id: "watch")
        var copy = watch
        copy.id = "strava-copy"
        copy.source = .strava
        let r = try measure([watch, copy]).get()
        XCTAssertEqual(r.stretches.count, 1)
        XCTAssertEqual(r.activityIDs.count, 1)
        XCTAssertFalse(r.isCorroborated)
        XCTAssertEqual(r.totalSeconds, 1080, accuracy: 1e-9)
    }

    func testHeartRateAnywhereInTheBandCounts() throws {
        // 97% and 103% of 165 are 160.05 and 169.95; 160.5 and 169.5 are inside.
        XCTAssertNoThrow(try measure([makeRun(hr: { _ in 160.5 })]).get())
        XCTAssertNoThrow(try measure([makeRun(hr: { _ in 169.5 })]).get())
        // 159 and 171 are outside: nothing touches the band.
        for bpm in [159.0, 171.0] {
            XCTAssertEqual(scan(measure([makeRun(hr: { _ in bpm })]))?.rejected, [], "\(bpm)")
        }
    }

    // MARK: No qualifying stretch

    func testEasyRunHasNoQualifyingStretch() {
        let s = scan(measure([makeRun(hr: { _ in 140 })]))
        XCTAssertEqual(s?.runsScanned, 1)
        XCTAssertEqual(s?.rejected, [])
        XCTAssertEqual(s?.treadmillActivityIDs, [])
    }

    func testEmptyInputHasNoQualifyingStretch() {
        XCTAssertEqual(measure([]), .failure(.noQualifyingStretch(LTHRPaceScan(runsScanned: 0, treadmillActivityIDs: [],
                                                                               rejected: []))))
        // A run with no samples at all.
        let bare = Activity(id: "bare", source: .healthKit, start: now.addingTimeInterval(-86_400), durationSeconds: 1800)
        XCTAssertEqual(scan(measure([bare]))?.runsScanned, 1)
    }

    func testRunsOutsideTheWindowWalksAndTreadmillRunsAreLeftOut() {
        let old = makeRun(id: "old", daysAgo: 61)
        let future = makeRun(id: "future", daysAgo: -1)
        let walk = makeRun(id: "walk", sport: .walk)
        let mill = makeRun(id: "mill", treadmill: true)
        let s = scan(measure([old, future, walk, mill]))
        XCTAssertEqual(s?.runsScanned, 0)
        XCTAssertEqual(s?.treadmillActivityIDs, ["mill"])
        // The 60-day edge is inclusive.
        XCTAssertNoThrow(try measure([makeRun(daysAgo: 60)]).get())
    }

    // MARK: Hills

    func testSteadyClimbIsRejectedAsHilly() throws {
        let s = scan(measure([makeRun(altitude: { _, m in 50 + 0.03 * m })]))
        let rejection = try XCTUnwrap(s?.rejected.first)
        guard case .hilly(let grade) = rejection.reason else { return XCTFail("\(rejection.reason)") }
        XCTAssertEqual(grade, 0.03, accuracy: 1e-9)
        XCTAssertEqual(rejection.start, now.addingTimeInterval(-5 * 86_400 + 600))
    }

    func testRollingHillsThatNetToZeroAreRejected() throws {
        // 10 m up and down every 400 m: a 200 m window catches a 20 m swing (10%).
        let s = scan(measure([makeRun(altitude: { _, m in 50 + 10 * sin(2 * .pi * m / 400) })]))
        guard case .hilly(let grade)? = s?.rejected.first?.reason else { return XCTFail("\(String(describing: s))") }
        XCTAssertGreaterThan(grade, 0.05)
    }

    func testShortHillOffsetFromAWindowStartIsCaught() throws {
        // A 200 m climb at 2.5% from 580 m to 780 m into the tempo. The used
        // part starts at 480 m (after 120 s at 4 m/s), so the hill begins 100 m
        // in and straddles where a fixed 200 m window would end.
        let hill: (Double, Double) -> Double? = { _, m in 50 + 0.025 * min(max(m - 580, 0), 200) }
        let s = scan(measure([makeRun(altitude: hill)]))
        guard case .hilly(let grade)? = s?.rejected.first?.reason else { return XCTFail("\(String(describing: s))") }
        XCTAssertEqual(grade, 0.025, accuracy: 1e-9)
        // The same hill at 2% is still caught; at 1% it passes the 1.5% limit.
        let steep2: (Double, Double) -> Double? = { _, m in 50 + 0.02 * min(max(m - 580, 0), 200) }
        guard case .hilly(let g2)? = scan(measure([makeRun(altitude: steep2)]))?.rejected.first?.reason else {
            return XCTFail("2% hill not caught")
        }
        XCTAssertEqual(g2, 0.02, accuracy: 1e-9)
        let gentle: (Double, Double) -> Double? = { _, m in 50 + 0.01 * min(max(m - 580, 0), 200) }
        XCTAssertEqual(try measure([makeRun(altitude: gentle)]).get().stretches.first?.maximumAbsoluteGrade ?? .nan,
                       0.01, accuracy: 1e-9)
    }

    func testGentleGradeUnderTheLimitCounts() throws {
        let r = try measure([makeRun(altitude: { _, m in 50 - 0.01 * m })]).get()
        XCTAssertEqual(r.stretches.first?.maximumAbsoluteGrade ?? .nan, 0.01, accuracy: 1e-9)
    }

    func testStretchShorterThanTheWindowUsesItsEndToEndGrade() throws {
        // A 4 m bump up and back down between 1000 m and 1400 m into the tempo:
        // with the default 200 m window it reads as a 2% climb.
        let bump: (Double, Double) -> Double? = { _, m in 50 + max(0, 4 - abs(m - 1200) / 50) }
        guard case .hilly(let grade)? = scan(measure([makeRun(altitude: bump)]))?.rejected.first?.reason else {
            return XCTFail("bump not caught")
        }
        XCTAssertEqual(grade, 0.02, accuracy: 1e-9)
        // With a window longer than the whole used stretch (4320 m), the grade is
        // measured end to end: the bump nets to zero, so the stretch counts.
        let long = PaceAtLTHROptions(gradeWindowMeters: 10_000)
        XCTAssertEqual(try measure([makeRun(altitude: bump)], options: long).get()
            .stretches.first?.maximumAbsoluteGrade ?? .nan, 0, accuracy: 1e-12)
        // A steady climb measured end to end: from the first reading (480 m in)
        // to the last held reading (4796 m in) over the 4320 m covered, so a 1%
        // climb reads just under 1% and counts, and a 2% climb is rejected.
        XCTAssertEqual(try measure([makeRun(altitude: { _, m in 50 + 0.01 * m })], options: long).get()
            .stretches.first?.maximumAbsoluteGrade ?? .nan, 0.01 * 4316 / 4320, accuracy: 1e-9)
        guard case .hilly(let g2)? = scan(measure([makeRun(altitude: { _, m in 50 + 0.02 * m })],
                                                  options: long))?.rejected.first?.reason else {
            return XCTFail("2% climb not caught end to end")
        }
        XCTAssertEqual(g2, 0.02 * 4316 / 4320, accuracy: 1e-9)
    }

    /// Pins today's behaviour (no smoothing): one noisy altitude sample on a flat
    /// stretch sets the steepest 200 m window. At 4 m/s the windows ending at and
    /// starting from the spike span exactly 200 m, so a spike of h meters reads as
    /// h / 200. Change this test deliberately if altitude smoothing is added.
    func testOneSampleAltitudeSpikeSetsTheGrade() throws {
        func spike(_ height: Double) -> Activity {
            makeRun(altitude: { k, _ in k == 600 ? 50 + height : 50 })
        }
        // A 5 m spike reads as 2.5%, over the 1.5% limit: the flat stretch is rejected.
        let s = scan(measure([spike(5)]))
        let rejection = try XCTUnwrap(s?.rejected.first)
        XCTAssertEqual(s?.rejected.count, 1)
        guard case .hilly(let grade) = rejection.reason else { return XCTFail("\(rejection.reason)") }
        XCTAssertEqual(grade, 0.025, accuracy: 1e-9)
        // A downward spike counts the same.
        guard case .hilly(let down)? = scan(measure([spike(-5)]))?.rejected.first?.reason else {
            return XCTFail("downward spike not caught")
        }
        XCTAssertEqual(down, 0.025, accuracy: 1e-9)
        // A 2 m spike reads as 1% and the stretch still counts, with that grade.
        let r = try measure([spike(2)]).get()
        XCTAssertEqual(r.stretches.first?.maximumAbsoluteGrade ?? .nan, 0.01, accuracy: 1e-9)
        XCTAssertEqual(r.totalSeconds, 1080, accuracy: 1e-9)
    }

    func testMissingAltitudeCannotProveFlatness() {
        XCTAssertEqual(scan(measure([makeRun(altitude: { _, _ in nil })]))?.rejected.map(\.reason), [.noElevation])
    }

    // MARK: Drift and steadiness

    func testHeartRateDriftIsRejected() throws {
        // 160.5 to 169.5 bpm over the tempo, inside the band throughout. Used
        // time [120, 1200): half means 163.425 and 167.475, a 2.48% rise.
        let s = scan(measure([makeRun(hr: { k in 160.5 + 9 * k / 1200 })]))
        guard case .heartRateDrift(let f)? = s?.rejected.first?.reason else { return XCTFail("\(String(describing: s))") }
        XCTAssertEqual(f, 167.475 / 163.425 - 1, accuracy: 1e-4)
    }

    func testPaceDriftIsRejected() throws {
        // Speed falls from 4.0 to 3.7 m/s at a steady heart rate: half means
        // 3.9025 and 3.7675 m/s, so pace slowed 3.58%.
        let s = scan(measure([makeRun(speed: { k in 4.0 - 0.3 * k / 1200 })]))
        guard case .paceDrift(let f)? = s?.rejected.first?.reason else { return XCTFail("\(String(describing: s))") }
        XCTAssertEqual(f, 3.9025 / 3.7675 - 1, accuracy: 1e-4)
    }

    func testSurgesAtAnInBandHeartRateAreUnsteady() throws {
        // 30 s at 3.4 m/s, 30 s at 4.6 m/s: CV is 0.6 / 4.0 = 0.15.
        let s = scan(measure([makeRun(speed: { k in Int(k / 30).isMultiple(of: 2) ? 3.4 : 4.6 })]))
        guard case .unsteadyPace(let cv)? = s?.rejected.first?.reason else { return XCTFail("\(String(describing: s))") }
        XCTAssertEqual(cv, 0.15, accuracy: 1e-9)
    }

    // MARK: Duration and continuity

    func testStretchUnderTheMinimumIsRejected() throws {
        // 9 minutes at LTHR: 7 minutes left after settling, under 8.
        let s = scan(measure([makeRun(tempo: 540)]))
        XCTAssertEqual(s?.rejected.map(\.reason), [.tooShort(seconds: 420)])
        // Exactly 10 minutes leaves exactly the minimum, which counts.
        XCTAssertEqual(try measure([makeRun(tempo: 600)]).get().totalSeconds, 480, accuracy: 1e-9)
    }

    func testBriefTouchOfTheBandIsNotListed() {
        XCTAssertEqual(scan(measure([makeRun(tempo: 90)]))?.rejected, [])
    }

    func testBriefExcursionIsBridgedAndLeftOutOfTheAverages() throws {
        // 10 s at 180 bpm in the middle: bridged, not counted.
        let r = try measure([makeRun(hr: { k in (600..<610).contains(k) ? 180 : 165 })]).get()
        XCTAssertEqual(r.stretches.count, 1)
        XCTAssertEqual(r.totalSeconds, 1070, accuracy: 1e-9)
        XCTAssertEqual(r.stretches.first?.averageHeartRate ?? .nan, 165, accuracy: 1e-9)
    }

    func testLongExcursionSplitsTheStretch() throws {
        // 30 s out of the band at 600 s splits it into [0, 600) and [630, 1200):
        // 480 s and 450 s after settling; the second is too short.
        let r = try measure([makeRun(hr: { k in (600..<630).contains(k) ? 180 : 165 })]).get()
        XCTAssertEqual(r.totalSeconds, 480, accuracy: 1e-9)
        XCTAssertEqual(r.scan.rejected.map(\.reason), [.tooShort(seconds: 450)])
    }

    func testPauseEndsTheStretch() throws {
        // Paused from 600 s to 659 s of the tempo: the first part is [0, 600)
        // (480 s used); the second starts on the clock again at 660 s, so
        // 540 s long and 420 s after settling.
        let r = try measure([makeRun(moving: { k in !(600..<660).contains(k) })]).get()
        XCTAssertEqual(r.totalSeconds, 480, accuracy: 1e-9)
        let rejected = try XCTUnwrap(r.scan.rejected.first)
        XCTAssertEqual(rejected.reason, .tooShort(seconds: 420))
        XCTAssertEqual(rejected.start, now.addingTimeInterval(-5 * 86_400 + 600 + 660))
    }

    // MARK: Non-finite input

    func testNonFiniteReadingsAreMissingNotZero() throws {
        // NaN heart rate for 10 s and an infinite speed for 5 s are missing
        // readings: the last usable value is held over them (MovingTime rule).
        let r = try measure([makeRun(hr: { k in (300..<310).contains(k) ? .nan : 165 },
                                 speed: { k in (900..<905).contains(k) ? .infinity : 4.0 })]).get()
        XCTAssertEqual(r.totalSeconds, 1080, accuracy: 1e-9)
        XCTAssertEqual(r.secondsPerMeter, 0.25, accuracy: 1e-12)
        // 40 s without heart rate: the reading at 299 s holds until 329 s, then
        // [329, 340) is bridged and left out (11 s).
        let gap = try measure([makeRun(hr: { k in (300..<340).contains(k) ? nil : 165 })]).get()
        XCTAssertEqual(gap.stretches.count, 1)
        XCTAssertEqual(gap.totalSeconds, 1069, accuracy: 1e-9)
        // A sample with a non-finite time is dropped.
        var odd = makeRun()
        odd.samples.append(StreamSample(t: .infinity, heartRate: 165, speed: 4, altitude: 50))
        odd.samples.append(StreamSample(t: .nan, heartRate: 165, speed: 4, altitude: 50))
        XCTAssertEqual(try measure([odd]).get().totalSeconds, 1080, accuracy: 1e-9)
        // No usable heart rate at all.
        XCTAssertEqual(scan(measure([makeRun(hr: { _ in .nan })]))?.rejected, [])
    }

    func testInvalidLTHRAndOptionsAreRefused() {
        for bad in [Double.nan, .infinity, -.infinity, 0, -165, 99, 221] {
            XCTAssertEqual(PaceAtLTHRMeter.measure(history: HistoryCleanup.clean([makeRun()]), lthr: bad, asOf: now),
                           .failure(.invalidLTHR),
                           "\(bad)")
        }
        let bad: [PaceAtLTHROptions] = [
            PaceAtLTHROptions(lookbackDays: 0),
            PaceAtLTHROptions(heartRateBandFraction: .nan),
            PaceAtLTHROptions(heartRateBandFraction: 0),
            PaceAtLTHROptions(settleSeconds: -1),
            PaceAtLTHROptions(minimumSeconds: 0),
            PaceAtLTHROptions(minimumSeconds: .infinity),
            PaceAtLTHROptions(minimumInBandShare: 1.1),
            PaceAtLTHROptions(gradeWindowMeters: 0),
            PaceAtLTHROptions(maximumGrade: .nan),
            PaceAtLTHROptions(maximumHeartRateDrift: -0.01),
            PaceAtLTHROptions(maximumPaceDrift: .infinity),
            PaceAtLTHROptions(maximumSpeedCV: .nan),
            PaceAtLTHROptions(plausibleSpeed: 0...7.5),
        ]
        for o in bad {
            XCTAssertEqual(measure([makeRun()], options: o), .failure(.invalidOptions), "\(o)")
        }
        XCTAssertTrue(PaceAtLTHROptions.default.isValid)
    }

    func testOptionsChangeTheOutcome() throws {
        // A 9-minute tempo counts once the minimum drops to 7 minutes.
        XCTAssertEqual(try measure([makeRun(tempo: 540)], options: PaceAtLTHROptions(minimumSeconds: 420)).get().totalSeconds,
                       420, accuracy: 1e-9)
        // The 3% climb counts with a 4% limit.
        XCTAssertNoThrow(try measure([makeRun(altitude: { _, m in 50 + 0.03 * m })],
                                     options: PaceAtLTHROptions(maximumGrade: 0.04)).get())
    }

    // MARK: Predictor (SPEC.md 3.9 threshold method)

    func testPredictorUsesTheMeasuredPace() throws {
        let pace = try measure([makeRun()]).get()
        let p = BlendedPredictor.predict(targetMeters: Distance.tenK, efforts: [], asOf: now, paceAtLTHR: pace)
        // 0.25 s/m is 14,400 m in an hour; 10K = 3600 * (10000 / 14400)^1.07 = 2436.99 s.
        let estimate = try XCTUnwrap(p.estimates.first { $0.method == .threshold })
        XCTAssertEqual(estimate.seconds, 2436.99, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(p.range).central, 2436.99, accuracy: 0.01)
        XCTAssertFalse(p.skipped.contains { $0.method == .threshold })
        // Same as passing the number directly.
        XCTAssertEqual(p, BlendedPredictor.predict(targetMeters: Distance.tenK, efforts: [], asOf: now,
                                                   secondsPerMeterAtLTHR: pace.secondsPerMeter))
    }

    func testPredictorSkipsAMissingStaleOrFuturePace() throws {
        let pace = try measure([makeRun(daysAgo: 5)]).get()
        func reason(_ asOf: Date, _ pace: PaceAtLTHR?, lookback: Int = BlendedPredictor.defaultLookbackDays) -> SkipReason? {
            BlendedPredictor.predict(targetMeters: Distance.tenK, efforts: [], asOf: asOf, lookbackDays: lookback,
                                     paceAtLTHR: pace).skipped.first { $0.method == .threshold }?.reason
        }
        XCTAssertEqual(reason(now, nil), .missingInput)
        // 125 days later the stretch (5 days before now) is past the 120-day window.
        XCTAssertEqual(reason(now.addingTimeInterval(125 * 86_400), pace), .missingInput)
        XCTAssertNil(reason(now.addingTimeInterval(114 * 86_400), pace))
        // Predicting as of a date before the stretch.
        XCTAssertEqual(reason(now.addingTimeInterval(-10 * 86_400), pace), .missingInput)
        XCTAssertEqual(reason(now, pace, lookback: 0), .missingInput)
    }

    func testPredictorWithShortLookbackSkipsAPaceWithOlderStretches() throws {
        // Stretches 50 and 5 days old (measured over the default 60 days).
        let pace = try measure([makeRun(id: "old", daysAgo: 50), makeRun(id: "new", daysAgo: 5)]).get()
        func reason(_ lookback: Int, _ pace: PaceAtLTHR) -> SkipReason? {
            BlendedPredictor.predict(targetMeters: Distance.tenK, efforts: [], asOf: now, lookbackDays: lookback,
                                     paceAtLTHR: pace).skipped.first { $0.method == .threshold }?.reason
        }
        // A 30-day predictor window excludes the 50-day stretch, so the pooled pace isn't used.
        XCTAssertEqual(reason(30, pace), .missingInput)
        XCTAssertNil(reason(60, pace))
        // Measured with the same 30-day lookback, the pace is current and counts.
        let recent = try measure([makeRun(id: "old", daysAgo: 50), makeRun(id: "new", daysAgo: 5)],
                                 options: PaceAtLTHROptions(lookbackDays: 30)).get()
        XCTAssertEqual(recent.activityIDs, ["new"])
        XCTAssertNil(reason(30, recent))
    }

    func testPredictorSkipsThresholdForTheMarathon() throws {
        let pace = try measure([makeRun()]).get()
        let p = BlendedPredictor.predict(targetMeters: Distance.marathon, efforts: [], asOf: now, paceAtLTHR: pace)
        XCTAssertEqual(p.skipped.first { $0.method == .threshold }?.reason, .notUsedForMarathon)
    }
}
