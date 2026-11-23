import XCTest
@testable import CoachCore

// #146: guardrail repair never cuts a long run below its floor
// (`AdaptationLimits.minimumTrimmedSeconds`), so when the runs already done
// fill a week, a long run at the floor used to stay planned and leave the
// week over the volume freeze or a weekly limit (SPEC 3.5 rules 2, 6 and 7).
// It is now dropped, with a plain reason, once nothing else in the week is
// left to cut. Synthetic plans and runs only; every threshold is a heuristic.
final class GuardrailRepairLongRunFloorTests: XCTestCase {
    typealias F = AdaptFixture
    private let floor = PlanHeuristics.minimumEasyRunSeconds
    private let asOf = F.date(week: 1, day: 3, hour: 6)

    /// Week 0: four 50-minute runs (200 min). Week 1: `done` minutes already
    /// run on Monday and Tuesday.
    private func history(done: Double) -> [PlannedWorkout] {
        (0..<4).map { F.easy("h\($0)", week: 0, day: $0 * 2, minutes: 50) }
            + [F.easy("d1", week: 1, day: 0, minutes: done / 2), F.easy("d2", week: 1, day: 1, minutes: done / 2)]
    }

    private var freezeWeek1: [DateInterval] {
        [DateInterval(start: F.date(week: 1, day: 0, hour: 0), end: F.date(week: 2, day: 0, hour: 0))]
    }

    private func noRunUnderTheFloor(_ r: GuardrailRepair.Result, file: StaticString = #filePath, line: UInt = #line) {
        for w in r.plan where w.kind != .rest && w.kind != .race {
            XCTAssertGreaterThanOrEqual(w.durationSeconds, floor - 1e-6, "\(w.id) planned under the floor", file: file, line: line)
        }
    }

    // MARK: The engine probe (#141's 200-minute easy-only stop)

    /// The reviewer's probe on the 2-week fixture: an easy-only stop from
    /// Monday of week 1, 200 minutes of unplanned easy runs on Monday and
    /// Tuesday, then the 2 mornings at usual that offer the test run. On
    /// main the long run stayed at its 20-minute floor and the week planned
    /// 3 h 40 min against the freeze's 3 h 34 min. Now every outcome passes
    /// the guardrails, the long run is dropped by repair with a reason once
    /// Tuesday's run fills the week, and the test run is still dropped by
    /// its own path (#141).
    func testEasyOnlyStopAt200MinutesPassesTheFreeze() throws {
        var d = F.Driver(plan: F.weeks(0..<2), context: AdaptationContext(zones: F.zones, timeZone: F.tz, tracksPain: true,
                                                                          usualPainSeed: 2))
        d.follow(until: F.date(week: 1, day: 0, hour: 5)) { _ in F.RunSpec() }
        d.morning(week: 1, day: 0, 5)
        XCTAssertEqual(d.state.painStop?.mode, .easyOnly)
        for (id, day, hour) in [("u1", 0, 17), ("u2", 1, 7)] {
            if day == 1 { d.morning(week: 1, day: 1, 2) }
            let w = F.easy(id, week: 1, day: day, minutes: 100, hour: hour)
            d.mornings(through: w.date)
            d.take(AdaptationEngine.processRun(F.run(for: w, F.RunSpec(id: "run-\(id)")), state: d.state, plan: d.plan,
                                               history: d.history, context: d.context))
        }
        d.morning(week: 1, day: 2, 2)

        assertAdaptationSound(d.outcomes)
        let last = try XCTUnwrap(d.outcomes.last)
        XCTAssertTrue(last.guardrailReport.passed, "\(last.guardrailReport.violations.map(\.explanation))")
        XCTAssertFalse(d.plan.contains { $0.id == "l1" }, "the long run at its floor is dropped")
        // Dropped once Tuesday's run fills the week, before the test run is offered.
        let drop = try XCTUnwrap(d.changes.first { $0.kind == .sessionDropped && $0.workoutIDs == ["l1"] })
        XCTAssertTrue(drop.explanation.contains("20 min"), drop.explanation)
        XCTAssertTrue(drop.explanation.contains("kept when possible"), drop.explanation)
        XCTAssertTrue(drop.explanation.contains("already at the plan's 20 min floor"), drop.explanation)
        XCTAssertTrue(drop.rule.contains("SPEC 3.5 rules 6 and 7"), drop.rule)
        XCTAssertTrue(drop.rule.contains("F4"), drop.rule)
        XCTAssertFalse(drop.rule.contains("rule 5") || drop.rule.contains("5,"), drop.rule)
        // One change per run: the same repair pass cut it to the floor, then
        // dropped it, and only the drop is posted.
        XCTAssertFalse(d.changes.contains { $0.kind == .sessionShortened && $0.workoutIDs.contains("l1") },
                       "\(d.changes.filter { $0.workoutIDs.contains("l1") }.map(\.kind))")
        XCTAssertFalse(d.changes.contains { $0.kind == .painTestRunRoom }, "not dropped as room for the test run")
        // The test run's own path (#141) is unchanged: dropped whole, never shortened.
        let t = try XCTUnwrap(d.state.painRecovery.test)
        XCTAssertNil(d.testSession)
        XCTAssertFalse(last.changes.contains { $0.kind == .sessionShortened && $0.workoutIDs.contains(t.workoutID) })
        let testDrop = try XCTUnwrap(last.changes.first { $0.kind == .sessionDropped && $0.workoutIDs.contains(t.workoutID) })
        XCTAssertTrue(testDrop.rule.contains("3.5 rule 7"))
        for o in d.outcomes {
            for w in o.plan where w.date >= (o.history.map(\.date).max() ?? .distantPast) && w.kind != .rest && w.kind != .race {
                XCTAssertGreaterThanOrEqual(w.durationSeconds, floor - 1e-6, "\(w.id) planned under the floor")
            }
        }
    }

    // MARK: Repair on its own

    /// The volume freeze: week 0 held 200 min, 190 are already run in week 1,
    /// and the 60-minute long run is cut to its 20-minute floor (210 min,
    /// still over). It is then dropped, and the week passes. The same pass
    /// cut it and dropped it, so only the drop is posted.
    func testAFreezeDropsTheLongRunAtItsFloor() throws {
        let r = GuardrailRepair.repair(plan: [F.long("l1", week: 1, day: 5, minutes: 60)], history: history(done: 190),
                                       asOf: asOf, freezes: freezeWeek1, context: F.context())
        XCTAssertTrue(r.report.passed, "\(r.report.violations.map(\.explanation))")
        XCTAssertFalse(r.plan.contains { $0.id == "l1" })
        XCTAssertFalse(r.changes.contains { $0.kind == .sessionShortened }, "cut, then dropped: only the drop is posted")
        let drop = try XCTUnwrap(r.changes.first { $0.kind == .sessionDropped && $0.workoutIDs == ["l1"] })
        XCTAssertEqual(r.changes.count, 1)
        XCTAssertTrue(drop.rule.contains("SPEC 3.5 rules 6 and 7"), drop.rule)
        XCTAssertTrue(drop.explanation.contains("frozen"), drop.explanation)
        XCTAssertEqual(drop.triggers.first?.metric, .weeklyVolume)
        XCTAssertTrue(drop.triggers.allSatisfy { $0.value.isFinite && !$0.detail.isEmpty })
        noRunUnderTheFloor(r)
    }

    /// The 10% weekly rise: 200 min in week 0 allows 220 in week 1; 205 are
    /// already run, so a long run at its 20-minute floor (225) can't stay.
    func testTheWeeklyRiseDropsTheLongRunAtItsFloor() throws {
        let r = GuardrailRepair.repair(plan: [F.long("l1", week: 1, day: 5, minutes: 20)], history: history(done: 205),
                                       asOf: asOf, freezes: [], context: F.context())
        XCTAssertTrue(r.report.passed, "\(r.report.violations.map(\.explanation))")
        XCTAssertTrue(r.plan.isEmpty)
        let drop = try XCTUnwrap(r.changes.first { $0.kind == .sessionDropped })
        XCTAssertEqual(drop.workoutIDs, ["l1"])
        XCTAssertTrue(drop.rule.contains("SPEC 3.5 rules 2 and 6"), drop.rule)
        XCTAssertTrue(drop.explanation.contains("(Heuristic, SPEC 3.5 rules 2 and 6, F4.)"), drop.explanation)
        XCTAssertFalse(r.changes.contains { $0.kind == .sessionShortened }, "never cut below the floor")
    }

    /// Easy runs go first, as before: with 175 min run, the 20-minute long
    /// run and a 30-minute easy run are over the freeze by 25 min, and
    /// trimming then dropping the easy run is enough. The long run stays.
    func testTheLongRunStaysWhenDroppingEasyRunsIsEnough() {
        let plan = [F.easy("e1", week: 1, day: 3, minutes: 30, hour: 17), F.long("l1", week: 1, day: 5, minutes: 20)]
        let r = GuardrailRepair.repair(plan: plan, history: history(done: 175), asOf: asOf, freezes: freezeWeek1,
                                       context: F.context())
        XCTAssertTrue(r.report.passed, "\(r.report.violations.map(\.explanation))")
        XCTAssertEqual(r.plan.first { $0.id == "l1" }?.durationSeconds, 20 * 60, "kept at its floor")
        XCTAssertFalse(r.plan.contains { $0.id == "e1" })
        XCTAssertFalse(r.changes.contains { $0.kind == .sessionDropped && $0.workoutIDs.contains("l1") })
    }

    /// A quality session still to come becomes an easy run of the same
    /// length first (3.5 rule 6) and is dropped as one; only then is the long
    /// run at its floor dropped.
    func testAQualitySessionIsSwappedAndDroppedBeforeTheLongRun() throws {
        let plan = [F.threshold("t1", week: 1, day: 3), F.long("l1", week: 1, day: 5, minutes: 20)]
        let r = GuardrailRepair.repair(plan: plan, history: history(done: 190), asOf: asOf, freezes: freezeWeek1,
                                       context: F.context())
        XCTAssertTrue(r.report.passed, "\(r.report.violations.map(\.explanation))")
        XCTAssertTrue(r.plan.isEmpty)
        let swap = try XCTUnwrap(r.changes.firstIndex { $0.kind == .qualitySwappedToEasy && $0.workoutIDs == ["t1"] })
        let dropT = try XCTUnwrap(r.changes.firstIndex { $0.kind == .sessionDropped && $0.workoutIDs.contains("t1") })
        let dropL = try XCTUnwrap(r.changes.firstIndex { $0.kind == .sessionDropped && $0.workoutIDs == ["l1"] })
        XCTAssertLessThan(swap, dropT)
        XCTAssertLessThan(dropT, dropL)
    }

    /// A race is never cut or dropped: the long run at its floor goes, the
    /// race stays, and what the race alone still breaks is left to the report.
    func testARaceStaysWhenTheLongRunIsDropped() {
        let race = PlannedWorkout(id: "r1", date: F.date(week: 1, day: 6, hour: 8), kind: .race, durationSeconds: 30 * 60)
        let plan = [F.long("l1", week: 1, day: 4, minutes: 20), race]
        let r = GuardrailRepair.repair(plan: plan, history: history(done: 190), asOf: asOf, freezes: freezeWeek1,
                                       context: F.context())
        XCTAssertEqual(r.plan.map(\.id), ["r1"])
        XCTAssertEqual(r.plan.first?.durationSeconds, 30 * 60)
        XCTAssertTrue(r.changes.contains { $0.kind == .sessionDropped && $0.workoutIDs == ["l1"] })
        XCTAssertFalse(r.report.passed, "the race keeps the week over the freeze, as before")
        XCTAssertTrue(r.report.violations.allSatisfy { $0.rule == .volumeFreeze })
    }

    /// A week the runs already done put over the limit on their own: the
    /// long run at its floor is dropped too, since planning it only adds.
    func testAWeekAlreadyOverOnItsOwnPlansNoLongRun() {
        let r = GuardrailRepair.repair(plan: [F.long("l1", week: 1, day: 5, minutes: 20)], history: history(done: 230),
                                       asOf: asOf, freezes: [], context: F.context())
        XCTAssertTrue(r.plan.isEmpty)
        XCTAssertTrue(r.changes.contains { $0.kind == .sessionDropped && $0.workoutIDs == ["l1"] })
    }

    /// Runs already done are never touched, and a later week is left as it is.
    func testOnlyRunsToComeInTheWeekAreDropped() {
        let plan = [F.long("l1", week: 1, day: 5, minutes: 20), F.long("l2", week: 2, day: 5, minutes: 20)]
        let r = GuardrailRepair.repair(plan: plan, history: history(done: 205), asOf: asOf, freezes: [], context: F.context())
        XCTAssertEqual(r.plan.map(\.id), ["l2"])
        XCTAssertEqual(r.plan.first?.durationSeconds, 20 * 60)
        XCTAssertFalse(r.changes.contains { $0.workoutIDs.contains { $0.hasPrefix("h") || $0.hasPrefix("d") } })
    }

    // MARK: `dropLongRunAtFloor` directly

    private func violation(_ rule: GuardrailRule) -> GuardrailViolation {
        GuardrailViolation(rule: rule, weekStart: F.date(week: 1, day: 0, hour: 0), measured: 230 * 60, allowed: 220 * 60,
                           unit: .seconds, explanation: "synthetic")
    }

    private func drop(_ rule: GuardrailRule, _ plan: [PlannedWorkout],
                      limits: AdaptationLimits = .default) -> (plan: [PlannedWorkout], changes: [PlanChange])? {
        let trigger = TriggerMetric(metric: .weeklyVolume, value: 230 * 60, expectedHigh: 220 * 60, unit: .seconds, detail: "synthetic")
        return GuardrailRepair.dropLongRunAtFloor(violation(rule), sessions: Array(plan.indices), plan: plan,
                                                  week: F.date(week: 1, day: 0, hour: 0), trigger: trigger,
                                                  context: F.context(limits: limits))
    }

    func testWithoutAnAmountOnlyTheWeeklyLimitsAndTheFreezeDropALongRun() {
        // `drop` sends no `amount`, so `.recoveryWeek` returns nil here for that reason alone.
        let plan = [F.long("l1", week: 1, day: 5, minutes: 20)]
        for rule in [GuardrailRule.weeklyIncrease, .fourWeekIncrease, .volumeFreeze] {
            XCTAssertEqual(drop(rule, plan)?.plan, [], "\(rule)")
        }
        for rule in [GuardrailRule.longRunShare, .singleRunSpike, .recoveryWeek, .qualitySessions] {
            XCTAssertNil(drop(rule, plan), "\(rule)")
        }
    }

    func testOnlyALongRunAtItsFloorIsDropped() {
        XCTAssertNil(drop(.volumeFreeze, [F.long("l1", week: 1, day: 5, minutes: 21)]), "above the floor: cut it instead")
        XCTAssertNil(drop(.volumeFreeze, [F.easy("e1", week: 1, day: 5, minutes: 20)]), "not a long run")
        XCTAssertNil(drop(.volumeFreeze, []), "empty")
        let zero = PlannedWorkout(id: "z", date: F.date(week: 1, day: 5), kind: .long, durationSeconds: 0)
        let nan = PlannedWorkout(id: "n", date: F.date(week: 1, day: 5), kind: .long, durationSeconds: .nan)
        let inf = PlannedWorkout(id: "i", date: F.date(week: 1, day: 5), kind: .long, durationSeconds: .infinity)
        XCTAssertNil(drop(.volumeFreeze, [zero, nan, inf]), "no valid length")
        // Two at the floor: the shorter, then the earlier, goes first.
        let two = [F.long("a", week: 1, day: 6, minutes: 20), F.long("b", week: 1, day: 4, minutes: 15),
                   F.long("c", week: 1, day: 3, minutes: 20)]
        XCTAssertEqual(drop(.volumeFreeze, two)?.changes.first?.workoutIDs, ["b"])
        XCTAssertEqual(drop(.volumeFreeze, Array(two.filter { $0.id != "b" }))?.changes.first?.workoutIDs, ["c"])
    }

    func testANonFiniteFloorFallsBackToTheDefault() {
        // #133/#140: a NaN, infinite or negative limit falls back to its default.
        var limits = AdaptationLimits.default
        limits.minimumTrimmedSeconds = .nan
        XCTAssertEqual(drop(.weeklyIncrease, [F.long("l1", week: 1, day: 5, minutes: 20)], limits: limits)?.plan, [])
        // A floor of 0 applies no floor: cuts can shorten the long run, so nothing is dropped here.
        limits.minimumTrimmedSeconds = 0
        XCTAssertNil(drop(.weeklyIncrease, [F.long("l1", week: 1, day: 5, minutes: 20)], limits: limits))
    }

    // MARK: One change per run

    /// A run shortened and then dropped in the same repair is named only by
    /// the drop; a shortened change that still names other runs keeps its
    /// reason with the count corrected; a swap before the cut is kept.
    func testAShortenedThenDroppedRunIsNamedOnlyByTheDrop() {
        let t = TriggerMetric(metric: .weeklyVolume, value: 2, expectedHigh: 1, unit: .seconds, detail: "synthetic")
        func change(_ kind: PlanChange.Kind, _ ids: [String], _ text: String) -> PlanChange {
            PlanChange(kind: kind, workoutIDs: ids, triggers: [t], rule: "SPEC 3.5", explanation: text)
        }
        let swap = change(.qualitySwappedToEasy, ["q"], "swap")
        let both = change(.sessionShortened, ["a", "b"], "Shortened 2 sessions in the week of X to stay inside.")
        let alone = change(.sessionShortened, ["c"], "Shortened a session in the week of X to stay inside.")
        let other = change(.sessionShortened, ["d"], "Shortened a session in the week of X to stay inside.")
        let drop = change(.sessionDropped, ["b", "c", "q"], "Dropped.")
        let out = GuardrailRepair.oneChangePerDroppedRun([swap, both, alone, other, drop])
        XCTAssertEqual(out.map(\.kind), [.qualitySwappedToEasy, .sessionShortened, .sessionShortened, .sessionDropped])
        XCTAssertEqual(out[1].workoutIDs, ["a"])
        XCTAssertEqual(out[1].explanation, "Shortened a session in the week of X to stay inside.")
        XCTAssertEqual(out[1].triggers, [t])
        XCTAssertEqual(out[2], other)
        XCTAssertEqual(out[3], drop)
        // A drop before a shortening of the same id (not a real repair order) changes nothing.
        XCTAssertEqual(GuardrailRepair.oneChangePerDroppedRun([drop, alone]), [drop, alone])
        XCTAssertEqual(GuardrailRepair.oneChangePerDroppedRun([]), [])
    }
}
