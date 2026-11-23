import XCTest
@testable import CoachCore

// Edge cases for BaselineBuilder. All runs and readings are synthetic.

private let utc = TimeZone(identifier: "UTC")!
private let newYork = TimeZone(identifier: "America/New_York")!
/// Monday 2026-06-01 00:00 UTC.
private let monday = Date(timeIntervalSince1970: 1_780_272_000)

private func at(day d: Double, hour h: Double = 7) -> Date {
    monday.addingTimeInterval(d * 86_400 + h * 3600)
}

/// Samples every `step` seconds from 0 through `seconds`; closures give each stream at time t.
private func makeRun(_ id: String,
                     start: Date,
                     seconds: Double = 1800,
                     step: Double = 5,
                     speed: @escaping (Double) -> Double? = { _ in 3 },
                     hr: @escaping (Double) -> Double? = { _ in 140 },
                     cadence: @escaping (Double) -> Double? = { _ in 170 },
                     distanceFromSpeed: Bool = true,
                     averageHR: Double? = nil,
                     averageCadence: Double? = nil,
                     indoor: Bool? = nil) -> Activity {
    var ts = Array(stride(from: 0.0, to: seconds, by: step))
    ts.append(seconds)
    var d = 0.0
    var prev = 0.0
    let samples: [StreamSample] = ts.map { t in
        if let v = speed(prev) { d += v * (t - prev) }
        prev = t
        return StreamSample(t: t, heartRate: hr(t), speed: speed(t), cadence: cadence(t),
                            distance: distanceFromSpeed ? d : nil)
    }
    return Activity(id: id, source: .healthKit, start: start, durationSeconds: seconds,
                    distanceMeters: distanceFromSpeed ? d : nil, isIndoor: indoor, hasRoute: indoor == true ? false : nil,
                    averageHeartRate: averageHR, averageCadence: averageCadence, samples: samples)
}

private func build(_ runs: [Activity],
                   efforts: [EffortMark] = [],
                   health: [DailyHealthSample] = [],
                   asOf: Date = at(day: 30, hour: 12),
                   timeZone: TimeZone = utc,
                   configure: (inout BaselineOptions) -> Void = { _ in }) -> BaselineReport {
    var opts = BaselineOptions(asOf: asOf, timeZone: timeZone)
    configure(&opts)
    return BaselineBuilder.build(activities: runs, efforts: efforts, dailyHealth: health, options: opts)
}

final class BaselineBuilderInputTests: XCTestCase {
    func testEmptyHistorySaysWhyForEverySection() {
        let r = build([])
        XCTAssertEqual(r.weeklyLoad.insufficiency?.reason, .noRuns)
        XCTAssertEqual(r.longRuns.insufficiency?.reason, .noRuns)
        XCTAssertEqual(r.bestEfforts.insufficiency?.reason, .noRuns)
        XCTAssertEqual(r.lthr.insufficiency?.reason, .noMarkedEfforts)
        XCTAssertEqual(r.peakHeartRate.insufficiency?.reason, .noRuns)
        XCTAssertEqual(r.easyPace.insufficiency?.reason, .needsLTHR)
        XCTAssertEqual(r.decoupling.insufficiency?.reason, .noRuns)
        XCTAssertEqual(r.cadence.insufficiency?.reason, .noRuns)
        XCTAssertEqual(r.restingHeartRate.insufficiency?.reason, .noReadings)
        XCTAssertEqual(r.hrv.insufficiency?.reason, .noReadings)
    }

    func testNonFiniteAsOfIsInvalidInput() {
        let r = build([makeRun("a", start: at(day: 1))], asOf: Date(timeIntervalSinceReferenceDate: .nan))
        let bad = BaselineValue<WeeklyLoadBaseline>.insufficient(InsufficientData(.invalidInput))
        XCTAssertEqual(r.weeklyLoad, bad)
        XCTAssertEqual(r.hrv.insufficiency?.reason, .invalidInput)
        XCTAssertEqual(r.history.activities.map(\.id), ["a"], "history is still cleaned")
    }

    func testInvalidOptionsAreInvalidInput() {
        for configure: (inout BaselineOptions) -> Void in [
            { $0.currentLoadWeeks = 0 }, { $0.recentDays = -1 }, { $0.normalRangeSD = .nan },
            { $0.bestEffortDistances = [5000, .infinity] }, { $0.peakHoldSeconds = 0 },
            { $0.decoupling.minimumCoverage = 2 }, { $0.minimumHeartRateCoverage = 1.5 },
            { $0.loadWindowWeeks = .max }, { $0.healthWindowDays = .max }, { $0.recentDays = .max },
            { $0.loadWindowWeeks = BaselineOptions.maximumLoadWindowWeeks + 1 },
        ] {
            let r = build([makeRun("a", start: at(day: 1))], configure: configure)
            XCTAssertEqual(r.decoupling.insufficiency?.reason, .invalidInput)
            XCTAssertEqual(r.cadence.insufficiency?.reason, .invalidInput)
        }
    }

    func testFutureAndNonRunActivitiesAreIgnored() {
        var walk = makeRun("walk", start: at(day: 2))
        walk.sport = .walk
        let r = build([walk, makeRun("future", start: at(day: 40))])
        XCTAssertEqual(r.weeklyLoad.insufficiency?.reason, .noRuns)
    }
}

final class BaselineWeeklyLoadTests: XCTestCase {
    func testWeeksStartMondayInTheCallersTimeZone() throws {
        // Sunday 23:30 New York is Monday 03:30 UTC.
        let lateSunday = Date(timeIntervalSince1970: 1_780_272_000 + 6 * 86_400 + 27.5 * 3600)
        let runs = [makeRun("mon", start: at(day: 0, hour: 14)), makeRun("late", start: lateSunday)]
        let asOf = at(day: 14, hour: 18)
        let ny = try XCTUnwrap(build(runs, asOf: asOf, timeZone: newYork).weeklyLoad.value)
        let gmt = try XCTUnwrap(build(runs, asOf: asOf, timeZone: utc).weeklyLoad.value)
        XCTAssertEqual(ny.weeks.first?.activityIDs, ["mon", "late"])
        XCTAssertEqual(gmt.weeks.first?.activityIDs, ["mon"])
        XCTAssertEqual(gmt.weeks[1].activityIDs, ["late"])
        XCTAssertEqual(gmt.weeks.first?.weekStart, monday)
    }

    func testDaylightSavingWeekAndYearBoundary() throws {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = newYork
        func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 7) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
        }
        // DST ends Sunday 2026-11-01 in New York: that week is 169 hours long.
        let dst = [makeRun("mon", start: local(2026, 10, 26)), makeRun("sun", start: local(2026, 11, 1, 22)),
                   makeRun("next", start: local(2026, 11, 2, 0))]
        let fall = try XCTUnwrap(build(dst, asOf: local(2026, 11, 4), timeZone: newYork).weeklyLoad.value)
        XCTAssertEqual(fall.weeks.map(\.activityIDs), [["mon", "sun"], ["next"]])
        XCTAssertEqual(fall.weeks[0].weekStart, local(2026, 10, 26, 0))
        XCTAssertEqual(fall.weeks[0].weekEnd.timeIntervalSince(fall.weeks[0].weekStart), 169 * 3600)
        XCTAssertEqual(fall.weeks[0].weekEnd, fall.weeks[1].weekStart)

        // ISO week 53 of 2026 runs Monday 2026-12-28 to Sunday 2027-01-03.
        let year = [makeRun("dec28", start: local(2026, 12, 28)), makeRun("jan3", start: local(2027, 1, 3, 20)),
                    makeRun("jan4", start: local(2027, 1, 4))]
        let ny = try XCTUnwrap(build(year, asOf: local(2027, 1, 6), timeZone: newYork).weeklyLoad.value)
        XCTAssertEqual(ny.weeks.map(\.activityIDs), [["dec28", "jan3"], ["jan4"]])
        XCTAssertEqual(ny.weeks[1].weekStart, local(2027, 1, 4, 0))
        XCTAssertEqual(ny.basisWeekStarts, [local(2026, 12, 28, 0)])
    }

    func testRunEntriesCarryWhatThePlanBuilderNeeds() {
        let tm = makeRun("tm", start: at(day: 10), indoor: true)
        let race = makeRun("race", start: at(day: 12), seconds: 2700, distanceFromSpeed: false)
        var walk = makeRun("walk", start: at(day: 13)); walk.sport = .walk
        let r = build([race, tm, walk, makeRun("later", start: at(day: 31))],
                      efforts: [EffortMark(activityID: "race", kind: .race)])
        XCTAssertEqual(r.runs, [
            BaselineRun(activityID: "tm", start: at(day: 10), movingSeconds: 1800, movingTimeIsKnown: true, distanceMeters: 5400,
                        isTreadmill: true, markedEffort: nil),
            BaselineRun(activityID: "race", start: at(day: 12), movingSeconds: 2700, movingTimeIsKnown: true, distanceMeters: nil,
                        isTreadmill: false, markedEffort: .race),
        ])
    }

    func testWindowStartsAtFirstRunAndCountsEmptyWeeksAsZero() throws {
        // Runs in weeks 1 and 3 only; asOf in week 4.
        let runs = [makeRun("a", start: at(day: 8)), makeRun("b", start: at(day: 22))]
        let load = try XCTUnwrap(build(runs, asOf: at(day: 30)).weeklyLoad.value)
        XCTAssertEqual(load.weeks.map(\.weekStart).first, at(day: 7, hour: 0))
        XCTAssertEqual(load.weeks.map(\.runCount), [1, 0, 1, 0])
        XCTAssertEqual(load.basisWeekStarts, [at(day: 7, hour: 0), at(day: 14, hour: 0), at(day: 21, hour: 0)])
        XCTAssertEqual(load.currentWeeklyMovingSeconds, 2 * 1800 / 3, accuracy: 1e-9)
    }

    func testOnlyTheCurrentWeekIsNoCompleteWeek() {
        let r = build([makeRun("a", start: at(day: 28))], asOf: at(day: 30))
        XCTAssertEqual(r.weeklyLoad.insufficiency?.reason, .noCompleteWeek)
        XCTAssertEqual(r.longRuns.insufficiency?.reason, .noCompleteWeek)
    }

    func testRunsWithoutDistanceMakeDistanceALowerBound() throws {
        let runs = [makeRun("a", start: at(day: 15)), makeRun("b", start: at(day: 16), distanceFromSpeed: false)]
        let load = try XCTUnwrap(build(runs).weeklyLoad.value)
        XCTAssertFalse(load.distanceIsComplete)
        XCTAssertEqual(load.weeks.first?.runsWithoutDistance, ["b"])
    }

    func testMovingTimeLeavesOutPauses() throws {
        // 30 min with a 10-minute stop in the middle: 20 min of moving time.
        var run = makeRun("a", start: at(day: 15))
        run.samples = run.samples.map { s in
            var s = s; s.isMoving = !(s.t >= 600 && s.t < 1200); return s
        }
        let long = try XCTUnwrap(build([run]).longRuns.value)
        XCTAssertEqual(long.longest.movingSeconds, 1200, accuracy: 1e-9)
        XCTAssertEqual(long.longest.shareOfWeek, 1)
    }
}

final class BaselineBestEffortTests: XCTestCase {
    func testFastestStretchInterpolatesTheStart() throws {
        // 2 m/s for 600 s, then 4 m/s: every 1000 m inside the fast part takes 250 s;
        // ties keep the earliest, which starts where the fast part begins.
        let samples: [StreamSample] = stride(from: 0.0, through: 1200, by: 10).map { (t: Double) -> StreamSample in
            let d: Double = t <= 600 ? 2 * t : 1200 + 4 * (t - 600)
            return StreamSample(t: t, distance: d)
        }
        let s = try XCTUnwrap(BaselineBuilder.fastestStretch(samples, meters: 1000))
        XCTAssertEqual(s.seconds, 250, accuracy: 1e-9)
        XCTAssertEqual(s.startT, 600, accuracy: 1e-9)
        // The fast part covers only 2400 m, so 3000 m needs 600 m of slow running first.
        let longer = try XCTUnwrap(BaselineBuilder.fastestStretch(samples, meters: 3000))
        XCTAssertEqual(longer.seconds, 600.0 / 2 + 2400.0 / 4, accuracy: 1e-9)
        XCTAssertEqual(longer.startT, 300, accuracy: 1e-9)
        XCTAssertNil(BaselineBuilder.fastestStretch(samples, meters: 5000))
        XCTAssertNil(BaselineBuilder.fastestStretch([], meters: 100))
    }

    func testGPSJumpAndBackwardsDistanceAreNotRewarded() throws {
        // 3 m/s throughout, but the stream jumps 3 km forward at 505 s (and
        // keeps the offset) and reads 0 once at 705 s. Neither may make an effort faster.
        var samples: [StreamSample] = stride(from: 0.0, through: 1000, by: 10).map { (t: Double) -> StreamSample in
            let d: Double = t <= 500 ? 3 * t : 3 * t + 3000
            return StreamSample(t: t, distance: d)
        }
        samples.append(StreamSample(t: 705, distance: 0))
        samples.append(StreamSample(t: 1005, distance: .nan))
        let s = try XCTUnwrap(BaselineBuilder.fastestStretch(samples, meters: 1000))
        XCTAssertEqual(s.seconds, 1000 / 3, accuracy: 1e-9)
        // The jump step and the two steps around the dip add nothing: 2,940 m remain.
        XCTAssertNil(BaselineBuilder.fastestStretch(samples, meters: 2_990))
    }

    func testDipThatRecoversIsCountedOnce() throws {
        // 300 -> 290 -> 330 is 30 m of running, not 40 m.
        let samples = [StreamSample(t: 0, distance: 300), StreamSample(t: 5, distance: 290),
                       StreamSample(t: 10, distance: 330)]
        XCTAssertNil(BaselineBuilder.fastestStretch(samples, meters: 31))
        let s = try XCTUnwrap(BaselineBuilder.fastestStretch(samples, meters: 30))
        XCTAssertEqual(s.seconds, 10, accuracy: 1e-9)
    }

    func testSameTimestampReadingsInEitherOrderAreNotCountedTwice() throws {
        // 3 m/s, with a second reading 25 m high at the same timestamp every 30 s.
        for highFirst in [false, true] {
            var samples: [StreamSample] = []
            for t in stride(from: 0.0, through: 1200, by: 5) {
                let truth = StreamSample(t: t, distance: 3 * t)
                let high = StreamSample(t: t, distance: 3 * t + 25)
                if t.truncatingRemainder(dividingBy: 30) == 0 {
                    samples += highFirst ? [high, truth] : [truth, high]
                } else {
                    samples.append(truth)
                }
            }
            let s = try XCTUnwrap(BaselineBuilder.fastestStretch(samples, meters: 1000))
            XCTAssertEqual(s.seconds, 1000.0 / 3, accuracy: 1e-9, "high first: \(highFirst)")
        }
    }

    func testGlitchesNeverMakeAnEffortFaster() {
        // Property check over 200 random streams: a 3 m/s run with detectable
        // glitches (backwards readings below the last usable true one, readings that
        // share a timestamp with the true one in either order and either
        // direction, GPS jumps that keep their offset, missing readings). No
        // effort may beat distance / 3 m/s.
        var seed: UInt64 = 0x2545F4914F6CDD1D
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let speed = 3.0
        var checked = 0
        for _ in 0..<200 {
            var samples: [StreamSample] = []
            var offset = 0.0
            var lastTrue = 0.0
            for t in stride(from: 0.0, through: 2000, by: 5) {
                let truth = speed * t + offset
                // The first reading is true: a wrong first reading has nothing to be checked against.
                switch t == 0 ? 1 : next() {
                case ..<0.10:
                    samples.append(StreamSample(t: t, distance: lastTrue - 1 - 50 * next()))
                    continue
                case ..<0.20:
                    let other = StreamSample(t: t, distance: truth + (next() - 0.5) * 60)
                    let real = StreamSample(t: t, distance: truth)
                    samples += next() < 0.5 ? [other, real] : [real, other]
                    continue // the true reading here is dropped with the conflicting one
                case ..<0.23:
                    offset += 500 + 2500 * next()
                    samples.append(StreamSample(t: t, distance: speed * t + offset))
                    lastTrue = speed * t + offset
                    continue
                case ..<0.26:
                    samples.append(StreamSample(t: t, distance: .nan))
                    continue
                default:
                    samples.append(StreamSample(t: t, distance: truth))
                }
                lastTrue = truth
            }
            for meters in [400.0, 1000, Distance.mile, 5000] {
                guard let s = BaselineBuilder.fastestStretch(samples, meters: meters) else { continue }
                checked += 1
                XCTAssertGreaterThanOrEqual(s.seconds, meters / speed - 1e-6, "\(meters) m")
            }
        }
        XCTAssertGreaterThan(checked, 600, "most streams should still give efforts")
    }

    func testFastRunnerWithNoisyOneHertzDistanceKeepsTheirSteps() throws {
        // 5 m/s with each reading up to 2 m off: steps of up to 9 m in 1 s exceed
        // 7.5 m/s but are noise, not jumps, and must still count.
        var seed: UInt64 = 42
        func noise() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (Double(seed >> 11) / Double(1 << 53) - 0.5) * 4
        }
        let samples = (0...1500).map { k in StreamSample(t: Double(k), distance: 5 * Double(k) + (k == 0 ? 0 : noise())) }
        let s = try XCTUnwrap(BaselineBuilder.fastestStretch(samples, meters: 5000))
        // Within twice the reading error (4 m at 5 m/s = 0.8 s) of the true 1000 s.
        XCTAssertEqual(s.seconds, 1000, accuracy: 0.8)
    }

    func testSustainedOverReadNeverCounts() throws {
        // 1 Hz, truly 3 m/s, but from 100 s the stream reads 8, 10 or 12 m/s for
        // 20 or 30 s, then either keeps the offset or drops back to the truth.
        for overSpeed in [8.0, 10, 12] {
            for seconds in [20.0, 30] {
                for keepsOffset in [true, false] {
                    let samples = (0...1200).map { k -> StreamSample in
                        let t = Double(k)
                        let overRead = t < 100 ? 0 : (overSpeed - 3) * (min(t, 100 + seconds) - 100)
                        let extra = t >= 100 + seconds && !keepsOffset ? 0 : overRead
                        return StreamSample(t: t, distance: 3 * t + extra)
                    }
                    for meters in [400.0, 1000] {
                        let s = try XCTUnwrap(BaselineBuilder.fastestStretch(samples, meters: meters))
                        XCTAssertGreaterThanOrEqual(s.seconds, (meters - 5) / 3,
                                                    "\(overSpeed) m/s for \(seconds) s, offset kept: \(keepsOffset), \(meters) m")
                    }
                }
            }
        }
    }

    func testSingleNoisyReadingIsKeptButASecondOverLimitStepIsNot() throws {
        // 0, 3, then a reading 11 m on (over 7.5 m/s by under 5 m), then back on track.
        let noisy = [0.0, 3, 14, 9, 12].enumerated().map { StreamSample(t: Double($0.offset), distance: $0.element) }
        let a = try XCTUnwrap(BaselineBuilder.fastestStretch(noisy, meters: 12))
        XCTAssertEqual(a.seconds, 4, accuracy: 1e-9, "the reading at 2 s waits for 3 s, which is plausible")
        // Two over-limit steps in a row: the second is a jump and nothing from them counts.
        let jumpy = [0.0, 3, 14, 25, 28].enumerated().map { StreamSample(t: Double($0.offset), distance: $0.element) }
        XCTAssertNil(BaselineBuilder.fastestStretch(jumpy, meters: 7))
        XCTAssertNotNil(BaselineBuilder.fastestStretch(jumpy, meters: 6))
    }

    func testDuplicateDistancesGiveOnePRPerDistance() throws {
        let run = makeRun("a", start: at(day: 20), seconds: 2000)
        let best = try XCTUnwrap(build([run]) { $0.bestEffortDistances = [5000, 1000, 5000] }.bestEfforts.value)
        XCTAssertEqual(best.personalRecords.map(\.distanceMeters), [1000, 5000])
    }

    func testTreadmillRunsAreLeftOut() {
        let r = build([makeRun("tm", start: at(day: 20), indoor: true)])
        XCTAssertEqual(r.bestEfforts.insufficiency,
                       InsufficientData(.noDistanceStreams, excluded: [ExcludedRun(activityID: "tm", reason: .treadmill)]))
    }

    func testRecentAndAllTimeDiffer() throws {
        let old = makeRun("old", start: at(day: 1), seconds: 2000, speed: { _ in 4 })
        let new = makeRun("new", start: at(day: 200), seconds: 2000, speed: { _ in 3.5 })
        let best = try XCTUnwrap(build([old, new], asOf: at(day: 210)) { $0.bestEffortDistances = [5000] }.bestEfforts.value)
        XCTAssertEqual(best.personalRecords.map(\.activityID), ["old"])
        XCTAssertEqual(best.recent.map(\.activityID), ["new"])
        XCTAssertEqual(best.recent[0].bestEffort.distanceMeters, 5000)
        XCTAssertEqual(best.evidenceActivityIDs, ["old", "new"])
    }
}

final class BaselineHeartRateTests: XCTestCase {
    func testTimeTrialUsesItsLast20Minutes() throws {
        let tt = makeRun("tt", start: at(day: 20), seconds: 1800, hr: { $0 < 600 ? 150 : 172 })
        let lthr = try XCTUnwrap(build([tt], efforts: [EffortMark(activityID: "tt", kind: .timeTrialLast20Min)]).lthr.value)
        XCTAssertEqual(lthr.estimate.bpm, 172, accuracy: 1e-9)
        XCTAssertFalse(lthr.estimate.isCorroborated)
        XCTAssertEqual(lthr.evidenceActivityIDs, ["tt"])
    }

    func testRaceFallsBackToSummaryHeartRateButTrialDoesNot() throws {
        let race = makeRun("race", start: at(day: 20), seconds: 2700, hr: { _ in nil }, averageHR: 169)
        let tt = makeRun("tt", start: at(day: 21), seconds: 1800, hr: { _ in nil }, averageHR: 171)
        let r = build([race, tt], efforts: [EffortMark(activityID: "race", kind: .race),
                                            EffortMark(activityID: "tt", kind: .timeTrialLast20Min)])
        let lthr = try XCTUnwrap(r.lthr.value)
        XCTAssertEqual(lthr.estimate.bpm, 169)
        XCTAssertEqual(lthr.excluded, [ExcludedRun(activityID: "tt", reason: .noHeartRate)])
    }

    func testMarksThatCannotCountAreListed() {
        let short = makeRun("5k", start: at(day: 20), seconds: 1200, hr: { _ in 180 })
        let old = makeRun("old", start: at(day: -200), seconds: 2700, hr: { _ in 170 })
        let future = makeRun("future", start: at(day: 40), seconds: 2700, hr: { _ in 170 })
        var walk = makeRun("walk", start: at(day: 21), seconds: 2700, hr: { _ in 170 })
        walk.sport = .walk
        let r = build([short, old, future, walk], efforts: [
            EffortMark(activityID: "5k", kind: .race), EffortMark(activityID: "old", kind: .race),
            EffortMark(activityID: "future", kind: .race), EffortMark(activityID: "nope", kind: .race),
            EffortMark(activityID: "5k", kind: .timeTrialLast20Min), EffortMark(activityID: "walk", kind: .race),
        ])
        XCTAssertEqual(r.lthr.insufficiency?.reason, .noQualifyingEfforts)
        let excluded = r.lthr.insufficiency?.excluded ?? []
        // Marks that don't resolve to a usable run come first, in mark order; then runs by start.
        XCTAssertEqual(Array(excluded.prefix(4)), [
            ExcludedRun(activityID: "future", reason: .afterAsOf),
            ExcludedRun(activityID: "nope", reason: .notInHistory),
            ExcludedRun(activityID: "5k", reason: .duplicateMark(of: "5k")),
            ExcludedRun(activityID: "walk", reason: .notARun),
        ])
        XCTAssertEqual(excluded[4], ExcludedRun(activityID: "old", reason: .outsideLookback))
        if case .effortDidNotQualify(let secs, let hr) = excluded[5].reason {
            XCTAssertEqual(excluded[5].activityID, "5k")
            XCTAssertEqual(secs, 1200); XCTAssertEqual(hr, 180, accuracy: 1e-9)
        } else { XCTFail("5k should not qualify") }
        XCTAssertEqual(excluded.count, 6)
        XCTAssertEqual(r.runs.first { $0.activityID == "5k" }?.markedEffort, .race, "first mark wins")
    }

    func testHeartRateMustCoverTheCountedTime() {
        // A 30-minute trial with heart rate only in its last 30 s must not set LTHR.
        let sparse = makeRun("tt", start: at(day: 20), seconds: 1800, hr: { $0 >= 1770 ? 190 : nil })
        let r = build([sparse], efforts: [EffortMark(activityID: "tt", kind: .timeTrialLast20Min)])
        XCTAssertEqual(r.lthr.insufficiency?.reason, .noQualifyingEfforts)
        guard case .insufficientHeartRateCoverage(let coverage)? = r.lthr.insufficiency?.excluded.first?.reason else {
            return XCTFail("expected a coverage exclusion")
        }
        XCTAssertEqual(coverage, 30.0 / 1200, accuracy: 1e-9)
        XCTAssertEqual(r.easyPace.insufficiency?.reason, .needsLTHR)

        // The same for a race whose stream drops out for most of the run; its
        // summary average is not used once a stream exists.
        let dropout = makeRun("race", start: at(day: 21), seconds: 2700, hr: { $0 < 600 ? 170 : nil }, averageHR: 170)
        let race = build([dropout], efforts: [EffortMark(activityID: "race", kind: .race)])
        XCTAssertEqual(race.lthr.insufficiency?.reason, .noQualifyingEfforts)

        // Exactly at the threshold counts.
        let edge = makeRun("edge", start: at(day: 22), seconds: 1800, hr: { $0 >= 840 ? 172 : nil })
        let ok = build([edge], efforts: [EffortMark(activityID: "edge", kind: .timeTrialLast20Min)]) {
            $0.minimumHeartRateCoverage = 0.8
        }
        XCTAssertEqual(ok.lthr.value?.estimate.bpm, 172)
    }

    /// 1 Hz speed and distance; heart rate either in every `hrEvery`-th sample
    /// or, when `separate`, in its own samples offset by half a second.
    private func sparseHR(_ id: String, day: Double, seconds: Double, hrEvery: Int, separate: Bool = false,
                          hr: Double = 170, hrGap: Range<Double>? = nil) -> Activity {
        var samples: [StreamSample] = []
        for k in 0...Int(seconds) {
            let t = Double(k)
            let hasHR = k % hrEvery == 0 && !(hrGap?.contains(t) ?? false)
            samples.append(StreamSample(t: t, heartRate: hasHR && !separate ? hr : nil, speed: 3.5, distance: 3.5 * t))
            if hasHR && separate && k < Int(seconds) { samples.append(StreamSample(t: t + 0.5, heartRate: hr)) }
        }
        return Activity(id: id, source: .healthKit, start: at(day: day), durationSeconds: seconds,
                        distanceMeters: 3.5 * seconds, samples: samples)
    }

    func testHeartRateRecordedLessOftenThanSpeedStillCounts() throws {
        for (every, separate) in [(2, false), (5, false), (5, true)] {
            let race = sparseHR("race", day: 20, seconds: 2700, hrEvery: every, separate: separate)
            let lthr = try XCTUnwrap(build([race], efforts: [EffortMark(activityID: "race", kind: .race)]).lthr.value,
                                     "HR every \(every) s, separate: \(separate)")
            XCTAssertEqual(lthr.estimate.bpm, 170, accuracy: 1e-9)
        }
    }

    func testHeartRateCoverageMatchesDecoupling() throws {
        // HR in its own offset samples every 5 s, with a 400 s dropout late in the run.
        let run = sparseHR("r", day: 20, seconds: 3000, hrEvery: 5, separate: true, hrGap: 2000..<2400)
        let timeline = MovingTime.held(run.samples, streams: [.heartRate: { (30...250).contains($0) }],
                                       maximumHoldSeconds: 30)
        let total = try XCTUnwrap(timeline.last?.end)
        let ours = try XCTUnwrap(BaselineBuilder.heldMean(timeline, of: .heartRate)).seconds / total
        var opts = DecouplingOptions.default
        opts.warmUpSeconds = 0
        opts.minimumCoverage = 0
        let dec = try Decoupling.compute(run.samples, options: opts).get()
        XCTAssertEqual(dec.movingSeconds, total, accuracy: 1e-9)
        // Equal halves, so the whole-run coverage is the mean of the two halves'.
        XCTAssertEqual(ours, (dec.firstHalfHRCoverage + dec.secondHalfHRCoverage) / 2, accuracy: 1e-9)
        XCTAssertLessThan(ours, 1)
    }

    func testPeakIgnoresSingleSpikesAndBrokenReadings() throws {
        let run = makeRun("a", start: at(day: 20), hr: { t in
            switch t {
            case 100: return 230       // one-sample strap spike
            case 200: return .nan
            case 300..<330: return 181 // held 30 s
            default: return 150
            }
        })
        let peak = try XCTUnwrap(build([run]).peakHeartRate.value)
        XCTAssertEqual(peak.bpm, 181)
        XCTAssertEqual(peak.evidenceActivityIDs, ["a"])
        let noHR = makeRun("b", start: at(day: 20), hr: { _ in nil })
        XCTAssertEqual(build([noHR]).peakHeartRate.insufficiency?.reason, .noHeartRateData)
    }

    func testHeldPeakNeedsCloselySpacedSamples() {
        // Samples 15 s apart can't show a 20 s hold (gap limit is 10 s).
        let sparse = [StreamSample(t: 0, heartRate: 170), StreamSample(t: 15, heartRate: 170), StreamSample(t: 30, heartRate: 170)]
        XCTAssertNil(BaselineBuilder.heldPeak(sparse, hold: 20, plausible: 30...250))
        let dense = (0...4).map { StreamSample(t: Double($0) * 5, heartRate: 170) }
        XCTAssertEqual(BaselineBuilder.heldPeak(dense, hold: 20, plausible: 30...250), 170)
    }
}

final class BaselineEasyPaceTests: XCTestCase {
    private func easy(_ id: String, day: Double, speed: Double = 3, hr: @escaping (Double) -> Double? = { _ in 145 }) -> Activity {
        makeRun(id, start: at(day: day), speed: { _ in speed }, hr: hr)
    }

    func testMedianOfRunsAtTheGivenHeartRate() throws {
        let runs = [easy("a", day: 20, speed: 3.0), easy("b", day: 22, speed: 3.2), easy("c", day: 24, speed: 2.9),
                    easy("hot", day: 25, hr: { _ in 160 })]
        let pace = try XCTUnwrap(build(runs) { $0.easyHeartRate = .bpm(145) }.easyPace.value)
        XCTAssertEqual(pace.metersPerSecond, 3.0, accuracy: 1e-9)
        XCTAssertEqual(pace.secondsPerKilometer, 1000 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(pace.band, 142...148)
        XCTAssertEqual(pace.evidenceActivityIDs, ["a", "b", "c"])
        XCTAssertEqual(pace.excluded, [ExcludedRun(activityID: "hot", reason: .tooLittleTimeAtHeartRate(seconds: 0))])
    }

    func testWarmUpIsSkipped() {
        // In band only during the first 5 minutes.
        let runs = (0..<3).map { easy("r\($0)", day: 20 + Double($0), hr: { $0 < 300 ? 145 : 170 }) }
        let r = build(runs) { $0.easyHeartRate = .bpm(145) }
        XCTAssertEqual(r.easyPace.insufficiency?.reason, .tooFewRuns(have: 0, need: 3))
    }

    func testWarmUpIsMovingTimeAndDistanceOnlyRunsSaySo() throws {
        // Paused for the first 10 minutes (watch started early), then 20 min in band:
        // 5 moving minutes are skipped, leaving 15.
        func late(_ id: String, _ day: Double) -> Activity {
            var r = easy(id, day: day)
            r.samples = r.samples.map { var s = $0; s.isMoving = s.t >= 600; return s }
            return r
        }
        let distanceOnly = makeRun("dist", start: at(day: 19), speed: { _ in 3 }, hr: { _ in 145 })
        var stripped = distanceOnly
        stripped.samples = stripped.samples.map { var s = $0; s.speed = nil; return s }
        let pace = try XCTUnwrap(build([stripped, late("a", 20), late("b", 21), late("c", 22)]) {
            $0.easyHeartRate = .bpm(145)
        }.easyPace.value)
        XCTAssertEqual(pace.runs.map(\.secondsInBand), [900, 900, 900])
        XCTAssertEqual(pace.excluded, [ExcludedRun(activityID: "dist", reason: .noSpeed)])
    }

    func testInterleavedHeartRateAndSpeedSamples() throws {
        // HealthKit style: speed and heart rate never share a sample.
        func interleaved(_ id: String, _ day: Double) -> Activity {
            var samples: [StreamSample] = []
            for k in 0...1800 {
                let t = Double(k)
                samples.append(StreamSample(t: t, speed: 3.1, cadence: k % 2 == 0 ? nil : 174, distance: 3.1 * t))
                if k % 5 == 2 { samples.append(StreamSample(t: t + 0.25, heartRate: 145)) }
            }
            return Activity(id: id, source: .healthKit, start: at(day: day), durationSeconds: 1800, samples: samples)
        }
        let runs = (0..<3).map { interleaved("i\($0)", 20 + Double($0)) }
        let pace = try XCTUnwrap(build(runs) { $0.easyHeartRate = .bpm(145) }.easyPace.value)
        XCTAssertEqual(pace.metersPerSecond, 3.1, accuracy: 1e-9)
        // HR starts at 2.25 s, well inside the warm-up, so all 25 minutes after it count.
        XCTAssertEqual(pace.runs[0].secondsInBand, 1500, accuracy: 1e-9)
        let trend = try XCTUnwrap(build(runs).cadence.value)
        XCTAssertEqual(trend.runs.map(\.stepsPerMinute), [174, 174, 174])
    }

    func testInvalidHeartRateAndTooFewRuns() {
        let runs = [easy("a", day: 20)]
        XCTAssertEqual(build(runs) { $0.easyHeartRate = .bpm(.nan) }.easyPace.insufficiency?.reason, .invalidInput)
        XCTAssertEqual(build(runs) { $0.easyHeartRate = .bpm(145) }.easyPace.insufficiency?.reason,
                       .tooFewRuns(have: 1, need: 3))
        XCTAssertEqual(build([easy("old", day: -60)]) { $0.easyHeartRate = .bpm(145) }.easyPace.insufficiency?.reason,
                       .noRuns)
    }
}

final class BaselineDecouplingTests: XCTestCase {
    func testUnsteadyAndShortRunsDoNotCount() {
        let steady = makeRun("steady", start: at(day: 20), seconds: 3600, hr: { 140 + $0 / 600 })
        let intervals = makeRun("intervals", start: at(day: 21), seconds: 3600,
                                speed: { Int($0 / 120) % 2 == 0 ? 4.5 : 2.5 }, hr: { _ in 150 })
        let short = makeRun("short", start: at(day: 22), seconds: 1800)
        let r = build([steady, intervals, short])
        XCTAssertEqual(r.decoupling.insufficiency?.reason, .tooFewRuns(have: 1, need: 3))
        XCTAssertEqual(r.decoupling.insufficiency?.excluded,
                       [ExcludedRun(activityID: "intervals", reason: .notSteady)])
    }

    func testRefusalsAreListed() throws {
        let noHR = makeRun("nohr", start: at(day: 20), seconds: 3600, hr: { _ in nil })
        let runs = (0..<3).map { makeRun("s\($0)", start: at(day: 21 + Double($0)), seconds: 3600) } + [noHR]
        let dec = try XCTUnwrap(build(runs).decoupling.value)
        XCTAssertEqual(dec.evidenceActivityIDs, ["s0", "s1", "s2"])
        XCTAssertEqual(dec.typicalPercent, 0, accuracy: 1e-9)
        XCTAssertEqual(dec.excluded, [ExcludedRun(activityID: "nohr", reason: .decouplingRefused(.insufficientHeartRate(coverage: 0)))])
    }
}

final class BaselineCadenceTests: XCTestCase {
    func testSummaryCadenceFallbackAndMissingCadence() throws {
        let runs = [makeRun("stream", start: at(day: 15), cadence: { _ in 172 }),
                    makeRun("summary", start: at(day: 16), cadence: { _ in nil }, averageCadence: 168),
                    makeRun("none", start: at(day: 17), cadence: { _ in .nan })]
        let trend = try XCTUnwrap(build(runs).cadence.value)
        XCTAssertEqual(trend.runs.map(\.stepsPerMinute), [172, 168])
        XCTAssertEqual(trend.runsWithoutCadence, ["none"])
        XCTAssertEqual(trend.slopePerWeek.insufficiency?.reason, .tooFewRuns(have: 2, need: 4))
        XCTAssertEqual(trend.gaps.map(\.activityIDs), [["none"]])
    }

    func testSlopeNeedsSpan() throws {
        let close = (0..<4).map { makeRun("c\($0)", start: at(day: 20, hour: 6 + Double($0))) }
        let trend = try XCTUnwrap(build(close).cadence.value)
        if case .spanTooShort(let days, let need)? = trend.slopePerWeek.insufficiency?.reason {
            XCTAssertEqual(days, 0.125, accuracy: 1e-9); XCTAssertEqual(need, 14)
        } else { XCTFail("expected spanTooShort") }
    }

    func testSlopeSignAndNoCadence() throws {
        let falling = (0..<5).map { i in makeRun("f\(i)", start: at(day: Double(i) * 7), cadence: { _ in 180 - Double(i) }) }
        let trend = try XCTUnwrap(build(falling, asOf: at(day: 33)).cadence.value)
        XCTAssertEqual(trend.slopePerWeek.value!, -1, accuracy: 1e-9)
        let none = [makeRun("x", start: at(day: 20), cadence: { _ in nil })]
        XCTAssertEqual(build(none).cadence.insufficiency?.reason, .noCadence)
    }
}

final class BaselineDailyHealthTests: XCTestCase {
    private let asOf = at(day: 70, hour: 12)

    private func readings(_ kind: DailyHealthSample.Kind, days: Range<Int>, value: (Int) -> Double) -> [DailyHealthSample] {
        days.map { DailyHealthSample(date: at(day: 70 - Double($0), hour: 6), kind: kind, value: value($0)) }
    }

    func testMeanSDAndRangeOverSixtyDays() throws {
        // Alternating 48 / 52 over 60 days, plus readings outside the window and after asOf.
        var input = readings(.restingHeartRate, days: 0..<70) { $0 % 2 == 0 ? 48 : 52 }
        input.append(DailyHealthSample(date: at(day: 71), kind: .restingHeartRate, value: 90))
        let b = try XCTUnwrap(build([], health: input, asOf: asOf).restingHeartRate.value)
        XCTAssertEqual(b.days.count, 60)
        XCTAssertEqual(b.mean, 50, accuracy: 1e-9)
        let sd = (60.0 * 4 / 59).squareRoot()
        XCTAssertEqual(b.standardDeviation, sd, accuracy: 1e-9)
        XCTAssertEqual(b.normalRange.lowerBound, 50 - sd, accuracy: 1e-9)
        XCTAssertEqual(b.sevenDayAverage.value!, (4 * 48 + 3 * 52) / 7.0, accuracy: 1e-9)
    }

    func testSeveralReadingsADayAreAveragedAndBadOnesIgnored() throws {
        var input = readings(.hrvSDNN, days: 0..<20) { _ in 60 }
        input.append(DailyHealthSample(date: at(day: 70, hour: 9), kind: .hrvSDNN, value: 80))
        input.append(DailyHealthSample(date: at(day: 69, hour: 9), kind: .hrvSDNN, value: .nan))
        input.append(DailyHealthSample(date: at(day: 68, hour: 9), kind: .hrvSDNN, value: 900))
        let b = try XCTUnwrap(build([], health: input, asOf: asOf).hrv.value)
        XCTAssertEqual(b.days.count, 20)
        XCTAssertEqual(b.days.last?.value, 70)
        XCTAssertEqual(build([], health: input, asOf: asOf).restingHeartRate.insufficiency?.reason, .noReadings)
    }

    func testTooFewDaysAndTooFewRecentReadings() throws {
        let few = readings(.restingHeartRate, days: 0..<10) { _ in 50 }
        XCTAssertEqual(build([], health: few, asOf: asOf).restingHeartRate.insufficiency?.reason,
                       .tooFewDays(have: 10, need: 14))
        // Plenty of days, but only two in the last week.
        let stale = readings(.restingHeartRate, days: 5..<40) { _ in 50 }
        let b = try XCTUnwrap(build([], health: stale, asOf: asOf).restingHeartRate.value)
        XCTAssertEqual(b.sevenDayAverage.insufficiency?.reason, .tooFewDays(have: 2, need: 3))
    }

    func testDaysFollowTheCallersTimeZone() throws {
        // 02:00 UTC readings fall on the previous calendar day in New York.
        let input = (0..<20).map { DailyHealthSample(date: at(day: 70 - Double($0), hour: 2), kind: .restingHeartRate, value: 50) }
        let ny = try XCTUnwrap(build([], health: input, asOf: asOf, timeZone: newYork).restingHeartRate.value)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = newYork
        XCTAssertEqual(ny.days.last?.day, cal.startOfDay(for: at(day: 69, hour: 12)))
    }
}
