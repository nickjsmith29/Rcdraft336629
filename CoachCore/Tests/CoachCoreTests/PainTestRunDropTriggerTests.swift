import XCTest
@testable import CoachCore

// #154 (from the #153 review): since repair names a run it shortened and then
// dropped only by the drop (`oneChangePerDroppedRun`), the pain test run's
// own drop (`repairKeepingTestRun`, SPEC 3.5 rule 7) cites the triggers of
// that drop alone. Those are the triggers of the guardrail that left no room
// for it, which is what its explanation says, so nothing is lost: the
// shortening it replaces belonged to a plan that is not kept (the plan is
// rebuilt without the test run). Synthetic plans, runs and reports only.
final class PainTestRunDropTriggerTests: XCTestCase {
    typealias F = AdaptFixture

    /// A rest-mode stop on Monday of week 1 (214 min in week 0), unplanned
    /// runs of `total` minutes on Monday and Tuesday, then the 2 mornings at
    /// usual that offer the 25-minute test run, as in `RestStopTestRunHoldTests`.
    private func probe(_ total: Double) -> F.Driver {
        var d = F.Driver(plan: F.weeks(0..<6), context: AdaptationContext(zones: F.zones, timeZone: F.tz, tracksPain: true,
                                                                          usualPainSeed: 2))
        d.follow(until: F.date(week: 1, day: 0, hour: 5)) { _ in F.RunSpec() }
        d.morning(week: 1, day: 0, 3, moved: true)
        XCTAssertEqual(d.state.painStop?.mode, .rest)
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

    /// From 211 minutes (repair would shorten the test run) to 216 (it would
    /// drop it whole), the test run's drop cites the weekly rise that leaves
    /// no room for it, with finite values and a reason, and never only the
    /// stop's own triggers.
    func testTheTestRunDropCitesTheGuardrailThatLeftNoRoom() throws {
        for total in stride(from: 211.0, through: 216.0, by: 1) {
            let d = probe(total)
            let t = try XCTUnwrap(d.state.painRecovery.test, "\(total)")
            let last = try XCTUnwrap(d.outcomes.last)
            let drop = try XCTUnwrap(last.changes.first { $0.kind == .sessionDropped && $0.workoutIDs.contains(t.workoutID) },
                                     "\(total) min")
            XCTAssertTrue(drop.triggers.contains { $0.metric == .weeklyVolume }, "\(total) min: \(drop.triggers.map(\.metric))")
            XCTAssertTrue(drop.triggers.allSatisfy { $0.value.isFinite && !$0.detail.isEmpty }, "\(total) min")
            // Besides the test run's own offer, the drop is the only change that names it (not also a shortening).
            XCTAssertEqual(last.changes.filter { $0.workoutIDs.contains(t.workoutID) && $0.kind != .painTestRun }.map(\.kind),
                           [.sessionDropped],
                           "\(total) min")
            assertAdaptationSound(d.outcomes)
        }
    }
}
