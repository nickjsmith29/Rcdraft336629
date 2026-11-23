import XCTest
@testable import CoachCore

// #131: repair's give-back after a long-to-easy swap (#122, #126) must not
// grow a run that already breaks a guardrail. Violation keys name the rule,
// the week and the run, not by how much, so before #131 a run stuck over the
// single-run spike rule at the floor could be given time back (the key was
// already there), and the repair loop then cut it again while the swap's
// change said the time went back. Synthetic runners and plans only; every
// threshold is a heuristic (SPEC 3.5 rules 1, 5 and 6).
final class GiveBackExistingViolationTests: XCTestCase {
    typealias F = AdaptFixture
    private let floor = PlanHeuristics.minimumEasyRunSeconds

    /// Five 15-minute runs before, so the spike rule allows 16.5 min. Week 1's
    /// 45-minute easy run is cut to the 20-minute floor and stays over the
    /// spike rule there; the 50-minute long run is spike-cut, then can't fit
    /// the long-run share above the floor and becomes a 20-minute easy run,
    /// which frees time. None of it may go back to the stuck easy run.
    private func stuckSpike() -> GuardrailRepair.Result {
        let history = (0..<5).map { F.easy("h\($0)", week: 0, day: $0, minutes: 15) }
        let plan = [F.easy("e1", week: 1, day: 2, minutes: 45), F.long("l1", week: 1, day: 6, minutes: 50)]
        return GuardrailRepair.repair(plan: plan, history: history, asOf: F.date(week: 1, day: 0, hour: 6), freezes: [],
                                      context: F.context())
    }

    func testARunStuckOverTheSpikeRuleGetsNoTimeBack() {
        let r = stuckSpike()
        let e1 = r.plan.first { $0.id == "e1" }
        XCTAssertEqual(e1?.durationSeconds, floor, "stuck at the floor, given nothing back")
        XCTAssertEqual(r.plan.first { $0.id == "l1" }?.kind, .easy)
        XCTAssertEqual(r.plan.first { $0.id == "l1" }?.durationSeconds, floor)
        // The spike on e1 is left to the report: no cut can fix it.
        XCTAssertEqual(r.report.violations.filter { $0.rule == .singleRunSpike }.compactMap(\.workoutID), ["e1"])
    }

    func testTheSwapsChangeTextStaysTrue() {
        let r = stuckSpike()
        let swaps = r.changes.filter { $0.kind == .longRunSwappedToEasy }
        XCTAssertEqual(swaps.count, 1)
        XCTAssertEqual(swaps.first?.workoutIDs, ["l1"], "no run named as given time back")
        XCTAssertFalse(swaps.first?.explanation.contains("goes back") ?? true, swaps.first?.explanation ?? "")
        // e1 is cut once, to the floor, and never cut again after a give-back.
        let e1Cuts = r.changes.filter { $0.kind != .longRunSwappedToEasy && $0.workoutIDs.contains("e1") }
        XCTAssertEqual(e1Cuts.count, 1, "\(r.changes.map(\.explanation))")
    }

    func testTheGiveBackStillGivesWhereNoViolationGrows() {
        // The same week with a run that broke nothing before the swap: the
        // easy run was cut only for the weekly rise, so it gets time back
        // (as in #126), while a stuck run in the same week doesn't.
        let history = [F.easy("h0", week: 0, day: 1, minutes: 45), F.easy("h1", week: 0, day: 4, minutes: 15)]
        let plan = [F.easy("e1", week: 1, day: 2, minutes: 40), F.long("l1", week: 1, day: 6, minutes: 40)]
        let r = GuardrailRepair.repair(plan: plan, history: history, asOf: F.date(week: 1, day: 0, hour: 6), freezes: [],
                                       context: F.context())
        XCTAssertTrue(r.report.passed, "\(r.report.violations.map(\.explanation))")
        XCTAssertEqual(r.plan.first { $0.id == "e1" }?.durationSeconds, 40 * 60)
        XCTAssertEqual(r.changes.first { $0.kind == .longRunSwappedToEasy }?.workoutIDs, ["l1", "e1"])
    }

    // MARK: The give-back on its own

    /// `giveBack` called directly on the stuck week: the run named by a spike
    /// violation is given nothing, and the plan comes back unchanged.
    func testGiveBackLeavesARunWithAViolationAsItIs() {
        let history = (0..<5).map { F.easy("h\($0)", week: 0, day: $0, minutes: 15) }
        let input = [F.easy("e1", week: 1, day: 2, minutes: 45), F.long("l1", week: 1, day: 6, minutes: 50)]
        let was = input[1].resized(toSeconds: 22 * 60)
        let swapped = was.resized(toSeconds: floor).swappedToEasy()
        let plan = [input[0].resized(toSeconds: floor), swapped]
        let week = PlanCalendar.weekStart(containing: input[0].date, timeZone: F.tz)
        let b = GuardrailRepair.giveBack(freedBy: was, swapped: swapped, week: week, plan: plan, input: input, history: history,
                                         asOf: F.date(week: 1, day: 0, hour: 6), freezes: [], context: F.context(), regrowth: .none)
        XCTAssertEqual(b.seconds, 0)
        XCTAssertEqual(b.plan, plan)
    }

    /// A later week's violation that both plans share may grow: repair reaches
    /// that week afterwards (earliest week first) and cuts it there, as before
    /// #131. Weeks 0 to 3 ran 60 min each (two 30-minute runs). Week 4's easy
    /// run was cut from 33 to 20 min, and its long run was swapped from 26 min
    /// to a 20-minute easy run, so week 4 stays a lighter week either way.
    /// Weeks 5 to 7 hold 99 min each, so the 4 weeks ending week 7 are over
    /// the rolling limit (30% over 240 min, 312 min). Growing week 4 grows
    /// that total, yet the 6 min still go back.
    func testALaterWeeksViolationThatGrowsIsNoBar() {
        let history = (0..<4).flatMap { w in [F.easy("h\(w)a", week: w, day: 1, minutes: 30), F.easy("h\(w)b", week: w, day: 4, minutes: 30)] }
        let later = (5..<8).flatMap { w in (0..<3).map { F.easy("x\(w)\($0)", week: w, day: 1 + 2 * $0, minutes: 33) } }
        let input = [F.easy("e4", week: 4, day: 2, minutes: 33), F.long("l4", week: 4, day: 6, minutes: 26)] + later
        let swapped = input[1].resized(toSeconds: floor).swappedToEasy()
        let plan = [input[0].resized(toSeconds: floor), swapped] + later
        let week = PlanCalendar.weekStart(containing: input[0].date, timeZone: F.tz)
        let week7 = PlanCalendar.weekStart(containing: F.date(week: 7, day: 0), timeZone: F.tz)
        let ctx = F.context()
        func rolling(_ p: [PlannedWorkout]) -> GuardrailViolation? {
            GuardrailChecker.check(history: history, planned: p, timeZone: F.tz, limits: ctx.guardrails, freezes: [], units: ctx.units)
                .violations.first { $0.rule == .fourWeekIncrease && $0.weekStart == week7 }
        }
        let before = GuardrailChecker.check(history: history, planned: plan, timeZone: F.tz, limits: ctx.guardrails, freezes: [],
                                            units: ctx.units).violations
        XCTAssertNotNil(rolling(plan), "week 7 is over the rolling limit: \(before.map(\.explanation))")
        XCTAssertFalse(before.contains { $0.weekStart == week }, "week 4 breaks nothing: \(before.map(\.explanation))")

        let b = GuardrailRepair.giveBack(freedBy: input[1], swapped: swapped, week: week, plan: plan, input: input, history: history,
                                         asOf: F.date(week: 4, day: 0, hour: 6), freezes: [], context: ctx, regrowth: .none)
        XCTAssertEqual(b.seconds, 6 * 60, "the 6 min go back")
        XCTAssertEqual(b.plan.first { $0.id == "e4" }?.durationSeconds, 26 * 60)
        XCTAssertGreaterThan(rolling(b.plan)?.measured ?? 0, rolling(plan)?.measured ?? .infinity, "week 7's total grew")
    }

    /// The same give-back with week 4's own easy run already over the spike
    /// rule (one 15-minute week before, so 16.5 min at most): that violation
    /// is in the give-back's own week and would grow, so nothing goes back.
    func testASameWeekViolationThatGrowsStillBars() {
        let history = (0..<5).map { F.easy("h\($0)", week: 0, day: $0, minutes: 15) }
        let input = [F.easy("e1", week: 1, day: 2, minutes: 45), F.long("l1", week: 1, day: 6, minutes: 30)]
        let swapped = input[1].resized(toSeconds: floor).swappedToEasy()
        let plan = [input[0].resized(toSeconds: floor), swapped]
        let week = PlanCalendar.weekStart(containing: input[0].date, timeZone: F.tz)
        let ctx = F.context()
        let before = GuardrailChecker.check(history: history, planned: plan, timeZone: F.tz, limits: ctx.guardrails, freezes: [],
                                            units: ctx.units).violations
        XCTAssertTrue(before.contains { $0.rule == .singleRunSpike && $0.workoutID == "e1" }, "\(before.map(\.explanation))")
        let b = GuardrailRepair.giveBack(freedBy: input[1], swapped: swapped, week: week, plan: plan, input: input, history: history,
                                         asOf: F.date(week: 1, day: 0, hour: 6), freezes: [], context: ctx, regrowth: .none)
        XCTAssertEqual(b.seconds, 0)
        XCTAssertEqual(b.plan, plan)
    }
}
