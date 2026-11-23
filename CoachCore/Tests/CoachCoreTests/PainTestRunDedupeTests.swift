import XCTest
@testable import CoachCore

// #144 (from the #141 reviews, #139): while a week can't hold the pain test
// run, every engine event offered it again (`manageTestRun`) and repair
// dropped it again (`repairKeepingTestRun`), posting a `painTestRun` offer and
// a `sessionDropped` change each time. The pair is now posted once per such
// week, saved in `PainRecovery.reportedTestRunDropWeek` like
// `reportedHoldShortfalls`. When the test run is offered is not changed (SPEC
// 3.5 rule 7), so the plan is the same as before: only the repeats go.
// Synthetic plans, runs and reports only.
final class PainTestRunDedupeTests: XCTestCase {
    typealias F = AdaptFixture

    /// A rest-mode stop in week 1 with 214 minutes of unplanned runs on
    /// Monday and Tuesday and the 2 mornings at usual that offer the test run,
    /// so week 1 can't hold it (as in `PainTestRunDropTriggerTests`).
    private func fullWeek() -> F.Driver {
        var d = F.Driver(plan: F.weeks(0..<6), context: AdaptationContext(zones: F.zones, timeZone: F.tz, tracksPain: true,
                                                                          usualPainSeed: 2))
        d.follow(until: F.date(week: 1, day: 0, hour: 5)) { _ in F.RunSpec() }
        d.morning(week: 1, day: 0, 3, moved: true)
        XCTAssertEqual(d.state.painStop?.mode, .rest)
        let total = 214.0
        for (id, day, minutes, hour) in [("u1", 0, total / 2, 17), ("u2", 1, total - total / 2, 7)] {
            if day == 1 { d.morning(week: 1, day: 1, 2) }
            let w = F.easy(id, week: 1, day: day, minutes: minutes, hour: hour)
            d.mornings(through: w.date)
            d.take(AdaptationEngine.processRun(F.run(for: w, F.RunSpec(id: "run-\(id)")), state: d.state, plan: d.plan,
                                               history: d.history, context: d.context))
        }
        d.morning(week: 1, day: 2, 2)
        return d
    }

    private func offers(_ o: [AdaptationOutcome]) -> [PlanChange] { o.flatMap(\.changes).filter { $0.kind == .painTestRun } }
    private func testDrops(_ o: [AdaptationOutcome]) -> [PlanChange] {
        o.flatMap(\.changes).filter { $0.kind == .sessionDropped && $0.rule.contains("rule 7") && $0.explanation.hasPrefix("The test run on") }
    }

    /// Two, then three, further events in the full week post no second pair,
    /// and the plan is what repeating the offer and drop would leave.
    func testRepeatedEventsInAFullWeekPostOnePair() throws {
        for extra in [1, 2, 3] {
            var d = fullWeek()
            let first = d.outcomes.count
            XCTAssertEqual(offers(d.outcomes).count, 1, "the week's first events post one offer")
            XCTAssertEqual(testDrops(d.outcomes).count, 1)
            let week1 = PlanCalendar.weekStart(containing: F.date(week: 1, day: 0), timeZone: F.tz)
            XCTAssertEqual(d.state.painRecovery.reportedTestRunDropWeek, week1)
            for k in 0..<extra { d.day(F.date(week: 1, day: 2, hour: 8 + k)) }
            XCTAssertEqual(d.outcomes.count, first + extra)
            XCTAssertEqual(offers(d.outcomes).count, 1, "\(extra) more events")
            XCTAssertEqual(testDrops(d.outcomes).count, 1, "\(extra) more events")
            // The offer is still made on each event (the way out is not delayed): the saved test run stands.
            XCTAssertNotNil(d.state.painRecovery.test)
            XCTAssertEqual(d.state.painRecovery.reportedTestRunDropWeek, week1)
            assertAdaptationSound(d.outcomes)
        }
    }

    /// The plan is the same with or without the saved week: clear it before
    /// an event and the plan and state match, only the repeated records differ.
    func testPlanIsTheSameAsWithoutTheDedupe() throws {
        let base = fullWeek()
        var d = base
        var fresh = base
        fresh.state.painRecovery.reportedTestRunDropWeek = nil
        let n = base.outcomes.count
        let date = F.date(week: 1, day: 3)
        d.day(date)
        fresh.day(date)
        XCTAssertEqual(d.plan, fresh.plan)
        XCTAssertEqual(d.state.painRecovery.test, fresh.state.painRecovery.test)
        let kinds: Set<PlanChange.Kind> = [.painTestRun, .sessionDropped]
        XCTAssertTrue(d.outcomes[n...].flatMap(\.changes).filter { kinds.contains($0.kind) }.isEmpty)
        XCTAssertEqual(fresh.outcomes[n...].flatMap(\.changes).filter { kinds.contains($0.kind) }.map(\.kind),
                       [.painTestRun, .sessionDropped])
    }

    /// A week that can hold the test run still gets it offered: the offer for
    /// the following week (made on Sunday, as on main) is posted, with no
    /// drop, and the saved week is cleared.
    func testTheFollowingWeekStillGetsTheOffer() throws {
        var d = fullWeek()
        for day in 3...5 { d.day(F.date(week: 1, day: day)) }
        XCTAssertEqual(offers(d.outcomes).count, 1, "full week: one offer so far")
        let before = d.outcomes.count
        d.day(F.date(week: 1, day: 6))
        let later = Array(d.outcomes[before...])
        XCTAssertEqual(offers(later).count, 1)
        XCTAssertTrue(testDrops(later).isEmpty)
        XCTAssertNil(d.state.painRecovery.reportedTestRunDropWeek)
        let t = try XCTUnwrap(d.state.painRecovery.test)
        let planned = try XCTUnwrap(d.plan.first { $0.id == t.workoutID })
        let week2 = PlanCalendar.weekStart(containing: F.date(week: 2, day: 0), timeZone: F.tz)
        XCTAssertEqual(PlanCalendar.weekStart(containing: planned.date, timeZone: F.tz), week2)
        XCTAssertEqual(planned.durationSeconds, t.seconds, accuracy: 1e-6)
        assertAdaptationSound(d.outcomes)
    }

    /// The saved week survives encoding, and an older state decodes without it.
    func testSavedWeekIsCoded() throws {
        var s = PainRecovery()
        s.reportedTestRunDropWeek = Date(timeIntervalSince1970: 86_400 * 100)
        let back = try JSONDecoder().decode(PainRecovery.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        XCTAssertNil(try JSONDecoder().decode(PainRecovery.self, from: Data("{}".utf8)).reportedTestRunDropWeek)
    }
}
