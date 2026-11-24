import XCTest
@testable import CoachCore

// SPEC.md 0.8, 3.5 rule 7 (owner-approved Nov 24, #93): the engine, the
// checker and the builder read the return after a pain stop of more than 14
// days the same way: the restart after a week run short, its floor, and the
// rolling 4-week check counting the stop's and the return's weeks at the
// pre-stop level. Each week's own time is read, never its time before an
// easy-run cap (#54). Hand-worked numbers; synthetic data only.
final class PainReturnRestartAgreementTests: XCTestCase {
    private typealias F = PlanFixture
    private typealias A = AdaptFixture
    private let utc = PlanFixture.utc
    private let m = 60.0

    private func monday(_ week: Int) -> Date { PlanCalendar.weekStart(containing: F.date(week: week, day: 0), timeZone: utc) }

    /// Easy weeks of the given minutes (0 leaves a week empty), from week `start`.
    private func weeks(_ minutes: [Double], start: Int = 0, prefix: String) -> [PlannedWorkout] {
        minutes.enumerated().flatMap { k, v in v > 0 ? F.easyWeek(start + k, minutes: v, prefix: prefix) : [] }
    }

    private func check(_ history: [PlannedWorkout], _ planned: [PlannedWorkout], regrowth: GuardrailRegrowth = .none) -> GuardrailReport {
        GuardrailChecker.check(history: history, planned: planned, timeZone: utc, regrowth: regrowth)
    }

    private func weekly(_ r: GuardrailReport) -> [GuardrailViolation] { r.violations.filter { $0.rule == .weeklyIncrease } }
    private func rolling(_ r: GuardrailReport) -> [GuardrailViolation] { r.violations.filter { $0.rule == .fourWeekIncrease } }

    // MARK: The checker reads the restart as the engine does

    /// The pre-stop level is 214 (four weeks of it, then three stop weeks). Week 7 (return week 1, step 1) is run at
    /// 100 against its ceiling of 0.65 x 214 = 139.1: under 139.1 / 1.2 = 115.9, so short. The next week is step 1
    /// again: at most max(139.1, 100) = 139.1 min = 8,346 s, the engine's hold for a restarted week.
    func testTheCheckerRestartsAfterAShortReturnWeek() throws {
        let h = weeks([214, 214, 214, 214, 0, 0, 0, 100], prefix: "h")
        XCTAssertTrue(weekly(check(h, weeks([139], start: 8, prefix: "p"))).isEmpty)
        let v = try XCTUnwrap(weekly(check(h, weeks([140], start: 8, prefix: "p"))).first)
        XCTAssertEqual(v.allowed, 0.65 * 214 * m, accuracy: 1e-6)
        // Run at 120 (>= 115.9) it is not short: the next week is step 2, 0.825 x 214 = 176.55.
        let ok = weeks([214, 214, 214, 214, 0, 0, 0, 120], prefix: "h")
        XCTAssertTrue(weekly(check(ok, weeks([176], start: 8, prefix: "p"))).isEmpty)
        XCTAssertEqual(try XCTUnwrap(weekly(check(ok, weeks([177], start: 8, prefix: "p"))).first).allowed, 0.825 * 214 * m, accuracy: 1e-6)
    }

    /// Weeks 7 and 8 at 139 and 176 are on the steps; week 9 is step 3 (214) run at 150, under 214 / 1.2 = 178.3, so
    /// short. The next week's ceiling is max(139.1, 150) = 150 min = 9,000 s: never below the week run.
    func testTheCheckersRestartCeilingIsNeverBelowTheWeekRun() throws {
        let h = weeks([214, 214, 214, 214, 0, 0, 0, 139, 176, 150], prefix: "h")
        XCTAssertTrue(weekly(check(h, weeks([150], start: 10, prefix: "p"))).isEmpty)
        XCTAssertEqual(try XCTUnwrap(weekly(check(h, weeks([151], start: 10, prefix: "p"))).first).allowed, 150 * m, accuracy: 1e-6)
    }

    // MARK: The rolling 4-week check

    /// A stop of more than 14 days whose weeks the checker can't see as a break (30% of the level, above the 25% line),
    /// as the engine hands them in: weeks 4 to 9 (the stop's weeks through the end of the return) count at the
    /// pre-stop level 200. Weeks: 200 x 4, 60 x 3, then 130, 165 and 200, planned 200 a week. At week 13 the 4 weeks
    /// before the window are weeks 6 to 9: 4 x 200 = 800, so 1.3 x 800 = 1,040 >= the 800 of weeks 10 to 13. Read at
    /// their volume they are 60 + 130 + 165 + 200 = 555, and 1.3 x 555 = 721.5 < 800.
    func testTheRollingCheckCountsTheStopAndTheReturnAtThePreStopLevel() throws {
        let h = weeks([200, 200, 200, 200, 60, 60, 60, 130, 165, 200], prefix: "h")
        let p = weeks([200, 200, 200, 200, 200], start: 10, prefix: "p")
        let stopAndReturn = GuardrailRegrowth(cutWeeks: (4...9).map { .init(weekStart: monday($0), original: 200 * m) })
        XCTAssertTrue(rolling(check(h, p, regrowth: stopAndReturn)).isEmpty)
        let plain = rolling(check(h, p))
        XCTAssertEqual(plain.map { PlanCalendar.weekStart(containing: $0.weekStart, timeZone: utc) }.sorted(),
                       [monday(10), monday(11), monday(12), monday(13)].sorted(), "read at their volume, weeks 10 to 13 refuse")
        let w13 = try XCTUnwrap(plain.first { $0.weekStart == monday(13) })
        XCTAssertEqual(w13.allowed, 1.3 * 555 * m, accuracy: 1e-6)
    }

    /// Own time (#54): week 7, the first return week, is run at 100 min with 40 min cut by an easy-run cap (140
    /// before it). Against its ceiling of 130 it is short at its own 100 (under 130 / 1.2 = 108.3), not at 140, so the
    /// return restarts and runs a week longer: week 8 at 165 against step 1's 130 is not short, week 9 at 200 against
    /// step 2's 165, week 10 at 170 against step 3's 200 (170 >= 166.7) ends it. All of weeks 7 to 10 count at the
    /// level 200 in the rolling check: at week 14 the 4 earlier weeks are 4 x 200 = 800, so 1.3 x 800 = 1,040 >= the
    /// 1,020 of weeks 11 to 14. Read at the time before the cap the return would have ended at week 9, week 10 would
    /// count at 170, and 1.3 x 770 = 1,001 < 1,020 would refuse.
    func testTheReturnIsReadAtEachWeeksOwnTimeNotItsTimeBeforeACap() throws {
        let h = weeks([200, 200, 200, 200, 0, 0, 0, 100, 165, 200, 170], prefix: "h")
        let p = weeks([255, 255, 255, 255], start: 11, prefix: "p")
        let cap = GuardrailPreCap(weeks: [PreCapWeek(weekStart: monday(7), secondsBeforeCap: 140 * m, secondsCut: 40 * m)])
        let r = rolling(check(h, p, regrowth: GuardrailRegrowth(preCap: cap)))
        XCTAssertFalse(r.contains { $0.weekStart == monday(14) }, "\(r.map(\.explanation))")
        // The same weeks with no cap are read the same.
        XCTAssertFalse(rolling(check(h, p)).contains { $0.weekStart == monday(14) })
    }

    // MARK: The builder

    private func input(days: [PlanWeekday], startWeek: Int, recent: Double) -> PlanInput {
        let monday = F.date(week: startWeek, day: 0, hour: 0)
        let race = monday.addingTimeInterval(Double(11 * 7 + 6) * 86_400 + 8 * 3600)
        return PlanInput(raceDistanceMeters: Distance.tenK, raceDate: race, startDate: monday, trainingDays: Set(days),
                         longRunDay: days.last!, maxSessionSeconds: nil, recentWeeklySeconds: recent * m,
                         recentLongRunSeconds: nil, heartRateZones: HRZones(lthr: 168),
                         easyPace: EasyPaceSample(secondsPerKm: 360, heartRate: 140),
                         fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: 25 * 60))
    }

    /// The builder after a stop of three weeks from a level of 300 min, return week 1 run at `back` minutes: its first
    /// week is at most the restart's ceiling (back 150, under 0.65 x 300 / 1.2 = 162.5: max(195, 150) = 195) or the next
    /// step's (back 195: 0.825 x 300 = 247.5), and every week it builds passes the checker. (`recent` is 90 min, the
    /// builder's minimum, which the 4-week mean of the history allows.)
    private func firstPlannedWeek(back: Double) throws -> (minutes: Double, passes: Bool) {
        let days: [PlanWeekday] = [.monday, .wednesday, .friday, .sunday]
        let history = weeks([300, 300, 300, 300, 0, 0, 0, back], prefix: "h")
        let result = PlanBuilder.build(input(days: days, startWeek: 8, recent: 90), history: history, timeZone: utc)
        let plan = try XCTUnwrap(result.plan, "\(result.issues)")
        let first = plan.weeks[0].workouts.reduce(0) { $0 + $1.durationSeconds } / m
        let all = plan.weeks.flatMap(\.workouts)
        return (first, GuardrailChecker.check(history: history, planned: all, timeZone: utc).passed)
    }

    func testTheBuilderRestartsAfterAShortReturnWeek() throws {
        let short = try firstPlannedWeek(back: 150)
        XCTAssertLessThanOrEqual(short.minutes, 0.65 * 300 + 1e-6, "the restart: step 1 again")
        XCTAssertTrue(short.passes)
        let steady = try firstPlannedWeek(back: 195)
        XCTAssertLessThanOrEqual(steady.minutes, 0.825 * 300 + 1e-6, "step 2")
        XCTAssertTrue(steady.passes)
    }

    // MARK: End to end in the engine

    /// A rest-mode stop of more than 14 days, the test run, and the return: week 4 is run at half of what is planned
    /// (short), so week 5 is step 1 again (at most 139.1 min) instead of step 2 (176.55); the weeks then follow the
    /// steps, the return ends, and at every event the checker, run independently with the regrowth the engine hands
    /// it, accepts the plan.
    func testStopReturnShortWeekRestartAndTheCheckerAccepts() throws {
        typealias D = A.Driver
        let ctx = AdaptationContext(zones: A.zones, timeZone: A.tz, tracksPain: true, usualPainSeed: 2)
        var d = D(plan: A.weeks(0..<16), context: ctx)
        d.follow(until: A.date(week: 0, day: 1, hour: 8)) { _ in A.RunSpec() }
        d.afterRun(week: 0, day: 1, 3, worsened: true, moved: true, activityID: "run-t0")
        for day in 2..<21 { d.morning(week: day / 7, day: day % 7, 3) }
        d.morning(week: 3, day: 0, 2)
        d.morning(week: 3, day: 1, 2)
        let test = try XCTUnwrap(d.testSession)
        d.runTest(2)
        d.morningAfter(test.date, 2)
        XCTAssertNil(d.state.painStop)
        let start = try XCTUnwrap(d.state.painRecovery.painReturn)
        XCTAssertGreaterThan(start.daysOff ?? 0, 14)
        XCTAssertEqual(start.level ?? 0, 214 * m, accuracy: 1e-6)

        var ceilings: [Double] = []
        var ended: Int?
        for week in 4..<14 where ended == nil {
            d.handFreshPlan(A.weeks(week..<16))
            d.day(A.date(week: week, day: 0, hour: 5))
            ceilings.append(A.weekVolume(week, d.plan) / m)
            // Week 4 is run at half of what is planned; the others as planned.
            for day in 0..<7 { d.runAsPlanned(on: A.date(week: week, day: day), scale: week == 4 ? 0.5 : 1) }
            d.day(A.date(week: week + 1, day: 0, hour: 5))
            if d.state.painRecovery.painReturn == nil { ended = week + 1 }
        }
        let end = try XCTUnwrap(ended, "the return ends: \(ceilings)")
        let ran = (4..<end).map { A.weekVolume($0, d.history) / m }
        print("restart scenario: planned \(ceilings) ran \(ran)")
        XCTAssertLessThan(ran[0], ceilings[0] / 1.2, "week 4 was run short")
        XCTAssertLessThanOrEqual(ceilings[1], 0.65 * 214 + 1e-6, "week 5 is step 1 again, not step 2's 176.55")
        XCTAssertGreaterThan(ceilings[1], ran[0], "and above the half run")
        if ceilings.count > 2 { XCTAssertLessThanOrEqual(ceilings[2], 0.825 * 214 + 1e-6, "week 6 is step 2") }
        XCTAssertTrue(d.changes.contains { $0.kind == .painReturnStep && $0.explanation.contains("restarts") })
        XCTAssertTrue(d.changes.contains { $0.kind == .painReturnStep && $0.explanation.contains("complete") })
        assertAdaptationSound(d.outcomes)
        // The weeks from the stop's start through the return count at the level in what the engine hands the checker.
        let last = try XCTUnwrap(d.outcomes.last)
        _ = last
        let cut = d.state.planSnapshot.cut
        for w in 0..<(end) { XCTAssertEqual(cut.first { $0.week == monday(w) }?.volume ?? 0, 214 * m, accuracy: 1e-6, "week \(w) counts at the level") }
        d.handFreshPlan(A.weeks(end..<16))
        d.day(A.date(week: end, day: 0, hour: 6))
        XCTAssertTrue(d.plan.contains { $0.kind.isQuality }, "quality comes back")
        assertAdaptationSound(d.outcomes)
    }

    // MARK: Behaviour is unchanged where rule 7's restart doesn't apply

    private func builtWeeks(days: [PlanWeekday], weekly: Double, weeks n: Int) throws -> [Int] {
        let monday = F.date(week: 8, day: 0, hour: 0)
        let race = monday.addingTimeInterval(Double((n - 1) * 7 + 6) * 86_400 + 8 * 3600)
        let i = PlanInput(raceDistanceMeters: Distance.tenK, raceDate: race, startDate: monday, trainingDays: Set(days),
                          longRunDay: days.last!, maxSessionSeconds: nil, recentWeeklySeconds: weekly * m,
                          recentLongRunSeconds: nil, heartRateZones: HRZones(lthr: 168),
                          easyPace: EasyPaceSample(secondsPerKm: 360, heartRate: 140),
                          fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: 25 * 60))
        let plan = try XCTUnwrap(PlanBuilder.build(i, history: [], timeZone: utc).plan)
        return plan.weeks.map { Int(($0.workouts.reduce(0) { $0 + $1.durationSeconds } / m).rounded()) }
    }

    /// Built plans, as on main at 93ea76c (weekly minutes of each week, taken before this change).
    func testBuiltPlansAreUnchanged() throws {
        XCTAssertEqual(try builtWeeks(days: [.monday, .wednesday, .friday, .saturday, .sunday], weekly: 360, weeks: 12),
                       [360, 388, 419, 330, 432, 432, 432, 323, 432, 432, 323, 222])
        XCTAssertEqual(try builtWeeks(days: [.tuesday, .thursday, .saturday], weekly: 200, weeks: 10),
                       [195, 210, 225, 174, 237, 237, 183, 237, 165, 147])
        XCTAssertEqual(try builtWeeks(days: [.tuesday, .wednesday, .friday, .sunday], weekly: 280, weeks: 14),
                       [279, 301, 326, 244, 335, 336, 336, 251, 336, 336, 251, 336, 252, 185])
    }

    /// A pain return after a stop of 14 days off or fewer (rule 6's regrowth, which has its own restart), as on
    /// main: the minutes run each week of the return, the app re-planning at full volume each Monday.
    func testAShortStopsReturnIsUnchanged() throws {
        let ctx = AdaptationContext(zones: A.zones, timeZone: A.tz, tracksPain: true, usualPainSeed: 2)
        var e = A.Driver(plan: A.weeks(0..<12), context: ctx)
        e.follow(until: A.date(week: 0, day: 1, hour: 8)) { _ in A.RunSpec() }
        e.afterRun(week: 0, day: 1, 3, worsened: true, moved: true, activityID: "run-t0")
        e.morning(week: 0, day: 2, 2)
        e.morning(week: 0, day: 3, 2)
        e.runTest(2)
        e.morningAfter(try XCTUnwrap(e.testSession.map(\.date) ?? e.history.last?.date), 2)
        for day in 4..<7 { e.runAsPlanned(on: A.date(week: 0, day: day)) }
        var vols: [Double] = []
        for week in 1..<9 {
            e.handFreshPlan(A.weeks(week..<12))
            for day in 0..<7 { e.runAsPlanned(on: A.date(week: week, day: day)) }
            vols.append(A.weekVolume(week, e.history) / m)
            if e.state.painRecovery.painReturn == nil { break }
        }
        XCTAssertEqual(vols, [117, 176, 140, 214, 214])
        XCTAssertNil(e.state.painRecovery.painReturn?.restartWeek)
        XCTAssertNil(e.state.painRecovery.painReturn?.judgedThrough, "the restart reading is for stops of more than 14 days")
    }
}
