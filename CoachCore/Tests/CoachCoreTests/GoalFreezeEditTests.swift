import XCTest
@testable import CoachCore

// Goal or plan edits during a pain freeze (SPEC 3.5 rule 7, F2, F4, #72).
//
// Hand-worked on `FreezeFixture`: the runner has a 30-minute Monday run and the
// old plan keeps Thu 35, Sat 35 and Sun 55 (the week ends at 155 minutes). A
// check-in on Tuesday froze volume for seven days, so next week (Mon 2026-09-28)
// is held at 120 minutes: Tue 25, Thu 30 (a quality session the freeze swapped
// for easy running), Sat 25, Sun long 40 (77% of 155, a recovery week).
final class GoalFreezeEditTests: XCTestCase {
    let tz = FreezeFixture.tz
    let today = FreezeFixture.today
    let freeze = FreezeFixture.freeze
    var report: BaselineReport { FreezeFixture.report() }
    let newGoal = GoalFixture.settings(weeksAhead: 16, time: .seconds(6900), pain: .recurring(areas: ["shin"]))

    func edit(_ s: GoalSettings, from old: GoalSettings = FreezeFixture.painful, hold: FreezeHold?,
              freezes: [DateInterval] = []) -> GoalReplan {
        GoalPlanner.replan(from: old, previousPlan: nil, to: s, baseline: report, today: today, freezes: freezes, freeze: hold)
    }

    func built(_ r: GoalReplan, file: StaticString = #filePath, line: UInt = #line) throws -> GoalPlan {
        try XCTUnwrap(r.result.plan, "\(r.result.issues)", file: file, line: line)
    }

    func minutes(_ w: TrainingPlanWeek) -> Double { w.trainingSeconds / 60 }

    /// The checker, run again from outside with the freeze in force and the rest of this week as the old plan keeps it.
    func assertPasses(_ p: GoalPlan, freezes: [DateInterval]? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let again = GuardrailChecker.check(history: p.history + FreezeFixture.currentWeekRest, planned: p.plan.workouts,
                                           timeZone: tz, freezes: freezes ?? [freeze])
        XCTAssertTrue(again.passed, "\(again.violations)", file: file, line: line)
        XCTAssertTrue(p.guardrailReport.passed, file: file, line: line)
    }

    // MARK: The edit goes through

    /// Before: the same edit, with the freeze passed only as an interval, is refused for growing the frozen week.
    func testWithoutTheHoldTheEditIsStillRefusedAsBefore() throws {
        let r = edit(newGoal, hold: nil, freezes: [freeze])
        guard case .failsGuardrails(let rep)? = r.result.issues.first else { return XCTFail("\(r.result)") }
        XCTAssertEqual(Set(rep.violations.map(\.rule)), [.volumeFreeze])
    }

    func testGoalEditDuringFreezeBuildsAndKeepsTheFrozenWeekAsItWas() throws {
        let r = edit(newGoal, hold: FreezeFixture.hold())
        let p = try built(r)
        assertPasses(p)
        let week = p.plan.weeks[0]
        // Same sessions: ids, days, kinds, lengths, targets and segments (so the same volume and intensity).
        XCTAssertEqual(week.workouts, FreezeFixture.frozenWeek)
        XCTAssertEqual(week.trainingSeconds, 120 * 60)
        XCTAssertEqual(week.easySeconds, 120 * 60, "every frozen session is easy: the swapped one stays easy")
        XCTAssertEqual(week.weekStart, FreezeFixture.monday(week: 1))
        XCTAssertTrue(week.isRecoveryWeek)
        // The plan is the new goal's: the new race date, 16 weeks.
        XCTAssertEqual(p.plan.weeks.count, 16)
        XCTAssertEqual(p.plan.workouts.last?.date, newGoal.race.date)
        XCTAssertEqual(p.freezeEdit?.frozenWeekStarts, [FreezeFixture.monday(week: 1)])
        XCTAssertEqual(p.freezeEdit?.relaidWeekStarts, [])
        XCTAssertNil(p.freezeEdit?.raceWeekStart)
        // The rest of this week stays as the old plan has it.
        XCTAssertEqual(r.keptThisWeek, FreezeFixture.currentWeekRest)
        XCTAssertEqual(r.droppedThisWeek, [])
        // Indexes and ids are unique.
        XCTAssertEqual(p.plan.weeks.map(\.index), Array(0..<16))
        XCTAssertEqual(Set(p.plan.workouts.map(\.id)).count, p.plan.workouts.count)
        // The plan is still provisional: it is rebuilt on its first Monday, the freeze held again (3.5, F3).
        XCTAssertEqual(p.rebuildDate, FreezeFixture.monday(week: 1))
        XCTAssertEqual(p.plan.notes.last?.hasPrefix("This week isn't over yet"), true)
    }

    func testTheSwappedQualitySessionStaysEasy() throws {
        let p = try built(edit(newGoal, hold: FreezeFixture.hold()))
        let thursday = try XCTUnwrap(p.plan.weeks[0].workouts.first { $0.id == "old-w1-thu" })
        XCTAssertEqual(thursday.kind, .easy)
        XCTAssertEqual(thursday.prescription?.segments.map(\.intensity), [.easy])
        XCTAssertTrue(thursday.prescription?.purpose.hasPrefix("Easy run in place of the planned quality session") == true)
        XCTAssertEqual(p.plan.weeks[0].workouts.filter { $0.kind.isQuality }.count, 0)
    }

    // MARK: A swap still to come

    func pendingSwap(week: Int) -> QualitySwap {
        let original = FreezeFixture.session("old-q", week: week, .thursday, .quality(.threshold), minutes: 40)
        return QualitySwap(original: original, replacement: original.swappedToEasy())
    }

    func testAPendingSwapFallsOnTheRebuiltPlansNextQualitySession() throws {
        let plain = try built(edit(newGoal, hold: FreezeFixture.hold()))
        let swapped = try built(edit(newGoal, hold: FreezeFixture.hold(pendingSwap: pendingSwap(week: 2))))
        // The next quality session after the frozen week: the first one of the rebuilt plan.
        let next = try XCTUnwrap(plain.plan.workouts.filter { $0.kind.isQuality }.min { $0.date < $1.date })
        XCTAssertGreaterThanOrEqual(next.date, FreezeFixture.monday(week: 2))
        let after = try XCTUnwrap(swapped.plan.workouts.first { $0.id == next.id })
        XCTAssertEqual(after.kind, .easy)
        XCTAssertEqual(after.date, next.date)
        XCTAssertEqual(after.durationSeconds, next.durationSeconds, "same length, so the volume is the same")
        XCTAssertEqual(swapped.freezeEdit?.swapLandsOn, next.date)
        // Nothing else changed.
        let others = swapped.plan.workouts.filter { $0.id != next.id }
        XCTAssertEqual(others, plain.plan.workouts.filter { $0.id != next.id })
        XCTAssertEqual(swapped.plan.weeks[0], plain.plan.weeks[0])
        // The frozen week still has no quality session; the swap did not spend itself there.
        XCTAssertTrue(swapped.plan.workouts.filter { $0.kind.isQuality }.allSatisfy { $0.date > next.date })
    }

    func testASwapWhoseSessionLiesInTheFrozenWeekOrBeforeIsNotPending() throws {
        let plain = try built(edit(newGoal, hold: FreezeFixture.hold()))
        // Its session is in the frozen week (already easy there): nothing more to swap.
        let inFrozen = try built(edit(newGoal, hold: FreezeFixture.hold(pendingSwap: pendingSwap(week: 1))))
        XCTAssertEqual(inFrozen.plan, plain.plan)
        XCTAssertNil(inFrozen.freezeEdit?.swapLandsOn)
    }

    // MARK: New days or longest session

    func testChangedDaysLayTheSameWorkoutsOutAtNoMoreThanTheFrozenVolume() throws {
        // Tuesday is no longer a training day; Thursday, Saturday and Sunday still are, so the rest of this week stays.
        let days: Set<PlanWeekday> = [.monday, .thursday, .saturday, .sunday]
        let s = GoalFixture.settings(weeksAhead: 14, days: days, pain: .recurring(areas: ["shin"]))
        let p = try built(edit(s, hold: FreezeFixture.hold()))
        assertPasses(p)
        let week = p.plan.weeks[0]
        // Tuesday's easy run moves to the free day nearest it, Monday; the rest stay as they were.
        let held = FreezeFixture.frozenWeek
        let moved = try XCTUnwrap(week.workouts.first { $0.id == "old-w1-tue" })
        XCTAssertEqual(moved.date, FreezeFixture.at(week: 1, day: .monday))
        XCTAssertEqual(moved.durationSeconds, 25 * 60)
        XCTAssertEqual(moved.prescription, held[0].prescription)
        XCTAssertEqual(Array(week.workouts.filter { $0.id != "old-w1-tue" }), Array(held.dropFirst()))
        XCTAssertEqual(week.trainingSeconds, 120 * 60, "no more than the frozen volume")
        XCTAssertTrue(week.workouts.allSatisfy { days.contains(PlanWeekday(of: $0.date, timeZone: tz)) })
        XCTAssertEqual(week.workouts.map(\.kind).sorted { "\($0)" < "\($1)" }, held.map(\.kind).sorted { "\($0)" < "\($1)" },
                       "the same workouts: no new or harder session types")
        XCTAssertEqual(p.freezeEdit?.relaidWeekStarts, [FreezeFixture.monday(week: 1)])
        XCTAssertTrue(p.freezeEdit?.explanation(timeZone: tz).contains { $0.contains("moved onto your new days") } == true)
    }

    func testANewLongestSessionShortensTheFrozenSessionsThatAreTooLong() throws {
        // Two frozen weeks; the second holds a 45-minute easy run (a quality session the freeze swapped),
        // longer than the 40 minutes the runner can now fit.
        let long = DateInterval(start: freeze.start, end: FreezeFixture.at(week: 2, day: .tuesday))
        let swapped = FreezeFixture.session("old-w2-thu", week: 2, .thursday, .quality(.threshold), minutes: 45)
            .swappedToEasyKeepingTarget(reason: "pain 5/10 (SPEC 3.5).")
        let second = [FreezeFixture.session("old-w2-tue", week: 2, .tuesday, .easy, minutes: 20), swapped,
                      FreezeFixture.session("old-w2-sat", week: 2, .saturday, .easy, minutes: 20),
                      FreezeFixture.session("old-w2-sun", week: 2, .sunday, .long, minutes: 35)]
        let hold = FreezeHold(freezes: [long], sessions: FreezeFixture.currentWeekRest + FreezeFixture.frozenWeek + second)
        let s = GoalFixture.settings(weeksAhead: 14, maxSession: .seconds(40 * 60), pain: .recurring(areas: ["shin"]))
        let p = try built(edit(s, hold: hold))
        assertPasses(p, freezes: [long])
        // The first week had nothing over 40 minutes: unchanged. The second keeps its sessions, the long easy run cut to 40
        // and then to the week's 35-minute long run (no easy run is longer than it, F3), the cut time dropped.
        XCTAssertEqual(p.plan.weeks[0].workouts, FreezeFixture.frozenWeek)
        let week = p.plan.weeks[1]
        let cut = try XCTUnwrap(week.workouts.first { $0.id == "old-w2-thu" })
        XCTAssertEqual(cut.durationSeconds, 35 * 60)
        XCTAssertEqual(cut.kind, .easy)
        // Every segment in proportion: still all easy, summing to the new length.
        XCTAssertEqual(cut.prescription?.durationSeconds ?? 0, 35 * 60, accuracy: 0.001)
        XCTAssertEqual(cut.prescription?.easySeconds ?? 0, 35 * 60, accuracy: 0.001)
        XCTAssertEqual(week.trainingSeconds, (20 + 35 + 20 + 35) * 60, "less than the frozen 120 minutes, never more")
        XCTAssertEqual(week.workouts.filter { $0.id != "old-w2-thu" }, second.filter { $0.id != "old-w2-thu" })
        XCTAssertEqual(p.freezeEdit?.relaidWeekStarts, [FreezeFixture.monday(week: 2)])
    }

    func testANewLongRunDayMovesTheLongRunAndTheSessionOnThatDayGivesWay() throws {
        let s = GoalFixture.settings(weeksAhead: 14, longRunDay: .saturday, pain: .recurring(areas: ["shin"]))
        let r = edit(s, hold: FreezeFixture.hold())
        let p = try built(r)
        let week = p.plan.weeks[0]
        let long = try XCTUnwrap(week.workouts.first { $0.kind == .long })
        XCTAssertEqual(long.date, FreezeFixture.at(week: 1, day: .saturday))
        // The easy run that was on Saturday takes the long run's old Sunday.
        let easy = try XCTUnwrap(week.workouts.first { $0.id == "old-w1-sat" })
        XCTAssertEqual(easy.date, FreezeFixture.at(week: 1, day: .sunday))
        XCTAssertEqual(week.trainingSeconds, 120 * 60)
        XCTAssertEqual(week.workouts.count, 4)
        // Without the long-run-day change, a long run off its day (say, moved by a missed day) stays put.
        let same = try built(edit(newGoal, hold: FreezeFixture.hold()))
        XCTAssertEqual(same.plan.weeks[0].workouts.first { $0.kind == .long }?.date, FreezeFixture.at(week: 1, day: .sunday))
    }

    func testAWeekCutByTheEditsDroppedSessionsNeverPassesTheWeekBefore() throws {
        // Thursday and Saturday are no longer training days, so the old plan's Thursday and Saturday runs this week
        // are dropped: the week before the frozen week ends at 85 minutes (Monday 30 and Sunday 55), and the freeze holds
        // the frozen week to it, whatever it held.
        let days: Set<PlanWeekday> = [.tuesday, .friday, .sunday, .wednesday]
        let s = GoalFixture.settings(weeksAhead: 14, days: days, pain: .recurring(areas: ["shin"]))
        let r = edit(s, hold: FreezeFixture.hold())
        let p = try built(r)
        XCTAssertEqual(r.droppedThisWeek.map(\.id), ["old-w0-thu", "old-w0-sat"])
        let week = p.plan.weeks[0]
        XCTAssertLessThanOrEqual(week.trainingSeconds, 85 * 60 + 0.5)
        XCTAssertTrue(week.workouts.allSatisfy { days.contains(PlanWeekday(of: $0.date, timeZone: tz)) })
        let again = GuardrailChecker.check(history: p.history + [FreezeFixture.currentWeekRest[2]], planned: p.plan.workouts,
                                           timeZone: tz, freezes: [freeze])
        XCTAssertTrue(again.passed, "\(again.violations)")
    }

    func twoWeekFreeze(_ second: [PlannedWorkout], first: [PlannedWorkout] = FreezeFixture.frozenWeek) -> FreezeHold {
        let long = DateInterval(start: freeze.start, end: FreezeFixture.at(week: 2, day: .tuesday))
        return FreezeHold(freezes: [long], sessions: FreezeFixture.currentWeekRest + first + second)
    }

    /// Reviewer round 2, blocker 1: a quality session that finds no free day apart from the other hard days turns
    /// easy at its length, and never gives way onto a day next to another quality session (F4).
    func testAQualitySessionThatCannotBePlacedApartTurnsEasyInsteadOfStackingNextToAnother() throws {
        let second = [FreezeFixture.session("old-w2-tue", week: 2, .tuesday, .easy, minutes: 15),
                      FreezeFixture.session("old-w2-wed", week: 2, .wednesday, .quality(.threshold), minutes: 25),
                      FreezeFixture.session("old-w2-thu", week: 2, .thursday, .easy, minutes: 15),
                      FreezeFixture.session("old-w2-fri", week: 2, .friday, .quality(.fartlek), minutes: 25),
                      FreezeFixture.session("old-w2-sun", week: 2, .sunday, .long, minutes: 40)]
        let days: Set<PlanWeekday> = [.tuesday, .wednesday, .thursday, .sunday]
        let s = GoalFixture.settings(weeksAhead: 14, days: days, pain: .recurring(areas: ["shin"]))
        let hold = twoWeekFreeze(second)
        let p = try built(edit(s, hold: hold))
        assertPasses(p, freezes: hold.freezes)
        let week = p.plan.weeks[1]
        let quality = week.workouts.filter { $0.kind.isQuality }
        XCTAssertEqual(quality.map(\.id), ["old-w2-wed"], "the threshold stays; the fartlek can't sit next to it")
        let fartlek = try XCTUnwrap(week.workouts.first { $0.id == "old-w2-fri" })
        XCTAssertEqual(fartlek.kind, .easy)
        XCTAssertEqual(fartlek.durationSeconds, 25 * 60, "same length")
        XCTAssertTrue(week.workouts.allSatisfy { days.contains(PlanWeekday(of: $0.date, timeZone: tz)) })
        XCTAssertLessThanOrEqual(week.trainingSeconds, 120 * 60 + 0.5)
        // No two hard days in a row, long run included as far as the builder counts them.
        let hardDays = quality.map { PlanWeekday(of: $0.date, timeZone: tz).rawValue }
        XCTAssertTrue(zip(hardDays, hardDays.dropFirst()).allSatisfy { $1 - $0 > 1 })
    }

    func layoutContext(days: Set<PlanWeekday>, hardOutside: Set<Int>) -> FreezeLayout.Context {
        let input = PlanInput(raceDistanceMeters: 21_097.5, raceDate: FreezeFixture.at(week: 14, day: .sunday),
                              startDate: today, trainingDays: days, longRunDay: .sunday, recentWeeklySeconds: 6000,
                              heartRateZones: nil)
        return FreezeLayout.Context(input: input, limits: .default, timeZone: tz, moveLongRun: false, race: nil, ceiling: nil,
                                    hardOutside: hardOutside)
    }

    func testALaidOutQualitySessionKeepsOffTheSundayBeforeAndTheMondayAfterTheWeek() {
        let week = FreezeFixture.monday(week: 1)
        func held(_ id: String, _ day: PlanWeekday, _ kind: PlannedWorkout.Kind) -> PlannedWorkout {
            FreezeFixture.session(id, week: 1, day, kind, minutes: 30)
        }
        // Tuesday is not a training day; Monday is the only free day.
        let before = [held("e1", .wednesday, .easy), held("e2", .saturday, .easy), held("l", .sunday, .long), held("q", .tuesday, .quality(.threshold))]
        let monday: Set<PlanWeekday> = [.monday, .wednesday, .saturday, .sunday]
        let free = FreezeLayout.lay(held: before, weekStart: week, layoutContext(days: monday, hardOutside: []))
        XCTAssertEqual(free.workouts.first { $0.id == "q" }?.kind, .quality(.threshold))
        XCTAssertEqual(free.workouts.first { $0.id == "q" }?.date, FreezeFixture.at(week: 1, day: .monday))
        let hard = FreezeLayout.lay(held: before, weekStart: week, layoutContext(days: monday, hardOutside: [-1]))
        XCTAssertEqual(hard.workouts.first { $0.id == "q" }?.kind, .easy, "the Sunday before is a hard day")
        XCTAssertEqual(hard.workouts.first { $0.id == "q" }?.durationSeconds, 30 * 60)
        // Sunday is the only free day, and the Monday after is hard.
        let after = [held("e1", .monday, .easy), held("e2", .wednesday, .easy), held("e3", .thursday, .easy), held("q", .tuesday, .quality(.threshold))]
        let sunday: Set<PlanWeekday> = [.monday, .wednesday, .thursday, .sunday]
        let open = FreezeLayout.lay(held: after, weekStart: week, layoutContext(days: sunday, hardOutside: []))
        XCTAssertEqual(open.workouts.first { $0.id == "q" }?.date, FreezeFixture.at(week: 1, day: .sunday))
        XCTAssertTrue(open.workouts.first { $0.id == "q" }?.kind.isQuality == true)
        let closed = FreezeLayout.lay(held: after, weekStart: week, layoutContext(days: sunday, hardOutside: [7]))
        XCTAssertEqual(closed.workouts.first { $0.id == "q" }?.kind, .easy, "the Monday after is a hard day")
    }

    /// Blocker 2: the baseline is not compared with the weeks the freeze made smaller.
    func testAThreeDayWeekEditedOverATwoWeekFreezeBuilds() throws {
        let old = GoalFixture.settings(weeksAhead: 14, days: [.monday, .wednesday, .saturday], longRunDay: .saturday,
                                       pain: .recurring(areas: ["shin"]))
        func week(_ n: Int) -> [PlannedWorkout] {
            [FreezeFixture.session("old-w\(n)-mon", week: n, .monday, .easy, minutes: 30),
             FreezeFixture.session("old-w\(n)-wed", week: n, .wednesday, .easy, minutes: 30),
             FreezeFixture.session("old-w\(n)-sat", week: n, .saturday, .long, minutes: 40)]
        }
        let hold = FreezeHold(freezes: [DateInterval(start: freeze.start, end: FreezeFixture.at(week: 2, day: .tuesday))],
                              sessions: FreezeFixture.currentWeekRest + week(1) + week(2))
        for days: Set<PlanWeekday> in [[.tuesday, .thursday, .sunday], [.monday, .wednesday, .sunday]] {
            let s = GoalFixture.settings(weeksAhead: 14, days: days, longRunDay: .sunday, pain: .recurring(areas: ["shin"]))
            let r = GoalPlanner.replan(from: old, previousPlan: nil, to: s, baseline: report, today: today, freeze: hold)
            let p = try built(r)
            XCTAssertEqual(p.freezeEdit?.frozenWeekStarts.count, 2)
            XCTAssertTrue(p.plan.weeks.prefix(2).allSatisfy { $0.trainingSeconds <= 100 * 60 + 0.5 })
            XCTAssertGreaterThan(p.plan.weeks.count, 3)
        }
    }

    /// Blocker 3: the long run's share cut never leaves an easy run longer than the long run.
    func testEasyRunsStayWithinTheLongRunWhenItsShareIsCut() throws {
        let days: Set<PlanWeekday> = [.tuesday, .thursday, .sunday]
        let s = GoalFixture.settings(weeksAhead: 14, days: days, pain: .recurring(areas: ["shin"]))
        let p = try built(edit(s, hold: FreezeFixture.hold()))
        assertPasses(p)
        let week = p.plan.weeks[0]
        let long = try XCTUnwrap(week.workouts.first { $0.kind == .long })
        XCTAssertLessThan(long.durationSeconds, 40 * 60, "the long run's share of the week was cut")
        let easy = week.workouts.filter { $0.kind == .easy || $0.kind == .recovery }
        XCTAssertFalse(easy.isEmpty)
        XCTAssertTrue(easy.allSatisfy { $0.durationSeconds <= long.durationSeconds + 0.01 }, "\(week.workouts.map(\.durationSeconds))")
        // The Thursday run was 30 minutes: cut to the long run's length, the cut time dropped, not shared out.
        XCTAssertEqual(week.workouts.first { $0.id == "old-w1-thu" }?.durationSeconds, long.durationSeconds)
        XCTAssertLessThanOrEqual(week.trainingSeconds, 120 * 60)
        let limits = { () -> GuardrailLimits in var l = GuardrailLimits.default; l.easyRunsWithinLongRun = true; return l }()
        let again = GuardrailChecker.check(history: p.history + FreezeFixture.currentWeekRest, planned: p.plan.workouts,
                                           timeZone: tz, limits: limits, freezes: [freeze])
        XCTAssertFalse(again.violations.contains { $0.rule == .easyRunLength }, "\(again.violations)")
    }

    /// The freeze ends before the plan's first week and covers only the rest of this week.
    func testAFreezeThatEndsBeforeTheFirstWeekIsStillInTheExplanation() throws {
        let short = DateInterval(start: freeze.start, end: FreezeFixture.at(week: 0, day: .saturday))
        let hold = FreezeHold(freezes: [short], sessions: FreezeFixture.currentWeekRest)
        let r = edit(newGoal, hold: hold)
        let p = try built(r)
        XCTAssertEqual(p.freezeEdit?.frozenWeekStarts, [])
        XCTAssertEqual(p.freezeEdit?.freezes, [short])
        XCTAssertEqual(p.freezeEdit?.firstGrowthWeekStart, FreezeFixture.monday(week: 1))
        let line = try XCTUnwrap(r.explanation.first { $0.hasPrefix("Your pain freeze") }, "\(r.explanation)")
        XCTAssertTrue(line.contains("still holds until"), line)
        XCTAssertTrue(line.contains(PlanFormatting.day(short.end, timeZone: tz)), line)
        XCTAssertTrue(line.contains("rest of this week"), line)
        // The plan is the one the edit builds with no freeze, and the rest of the week is kept as before.
        let plain = edit(newGoal, hold: nil)
        XCTAssertEqual(try built(r).plan, try built(plain).plan)
        XCTAssertEqual(r.keptThisWeek, plain.keptThisWeek)
        // A freeze that is already over says nothing.
        let over = DateInterval(start: freeze.start, end: FreezeFixture.at(week: 0, day: .tuesday))
        let none = edit(newGoal, hold: FreezeHold(freezes: [over], sessions: FreezeFixture.currentWeekRest))
        XCTAssertNil(try built(none).freezeEdit)
    }

    // MARK: Growth after the freeze

    func testGrowthResumesAfterTheFreezeMeasuredFromTheFrozenWeek() throws {
        let p = try built(edit(newGoal, hold: FreezeFixture.hold()))
        let frozen = minutes(p.plan.weeks[0])
        let next = minutes(p.plan.weeks[1])
        XCTAssertEqual(frozen, 120)
        XCTAssertGreaterThan(next, frozen, "growth resumes the week after the freeze")
        // The weekly rise over the frozen week, though that week reads as a recovery week
        // (rule 2 alone would measure from the 155 before it): at most 10%, i.e. 132 minutes.
        XCTAssertLessThanOrEqual(next, 132)
        XCTAssertEqual(p.freezeEdit?.firstGrowthWeekStart, FreezeFixture.monday(week: 2))
        XCTAssertEqual(p.plan.weeks[1].weekStart, FreezeFixture.monday(week: 2))
        // The week after the frozen one is a build week with its quality session again.
        XCTAssertEqual(p.plan.weeks[1].workouts.filter { $0.kind.isQuality }.count, 1)
    }

    func testAFreezeOverTwoWeeksHoldsBothAndGrowthStartsAfterThem() throws {
        let long = DateInterval(start: freeze.start, end: FreezeFixture.at(week: 2, day: .tuesday))
        // The second frozen week, no larger than the first: 120 minutes in four sessions.
        let second = [FreezeFixture.session("old-w2-tue", week: 2, .tuesday, .easy, minutes: 25),
                      FreezeFixture.session("old-w2-thu", week: 2, .thursday, .quality(.fartlek), minutes: 30),
                      FreezeFixture.session("old-w2-sat", week: 2, .saturday, .easy, minutes: 25),
                      FreezeFixture.session("old-w2-sun", week: 2, .sunday, .long, minutes: 40)]
        let hold = FreezeHold(freezes: [long], sessions: FreezeFixture.currentWeekRest + FreezeFixture.frozenWeek + second)
        let p = try built(edit(newGoal, hold: hold))
        assertPasses(p, freezes: [long])
        XCTAssertEqual(p.plan.weeks[0].workouts, FreezeFixture.frozenWeek)
        XCTAssertEqual(p.plan.weeks[1].workouts, second, "a quality session the freeze did not swap stays as it was")
        XCTAssertEqual(p.freezeEdit?.frozenWeekStarts, [FreezeFixture.monday(week: 1), FreezeFixture.monday(week: 2)])
        XCTAssertEqual(p.freezeEdit?.firstGrowthWeekStart, FreezeFixture.monday(week: 3))
        XCTAssertLessThanOrEqual(minutes(p.plan.weeks[2]), 132)
        XCTAssertGreaterThan(minutes(p.plan.weeks[2]), 120)
    }

    // MARK: The freeze itself

    func testTheFreezeEndsOnItsOriginalDay() throws {
        let p = try built(edit(newGoal, hold: FreezeFixture.hold()))
        XCTAssertEqual(p.freezeEdit?.freezes, [freeze])
        XCTAssertEqual(p.freezeEdit?.freezeStart, freeze.start)
        XCTAssertEqual(p.freezeEdit?.freezeEnd, freeze.end)
        // Through the engine's own state: the hold carries exactly the intervals still in force, none lifted or restarted.
        let state = AdaptationState(freezes: [VolumeFreeze(interval: freeze, checkIn: freeze.start)])
        let hold = try XCTUnwrap(state.freezeHold(plan: FreezeFixture.currentWeekRest + FreezeFixture.frozenWeek, at: today))
        XCTAssertEqual(hold.freezes, state.freezeIntervals(at: today))
        XCTAssertEqual(try built(edit(newGoal, hold: hold)).freezeEdit?.freezeEnd, freeze.end)
        XCTAssertEqual(state.freezes, [VolumeFreeze(interval: freeze, checkIn: freeze.start)])
    }

    func testTheExplanationSaysTheFreezeStillHoldsAndWhenItEnds() throws {
        let r = edit(newGoal, hold: FreezeFixture.hold())
        let start = PlanFormatting.day(freeze.start, timeZone: tz)
        let end = PlanFormatting.day(freeze.end, timeZone: tz)
        XCTAssertEqual(start, "2026-09-22")
        XCTAssertEqual(end, "2026-09-29")
        let line = try XCTUnwrap(r.explanation.first { $0.contains("pain freeze") })
        XCTAssertEqual(line, "Your pain freeze from 2026-09-22 still holds until 2026-09-29; this edit doesn't shorten or lift it. The week it covers keeps its volume and its easy sessions, and the new plan grows toward your new goal from the week of 2026-10-05 (SPEC 3.5 rule 7).")
        XCTAssertTrue(r.explanation.contains("Every week passes the load guardrails (SPEC 3.5)."))
        XCTAssertTrue(r.explanation.contains("The 3 sessions left this week from the previous plan stay as planned."))
        XCTAssertTrue(try built(r).plan.notes.contains { $0.contains("held by your pain freeze") })
    }

    func testTheExplanationNamesAPendingSwapAndAMovedWeek() throws {
        let days: Set<PlanWeekday> = [.monday, .thursday, .saturday, .sunday]
        let s = GoalFixture.settings(weeksAhead: 14, days: days, pain: .recurring(areas: ["shin"]))
        let r = edit(s, hold: FreezeFixture.hold(pendingSwap: pendingSwap(week: 2)))
        let p = try built(r)
        let landed = PlanFormatting.day(try XCTUnwrap(p.freezeEdit?.swapLandsOn), timeZone: tz)
        XCTAssertTrue(r.explanation.contains("The frozen week of 2026-09-28 keeps the same sessions, moved onto your new days or shortened where your new days, your longest session or the week before it leave less room, at no more than the volume the freeze holds. No new or harder session types are added."), "\(r.explanation)")
        XCTAssertTrue(r.explanation.contains("The quality session your pain check-in swapped for easy running hadn't come up yet, so the new plan's next quality session, on \(landed), is an easy run instead."), "\(r.explanation)")
    }

    // MARK: A rebuild holds the freeze too

    func testTheProvisionalRebuildHoldsTheFreezeToo() async throws {
        let w = BaselineFixture.weeks
        let rest = [GoalFixture.run("rest-thu", week: w, day: .thursday, minutes: 35),
                    GoalFixture.run("rest-sat", week: w, day: .saturday, minutes: 35),
                    GoalFixture.run("rest-sun", week: w, day: .sunday, minutes: 55, hour: 8)]
        let first = try XCTUnwrap(GoalPlanner.plan(settings: FreezeFixture.painful, baseline: report, today: today).plan)
        let monday = try XCTUnwrap(first.rebuildDate)
        let hold = FreezeFixture.hold()
        let attempt = await ProvisionalRebuild.run(ProvisionalRebuild.CurrentPlan(first), freezes: [freeze], freeze: hold,
                                                   now: monday.addingTimeInterval(3600), timeZone: tz,
                                                   baseline: { options in
                                                       GoalFixture.fixtureReport(asOf: options.asOf) {
                                                           $0 += rest + [GoalFixture.run("mon-run", week: w, day: .monday, minutes: 30)]
                                                       }
                                                   },
                                                   log: { _ in }, fail: { _ in })
        let a = try XCTUnwrap(attempt)
        XCTAssertTrue(a.outcome.isRebuilt, "\(String(describing: a.outcome.note))")
        XCTAssertEqual(a.outcome.plan.plan.weeks[0].workouts, FreezeFixture.frozenWeek)
        XCTAssertEqual(a.outcome.plan.freezeEdit?.freezeEnd, freeze.end)
    }

    // MARK: A race inside a frozen week, and a plan the freeze covers to the race

    /// A 5K four weeks out, the freeze (a long one, as the limits allow) over all four weeks: 120 minutes held each
    /// week but the race week, which holds 110 (a recovery week after three build weeks, race included).
    func fiveK(freezeEnd: Date, held: [PlannedWorkout]) -> (GoalSettings, FreezeHold) {
        let s = GoalFixture.settings(distance: Distance.fiveK, weeksAhead: 4, pain: .recurring(areas: ["shin"]))
        let f = DateInterval(start: freeze.start, end: freezeEnd)
        return (s, FreezeHold(freezes: [f], sessions: FreezeFixture.currentWeekRest + held))
    }

    func heldWeek(_ week: Int, sessions: [(PlanWeekday, PlannedWorkout.Kind, Double)]) -> [PlannedWorkout] {
        sessions.enumerated().map { FreezeFixture.session("old-w\(week)-\($0.offset)", week: week, $0.element.0, $0.element.1, minutes: $0.element.2) }
    }

    func testARaceInsideAFrozenWeekStaysPutAndCountsTowardTheFrozenVolume() throws {
        let weeks = heldWeek(1, sessions: [(.tuesday, .easy, 25), (.thursday, .easy, 30), (.saturday, .easy, 25), (.sunday, .long, 40)])
            + heldWeek(2, sessions: [(.tuesday, .easy, 25), (.thursday, .easy, 30), (.saturday, .easy, 25), (.sunday, .long, 40)])
            + heldWeek(3, sessions: [(.tuesday, .easy, 25), (.thursday, .easy, 30), (.saturday, .easy, 25), (.sunday, .long, 40)])
            // Race week: 110 minutes held, race day Sunday.
            + heldWeek(4, sessions: [(.tuesday, .easy, 30), (.thursday, .easy, 35), (.saturday, .easy, 30), (.sunday, .easy, 15)])
        let (s, hold) = fiveK(freezeEnd: FreezeFixture.at(week: 5, day: .monday), held: weeks)
        let old = GoalFixture.settings(distance: Distance.fiveK, weeksAhead: 4, pain: .recurring(areas: ["shin"]))
        let r = GoalPlanner.replan(from: old, previousPlan: nil, to: s, baseline: report, today: today, freeze: hold)
        let p = try built(r)
        assertPasses(p, freezes: hold.freezes)
        XCTAssertEqual(p.plan.weeks.count, 4)
        XCTAssertEqual(p.freezeEdit?.frozenWeekStarts.count, 4)
        XCTAssertNil(p.freezeEdit?.firstGrowthWeekStart)
        let raceWeek = try XCTUnwrap(p.plan.weeks.last)
        let race = try XCTUnwrap(raceWeek.workouts.first { $0.kind == .race })
        XCTAssertEqual(race.date, s.race.date, "the race stays on the day the runner set")
        XCTAssertEqual(race.id, "plan-race")
        XCTAssertEqual(raceWeek.isRaceWeek, true)
        XCTAssertEqual(p.freezeEdit?.raceWeekStart, raceWeek.weekStart)
        // The race counts toward the frozen 110 minutes: the other runs, Tuesday to Saturday only (the Sunday run
        // falls on race day), shrink by it, so the week adds up to the frozen volume.
        let others = raceWeek.workouts.filter { $0.kind != .race }
        XCTAssertTrue(others.allSatisfy { $0.date < race.date.addingTimeInterval(-3 * 3600) })
        let total = raceWeek.workouts.reduce(0.0) { $0 + $1.durationSeconds }
        XCTAssertEqual(total, 110 * 60, accuracy: 0.01)
        let budget = 110 * 60 - p.plan.raceSeconds
        XCTAssertEqual(others.reduce(0.0) { $0 + $1.durationSeconds }, budget, accuracy: 0.01)
        // 95 held minutes (30, 35, 30) scale by budget / 5700 s; same order, same days, none dropped.
        XCTAssertEqual(others.map(\.id), ["old-w4-0", "old-w4-1", "old-w4-2"])
        let scale: Double = budget / 5700
        for (w, held) in zip(others, [30.0, 35.0, 30.0]) {
            XCTAssertEqual(w.durationSeconds, held * 60 * scale, accuracy: 0.01)
        }
        // The weeks before it are held as they were.
        XCTAssertEqual(p.plan.weeks[0].workouts, weeks.filter { $0.id.hasPrefix("old-w1") })
        XCTAssertTrue(r.explanation.contains { $0.hasPrefix("Your race falls inside the freeze, in the week of") }, "\(r.explanation)")
        XCTAssertTrue(r.explanation.contains { $0.contains("there is no week after them before the race") })
    }

    func testARaceLongerThanTheWeekBeforeIsRefusedNotPlannedAboveTheFreeze() throws {
        // The week before the race week holds 15 minutes; the 5K takes longer, and the freeze holds the race week to
        // the week before it, the race included, so no plan keeps the freeze and the edit is refused, not bent.
        let weeks = heldWeek(1, sessions: [(.tuesday, .easy, 25), (.thursday, .easy, 30), (.saturday, .easy, 25), (.sunday, .long, 40)])
            + heldWeek(2, sessions: [(.tuesday, .easy, 25), (.thursday, .easy, 30), (.saturday, .easy, 25), (.sunday, .long, 40)])
            + heldWeek(3, sessions: [(.tuesday, .easy, 15)])
            + heldWeek(4, sessions: [(.tuesday, .easy, 5)])
        let (s, hold) = fiveK(freezeEnd: FreezeFixture.at(week: 5, day: .monday), held: weeks)
        let r = GoalPlanner.plan(settings: s, baseline: report, today: today, freeze: hold)
        guard case .cannotBuild(let found)? = r.issues.first, case .failsGuardrails(let rep)? = found.first else { return XCTFail("\(r)") }
        XCTAssertTrue(rep.violations.contains { $0.rule == .volumeFreeze && $0.weekStart == FreezeFixture.monday(week: 4) })
    }

    func testTheWeeksAfterAShortFreezeAreBuiltToTheRace() throws {
        let weeks = heldWeek(1, sessions: [(.tuesday, .easy, 25), (.thursday, .easy, 30), (.saturday, .easy, 25), (.sunday, .long, 40)])
            + heldWeek(2, sessions: [(.tuesday, .easy, 25), (.thursday, .easy, 30), (.saturday, .easy, 25), (.sunday, .long, 40)])
        // The freeze ends in the second week, so two weeks (a build week and the race week) come after the frozen ones.
        let (s, hold) = fiveK(freezeEnd: FreezeFixture.at(week: 2, day: .wednesday), held: weeks)
        let p = try built(GoalPlanner.replan(from: s, previousPlan: nil, to: s, baseline: report, today: today, freeze: hold))
        assertPasses(p, freezes: hold.freezes)
        XCTAssertEqual(p.plan.weeks.count, 4)
        XCTAssertEqual(p.freezeEdit?.frozenWeekStarts, [FreezeFixture.monday(week: 1), FreezeFixture.monday(week: 2)])
        XCTAssertEqual(p.freezeEdit?.firstGrowthWeekStart, p.plan.weeks[2].weekStart)
        XCTAssertEqual(p.plan.weeks.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(p.plan.weeks[3].isRaceWeek, true)
        XCTAssertEqual(p.plan.workouts.last?.kind, .race)
        XCTAssertLessThanOrEqual(minutes(p.plan.weeks[2]), 132)
    }

    func testAFreezeThatLeavesOnlyTheRaceWeekIsRefusedPlainly() throws {
        let weeks = heldWeek(1, sessions: [(.tuesday, .easy, 25), (.thursday, .easy, 30), (.saturday, .easy, 25), (.sunday, .long, 40)])
            + heldWeek(2, sessions: [(.tuesday, .easy, 25), (.thursday, .easy, 30), (.saturday, .easy, 25), (.sunday, .long, 40)])
            + heldWeek(3, sessions: [(.tuesday, .easy, 25), (.thursday, .easy, 30), (.saturday, .easy, 25), (.sunday, .long, 40)])
        let (s, hold) = fiveK(freezeEnd: FreezeFixture.at(week: 3, day: .wednesday), held: weeks)
        let r = GoalPlanner.plan(settings: s, baseline: report, today: today, freeze: hold)
        XCTAssertEqual(r.issues, [.cannotBuild([.leadTimeTooShort(weeksAvailable: 1, minimumWeeks: 2)])])
    }

    // MARK: An edit with no freeze is as on main

    /// Pinned on main (e978ad6): the same edit with no freeze.
    func testNoFreezePinOne_theEditIsAsOnMain() throws {
        let r = edit(newGoal, hold: nil)
        let p = try built(r)
        XCTAssertEqual(p.plan.weeks.count, 16)
        XCTAssertEqual(p.plan.weeks.prefix(6).map { Int(minutes($0)) }, [116, 126, 136, 105, 146, 146])
        XCTAssertEqual(p.plan.workouts.count, 62)
        XCTAssertEqual(p.plan.weeks[0].workouts.map(\.id), ["plan-w0-d1-easy", "plan-w0-d3-easy", "plan-w0-d5-easy", "plan-w0-d6-long"])
        XCTAssertEqual(p.rebuildDate, FreezeFixture.monday(week: 1))
        XCTAssertEqual(p.plan.notes.count, 2)
        XCTAssertNil(p.freezeEdit)
        XCTAssertEqual(r.explanation, [
            "Race date moved from 2027-01-03 to 2027-01-17.",
            "Goal changed from best possible to 1:55:00.",
            "The plan runs 16 weeks to race day, peaking at 3 h 38 min a week.",
            "Every week passes the load guardrails (SPEC 3.5).",
        ])
        // A hold whose freeze ended before the plan starts changes nothing either.
        let ended = DateInterval(start: freeze.start.addingTimeInterval(-86_400 * 8), end: freeze.start.addingTimeInterval(-86_400))
        let past = edit(newGoal, hold: FreezeHold(freezes: [ended], sessions: FreezeFixture.currentWeekRest + FreezeFixture.frozenWeek))
        XCTAssertEqual(past.result, r.result)
        XCTAssertNil(past.result.plan?.freezeEdit)
        // An empty hold, and no hold at the builder, are `build`.
        XCTAssertEqual(edit(newGoal, hold: FreezeHold(freezes: [], sessions: [])).result, r.result)
    }

    /// Pinned on main: a freeze passed only as an interval still refuses the edit that grows the frozen week.
    func testNoFreezePinTwo_aFreezeIntervalAloneStillRefusesAsOnMain() throws {
        let r = edit(newGoal, hold: nil, freezes: [freeze])
        XCTAssertEqual(r.result.issues.count, 1)
        guard case .failsGuardrails(let rep)? = r.result.issues.first else { return XCTFail("\(r.result)") }
        XCTAssertEqual(rep.violations.map(\.rule), [.volumeFreeze])
        XCTAssertEqual(r.explanation, [
            "Race date moved from 2027-01-03 to 2027-01-17.",
            "Goal changed from best possible to 1:55:00.",
            "No new plan could be built from these settings, so the previous plan stays in place.",
        ])
        XCTAssertEqual(r.keptThisWeek, [])
        // And a hold with no session in the first frozen week falls back to that, the plan built as `build` builds it.
        let bare = FreezeHold(freezes: [freeze], sessions: FreezeFixture.currentWeekRest)
        XCTAssertEqual(edit(newGoal, hold: bare).result, r.result)
    }

    func testTheBuilderWithNoFreezeIsBuild() throws {
        let input = BaselinePlanMapping.planInput(settings: newGoal, baseline: report, startDate: today)
        let history = BaselinePlanMapping.planHistory(from: report).filter { $0.date < today }
        let plain = PlanBuilder.build(input, history: history, timeZone: tz)
        XCTAssertEqual(PlanBuilder.build(input, history: history, timeZone: tz, freeze: nil), plain)
        let after = DateInterval(start: FreezeFixture.at(week: 9, day: .monday), end: FreezeFixture.at(week: 9, day: .friday))
        XCTAssertEqual(PlanBuilder.build(input, history: history, timeZone: tz, freeze: FreezeHold(freezes: [after], sessions: [])), plain,
                       "a freeze that doesn't reach the plan's first week leaves the plan alone")
        let held = PlanBuilder.build(input, history: history, timeZone: tz, freeze: FreezeFixture.hold())
        XCTAssertEqual(held.plan?.weeks[0].workouts, FreezeFixture.frozenWeek)
    }

    // MARK: The adaptation state's hold

    func testStateHoldIsNilWithoutAFreezeAndCarriesOnlyAPendingSwap() throws {
        let plan = FreezeFixture.currentWeekRest + FreezeFixture.frozenWeek
        XCTAssertNil(AdaptationState().freezeHold(plan: plan, at: today))
        let ended = AdaptationState(freezes: [VolumeFreeze(interval: freeze, checkIn: freeze.start)])
        XCTAssertNil(ended.freezeHold(plan: plan, at: freeze.end), "a freeze that has ended is not in force")

        let swap = pendingSwap(week: 0)
        let response = PainResponse(checkIn: PainCheckIn(date: freeze.start, score: 5), triggers: [.scoreAtOrAbove(threshold: 4)],
                                    freezeStart: freeze.start, freezeEnd: freeze.end, swap: swap, suggestClinician: false,
                                    explanation: "")
        var state = AdaptationState(appliedPainResponse: response, freezes: [VolumeFreeze(interval: freeze, checkIn: freeze.start)])
        XCTAssertEqual(try XCTUnwrap(state.freezeHold(plan: plan, at: today)).pendingSwap, swap)
        XCTAssertEqual(try XCTUnwrap(state.freezeHold(plan: plan, at: today)).sessions, plan)
        // Once the swapped session's day has passed, there is nothing left to swap.
        XCTAssertNil(try XCTUnwrap(state.freezeHold(plan: plan, at: swap.original.date.addingTimeInterval(1))).pendingSwap)
        state.appliedPainResponse = nil
        XCTAssertNil(try XCTUnwrap(state.freezeHold(plan: plan, at: today)).pendingSwap)
    }
}
