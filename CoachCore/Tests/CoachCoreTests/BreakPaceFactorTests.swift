import XCTest
@testable import CoachCore

// Paces after a break (SPEC 3.5 rule 4, #28). Synthetic runners only. Factors
// and day counts below are worked out by hand from [8]'s table and SPEC's day
// counting; day n is n days after `PlanFixture.firstMonday` (a Monday), so
// day 56 is the Monday of week 8 and days 28 to 34 are week 5.

final class BreakPaceFactorTableTests: XCTestCase {
    func testTheTableRowsExactly() {
        let rows: [(Int, Double)] = [(0, 1.000), (5, 1.000), (6, 0.997), (7, 0.994), (10, 0.985), (14, 0.973),
                                     (21, 0.952), (28, 0.931), (35, 0.910), (42, 0.889), (49, 0.868), (56, 0.847),
                                     (63, 0.826), (70, 0.805), (72, 0.800)]
        for (days, factor) in rows { XCTAssertEqual(BreakPaceFactor.factor(daysOff: days), factor, "\(days) days") }
    }

    func testACountBetweenRowsTakesTheLongerRow() {
        // 8 and 9 use the 10-day row; 11 to 13 the 14-day row; 15 the 21-day row.
        for d in [8, 9] { XCTAssertEqual(BreakPaceFactor.factor(daysOff: d), 0.985, "\(d)") }
        for d in [11, 12, 13] { XCTAssertEqual(BreakPaceFactor.factor(daysOff: d), 0.973, "\(d)") }
        XCTAssertEqual(BreakPaceFactor.factor(daysOff: 15), 0.952)
        XCTAssertEqual(BreakPaceFactor.factor(daysOff: 22), 0.931)
        XCTAssertEqual(BreakPaceFactor.factor(daysOff: 36), 0.889)
        // 71 days rounds up to the last row.
        XCTAssertEqual(BreakPaceFactor.factor(daysOff: 71), 0.800)
    }

    func testPastTheLastRowAndBeforeTheFirst() {
        for d in [72, 73, 100, 10_000, Int.max] { XCTAssertEqual(BreakPaceFactor.factor(daysOff: d), 0.800, "\(d)") }
        for d in [0, -1, Int.min] { XCTAssertEqual(BreakPaceFactor.factor(daysOff: d), 1.0, "\(d)") }
    }

    func testTheFactorFallsOneStepPerWeekFrom28DaysOn() {
        // 0.021 lower for each further week: 28 days 0.931, then 0.910, 0.889, ... 0.805 at 70.
        var expected = 0.931
        for days in stride(from: 28, through: 70, by: 7) {
            XCTAssertEqual(BreakPaceFactor.factor(daysOff: days), expected, accuracy: 1e-12, "\(days)")
            expected -= 0.021
        }
    }

    func testTheFactorFallsAsDaysGrow() {
        var last = 1.0
        for d in 0...120 {
            let f = BreakPaceFactor.factor(daysOff: d)
            XCTAssertLessThanOrEqual(f, last, "\(d)")
            last = f
        }
    }

    func testTheLiftOverTheReturnWeeksAfterAShortBreak() {
        let f = 0.973
        XCTAssertEqual(BreakPaceFactor.effectiveFactor(f, shortBreak: true, weeksBack: 0), 1)
        XCTAssertEqual(BreakPaceFactor.effectiveFactor(f, shortBreak: true, weeksBack: 1), 0.973)
        // Halfway between the factor and 1.0: (0.973 + 1) / 2.
        XCTAssertEqual(BreakPaceFactor.effectiveFactor(f, shortBreak: true, weeksBack: 2), 0.9865, accuracy: 1e-12)
        XCTAssertEqual(BreakPaceFactor.effectiveFactor(f, shortBreak: true, weeksBack: 3), 1)
        XCTAssertEqual(BreakPaceFactor.effectiveFactor(f, shortBreak: true, weeksBack: 9), 1)
    }

    func testALongerBreakHoldsTheFactorUntilARaceEndsIt() {
        for k in [1, 2, 3, 4, 10, 40] {
            XCTAssertEqual(BreakPaceFactor.effectiveFactor(0.952, shortBreak: false, weeksBack: k), 0.952, "\(k)")
            XCTAssertEqual(BreakPaceFactor.effectiveFactor(0.952, shortBreak: false, weeksBack: k, ended: true), 1, "\(k)")
        }
        XCTAssertEqual(BreakPaceFactor.effectiveFactor(0.952, shortBreak: false, weeksBack: 0), 1)
    }

    func testAPaceIsDividedByTheFactor() {
        // 360 s/km at 0.994 of the speed is 360 / 0.994.
        XCTAssertEqual(BreakPaceFactor.pace(360, factor: 0.994), 362.17303822937623, accuracy: 1e-9)
        XCTAssertEqual(BreakPaceFactor.pace(360, factor: 1), 360)
    }

    func testNoNonsenseFactorChangesAnything() {
        for f in [Double.nan, .infinity, 0, -1, 1, 1.5] {
            XCTAssertEqual(BreakPaceFactor.effectiveFactor(f, shortBreak: false, weeksBack: 1), 1, "\(f)")
            XCTAssertEqual(BreakPaceFactor.effectiveFactor(f, shortBreak: true, weeksBack: 2), 1, "\(f)")
        }
    }
}

final class ReturnPaceScheduleTests: XCTestCase {
    private let tz = PlanFixture.utc

    private func day(_ n: Int, hour: Int = 7) -> Date { PlanFixture.firstMonday.addingTimeInterval(Double(n) * 86_400 + Double(hour) * 3600) }

    /// A 30-minute run on each given day.
    private func runs(_ days: [Int], minutes: Double = 30) -> [PlannedWorkout] {
        days.map { PlannedWorkout(id: "r\($0)", date: day($0), kind: .easy, durationSeconds: minutes * 60) }
    }

    /// A run every day from day 0 to `through`, except on the days in `off`
    /// (and with the runs at `keep` left in).
    private func daily(through: Int = 55, off: [ClosedRange<Int>] = [], keep: Set<Int> = []) -> [Int] {
        (0...through).filter { d in keep.contains(d) || !off.contains { $0.contains(d) } }
    }

    private func latest(_ days: [Int], start: Int = 56, startHour: Int = 0, firstMonday: Int = 56,
                        efforts: [AnchorEffort] = [], race: Double = Distance.tenK) -> ReturnPaceSchedule? {
        ReturnPaceSchedule.latest(history: runs(days), efforts: efforts, raceDistanceMeters: race,
                                  startDate: day(start, hour: startHour), firstMonday: day(firstMonday, hour: 0),
                                  timeZone: tz, limits: .default)
    }

    // MARK: Day counting

    func testAPlainSixDayGapIsABreakWithNoBreakWeek() throws {
        // No run on days 38 to 43: six days, none of them a whole week.
        let s = try XCTUnwrap(latest(daily(off: [38...43])))
        XCTAssertEqual(s.daysOff, 6)
        XCTAssertEqual(s.found.breakWeeks, 0)
        XCTAssertTrue(s.isShort)
        XCTAssertFalse(s.found.ongoing)
        XCTAssertEqual(s.factor, 0.997)
        // Week 1 is the week of the first run back (day 44, in the week of day 42).
        XCTAssertEqual(s.firstWeekBack, day(42, hour: 0))
        XCTAssertEqual(s.weekNumber(of: day(56, hour: 0), timeZone: tz), 3)
    }

    func testAFiveDayGapIsNoBreak() {
        XCTAssertNil(latest(daily(off: [38...42])))
        // Nor is steady running, or a run every other day.
        XCTAssertNil(latest(daily()))
        XCTAssertNil(latest((0...55).filter { $0 % 2 == 0 }))
    }

    func testOneBreakWeekWithAShortRunStillCountsAllSevenDays() throws {
        // Week 6 (days 35 to 41) holds one 30-minute run on day 38: a break week
        // (30 of the 210 minutes before it is under the quarter line), and
        // every day of it counts as off.
        let s = try XCTUnwrap(latest(daily(off: [35...41], keep: [38])))
        XCTAssertEqual(s.daysOff, 7)
        XCTAssertEqual(s.found.breakWeeks, 1)
        XCTAssertTrue(s.isShort)
        XCTAssertEqual(s.factor, 0.994)
        XCTAssertEqual(s.firstWeekBack, day(42, hour: 0), "the ramp's week 1 is the week after the break week")
    }

    func testABreakWeekPlusDaysOffEitherSide() throws {
        // Days 33, 34 and 42, 43 are also run-free: 2 + 7 + 2 = 11 days, the 14-day row.
        let s = try XCTUnwrap(latest(daily(off: [33...43], keep: [38])))
        XCTAssertEqual(s.daysOff, 11)
        XCTAssertEqual(s.found.breakWeeks, 1)
        XCTAssertEqual(s.factor, 0.973)
        // The first run back (day 44) is a Wednesday, but the ramp's week 1 is the week after the break week.
        XCTAssertEqual(s.firstWeekBack, day(42, hour: 0))
    }

    func testTwoBreakWeeksPlusDaysOffEitherSideIsShortByWeeks() throws {
        // Days 33 to 50 off but for short runs on 38 and 45: 18 days, over 14, yet two
        // break weeks are a short break.
        let s = try XCTUnwrap(latest(daily(off: [33...50], keep: [38, 45])))
        XCTAssertEqual(s.daysOff, 18)
        XCTAssertEqual(s.found.breakWeeks, 2)
        XCTAssertTrue(s.isShort)
        XCTAssertEqual(s.factor, 0.952)
        XCTAssertEqual(s.firstWeekBack, day(49, hour: 0))
        XCTAssertEqual(s.weekNumber(of: day(56, hour: 0), timeZone: tz), 2)
    }

    func testThreeBreakWeeksAreALongerBreak() throws {
        let s = try XCTUnwrap(latest(daily(off: [28...48], keep: [31, 38, 45])))
        XCTAssertEqual(s.daysOff, 21)
        XCTAssertEqual(s.found.breakWeeks, 3)
        XCTAssertFalse(s.isShort)
        XCTAssertEqual(s.factor, 0.952)
        XCTAssertEqual(s.firstWeekBack, day(49, hour: 0))
    }

    func testABreakStillRunningAtTheStartCountsToTheDayBeforeAndStartsWeekOneAtTheFirstWeek() throws {
        // Runs to day 41, none since: weeks 7 and 8 (days 42 to 55) are two break weeks, 14 days.
        let s = try XCTUnwrap(latest(daily(through: 41)))
        XCTAssertEqual(s.daysOff, 14)
        XCTAssertTrue(s.found.ongoing)
        XCTAssertEqual(s.factor, 0.973)
        XCTAssertEqual(s.firstWeekBack, day(56, hour: 0), "the first run back is in the plan")
        XCTAssertEqual(s.weekNumber(of: day(56, hour: 0), timeZone: tz), 1)
    }

    func testAMidWeekStartCountsOnlyTheDaysKnownSoFar() throws {
        // Runs to day 44 (a Wednesday). The plan starts on Friday, day 53, with the
        // next Monday, day 56, as its first week. Days 45 to 52 are off: 8.
        let s = try XCTUnwrap(latest(daily(through: 44), start: 53, startHour: 7))
        XCTAssertEqual(s.daysOff, 8)
        XCTAssertEqual(s.factor, 0.985)
        XCTAssertTrue(s.isShort)
        XCTAssertTrue(s.found.ongoing)
        XCTAssertEqual(s.firstWeekBack, day(56, hour: 0))
    }

    func testRestDaysAndZeroLengthSessionsAreNotRuns() throws {
        var h = runs(daily(off: [38...43]))
        h.append(PlannedWorkout(id: "rest", date: day(40), kind: .rest, durationSeconds: 3600))
        h.append(PlannedWorkout(id: "zero", date: day(41), kind: .easy, durationSeconds: 0))
        let s = try XCTUnwrap(ReturnPaceSchedule.latest(history: h, efforts: [], raceDistanceMeters: Distance.tenK,
                                                       startDate: day(56, hour: 0), firstMonday: day(56, hour: 0),
                                                       timeZone: tz, limits: .default))
        XCTAssertEqual(s.daysOff, 6)
        // A run of unknown length still happened.
        var unknown = runs(daily(off: [38...43]))
        unknown.append(PlannedWorkout(id: "nan", date: day(40), kind: .easy, durationSeconds: .nan))
        XCTAssertNil(ReturnPaceSchedule.latest(history: unknown, efforts: [], raceDistanceMeters: Distance.tenK,
                                              startDate: day(56, hour: 0), firstMonday: day(56, hour: 0),
                                              timeZone: tz, limits: .default))
    }

    func testNoHistoryIsNoBreak() {
        XCTAssertNil(latest([]))
    }

    func testAnOldShortBreakNoLongerMatters() {
        // Back for weeks 4 and on: the 6-day gap is behind the plan's first week.
        XCTAssertNil(latest(daily(through: 97, off: [10...15]), start: 98, firstMonday: 98))
    }

    // MARK: Marked races and the pre-break anchor

    private func effort(_ seconds: Double, day d: Int, race: Bool, meters: Double = Distance.fiveK) -> AnchorEffort {
        AnchorEffort(anchor: RaceEquivalent(distanceMeters: meters, seconds: seconds), date: day(d), isMarkedRace: race)
    }

    func testOnlyAMarkedRaceAfterTheBreakEndsIt() throws {
        let h = daily(off: [33...50], keep: [38, 45])
        // Before the break: a race. After it: a training best effort and a race.
        let pre = effort(1500, day: 20, race: true)
        let bestEffort = effort(1400, day: 52, race: false)
        let race = effort(1440, day: 53, race: true)
        let none = try XCTUnwrap(latest(h, efforts: [pre, bestEffort]))
        XCTAssertNil(none.raceAnchor, "a training best effort doesn't end the factor")
        XCTAssertEqual(none.preBreakAnchor, pre.anchor)
        let ended = try XCTUnwrap(latest(h, efforts: [pre, bestEffort, race]))
        XCTAssertEqual(ended.raceAnchor, race.anchor)
        XCTAssertEqual(ended.preBreakAnchor, pre.anchor)
        XCTAssertEqual(ended.factor(week: 2), 1)
        XCTAssertEqual(none.factor(week: 2), 0.976, accuracy: 1e-12)
        // A race before the break, or one dated inside it, is no race after it.
        XCTAssertNil(try XCTUnwrap(latest(h, efforts: [pre])).raceAnchor)
        XCTAssertNil(try XCTUnwrap(latest(h, efforts: [effort(1440, day: 40, race: true)])).raceAnchor)
        // Efforts that aren't valid anchors are ignored.
        let bad = AnchorEffort(anchor: RaceEquivalent(distanceMeters: 1000, seconds: 200), date: day(53), isMarkedRace: true)
        XCTAssertNil(try XCTUnwrap(latest(h, efforts: [bad])).raceAnchor)
    }

    func testTheBestRaceAfterTheBreakIsTheOneClosestToTheGoalDistance() throws {
        let h = daily(off: [33...50], keep: [38, 45])
        let fiveK = effort(1440, day: 52, race: true)
        let tenK = effort(3000, day: 53, race: true, meters: Distance.tenK)
        let s = try XCTUnwrap(latest(h, efforts: [fiveK, tenK], race: Distance.halfMarathon))
        XCTAssertEqual(s.raceAnchor, tenK.anchor)
    }

    // MARK: Paces

    private let zones = HRZones(lthr: 165)!

    /// Easy 6:00/km, a 25:00 5K anchor, goal pace 5:00/km.
    private func model(anchor: RaceEquivalent? = RaceEquivalent(distanceMeters: Distance.fiveK, seconds: 1500)) -> TargetModel {
        TargetModel(zones: zones, category: .tenK, easyPace: 360,
                    thresholdPace: anchor.flatMap { TargetModel.riegelPace(anchor: $0, seconds: 3600) },
                    vo2maxPace: anchor.flatMap { TargetModel.riegelPace(anchor: $0, seconds: 720) }, racePace: 300)
    }

    private let anchor25 = RaceEquivalent(distanceMeters: Distance.fiveK, seconds: 1500)

    private func targets(_ s: ReturnPaceSchedule, week k: Int, anchor: RaceEquivalent? = nil,
                         base: TargetModel? = nil) -> TargetModel {
        let a = anchor ?? anchor25
        let monday = s.firstWeekBack.addingTimeInterval(Double(k - 1) * 7 * 86_400)
        return s.targets(base ?? model(anchor: a), fitnessAnchor: a, weekStart: monday, timeZone: tz)
    }

    func testAShortBreaksPacesLiftOverWeeksOneToThree() throws {
        // 14 days off with no break week... two break weeks, still running: 0.973.
        let s = try XCTUnwrap(latest(daily(through: 41)))
        let base = model()
        let f1 = 0.973, f2 = (0.973 + 1) / 2
        let w1 = targets(s, week: 1), w2 = targets(s, week: 2), w3 = targets(s, week: 3), w4 = targets(s, week: 4)
        func check(_ t: TargetModel, _ f: Double, _ label: String) throws {
            XCTAssertEqual(try XCTUnwrap(t.easyPace), 360 / f, accuracy: 1e-9, label)
            XCTAssertEqual(try XCTUnwrap(t.thresholdPace), try XCTUnwrap(base.thresholdPace) / f, accuracy: 1e-9, label)
            XCTAssertEqual(try XCTUnwrap(t.vo2maxPace), try XCTUnwrap(base.vo2maxPace) / f, accuracy: 1e-9, label)
            XCTAssertEqual(t.racePace, 300, label)
        }
        try check(w1, f1, "week 1")
        try check(w2, f2, "week 2")
        try check(w3, 1, "week 3")
        try check(w4, 1, "week 4")
        // Hand check of week 1's easy pace: 360 / 0.973 = 369.9897...
        XCTAssertEqual(try XCTUnwrap(w1.easyPace), 369.9897225077081, accuracy: 1e-9)
        // Week 3 and on are the model itself.
        XCTAssertEqual(w3.easyPace, base.easyPace)
        XCTAssertEqual(w3.thresholdPace, base.thresholdPace)
        XCTAssertEqual(w4.vo2maxPace, base.vo2maxPace)
    }

    func testHeartRateTargetsAndRacePaceAreNeverChanged() throws {
        let s = try XCTUnwrap(latest(daily(through: 41)))
        let base = model()
        for k in 1...6 {
            let t = targets(s, week: k)
            for i in WorkoutIntensity.allCases {
                XCTAssertEqual(t.heartRate(i), base.heartRate(i), "week \(k) \(i)")
            }
            XCTAssertEqual(t.pace(.racePace), base.pace(.racePace))
            XCTAssertEqual(t.pace(.race), base.pace(.race))
            XCTAssertEqual(t.target(.threshold).heartRate, base.target(.threshold).heartRate)
        }
    }

    func testNoAnchorLeavesNoThresholdPaceToSlow() throws {
        let s = try XCTUnwrap(latest(daily(through: 41)))
        let base = model(anchor: nil)
        let t = s.targets(base, fitnessAnchor: nil, weekStart: day(56, hour: 0), timeZone: tz)
        XCTAssertNil(t.thresholdPace)
        XCTAssertNil(t.vo2maxPace)
        XCTAssertEqual(try XCTUnwrap(t.easyPace), 360 / 0.973, accuracy: 1e-9)
        // And no easy pace sample means no easy pace.
        let noEasy = TargetModel(zones: zones, category: .tenK, easyPace: nil, thresholdPace: nil, vo2maxPace: nil, racePace: nil)
        XCTAssertNil(s.targets(noEasy, fitnessAnchor: nil, weekStart: day(56, hour: 0), timeZone: tz).easyPace)
    }

    func testALongerBreakHoldsTheFactorPastWeekThreeUntilAMarkedRaceAppears() throws {
        let h = daily(off: [28...48], keep: [31, 38, 45])
        let held = try XCTUnwrap(latest(h, efforts: [effort(1400, day: 52, race: false)]))
        XCTAssertFalse(held.isShort)
        let base = model()
        for k in [1, 2, 3, 4, 10, 30] {
            let t = targets(held, week: k)
            XCTAssertEqual(try XCTUnwrap(t.easyPace), 360 / 0.952, accuracy: 1e-9, "week \(k)")
            XCTAssertEqual(try XCTUnwrap(t.thresholdPace), try XCTUnwrap(base.thresholdPace) / 0.952, accuracy: 1e-9, "week \(k)")
        }
        // A marked race after the break ends it: no slow-down in week 4 and on.
        let race = effort(1500, day: 52, race: true)
        let ended = try XCTUnwrap(latest(h, efforts: [race]))
        XCTAssertEqual(ended.raceAnchor, race.anchor)
        for k in [4, 10, 30] {
            let t = targets(ended, week: k)
            XCTAssertEqual(t.easyPace, base.easyPace, "week \(k)")
            XCTAssertEqual(t.thresholdPace, base.thresholdPace, "week \(k)")
        }
        // A race that is itself so old that the break's weeks are long past changes nothing either way.
        XCTAssertTrue(ended.affects(week: 3))
        XCTAssertFalse(ended.affects(week: 4))
        XCTAssertTrue(held.affects(week: 40))
    }

    func testAMarkedRaceBeforeTheBreakNeverEndsALongBreak() throws {
        let h = daily(off: [28...48], keep: [31, 38, 45])
        let s = try XCTUnwrap(latest(h, efforts: [effort(1500, day: 10, race: true)]))
        XCTAssertNil(s.raceAnchor)
        XCTAssertEqual(try XCTUnwrap(targets(s, week: 20).easyPace), 360 / 0.952, accuracy: 1e-9)
    }

    func testNoTrainingPaceIsFasterThanBeforeTheBreakThroughWeekThree() throws {
        // Two break weeks, back for week 7 on. A pre-break 25:00 race, then a faster 24:00 race after.
        let h = daily(off: [33...50], keep: [38, 45])
        let pre = effort(1500, day: 20, race: true)
        let faster = effort(1440, day: 52, race: true)
        let s = try XCTUnwrap(latest(h, efforts: [pre, faster]))
        let preModel = model(anchor: pre.anchor)
        let fasterModel = model(anchor: faster.anchor)
        XCTAssertLessThan(try XCTUnwrap(fasterModel.thresholdPace), try XCTUnwrap(preModel.thresholdPace))
        for k in 1...3 {
            let t = targets(s, week: k, anchor: faster.anchor, base: fasterModel)
            // The race ended the factor (1.0), but the paces stay the pre-break ones.
            XCTAssertEqual(try XCTUnwrap(t.thresholdPace), try XCTUnwrap(preModel.thresholdPace), accuracy: 1e-9, "week \(k)")
            XCTAssertEqual(try XCTUnwrap(t.vo2maxPace), try XCTUnwrap(preModel.vo2maxPace), accuracy: 1e-9, "week \(k)")
            XCTAssertEqual(try XCTUnwrap(t.easyPace), 360, "no slow-down: the race ended the factor")
        }
        // From week 4 the faster anchor's paces stand.
        let w4 = targets(s, week: 4, anchor: faster.anchor, base: fasterModel)
        XCTAssertEqual(w4.thresholdPace, fasterModel.thresholdPace)
        XCTAssertLessThan(try XCTUnwrap(w4.thresholdPace), try XCTUnwrap(preModel.thresholdPace))
    }

    func testASlowerRaceAfterTheBreakSetsSlowerPaces() throws {
        let h = daily(off: [33...50], keep: [38, 45])
        let pre = effort(1500, day: 20, race: true)
        let slower = effort(1560, day: 52, race: true)
        let s = try XCTUnwrap(latest(h, efforts: [pre, slower]))
        let slowerModel = model(anchor: slower.anchor)
        for k in 1...3 {
            let t = targets(s, week: k, anchor: slower.anchor, base: slowerModel)
            XCTAssertEqual(try XCTUnwrap(t.thresholdPace), try XCTUnwrap(slowerModel.thresholdPace), accuracy: 1e-9, "week \(k)")
        }
    }

    func testAFasterBestEffortAfterTheBreakDoesNotBeatTheFactorEither() throws {
        // A training best effort (no race) faster than the pre-break anchor: the factor stays and the pace
        // is divided from the pre-break value through week 3.
        let h = daily(off: [33...50], keep: [38, 45])
        let pre = effort(1500, day: 20, race: true)
        let fasterBest = effort(1440, day: 52, race: false)
        let s = try XCTUnwrap(latest(h, efforts: [pre, fasterBest]))
        let preModel = model(anchor: pre.anchor)
        let fasterModel = model(anchor: fasterBest.anchor)
        let t = targets(s, week: 1, anchor: fasterBest.anchor, base: fasterModel)
        XCTAssertEqual(try XCTUnwrap(t.thresholdPace), try XCTUnwrap(preModel.thresholdPace) / 0.952, accuracy: 1e-9)
        let t2 = targets(s, week: 2, anchor: fasterBest.anchor, base: fasterModel)
        XCTAssertEqual(try XCTUnwrap(t2.thresholdPace), try XCTUnwrap(preModel.thresholdPace) / ((0.952 + 1) / 2), accuracy: 1e-9)
        let t3 = targets(s, week: 3, anchor: fasterBest.anchor, base: fasterModel)
        XCTAssertEqual(try XCTUnwrap(t3.thresholdPace), try XCTUnwrap(preModel.thresholdPace), accuracy: 1e-9)
    }
}
