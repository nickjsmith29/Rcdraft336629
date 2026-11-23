import XCTest
@testable import CoachCore

// SPEC 3.5 rule 7, #108: in rest mode, the stop's own rest days are part of
// the stop, not a recovery week of the plan, so the test run is offered as
// soon as the 2 mornings and walking pain allow it, also in the week after
// the stop's week. Synthetic plans and reports only.
final class RestStopTestRunWeekTests: XCTestCase {
    typealias F = AdaptFixture

    func context() -> AdaptationContext {
        AdaptationContext(zones: F.zones, timeZone: F.tz, tracksPain: true, usualPainSeed: 2)
    }

    /// Week 0 run in full (214 min), then week 1 run up to `stopDay`'s 06:00
    /// report, which stops running in rest mode (a change in how the runner
    /// moved). Usual pain is 2, the interview seed.
    func stopped(stopDay: Int, weeks: Range<Int> = 0..<6) -> F.Driver {
        var d = F.Driver(plan: F.weeks(weeks), context: context())
        d.follow(until: F.date(week: 1, day: stopDay, hour: 5)) { _ in F.RunSpec() }
        d.morning(week: 1, day: stopDay, 3, moved: true)
        return d
    }

    /// Pain stays above usual each morning after the stop until day
    /// `settle` (days counted from Monday of week 1), then sits at usual,
    /// with walking pain 0. The offered test run is run on its day at usual
    /// pain, and the morning after it ends the stop. Returns the first day a
    /// test run was offered for and the day the stop ended, or nil when it
    /// didn't end by `lastDay`.
    func course(stopDay: Int, settle: Int, lastDay: Int = 27) -> (offered: Int, ended: Int)? {
        var d = stopped(stopDay: stopDay)
        XCTAssertEqual(d.state.painStop?.mode, .rest)
        let start = F.date(week: 1, day: 0, hour: 0)
        func dayIndex(_ date: Date) -> Int { Int((date.timeIntervalSince(start) / 86_400).rounded(.down)) }
        var offered: Int?
        for day in (stopDay + 1)...lastDay {
            d.morning(week: 1 + day / 7, day: day % 7, day < settle ? 3 : 2)
            if d.state.painStop == nil { return offered.map { ($0, day) } }
            guard let t = d.testSession else { continue }
            offered = offered ?? dayIndex(t.date)
            if dayIndex(t.date) == day { d.runTest(2) }
        }
        return nil
    }

    // MARK: The week after the stop's week (#108)

    /// Stopped on Thursday of week 1, pain settles on the Monday after:
    /// Monday and Tuesday at usual make Tuesday's session the test run, in
    /// the week the stop emptied (0 min as handed back). Before #108 that
    /// week read as a recovery week with a ceiling of 0, the test run was
    /// dropped and offered only on Monday of week 3, day 14 of the stop.
    func testTheTestRunIsOfferedInTheWeekAfterTheStopWeek() throws {
        var d = stopped(stopDay: 3)
        XCTAssertEqual(d.state.painStop?.mode, .rest)
        for day in 4..<7 { d.morning(week: 1, day: day, 3) }
        d.morning(week: 2, day: 0, 2)
        XCTAssertNil(d.testSession, "one morning at usual is not enough")
        XCTAssertEqual(F.weekVolume(2, d.plan), 0, "the stop emptied week 2")
        d.morning(week: 2, day: 1, 2)
        let test = try XCTUnwrap(d.testSession, "offered as soon as the 2 mornings allow it")
        XCTAssertEqual(test.id, "t2", "Tuesday's session becomes the test run")
        XCTAssertEqual(test.kind, .easy)
        XCTAssertEqual(test.durationSeconds, 25 * 60, "rule 7's test run: half the usual easy run (50 min), within 20 to 30 minutes")
        XCTAssertTrue(d.plan.filter { $0.id != test.id }.allSatisfy { $0.kind == .rest || $0.kind == .race },
                      "still the only run a rest-mode stop allows")
        XCTAssertFalse(d.changes.contains { $0.kind == .sessionDropped && $0.workoutIDs.contains("t2") })
        d.runTest(2)
        d.morningAfter(test.date, 2)
        XCTAssertNil(d.state.painStop, "the stop ends on Wednesday of week 2, day 9 after it started")
        let r = try XCTUnwrap(d.state.painRecovery.painReturn)
        XCTAssertLessThanOrEqual(r.daysOff ?? 99, 14, "6 to 14 days off: rule 4's ramp applies from week 2 of the return")
        assertAdaptationSound(d.outcomes)
    }

    /// Pain settles on the Tuesday after the stop week: Tuesday and
    /// Wednesday at usual, and the next session, Thursday's, is the test run.
    func testPainSettlingOnTheTuesdayAfterGetsTheTestThatWeek() throws {
        var d = stopped(stopDay: 4)
        for day in 5..<8 { d.morning(week: 1 + day / 7, day: day % 7, 3) }
        d.morning(week: 2, day: 1, 2)
        d.morning(week: 2, day: 2, 2)
        XCTAssertEqual(try XCTUnwrap(d.testSession).id, "e2a")
        assertAdaptationSound(d.outcomes)
    }

    /// The stop's own week emptied by the stop reads the same way: stopped
    /// on Monday (nothing run that week) or Wednesday (Tuesday's 54 min run),
    /// with 2 mornings at usual straight after, the test run comes that week.
    /// Before #108 the first waited for Monday of week 2 and the second for
    /// Monday of week 3.
    func testTheTestRunIsOfferedInTheStopWeekItself() throws {
        var mon = stopped(stopDay: 0)
        mon.morning(week: 1, day: 1, 2)
        mon.morning(week: 1, day: 2, 2)
        XCTAssertEqual(try XCTUnwrap(mon.testSession).id, "e1a")
        var wed = stopped(stopDay: 2)
        XCTAssertEqual(wed.history.map(\.id).filter { $0.hasSuffix("t1") }.count, 1, "Tuesday was run before the stop")
        wed.morning(week: 1, day: 3, 2)
        wed.morning(week: 1, day: 4, 2)
        XCTAssertEqual(try XCTUnwrap(wed.testSession).id, "l1", "Saturday's session, as an easy test run")
        XCTAssertEqual(wed.testSession?.kind, .easy)
        assertAdaptationSound(mon.outcomes + wed.outcomes)
    }

    /// On a grid of stop days and the day pain settles, the test run comes
    /// on the day the 2 mornings allow it or the next (the offer rule's own
    /// horizon), and the stop ends the morning after it. Every stop here is
    /// a rest-mode stop with no other run in it.
    func testOnAGridTheTestRunIsNeverHeldBack() throws {
        for stop in [0, 3, 6] {
            for after in [1, 4, 5, 8] {
                let settle = stop + after
                let ready = settle + 1   // the second morning at usual
                let c = try XCTUnwrap(course(stopDay: stop, settle: settle), "stop \(stop), settle \(settle): the stop ends")
                XCTAssertTrue((ready...(ready + 1)).contains(c.offered), "stop \(stop), settle \(settle): offered on day \(c.offered)")
                XCTAssertEqual(c.ended, c.offered + 1, "stop \(stop), settle \(settle)")
            }
        }
    }

    // MARK: The ceiling in rest mode

    /// In rest mode the stop's ceiling doesn't read recovery weeks from the
    /// rested plan handed back: a week the stop emptied is at the level, and
    /// since #124 so is a recovery week of the original plan (the plain
    /// level; see `RestStopCeilingTests`). In easy-only mode the plan handed
    /// in is read, as before.
    func testTheRestModeCeilingIgnoresTheRestedPlan() {
        let original = F.weeks(0..<5, easyMinutes: { $0 == 3 ? (20, 20) : (55, 45) }, longMinutes: { $0 == 3 ? 40 : 60 })
        XCTAssertEqual(F.weekVolume(3, original), 134 * 60)
        let history = original.filter { $0.date < F.date(week: 1, day: 0, hour: 0) }.map {
            PlannedWorkout(id: "run-\($0.id)", date: $0.date, kind: $0.kind, durationSeconds: $0.durationSeconds)
        }
        let rested = original.filter { $0.date >= F.date(week: 1, day: 0, hour: 0) }.map {
            PlannedWorkout(id: $0.id, date: $0.date, kind: .rest, durationSeconds: 0)
        }
        let level = 214.0 * 60
        func work(_ mode: PainStopMode) -> AdaptationEngine.Work {
            var state = AdaptationState()
            state.planSnapshot = PlanSnapshot(sessions: original, returned: PlanSnapshot.returned(rested))
            state.painStop = PainStop(since: F.date(week: 1, day: 0, hour: 6), mode: mode, triggers: [.changedMovement],
                                      lastTriggered: F.date(week: 1, day: 0, hour: 6), level: level)
            return AdaptationEngine.Work(state: state, plan: rested, history: history, context: context(),
                                         asOf: F.date(week: 1, day: 1, hour: 6))
        }
        func week(_ w: Int) -> Date { PlanCalendar.weekStart(containing: F.date(week: w, day: 0), timeZone: F.tz) }
        let rest = work(.rest)
        XCTAssertEqual(rest.state.planSnapshot.sessions, original, "the rested plan handed back keeps the snapshot")
        XCTAssertEqual(rest.stopCeiling(week(1), level), level, accuracy: 1e-6, "the stop's week, emptied by the stop")
        XCTAssertEqual(rest.stopCeiling(week(2), level), level, accuracy: 1e-6, "the week after, emptied by the stop")
        XCTAssertEqual(rest.stopCeiling(week(3), level), level, accuracy: 1e-6, "the original plan's recovery week: the plain level (#124)")
        XCTAssertEqual(rest.stopCeiling(week(4), level), level, accuracy: 1e-6)
        XCTAssertEqual(rest.stopCeiling(week(9), level), level, accuracy: 1e-6, "past the plan: unknown, the level")
        // Easy-only: the plan handed in, unchanged. (A rested plan in
        // easy-only mode is only a probe of that reading.)
        let easy = work(.easyOnly)
        XCTAssertEqual(easy.stopCeiling(week(1), level), 0, accuracy: 1e-6, "the handed-in plan as before")
        XCTAssertEqual(easy.stopCeiling(week(2), level), level, accuracy: 1e-6, "the week before is 0: no ratio")
    }
}
