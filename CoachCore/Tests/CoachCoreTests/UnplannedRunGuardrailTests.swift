import XCTest
@testable import CoachCore

// #149 item 2: a real run the plan did not ask for is volume the runner did,
// so it counts in the guardrail's weekly volume on purpose (the report says
// what was run, planned or not). These tests pin that behaviour as it is
// today. Whether an unplanned run should instead be exempt from a guardrail
// would be a guardrail rule change, which is the owner's call, not decided
// here. Synthetic plans only; every limit is a heuristic (SPEC 3.5 rules 4, 6
// and 7, section 8).
final class UnplannedRunGuardrailTests: XCTestCase {
    typealias F = AdaptFixture

    // MARK: The checker counts unplanned history

    /// Two steady weeks of 180 min (weeks 1 and 2), then week 3 planned at 180
    /// min: three easy runs of 60 min on days 4, 5 and 6 of the week.
    private func steady() -> (history: [PlannedWorkout], planned: [PlannedWorkout]) {
        let history = (1..<3).flatMap { w in
            [F.easy("h\(w)a", week: w, day: 1, minutes: 60), F.easy("h\(w)b", week: w, day: 3, minutes: 60),
             F.easy("h\(w)c", week: w, day: 5, minutes: 60)]
        }
        let planned = [F.easy("p3a", week: 3, day: 4, minutes: 60), F.easy("p3b", week: 3, day: 5, minutes: 60),
                       F.easy("p3c", week: 3, day: 6, minutes: 60)]
        return (history, planned)
    }

    func testAPlanThatKeepsTheWeekSteadyPasses() {
        let s = steady()
        let r = GuardrailChecker.check(history: s.history, planned: s.planned, timeZone: F.tz)
        XCTAssertTrue(r.passed, "\(r.violations.map(\.explanation))")
    }

    func testAnUnplannedRunCountsTowardTheWeeklyIncrease() {
        let s = steady()
        // A real 60-minute run on Monday of week 3 that no plan asked for
        // takes the week to 240 min, past 110% of the 180 before it.
        let unplanned = F.easy("unplanned", week: 3, day: 0, minutes: 60)
        let r = GuardrailChecker.check(history: s.history + [unplanned], planned: s.planned, timeZone: F.tz)
        XCTAssertFalse(r.passed)
        XCTAssertTrue(r.violations.contains { $0.rule == .weeklyIncrease }, "\(r.violations.map(\.explanation))")
    }

    // MARK: The engine, a real run on a rested day of the pain-stop return

    /// Pain that worsened on a run stops running; pain-free mornings end the
    /// stop with a test run in week 1; the mornings of week 2 (return week 1,
    /// through Sunday's 06:00) have then run, as in #148's probe.
    private func atReturnWeekOne(week1Fraction: Double) -> F.Driver {
        var limits = PainRecoveryLimits()
        limits.week1Fraction = week1Fraction
        var c = F.context(tracksPain: true)
        c.painRecoveryLimits = limits
        var d = F.Driver(plan: F.weeks(0..<4), context: c)
        d.follow(until: F.date(week: 0, day: 6, hour: 23)) { _ in F.RunSpec() }
        d.afterRun(week: 0, day: 6, 6, worsened: true, hour: 10)
        for day in 0..<7 { d.morning(week: 1, day: day, 0) }
        if d.testSession != nil { d.runTest(0) }
        for day in 0..<7 { d.morning(week: 2, day: day, 0) }
        return d
    }

    private func sunday(_ d: F.Driver) throws -> PlannedWorkout {
        let day = F.date(week: 2, day: 6)
        return try XCTUnwrap(d.plan.first { PlanCalendar.calendar(timeZone: F.tz).isDate($0.date, inSameDayAs: day) })
    }

    /// Syncs a real 30-minute run on week 2's Sunday and returns the outcome.
    private func syncRealRun(_ d: inout F.Driver) throws -> AdaptationOutcome {
        let real = F.easy("real-sunday", week: 2, day: 6, minutes: 30)
        d.take(AdaptationEngine.processRun(F.run(for: real), state: d.state, plan: d.plan, history: d.history,
                                           context: d.context))
        let o = try XCTUnwrap(d.outcomes.last)
        XCTAssertTrue(o.history.contains { $0.date == real.date }, "the run is history")
        XCTAssertGreaterThanOrEqual(F.weekVolume(2, o.history), 30 * 60 - 1e-6, "the week's volume includes it")
        return o
    }

    /// With a week 1 ceiling of 0 the return's week 1 plans no runs, so Sunday
    /// is a rest day: a real run there is unplanned volume. The hold shows it
    /// (`holdShortfall`, `holdsSatisfied` false); no guardrail fails on it.
    func testARealRunOnTheRestedSundayOfReturnWeekOnePostsAHoldShortfallButPassesTheGuardrail() throws {
        var d = atReturnWeekOne(week1Fraction: 0)
        XCTAssertEqual(try sunday(d).id, "e2b")
        XCTAssertEqual(try sunday(d).kind, .rest)
        let o = try syncRealRun(&d)
        XCTAssertTrue(o.changes.contains { $0.kind == .holdShortfall }, "\(o.changes.map(\.kind))")
        XCTAssertFalse(o.holdsSatisfied)
        XCTAssertTrue(o.guardrailReport.passed, "\(o.guardrailReport.violations.map(\.explanation))")
    }

    /// At the default ceiling Sunday is still a 45-minute easy run, and the
    /// same 30-minute run posts nothing.
    func testTheSameRunAtTheDefaultCeilingPostsNothing() throws {
        var d = atReturnWeekOne(week1Fraction: PainRecoveryLimits.default.week1Fraction)
        XCTAssertEqual(try sunday(d).id, "e2b")
        XCTAssertEqual(try sunday(d).kind, .easy)
        XCTAssertEqual(try sunday(d).durationSeconds, 45 * 60, accuracy: 1e-6)
        let o = try syncRealRun(&d)
        XCTAssertFalse(o.changes.contains { $0.kind == .holdShortfall }, "\(o.changes.map(\.kind))")
        XCTAssertTrue(o.guardrailReport.passed)
    }
}
