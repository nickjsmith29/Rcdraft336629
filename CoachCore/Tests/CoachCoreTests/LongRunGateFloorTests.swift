import XCTest
@testable import CoachCore

// #159 (owner's decision, SPEC 3.3): when the length the long-run gate allows
// is under the 20-minute easy-run floor (`AdaptationLimits.minimumTrimmedSeconds`,
// by default `PlanHeuristics.minimumEasyRunSeconds`), the next long run is held
// at that length, never longer than its plan, whether it is planned under, at
// or above the floor. It is not raised to the floor (#121) or rested (#132).
// The 3.5 guardrails still repair the plan after the gate. Synthetic records
// and plans only; no real runner is here.
final class LongRunGateFloorTests: XCTestCase {
    typealias F = AdaptFixture
    private let floor = PlanHeuristics.minimumEasyRunSeconds

    /// Two long-run records before week 0, each planned and run at `minutes`.
    /// `qualifying` sets decoupling under the gate's 5% (the gate opens) or
    /// over it (the gate holds at the recent level).
    private func records(minutes: Double, qualifying: Bool) -> [LongRunRecord] {
        [-2, -1].map { w in
            LongRunRecord(activityID: "old-l\(-w)", date: F.date(week: w, day: 5), plannedSeconds: minutes * 60,
                          movingSeconds: minutes * 60, decouplingPercent: qualifying ? 2 : 8)
        }
    }

    /// The morning call on Monday of week 0, with `records` in saved state and
    /// a plan of Tue threshold, Thu easy, Sat long (`long` min), Sun easy.
    private func monday(records: [LongRunRecord], long: Double = 50, plan: [PlannedWorkout]? = nil,
                        context: AdaptationContext = F.context()) -> F.Driver {
        var d = F.Driver(plan: plan ?? F.weeks(0..<2, longMinutes: { _ in long }), context: context)
        d.state.longRuns = records
        d.day(F.date(week: 0, day: 0, hour: 5))
        return d
    }

    private func l0(_ d: F.Driver) -> PlannedWorkout? { d.plan.first { $0.id == "l0" } }
    private func gateChanges(_ d: F.Driver) -> [PlanChange] {
        d.changes.filter { $0.workoutIDs == ["l0"] && $0.rule == "SPEC 3.3, section 8" }
    }

    // MARK: Under the floor

    func testAHeldGateUnderTheFloorHoldsTheLongRunAtTheAllowance() throws {
        // Recent long runs of 18 min that didn't qualify: the 50-minute long
        // run is held at 18 min, under the floor, still a long run.
        let d = monday(records: records(minutes: 18, qualifying: false))
        let w = try XCTUnwrap(l0(d))
        XCTAssertEqual(w.kind, .long, "still a long run, so the next one is recorded")
        XCTAssertEqual(w.durationSeconds, 18 * 60)
        XCTAssertEqual(w.prescription?.durationSeconds, 18 * 60)
        let held = gateChanges(d)
        XCTAssertEqual(held.map(\.kind), [.longRunHeld])
        let c = try XCTUnwrap(held.first)
        XCTAssertTrue(c.explanation.contains("stays at 18 min instead of 50 min"), c.explanation)
        XCTAssertTrue(c.explanation.contains("under the 20 min floor"), c.explanation)
        XCTAssertTrue(c.explanation.contains("SPEC 3.3, section 8; owner's decision, #159"), c.explanation)
        XCTAssertFalse(c.explanation.contains("shortest run the plan schedules"), c.explanation)
        let t = try XCTUnwrap(c.triggers.first { $0.metric == .longRunDuration && $0.sourceID == "l0" })
        XCTAssertEqual(t.value, 50 * 60)
        XCTAssertEqual(t.expectedHigh, 18 * 60, "the debrief reads the allowed time from here")
        XCTAssertEqual(c.triggers.filter { $0.metric == .decoupling }.map(\.sourceID), ["old-l2", "old-l1"])
        assertAdaptationSound(d.outcomes)
    }

    func testAnOpenGateWhoseStepEndsUnderTheFloorHoldsAtTheAllowance() throws {
        // Qualifying 6-minute long runs: the step allows 16 min, under the floor.
        let d = monday(records: records(minutes: 6, qualifying: true))
        let w = try XCTUnwrap(l0(d))
        XCTAssertEqual(w.kind, .long)
        XCTAssertEqual(w.durationSeconds, 16 * 60)
        let c = try XCTUnwrap(gateChanges(d).first)
        XCTAssertEqual(c.kind, .longRunHeld)
        XCTAssertTrue(c.explanation.contains("the step is limited to 10 min, so it is held at 16 min, under the 20 min floor"), c.explanation)
        assertAdaptationSound(d.outcomes)
    }

    func testARunPlannedAtOrAboveTheFloorIsHeldAtTheAllowanceAsALongRun() throws {
        // Planned at 25 min (above the floor), allowance 18 min.
        let d = monday(records: records(minutes: 18, qualifying: false), long: 25)
        let w = try XCTUnwrap(l0(d))
        XCTAssertEqual(w.kind, .long)
        XCTAssertEqual(w.durationSeconds, 18 * 60)
        XCTAssertEqual(gateChanges(d).map(\.kind), [.longRunHeld])
        // Planned exactly at the floor.
        let e = monday(records: records(minutes: 18, qualifying: false), long: 20)
        XCTAssertEqual(l0(e)?.kind, .long)
        XCTAssertEqual(l0(e)?.durationSeconds, 18 * 60)
        assertAdaptationSound(d.outcomes)
        assertAdaptationSound(e.outcomes)
    }

    func testAVerySmallAllowanceHoldsTheRunAtIt() throws {
        // Records of 3 min: the allowance is 3 min (> 0), a very small hold.
        let d = monday(records: records(minutes: 3, qualifying: false))
        let w = try XCTUnwrap(l0(d))
        XCTAssertEqual(w.kind, .long)
        XCTAssertEqual(w.durationSeconds, 3 * 60)
        XCTAssertEqual(gateChanges(d).map(\.kind), [.longRunHeld])
        // No record level (allowance 0) leaves the plan alone.
        let none = monday(records: records(minutes: 0, qualifying: false))
        XCTAssertTrue(gateChanges(none).isEmpty)
    }

    func testGuardrailRepairStillRunsAfterTheHold() throws {
        // Held at 18 min, the long run would be 18 of 38 min in the week,
        // over the 35% long-run share (3.5 rule 5), so repair still acts on
        // it after the gate.
        let plan = [F.easy("e0a", week: 0, day: 1, minutes: 20), F.long("l0", week: 0, day: 5, minutes: 50)]
        let d = monday(records: records(minutes: 18, qualifying: false), plan: plan)
        let day = d.changes.filter { $0.workoutIDs.first == "l0" }
        XCTAssertEqual(day.first?.kind, .longRunHeld)
        XCTAssertEqual(day.map(\.kind), [.longRunHeld, .longRunSwappedToEasy])
        XCTAssertEqual(l0(d)?.kind, .easy)
        XCTAssertEqual(l0(d)?.durationSeconds, 18 * 60)
        assertAdaptationSound(d.outcomes)
    }

    func testTheHoldAtTheFloorIsSaidOnce() {
        var d = monday(records: records(minutes: 18, qualifying: false))
        d.day(F.date(week: 0, day: 1, hour: 5))
        d.day(F.date(week: 0, day: 2, hour: 5))
        XCTAssertEqual(l0(d)?.durationSeconds, 18 * 60)
        XCTAssertEqual(gateChanges(d).count, 1, "the same plan handed back says nothing new")
    }

    func testALongRunPlannedUnderTheFloorIsHeldAtTheAllowanceNotRested() throws {
        // A handed-in plan's 19-minute long run that the gate (15 min) cuts:
        // held at 15 min as a long run, not rested (#159).
        let d = monday(records: records(minutes: 15, qualifying: false), long: 19)
        let w = try XCTUnwrap(l0(d))
        XCTAssertEqual(w.kind, .long)
        XCTAssertEqual(w.durationSeconds, 15 * 60)
        let c = try XCTUnwrap(gateChanges(d).first)
        XCTAssertEqual(c.kind, .longRunHeld)
        XCTAssertTrue(c.explanation.contains("stays at 15 min instead of 19 min"), c.explanation)
        XCTAssertFalse(d.changes.contains { $0.kind == .sessionRested })
        assertAdaptationSound(d.outcomes)
    }

    func testAHoldAtTheAllowanceNeverRestsEvenWhereTheFloorWouldBreakTheSpikeRule() throws {
        // The records' 18-min long runs are in history too, so the spike
        // reference is 18 min; a run at the 20-min floor would be over the
        // plan's other 15-min run's share, but the gate holds at 18 min and
        // does not rest it (#159). The share then makes it an easy run.
        let history = [-2, -1].map { F.long("old-l\(-$0)", week: $0, day: 5, minutes: 18) }
        let plan = [F.easy("e0a", week: 0, day: 1, minutes: 15), F.long("l0", week: 0, day: 5, minutes: 40)]
        var d = F.Driver(plan: plan, history: history, context: F.context())
        d.state.longRuns = records(minutes: 18, qualifying: false)
        d.day(F.date(week: 0, day: 0, hour: 5))
        XCTAssertEqual(gateChanges(d).map(\.kind), [.longRunHeld])
        XCTAssertEqual(l0(d)?.kind, .easy)
        XCTAssertEqual(l0(d)?.durationSeconds, 18 * 60)
        assertAdaptationSound(d.outcomes)
    }

    // MARK: At or above the floor, unchanged

    func testAGateAtOrAboveTheFloorIsUnchanged() throws {
        // A held gate at 25 min, and an open one at 18 + 10 = 28 min: held
        // there as before, with the same words.
        let held = monday(records: records(minutes: 25, qualifying: false))
        XCTAssertEqual(l0(held)?.durationSeconds, 25 * 60)
        let c = try XCTUnwrap(gateChanges(held).first)
        XCTAssertEqual(c.kind, .longRunHeld)
        XCTAssertTrue(c.explanation.hasPrefix("The long run on"), c.explanation)
        XCTAssertTrue(c.explanation.contains("stays at 25 min instead of 50 min: your last 2 long runs were not all completed"), c.explanation)
        XCTAssertTrue(c.explanation.hasSuffix("(SPEC 3.3.)"), c.explanation)
        XCTAssertEqual(c.triggers.first?.detail, "next long run planned at 50 min; at most 25 min allowed")
        assertAdaptationSound(held.outcomes)

        let open = monday(records: records(minutes: 18, qualifying: true))
        XCTAssertEqual(l0(open)?.durationSeconds, 28 * 60)
        XCTAssertEqual(gateChanges(open).first?.kind, .longRunHeld)
        XCTAssertTrue(gateChanges(open).first?.explanation.hasSuffix("(SPEC 3.3.)") ?? false)

        // A gate exactly at the floor holds at the floor, as before.
        let atFloor = monday(records: records(minutes: 20, qualifying: false))
        XCTAssertEqual(l0(atFloor)?.durationSeconds, floor)
        XCTAssertTrue(gateChanges(atFloor).first?.explanation.hasSuffix("(SPEC 3.3.)") ?? false)
    }

    func testALongRunWithinTheGateIsLeftAlone() {
        let d = monday(records: records(minutes: 18, qualifying: false), long: 18)
        XCTAssertEqual(l0(d)?.kind, .long, "a planned long run at or under the gate is not the gate's to change")
        XCTAssertEqual(l0(d)?.durationSeconds, 18 * 60)
        XCTAssertTrue(gateChanges(d).isEmpty)
    }

    func testNoFloorLeavesTheGateAsItWas() {
        // A floor of 0 or less applies no floor.
        for f in [0.0, -60] {
            let d = monday(records: records(minutes: 18, qualifying: false),
                           context: F.context(limits: AdaptationLimits(minimumTrimmedSeconds: f)))
            XCTAssertEqual(l0(d)?.durationSeconds, 18 * 60, "floor \(f)")
            XCTAssertTrue(gateChanges(d).first?.explanation.hasSuffix("(SPEC 3.3.)") ?? false, "floor \(f)")
        }
    }
}
