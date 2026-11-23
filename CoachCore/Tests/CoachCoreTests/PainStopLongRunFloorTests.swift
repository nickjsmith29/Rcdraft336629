import XCTest
@testable import CoachCore

// #101: the two pain-stop paths that cap a long run after the plan is built
// (rule 7's week-1 return cap and the easy-only stop's long-run share of the
// held level) never draft a run under the 20-minute floor
// (`AdaptationLimits.minimumTrimmedSeconds`, by default
// `PlanHeuristics.minimumEasyRunSeconds`), matching the plan builder (#79,
// #98): a capped long run under the floor is raised to it only when every
// limit allows, otherwise it becomes an easy run at the floor, or a rest day
// that says why. Synthetic plans and reports only; no real runner is here.
final class PainStopLongRunFloorTests: XCTestCase {
    typealias F = AdaptFixture
    private let floor = PlanHeuristics.minimumEasyRunSeconds

    private func context() -> AdaptationContext {
        AdaptationContext(zones: F.zones, timeZone: F.tz, tracksPain: true, usualPainSeed: 2)
    }

    /// Every run planned in every outcome is at least the floor; the test run
    /// that can end a stop has its own length (SPEC 3.5 rule 7) and is left out.
    private func assertNoRunUnderTheFloor(_ outcomes: [AdaptationOutcome], file: StaticString = #filePath, line: UInt = #line) {
        for (k, o) in outcomes.enumerated() {
            let test = o.state.painRecovery.test?.workoutID
            for w in o.plan where w.kind != .rest && w.kind != .race && w.id != test {
                XCTAssertGreaterThanOrEqual(w.durationSeconds, floor - 1e-6,
                                            "outcome \(k): \(w.id) (\(w.kind)) is \(w.durationSeconds / 60) min",
                                            file: file, line: line)
            }
        }
    }

    // MARK: The return's week-1 long run (rule 7)

    /// Weeks of Tue threshold (54 min), Thu easy (55), Sat long (`long` min),
    /// Sun easy (45). Stopped by pain that got worse during t0, then two good
    /// mornings and a passed test run; Friday's morning ends the stop, so the
    /// return's week 1 runs to the end of week 1.
    private func returning(long: Double) -> F.Driver {
        var d = F.Driver(plan: F.weeks(0..<6, longMinutes: { _ in long }), context: context())
        d.follow(until: F.date(week: 0, day: 1, hour: 8)) { _ in F.RunSpec() }
        d.afterRun(week: 0, day: 1, 3, worsened: true, activityID: "run-t0")
        d.morning(week: 0, day: 2, 2, walking: 1)
        d.morning(week: 0, day: 3, 1, walking: 0)
        d.runTest(3, worsened: true)
        d.morning(week: 0, day: 4, 2)
        return d
    }

    func testAWeekOneLongRunCappedUnderTheFloorBecomesAnEasyRunAtTheFloor() {
        // 65% of a 28-minute pre-stop long run is 18.2 min: too short for a long run.
        let d = returning(long: 28)
        XCTAssertNotNil(d.state.painRecovery.painReturn, "the return has begun")
        for id in ["l0", "l1"] {
            let w = d.plan.first { $0.id == id }
            XCTAssertEqual(w?.kind, .easy, id)
            XCTAssertEqual(w?.durationSeconds, floor, id)
            XCTAssertEqual(w?.prescription?.segments.map(\.durationSeconds), [floor], id)
            XCTAssertEqual(w?.prescription?.rules, [.easyByHeartRate], id)
        }
        let swaps = d.changes.filter { $0.kind == .longRunSwappedToEasy && $0.workoutIDs == ["l0"] }
        XCTAssertEqual(swaps.count, 1, "said once, not on every event")
        XCTAssertTrue(swaps.first?.explanation.contains("20 min") ?? false)
        XCTAssertTrue(swaps.first?.triggers.contains { $0.metric == .longRunDuration } ?? false)
        // Saturday's run still keeps its day first on alternate days.
        XCTAssertEqual(d.plan.first { $0.id == "e0b" }?.kind, .rest)
        assertNoRunUnderTheFloor(d.outcomes)
        assertAdaptationSound(d.outcomes)
    }

    func testWeekTwoKeepsTheFloor() {
        var d = returning(long: 28)
        d.day(F.date(week: 2, day: 0, hour: 5))
        XCTAssertEqual(d.course.returnStep, 2)
        XCTAssertGreaterThanOrEqual(d.plan.first { $0.id == "l2" }?.durationSeconds ?? 0, floor)
        assertNoRunUnderTheFloor(d.outcomes)
        assertAdaptationSound(d.outcomes)
    }

    func testAWeekOneCapAtOrAboveTheFloorStillShortensTheLongRun() {
        // 65% of 32 min is 20.8 min: a long run of 20 min, as before #101.
        let d = returning(long: 32)
        let l0 = d.plan.first { $0.id == "l0" }
        XCTAssertEqual(l0?.kind, .long)
        XCTAssertEqual(l0?.durationSeconds, 20 * 60)
        XCTAssertFalse(d.changes.contains { $0.kind == .longRunSwappedToEasy })
        assertNoRunUnderTheFloor(d.outcomes)
        assertAdaptationSound(d.outcomes)
    }

    func testAWeekOneEasyRunOnTheLongRunDayIsCappedToo() {
        // The engine's own plan with the long-run day as a longer easy run (as
        // a regrowth trial restores it, at its original length) is held to
        // the same week-1 rule, so the cap can't be dodged by the swap.
        var d = returning(long: 28)
        let i = d.plan.firstIndex { $0.id == "l1" }!
        d.plan[i] = d.plan[i].resized(toSeconds: 28 * 60)
        d.state.planSnapshot.returned = PlanSnapshot.returned(d.plan)   // not a re-plan
        d.day(F.date(week: 1, day: 0, hour: 5))
        let l1 = d.plan.first { $0.id == "l1" }
        XCTAssertEqual(l1?.kind, .easy)
        XCTAssertEqual(l1?.durationSeconds, floor)
        assertNoRunUnderTheFloor(d.outcomes)
        assertAdaptationSound(d.outcomes)
    }

    func testAReplanInWeekOneIsCappedAgain() {
        var d = returning(long: 28)
        d.handFreshPlan(F.weeks(1..<6, longMinutes: { _ in 28 }))
        d.day(F.date(week: 1, day: 0, hour: 5))
        let l1 = d.plan.first { $0.id == "l1" }
        XCTAssertEqual(l1?.kind, .easy)
        XCTAssertEqual(l1?.durationSeconds, floor)
        XCTAssertFalse(d.plan.contains { $0.kind.isQuality })
        assertNoRunUnderTheFloor(d.outcomes)
        assertAdaptationSound(d.outcomes)
    }

    // MARK: The easy-only stop's long-run cap

    /// Weeks of Tue easy (30 min), Thu easy (25), Sat long (25), Sun easy
    /// (20). Tuesday and Thursday of week 0 are missed and pain gets worse
    /// during Saturday's run: the stop's level is what week 0 held, about
    /// 45 min, whose 35% long-run share is under 16 min.
    private func smallPlan() -> [PlannedWorkout] {
        (0..<4).flatMap { w in
            [F.easy("e\(w)a", week: w, day: 1, minutes: 30),
             F.easy("e\(w)b", week: w, day: 3, minutes: 25),
             F.long("l\(w)", week: w, day: 5, minutes: 25),
             F.easy("e\(w)c", week: w, day: 6, minutes: 20)]
        }
    }

    private func stoppedEasyOnly() -> F.Driver {
        var d = F.Driver(plan: smallPlan(), context: context())
        d.follow(until: F.date(week: 0, day: 5, hour: 8)) { $0.id == "e0a" || $0.id == "e0b" ? nil : F.RunSpec() }
        d.afterRun(week: 0, day: 5, 3, worsened: true, activityID: "run-l0")
        return d
    }

    func testAnEasyOnlyStopLongRunCappedUnderTheFloorBecomesAnEasyRunAtTheFloor() {
        let d = stoppedEasyOnly()
        XCTAssertEqual(d.state.painStop?.mode, .easyOnly)
        let level = d.state.painStop?.level ?? 0
        XCTAssertLessThan(0.35 * level, floor, "the share of the held level is too short for a long run")
        XCTAssertFalse(d.plan.contains { $0.kind == .long }, "no long run of 20 min or more fits 35% of the held level")
        let swapped = d.changes.filter { $0.kind == .longRunSwappedToEasy && $0.rule.contains("rule 7") }
        XCTAssertFalse(swapped.isEmpty)
        XCTAssertTrue(swapped.allSatisfy { c in c.triggers.contains { $0.metric == .longRunShare } })
        XCTAssertTrue(swapped.allSatisfy { $0.explanation.contains("20 min") })
        for c in swapped {
            for id in c.workoutIDs {
                guard let w = d.outcomes.first(where: { $0.changes.contains(c) })?.plan.first(where: { $0.id == id }) else { continue }
                XCTAssertEqual(w.kind, .easy, id)
                XCTAssertGreaterThanOrEqual(w.durationSeconds, floor, id)
            }
        }
        for week in 1..<4 { XCTAssertLessThanOrEqual(F.weekVolume(week, d.plan), level + 1e-6, "week \(week)") }
        XCTAssertTrue(d.outcomes.last!.holdsSatisfied)
        assertNoRunUnderTheFloor(d.outcomes)
        assertAdaptationSound(d.outcomes)
    }

    func testTheEasyOnlyFloorHoldsOnLaterEvents() {
        var d = stoppedEasyOnly()
        let said = d.changes.filter { $0.kind == .longRunSwappedToEasy }.count
        d.day(F.date(week: 1, day: 0, hour: 5))
        d.day(F.date(week: 2, day: 0, hour: 5))
        XCTAssertNotNil(d.state.painStop)
        XCTAssertFalse(d.plan.contains { $0.kind == .long })
        XCTAssertEqual(d.changes.filter { $0.kind == .longRunSwappedToEasy }.count, said, "nothing new to say")
        assertNoRunUnderTheFloor(d.outcomes)
        assertAdaptationSound(d.outcomes)
    }

    // MARK: The decision (heuristic, matching #98's builder)

    private func long(_ minutes: Double, distance: Double? = nil) -> PlannedWorkout {
        var w = F.long("l", week: 1, day: 5, minutes: minutes)
        w.distanceMeters = distance
        return w
    }

    func testFloorDecision() {
        let w = long(30)
        let pass: (PlannedWorkout) -> Bool = { _ in true }
        // The floor fits the cap: a long run at the floor.
        XCTAssertEqual(AdaptationEngine.longRunUnderFloor(w, cap: 20 * 60, floor: floor, measure: .time, passesSpike: pass),
                       .long(floor))
        XCTAssertEqual(AdaptationEngine.longRunUnderFloor(w, cap: 19.5 * 60, floor: 19.5 * 60, measure: .time, passesSpike: pass),
                       .long(19.5 * 60), "a floor off the whole minute can fit a cap the minute rounding missed")
        // Under the cap: an easy run at the floor.
        XCTAssertEqual(AdaptationEngine.longRunUnderFloor(w, cap: 19 * 60, floor: floor, measure: .time, passesSpike: pass),
                       .easy(floor))
        XCTAssertEqual(AdaptationEngine.longRunUnderFloor(w, cap: 0, floor: floor, measure: .time, passesSpike: pass),
                       .easy(floor), "a cap of nothing still leaves no run under the floor")
        // Spike: nothing at the floor passes, so a rest day.
        XCTAssertEqual(AdaptationEngine.longRunUnderFloor(w, cap: 19 * 60, floor: floor, measure: .time, passesSpike: { _ in false }),
                       .rest(.spike))
        // Planned under the floor already: never lengthened.
        XCTAssertEqual(AdaptationEngine.longRunUnderFloor(long(18), cap: 10 * 60, floor: floor, measure: .time, passesSpike: pass),
                       .rest(.plannedUnderFloor))
        // Exactly at the floor: an easy run at the floor.
        XCTAssertEqual(AdaptationEngine.longRunUnderFloor(long(20), cap: 15 * 60, floor: floor, measure: .time, passesSpike: pass),
                       .easy(floor))
    }

    func testFloorDecisionInDistance() {
        // 30 min for 5,000 m: the floor is 3,333 m.
        let w = long(30, distance: 5000)
        let pass: (PlannedWorkout) -> Bool = { _ in true }
        XCTAssertEqual(AdaptationEngine.longRunUnderFloor(w, cap: 3400, floor: floor, measure: .distance, passesSpike: pass), .long(floor))
        XCTAssertEqual(AdaptationEngine.longRunUnderFloor(w, cap: 3300, floor: floor, measure: .distance, passesSpike: pass), .easy(floor))
        // No known distance: the long run can't be checked against the cap, so it runs easy.
        XCTAssertEqual(AdaptationEngine.longRunUnderFloor(long(30), cap: 3400, floor: floor, measure: .distance, passesSpike: pass), .easy(floor))
    }

    func testFloorDecisionRejectsInvalidInput() {
        let pass: (PlannedWorkout) -> Bool = { _ in true }
        for f in [0, -60, Double.nan, Double.infinity] {
            XCTAssertNil(AdaptationEngine.longRunUnderFloor(long(30), cap: 10 * 60, floor: f, measure: .time, passesSpike: pass), "\(f)")
        }
        for c in [Double.nan, -Double.infinity, Double.infinity, -1] {
            XCTAssertNil(AdaptationEngine.longRunUnderFloor(long(30), cap: c, floor: floor, measure: .time, passesSpike: pass), "\(c)")
        }
        var bad = long(30)
        bad.durationSeconds = .nan
        XCTAssertNil(AdaptationEngine.longRunUnderFloor(bad, cap: 10 * 60, floor: floor, measure: .time, passesSpike: pass))
        bad.durationSeconds = 0
        XCTAssertNil(AdaptationEngine.longRunUnderFloor(bad, cap: 10 * 60, floor: floor, measure: .time, passesSpike: pass))
    }

    func testTheSpikeCheckReadsTheWindowBeforeTheRun() {
        // A single 15-minute run in the window allows at most 16.5 min: a run
        // at the floor would spike.
        let history = [PlannedWorkout(id: "h", date: F.date(week: 1, day: 1), kind: .easy, durationSeconds: 15 * 60)]
        let run = F.easy("x", week: 1, day: 5, minutes: 20)
        XCTAssertFalse(AdaptationEngine.passesSpike(run, sessions: history, context: context()))
        XCTAssertTrue(AdaptationEngine.passesSpike(run.resized(toSeconds: 16 * 60), sessions: history, context: context()))
        XCTAssertTrue(AdaptationEngine.passesSpike(run, sessions: [], context: context()), "no reference: not evaluated, as the checker reads it")
        XCTAssertFalse(AdaptationEngine.passesSpike(run, sessions: history + [run], context: context()), "the run is left out of its own window")
    }
}
