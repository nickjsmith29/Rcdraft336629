import XCTest
@testable import CoachCore

// SPEC F4, section 8: the adaptation engine on synthetic plans and runs.
final class AdaptationEngineTests: XCTestCase {
    typealias F = AdaptFixture

    private func assertSound(_ d: F.Driver, spikeOff: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        assertAdaptationSound(d.outcomes, limits: spikeOff ? GuardrailLimits(maxSingleRunIncrease: .infinity) : .default,
                              file: file, line: line)
    }

    private func workPace(_ w: PlannedWorkout?) -> Double? {
        w?.prescription?.segments.first { $0.role == .work }?.target.pace?.fastestSecondsPerKm
    }

    private func find(_ id: String, _ plan: [PlannedWorkout]) -> PlannedWorkout? { plan.first { $0.id == id } }

    // MARK: Paces move only after two of the last three quality sessions agree

    func testTwoAheadQualitySessionsMovePacesFasterOnce() {
        var d = F.Driver(plan: F.weeks(0..<4), context: F.context())
        let spec: (PlannedWorkout) -> F.RunSpec? = { $0.kind.isQuality ? F.RunSpec(pace: 0.97) : F.RunSpec() }
        d.follow(until: F.date(week: 0, day: 6, hour: 23), spec)
        XCTAssertTrue(d.changes.filter { $0.kind == .paceTargetsFaster }.isEmpty, "one session is a one-off")
        XCTAssertEqual(d.state.qualitySignals.map(\.signal), [.ahead])

        d.follow(until: F.date(week: 1, day: 1, hour: 23), spec)
        let moves = d.changes.filter { $0.kind == .paceTargetsFaster }
        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(Set(moves[0].workoutIDs), ["t2", "t3"])
        XCTAssertEqual(workPace(find("t2", d.plan))!, 270 * 0.99 * 0.985, accuracy: 1e-9)
        XCTAssertEqual(d.state.qualityPaceFactor, 0.985, accuracy: 1e-12)
        XCTAssertTrue(d.state.qualitySignals.isEmpty, "a move consumes its sessions")
        // The change cites the count and both sessions' pace and heart rate.
        let t = moves[0].triggers
        XCTAssertEqual(t.first?.metric, .signalCount)
        XCTAssertEqual(Set(t.filter { $0.metric == .pace }.compactMap(\.sourceID)), ["run-t0", "run-t1"])
        XCTAssertEqual(t.filter { $0.metric == .heartRate }.count, 2)
        XCTAssertTrue(moves[0].explanation.contains("1.5% faster"))

        // The next ahead session alone does not move them again.
        d.follow(until: F.date(week: 2, day: 6, hour: 23), spec)
        XCTAssertEqual(d.changes.filter { $0.kind == .paceTargetsFaster }.count, 1)
        assertSound(d)
    }

    func testOneOffsDoNotMovePaces() {
        let specs: [String: F.RunSpec] = ["t0": F.RunSpec(pace: 0.97), "t1": F.RunSpec(pace: 1.05), "t2": F.RunSpec()]
        var d = F.Driver(plan: F.weeks(0..<4), context: F.context())
        d.follow(until: F.date(week: 2, day: 6, hour: 23)) { specs[$0.id] ?? F.RunSpec() }
        XCTAssertEqual(d.state.qualitySignals.map(\.signal), [.ahead, .behind, .onTrack])
        XCTAssertFalse(d.changes.contains { [.paceTargetsFaster, .paceTargetsSlower, .volumeHeld].contains($0.kind) })
        XCTAssertEqual(workPace(find("t3", d.plan))!, 270 * 0.99, accuracy: 1e-9)
        assertSound(d)
    }

    func testTwoBehindSessionsSlowPacesAndHoldVolume() {
        // Week 2 plans more running (226 against 214 min); the hold keeps it at week 1's level.
        let plan = F.weeks(0..<4, easyMinutes: { $0 == 2 ? (62, 50) : (55, 45) })
        var d = F.Driver(plan: plan, context: F.context())
        let behind: [String: F.RunSpec] = ["t0": F.RunSpec(pace: 1.04), "t1": F.RunSpec(hr: .high)]
        d.follow(until: F.date(week: 1, day: 1, hour: 23)) { behind[$0.id] ?? F.RunSpec() }
        let slower = d.changes.filter { $0.kind == .paceTargetsSlower }
        XCTAssertEqual(slower.count, 1)
        XCTAssertEqual(workPace(find("t2", d.plan))!, 270 * 0.99 * 1.015, accuracy: 1e-9)
        let held = d.changes.filter { $0.kind == .volumeHeld }
        XCTAssertEqual(held.count, 1)
        XCTAssertTrue(d.state.freezes.isEmpty, "a hold is not a pain freeze")
        XCTAssertEqual(d.state.holds.count, 1)
        XCTAssertEqual(d.state.holds[0].level, 214 * 60, "the higher of week 1 and week 0")
        // Week 2 overlaps the hold, so it is cut back to week 1's volume.
        XCTAssertLessThanOrEqual(F.weekVolume(2, d.history + d.plan), F.weekVolume(1, d.history + d.plan) + 1e-6)
        XCTAssertTrue(d.changes.contains { $0.kind == .sessionShortened && $0.triggers.first?.metric == .weeklyVolume })
        assertSound(d)
    }

    func testHoldStartingInARecoveryWeekHoldsThePreRecoveryLevel() {
        // Week 1 is a recovery week (149 against 214 min); week 2 returns to 214.
        let plan = F.weeks(0..<3, easyMinutes: { $0 == 1 ? (25, 20) : (55, 45) }, longMinutes: { $0 == 1 ? 50 : 60 })
        var d = F.Driver(plan: plan, context: F.context())
        let behind: [String: F.RunSpec] = ["t0": F.RunSpec(pace: 1.04), "t1": F.RunSpec(pace: 1.04)]
        d.follow(until: F.date(week: 1, day: 6, hour: 23)) { behind[$0.id] ?? F.RunSpec() }
        XCTAssertEqual(d.state.holds.first?.level, 214 * 60)
        XCTAssertEqual(F.weekVolume(2, d.plan), 214 * 60, "the return from the recovery week is not cut")
        XCTAssertFalse(d.changes.contains { $0.kind == .sessionShortened })
        assertSound(d)
    }

    // MARK: Easy runs above the zone-2 cap

    func testEasyRunsAboveCapSlowEasyPaceAndFlagIt() {
        var d = F.Driver(plan: F.weeks(0..<2), context: F.context())
        d.follow(until: F.date(week: 0, day: 6, hour: 23)) { $0.kind.isQuality ? F.RunSpec() : F.RunSpec(hr: .high) }
        let c = d.changes.filter { $0.kind == .easyPaceSlower }
        XCTAssertEqual(c.count, 1)
        XCTAssertGreaterThanOrEqual(c[0].triggers[0].value, F.zones.easyCeiling)
        XCTAssertEqual(c[0].triggers[0].expectedHigh, F.zones.easyCeiling)
        XCTAssertEqual(c[0].triggers.count, 4)
        let e1 = find("e1a", d.plan)!.prescription!.segments[0].target.pace!
        XCTAssertEqual(e1.fastestSecondsPerKm, 360 * 1.015, accuracy: 1e-9)
        // Warm-ups of quality sessions are easy running too.
        XCTAssertEqual(find("t1", d.plan)!.prescription!.segments[0].target.pace!.fastestSecondsPerKm, 360 * 1.015, accuracy: 1e-9)
        XCTAssertEqual(workPace(find("t1", d.plan))!, 270 * 0.99, accuracy: 1e-9, "quality paces stay")
        XCTAssertTrue(d.state.easyHeartRates.isEmpty)
        assertSound(d)
    }

    func testEasyRunsUnderCapChangeNothing() {
        var d = F.Driver(plan: F.weeks(0..<2), context: F.context())
        d.follow(until: F.date(week: 0, day: 6, hour: 23)) { _ in F.RunSpec() }
        XCTAssertFalse(d.changes.contains { $0.kind == .easyPaceSlower })
        XCTAssertEqual(d.state.easyHeartRates.count, 3)
    }

    // MARK: Long runs progress only when decoupling stays under 5% (3.3)

    /// Long runs of 60, 70 and 90 minutes.
    private var growingLongs: [PlannedWorkout] { F.weeks(0..<3, longMinutes: { [60, 70, 90][$0] }) }

    /// These tests isolate the long-run gate (3.3, 10-minute steps) from the
    /// single-run spike rule (3.5 rule 1), which would also cut a 60 to 70
    /// minute step to 66; `testSpikeRuleAndGateTogether` covers both at once.
    private var gateOnly: AdaptationContext {
        AdaptationContext(zones: F.zones, timeZone: F.tz, tracksPain: false,
                          guardrails: GuardrailLimits(maxSingleRunIncrease: .infinity))
    }

    func testSpikeRuleAndGateTogether() {
        // With the spike rule on, 70 after 60 is cut to 66 (10% over the 30-day longest).
        var d = F.Driver(plan: growingLongs, context: F.context())
        d.follow(until: F.date(week: 0, day: 5, hour: 23)) { _ in F.RunSpec() }
        // The reference is the 60-minute run as recorded, so 65 or 66 whole minutes.
        XCTAssertEqual(find("l1", d.plan)!.durationSeconds, 66 * 60, accuracy: 60)
        XCTAssertTrue(d.changes.contains { $0.kind == .sessionShortened && $0.workoutIDs == ["l1"]
            && $0.triggers.first?.metric == .singleRunSpike })
        assertSound(d)
    }

    func testLongRunGateOpensWithTheSpikeRuleOn() throws {
        // Long runs 60, 65, 80 with the spike rule on. 65 is within 10% of 60,
        // so it runs as planned; after two qualifying long runs the gate opens
        // and allows a step of at most 10 minutes (75), and the spike rule
        // then holds the third to 10% over the 65 it follows.
        var d = F.Driver(plan: F.weeks(0..<3, longMinutes: { [60, 65, 80][$0] }), context: F.context())
        d.follow(until: F.date(week: 0, day: 5, hour: 23)) { _ in F.RunSpec() }
        XCTAssertEqual(find("l1", d.plan)!.durationSeconds, 65 * 60)
        d.follow(until: F.date(week: 1, day: 5, hour: 23)) { _ in F.RunSpec() }
        let l1 = try XCTUnwrap(d.history.first { $0.id.contains("l1") })
        let l2 = find("l2", d.plan)!
        XCTAssertLessThanOrEqual(l2.durationSeconds, l1.durationSeconds * 1.1 + 1e-6)
        XCTAssertGreaterThanOrEqual(l2.durationSeconds, 70 * 60, "the gate opened: more than the 65 before")
        XCTAssertEqual(l2.prescription!.durationSeconds, l2.durationSeconds)
        XCTAssertTrue(d.changes.contains { $0.workoutIDs.contains("l2") && $0.triggers.contains { $0.metric == .singleRunSpike } })
        XCTAssertFalse(d.changes.contains { $0.kind == .longRunHeld && $0.workoutIDs.contains("l2")
            && $0.triggers.contains { $0.metric == .decoupling && $0.value >= 5 } }, "the gate is open, not shut")
        assertSound(d)
    }

    func testLongRunGateOpensOnlyAfterTwoQualifyingLongRunsAndLimitsTheStep() {
        var d = F.Driver(plan: growingLongs, context: gateOnly)
        d.follow(until: F.date(week: 0, day: 5, hour: 23)) { _ in F.RunSpec() }
        XCTAssertFalse(d.changes.contains { $0.kind == .longRunHeld }, "one long run is too little evidence to hold")
        XCTAssertEqual(find("l1", d.plan)!.durationSeconds, 70 * 60)

        d.follow(until: F.date(week: 1, day: 5, hour: 23)) { _ in F.RunSpec() }
        let held = d.changes.filter { $0.kind == .longRunHeld }
        XCTAssertEqual(held.count, 1)
        XCTAssertEqual(held[0].workoutIDs, ["l2"])
        // Two qualifying long runs: a step is allowed, but at most 10 minutes over 70.
        XCTAssertEqual(find("l2", d.plan)!.durationSeconds, 80 * 60)
        XCTAssertEqual(find("l2", d.plan)!.prescription!.durationSeconds, 80 * 60)
        XCTAssertTrue(held[0].explanation.contains("limited"))
        XCTAssertEqual(held[0].triggers.filter { $0.metric == .decoupling && $0.value < 5 }.count, 2)
        assertSound(d, spikeOff: true)
    }

    func testLongRunGateAllowsAStepOfTenMinutes() {
        var d = F.Driver(plan: F.weeks(0..<3, longMinutes: { [60, 70, 80][$0] }), context: gateOnly)
        d.follow(until: F.date(week: 1, day: 5, hour: 23)) { _ in F.RunSpec() }
        XCTAssertFalse(d.changes.contains { $0.kind == .longRunHeld })
        XCTAssertEqual(find("l2", d.plan)!.durationSeconds, 80 * 60)
    }

    func testDecoupledLongRunHoldsTheNextOne() {
        var d = F.Driver(plan: growingLongs, context: gateOnly)
        d.follow(until: F.date(week: 1, day: 5, hour: 23)) { $0.id == "l1" ? F.RunSpec(drift: 0.15) : F.RunSpec() }
        XCTAssertGreaterThan(d.state.longRuns.last!.decouplingPercent!, 5)
        XCTAssertEqual(find("l2", d.plan)!.durationSeconds, 70 * 60, "held at the longest recent long run")
        let held = d.changes.filter { $0.kind == .longRunHeld }.last!
        XCTAssertTrue(held.triggers.contains { $0.metric == .decoupling && $0.value > 5 && $0.sourceID == "run-l1" })
        assertSound(d, spikeOff: true)
    }

    func testShortLongRunIsNotAtTargetDuration() {
        var d = F.Driver(plan: growingLongs, context: gateOnly)
        d.follow(until: F.date(week: 1, day: 5, hour: 23)) { $0.id == "l1" ? F.RunSpec(durationScale: 0.8) : F.RunSpec() }
        XCTAssertEqual(find("l2", d.plan)!.durationSeconds, 70 * 60)
    }

    func testLongRunWithoutDecouplingIsHeldAndSaysWhy() {
        var d = F.Driver(plan: growingLongs, context: gateOnly)
        d.follow(until: F.date(week: 1, day: 5, hour: 23)) { $0.kind == .long ? F.RunSpec(heartRate: false) : F.RunSpec() }
        XCTAssertEqual(find("l2", d.plan)!.durationSeconds, 70 * 60)
        let held = d.changes.filter { $0.kind == .longRunHeld }.last!
        XCTAssertTrue(held.triggers.contains { $0.detail.contains("could not be measured") })
    }

    func testShortRecoveryLongRunDoesNotPullTheNextOneDown() {
        // 80, recovery 50, then 85: the reference is the longest recent (80), so 85 stands.
        var d = F.Driver(plan: F.weeks(0..<3, easyMinutes: { $0 == 1 ? (45, 40) : (70, 60) }, longMinutes: { [80, 50, 85][$0] }),
                         context: gateOnly)
        d.follow(until: F.date(week: 1, day: 5, hour: 23)) { _ in F.RunSpec() }
        XCTAssertEqual(find("l2", d.plan)!.durationSeconds, 85 * 60)
    }

    // MARK: Missed days (F4: drop the lowest-value session, never stack quality days)

    func testMissedQualityTakesTheNextEasySlot() {
        let o = AdaptationEngine.processDay(asOf: F.date(week: 0, day: 2, hour: 6), state: AdaptationState(),
                                            plan: F.weeks(0..<2), history: [], context: F.context())
        let moved = o.changes.filter { $0.kind == .sessionMoved }
        XCTAssertEqual(moved.count, 1)
        XCTAssertEqual(moved[0].workoutIDs, ["t0", "e0a"])
        XCTAssertEqual(moved[0].triggers[0].metric, .missedSession)
        XCTAssertEqual(moved[0].triggers[0].sourceID, "t0")
        XCTAssertNil(find("e0a", o.plan))
        XCTAssertEqual(find("t0", o.plan)!.date, F.date(week: 0, day: 3))
        XCTAssertEqual(find("t0", o.plan)!.kind, .quality(.threshold))
        // The week loses the easy run (nothing is crammed), which makes the
        // long run too large a share, so the guardrail shortens it as well.
        XCTAssertLessThanOrEqual(F.weekVolume(0, o.plan), (54 + 60 + 45) * 60)
        let long = find("l0", o.plan)!
        XCTAssertLessThan(long.durationSeconds, 3600)
        XCTAssertLessThanOrEqual(long.durationSeconds / F.weekVolume(0, o.plan), 0.35)
        XCTAssertTrue(o.changes.contains { $0.kind == .sessionShortened && $0.workoutIDs == ["l0"] && $0.triggers[0].metric == .longRunShare })
        XCTAssertTrue(o.guardrailReport.passed)
    }

    func testRunWithoutMorningCallStillRearrangesButKeepsTheSessionBeingRun() {
        // No morning call on Thursday: the Thursday easy run is what the runner did,
        // so the missed Tuesday quality takes Sunday's easy slot instead.
        let plan = F.weeks(0..<2)
        let o = AdaptationEngine.processRun(F.run(for: plan.first { $0.id == "e0a" }!), state: AdaptationState(),
                                            plan: plan, history: [], context: F.context())
        XCTAssertEqual(o.assessment?.plannedWorkoutID, "e0a")
        XCTAssertEqual(o.changes.first { $0.kind == .sessionMoved }?.workoutIDs, ["t0", "e0b"])
    }

    func testMissedQualityNeverLandsNextToAnotherQualityDay() {
        var plan = F.weeks(0..<2)
        plan.append(F.threshold("f0", week: 0, day: 4))   // Friday quality
        let o = AdaptationEngine.processDay(asOf: F.date(week: 0, day: 2, hour: 6), state: AdaptationState(),
                                            plan: plan, history: [], context: F.context())
        XCTAssertEqual(o.changes.first { $0.kind == .sessionMoved }?.workoutIDs, ["t0", "e0b"])
        XCTAssertEqual(find("t0", o.plan)!.date, F.date(week: 0, day: 6))
        XCTAssertNotNil(find("e0a", o.plan))
    }

    func testMissedQualityWithNoSafeSlotIsDropped() {
        let plan = [F.threshold("t0", week: 0, day: 1), F.easy("e0", week: 0, day: 2, minutes: 40),
                    F.threshold("q0", week: 0, day: 3), F.long("l0", week: 0, day: 5, minutes: 60)]
        let o = AdaptationEngine.processDay(asOf: F.date(week: 0, day: 2, hour: 6), state: AdaptationState(),
                                            plan: plan, history: [], context: F.context())
        let dropped = o.changes.filter { $0.kind == .sessionDropped }
        XCTAssertEqual(dropped.map(\.workoutIDs), [["t0"]])
        XCTAssertTrue(dropped[0].explanation.contains("stacking"))
        XCTAssertEqual(o.plan.map(\.id), ["e0", "q0", "l0"])
    }

    func testMissedEasyRunIsDroppedAndMissedLongRunMoves() {
        let o = AdaptationEngine.processDay(asOf: F.date(week: 0, day: 4, hour: 6), state: AdaptationState(),
                                            plan: F.weeks(0..<1), history: [], context: F.context())
        // Tuesday's quality takes Sunday's easy slot; Thursday's easy run is simply dropped.
        XCTAssertEqual(o.changes.first { $0.kind == .sessionMoved }?.workoutIDs, ["t0", "e0b"])
        XCTAssertEqual(o.changes.filter { $0.kind == .sessionDropped }.flatMap(\.workoutIDs), ["e0a"])
        XCTAssertTrue(o.changes.first { $0.workoutIDs == ["e0a"] }!.explanation.contains("lowest-value"))

        let o2 = AdaptationEngine.processDay(asOf: F.date(week: 0, day: 6, hour: 6), state: AdaptationState(),
                                             plan: [F.long("l0", week: 0, day: 5, minutes: 60), F.easy("e0", week: 0, day: 6, minutes: 40)],
                                             history: [], context: F.context())
        XCTAssertEqual(o2.changes.first?.kind, .sessionMoved)
        XCTAssertEqual(o2.plan.map(\.id), ["l0"])
        XCTAssertEqual(o2.plan[0].date, F.date(week: 0, day: 6))
    }

    func testSessionsMissedInPastWeeksAreDropped() {
        let o = AdaptationEngine.processDay(asOf: F.date(week: 1, day: 0, hour: 6), state: AdaptationState(),
                                            plan: F.weeks(0..<2), history: [], context: F.context())
        XCTAssertEqual(Set(o.changes.filter { $0.kind == .sessionDropped }.flatMap(\.workoutIDs)), ["t0", "e0a", "l0", "e0b"])
        XCTAssertTrue(o.plan.allSatisfy { $0.date >= F.date(week: 1, day: 0, hour: 0) })
    }

    func testRunMatchesSameDaySessionOrNamedOne() {
        let plan = F.weeks(0..<1)
        var late = F.run(for: plan[0])
        late.activity.start = F.date(week: 0, day: 1, hour: 18)
        let o = AdaptationEngine.processRun(late, state: AdaptationState(), plan: plan, history: [], context: F.context())
        XCTAssertEqual(o.assessment?.plannedWorkoutID, "t0")
        XCTAssertNil(find("t0", o.plan))
        XCTAssertEqual(o.history.map(\.kind), [.quality(.threshold)])

        // A run a day late, named by the app, is not taken as missed.
        var named = F.run(for: plan[0])
        named.activity.start = F.date(week: 0, day: 2)
        named.plannedWorkoutID = "t0"
        let o2 = AdaptationEngine.processRun(named, state: AdaptationState(), plan: plan, history: [], context: F.context())
        XCTAssertEqual(o2.assessment?.plannedWorkoutID, "t0")
        XCTAssertTrue(o2.changes.isEmpty)

        // Unplanned: logged as easy, not classified.
        var extra = F.run(for: plan[0])
        extra.activity.start = F.date(week: 0, day: 0)
        let o3 = AdaptationEngine.processRun(extra, state: AdaptationState(), plan: plan, history: [], context: F.context())
        XCTAssertNil(o3.assessment?.signal)
        XCTAssertEqual(o3.history.map(\.kind), [.easy])
        XCTAssertEqual(o3.plan.count, plan.count)

        // Not a run: nothing logged or matched.
        var walk = F.run(for: plan[0])
        walk.activity.sport = .walk
        let o4 = AdaptationEngine.processRun(walk, state: AdaptationState(), plan: plan, history: [], context: F.context())
        XCTAssertNil(o4.assessment)
        XCTAssertTrue(o4.history.isEmpty)
        XCTAssertEqual(o4.plan.count, plan.count)
    }

    // MARK: Guardrail repair (3.5) after the runner's weeks differ from the plan

    /// A missed run makes week 0 a cut week (150 of 200 min; straight back
    /// to week 1's 216 would be 44% more), so week 1 holds the regrowth's
    /// bound: the higher of 20% over 150 (180) and the first return step
    /// (65% of 216), not the plain 10% (SPEC 3.5 rule 6, #107).
    func testMissedRunLowersNextWeekToTheRegrowthLimit() {
        let plan = PlanFixture.easyWeeks([200, 216, 232])
        let o = AdaptationEngine.processDay(asOf: F.date(week: 0, day: 1, hour: 6), state: AdaptationState(),
                                            plan: plan, history: [], context: F.context())
        XCTAssertTrue(o.guardrailReport.passed, "\(o.guardrailReport.violations.map(\.explanation))")
        XCTAssertLessThanOrEqual(F.weekVolume(1, o.plan), 150 * 1.2 * 60 + 1e-6)
        let cut = o.changes.filter { $0.kind == .sessionShortened }
        XCTAssertFalse(cut.isEmpty)
        XCTAssertEqual(cut[0].triggers[0].metric, .weeklyVolume)
        XCTAssertEqual(cut[0].triggers[0].expectedHigh!, 150 * 1.2 * 60, accuracy: 1e-6)
        XCTAssertTrue(o.plan.allSatisfy { $0.durationSeconds >= PlanHeuristics.minimumEasyRunSeconds })
        XCTAssertTrue(o.plan.allSatisfy { $0.durationSeconds.truncatingRemainder(dividingBy: 60) == 0 }, "whole minutes")
    }

    func testRepairKeepsTheRecoveryWeekWhereItWas() {
        // 300, 320, recovery 240, 330: a missed run in week 0 cuts week 1, so
        // week 2 is no longer 80% of the week before. The repair cuts week 2
        // (the planned recovery week), not week 3. Week 0 is a low week, so
        // week 3 is the third week growing back to the plan and holds the
        // whole planned week, never more (SPEC 3.5 rule 6, #64).
        let plan = PlanFixture.easyWeeks([300, 320, 240, 330])
        let o = AdaptationEngine.processDay(asOf: F.date(week: 0, day: 1, hour: 6), state: AdaptationState(),
                                            plan: plan, history: [], context: F.context())
        XCTAssertTrue(o.guardrailReport.passed, "\(o.guardrailReport.violations.map(\.explanation))")
        let w = (1...3).map { F.weekVolume($0, o.plan) }
        XCTAssertLessThanOrEqual(w[1], 0.8 * w[0] + 1e-6)
        XCTAssertGreaterThan(w[2], 1.1 * w[1], "week 3 is not measured against the recovery week")
        XCTAssertEqual(w[2], 330 * 60, accuracy: 1e-6, "week 3 grows back to the plan, never above it")
        XCTAssertEqual(o.regrowth.week(PlanCalendar.weekStart(containing: F.date(week: 3, day: 0), timeZone: F.tz))?.step, 3)
    }

    func testRepairNeverCutsQualityOrRaceAndNeverLengthens() {
        let plan = F.weeks(0..<3, easyMinutes: { $0 == 1 ? (90, 70) : (55, 45) })
        let o = AdaptationEngine.processDay(asOf: F.date(week: 0, day: 0, hour: 6), state: AdaptationState(),
                                            plan: plan, history: [], context: F.context())
        XCTAssertTrue(o.guardrailReport.passed)
        for w in o.plan {
            let before = find(w.id, plan)!
            XCTAssertLessThanOrEqual(w.durationSeconds, before.durationSeconds)
            if w.kind.isQuality { XCTAssertEqual(w, before) }
        }
    }
}
