import XCTest
@testable import CoachCore

// SPEC 3.5 rule 7, #124 (follow-ups from #123): a rest-mode stop's weekly
// ceiling is the plain pre-stop level, so it can't trim or drop the test run
// in a recovery week of the original plan, and an unplanned run logged while
// stopped is not a hold shortfall. Synthetic plans, runs and reports only.
final class RestStopCeilingTests: XCTestCase {
    typealias F = AdaptFixture

    func context() -> AdaptationContext {
        AdaptationContext(zones: F.zones, timeZone: F.tz, tracksPain: true, usualPainSeed: 2)
    }

    /// Week 0 run in full (214 min, easy runs of 55 and 45 min), then a
    /// Monday 06:00 report in week 1 that stops running in rest mode (a
    /// change in how the runner moved). Usual pain is 2, the interview seed.
    func stoppedOnMonday(_ plan: [PlannedWorkout]) -> F.Driver {
        var d = F.Driver(plan: plan, context: context())
        d.follow(until: F.date(week: 1, day: 0, hour: 5)) { _ in F.RunSpec() }
        d.morning(week: 1, day: 0, 3, moved: true)
        return d
    }

    /// An easy run the plan doesn't have, logged at `hour` of `week`/`day`.
    func unplanned(_ id: String, week: Int, day: Int, minutes: Double, hour: Int, into d: inout F.Driver) {
        let w = F.easy(id, week: week, day: day, minutes: minutes, hour: hour)
        d.mornings(through: w.date)
        d.take(AdaptationEngine.processRun(F.run(for: w, F.RunSpec(id: "run-\(id)")), state: d.state, plan: d.plan,
                                           history: d.history, context: d.context))
    }

    // MARK: Recovery week of the original plan

    /// Week 1 of the original plan is a recovery week (134 min after 214,
    /// about 63%). The runner is stopped on its Monday and logs two
    /// unplanned 60-minute runs before pain settles, then gets the test run
    /// that week. Reading the original plan's recovery-week share (134 min)
    /// would leave 14 min for it, under rule 7's 20 to 30 minutes; the plain
    /// level (214 min) keeps it at half the usual easy run, 25 minutes.
    func testTheTestRunKeepsItsLengthInARecoveryWeekOfTheOriginalPlan() throws {
        let original = F.weeks(0..<6, easyMinutes: { $0 == 1 ? (20, 20) : (55, 45) }, longMinutes: { $0 == 1 ? 40 : 60 })
        XCTAssertEqual(F.weekVolume(0, original), 214 * 60)
        XCTAssertEqual(F.weekVolume(1, original), 134 * 60, "a recovery week: at most 80% of the week before")
        var d = stoppedOnMonday(original)
        XCTAssertEqual(d.state.painStop?.mode, .rest)
        XCTAssertEqual(try XCTUnwrap(d.state.painStop?.level), 214 * 60, accuracy: 1e-6, "week 0 as run")
        unplanned("u1", week: 1, day: 0, minutes: 60, hour: 17, into: &d)
        d.morning(week: 1, day: 1, 2)
        unplanned("u2", week: 1, day: 1, minutes: 60, hour: 7, into: &d)
        XCTAssertEqual(F.weekVolume(1, d.history), 120 * 60)
        XCTAssertNil(d.testSession, "one morning at usual is not enough")
        d.morning(week: 1, day: 2, 2)
        let test = try XCTUnwrap(d.testSession, "offered once the 2 mornings allow it")
        let week1 = PlanCalendar.weekStart(containing: F.date(week: 1, day: 0), timeZone: F.tz)
        XCTAssertEqual(PlanCalendar.weekStart(containing: test.date, timeZone: F.tz), week1, "in the original plan's recovery week")
        XCTAssertEqual(test.kind, .easy)
        XCTAssertEqual(test.durationSeconds, 25 * 60, "rule 7's test run: half the usual easy run (50 min), within 20 to 30 minutes")
        let offered = try XCTUnwrap(d.changes.lastIndex { $0.kind == .painTestRun && $0.workoutIDs.contains(test.id) })
        XCTAssertFalse(d.changes[offered...].contains { [.sessionShortened, .sessionDropped, .sessionRested].contains($0.kind)
            && $0.workoutIDs.contains(test.id) }, "the stop's hold neither trims nor drops it")
        XCTAssertTrue(d.plan.filter { $0.id != test.id }.allSatisfy { $0.kind == .rest || $0.kind == .race },
                      "still the only run a rest-mode stop allows")
        XCTAssertTrue(d.outcomes.allSatisfy(\.holdsSatisfied))
        XCTAssertFalse(d.changes.contains { $0.kind == .holdShortfall })
        d.runTest(2)
        d.morningAfter(test.date, 2)
        XCTAssertNil(d.state.painStop, "the passed test run ends the stop")
        assertAdaptationSound(d.outcomes)
    }

    /// The ceiling itself: in rest mode it is the level in every week, a
    /// recovery week of the original plan included; easy-only mode still
    /// keeps the recovery-week share of the plan handed in.
    func testTheRestModeCeilingIsThePlainLevel() {
        let original = F.weeks(0..<5, easyMinutes: { $0 == 3 ? (20, 20) : (55, 45) }, longMinutes: { $0 == 3 ? 40 : 60 })
        let monday = F.date(week: 1, day: 0, hour: 0)
        let history = original.filter { $0.date < monday }.map {
            PlannedWorkout(id: "run-\($0.id)", date: $0.date, kind: $0.kind, durationSeconds: $0.durationSeconds)
        }
        let rested = original.filter { $0.date >= monday }.map {
            PlannedWorkout(id: $0.id, date: $0.date, kind: .rest, durationSeconds: 0)
        }
        let level = 214.0 * 60
        func work(_ mode: PainStopMode, plan: [PlannedWorkout]) -> AdaptationEngine.Work {
            var state = AdaptationState()
            state.planSnapshot = PlanSnapshot(sessions: original, returned: PlanSnapshot.returned(rested))
            state.painStop = PainStop(since: F.date(week: 1, day: 0, hour: 6), mode: mode, triggers: [.changedMovement],
                                      lastTriggered: F.date(week: 1, day: 0, hour: 6), level: level)
            return AdaptationEngine.Work(state: state, plan: plan, history: history, context: context(),
                                         asOf: F.date(week: 1, day: 1, hour: 6))
        }
        func week(_ w: Int) -> Date { PlanCalendar.weekStart(containing: F.date(week: w, day: 0), timeZone: F.tz) }
        let rest = work(.rest, plan: rested)
        for w in [1, 2, 3, 4, 9] {
            XCTAssertEqual(rest.stopCeiling(week(w), level), level, accuracy: 1e-6, "week \(w)")
        }
        XCTAssertTrue(rest.stopCeiling(week(3), .nan).isNaN, "the level as given: nothing is read from the plan")
        let easy = work(.easyOnly, plan: original.filter { $0.date >= monday })
        XCTAssertEqual(easy.stopCeiling(week(3), level), level * 134 / 214, accuracy: 1e-6,
                       "easy-only: the recovery week of the plan handed in keeps its share")
        XCTAssertEqual(easy.stopCeiling(week(2), level), level, accuracy: 1e-6)
    }

    // MARK: Unplanned runs during a rest stop (#123)

    /// An unplanned run logged while a rest-mode stop stands is history the
    /// hold can't undo, but it stays under the pre-stop level, so no
    /// `holdShortfall` is posted and `holdsSatisfied` stays true. Before #123
    /// the emptied week read as a recovery week with a ceiling of 0, and the
    /// run was reported as a shortfall. Pinned as deliberate (#124).
    func testAnUnplannedRunDuringARestStopIsNotAHoldShortfall() throws {
        var d = stoppedOnMonday(F.weeks(0..<6))
        XCTAssertEqual(d.state.painStop?.mode, .rest)
        let stopped = d.outcomes.count
        d.morning(week: 1, day: 1, 3)
        unplanned("u1", week: 1, day: 1, minutes: 40, hour: 7, into: &d)
        let ran = try XCTUnwrap(d.outcomes.last)
        XCTAssertTrue(ran.history.contains { $0.id == "run-u1" && $0.kind == .easy }, "logged as an unplanned easy run")
        XCTAssertTrue(ran.holdsSatisfied)
        XCTAssertFalse(ran.changes.contains { $0.kind == .holdShortfall })
        XCTAssertEqual(d.state.painStop?.mode, .rest, "an unplanned run doesn't end the stop")
        // The mornings after it see the same.
        d.morning(week: 1, day: 2, 3)
        unplanned("u2", week: 1, day: 3, minutes: 40, hour: 7, into: &d)
        d.morning(week: 1, day: 4, 3)
        d.day(F.date(week: 2, day: 1, hour: 6))
        let since = d.outcomes[stopped...]
        XCTAssertTrue(since.allSatisfy(\.holdsSatisfied))
        XCTAssertFalse(since.contains { $0.changes.contains { $0.kind == .holdShortfall } })
        XCTAssertTrue(d.state.reportedHoldShortfalls.isEmpty)
        XCTAssertTrue(d.plan.allSatisfy { $0.kind == .rest || $0.kind == .race }, "the plan stays rested")
        assertAdaptationSound(d.outcomes)
    }
}
