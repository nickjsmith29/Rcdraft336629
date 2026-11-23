import XCTest
@testable import CoachCore

// ProgressBuilder (F13) on synthetic histories: each point reuses the F1
// baseline, cites its evidence, and holds its comparison basis fixed.

private typealias F = ProgressFixture

/// A 45-minute race at 170 bpm, marked as a race: LTHR 170, easy ceiling 153 (SPEC.md 3.2).
private func race(week: Int) -> (Activity, EffortMark) {
    let a = F.run("race-w\(week)", start: F.at(week: week, day: 5, hour: 9), seconds: 45 * 60, speed: 3.8,
                  hr: { _ in 170 }, cadence: 180)
    return (a, EffortMark(activityID: a.id, kind: .race))
}

final class ProgressBuilderTests: XCTestCase {
    func testEveryPointIsTheBaselineAsOfThatWeek() throws {
        let weeks = F.trend(12, start: 2.9, rate: 0.01)
        let d = F.dashboard(weeks, asOfWeek: 12)
        let easy = try XCTUnwrap(d.metric(.easyPace))
        let drift = try XCTUnwrap(d.metric(.longRunDecoupling))
        let load = try XCTUnwrap(d.metric(.weeklyLoad))
        XCTAssertEqual(easy.series.count, 13)
        for (i, k) in (0...12).reversed().enumerated() {
            var o = BaselineOptions(asOf: F.asOf(week: 12 - k), timeZone: F.utc, recentDays: 28)
            o.easyHeartRate = .bpm(F.easyHR)
            let r = BaselineBuilder.build(activities: F.history(weeks), options: o)
            XCTAssertEqual(easy.series[i].asOf, o.asOf)
            XCTAssertEqual(easy.series[i].value, r.easyPace.value?.secondsPerKilometer)
            XCTAssertEqual(easy.series[i].evidence.activityIDs, r.easyPace.value?.evidenceActivityIDs ?? [])
            XCTAssertEqual(drift.series[i].value, r.decoupling.value?.typicalPercent)
            XCTAssertEqual(load.series[i].value, r.weeklyLoad.value?.currentWeeklyMovingSeconds)
            if let v = easy.series[i].value { XCTAssertTrue(v.isFinite) }
        }
        XCTAssertEqual(d.easyHeartRate, F.easyHR)
        XCTAssertEqual(easy.changes.map(\.weeks), [4, 12])
    }

    func testLongHistoryGivesTheSameValuesAsTheWholeHistory() throws {
        // Runs in weeks 0-5, a long break, then weeks 31-39: snapshots read only
        // recent activities, and the weekly-load window must still count the
        // empty weeks before week 31 as zeros, as the whole history does.
        let weeks = F.trend(6, start: 3.0, rate: 0) + Array(repeating: .off, count: 25) + F.trend(9, start: 3.1, rate: 0.01)
        let acts = F.history(weeks)
        let d = ProgressBuilder.build(activities: acts, options: F.options(asOf: F.asOf(week: 40)))
        let load = try XCTUnwrap(d.metric(.weeklyLoad))
        let easy = try XCTUnwrap(d.metric(.easyPace))
        var sawZeroWeek = false
        for (i, k) in (0...12).reversed().enumerated() {
            var o = BaselineOptions(asOf: F.asOf(week: 40 - k), timeZone: F.utc, recentDays: 28)
            o.easyHeartRate = .bpm(F.easyHR)
            let r = BaselineBuilder.build(activities: acts, options: o)
            XCTAssertEqual(load.series[i].value, r.weeklyLoad.value?.currentWeeklyMovingSeconds, "snapshot \(i)")
            XCTAssertEqual(load.series[i].evidence.activityIDs, r.weeklyLoad.value?.evidenceActivityIDs ?? [])
            XCTAssertEqual(easy.series[i].value, r.easyPace.value?.secondsPerKilometer)
            if let w = r.weeklyLoad.value, w.weeks.contains(where: { $0.isComplete && $0.runCount == 0 }) { sawZeroWeek = true }
        }
        XCTAssertTrue(sawZeroWeek, "the fixture should exercise empty weeks inside the load window")
        XCTAssertFalse(d.runs.contains { $0.activityID == "w0-tue" }, "old runs aren't re-read")
    }

    func testFourWeekChangeComparesWindowsThatShareNoRun() throws {
        let d = F.dashboard(F.trend(12, start: 2.9, rate: 0.01), asOfWeek: 12)
        let c = try XCTUnwrap(d.metric(.easyPace)).change(overWeeks: 4)
        let now = Set(try XCTUnwrap(c.latest).evidence.activityIDs)
        let then = Set(try XCTUnwrap(c.earlier).evidence.activityIDs)
        XCTAssertFalse(now.isEmpty)
        XCTAssertFalse(then.isEmpty)
        XCTAssertTrue(now.isDisjoint(with: then))
        XCTAssertEqual(c.direction, .improving)
        XCTAssertLessThan(try XCTUnwrap(c.delta), 0, "faster pace at the same heart rate is fewer s/km")
    }

    func testEasyHeartRateComesFromCurrentZonesAndStaysFixed() throws {
        let (r, mark) = race(week: 9)
        let d = F.dashboard(F.trend(12, start: 3.0, rate: 0), asOfWeek: 12, efforts: [mark], extra: [r]) {
            $0.baseline.easyHeartRate = .zoneTwoMidpoint
        }
        let hr = try XCTUnwrap(d.easyHeartRate)
        XCTAssertEqual(hr, (0.85 + 0.90) / 2 * 170, accuracy: 0.2)
        XCTAssertEqual(try XCTUnwrap(d.easyCeiling), 0.90 * 170, accuracy: 0.2)
        // Runs sit at 140 bpm, outside the band around ~149, so easy pace is missing,
        // and before the race it is missing for the same reason, not for lack of LTHR.
        let easy = try XCTUnwrap(d.metric(.easyPace))
        for p in easy.series {
            guard case .insufficient(let why)? = p.gap else { return XCTFail("expected a gap") }
            XCTAssertNotEqual(why.reason, .needsLTHR)
        }
    }

    func testWithoutLTHRZoneBasedValuesSayWhy() throws {
        let d = F.dashboard(F.trend(12, start: 3.0, rate: 0), asOfWeek: 12) {
            $0.baseline.easyHeartRate = .zoneTwoMidpoint
        }
        XCTAssertNil(d.easyHeartRate)
        XCTAssertNil(d.easyCeiling)
        XCTAssertTrue(try XCTUnwrap(d.metric(.easyPace)).series.allSatisfy { $0.gap == .baseline(.needsLTHR) })
        XCTAssertTrue(try XCTUnwrap(d.metric(.easyShare)).series.allSatisfy { $0.gap == .baseline(.needsLTHR) })
    }

    func testEasyShareMovesTowardTheTargetRange() throws {
        let (r, mark) = race(week: 0)
        // Weeks 0-7: three hard runs of four (easy share 60/165 = 36%);
        // weeks 8-11: one hard run. The latest 28 days hold week 8's Thursday to
        // Sunday and weeks 9-11: 520 easy minutes of 625 (83%, inside 75 to 85%).
        var weeks = F.trend(12, start: 3.0, rate: 0)
        for i in 0..<12 { weeks[i].hard = i < 8 ? ["tue", "thu", "sat"] : ["tue"] }
        // A run without heart rate in the window is left out of the share.
        let noHR = F.run("no-hr", start: F.at(week: 11, day: 2), seconds: 1800, speed: 3, hr: { _ in nil }, cadence: nil)
        let d = F.dashboard(weeks, asOfWeek: 12, efforts: [mark], extra: [r, noHR])
        let share = try XCTUnwrap(d.metric(.easyShare))
        let latest = try XCTUnwrap(share.latest)
        XCTAssertEqual(try XCTUnwrap(latest.value), 520.0 / 625, accuracy: 0.002)
        XCTAssertFalse(latest.evidence.activityIDs.contains("no-hr"))
        XCTAssertTrue(latest.evidence.activityIDs.contains("w11-sun"))
        let c = share.change(overWeeks: 4)
        XCTAssertEqual(try XCTUnwrap(c.earlier?.value), 60.0 / 165, accuracy: 0.03)
        XCTAssertEqual(c.direction, .improving)
    }

    func testEasyShareWithNoHeartRateSaysSo() throws {
        let (r, mark) = race(week: 0)
        let blind = (0..<4).map {
            F.run("blind\($0)", start: F.at(week: 11, day: $0), seconds: 1800, speed: 3, hr: { _ in nil }, cadence: nil)
        }
        let d = ProgressBuilder.build(activities: [r] + blind, efforts: [mark],
                                      options: F.options(asOf: F.asOf(week: 12)))
        guard case .insufficient(let why)? = try XCTUnwrap(d.metric(.easyShare)).latest?.gap else {
            return XCTFail("expected a gap")
        }
        XCTAssertEqual(why.reason, .noHeartRateData)
        XCTAssertEqual(why.excluded.map(\.activityID), blind.map(\.id))
    }

    func testLoadVersusPlan() throws {
        // Actual: 3 x 35 + 60 = 165 minutes every week.
        func planned(week: Int, minutes: Double) -> PlannedWorkout {
            PlannedWorkout(id: "p\(week)", date: F.at(week: week, day: 1), kind: .easy, durationSeconds: minutes * 60)
        }
        let plan = (0..<12).map { planned(week: $0, minutes: $0 < 8 ? 250 : 165) }
        let d = F.dashboard(F.trend(12, start: 3.0, rate: 0), asOfWeek: 12, plan: plan)
        let m = try XCTUnwrap(d.metric(.loadVersusPlan))
        let latest = try XCTUnwrap(m.latest)
        XCTAssertEqual(try XCTUnwrap(latest.value), 1, accuracy: 1e-9)
        XCTAssertEqual(latest.evidence.plannedWorkoutIDs, ["p8", "p9", "p10", "p11"])
        XCTAssertEqual(latest.evidence.activityIDs.count, 16)
        let c = m.change(overWeeks: 4)
        XCTAssertEqual(try XCTUnwrap(c.earlier?.value), 165.0 / 250, accuracy: 1e-9)
        XCTAssertEqual(c.direction, .improving)

        XCTAssertNil(F.dashboard(F.trend(12, start: 3.0, rate: 0), asOfWeek: 12).metric(.loadVersusPlan),
                     "no plan, no plan metric")

        let future = [planned(week: 20, minutes: 100)]
        let df = F.dashboard(F.trend(12, start: 3.0, rate: 0), asOfWeek: 12, plan: future)
        XCTAssertEqual(df.metric(.loadVersusPlan)?.latest?.gap, .noPlannedSessions)

        var broken = plan
        broken[10].durationSeconds = .nan
        let db = F.dashboard(F.trend(12, start: 3.0, rate: 0), asOfWeek: 12, plan: broken)
        XCTAssertEqual(db.metric(.loadVersusPlan)?.latest?.gap, .plannedVolumeUnknown)

        let rest = (8..<12).map { PlannedWorkout(id: "r\($0)", date: F.at(week: $0, day: 1), kind: .rest, durationSeconds: 0) }
        let dr = F.dashboard(F.trend(12, start: 3.0, rate: 0), asOfWeek: 12, plan: rest)
        XCTAssertEqual(dr.metric(.loadVersusPlan)?.latest?.gap, .noPlannedSessions, "rest-only weeks have nothing to compare")
    }

    func testRestingHRAndHRVUseSevenDayAveragesWithTheNormalRange() throws {
        let end = F.asOf(week: 12)
        // Resting HR falls 0.1 bpm a day (older days are higher); HRV is flat.
        let health = F.health(days: 160, before: end, resting: { 48 + 0.1 * Double($0) }, sdnn: { _ in 60 })
        let d = F.dashboard(F.trend(12, start: 3.0, rate: 0), asOfWeek: 12, health: health)
        let rhr = try XCTUnwrap(d.metric(.restingHeartRate))
        let latest = try XCTUnwrap(rhr.latest)
        XCTAssertEqual(try XCTUnwrap(latest.value), 48.3, accuracy: 1e-9)
        XCTAssertEqual(latest.evidence.days.count, 7)
        let band = try XCTUnwrap(latest.band)
        XCTAssertTrue(band.lowerBound < band.upperBound)
        let c = rhr.change(overWeeks: 4)
        XCTAssertEqual(try XCTUnwrap(c.delta), -2.8, accuracy: 1e-9)
        XCTAssertEqual(c.direction, .improving)
        XCTAssertEqual(try XCTUnwrap(d.metric(.hrv)).change(overWeeks: 4).direction, .noChange)
        XCTAssertEqual(try XCTUnwrap(d.metric(.hrv)).change(overWeeks: 12).direction, .noChange)

        let none = F.dashboard(F.trend(12, start: 3.0, rate: 0), asOfWeek: 12)
        XCTAssertEqual(none.metric(.hrv)?.latest?.gap, .baseline(.noReadings))
    }

    func testBestEffortsAndPredictions() throws {
        let d = F.dashboard(F.trend(12, start: 2.9, rate: 0.01), asOfWeek: 12)
        let fiveK = try XCTUnwrap(d.metric(.bestEffort(meters: Distance.fiveK)))
        let latest = try XCTUnwrap(fiveK.latest)
        XCTAssertEqual(try XCTUnwrap(latest.value), Distance.fiveK / (2.9 * pow(1.01, 11)), accuracy: 1)
        XCTAssertEqual(latest.evidence.activityIDs.count, 1)
        XCTAssertEqual(fiveK.change(overWeeks: 4).direction, .improving)
        // 60-minute runs at about 3 m/s never cover a half marathon.
        XCTAssertEqual(d.metric(.bestEffort(meters: Distance.halfMarathon))?.latest?.gap, .noEffortAtDistance)

        let p = try XCTUnwrap(d.metric(.predictedTime(meters: Distance.tenK)))
        let pl = try XCTUnwrap(p.latest)
        let v = try XCTUnwrap(pl.value)
        XCTAssertTrue(try XCTUnwrap(pl.band).contains(v))
        XCTAssertFalse(pl.evidence.activityIDs.isEmpty)
        XCTAssertTrue(pl.evidence.activityIDs.allSatisfy { d.runs.map(\.activityID).contains($0) })
        XCTAssertEqual(p.change(overWeeks: 4).direction, .improving)
        XCTAssertEqual(p.change(overWeeks: 12).direction, .improving)
    }

    func testPredictionAndBestEffortGapsSayWhy() throws {
        let tread = (0..<4).map {
            F.run("t\($0)", start: F.at(week: 11, day: $0), seconds: 1800, speed: 3, hr: { _ in 140 }, cadence: 170,
                  indoor: true)
        }
        let d = ProgressBuilder.build(activities: tread, options: F.options(asOf: F.asOf(week: 12)))
        guard case .insufficient(let why)? = d.metric(.bestEffort(meters: Distance.fiveK))?.latest?.gap else {
            return XCTFail("expected a gap")
        }
        XCTAssertEqual(why.reason, .noDistanceStreams)
        XCTAssertEqual(why.excluded.map(\.reason), Array(repeating: .treadmill, count: 4))
        XCTAssertNotNil(d.metric(.predictedTime(meters: Distance.fiveK))?.latest?.gap)

        let empty = ProgressBuilder.build(activities: [], options: F.options(asOf: F.asOf(week: 12)))
        XCTAssertEqual(empty.metric(.bestEffort(meters: Distance.mile))?.latest?.gap, .baseline(.noRuns))
        XCTAssertEqual(empty.metric(.predictedTime(meters: Distance.fiveK))?.latest?.gap, .baseline(.noRuns))
    }

    func testCadenceIsInformationalUnlessRated() throws {
        var weeks = F.trend(12, start: 3.0, rate: 0)
        for i in 0..<12 { weeks[i].cadence = 165 + Double(i) }
        let d = F.dashboard(weeks, asOfWeek: 12)
        let cad = try XCTUnwrap(d.metric(.cadence))
        XCTAssertEqual(cad.polarity, .informational)
        // Basis weeks 8-11: mean of 173...176.
        XCTAssertEqual(try XCTUnwrap(cad.latest?.value), 174.5, accuracy: 1e-9)
        XCTAssertEqual(cad.change(overWeeks: 4).direction, .notRated)
        let rated = F.dashboard(weeks, asOfWeek: 12) { $0.cadencePolarity = .higherIsBetter }
        XCTAssertEqual(rated.metric(.cadence)?.change(overWeeks: 4).direction, .improving)

        for i in 0..<12 { weeks[i].cadence = nil }
        let none = F.dashboard(weeks, asOfWeek: 12)
        guard case .insufficient(let why)? = none.metric(.cadence)?.latest?.gap else { return XCTFail("expected a gap") }
        XCTAssertEqual(why.reason, .noCadence)
    }

    func testSeriesCoversTheLongestChangeSpan() throws {
        let d = F.dashboard(F.trend(24, start: 3.0, rate: 0), asOfWeek: 24) { $0.changeWeeks = [4, 20] }
        let m = try XCTUnwrap(d.metric(.weeklyLoad))
        XCTAssertEqual(m.series.count, 21)
        XCTAssertEqual(m.changes.map(\.weeks), [4, 20])
        XCTAssertEqual(m.change(overWeeks: 20).direction, .notRated)
        XCTAssertEqual(m.change(overWeeks: 21).outcome, .unavailable(.notInSeries))
    }

    func testSnapshotsFollowCalendarDaysAcrossDaylightSaving() throws {
        let ny = TimeZone(identifier: "America/New_York")!
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 18; c.hour = 12
        let asOf = PlanCalendar.calendar(timeZone: ny).date(from: c)!
        let d = ProgressBuilder.build(activities: [], options: ProgressOptions(asOf: asOf, timeZone: ny))
        let dates = try XCTUnwrap(d.metric(.weeklyLoad)).series.map(\.asOf)
        let cal = PlanCalendar.calendar(timeZone: ny)
        XCTAssertTrue(dates.allSatisfy { cal.component(.hour, from: $0) == 12 && cal.component(.weekday, from: $0) == 4 })
    }

    func testTrailingWindowDefaultsTo28DaysForEitherInitializer() {
        let asOf = F.asOf(week: 12)
        XCTAssertEqual(ProgressOptions(asOf: asOf, timeZone: F.utc).baseline.recentDays, 28)
        XCTAssertEqual(ProgressOptions(baseline: BaselineOptions(asOf: asOf, timeZone: F.utc)).baseline.recentDays, 28)
        XCTAssertEqual(ProgressOptions(baseline: BaselineOptions(asOf: asOf, timeZone: F.utc),
                                       trailingWindowDays: 42).baseline.recentDays, 42)
    }

    func testInvalidOptions() {
        let asOf = F.asOf(week: 12)
        var bad: [ProgressOptions] = []
        bad.append(F.options(asOf: asOf) { $0.seriesWeeks = 0 })
        bad.append(F.options(asOf: asOf) { $0.changeWeeks = [0] })
        bad.append(F.options(asOf: asOf) { $0.changeWeeks = [ProgressOptions.maximumSeriesWeeks + 1] })
        bad.append(F.options(asOf: asOf) { $0.noise.hrv = NoiseThreshold(relative: .nan) })
        bad.append(F.options(asOf: asOf) { $0.noise.cadence = NoiseThreshold(absolute: -1) })
        bad.append(F.options(asOf: asOf) { $0.predictionTargets = [.infinity] })
        bad.append(F.options(asOf: asOf) { $0.bestEffortDistances = [0] })
        bad.append(F.options(asOf: asOf) { $0.easyShareTarget = 0.7...Double.infinity })
        bad.append(F.options(asOf: asOf) { $0.cadencePolarity = .towardRange(-Double.infinity...180) })
        bad.append(F.options(asOf: asOf) { $0.baseline.recentDays = 0 })
        bad.append(F.options(asOf: Date(timeIntervalSinceReferenceDate: .nan)))
        for o in bad {
            XCTAssertFalse(o.isValid)
            let d = ProgressBuilder.build(activities: F.history(F.trend(12, start: 3, rate: 0)), options: o)
            XCTAssertFalse(d.optionsAreValid)
            XCTAssertTrue(d.metrics.allSatisfy { $0.latest?.gap == .baseline(.invalidInput) })
            XCTAssertEqual(d.summary().verdict, .nothingMoved([.invalidOptions]))
        }
        XCTAssertTrue(F.options(asOf: asOf).isValid)
    }
}
