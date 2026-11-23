import XCTest
@testable import CoachCore

// #159 review: SPEC 3.5 rule 1 applies after the 3.3 hold (owner's decision,
// #159). A long run held under the 20-minute floor (a product heuristic) can
// still be longer than the single-run spike rule allows; `cutSpike` gives a run
// already under the floor no floor (cut to the whole minute the rule allows,
// or dropped), and still never cuts a run at or above the floor below it.
// Synthetic data only.
final class GuardrailSpikeUnderFloorTests: XCTestCase {
    typealias F = AdaptFixture
    private let floor = PlanHeuristics.minimumEasyRunSeconds

    private func records(weeks: [Int], minutes: Double) -> [LongRunRecord] {
        weeks.map { w in
            LongRunRecord(activityID: "old-l\(-w)", date: F.date(week: w, day: 5), plannedSeconds: minutes * 60,
                          movingSeconds: minutes * 60, decouplingPercent: 8)
        }
    }

    private func morning(plan: [PlannedWorkout], history: [PlannedWorkout] = [], records: [LongRunRecord] = []) -> F.Driver {
        var d = F.Driver(plan: plan, history: history, context: F.context())
        d.state.longRuns = records
        d.day(F.date(week: 0, day: 0, hour: 5))
        return d
    }

    func testAHeldRunIsCutByTheSpikeRuleBelowTheFloorWhenOldRecordsAndShortHistory() throws {
        // Records at weeks -6 and -5 (18 min, not qualifying); only 15-min runs
        // in the last 30 days, four a week. The held 18-min long run is over
        // the 15 min x 1.1 = 16.5 min the spike rule allows: cut to 16 min.
        let history = (-4 ..< 0).flatMap { w in
            [1, 2, 4, 6].map { F.easy("h\(w)-\($0)", week: w, day: $0, minutes: 15) }
        }
        let plan = [F.easy("e0a", week: 0, day: 1, minutes: 15), F.long("l0", week: 0, day: 5, minutes: 40)]
        let d = morning(plan: plan, history: history, records: records(weeks: [-6, -5], minutes: 18))
        let w = try XCTUnwrap(d.plan.first { $0.id == "l0" })
        XCTAssertEqual(w.durationSeconds, 16 * 60)
        XCTAssertTrue(d.changes.contains { $0.kind == .longRunHeld && $0.workoutIDs == ["l0"] })
        XCTAssertFalse(d.changes.contains { $0.kind == .sessionRested })
        assertAdaptationSound(d.outcomes)
    }

    func testAHandedInPlanOfFifteenAndEighteenMinuteEasyRunsRepairsSound() throws {
        let plan = [F.easy("e0a", week: 0, day: 1, minutes: 15), F.easy("e0b", week: 0, day: 5, minutes: 18)]
        let d = morning(plan: plan)
        let w = try XCTUnwrap(d.plan.first { $0.id == "e0b" })
        XCTAssertEqual(w.durationSeconds, 16 * 60)
        assertAdaptationSound(d.outcomes)
    }

    func testARunAtOrAboveTheFloorIsNeverCutBelowItBySpikeRepair() throws {
        // The spike rule would allow 16 min, but a 25-min run (and one exactly
        // at the floor) is cut to the floor at most.
        for minutes in [25.0, 20.0] {
            let plan = [F.easy("e0a", week: 0, day: 1, minutes: 15), F.easy("e0b", week: 0, day: 5, minutes: minutes)]
            let d = morning(plan: plan)
            let w = try XCTUnwrap(d.plan.first { $0.id == "e0b" })
            XCTAssertEqual(w.durationSeconds, floor, "\(minutes)")
        }
    }

    func testARunWhoseAllowanceIsUnderAMinuteIsDroppedNotKeptUnderTheFloor() throws {
        // A 30-s reference run allows 33 s, under a minute.
        let tiny = PlannedWorkout(id: "tiny", date: F.date(week: 0, day: 1), kind: .easy, durationSeconds: 30)
        let plan = [tiny, F.easy("e0b", week: 0, day: 5, minutes: 15)]
        let d = morning(plan: plan)
        XCTAssertFalse(d.plan.contains { $0.id == "e0b" }, "dropped: the rule allows under a minute")
        assertAdaptationSound(d.outcomes)
    }
}
