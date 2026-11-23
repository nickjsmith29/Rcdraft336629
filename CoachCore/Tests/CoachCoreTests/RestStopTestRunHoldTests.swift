import XCTest
@testable import CoachCore

// SPEC 3.5 rule 7, #139: in a rest-mode pain stop, unplanned runs that fill
// the week must not let the stop's hold, or an F4 volume hold (section 8),
// trim or drop the test run. Rule 7 fixes its size (20 to 30 minutes, or half
// the usual easy run), it is the only way out of the stop, and
// `PainTestRun.seconds` always matches the session. Synthetic plans, runs and
// reports only.
final class RestStopTestRunHoldTests: XCTestCase {
    typealias F = AdaptFixture

    func context() -> AdaptationContext {
        AdaptationContext(zones: F.zones, timeZone: F.tz, tracksPain: true, usualPainSeed: 2)
    }

    /// Week 0 run in full (214 min, easy runs of 55 and 45 min), then a
    /// Monday 06:00 report in week 1 that stops running in rest mode (a
    /// change in how the runner moved). Usual pain is 2, the interview seed.
    func stoppedOnMonday() -> F.Driver {
        var d = F.Driver(plan: F.weeks(0..<6), context: context())
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

    /// The reviewer's probe: stopped on Monday of week 1 at a 214-minute
    /// level, two unplanned runs of `first` and `second` minutes on Monday
    /// evening and Tuesday morning, then the 2 mornings at usual that offer
    /// the 25-minute test run on Wednesday, in the same week.
    func probe(_ first: Double, _ second: Double, setUp: (inout F.Driver) -> Void = { _ in }) throws -> F.Driver {
        var d = stoppedOnMonday()
        XCTAssertEqual(d.state.painStop?.mode, .rest)
        XCTAssertEqual(try XCTUnwrap(d.state.painStop?.level), 214 * 60, accuracy: 1e-6, "week 0 as run")
        setUp(&d)
        unplanned("u1", week: 1, day: 0, minutes: first, hour: 17, into: &d)
        d.morning(week: 1, day: 1, 2)
        unplanned("u2", week: 1, day: 1, minutes: second, hour: 7, into: &d)
        XCTAssertEqual(F.weekVolume(1, d.history), (first + second) * 60)
        XCTAssertNil(d.testSession, "one morning at usual is not enough")
        d.morning(week: 1, day: 2, 2)
        return d
    }

    /// The test run is offered, at rule 7's 25 minutes (half the usual easy
    /// run of 50), matches `PainTestRun.seconds`, and no change since the
    /// offer trims, drops or rests it.
    func assertWhole(_ d: F.Driver, _ what: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let test = try XCTUnwrap(d.testSession, "\(what): offered and still planned", file: file, line: line)
        let t = try XCTUnwrap(d.state.painRecovery.test, file: file, line: line)
        let week1 = PlanCalendar.weekStart(containing: F.date(week: 1, day: 0), timeZone: F.tz)
        XCTAssertEqual(PlanCalendar.weekStart(containing: test.date, timeZone: F.tz), week1, "\(what): that week",
                       file: file, line: line)
        XCTAssertEqual(test.kind, .easy, file: file, line: line)
        XCTAssertEqual(test.durationSeconds, 25 * 60, "\(what): rule 7's size, not trimmed", file: file, line: line)
        XCTAssertEqual(t.seconds, test.durationSeconds, "\(what): PainTestRun.seconds matches the session", file: file, line: line)
        let offered = try XCTUnwrap(d.changes.lastIndex { $0.kind == .painTestRun && $0.workoutIDs.contains(test.id) },
                                    file: file, line: line)
        XCTAssertFalse(d.changes[offered...].contains { [.sessionShortened, .sessionDropped, .sessionRested].contains($0.kind)
            && $0.workoutIDs.contains(test.id) }, "\(what): no hold cuts the test run", file: file, line: line)
        XCTAssertTrue(d.plan.filter { $0.id != test.id }.allSatisfy { $0.kind == .rest || $0.kind == .race },
                      "\(what): still the only run a rest-mode stop allows", file: file, line: line)
    }

    // MARK: The stop's own hold

    /// 120 minutes of unplanned runs: the week with the test run (145 min)
    /// stays under the level, as before.
    func testUnderTheLevelTheTestRunStaysWhole() throws {
        let d = try probe(60, 60)
        try assertWhole(d, "120 min")
        XCTAssertTrue(d.outcomes.allSatisfy(\.holdsSatisfied))
        XCTAssertFalse(d.changes.contains { $0.kind == .holdShortfall })
        assertAdaptationSound(d.outcomes)
    }

    /// About 190, 195 and 200 minutes of unplanned runs: on main the stop's
    /// hold trimmed the test run to 24 minutes at 190 (with
    /// `PainTestRun.seconds` still at 25) and dropped it at 195 and 200 (the
    /// reviewer's probe saw a trim to 19 minutes, under rule 7's 20-minute
    /// minimum, at about 195). The test run is now left out of the hold's cuts: it
    /// keeps its 25 minutes, and the week above the level is reported as a
    /// shortfall that names the test run, since the runs already done are the
    /// only other volume in it.
    func assertProbeKeepsTheTestRun(_ first: Double, _ second: Double,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let what = "\(Int(first + second)) min"
        let d = try probe(first, second)
        try assertWhole(d, what, file: file, line: line)
        let last = try XCTUnwrap(d.outcomes.last, file: file, line: line)
        XCTAssertFalse(last.holdsSatisfied, "\(what): the week is above the level, so the hold isn't met", file: file, line: line)
        let shortfall = try XCTUnwrap(last.changes.first { $0.kind == .holdShortfall }, what, file: file, line: line)
        XCTAssertTrue(shortfall.explanation.contains("test run"), "\(what): \(shortfall.explanation)", file: file, line: line)
        XCTAssertTrue(shortfall.rule.contains("3.5 rule 7"), what, file: file, line: line)
        assertAdaptationSound(d.outcomes, file: file, line: line)
    }

    func testAbout190MinutesOfUnplannedRunsDoNotTrimTheTestRun() throws { try assertProbeKeepsTheTestRun(95, 95) }

    func testAbout195MinutesOfUnplannedRunsDoNotCutTheTestRun() throws { try assertProbeKeepsTheTestRun(95, 100) }

    func testAbout200MinutesOfUnplannedRunsDoNotDropTheTestRun() throws { try assertProbeKeepsTheTestRun(100, 100) }

    // MARK: Guardrail repair (3.5)

    /// From about 211 minutes of unplanned runs the week with the test run
    /// breaks the 10% weekly rise over week 0's 214 minutes, and guardrail
    /// repair, which a hold can't override, would shorten the test run (to
    /// 24 minutes at 211, to 20 at 215). It is kept whole or not at all: it
    /// is dropped, with a change that says why, offered again once the week
    /// allows, and never left shorter than `PainTestRun.seconds`. At 216
    /// repair would drop it whole, and the drop is posted the same way.
    func testGuardrailRepairNeverLeavesAShortenedTestRun() throws {
        for (first, second) in [(105.0, 106.0), (107.0, 108.0), (108.0, 108.0)] {
            let what = "\(Int(first + second)) min"
            var d = try probe(first, second)
            let last = try XCTUnwrap(d.outcomes.last, what)
            let t = try XCTUnwrap(d.state.painRecovery.test, what)
            XCTAssertNil(d.testSession, "\(what): dropped, not shortened")
            XCTAssertFalse(d.plan.contains { $0.id == t.workoutID && $0.kind != .rest }, what)
            XCTAssertFalse(last.changes.contains { $0.kind == .sessionShortened && $0.workoutIDs.contains(t.workoutID) }, what)
            let drop = try XCTUnwrap(last.changes.first { $0.kind == .sessionDropped && $0.workoutIDs.contains(t.workoutID) }, what)
            XCTAssertTrue(drop.rule.contains("3.5 rule 7"), what)
            XCTAssertTrue(drop.explanation.contains("25 min"), "\(what): \(drop.explanation)")
            if first + second < 216 {
                XCTAssertTrue(drop.explanation.contains("shorten it to"), "\(what): \(drop.explanation)")
            }
            // Never a shortened test run on any later event either: it comes
            // back whole once the week allows (the next week here).
            for day in 3..<10 {
                d.morning(week: 1 + day / 7, day: day % 7, 2)
                if let s = d.testSession, let r = d.state.painRecovery.test {
                    XCTAssertEqual(s.durationSeconds, r.seconds, "\(what), day \(day): PainTestRun.seconds matches the session")
                    XCTAssertEqual(s.durationSeconds, 25 * 60, "\(what), day \(day)")
                }
            }
            let again = try XCTUnwrap(d.testSession, "\(what): offered again")
            XCTAssertEqual(again.durationSeconds, 25 * 60, what)
            XCTAssertEqual(PlanCalendar.weekStart(containing: again.date, timeZone: F.tz),
                           PlanCalendar.weekStart(containing: F.date(week: 2, day: 0), timeZone: F.tz), "\(what): the next week")
            assertAdaptationSound(d.outcomes)
        }
    }

    // MARK: Easy-only stop: room for the test run

    /// Weeks 0 and 1 run as planned up to Monday of week 1 (214 min in week
    /// 0), an easy-only stop from that morning's report of 5, unplanned easy
    /// runs of `total / 2` minutes on Monday evening and Tuesday morning,
    /// and the 2 mornings at usual that offer the test run.
    func easyOnlyProbe(_ total: Double) -> F.Driver {
        var d = F.Driver(plan: F.weeks(0..<2), context: context())
        d.follow(until: F.date(week: 1, day: 0, hour: 5)) { _ in F.RunSpec() }
        d.morning(week: 1, day: 0, 5)
        XCTAssertEqual(d.state.painStop?.mode, .easyOnly)
        unplanned("u1", week: 1, day: 0, minutes: total / 2, hour: 17, into: &d)
        d.morning(week: 1, day: 1, 2)
        unplanned("u2", week: 1, day: 1, minutes: total / 2, hour: 7, into: &d)
        d.morning(week: 1, day: 2, 2)
        return d
    }

    /// 160 minutes of unplanned runs: the week with the 60-minute long run
    /// and the test run would break the 10% weekly rise, and dropping the
    /// long run makes room for the test run whole. It is kept at 25 minutes,
    /// matching `PainTestRun.seconds`, and the room change says which run
    /// went (the easy-only drop-whole behaviour, heuristic, SPEC 3.5 rule 7).
    func testEasyOnlyRoomThatFitsKeepsTheTestRunWhole() throws {
        let d = easyOnlyProbe(160)
        let test = try XCTUnwrap(d.testSession, "kept")
        XCTAssertEqual(test.durationSeconds, 25 * 60)
        XCTAssertEqual(d.state.painRecovery.test?.seconds, test.durationSeconds)
        let last = try XCTUnwrap(d.outcomes.last)
        let room = try XCTUnwrap(last.changes.first { $0.kind == .painTestRunRoom })
        XCTAssertEqual(room.workoutIDs, ["l1"])
        XCTAssertFalse(d.plan.contains { $0.id == "l1" }, "dropped for the test run")
        XCTAssertFalse(last.changes.contains { $0.kind == .sessionDropped && $0.workoutIDs.contains(test.id) })
        assertAdaptationSound(d.outcomes)
    }

    /// 190 and 200 minutes of unplanned runs: even with the long run
    /// dropped as room, repair would still shorten or drop the test run, so
    /// the test run alone goes. The room is given back: no `painTestRunRoom`
    /// change is posted, and at 190 the long run keeps the outcome it had on
    /// main (24 minutes, cut by repair as before), so the week keeps a
    /// planned run. Before the round-1 fix the long run was dropped as room
    /// and the test run with it, leaving the week empty. At 200 the runs
    /// already done leave no room under the volume freeze even for the long
    /// run at its 20-minute floor, so guardrail repair drops it with its own
    /// reason (#146), not as room for the test run, and the week passes.
    func testEasyOnlyRoomThatDoesNotFitIsGivenBack() throws {
        for (total, longMinutes) in [(190.0, 24.0), (200.0, nil as Double?)] {
            let what = "\(Int(total)) min"
            let d = easyOnlyProbe(total)
            let last = try XCTUnwrap(d.outcomes.last, what)
            let t = try XCTUnwrap(d.state.painRecovery.test, what)
            XCTAssertNil(d.testSession, "\(what): the test run is dropped")
            XCTAssertFalse(d.changes.contains { $0.kind == .painTestRunRoom }, "\(what): no room was kept")
            if let longMinutes {
                let long = try XCTUnwrap(d.plan.first { $0.id == "l1" }, "\(what): the long run is not lost to room")
                XCTAssertEqual(long.kind, .long, what)
                XCTAssertEqual(long.durationSeconds, longMinutes * 60, "\(what): main's outcome")
            } else {
                XCTAssertFalse(d.plan.contains { $0.id == "l1" }, "\(what): dropped by repair, never planned under the floor")
                let floorDrop = try XCTUnwrap(d.changes.first { $0.kind == .sessionDropped && $0.workoutIDs == ["l1"] }, what)
                XCTAssertTrue(floorDrop.explanation.contains("already at the plan's 20 min floor"), "\(what): \(floorDrop.explanation)")
            }
            let drop = try XCTUnwrap(last.changes.first { $0.kind == .sessionDropped && $0.workoutIDs.contains(t.workoutID) }, what)
            XCTAssertTrue(drop.rule.contains("3.5 rule 7"), what)
            XCTAssertTrue(drop.explanation.contains("25 min"), "\(what): \(drop.explanation)")
            XCTAssertTrue(last.guardrailReport.passed, "\(what): \(last.guardrailReport.violations.map(\.explanation))")
            assertAdaptationSound(d.outcomes)
        }
    }

    /// The test run kept whole still ends the stop the usual way.
    func testTheWholeTestRunStillEndsTheStop() throws {
        var d = try probe(100, 100)
        let test = try XCTUnwrap(d.testSession)
        d.runTest(2)
        d.morningAfter(test.date, 2)
        XCTAssertNil(d.state.painStop, "the passed test run ends the stop")
        XCTAssertNotNil(d.state.painRecovery.painReturn)
        assertAdaptationSound(d.outcomes)
    }

    // MARK: F4 volume holds (section 8)

    /// An F4 volume hold below the week's volume (130 min, with 120 min
    /// already run) can't cut the test run either: on main it trimmed or
    /// dropped it the same way.
    func testAnF4VolumeHoldNeverCutsTheTestRun() throws {
        let start = PlanCalendar.weekStart(containing: F.date(week: 1, day: 0), timeZone: F.tz)
        let end = PlanCalendar.weekStart(containing: F.date(week: 3, day: 0), timeZone: F.tz)
        let d = try probe(60, 60) {
            $0.state.holds = [VolumeHold(interval: DateInterval(start: start, end: end), level: 130 * 60)]
        }
        XCTAssertEqual(d.state.holds.count, 1, "the F4 hold still stands")
        try assertWhole(d, "F4 hold at 130 min")
        let shortfall = try XCTUnwrap(d.outcomes.last?.changes.first { $0.kind == .holdShortfall })
        XCTAssertTrue(shortfall.explanation.contains("test run"), shortfall.explanation)
        assertAdaptationSound(d.outcomes)
    }

    /// Directly on `enforceHolds`: with the test run the only run to come,
    /// neither an F4 hold nor the stop's hold cuts it, and the other runs of
    /// the week are still cut as before.
    func testEnforceHoldsLeavesTheTestRunOutOfItsCuts() throws {
        let monday = F.date(week: 1, day: 0, hour: 0)
        let history = [F.easy("h1", week: 1, day: 0, minutes: 100, hour: 7)]
        let test = F.easy("t1", week: 1, day: 2, minutes: 25)
        let other = F.easy("e1", week: 1, day: 4, minutes: 40)
        let week = DateInterval(start: monday, end: F.date(week: 2, day: 0, hour: 0))
        var state = AdaptationState()
        state.holds = [VolumeHold(interval: week, level: 110 * 60)]
        state.painRecovery.test = PainTestRun(workoutID: test.id, offeredAt: F.date(week: 1, day: 1, hour: 6), seconds: 25 * 60)
        var w = AdaptationEngine.Work(state: state, plan: [test, other], history: history, context: context(),
                                      asOf: F.date(week: 1, day: 1, hour: 6))
        let satisfied = w.enforceHolds(asOf: F.date(week: 1, day: 1, hour: 6))
        XCTAssertEqual(w.plan.first { $0.id == test.id }?.durationSeconds, 25 * 60, "the test run keeps its length")
        XCTAssertFalse(w.plan.contains { $0.id == other.id && $0.durationSeconds >= 40 * 60 }, "the other run is still cut")
        XCTAssertFalse(w.changes.contains { $0.workoutIDs.contains(test.id) })
        XCTAssertFalse(satisfied, "100 run + 25 test is above 110 with nothing else to cut")
        XCTAssertTrue(w.changes.contains { $0.kind == .holdShortfall && $0.explanation.contains("test run") })
        // Without a test run the same session is cut as any easy run.
        var plain = AdaptationEngine.Work(state: AdaptationState(holds: state.holds), plan: [test, other], history: history,
                                          context: context(), asOf: F.date(week: 1, day: 1, hour: 6))
        _ = plain.enforceHolds(asOf: F.date(week: 1, day: 1, hour: 6))
        XCTAssertTrue(plain.changes.contains { $0.workoutIDs.contains(test.id) }, "not a test run: cut as before")
    }
}
