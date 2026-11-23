import XCTest
@testable import CoachCore

extension AdaptFixture.Driver {
    /// A morning report at 06:00 of `week`/`day` (SPEC 3.5 rule 7: pain in
    /// the spot and pain on daily walking).
    mutating func morning(week: Int, day: Int, _ score: Int?, walking: Int? = 0, moved: Bool = false,
                          flags: [PainRedFlag] = [], hour: Int = 6) {
        report(PainReport(date: AdaptFixture.date(week: week, day: day, hour: hour), timing: .nextMorning,
                          hasPain: (score ?? 1) > 0, changedMovement: moved, score: score, walkingScore: walking, redFlags: flags))
    }

    /// An after-run report at `hour` of `week`/`day`.
    mutating func afterRun(week: Int, day: Int, _ score: Int?, worsened: Bool = false, moved: Bool = false,
                           activityID: String? = nil, hour: Int = 9) {
        report(PainReport(date: AdaptFixture.date(week: week, day: day, hour: hour), timing: .afterRun,
                          hasPain: (score ?? 1) > 0, worsenedDuringRun: worsened, changedMovement: moved, score: score,
                          activityID: activityID))
    }

    /// The test run as planned, or nil.
    var testSession: PlannedWorkout? {
        state.painRecovery.test.flatMap { t in plan.first { $0.id == t.workoutID } }
    }

    /// Runs the offered test run, then reports in-run pain an hour after it ends.
    mutating func runTest(_ score: Int?, worsened: Bool = false, moved: Bool = false,
                          file: StaticString = #filePath, line: UInt = #line) {
        guard let w = testSession else { return XCTFail("no test run offered", file: file, line: line) }
        mornings(through: w.date)
        take(AdaptationEngine.processRun(AdaptFixture.run(for: w), state: state, plan: plan, history: history, context: context))
        report(PainReport(date: w.date.addingTimeInterval(w.durationSeconds + 3600), timing: .afterRun,
                          hasPain: (score ?? 1) > 0, worsenedDuringRun: worsened, changedMovement: moved, score: score,
                          activityID: "run-\(w.id)"))
    }

    /// A morning report at 06:00 the day after `date`.
    mutating func morningAfter(_ date: Date, _ score: Int?, walking: Int? = 0) {
        let cal = PlanCalendar.calendar(timeZone: context.timeZone)
        let next = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: date))!.addingTimeInterval(6 * 3600)
        report(PainReport(date: next, timing: .nextMorning, hasPain: (score ?? 1) > 0, score: score, walkingScore: walking))
    }

    /// The app hands in a re-planned plan (F2, F3), keeping an offered test run.
    mutating func handFreshPlan(_ fresh: [PlannedWorkout]) {
        let test = state.painRecovery.test.flatMap { t in plan.first { $0.id == t.workoutID } }
        let cal = PlanCalendar.calendar(timeZone: context.timeZone)
        let today = cal.startOfDay(for: fresh.map(\.date).min() ?? .distantPast)
        plan = (fresh.filter { $0.date >= today && $0.id != test?.id } + (test.map { [$0] } ?? [])).sorted { $0.date < $1.date }
    }

    /// Runs the planned sessions of `date`'s day (not rest or races) as
    /// planned, scaled by `scale`, each reported at `score` after it.
    mutating func runAsPlanned(on date: Date, scale: Double = 1, score: Int = 0) {
        let cal = PlanCalendar.calendar(timeZone: context.timeZone)
        let ids = plan.filter { cal.isDate($0.date, inSameDayAs: date) && $0.kind != .rest && $0.kind != .race }.map(\.id)
        for id in ids {
            guard let w = plan.first(where: { $0.id == id }) else { continue }
            mornings(through: w.date)
            guard let current = plan.first(where: { $0.id == id }) else { continue }
            take(AdaptationEngine.processRun(AdaptFixture.run(for: current, AdaptFixture.RunSpec(durationScale: scale)),
                                             state: state, plan: plan, history: history, context: context))
            report(PainReport(date: current.date.addingTimeInterval(current.durationSeconds * scale + 1800), timing: .afterRun,
                              hasPain: score > 0, score: score, activityID: "run-\(current.id)"))
        }
    }

    var course: PainCourseStatus { outcomes.last!.painCourse }
}

// SPEC 3.5 rule 7 inside the F4 engine (#73): usual pain, the next-morning
// trigger, ending a stop, the return guards and the clinician flag.
// Synthetic plans and reports only.
final class AdaptationPainRecoveryTests: XCTestCase {
    typealias F = AdaptFixture

    func context(tracksPain: Bool = true, seed: Int? = 2) -> AdaptationContext {
        AdaptationContext(zones: F.zones, timeZone: F.tz, tracksPain: tracksPain, usualPainSeed: seed)
    }

    /// Runs week 0's Tuesday threshold session (t0, 07:00 to 07:54).
    func started(_ ctx: AdaptationContext, weeks: Range<Int> = 0..<6) -> F.Driver {
        var d = F.Driver(plan: F.weeks(weeks), context: ctx)
        d.follow(until: F.date(week: 0, day: 1, hour: 8)) { _ in F.RunSpec() }
        return d
    }

    /// Stopped by pain that got worse during t0, usual 2 (the interview seed).
    func stopped(_ ctx: AdaptationContext? = nil, moved: Bool = false, weeks: Range<Int> = 0..<6) -> F.Driver {
        var d = started(ctx ?? context(), weeks: weeks)
        d.afterRun(week: 0, day: 1, 3, worsened: true, moved: moved, activityID: "run-t0")
        return d
    }

    /// Stopped, then 2 good mornings (Wed, Thu) and a passed test run on
    /// Thursday's easy run; Friday's morning ends the stop.
    func returning(_ ctx: AdaptationContext? = nil, weeks: Range<Int> = 0..<6) -> F.Driver {
        var d = stopped(ctx, weeks: weeks)
        d.morning(week: 0, day: 2, 2, walking: 1)
        d.morning(week: 0, day: 3, 1, walking: 0)
        d.runTest(3, worsened: true)
        d.morning(week: 0, day: 4, 2)
        return d
    }

    func assertNoQuality(_ d: F.Driver, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(d.plan.contains { $0.kind.isQuality }, "no quality session", file: file, line: line)
    }

    // MARK: Usual pain

    func testUsualComesFromTheSeedThenCheckInsAndRoundsDown() {
        var d = started(context(seed: 3))
        XCTAssertEqual(d.course.usual, 3)
        d.checkIn(1, at: F.date(week: 0, day: 1, hour: 9))
        d.checkIn(2, at: F.date(week: 0, day: 5, hour: 9))
        XCTAssertEqual(d.course.usual, 3, "two stable check-ins: still the seed")
        d.checkIn(2, at: F.date(week: 1, day: 1, hour: 9))
        XCTAssertEqual(d.course.usual, 2, "median of 1, 2, 2")
        d.checkIn(1, at: F.date(week: 1, day: 5, hour: 9))
        XCTAssertEqual(d.course.usual, 1, "median of 1, 1, 2, 2 is 1.5, rounded down")
        XCTAssertEqual(d.state.painRecovery.usualSamples.count, 4)
    }

    func testUsualIsZeroWithoutAPainHistoryWhateverTheSeed() {
        let d = started(context(tracksPain: false, seed: 5))
        XCTAssertEqual(d.course.usual, 0)
    }

    func testUsualIsFrozenDuringTheStopAndTheReturn() {
        var d = stopped()
        XCTAssertEqual(d.state.painRecovery.frozenUsual, 2)
        d.checkIn(0, at: F.date(week: 0, day: 2, hour: 9))
        d.checkIn(0, at: F.date(week: 0, day: 2, hour: 10))
        d.checkIn(0, at: F.date(week: 0, day: 2, hour: 11))
        XCTAssertEqual(d.course.usual, 2, "check-ins during a stop are not stable")
        XCTAssertTrue(d.state.painRecovery.usualSamples.allSatisfy { $0.date < F.date(week: 0, day: 1, hour: 9) })
        // A changed seed (say, the runner edits the interview) doesn't move it either.
        var edited = d
        edited = F.Driver(plan: d.plan, history: d.history, context: context(seed: 0))
        edited.state = d.state
        edited.day(F.date(week: 0, day: 2, hour: 12))
        XCTAssertEqual(edited.course.usual, 2)
    }

    // MARK: Next-morning trigger through the engine

    func testNextMorningUsualPlusOneFreezesAndPlusTwoStops() {
        var d = started(context())
        d.morning(week: 0, day: 2, 3)   // 22 h after t0, usual + 1
        XCTAssertNil(d.state.painStop)
        XCTAssertTrue(d.outcomes.last!.changes.contains { $0.kind == .painVolumeFreeze && $0.rule.contains("rule 7") })
        XCTAssertFalse(d.state.freezes.isEmpty)
        var e = started(context())
        e.morning(week: 0, day: 2, 4)
        XCTAssertEqual(e.state.painStop?.triggers, [.stillThereNextMorning])
    }

    func testNextMorningStillAboveUsualAfter48HoursStops() {
        var d = started(context())
        // t0 ended at 07:54 on Tuesday; Thursday 07:53 is just under 48 hours.
        d.report(PainReport(date: F.date(week: 0, day: 3, hour: 7).addingTimeInterval(53 * 60), timing: .nextMorning,
                            hasPain: true, score: 3))
        XCTAssertNil(d.state.painStop)
        d.report(PainReport(date: F.date(week: 0, day: 3, hour: 7).addingTimeInterval(54 * 60), timing: .nextMorning,
                            hasPain: true, score: 3))
        XCTAssertEqual(d.state.painStop?.triggers, [.stillThereNextMorning])
    }

    func testRedFlagStopsAtOnceWithTheClinicianFlag() {
        var d = started(context(tracksPain: false, seed: nil))
        d.morning(week: 0, day: 2, 1, flags: [.swelling])
        XCTAssertEqual(d.state.painStop?.mode, .rest)
        XCTAssertEqual(d.state.painStop?.triggers, [.redFlag])
        XCTAssertEqual(d.course.clinicianFlag?.reasons, [.redFlag])
        XCTAssertTrue(d.outcomes.last!.adviseClinician)
        XCTAssertTrue(d.course.askMorningQuestions)
    }

    // MARK: Ending a stop

    func testStopEndsAfterTwoMorningsWalkingAndAPassedTestRun() {
        var d = stopped()
        XCTAssertNotNil(d.state.painStop)
        d.morning(week: 0, day: 2, 2, walking: 1)
        XCTAssertNil(d.state.painRecovery.test, "one morning is not enough")
        d.morning(week: 0, day: 3, 1, walking: 0)
        let test = d.testSession!
        XCTAssertEqual(test.id, "e0a", "Thursday's easy run becomes the test run")
        XCTAssertEqual(test.durationSeconds, 20 * 60, "no easy run in the history: 20 minutes")
        XCTAssertEqual(test.kind, .easy)
        XCTAssertEqual(d.course.testRun?.id, "e0a")
        XCTAssertTrue(d.outcomes.last!.changes.contains { $0.kind == .painTestRun && $0.workoutIDs == ["e0a"] })
        // Pain got worse during the test but stayed within usual + 1 and 3/10:
        // only the test-run limits judge it.
        d.runTest(3, worsened: true)
        XCTAssertNotNil(d.state.painStop)
        XCTAssertEqual(d.state.painStop?.triggers, [.worsenedDuringRun], "no new trigger from the test")
        XCTAssertEqual(d.state.painRecovery.test?.inRunPassed, true)
        d.morning(week: 0, day: 4, 2)
        XCTAssertNil(d.state.painStop)
        XCTAssertTrue(d.course.returnStarted)
        XCTAssertEqual(d.course.returnStep, 1)
        XCTAssertEqual(d.state.painRecovery.painReturn?.daysOff, 1, "Wednesday off between t0 and the test")
        XCTAssertTrue(d.outcomes.last!.changes.contains { $0.kind == .painStopEnded })
        XCTAssertEqual(d.state.painRecovery.frozenUsual, 2, "usual stays frozen through the return")
        assertNoQuality(d)
    }

    func testAFailedTestRestartsTheCount() {
        var d = stopped()
        d.morning(week: 0, day: 2, 2)
        d.morning(week: 0, day: 3, 2)
        d.runTest(4)   // above usual + 1
        XCTAssertNil(d.state.painRecovery.test)
        XCTAssertNotNil(d.state.painStop)
        XCTAssertTrue(d.outcomes.last!.changes.contains { $0.kind == .painTestRunFailed && $0.explanation.contains("didn't pass") })
        d.morning(week: 0, day: 4, 2)
        XCTAssertNil(d.state.painRecovery.test, "the count starts again: one morning")
        d.morning(week: 0, day: 5, 2)
        XCTAssertNotNil(d.testSession, "two new mornings: a new test")
    }

    func testATestFailsOnAMorningAboveUsualOrWithNoInRunReport() {
        var d = stopped()
        d.morning(week: 0, day: 2, 2)
        d.morning(week: 0, day: 3, 2)
        d.runTest(2)
        d.morning(week: 0, day: 4, 3)   // usual + 1 the next morning
        XCTAssertNotNil(d.state.painStop)
        XCTAssertNil(d.state.painRecovery.test)
        // No in-run report at all: the morning after fails the test too.
        var e = stopped()
        e.morning(week: 0, day: 2, 2)
        e.morning(week: 0, day: 3, 2)
        let w = e.testSession!
        e.take(AdaptationEngine.processRun(F.run(for: w), state: e.state, plan: e.plan, history: e.history, context: e.context))
        e.morning(week: 0, day: 4, 0)
        XCTAssertNotNil(e.state.painStop)
        XCTAssertTrue(e.outcomes.last!.changes.contains { $0.kind == .painTestRunFailed && $0.explanation.contains("no pain report") })
    }

    func testANextMorningTriggerAfterTheTestStopsAtOnce() {
        var d = stopped()
        d.morning(week: 0, day: 2, 2)
        d.morning(week: 0, day: 3, 2)
        d.runTest(3)
        d.morning(week: 0, day: 4, 5)
        XCTAssertEqual(Set(d.state.painStop!.triggers), [.worsenedDuringRun, .stillThereNextMorning])
        XCTAssertEqual(d.state.painStop?.mode, .rest, "two triggers: rest")
    }

    func testAMovementChangeDuringTheTestFailsItAndStops() {
        var d = stopped()
        d.morning(week: 0, day: 2, 2)
        d.morning(week: 0, day: 3, 2)
        d.runTest(1, moved: true)
        XCTAssertNil(d.state.painRecovery.test)
        XCTAssertEqual(d.state.painStop?.mode, .rest)
        XCTAssertTrue(d.state.painRecovery.stopFromMovement)
    }

    func testAfterAMovementStopTheTestAllowsNoPainAboveUsual() {
        var d = stopped(moved: true)
        XCTAssertEqual(d.state.painStop?.mode, .rest)
        d.morning(week: 0, day: 2, 2)
        d.morning(week: 0, day: 3, 2)
        let test = d.testSession!
        XCTAssertEqual(test.kind, .easy, "the test run is the one run a rest-mode stop allows")
        XCTAssertTrue(d.plan.filter { $0.id != test.id }.allSatisfy { $0.kind == .rest || $0.kind == .race })
        d.runTest(3)   // usual + 1: fine after other stops, not after a movement change
        XCTAssertNil(d.state.painRecovery.test)
        XCTAssertNotNil(d.state.painStop)
    }

    func testAMorningAboveUsualWithdrawsAnOfferedTest() {
        var d = stopped()
        d.morning(week: 0, day: 2, 2)
        d.morning(week: 0, day: 3, 2, hour: 5)
        XCTAssertEqual(d.testSession?.id, "e0a")
        d.morning(week: 0, day: 3, 3, hour: 6)   // a second, worse report that morning
        XCTAssertNil(d.state.painRecovery.test)
        XCTAssertEqual(d.plan.first { $0.id == "e0a" }?.kind, .rest)
        XCTAssertTrue(d.outcomes.last!.changes.contains { $0.kind == .painTestRunWithdrawn && $0.explanation.contains("withdrawn") })
    }

    func testAMissedTestIsOfferedAgain() {
        var d = stopped()
        d.morning(week: 0, day: 2, 2)
        d.morning(week: 0, day: 3, 2)
        XCTAssertEqual(d.testSession?.id, "e0a")
        d.day(F.date(week: 0, day: 4, hour: 5))   // Thursday passed without the run, no new morning yet
        XCTAssertNotNil(d.testSession, "offered again")
        XCTAssertNotEqual(d.testSession?.id, "e0a")
    }

    func testAnyReportAboveUsualRestartsTheCount() {
        var d = stopped()
        d.morning(week: 0, day: 2, 2)
        d.afterRun(week: 0, day: 2, 3, hour: 12)   // an easy run during the stop, usual + 1
        d.morning(week: 0, day: 3, 2)
        XCTAssertNil(d.state.painRecovery.test, "the 2 mornings and the test must be 3 reports in a row at or below usual")
    }

    func testUsualFourOrMoreCannotEndAndRaisesTheFlag() {
        var d = stopped(context(seed: 4))
        XCTAssertTrue(d.state.painRecovery.cannotEnd)
        XCTAssertTrue(d.course.stopCannotEnd)
        XCTAssertEqual(d.course.clinicianFlag?.reasons, [.staysStopped])
        for day in 2...6 { d.morning(week: 0, day: day, 0) }
        XCTAssertNil(d.state.painRecovery.test, "no test run however good the mornings")
        XCTAssertNotNil(d.course.clinicianFlag, "reports at or below usual alone never clear it")
        XCTAssertNotNil(d.state.painStop)
        // Usual 3 is the boundary below.
        let e = stopped(context(seed: 3))
        XCTAssertFalse(e.state.painRecovery.cannotEnd)
        XCTAssertNil(e.course.clinicianFlag)
    }

    func testWalkingPainStillThreeAboutSevenDaysInRaisesTheFlag() {
        var d = stopped()   // since Tuesday 09:00 of week 0
        for day in 2...6 { d.morning(week: 0, day: day, 2, walking: 3) }
        d.morning(week: 1, day: 0, 2, walking: 3)
        XCTAssertNil(d.course.clinicianFlag, "6 days in: not yet")
        d.morning(week: 1, day: 1, 2, walking: 3)
        XCTAssertEqual(d.course.clinicianFlag?.reasons, [.staysStopped])
        XCTAssertNotNil(d.state.painStop)
        // Walking settles: the normal end path still ends the stop and clears the flag.
        d.morning(week: 1, day: 2, 2, walking: 2)
        d.morning(week: 1, day: 3, 2, walking: 1)
        // Week 1 is held to 10% over the stop week's 54 minutes, so other runs
        // make room for the test run rather than the test being dropped.
        let test = try! XCTUnwrap(d.testSession)
        XCTAssertLessThanOrEqual(F.weekVolume(1, d.plan.filter { $0.date >= F.date(week: 1, day: 3, hour: 7) }), 59 * 60)
        d.runTest(2)
        d.morningAfter(test.date, 1, walking: 0)
        XCTAssertNil(d.state.painStop)
        XCTAssertNil(d.course.clinicianFlag)
        XCTAssertEqual(d.state.painRecovery.flagEnded?.how, .cleared)
        XCTAssertFalse(d.outcomes.last!.adviseClinician)
    }

    func testNoPainHistoryNewPainAboveZeroAboutSevenDaysInRaisesTheFlag() {
        var d = started(context(tracksPain: false, seed: nil))
        d.afterRun(week: 0, day: 1, 1, worsened: true, activityID: "run-t0")
        for day in 2...6 { d.morning(week: 0, day: day, 1) }
        d.morning(week: 1, day: 0, 1)
        d.morning(week: 1, day: 1, 1)
        XCTAssertTrue(d.course.clinicianFlag?.reasons.contains(.staysStopped) ?? false)
        XCTAssertNil(d.state.painRecovery.test, "usual 0: mornings must be back at 0")
    }

    // MARK: Lasting pain above usual

    func testPainAboveUsualOnMostDaysForAWeekStopsAndFlags() {
        var d = started(context(tracksPain: false, seed: nil))
        for k in 0...6 {
            d.report(PainReport(date: F.date(week: 0, day: 2, hour: 12).addingTimeInterval(Double(k) * 86_400),
                                timing: .afterRun, hasPain: true, score: 1))
        }
        XCTAssertNil(d.state.painStop, "day 6: not yet a week")
        d.report(PainReport(date: F.date(week: 1, day: 2, hour: 12), timing: .afterRun, hasPain: true, score: 1))
        XCTAssertEqual(d.state.painStop?.triggers, [.lastingAboveUsual])
        XCTAssertEqual(d.course.clinicianFlag?.reasons, [.lastingAboveUsual])
        // A tracker whose usual is 1 is not lasting at 1.
        var e = started(context(seed: 1))
        for k in 0...8 {
            e.report(PainReport(date: F.date(week: 0, day: 2, hour: 12).addingTimeInterval(Double(k) * 86_400),
                                timing: .afterRun, hasPain: true, score: 1))
        }
        XCTAssertNil(e.state.painStop)
        XCTAssertNil(e.course.clinicianFlag)
    }

    // MARK: Clinician flag off, ask, close, reopen

    func flagged() -> F.Driver {
        var d = started(context(seed: 2))
        d.morning(week: 0, day: 2, 2, flags: [.numbnessOrTingling])
        return d
    }

    func testTheFlagTurnsOffOnlyWithThreeReportsIncludingAPassedTest() {
        var d = flagged()
        XCTAssertNotNil(d.course.clinicianFlag)
        d.morning(week: 0, day: 3, 2)
        d.morning(week: 0, day: 4, 2)
        XCTAssertNotNil(d.course.clinicianFlag, "two reports at or below usual: still on")
        XCTAssertEqual(d.course.clinicianFlag?.streak, 2)
        d.runTest(2)
        XCTAssertNotNil(d.course.clinicianFlag, "the test's in-run report waits for its morning")
        d.morning(week: 0, day: 6, 2)
        XCTAssertNil(d.course.clinicianFlag)
        XCTAssertNil(d.state.painStop)
        XCTAssertEqual(d.state.painRecovery.flagEnded?.how, .cleared)
    }

    func testSilenceAsksOnceAtSevenDaysAndClosesAtFourteen() {
        var d = flagged()   // raised Wednesday 06:00 of week 0
        var asks: [Int] = []
        for k in 1...15 {
            let n = d.outcomes.count
            d.day(F.date(week: 0, day: 2, hour: 7).addingTimeInterval(Double(k) * 86_400))
            let step = d.outcomes[n...]   // this day's midnight call and the 07:00 one
            if step.contains(where: { $0.painCourse.askForReport }) { asks.append(k) }
            if k < 14 {
                XCTAssertNotNil(d.course.clinicianFlag, "day \(k): silence never clears it")
                XCTAssertTrue(d.outcomes.last!.adviseClinician)
            }
            XCTAssertEqual(step.filter { $0.painCourse.flagClosedUnresolved }.count, k == 14 ? 1 : 0,
                           "day \(k): set on the closing event only")
        }
        XCTAssertEqual(asks, [7], "asked once")
        XCTAssertNil(d.course.clinicianFlag)
        XCTAssertFalse(d.outcomes.last!.adviseClinician)
        XCTAssertEqual(d.state.painRecovery.flagEnded?.how, .closedUnresolved)
        XCTAssertNotNil(d.state.painStop, "the close never ends a stop")
        XCTAssertEqual(d.state.painRecovery.frozenUsual, 2, "usual stays frozen while the stop stands")
    }

    func testAReportResetsTheSilenceClock() {
        var d = flagged()
        d.day(F.date(week: 0, day: 2, hour: 7).addingTimeInterval(6 * 86_400))
        d.morning(week: 1, day: 1, 3)   // above usual: the flag stays, the clock restarts
        let n = d.outcomes.count
        d.day(F.date(week: 1, day: 6, hour: 7))
        XCTAssertFalse(d.outcomes[n...].contains { $0.painCourse.askForReport }, "6 days after the report")
        let m = d.outcomes.count
        d.day(F.date(week: 2, day: 1, hour: 7))
        XCTAssertTrue(d.outcomes[m...].contains { $0.painCourse.askForReport }, "7 days after the report")
        XCTAssertNotNil(d.course.clinicianFlag)
    }

    func testANewTriggerWithinSixWeeksOfTheFlagReopensIt() {
        var d = flagged()
        d.morning(week: 0, day: 3, 2)
        d.morning(week: 0, day: 4, 2)
        d.runTest(2)
        d.morning(week: 0, day: 6, 2)
        XCTAssertNil(d.course.clinicianFlag)
        let ended = d.state.painRecovery.flagEnded!.date
        // A next-morning trigger in the return reopens the stop, and the flag with it.
        d.morning(week: 1, day: 1, 5)
        XCTAssertNotNil(d.state.painStop)
        XCTAssertEqual(d.course.clinicianFlag?.reasons, [.reopened])
        XCTAssertLessThanOrEqual(d.state.painStop!.since.timeIntervalSince(ended), 42 * 86_400)
    }

    func testATriggerMoreThanSixWeeksAfterTheFlagDoesNotReopenIt() {
        var d = flagged()
        d.morning(week: 0, day: 3, 2)
        d.morning(week: 0, day: 4, 2)
        d.runTest(2)
        d.morning(week: 0, day: 6, 2)    // flag cleared Sunday of week 0
        d.day(F.date(week: 5, day: 0))
        // The return is taken as over. Driving it out with runReturnOut takes
        // past the 42-day window here: from a rest-mode stop, the guardrails
        // hold the weeks below 90% of the pre-stop reference for longer than
        // that. How the return ends is tested in the return tests below.
        d.state.painRecovery.painReturn = nil
        d.state.painRecovery.frozenUsual = nil
        var later = F.Driver(plan: F.weeks(6..<9), history: d.history, context: d.context)
        later.state = d.state
        later.afterRun(week: 6, day: 6, 2, worsened: true, hour: 10)   // 42 days after: still inside
        XCTAssertEqual(later.course.clinicianFlag?.reasons, [.reopened])
        var outside = F.Driver(plan: F.weeks(7..<9), history: d.history, context: d.context)
        outside.state = d.state
        outside.afterRun(week: 7, day: 0, 2, worsened: true, hour: 10)  // 43 days after
        XCTAssertNotNil(outside.state.painStop)
        XCTAssertNil(outside.course.clinicianFlag)
    }

    // MARK: The return

    func testReturnWeekOneIsAlternateDaysWithTheLongRunCapped() {
        let d = returning()
        // The return started on Friday of week 0; week 1 is still week 1.
        let l0 = d.plan.first { $0.id == "l0" }!
        XCTAssertEqual(l0.durationSeconds, 39 * 60, "65% of the 60-minute pre-stop long run")
        XCTAssertEqual(d.plan.first { $0.id == "e0b" }?.kind, .rest, "Sunday is next to Saturday's long run")
        let week1 = d.plan.filter { PlanCalendar.weekStart(containing: $0.date, timeZone: F.tz) == PlanCalendar.weekStart(containing: F.date(week: 1, day: 0), timeZone: F.tz) }
        let runDays = week1.filter { $0.kind != .rest }.map { Calendar(identifier: .gregorian).component(.weekday, from: $0.date) }
        XCTAssertEqual(runDays.count, 3, "Tue, Thu, Sat")
        for (a, b) in zip(runDays, runDays.dropFirst()) { XCTAssertGreaterThanOrEqual(b - a, 2) }
        XCTAssertLessThanOrEqual(F.weekVolume(1, d.plan), 0.65 * 214 * 60 + 1e-6)
        XCTAssertEqual(d.plan.first { $0.id == "l1" }?.durationSeconds, 39 * 60)
        assertNoQuality(d)
        assertAdaptationSound(d.outcomes)
    }

    func testReturnRegrowsAndQualityComesBackAfterAFullWeekAtPlanVolume() {
        var d = returning()
        d.day(F.date(week: 2, day: 0, hour: 5))
        XCTAssertEqual(d.course.returnStep, 2)
        XCTAssertLessThanOrEqual(F.weekVolume(2, d.plan), 0.825 * 214 * 60 + 1e-6)
        assertNoQuality(d)
        d.day(F.date(week: 3, day: 0, hour: 5))
        XCTAssertEqual(d.course.returnStep, 3)
        assertNoQuality(d)
        // Week 3 is run as planned with no symptoms, but nothing was run in
        // weeks 1 and 2, so the guardrails hold it far below the pre-stop
        // 214 minutes and it doesn't count.
        for day in 0..<7 { d.runAsPlanned(on: F.date(week: 3, day: day)) }
        assertNoQuality(d)
        XCTAssertLessThan(F.weekVolume(3, d.history), 0.9 * 214 * 60)
        var kept = F.Driver(plan: F.weeks(4..<6), history: d.history, context: d.context)
        kept.state = d.state
        kept.day(F.date(week: 4, day: 0, hour: 5))
        XCTAssertNotNil(kept.state.painRecovery.painReturn, "a week the guardrails cut short never counts")
        assertNoQuality(kept)
        // Run as planned with the app re-planning the weeks ahead each Monday
        // (F2, F3; repair only cuts, so a cut plan never grows back), the
        // weeks grow back and one counts.
        var e = returning(weeks: 0..<16)
        for day in 5..<7 { e.runAsPlanned(on: F.date(week: 0, day: day)) }
        // runReturnOut checks each repeat against its week's own reference.
        guard let (ended, last) = runReturnOut(&e, from: 1, through: 14, freshPlans: 0..<16) else { return XCTFail("the return never ended") }
        let endWeek = F.date(week: ended - 1, day: 0, hour: 0)
        let reference = try! XCTUnwrap(last.reference(forWeek: endWeek))
        XCTAssertEqual(last.planVolumeWeek(timeZone: F.tz), endWeek, "the week that ended it is the week at plan volume")
        XCTAssertGreaterThanOrEqual(F.weekVolume(ended - 1, e.history), 0.9 * reference - 1e-6)
        kept = F.Driver(plan: F.weeks(ended..<(ended + 2)), history: e.history, context: e.context)
        kept.state = e.state
        kept.day(F.date(week: ended, day: 0, hour: 6))
        XCTAssertNil(kept.state.painRecovery.painReturn)
        XCTAssertTrue(e.changes.contains { $0.kind == .painReturnStep && $0.explanation.contains("complete") })
        XCTAssertTrue(kept.plan.contains { $0.kind.isQuality }, "quality comes back")
        XCTAssertNil(kept.state.painRecovery.frozenUsual, "usual is measured again")
        XCTAssertEqual(kept.course.usual, 2)
    }

    func testSymptomsStepBackAndASecondFailureAtTheSameStepReopens() {
        var d = returning()
        d.day(F.date(week: 2, day: 0, hour: 5))
        d.afterRun(week: 2, day: 1, 3, hour: 10)   // step 2: above usual
        let r = d.state.painRecovery.painReturn!
        XCTAssertEqual(r.failedSteps, [2])
        XCTAssertEqual(d.course.returnStep, 1, "back one step")
        XCTAssertTrue(d.outcomes.last!.changes.contains { $0.kind == .painReturnStep })
        XCTAssertTrue(d.plan.filter { Calendar(identifier: .gregorian).isDate($0.date, inSameDayAs: F.date(week: 2, day: 2)) }
            .allSatisfy { $0.kind == .rest }, "the next day is rest")
        d.day(F.date(week: 3, day: 0, hour: 5))
        XCTAssertEqual(d.course.returnStep, 1, "the step before runs for a full week")
        d.day(F.date(week: 4, day: 0, hour: 5))
        XCTAssertEqual(d.course.returnStep, 2)
        d.afterRun(week: 4, day: 1, 3, hour: 10)
        XCTAssertEqual(d.state.painStop?.triggers, [.recurredInReturn])
        XCTAssertNil(d.state.painRecovery.painReturn)
        XCTAssertTrue(d.course.clinicianFlag?.reasons.contains(.secondFailure) ?? false)
        XCTAssertEqual(d.state.painRecovery.frozenUsual, 2)
    }

    func testWeekOneAllowsUsualPlusOneAndRepeatsOnSymptoms() {
        var d = returning()
        d.afterRun(week: 1, day: 1, 3, worsened: true, hour: 10)   // usual + 1 in week 1, even though it got worse
        XCTAssertNotNil(d.state.painRecovery.painReturn)
        XCTAssertEqual(d.state.painRecovery.painReturn?.failedSteps, [])
        XCTAssertNil(d.state.painStop, "in the return, pain that got worse is judged by the recurrence rule")
        d.afterRun(week: 1, day: 3, 4, hour: 10)
        XCTAssertEqual(d.state.painRecovery.painReturn?.failedSteps, [1])
        XCTAssertEqual(d.course.returnStep, 1)
        d.afterRun(week: 1, day: 5, 4, hour: 10)
        XCTAssertNotNil(d.state.painStop, "a second failure in week 1 reopens the stop")
    }

    func testAMovementChangeOrNextMorningTriggerInTheReturnReopensAtOnce() {
        var d = returning()
        d.afterRun(week: 1, day: 1, 0, moved: true, hour: 10)
        XCTAssertEqual(d.state.painStop?.triggers, [.changedMovement])
        XCTAssertEqual(d.state.painStop?.mode, .rest)
        XCTAssertNil(d.state.painRecovery.painReturn)
        XCTAssertEqual(d.course.clinicianFlag?.reasons, [.movementChangeInReturn],
                       "the stricter reading (#92): a movement change in the return also raises the flag")
        var e = returning()
        e.morning(week: 1, day: 2, 4)
        XCTAssertEqual(e.state.painStop?.triggers, [.stillThereNextMorning])
        XCTAssertNotNil(e.state.painStop?.level)
        XCTAssertEqual(e.state.painStop?.level, returning().state.painRecovery.painReturn?.level, "the pre-stop level carries over")
    }

    func testAReturnCheckInAboveUsualIsASymptom() {
        var d = returning()
        d.day(F.date(week: 2, day: 0, hour: 5))
        d.checkIn(3, at: F.date(week: 2, day: 1, hour: 9))
        XCTAssertEqual(d.state.painRecovery.painReturn?.failedSteps, [2])
    }

    // MARK: #72 review items

    func testStopLevelLeavesOutRacesAndRunsAfterTheStop() {
        let race = PlannedWorkout(id: "race", date: F.date(week: 0, day: 6), kind: .race, durationSeconds: 100 * 60)
        var d = F.Driver(plan: F.weeks(0..<3).filter { $0.id != "e0b" } + [race], context: context())
        d.follow(until: F.date(week: 0, day: 1, hour: 8)) { _ in F.RunSpec() }
        d.afterRun(week: 0, day: 1, 3, worsened: true, activityID: "run-t0")
        XCTAssertEqual(d.state.painStop?.level, (54 + 55 + 60) * 60, "the race is left out of the level")
    }

    func testStopLevelFallsBackToTheFirstKnownWeek() {
        // Nothing in the stop week or the week before; the plan starts a week later.
        var d = F.Driver(plan: F.weeks(2..<4), context: context())
        d.report(PainReport(date: F.date(week: 0, day: 2, hour: 9), timing: .afterRun, hasPain: true, worsenedDuringRun: true))
        XCTAssertEqual(d.state.painStop?.level, 214 * 60)
    }

    func testRunningMoreAfterTheStopDoesNotRaiseTheLevel() {
        var d = stopped()
        let level = d.state.painStop!.level!
        var hog = F.easy("extra", week: 0, day: 2, minutes: 120, hour: 12)
        hog.prescription = nil
        d.take(AdaptationEngine.processRun(F.run(for: hog), state: d.state, plan: d.plan, history: d.history, context: d.context))
        XCTAssertEqual(d.state.painStop?.level, level)
        // Even a stop whose level is filled in later ignores runs from the stop on.
        // A stop whose level is filled in later ignores runs from the stop on;
        // it reads the plan as the stop has cut it, so it can only come out lower.
        var e = d
        e.state.painStop?.level = nil
        e.day(F.date(week: 0, day: 3))
        XCTAssertLessThanOrEqual(e.state.painStop?.level ?? .infinity, level)
    }

    func testEasyOnlyLongRunCapFollowsTheRecoveryWeekCeiling() {
        // Week 2 is a recovery week (about 75%); its long run fits 35% of that week's ceiling.
        let plan = F.weeks(0..<4, easyMinutes: { $0 == 2 ? (35, 30) : (55, 45) }, longMinutes: { $0 == 2 ? 60 : 70 })
        var d = F.Driver(plan: plan, context: context())
        d.follow(until: F.date(week: 0, day: 1, hour: 8)) { _ in F.RunSpec() }
        d.afterRun(week: 0, day: 1, 3, worsened: true, activityID: "run-t0")
        let level = d.state.painStop!.level!
        let ratio = (54.0 + 35 + 60 + 30) / (54 + 55 + 70 + 45)
        let l2 = d.plan.first { $0.id == "l2" }!
        XCTAssertLessThanOrEqual(l2.durationSeconds, 0.35 * level * ratio + 1e-6)
        XCTAssertGreaterThan(l2.durationSeconds, 0.35 * level * ratio - 60.0001)
    }

    // MARK: The week at plan volume (review round 1)

    /// Returning, every run done as planned through week 2, at step 3 from week 3 on.
    func atPlanVolume() -> F.Driver {
        var d = returning()
        for day in 5..<21 { d.runAsPlanned(on: F.date(week: day / 7, day: day % 7)) }
        d.day(F.date(week: 3, day: 0, hour: 5))
        XCTAssertEqual(d.course.returnStep, 3)
        return d
    }

    func testAWeekNotRunAtPlanVolumeRepeats() {
        var d = atPlanVolume()
        XCTAssertGreaterThan(F.weekVolume(3, d.plan), 60 * 60)
        d.day(F.date(week: 4, day: 0, hour: 5))   // nothing run in week 3
        XCTAssertNotNil(d.state.painRecovery.painReturn, "0 minutes run: the return goes on")
        XCTAssertEqual(d.course.returnStep, 3)
        XCTAssertTrue(d.changes.contains { $0.kind == .painReturnRepeated && $0.explanation.contains("planned") })
        XCTAssertFalse(d.changes.contains { $0.kind == .painReturnStep && $0.explanation.contains("complete") })
        assertNoQuality(d)
    }

    /// Week 3 (the week at plan volume) as run: four easy runs that add up
    /// to `share` of its reference, written straight into the history (the
    /// engine would cut the rest of a week the runner over-ran), then judged.
    /// Returns what was run, the bar, and the driver.
    func weekAtShare(_ share: Double) -> (ran: Double, bar: Double, d: F.Driver) {
        var d = atPlanVolume()
        let r = d.state.painRecovery.painReturn!
        let week = F.date(week: 3, day: 0, hour: 0)
        XCTAssertEqual(r.planVolumeWeek(timeZone: F.tz), week)
        let reference = r.reference(forWeek: week)!
        let each = share * reference / 4 / 60
        d.history += [1, 3, 5, 6].map { F.easy("w3-\($0)", week: 3, day: $0, minutes: each) }
        let ran = F.weekVolume(3, d.history)
        d.day(F.date(week: 4, day: 0, hour: 5))
        return (ran, 0.9 * reference, d)
    }

    func testTheNinetyPercentBarFromBothSides() {
        let under = weekAtShare(0.885)
        XCTAssertLessThan(under.ran, under.bar)
        XCTAssertGreaterThan(under.ran, under.bar - 0.03 * under.bar / 0.9, "just under the bar")
        XCTAssertNotNil(under.d.state.painRecovery.painReturn, "just under 90%: the week repeats")
        XCTAssertTrue(under.d.changes.contains { $0.kind == .painReturnRepeated })
        let over = weekAtShare(0.915)
        XCTAssertGreaterThanOrEqual(over.ran, over.bar)
        XCTAssertLessThan(over.ran, over.bar + 0.03 * over.bar / 0.9, "just over the bar")
        XCTAssertNil(over.d.state.painRecovery.painReturn, "just over 90%: the return ends")
        XCTAssertTrue(over.d.changes.contains { $0.kind == .painReturnStep && $0.explanation.contains("complete") })
    }

    // Review round 2: the week is judged against the reference fixed before
    // the stop (214 minutes here), never the week as since cut.

    func testAWeekTheGuardrailsHoldBelowPlanDoesNotCount() {   // (a)
        var d = atPlanVolume()
        let planned = F.weekVolume(3, d.plan)
        XCTAssertLessThan(planned, 0.9 * 214 * 60, "the guardrails hold week 3 below the pre-stop plan")
        for day in 0..<7 { d.runAsPlanned(on: F.date(week: 3, day: day)) }
        XCTAssertEqual(F.weekVolume(3, d.history), planned, accuracy: 60)
        d.day(F.date(week: 4, day: 0, hour: 5))
        XCTAssertNotNil(d.state.painRecovery.painReturn, "everything planned was run, but it is short of 90% of 214 min")
        XCTAssertTrue(d.changes.contains { $0.kind == .painReturnRepeated && $0.explanation.contains("planned before the stop") })
        assertNoQuality(d)
    }

    func testAWeekAFreezeHoldsBelowPlanDoesNotCount() {   // (b)
        var d = returning()
        for day in 5..<20 { d.runAsPlanned(on: F.date(week: day / 7, day: day % 7)) }
        d.morning(week: 2, day: 6, 3)   // usual + 1: a 7-day freeze over week 3, no stop
        XCTAssertNil(d.state.painStop)
        XCTAssertFalse(d.state.freezes.isEmpty)
        d.runAsPlanned(on: F.date(week: 2, day: 6))
        for day in 0..<7 { d.runAsPlanned(on: F.date(week: 3, day: day)) }
        XCTAssertLessThan(F.weekVolume(3, d.history), 0.9 * 214 * 60)
        d.day(F.date(week: 4, day: 0, hour: 5))
        XCTAssertNotNil(d.state.painRecovery.painReturn)
        XCTAssertTrue(d.changes.contains { $0.kind == .painReturnRepeated })
    }

    func testAnEmptyWeekDoesNotCount() {   // (c)
        let d = atPlanVolume()
        var kept = F.Driver(plan: [], history: d.history, context: d.context)   // the plan ended
        kept.state = d.state
        kept.day(F.date(week: 3, day: 3, hour: 5))
        kept.day(F.date(week: 4, day: 0, hour: 5))
        XCTAssertNotNil(kept.state.painRecovery.painReturn, "0 min run never counts")
        XCTAssertEqual(kept.state.painRecovery.painReturn?.stepWeek, PlanCalendar.weekStart(containing: F.date(week: 4, day: 0), timeZone: F.tz))
        kept.day(F.date(week: 6, day: 0, hour: 5))
        XCTAssertNotNil(kept.state.painRecovery.painReturn)
    }

    func testARestModeReturnWhoseKeptPlanIsNeverHandedBackDoesNotEnd() {   // (d)
        var d = stopped(moved: true)
        d.morning(week: 0, day: 2, 2)
        d.morning(week: 0, day: 3, 2)
        d.runTest(2)
        d.morning(week: 0, day: 4, 2)
        XCTAssertNotNil(d.state.painRecovery.painReturn)
        XCTAssertTrue(d.course.returnStarted)
        // The rest-day plan is never handed back. It grows back toward the
        // plan as it stood before the stop, as easy runs (SPEC 3.5 rule 6,
        // #64), but nothing is run.
        for week in 1..<6 { d.day(F.date(week: week, day: 3, hour: 12)) }
        XCTAssertFalse(d.plan.contains { $0.kind.isQuality })
        XCTAssertNotNil(d.state.painRecovery.painReturn, "nothing run: the return never completes")
        XCTAssertFalse(d.changes.contains { $0.kind == .painReturnStep && $0.explanation.contains("complete") })
        // Every outcome passes the guardrails: once more than 14 days pass
        // with nothing run, the regrowth ends and the weeks are cut to their
        // floors; a week left with only its long run has it as an easy run
        // at the floor (3.5 rules 5 and 6, #122), never a lone "long" run
        // that is all of its week.
        assertAdaptationSound(d.outcomes)
        for w in 1..<6 {
            XCTAssertLessThanOrEqual(F.weekVolume(w, d.history + d.plan), F.weekVolume(w, F.weeks(0..<6)) + 1e-6, "week \(w): never above plan")
        }
    }

    func testAWeekWithNoEventIsJudgedOnWhatWasRun() {   // (e)
        let d = atPlanVolume()
        // No event at all in week 3 or 4: its sessions are missed and dropped.
        let o = AdaptationEngine.processDay(asOf: F.date(week: 5, day: 0, hour: 5), state: d.state, plan: d.plan,
                                            history: d.history, context: d.context)
        XCTAssertNotNil(o.state.painRecovery.painReturn)
        XCTAssertEqual(o.state.painRecovery.painReturn?.stepWeek, PlanCalendar.weekStart(containing: F.date(week: 5, day: 0), timeZone: F.tz),
                       "the week at plan volume is now the current week")
        XCTAssertTrue(o.changes.contains { $0.kind == .painReturnRepeated })
        XCTAssertFalse(o.plan.contains { $0.kind.isQuality })
    }

    func testAWeekWithANextMorningAboveUsualRepeats() {
        var d = atPlanVolume()
        for day in 0..<7 {
            d.runAsPlanned(on: F.date(week: 3, day: day))
            if day == 1 { d.morning(week: 3, day: 2, 3) }   // usual + 1 the morning after: freezes growth, no stop
        }
        XCTAssertNil(d.state.painStop)
        XCTAssertFalse(d.state.freezes.isEmpty)
        var kept = F.Driver(plan: F.weeks(4..<8), history: d.history, context: d.context)
        kept.state = d.state
        kept.day(F.date(week: 4, day: 0, hour: 5))
        XCTAssertNotNil(kept.state.painRecovery.painReturn, "a symptom in the week: it repeats")
        XCTAssertTrue(kept.changes.contains { $0.kind == .painReturnRepeated && $0.explanation.contains("above your usual") })
        assertNoQuality(kept)
    }

    /// Runs every planned session from `from` (a week) on, week by week, and
    /// returns the week whose start found the return over; nil if it never ends.
    /// Every repeat is checked against the reference of the week it judged
    /// (`PainReturn.reference(forWeek:)`). Returns the week whose start found
    /// the return over and the return as it stood just before.
    func runReturnOut(_ d: inout F.Driver, from: Int, through last: Int, freshPlans: Range<Int>? = nil,
                      file: StaticString = #filePath, line: UInt = #line) -> (Int, PainReturn)? {
        for week in from...last {
            if let r = freshPlans { d.handFreshPlan(F.weeks(week..<r.upperBound)) }
            for day in 0..<7 { d.runAsPlanned(on: F.date(week: week, day: day)) }
            guard let before = d.state.painRecovery.painReturn else { return nil }
            let n = d.changes.count
            d.day(F.date(week: week + 1, day: 0, hour: 5))
            let judged = before.planVolumeWeek(timeZone: F.tz)
            for c in d.changes[n...] where c.kind == .painReturnRepeated {
                let ref = before.reference(forWeek: judged) ?? .nan
                let t = c.triggers.first { $0.metric == .weeklyVolume }
                XCTAssertEqual(t?.expectedLow ?? .nan, 0.9 * ref, accuracy: 1e-6, "the repeat's bar is 90% of its week's reference", file: file, line: line)
                XCTAssertLessThan(t?.value ?? .infinity, 0.9 * ref, "a repeat only below the bar", file: file, line: line)
                XCTAssertLessThan(F.weekVolume(week, d.history), 0.9 * ref, file: file, line: line)
            }
            if d.state.painRecovery.painReturn == nil { return (week + 1, before) }
        }
        return nil
    }

    // MARK: A stop of more than 14 days (owner decision Nov 21, #107)

    /// A rest-mode stop of about 20 days: the only run in the stop weeks is
    /// the 20-minute test run. The weeks back are bounded by the return's
    /// own ceilings (65%, 82.5%, 100% of the pre-stop level) and the spike
    /// rule, not by a weekly rise measured from the stop weeks (SPEC 3.5
    /// rule 7, owner decision Nov 21, #107), so with the app re-planning
    /// every week at full volume and the runner doing every run, the weeks
    /// grow, never above the plan or a ceiling, the return ends and quality
    /// comes back. Before, each week was held near 20 minutes for good.
    func testARestStopOfMoreThan14DaysGrowsBackUnderTheReturnsCeilings() throws {
        var d = stopped(moved: true, weeks: 0..<14)   // rest mode from Tuesday of week 0
        for day in 2..<21 { d.morning(week: day / 7, day: day % 7, 3) }   // above usual 2: stays stopped
        d.morning(week: 3, day: 0, 2)
        d.morning(week: 3, day: 1, 2)
        let test = try XCTUnwrap(d.testSession)
        XCTAssertEqual(test.durationSeconds, 20 * 60)
        d.runTest(2)
        d.morningAfter(test.date, 2)
        XCTAssertNil(d.state.painStop)
        let r = try XCTUnwrap(d.state.painRecovery.painReturn)
        XCTAssertGreaterThan(r.daysOff ?? 0, 14)
        let firstWeek = 4   // the test run is in week 3; the return's steps count from week 4
        var ended: Int?
        var ceilings: [Int] = []
        for week in firstWeek..<13 where ended == nil {
            d.handFreshPlan(F.weeks(week..<14))
            d.day(F.date(week: week, day: 0, hour: 5))
            if let ret = d.state.painRecovery.painReturn {
                ceilings.append(ret.step(atWeek: PlanCalendar.weekStart(containing: F.date(week: week, day: 0), timeZone: F.tz),
                                         timeZone: F.tz, limits: d.context.painRecoveryLimits))
            }
            for day in 0..<7 { d.runAsPlanned(on: F.date(week: week, day: day)) }
            d.day(F.date(week: week + 1, day: 0, hour: 5))
            if d.state.painRecovery.painReturn == nil { ended = week + 1 }
        }
        let weeks = (firstWeek..<(ended ?? 13)).map { F.weekVolume($0, d.history) / 60 }
        print("rest stop of more than 14 days, minutes a week from week 4: \(weeks), return steps \(ceilings)")
        let end = try XCTUnwrap(ended, "the return ends: \(weeks)")
        XCTAssertGreaterThan(weeks.max() ?? 0, 0.9 * 214, "back at plan volume: \(weeks)")
        let steps = [0.65, 0.825, 1.0]
        for (k, w) in (firstWeek..<end).enumerated() {
            let v = F.weekVolume(w, d.history)
            XCTAssertLessThanOrEqual(v, F.weekVolume(w, F.weeks(0..<14)) + 1e-6, "week \(w): never above plan")
            let step = k < ceilings.count ? ceilings[k] : 3
            XCTAssertLessThanOrEqual(v, steps[min(step, 3) - 1] * 214 * 60 + 60, "week \(w): within the return's ceiling")
        }
        XCTAssertGreaterThan(F.weekVolume(firstWeek + 1, d.history), 30 * 60, "no longer held near the 20-minute test run")
        d.handFreshPlan(F.weeks(end..<14))
        d.day(F.date(week: end, day: 0, hour: 6))
        XCTAssertTrue(d.plan.contains { $0.kind.isQuality }, "quality comes back")
        assertAdaptationSound(d.outcomes)
    }

    /// The same rest-mode stop, ended within the week (14 days off or
    /// fewer): the only runs before the return are the session that stopped
    /// it and the 20-minute test run, yet the weeks after grow back to the
    /// plan as it stood before the stop, never above it, under the return's
    /// own ceilings; a week at plan volume counts, the return ends and
    /// quality comes back (SPEC 3.5 rules 6 and 7, #64, #107). Each week holds
    /// the higher of 20% more than the week before and its return step.
    /// Before #64 the 10% check
    /// measured those weeks from the test run's week.
    func testAShortRestStopGrowsBackToThePlanAndTheReturnEnds() throws {
        var d = stopped(moved: true, weeks: 0..<12)   // rest mode from Tuesday of week 0
        d.morning(week: 0, day: 2, 2)
        d.morning(week: 0, day: 3, 2)
        guard let test = d.testSession else { return XCTFail("no test run offered") }
        d.runTest(2)
        d.morningAfter(test.date, 2)
        XCTAssertNil(d.state.painStop)
        guard let r = d.state.painRecovery.painReturn else { return XCTFail("no return") }
        XCTAssertLessThanOrEqual(r.daysOff ?? 99, 14)
        for day in 4..<7 { d.runAsPlanned(on: F.date(week: 0, day: day)) }
        var ended: Int?
        for week in 1..<11 where ended == nil {
            d.handFreshPlan(F.weeks(week..<12))
            for day in 0..<7 { d.runAsPlanned(on: F.date(week: week, day: day)) }
            d.day(F.date(week: week + 1, day: 0, hour: 5))
            if d.state.painRecovery.painReturn == nil { ended = week + 1 }
        }
        let weeks = (0..<(ended ?? 11)).map { F.weekVolume($0, d.history) / 60 }
        print("short rest stop, minutes a week from week 0: \(weeks)")
        let end = try XCTUnwrap(ended, "the return ends: \(weeks)")
        XCTAssertLessThanOrEqual(end, 7, "back at plan volume within a few weeks: \(weeks)")
        XCTAssertGreaterThanOrEqual(F.weekVolume(end - 1, d.history), 0.9 * 214 * 60, "\(weeks)")
        d.handFreshPlan(F.weeks(end..<12))
        d.day(F.date(week: end, day: 0, hour: 6))
        XCTAssertTrue(d.plan.contains { $0.kind.isQuality }, "quality comes back")
        XCTAssertTrue(d.changes.contains { $0.kind == .sessionRegrown })
        for w in 1..<end {
            XCTAssertLessThanOrEqual(F.weekVolume(w, d.history), F.weekVolume(w, F.weeks(0..<12)) + 1e-6, "week \(w): never above plan")
        }
        assertAdaptationSound(d.outcomes)
    }

    /// A return week run short starts the regrowth's steps again (3.5 rules
    /// 6 and 7, owner decision Nov 21, #107): the next week holds at most the
    /// higher of 20% over what was run and the first return step (65% of the
    /// plan), never above the plan, with the return's own ceiling on top. Run
    /// short again, the same: a return repeating at plan volume never sits at
    /// 100% after a short week. The app re-plans at full volume every Monday
    /// and the runner runs 40% of every session.
    func testAReturnWeekRunShortStartsTheRegrowthAgain() {
        var d = returning(weeks: 0..<8)
        for day in 5..<7 { d.runAsPlanned(on: F.date(week: 0, day: day)) }
        d.handFreshPlan(F.weeks(1..<8))
        for day in 0..<7 { d.runAsPlanned(on: F.date(week: 1, day: day)) }
        let original = F.weekVolume(2, F.weeks(0..<8))
        XCTAssertEqual(original, 214 * 60, accuracy: 1e-6)
        var ran: [Double] = []
        var next: [Double] = []
        for week in 2..<5 {
            d.handFreshPlan(F.weeks(week..<8))
            d.day(F.date(week: week, day: 0, hour: 5))
            if week > 2 { next.append(F.weekVolume(week, d.plan + d.history)) }
            for day in 0..<7 { d.runAsPlanned(on: F.date(week: week, day: day), scale: 0.4) }
            ran.append(F.weekVolume(week, d.history))
        }
        d.handFreshPlan(F.weeks(5..<8))
        d.day(F.date(week: 5, day: 0, hour: 5))
        next.append(F.weekVolume(5, d.plan))
        print("return run at 40%: ran \(ran.map { $0 / 60 }) min, the week after planned \(next.map { $0 / 60 }) min")
        XCTAssertNotNil(d.state.painRecovery.painReturn, "weeks run short: the return goes on")
        XCTAssertGreaterThan(next[0], ran[0], "the week after the first short week grows")
        for (i, planned) in next.enumerated() {
            let bound = min(original, max(1.2 * ran[i], 0.65 * original))
            XCTAssertLessThanOrEqual(planned, bound + 1e-6, "week \(i + 3) after a week run at 40%: \(planned / 60) min, at most \(bound / 60)")
            // The week grows, unless the recovery cadence (3.5: a recovery
            // week after at most 3 build weeks) makes it a recovery week.
            XCTAssertGreaterThanOrEqual(planned, 0.8 * ran[i] - 5 * 60, "week \(i + 3): at least a recovery week after \(ran[i] / 60) min")
        }
        let last = d.outcomes.last!.regrowth
        XCTAssertEqual(last.week(PlanCalendar.weekStart(containing: F.date(week: 5, day: 0), timeZone: F.tz))?.step, 1,
                       "the steps start again after a week run short")
        XCTAssertNotNil(last.cutOriginal(PlanCalendar.weekStart(containing: F.date(week: 4, day: 0), timeZone: F.tz)),
                        "the week run short counts at the plan in the rolling check")
        assertAdaptationSound(d.outcomes)
        assertNoQuality(d)
    }

    // MARK: A stop stored in a version 2 state (review round 1)

    /// `d`'s state as a version 2 state would store it: no rule 7 state.
    func asVersion2(_ d: F.Driver) throws -> F.Driver {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(d.state)) as! [String: Any]
        json["formatVersion"] = 2
        json.removeValue(forKey: "painRecovery")
        let state = try JSONDecoder().decode(AdaptationState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(state.painRecovery, PainRecovery())
        XCTAssertNotNil(state.painStop)
        var v2 = F.Driver(plan: d.plan, history: d.history, context: d.context)
        v2.state = state
        return v2
    }

    func testAStoredMovementStopGetsItsBookkeepingAndTheStricterTest() throws {
        var d = try asVersion2(stopped(moved: true))
        d.morning(week: 0, day: 2, 2)
        XCTAssertEqual(d.state.painRecovery.frozenUsual, 2)
        XCTAssertTrue(d.state.painRecovery.stopFromMovement)
        // The rest-mode plan has no long run left: the long-run share of the level.
        XCTAssertEqual(d.state.painRecovery.preStopLongRun ?? 0, 0.35 * 214 * 60, accuracy: 1e-6)
        XCTAssertEqual(d.state.painRecovery.countFrom, d.state.painStop?.since)
        d.morning(week: 0, day: 3, 2)
        d.runTest(3)   // usual + 1 fails a movement stop's test
        XCTAssertNotNil(d.state.painStop)
        XCTAssertNil(d.state.painRecovery.test)
    }

    func testAStoredStopWithoutAMovementChangeEndsAsUsual() throws {
        var d = try asVersion2(stopped())
        d.morning(week: 0, day: 2, 2)
        XCTAssertFalse(d.state.painRecovery.stopFromMovement)
        d.morning(week: 0, day: 3, 1)
        d.runTest(3)
        d.morning(week: 0, day: 4, 2)
        XCTAssertNil(d.state.painStop)
        XCTAssertNotNil(d.state.painRecovery.painReturn)
    }

    func testAStoredRedFlagStopCountsAsAMovementStop() throws {
        var s = started(context())
        s.morning(week: 0, day: 2, 2, flags: [.lastingMovementChange])
        var d = try asVersion2(s)
        d.day(F.date(week: 0, day: 2, hour: 12))
        XCTAssertTrue(d.state.painRecovery.stopFromMovement, "a red flag may be a lasting movement change: the stricter limit")
    }

    // MARK: The return's level when the stop has none (review round 1)

    /// A stop in week `stopWeek` with no level, ended by the test run; the return's level.
    func fallbackLevel(history: [PlannedWorkout], stopWeek: Int) -> Double? {
        var d = F.Driver(plan: [], history: history, context: context())
        d.report(PainReport(date: F.date(week: stopWeek, day: 1, hour: 9), timing: .afterRun, hasPain: true, worsenedDuringRun: true))
        XCTAssertNil(d.state.painStop?.level, "no volume in the stop week, the week before or after")
        d.morning(week: stopWeek, day: 2, 2)
        d.morning(week: stopWeek, day: 3, 2)
        d.runTest(2)
        d.morningAfter(d.history.last!.date, 2)
        return d.state.painRecovery.painReturn?.level
    }

    func testAReturnWithNoKnownLevelUsesTheLatestRecentWeekUpToTheFloor() {
        let small = [F.easy("h1", week: 0, day: 1, minutes: 30), F.long("h2", week: 0, day: 5, minutes: 40)]
        XCTAssertEqual(fallbackLevel(history: small, stopWeek: 2), 70 * 60, "the latest week in the spike window")
        let big = [F.easy("h1", week: 0, day: 1, minutes: 50), F.long("h2", week: 0, day: 5, minutes: 70)]
        XCTAssertEqual(fallbackLevel(history: big, stopWeek: 2), 90 * 60, "at most the 90-minute floor")
        XCTAssertEqual(fallbackLevel(history: small, stopWeek: 6), 90 * 60, "older than 30 days: the floor")
    }

    func testAReturnWithNoHistoryHoldsWeekOneToTheFloor() {
        var d = F.Driver(plan: [], context: context())
        d.report(PainReport(date: F.date(week: 0, day: 1, hour: 9), timing: .afterRun, hasPain: true, worsenedDuringRun: true))
        d.morning(week: 0, day: 2, 2)
        d.morning(week: 0, day: 3, 2)
        d.runTest(2)
        d.morningAfter(d.history.last!.date, 2)
        XCTAssertEqual(d.state.painRecovery.painReturn?.level, 90 * 60)
        // The app hands a plan back: week 1 is held to 65% of the floor.
        var kept = F.Driver(plan: F.weeks(1..<3), history: d.history, context: d.context)
        kept.state = d.state
        kept.day(F.date(week: 1, day: 0, hour: 5))
        XCTAssertLessThanOrEqual(F.weekVolume(1, kept.plan), 0.65 * 90 * 60 + 1e-6)
        XCTAssertGreaterThan(F.weekVolume(1, kept.plan), 0)
    }

    // MARK: Invalid input

    func testInvalidInputsChangeNothing() {
        var d = stopped()
        let before = d.state
        d.report(PainReport(date: Date(timeIntervalSinceReferenceDate: .nan), timing: .nextMorning, hasPain: true, score: 0, walkingScore: 0))
        XCTAssertEqual(d.state.painRecovery, before.painRecovery)
        d.morning(week: 0, day: 2, 2, walking: 11)
        d.morning(week: 0, day: 3, 2, walking: -1)
        XCTAssertNil(d.state.painRecovery.test, "walking outside 0...10 is unknown")
        d.checkIn(11, at: F.date(week: 0, day: 3, hour: 12))
        XCTAssertNil(d.state.painRecovery.test)
        // An empty plan and history: a stop still starts, and a test is added.
        var e = F.Driver(plan: [], context: context())
        e.report(PainReport(date: F.date(week: 0, day: 1, hour: 9), timing: .afterRun, hasPain: true, worsenedDuringRun: true))
        XCTAssertNotNil(e.state.painStop)
        XCTAssertNil(e.state.painStop?.level)
        e.morning(week: 0, day: 2, 0)
        e.morning(week: 0, day: 3, 0)
        XCTAssertEqual(e.testSession?.durationSeconds, 20 * 60)
        XCTAssertEqual(e.plan.count, 1)
    }

    func testStateRoundTripsMidReturn() throws {
        let d = returning()
        let back = try JSONDecoder().decode(AdaptationState.self, from: try JSONEncoder().encode(d.state))
        XCTAssertEqual(back, d.state)
        XCTAssertNotNil(back.painRecovery.painReturn)
    }

    // MARK: Property: no state is a dead end the spec doesn't name

    private struct SplitMix {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func chance(_ p: Double) -> Bool { Double(next() % 10_000) / 10_000 < p }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    /// The invariants rule 7 keeps on every outcome.
    private func checkInvariants(_ d: F.Driver, _ note: String, file: StaticString = #filePath, line: UInt = #line) {
        let rec = d.state.painRecovery
        if rec.flag != nil { XCTAssertNotNil(d.state.painStop, "\(note): the flag is on only with a stop", file: file, line: line) }
        if rec.test != nil { XCTAssertNotNil(d.state.painStop, "\(note): a test only during a stop", file: file, line: line) }
        XCTAssertFalse(d.state.painStop != nil && rec.painReturn != nil, "\(note): a stop or a return, never both", file: file, line: line)
        if d.state.painStop != nil || rec.painReturn != nil || rec.flag != nil {
            XCTAssertNotNil(rec.frozenUsual, "\(note): usual frozen", file: file, line: line)
        }
        if d.state.painStop != nil || rec.painReturn != nil {
            XCTAssertFalse(d.plan.contains { $0.kind.isQuality }, "\(note): no quality", file: file, line: line)
        }
        if d.state.painStop?.mode == .rest {
            XCTAssertTrue(d.plan.allSatisfy { $0.kind == .rest || $0.kind == .race || $0.id == rec.test?.workoutID },
                          "\(note): rest mode", file: file, line: line)
        }
        XCTAssertEqual(d.outcomes.last?.adviseClinician ?? false, (d.outcomes.last?.suggestClinician ?? false) || rec.flag != nil,
                       file: file, line: line)
    }

    /// How a fuzz trial ended.
    enum TrialEnd: Equatable { case finished, repeatingForVolume, cannotEndStop }

    /// Seeded fuzz trials: a random stretch of `prefixDays` (runs, after-run
    /// and morning reports), then pain settles until week 14. Invariants are
    /// checked on every event; returns how each trial ended.
    func fuzzTrials(seed: UInt64, count: Int, prefixDays: Int) -> [TrialEnd] {
        var rng = SplitMix(state: seed)
        var ends: [TrialEnd] = []
        for trial in 0..<count {
            let tracks = rng.chance(0.6)
            let seed = tracks ? rng.int(6) : nil
            var d = F.Driver(plan: F.weeks(0..<14), context: context(tracksPain: tracks, seed: seed))
            for day in 0..<prefixDays {
                let w = day / 7, dd = day % 7
                if rng.chance(0.7) {
                    d.morning(week: w, day: dd, rng.chance(0.1) ? nil : rng.int(7), walking: rng.chance(0.1) ? nil : rng.int(5),
                              moved: rng.chance(0.03), flags: rng.chance(0.02) ? [.sharpPain] : [])
                    checkInvariants(d, "trial \(trial) day \(day) morning")
                }
                if let s = d.plan.first(where: { calendar.isDate($0.date, inSameDayAs: F.date(week: w, day: dd)) && $0.kind != .rest && $0.kind != .race }),
                   rng.chance(0.8) {
                    d.mornings(through: s.date)
                    if let current = d.plan.first(where: { $0.id == s.id }) {
                        d.take(AdaptationEngine.processRun(F.run(for: current), state: d.state, plan: d.plan, history: d.history,
                                                           context: d.context))
                        d.report(PainReport(date: current.date.addingTimeInterval(current.durationSeconds + 1800), timing: .afterRun,
                                            hasPain: rng.chance(0.5), worsenedDuringRun: rng.chance(0.1), changedMovement: rng.chance(0.03),
                                            score: rng.chance(0.7) ? rng.int(7) : nil, activityID: "run-\(current.id)"))
                        checkInvariants(d, "trial \(trial) day \(day) run")
                    }
                }
            }
            // Then pain settles: every morning at 0 with walking at 0, the
            // test run done and reported at 0 whenever one is offered, and
            // every other planned run done as planned and reported at 0. The
            // app re-plans the weeks ahead each Monday at full volume (F2, F3).
            for day in prefixDays..<98 {
                let w = day / 7, dd = day % 7
                if dd == 0 { d.handFreshPlan(F.weeks(w..<14)) }
                d.morning(week: w, day: dd, 0, walking: 0)
                checkInvariants(d, "trial \(trial) day \(day) settled morning")
                if let t = d.testSession, calendar.isDate(t.date, inSameDayAs: F.date(week: w, day: dd)) {
                    d.runTest(0)
                    checkInvariants(d, "trial \(trial) day \(day) test")
                } else {
                    d.runAsPlanned(on: F.date(week: w, day: dd))
                    checkInvariants(d, "trial \(trial) day \(day) settled run")
                }
            }
            d.day(F.date(week: 14, day: 0))
            let rec = d.state.painRecovery
            if let stop = d.state.painStop {
                // The one dead end the spec names: usual 4 or more at the stop's
                // start (#85 is the open question on a way out).
                XCTAssertTrue(rec.cannotEnd, "trial \(trial): stuck in a stop since \(stop.since) the spec doesn't name")
                XCTAssertGreaterThanOrEqual(rec.frozenUsual ?? 0, 4, "trial \(trial)")
                ends.append(.cannotEndStop)
            } else if let r = rec.painReturn {
                // The conservative state the review named: the return stays at
                // full plan volume while the guardrails keep a week below 90%
                // of the pre-stop reference, for instance where the spike rule
                // holds the long run back or a random week was run short and
                // the regrowth's steps start again. Every repeat is for
                // volume, not symptoms. (After more than 14 days off, the
                // weeks back are bounded by the return's own ceilings, owner
                // decision Nov 21, #107;
                // `testARestStopOfMoreThan14DaysGrowsBackUnderTheReturnsCeilings`.)
                XCTAssertEqual(r.step, PainReturnRule.planVolumeStep(), "trial \(trial)")
                XCTAssertNil(rec.flag, "trial \(trial): a flag left on")
                let repeats = d.changes.filter { $0.kind == .painReturnRepeated }
                XCTAssertFalse(repeats.isEmpty, "trial \(trial)")
                XCTAssertTrue(repeats.allSatisfy { $0.explanation.contains("planned before the stop") }, "trial \(trial): a repeat for symptoms")
                ends.append(.repeatingForVolume)
            } else {
                XCTAssertNil(rec.flag, "trial \(trial): a flag left on")
                ends.append(.finished)
            }
            checkInvariants(d, "trial \(trial) end")
        }
        return ends
    }

    /// Long random stretches (3 weeks): the default run keeps 1 trial (each
    /// takes about 30 s); the slow run has 10.
    func testFuzzNoDeadEndsAndInvariantsHold() {
        let ends = fuzzTrials(seed: 0x73, count: 1, prefixDays: 21)
        print("fuzz (21-day stretches): \(ends)")
        XCTAssertEqual(ends.count, 1)
    }

    /// Short random stretches (5 days), which #91's return ramp covers: a
    /// minimum number of returns must finish.
    func testFuzzShortStopsFinishTheirReturn() {
        let ends = fuzzTrials(seed: 0x9173, count: 2, prefixDays: 5)
        print("fuzz (5-day stretches): \(ends)")
        XCTAssertGreaterThanOrEqual(ends.filter { $0 == .finished }.count, 1, "\(ends)")
    }

    /// The rest of both fuzzes: `COACHCORE_SLOW_TESTS=1 swift test`.
    func testFuzzNoDeadEndsSlow() throws {
        guard ProcessInfo.processInfo.environment["COACHCORE_SLOW_TESTS"] == "1" else {
            throw XCTSkip("set COACHCORE_SLOW_TESTS=1 to run the long fuzz")
        }
        let long = fuzzTrials(seed: 0x7373, count: 10, prefixDays: 21)
        let short = fuzzTrials(seed: 0x917373, count: 10, prefixDays: 5)
        func count(_ ends: [TrialEnd]) -> String {
            "finished \(ends.filter { $0 == .finished }.count), repeating \(ends.filter { $0 == .repeatingForVolume }.count), cannot end \(ends.filter { $0 == .cannotEndStop }.count)"
        }
        print("fuzz slow: long \(count(long)); short \(count(short))")
        // With #64's regrowth (SPEC 3.5 rules 6 and 7), 8 of the 10 long
        // trials finish their return and the other 2 can't end a stop the
        // spec names (#85); 7 of the 10 short ones finish, 2 repeat for
        // volume and 1 can't end its stop (seeded, so the counts are fixed).
        XCTAssertGreaterThanOrEqual(short.filter { $0 == .finished }.count, 7, "\(short)")
        XCTAssertGreaterThanOrEqual(long.filter { $0 == .finished }.count, 8, "\(long)")
    }

    private var calendar: Calendar { PlanCalendar.calendar(timeZone: F.tz) }
}
