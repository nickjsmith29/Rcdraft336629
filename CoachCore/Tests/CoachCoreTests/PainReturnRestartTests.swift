import XCTest
@testable import CoachCore

// SPEC.md 0.8, 3.5 rule 7 "From week 2 on" and "Recurrence" (owner-approved
// Nov 24, #93): after a pain stop of more than 14 days, a return week run
// under 1 / 1.2 (about 83%) of what it was planned to hold sets the next week
// back to step 1, its ceiling never below the week actually run; a recurrence
// week that is also short takes the lower of the step back and the restart; a
// second failure at the same step still reopens the stop; the rolling 4-week
// check counts every week from the stop's start through the end of the return
// at the pre-stop level. Every expected number is worked out by hand below.
// Synthetic plans, runs and reports only.
//
// The fixture (`AdaptFixture.weeks`) is a week of 214 minutes (Tue threshold
// 54, Thu easy 55, Sat long 60, Sun easy 45), so the pre-stop level is
// L = 214 min = 12,840 s and the return's ceilings are:
//   step 1: 0.65  x 214 = 139.1 min  (8,346 s)
//   step 2: 0.825 x 214 = 176.55 min (10,593 s)
//   step 3: the plan's own volume, 214 min.
// A week planned at P minutes is run short when it is under P / 1.2.
final class PainReturnRestartTests: XCTestCase {
    typealias F = AdaptFixture
    private let level = 214.0 * 60
    private let c1 = 0.65 * 214.0       // 139.1 min
    private let c2 = 0.825 * 214.0      // 176.55 min

    private var context: AdaptationContext {
        AdaptationContext(zones: F.zones, timeZone: F.tz, tracksPain: true, usualPainSeed: 2)
    }

    private func monday(_ week: Int) -> Date {
        PlanCalendar.weekStart(containing: F.date(week: week, day: 0), timeZone: F.tz)
    }

    private func minutes(_ week: Int, _ sessions: [PlannedWorkout]) -> Double { F.weekVolume(week, sessions) / 60 }

    /// A return after a pain stop of 20 days off, as stored mid-return: the return began on Wednesday of week 3, so
    /// week 4 is its first full week (step 1 there, step 2 in week 5, step 3 in week 6), unless `step` and `stepWeek`
    /// say otherwise. History: weeks 0 to 2 as planned (the level), and `ran` minutes in the given later weeks, split
    /// over a Tuesday, a Thursday and a Saturday run. `planned` is what the engine returned for those weeks at their
    /// first event (`PlanSnapshot.planned`). The app hands in 214 minutes a week from `planFrom` on.
    private func midReturn(step: Int = 1, stepWeek: Int = 4, ran: [Int: Double], planned: [Int: Double],
                           failed: [Int] = [], judgedThrough: Int? = nil, planFrom: Int) -> F.Driver {
        var history = F.weeks(0..<3)
        for (w, total) in ran.sorted(by: { $0.key < $1.key }) {
            for day in [1, 3, 5] { history.append(F.easy("h\(w)-\(day)", week: w, day: day, minutes: total / 3)) }
        }
        let r = PainReturn(start: F.date(week: 3, day: 2, hour: 6), level: level, preStopLongRun: 3600, daysOff: 20,
                           fromMovement: false, step: step, stepWeek: monday(stepWeek), failedSteps: failed,
                           judgedThrough: judgedThrough.map(monday))
        let snapshot = PlanSnapshot(planned: planned.sorted { $0.key < $1.key }
            .map { PlanWeekVolume(week: monday($0.key), volume: $0.value * 60) })
        var d = F.Driver(plan: F.weeks(planFrom..<14), history: history, context: context)
        d.state = AdaptationState(painRecovery: PainRecovery(frozenUsual: 2, preStopLongRun: 3600, painReturn: r),
                                  planSnapshot: snapshot)
        return d
    }

    private func ret(_ d: F.Driver) -> PainReturn? { d.state.painRecovery.painReturn }

    /// The weekly ceiling the engine holds for `week` of the return (`returnHolds`), in seconds, read from `d`'s state.
    private func hold(_ d: F.Driver, week: Int) -> Double? {
        let w = AdaptationEngine.Work(state: d.state, plan: d.plan, history: d.history, context: d.context, asOf: monday(week))
        return w.returnHolds().first { $0.interval.start == monday(week) }?.level
    }

    // MARK: The restart

    /// Week 4 (step 1) was planned at 139 min and run at 100: 100 < 139 / 1.2 = 115.8, so it was run short and week 5
    /// is step 1 again (at most 0.65 x 214 = 139.1 min), not step 2 (176.55).
    func testAReturnWeekRunShortSetsTheNextWeekBackToStep1() throws {
        var d = midReturn(ran: [4: 100], planned: [4: 139], planFrom: 5)
        d.day(F.date(week: 5, day: 0, hour: 5))
        let r = try XCTUnwrap(ret(d))
        XCTAssertEqual(r.restartWeek, monday(5))
        XCTAssertEqual(r.restartFloor ?? 0, 100 * 60, accuracy: 1e-6)
        XCTAssertEqual(r.step, 1)
        XCTAssertEqual(r.stepWeek, monday(5))
        XCTAssertEqual(r.judgedThrough, monday(4))
        XCTAssertEqual(d.course.returnStep, 1, "step 1, not step 2")
        XCTAssertEqual(r.step(atWeek: monday(6), timeZone: F.tz), 2, "then the steps go on")
        let restart = try XCTUnwrap(d.changes.first { $0.kind == .painReturnStep })
        XCTAssertTrue(restart.explanation.contains("restarts"), restart.explanation)
        XCTAssertEqual(try XCTUnwrap(hold(d, week: 5)), 0.65 * level, accuracy: 1e-6, "8,346 s = 139.1 min, not 10,593")
        XCTAssertEqual(try XCTUnwrap(hold(d, week: 6)), 0.825 * level, accuracy: 1e-6, "then step 2")
        XCTAssertLessThanOrEqual(minutes(5, d.plan), c1 + 1e-6, "139.1 min, not 176.55")
        assertAdaptationSound(d.outcomes)
    }

    /// The same week run at 120 min: 120 >= 115.8, so the count goes on to step 2 (176.55 min).
    func testAReturnWeekRunAtOrAboveTheLineGoesOnToTheNextStep() throws {
        var d = midReturn(ran: [4: 120], planned: [4: 139], planFrom: 5)
        d.day(F.date(week: 5, day: 0, hour: 5))
        let r = try XCTUnwrap(ret(d))
        XCTAssertNil(r.restartWeek)
        XCTAssertNil(r.restartFloor)
        XCTAssertEqual(r.judgedThrough, monday(4), "the week was read")
        XCTAssertEqual(d.course.returnStep, 2)
        XCTAssertLessThanOrEqual(minutes(5, d.plan), c2 + 1e-6)
        XCTAssertEqual(try XCTUnwrap(hold(d, week: 5)), 0.825 * level, accuracy: 1e-6, "step 2: 10,593 s = 176.55 min")
        XCTAssertGreaterThan(minutes(5, d.plan), c1 + 1, "above step 1's 139.1 min")
        XCTAssertFalse(d.changes.contains { $0.explanation.contains("restarts") })
        assertAdaptationSound(d.outcomes)
    }

    /// Each finished week is read once: the same event again changes nothing, and a week still running is not read.
    func testAWeekIsReadOnceAndNotBeforeItEnds() throws {
        var d = midReturn(ran: [4: 100], planned: [4: 139], planFrom: 5)
        d.day(F.date(week: 4, day: 5, hour: 20))
        XCTAssertNil(ret(d)?.judgedThrough, "week 4 is still running")
        XCTAssertNil(ret(d)?.restartWeek)
        d.day(F.date(week: 5, day: 0, hour: 5))
        let first = try XCTUnwrap(ret(d))
        d.day(F.date(week: 5, day: 2, hour: 5))
        XCTAssertEqual(ret(d), first)
        XCTAssertEqual(d.changes.filter { $0.explanation.contains("restarts") }.count, 1)
    }

    // MARK: The floor

    /// Week 6 is step 3 (the plan's 214 min) and was run at 150: 150 < 214 / 1.2 = 178.3, so it was run short. The
    /// restart's ceiling is the higher of 0.65 x 214 = 139.1 and the 150 run, so week 7 may hold 150 min: never
    /// below the week run.
    func testTheRestartedCeilingIsNeverBelowTheWeekRun() throws {
        var d = midReturn(step: 1, stepWeek: 4, ran: [4: 139, 5: 176, 6: 150], planned: [6: 214], judgedThrough: 5, planFrom: 7)
        XCTAssertEqual(ret(d)?.step(atWeek: monday(6), timeZone: F.tz), 3)
        d.day(F.date(week: 7, day: 0, hour: 5))
        let r = try XCTUnwrap(ret(d))
        XCTAssertEqual(r.restartWeek, monday(7))
        XCTAssertEqual(r.restartFloor ?? 0, 150 * 60, accuracy: 1e-6)
        XCTAssertEqual(r.restartFloor(forWeek: monday(7)) ?? 0, 9000, accuracy: 1e-6)
        XCTAssertNil(r.restartFloor(forWeek: monday(8)), "the floor is for the restarted week alone")
        XCTAssertEqual(try XCTUnwrap(hold(d, week: 7)), 9000, accuracy: 1e-6, "max(8,346, 9,000): the week run is the floor")
        XCTAssertEqual(try XCTUnwrap(hold(d, week: 8)), 0.825 * level, accuracy: 1e-6, "the floor is for one week")
        XCTAssertLessThanOrEqual(minutes(7, d.plan), 150 + 1e-6)
        assertAdaptationSound(d.outcomes)
    }

    /// A restart ceiling below the step's share is the share: week run at 100 of 214 planned: 139.1, not 100.
    func testTheRestartedCeilingIsTheStepsShareWhenTheWeekRunWasLower() throws {
        var d = midReturn(step: 1, stepWeek: 4, ran: [4: 139, 5: 176, 6: 100], planned: [6: 214], judgedThrough: 5, planFrom: 7)
        d.day(F.date(week: 7, day: 0, hour: 5))
        XCTAssertEqual(ret(d)?.restartWeek, monday(7))
        XCTAssertEqual(try XCTUnwrap(hold(d, week: 7)), 0.65 * level, accuracy: 1e-6, "139.1 min, not the 100 run")
        XCTAssertLessThanOrEqual(minutes(7, d.plan), c1 + 1e-6)
    }

    // MARK: Recurrence plus short

    /// Week 6 (step 3, planned 214) has symptoms on a run (pain 3 against usual 2), which sets the step back to step
    /// 2 (176.55 min) for week 7, and is run at 100 min, short (100 < 178.3). The restart's ceiling is
    /// max(139.1, 100) = 139.1, lower than 176.55, so the restart applies: week 7 is step 1 with 139.1 min.
    func testARecurrenceWeekThatIsAlsoShortTakesTheRestartWhenItIsLower() throws {
        var d = midReturn(step: 1, stepWeek: 4, ran: [4: 139, 5: 176, 6: 100], planned: [6: 214], judgedThrough: 5, planFrom: 7)
        d.afterRun(week: 6, day: 3, 3, hour: 10)
        XCTAssertEqual(ret(d)?.failedSteps, [3])
        XCTAssertEqual(ret(d)?.step, 2, "the step back")
        XCTAssertEqual(ret(d)?.stepWeek, monday(7))
        d.day(F.date(week: 7, day: 0, hour: 5))
        let r = try XCTUnwrap(ret(d))
        XCTAssertEqual(r.restartWeek, monday(7))
        XCTAssertEqual(r.step, 1)
        XCTAssertEqual(r.failedSteps, [3], "the failure at step 3 stays on record")
        XCTAssertEqual(try XCTUnwrap(hold(d, week: 7)), 0.65 * level, accuracy: 1e-6, "the lower of 10,593 and 8,346")
        XCTAssertLessThanOrEqual(minutes(7, d.plan), c1 + 1e-6)
        XCTAssertNil(d.state.painStop)
    }

    /// The same, run at 177 min: short (177 < 178.3), but the restart's ceiling max(139.1, 177) = 177 is above the
    /// step back's 176.55, so the step back is the lower and holds: week 7 is step 2, no restart.
    func testARecurrenceWeekThatIsAlsoShortKeepsTheStepBackWhenItIsLower() throws {
        var d = midReturn(step: 1, stepWeek: 4, ran: [4: 139, 5: 176, 6: 177], planned: [6: 214], judgedThrough: 5, planFrom: 7)
        d.afterRun(week: 6, day: 3, 3, hour: 10)
        d.day(F.date(week: 7, day: 0, hour: 5))
        let r = try XCTUnwrap(ret(d))
        XCTAssertNil(r.restartWeek, "the step back is lower")
        XCTAssertEqual(r.step, 2)
        XCTAssertEqual(r.judgedThrough, monday(6))
        XCTAssertEqual(try XCTUnwrap(hold(d, week: 7)), 0.825 * level, accuracy: 1e-6, "the lower of 10,593 and 10,620")
        XCTAssertLessThanOrEqual(minutes(7, d.plan), c2 + 1e-6)
    }

    // MARK: A second failure

    /// A failure at step 2 before a restart, then the restart (step 1 in week 7, step 2 in week 8) and symptoms at step
    /// 2 again: the second failure at the same step reopens the stop and turns the clinician flag on.
    func testASecondFailureAtTheSameStepAfterARestartReopensTheStop() throws {
        var d = midReturn(step: 1, stepWeek: 7, ran: [4: 139, 5: 176, 6: 100], planned: [6: 214], failed: [2],
                          judgedThrough: 7, planFrom: 7)
        d.state.painRecovery.painReturn?.restartWeek = monday(7)
        d.state.painRecovery.painReturn?.restartFloor = 100 * 60
        XCTAssertEqual(ret(d)?.step(atWeek: monday(8), timeZone: F.tz), 2)
        d.afterRun(week: 8, day: 1, 3, hour: 10)   // 3 against usual 2: symptoms at step 2
        XCTAssertEqual(d.state.painStop?.triggers, [.recurredInReturn])
        XCTAssertNil(ret(d))
        XCTAssertTrue(d.course.clinicianFlag?.reasons.contains(.secondFailure) ?? false)
    }

    /// A first failure at a step after a restart still steps back, as before.
    func testAFirstFailureAfterARestartStepsBack() throws {
        var d = midReturn(step: 1, stepWeek: 7, ran: [4: 139, 5: 176, 6: 100], planned: [6: 214], judgedThrough: 7, planFrom: 7)
        d.state.painRecovery.painReturn?.restartWeek = monday(7)
        d.state.painRecovery.painReturn?.restartFloor = 100 * 60
        d.afterRun(week: 8, day: 1, 3, hour: 10)
        XCTAssertEqual(ret(d)?.failedSteps, [2])
        XCTAssertEqual(ret(d)?.step, 1)
        XCTAssertNil(d.state.painStop)
    }

    // MARK: A restart brings back the weekly ceilings only

    /// Week 1's allowance of usual + 1 doesn't come back with the restart: in the restarted week pain above usual is
    /// symptoms, as in the weeks before it. Pain 3 against usual 2 is allowed in week 1 of a return (step 1) and is
    /// not allowed in the restarted week.
    func testTheRestartedWeekJudgesPainAsLaterStepsDo() throws {
        var d = midReturn(ran: [4: 100], planned: [4: 139], planFrom: 5)
        d.day(F.date(week: 5, day: 0, hour: 5))
        XCTAssertEqual(ret(d)?.restartWeek, monday(5))
        XCTAssertEqual(ret(d)?.symptomStep(atWeek: monday(5), timeZone: F.tz), 2)
        XCTAssertEqual(ret(d)?.symptomStep(atWeek: monday(6), timeZone: F.tz), 2)
        XCTAssertFalse(PainReturnRule.symptoms(level: 3, changedMovement: false, step: 1, usual: 2), "week 1's allowance")
        d.afterRun(week: 5, day: 1, 3, hour: 10)
        XCTAssertEqual(ret(d)?.failedSteps, [1], "usual + 1 is symptoms in the restarted week")
    }

    /// Week 1's alternate days and long-run cap come back only through the recurrence rule: the restarted week keeps
    /// them off, and a week that is step 1 through a recurrence has them.
    func testTheRestartDoesNotBringBackWeekOnesAlternateDays() throws {
        func alternateDayChanges(_ d: F.Driver) -> Int {
            d.changes.filter { $0.explanation.contains("easy runs are on alternate days") || $0.explanation.contains("is shortened to") }.count
        }
        var restarted = midReturn(ran: [4: 100], planned: [4: 139], planFrom: 5)
        restarted.day(F.date(week: 5, day: 0, hour: 5))
        XCTAssertEqual(ret(restarted)?.restartWeek, monday(5))
        XCTAssertEqual(alternateDayChanges(restarted), 0, "no week-1 guard on the restarted week")
        // The same week as step 1 through a recurrence in week 4 (no restart): the guards apply.
        var stepBack = midReturn(step: 1, stepWeek: 5, ran: [4: 120], planned: [4: 139], failed: [2], planFrom: 5)
        stepBack.day(F.date(week: 5, day: 0, hour: 5))
        XCTAssertNil(ret(stepBack)?.restartWeek)
        XCTAssertGreaterThan(alternateDayChanges(stepBack), 0, "week 1's guards return through the recurrence rule")
    }

    // MARK: A week with no recorded plan

    /// A return week run before the plan existed (no recorded planned volume) counts as planned at its step's
    /// ceiling: week 4 ran 100 against step 1's 139.1 min (100 < 139.1 / 1.2 = 115.9) is short.
    func testAWeekWithNoRecordedPlanCountsAsPlannedAtItsStepsCeiling() throws {
        var d = midReturn(ran: [4: 100], planned: [:], planFrom: 5)
        d.day(F.date(week: 5, day: 0, hour: 5))
        XCTAssertEqual(ret(d)?.restartWeek, monday(5))
        var ok = midReturn(ran: [4: 120], planned: [:], planFrom: 5)
        ok.day(F.date(week: 5, day: 0, hour: 5))
        XCTAssertNil(ret(ok)?.restartWeek, "120 >= 115.9")
    }

    /// No restart after a stop of 14 days off or fewer (rule 6's regrowth has its own) or with no level.
    func testNoRestartAfterAShortStopOrWithoutALevel() throws {
        var short = midReturn(ran: [4: 100], planned: [4: 139], planFrom: 5)
        short.state.painRecovery.painReturn = PainReturn(start: F.date(week: 3, day: 2, hour: 6), level: level, preStopLongRun: 3600,
                                                         daysOff: 14, fromMovement: false, stepWeek: monday(4))
        short.day(F.date(week: 5, day: 0, hour: 5))
        XCTAssertNil(ret(short)?.restartWeek)
        XCTAssertNil(ret(short)?.judgedThrough)
        var none = midReturn(ran: [4: 100], planned: [4: 139], planFrom: 5)
        none.state.painRecovery.painReturn = PainReturn(start: F.date(week: 3, day: 2, hour: 6), level: nil, preStopLongRun: 3600,
                                                        daysOff: 20, fromMovement: false, stepWeek: monday(4))
        none.day(F.date(week: 5, day: 0, hour: 5))
        XCTAssertNil(ret(none)?.restartWeek)
    }

    // MARK: Stored state

    /// A state stored by format version 5 (before the restart state existed), mid-return after 20 days off: the
    /// return started on Wednesday 2026-01-28 06:00 UTC, level 214 min, week 4 (Mon 2026-02-02) its first full week.
    /// Dates are seconds since 2001-01-01, as the encoder writes them.
    private static let version5State = #"""
    {"formatVersion":5,"assessments":[],"qualitySignals":[],"easyHeartRates":[],"longRuns":[],"painCheckIns":[],"freezes":[],"holds":[],"qualityPaceFactor":1,"easyPaceFactor":1,"reportedHoldShortfalls":[],"painReports":[],"painRecovery":{"cannotEnd":false,"flaggedThisStop":false,"frozenUsual":2,"painReturn":{"daysOff":20,"failedSteps":[],"fromMovement":true,"level":12840,"planWeeks":[{"volume":12840,"week":789264000},{"volume":12840,"week":789868800}],"preStopLongRun":3600,"start":791272800,"step":1,"stepWeek":791683200},"prePlanWeeks":[],"preStopLongRun":3600,"stopFromMovement":true,"usualSamples":[]},"planSnapshot":{"sessions":[],"earlier":[],"returned":[],"planned":[{"week":791683200,"volume":8340}]},"preCap":{"weeks":[]}}
    """#

    func testAVersion5StateDecodesWithNoRestartYet() throws {
        let state = try JSONDecoder().decode(AdaptationState.self, from: Data(Self.version5State.utf8))
        let r = try XCTUnwrap(state.painRecovery.painReturn)
        XCTAssertEqual(r.start, F.date(week: 3, day: 2, hour: 6))
        XCTAssertEqual(r.stepWeek, monday(4))
        XCTAssertEqual(r.level, level)
        XCTAssertNil(r.restartWeek)
        XCTAssertNil(r.restartFloor)
        XCTAssertNil(r.judgedThrough)
        XCTAssertEqual(AdaptationState.formatVersion, 6)
        // Written back it is version 6 and reads the same.
        let data = try JSONEncoder().encode(state)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"formatVersion\":6"))
        XCTAssertEqual(try JSONDecoder().decode(AdaptationState.self, from: data), state)
    }

    /// The engine carries on from that state: week 4 was planned at 139 (the stored snapshot) and run at 100, so the
    /// next event restarts the steps; the new fields are then stored and read back.
    func testTheEngineCarriesOnFromAVersion5State() throws {
        var history = F.weeks(0..<3)
        for day in [1, 3, 5] { history.append(F.easy("h4-\(day)", week: 4, day: day, minutes: 100.0 / 3)) }
        var d = F.Driver(plan: F.weeks(5..<14), history: history, context: context)
        d.state = try JSONDecoder().decode(AdaptationState.self, from: Data(Self.version5State.utf8))
        d.day(F.date(week: 5, day: 0, hour: 5))
        let r = try XCTUnwrap(ret(d))
        XCTAssertEqual(r.restartWeek, monday(5))
        XCTAssertEqual(r.restartFloor ?? 0, 6000, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(minutes(5, d.plan), c1 + 1e-6)
        let back = try JSONDecoder().decode(AdaptationState.self, from: JSONEncoder().encode(d.state))
        XCTAssertEqual(back, d.state)
        XCTAssertEqual(back.painRecovery.painReturn?.restartWeek, monday(5))
        // A version 5 state whose return has already run weeks as planned just goes on: nothing is restarted.
        var plain = F.Driver(plan: F.weeks(5..<14), history: F.weeks(0..<3) + [F.easy("h4", week: 4, day: 3, minutes: 139)], context: context)
        plain.state = try JSONDecoder().decode(AdaptationState.self, from: Data(Self.version5State.utf8))
        plain.day(F.date(week: 5, day: 0, hour: 5))
        XCTAssertNil(ret(plain)?.restartWeek, "139 min run of 139 planned")
        XCTAssertEqual(plain.course.returnStep, 2)
    }
}
