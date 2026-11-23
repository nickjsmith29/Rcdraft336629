import XCTest
@testable import CoachCore

// #154: the recovery cadence (SPEC 3.5, "a recovery week every third or
// fourth week", a coaching-convention heuristic) with the long run stuck at
// its floor (`AdaptationLimits.minimumTrimmedSeconds`). When the runs
// already done fill the lightest week of a too-long streak of build weeks
// and nothing is left to cut there but a long run at its floor, repair used
// to leave the violation in the report. It now drops that long run, as #146
// does for the weekly limits and the freeze, but only when dropping it makes
// the week a recovery week. Synthetic plans and runs only; every threshold
// is a heuristic.
final class GuardrailRepairRecoveryFloorTests: XCTestCase {
    typealias F = AdaptFixture
    private let asOf = F.date(week: 3, day: 3, hour: 6)

    /// Weeks 0 to 2: four 50-minute runs each (200 min, three build weeks).
    /// Week 3: `done` minutes already run on Monday and Tuesday.
    private func history(done: Double) -> [PlannedWorkout] {
        (0..<3).flatMap { wk in (0..<4).map { F.easy("h\(wk)-\($0)", week: wk, day: $0 * 2, minutes: 50) } }
            + [F.easy("d1", week: 3, day: 0, minutes: done / 2), F.easy("d2", week: 3, day: 1, minutes: done / 2)]
    }

    private func check(_ plan: [PlannedWorkout], _ history: [PlannedWorkout]) -> GuardrailReport {
        let c = F.context()
        return GuardrailChecker.check(history: history, planned: plan, timeZone: c.timeZone, limits: c.guardrails,
                                      freezes: [], units: c.units)
    }

    /// 150 min are already run in week 3, so with its 20-minute long run the
    /// week holds 170 min, 85% of week 2's 200: the fourth build week in a
    /// row. The long run is at its floor and is all that is left to come, so
    /// no cut can reach the 160 min (80%) a recovery week allows. Dropping it
    /// leaves 150 min, a recovery week, and the plan passes.
    func testTheRecoveryCadenceDropsTheLongRunAtItsFloor() throws {
        let plan = [F.long("l1", week: 3, day: 5, minutes: 20)]
        let before = check(plan, history(done: 150))
        XCTAssertEqual(before.violations.map(\.rule), [.recoveryWeek], "the case this issue is about")

        let r = GuardrailRepair.repair(plan: plan, history: history(done: 150), asOf: asOf, freezes: [], context: F.context())
        XCTAssertTrue(r.report.passed, "\(r.report.violations.map(\.explanation))")
        XCTAssertTrue(r.plan.isEmpty)
        XCTAssertEqual(r.changes.count, 1)
        let drop = try XCTUnwrap(r.changes.first)
        XCTAssertEqual(drop.kind, .sessionDropped)
        XCTAssertEqual(drop.workoutIDs, ["l1"])
        XCTAssertTrue(drop.rule.contains("SPEC 3.5"), drop.rule)
        XCTAssertTrue(drop.rule.contains("rule 6"), drop.rule)
        XCTAssertTrue(drop.rule.contains("F4"), drop.rule)
        XCTAssertTrue(drop.explanation.contains("recovery week every third or fourth week"), drop.explanation)
        XCTAssertTrue(drop.explanation.contains("already at the plan's 20 min floor"), drop.explanation)
        XCTAssertTrue(drop.explanation.contains("missed-day rule"), drop.explanation)
        XCTAssertEqual(drop.triggers.first?.metric, .buildWeeks)
        XCTAssertEqual(drop.triggers.first?.value, 4)
        XCTAssertTrue(drop.triggers.allSatisfy { $0.value.isFinite && !$0.detail.isEmpty })
    }

    /// With 165 min already run the week is a build week even with no long
    /// run (82.5% of 200), so dropping the long run would not fix the
    /// cadence: it stays, and the violation is left to the report as before.
    func testTheLongRunStaysWhenDroppingItCannotMakeARecoveryWeek() {
        let plan = [F.long("l1", week: 3, day: 5, minutes: 20)]
        let r = GuardrailRepair.repair(plan: plan, history: history(done: 165), asOf: asOf, freezes: [], context: F.context())
        XCTAssertEqual(r.plan, plan)
        XCTAssertTrue(r.changes.isEmpty)
        XCTAssertEqual(r.report.violations.map(\.rule), [.recoveryWeek])
    }

    /// An easy run still to come is trimmed and dropped first (3.5 rule 6's
    /// order); the long run at its floor stays when that is enough.
    func testEasyRunsGoBeforeTheLongRun() {
        let plan = [F.easy("e1", week: 3, day: 3, minutes: 20, hour: 17), F.long("l1", week: 3, day: 5, minutes: 20)]
        let r = GuardrailRepair.repair(plan: plan, history: history(done: 140), asOf: asOf, freezes: [], context: F.context())
        XCTAssertTrue(r.report.passed, "\(r.report.violations.map(\.explanation))")
        XCTAssertEqual(r.plan.map(\.id), ["l1"])
        XCTAssertEqual(r.plan.first?.durationSeconds, 20 * 60, "kept at its floor")
    }

    /// Two long runs at the floor and 150 min run (190 min, 95%): the shorter
    /// one goes first, then the other, until the week is a recovery week.
    func testTwoLongRunsAtTheFloorGoOneAtATime() {
        let plan = [F.long("a", week: 3, day: 4, minutes: 20), F.long("b", week: 3, day: 5, minutes: 20)]
        let r = GuardrailRepair.repair(plan: plan, history: history(done: 150), asOf: asOf, freezes: [], context: F.context())
        XCTAssertTrue(r.report.passed, "\(r.report.violations.map(\.explanation))")
        XCTAssertTrue(r.plan.isEmpty)
        XCTAssertEqual(r.changes.map(\.workoutIDs), [["a"], ["b"]])
        // With 140 min run (180 min, 90%) dropping one is enough.
        let one = GuardrailRepair.repair(plan: plan, history: history(done: 140), asOf: asOf, freezes: [], context: F.context())
        XCTAssertTrue(one.report.passed, "\(one.report.violations.map(\.explanation))")
        XCTAssertEqual(one.plan.map(\.id), ["b"])
    }

    // MARK: `dropLongRunAtFloor` directly

    private func drop(_ plan: [PlannedWorkout], amount: Double?) -> (plan: [PlannedWorkout], changes: [PlanChange])? {
        let v = GuardrailViolation(rule: .recoveryWeek, weekStart: F.date(week: 3, day: 0, hour: 0), measured: 4, allowed: 3,
                                   unit: .weeks, explanation: "synthetic")
        let trigger = TriggerMetric(metric: .buildWeeks, value: 4, expectedHigh: 3, unit: .weeks, detail: "synthetic")
        return GuardrailRepair.dropLongRunAtFloor(v, sessions: Array(plan.indices), plan: plan, week: F.date(week: 3, day: 0, hour: 0),
                                                  trigger: trigger, amount: amount, context: F.context())
    }

    func testARecoveryCadenceDropNeedsAnAmountTheDropsCanReach() {
        let plan = [F.long("l1", week: 3, day: 5, minutes: 20)]
        XCTAssertEqual(drop(plan, amount: 10 * 60)?.plan, [])
        XCTAssertEqual(drop(plan, amount: 20 * 60)?.plan, [], "exactly reaching it passes")
        XCTAssertNil(drop(plan, amount: 21 * 60), "can't make a recovery week")
        XCTAssertNil(drop(plan, amount: nil))
        XCTAssertNil(drop(plan, amount: .nan))
        XCTAssertNil(drop(plan, amount: .infinity))
        XCTAssertNil(drop(plan, amount: 0))
        XCTAssertNil(drop(plan, amount: -60))
        XCTAssertNil(drop([], amount: 10 * 60))
        XCTAssertNil(drop([F.long("l1", week: 3, day: 5, minutes: 21)], amount: 10 * 60), "above the floor: cut it instead")
        // Two at the floor reach 40 min together: the shorter, then the earlier, goes first.
        let two = [F.long("a", week: 3, day: 6, minutes: 20), F.long("b", week: 3, day: 4, minutes: 20)]
        XCTAssertEqual(drop(two, amount: 35 * 60)?.changes.first?.workoutIDs, ["b"])
        XCTAssertNil(drop(two, amount: 41 * 60))
    }
}
