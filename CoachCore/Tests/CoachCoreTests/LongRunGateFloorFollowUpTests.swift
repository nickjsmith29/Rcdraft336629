import XCTest
@testable import CoachCore

// #136, follow-ups to #121's gate floor (#132 review):
// 1. A long run planned under the 20-minute floor but within the gate's
//    allowance stays as planned: nothing shortens it, and a rest day would
//    record no long run, so the gate's level could never move (a dead end).
//    The tests below pin that it keeps running week after week.
// 2. #159: a long run over the gate under the floor is held at the allowance
//    and keeps running, so the records grow.
// Synthetic records and plans only; no real runner is here.
final class LongRunGateFloorFollowUpTests: XCTestCase {
    typealias F = AdaptFixture
    private let floor = PlanHeuristics.minimumEasyRunSeconds

    /// Two long-run records before week 0, each planned and run at `minutes`.
    /// `qualifying` sets decoupling under the gate's 5% (the gate opens) or
    /// over it (the gate holds at the recent level).
    private func records(minutes: Double, qualifying: Bool) -> [LongRunRecord] {
        [-2, -1].map { w in
            LongRunRecord(activityID: "old-l\(-w)", date: F.date(week: w, day: 5), plannedSeconds: minutes * 60,
                          movingSeconds: minutes * 60, decouplingPercent: qualifying ? 2 : 8,
                          averageHeartRate: qualifying && minutes <= 40 ? F.zones.easyCeiling - 10 : nil,
                          easyCeiling: F.zones.easyCeiling)
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

    // MARK: 1. Under the floor but within the gate: left as planned, no dead end

    /// Six weeks of the usual plan with every long run at `long` min, each
    /// run as planned from Monday of week 0 to the end of week 5.
    /// `heartRate: false` runs them with no heart rate recorded, so a short run
    /// can't count by easy heart rate (#170) and the held gate stays held.
    private func sixWeeks(records: [LongRunRecord], long: Double, heartRate: Bool = true) -> F.Driver {
        var d = F.Driver(plan: F.weeks(0..<6, longMinutes: { _ in long }), context: F.context())
        d.state.longRuns = records
        d.day(F.date(week: 0, day: 0, hour: 5))
        d.follow(until: F.date(week: 5, day: 6, hour: 23)) { _ in F.RunSpec(heartRate: heartRate) }
        return d
    }

    func testSubFloorLongRunsWithinTheGateKeepRunningAndTheRecordsGrow() {
        // A held gate at 18 min with 18-minute long runs, and an open gate on
        // 6-minute records (16 min allowed) with 15-minute long runs: each
        // long run is within the gate, so every one is run and recorded.
        for (level, qualifying, long) in [(18.0, false, 18.0), (6, true, 15)] {
            let d = sixWeeks(records: records(minutes: level, qualifying: qualifying), long: long)
            let ids = (0..<6).map { "l\($0)" }
            XCTAssertEqual(d.state.longRuns.count, 2 + 6, "level \(level): every long run is recorded")
            XCTAssertEqual(d.state.longRuns.suffix(6).map(\.plannedSeconds), Array(repeating: long * 60, count: 6),
                           "level \(level): each at its planned length")
            XCTAssertFalse(d.changes.contains { $0.kind == .sessionRested && ids.contains($0.workoutIDs.first ?? "") },
                           "level \(level): no long run is rested")
            XCTAssertFalse(d.changes.contains { $0.rule == "SPEC 3.3, section 8" && ids.contains($0.workoutIDs.first ?? "") },
                           "level \(level): the gate never touches a run within it")
            assertAdaptationSound(d.outcomes)
        }
    }

    // MARK: 2. Over the gate, held at the allowance (#159)

    func testSubFloorLongRunsOverTheGateKeepRunningAndTheRecordsGrow() {
        // 19-min long runs on 18-min records that don't qualify, 6 weeks:
        // each is held at 18 min, run and recorded; none is rested. The runs
        // carry no heart rate: with an easy one they would qualify by #170's
        // short-run route and the gate would open (LongRunShortRouteTests).
        let d = sixWeeks(records: records(minutes: 18, qualifying: false), long: 19, heartRate: false)
        let ids = (0..<6).map { "l\($0)" }
        XCTAssertEqual(d.state.longRuns.count, 2 + 6)
        XCTAssertEqual(d.state.longRuns.suffix(6).map(\.plannedSeconds), Array(repeating: 18 * 60, count: 6))
        XCTAssertFalse(d.changes.contains { $0.kind == .sessionRested && ids.contains($0.workoutIDs.first ?? "") })
        XCTAssertEqual(d.changes.filter { $0.kind == .longRunHeld && ids.contains($0.workoutIDs.first ?? "") }.count, 6)
        assertAdaptationSound(d.outcomes)
    }
}
