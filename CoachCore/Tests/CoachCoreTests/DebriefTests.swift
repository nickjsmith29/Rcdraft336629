import Foundation
import XCTest
@testable import CoachCore

// Synthetic runs only (AdaptFixture): no real runner's data.
private typealias F = AdaptFixture

final class DebriefTests: XCTestCase {
    private let wideShare = AdaptationContext(zones: F.zones, timeZone: F.tz, tracksPain: false,
                                              guardrails: GuardrailLimits(maxLongRunShare: 1))

    // MARK: Helpers

    /// Runs `run` through the engine against `plan` and builds its debrief.
    private func debrief(_ run: CompletedRun, planned: PlannedWorkout?, plan: [PlannedWorkout],
                         context: AdaptationContext? = nil,
                         heuristics: DebriefHeuristics = .default) -> (DebriefFacts, AdaptationOutcome) {
        let ctx = context ?? wideShare
        let o = AdaptationEngine.processRun(run, state: AdaptationState(), plan: plan, history: [], context: ctx)
        return (DebriefFacts.build(run: run, planned: planned, outcome: o, previousOutcome: nil, context: ctx,
                                   heuristics: heuristics), o)
    }

    private func longRun(_ spec: F.RunSpec = F.RunSpec(drift: 0.03, cadenceFade: 0.01)) -> (PlannedWorkout, CompletedRun, [PlannedWorkout]) {
        let long = F.long("l0", week: 0, day: 5, minutes: 60)
        return (long, F.run(for: long, spec), [long, F.easy("e0b", week: 0, day: 6, minutes: 45)])
    }

    private func withSamples(_ run: CompletedRun, _ edit: (inout StreamSample, Int) -> Void) -> CompletedRun {
        var r = run
        for i in r.activity.samples.indices { edit(&r.activity.samples[i], i) }
        return r
    }

    private func topics(_ d: DebriefFacts, _ h: DebriefHeuristics = .default) -> [DebriefLine.Topic] {
        DebriefText.lines(d, heuristics: h).map(\.topic)
    }

    // MARK: The contract: every claim maps to a computed fact (F6 acceptance)

    func testFullDataLongRunGivesFiveLinesFromComputedMetrics() throws {
        let (long, run, plan) = longRun()
        let (d, o) = debrief(run, planned: long, plan: plan)
        let m = try XCTUnwrap(o.assessment?.metrics)

        XCTAssertEqual(topics(d), [.run, .heartRate, .drift, .cadence, .plan])
        // Each fact holds the engine's own numbers, not new ones.
        XCTAssertEqual(d.fact("run")?.value(.movingTime), m.movingSeconds)
        XCTAssertEqual(d.fact("run")?.value(.distance), run.activity.distanceMeters)
        XCTAssertEqual(d.fact("pace")?.value(.pace), m.paceSecondsPerKm)
        XCTAssertEqual(d.fact("heartRate")?.value(.heartRate), m.key?.heartRate)
        XCTAssertEqual(d.fact("heartRate")?.value(.zone), m.key?.heartRate.flatMap { F.zones.zone(for: $0) }.map { Double($0.rawValue) })
        XCTAssertEqual(d.fact("heartRate")?.value(.bandCeiling), F.zones.easyCeiling)
        // The band the classifier judged by: its floor falls back to zone 2's lower bound.
        let hrTrigger = o.assessment?.triggers.first { $0.metric == .heartRate }
        XCTAssertEqual(d.fact("heartRate")?.value(.bandFloor), hrTrigger?.expectedLow)
        XCTAssertEqual(d.fact("heartRate")?.value(.bandFloor), F.zones.lowerBound(.z2))
        XCTAssertEqual(d.fact("drift")?.value(.decoupling), m.decoupling?.percent)
        XCTAssertEqual(d.fact("cadence")?.value(.cadence), m.key?.cadence)
        XCTAssertEqual(d.fact("cadence")?.value(.cadenceFade), m.cadenceFadePercent)
        XCTAssertEqual(d.fact("cadence")?.value(.fadeLimit), AdaptationLimits.default.strainCadenceFadePercent)
        XCTAssertEqual(d.fact("assessment")?.kind, o.assessment?.signal.map { .assessment($0) })
        XCTAssertTrue(o.changes.isEmpty)
        XCTAssertNotNil(d.fact("noChange"))
        XCTAssertEqual(d.fact("heartRate")?.comparison, .within)
        XCTAssertEqual(d.fact("cadence")?.comparison, .within)
        let text = DebriefText.text(d)
        XCTAssertTrue(text.contains("for the planned long run"), text)
        XCTAssertTrue(text.contains("No plan changes."), text)
        assertDebriefContract(d)
    }

    func testStrainingLongRunStatesTheDriftAndFade() throws {
        let (long, run, plan) = longRun(F.RunSpec(drift: 0.3, cadenceFade: 0.06))
        let (d, o) = debrief(run, planned: long, plan: plan)
        let drift = try XCTUnwrap(d.fact("drift"))
        XCTAssertEqual(drift.value(.decoupling), o.assessment?.metrics.decoupling?.percent)
        XCTAssertEqual(drift.kind, .decoupling(.pace, .aboveAerobicThreshold))
        XCTAssertEqual(drift.comparison, .above)
        XCTAssertEqual(d.fact("cadence")?.comparison, .above)
        let text = DebriefText.text(d)
        XCTAssertTrue(text.contains("over 10%, a sign the effort was above the aerobic threshold"), text)
        XCTAssertTrue(text.contains("at or above the 3% fade"), text)
        assertDebriefContract(d)
    }

    func testThresholdSessionReadsRepsAndSkipsTheFade() throws {
        let t = F.threshold("t0", week: 0, day: 1)
        let (d, _) = debrief(F.run(for: t), planned: t, plan: [t])
        XCTAssertEqual(d.fact("pace")?.kind, .pace(.reps))
        XCTAssertEqual(d.fact("pace")?.comparison, .within)
        XCTAssertEqual(d.fact("heartRate")?.comparison, .within)
        XCTAssertNil(d.fact("cadence")?.value(.cadenceFade), "thirds of an interval session mix reps and jogs")
        XCTAssertNil(d.fact("drift"), "decoupling is kept only for steady runs")
        let text = DebriefText.text(d)
        XCTAssertTrue(text.contains("over the reps, inside the"), text)
        XCTAssertTrue(text.contains("on track with the plan"), text)
        assertDebriefContract(d)
    }

    func testPaceComparisonsFollowTheTargetAndTolerance() throws {
        let t = F.threshold("t0", week: 0, day: 1)
        let target = try XCTUnwrap(t.prescription?.segments.first { $0.role == .work }?.target.pace)
        let mid = (target.fastestSecondsPerKm + target.slowestSecondsPerKm) / 2
        let cases: [(Double, DebriefComparison, String)] = [
            (1.05, .above, "slower than the"),
            (0.94, .below, "faster than the"),
            (target.slowestSecondsPerKm * 1.005 / mid, .withinTolerance, "slower than the"),
        ]
        for (multiplier, expected, phrase) in cases {
            let (d, o) = debrief(F.run(for: t, F.RunSpec(pace: multiplier)), planned: t, plan: [t])
            XCTAssertEqual(d.fact("pace")?.comparison, expected, "\(multiplier)")
            XCTAssertEqual(d.fact("pace")?.value(.pace), o.assessment?.metrics.paceSecondsPerKm)
            XCTAssertTrue(DebriefText.text(d).contains(phrase), DebriefText.text(d))
            assertDebriefContract(d)
        }
    }

    func testHeartRateAboveTheBandReadsBehind() {
        let t = F.threshold("t0", week: 0, day: 1)
        let (d, o) = debrief(F.run(for: t, F.RunSpec(hr: .high)), planned: t, plan: [t])
        XCTAssertEqual(o.assessment?.signal, .behind)
        XCTAssertEqual(d.fact("heartRate")?.comparison, .above)
        let text = DebriefText.text(d)
        XCTAssertTrue(text.contains("bpm target band"), text)
        XCTAssertTrue(text.contains(", at or above the top of the "), text)
        XCTAssertTrue(text.contains("behind the plan"), text)
        if let z = d.fact("heartRate")?.value(.zone).flatMap({ HRZone(rawValue: Int($0)) }), z >= .z5a {
            XCTAssertTrue(text.contains("(zone 5"), "Friel's 5a to 5c labels, not raw values: \(text)")
        }
        assertDebriefContract(d)
    }

    // MARK: Missing data: skip a line rather than invent one

    func testNoHeartRateLeavesHeartRateAndDriftOut() {
        let (long, run, plan) = longRun(F.RunSpec(heartRate: false))
        let (d, _) = debrief(run, planned: long, plan: plan)
        XCTAssertNil(d.fact("heartRate"))
        XCTAssertNil(d.fact("drift"))
        XCTAssertEqual(d.fact("missing")?.kind, .missing([.heartRate]))
        let text = DebriefText.text(d)
        XCTAssertFalse(text.contains("bpm"), text)
        XCTAssertTrue(text.contains("No heart rate was recorded"), text)
        assertDebriefContract(d)
    }

    func testNoCadenceLeavesCadenceOut() {
        let (long, run, plan) = longRun()
        let noCadence = withSamples(run) { s, _ in s.cadence = nil }
        let (d, _) = debrief(noCadence, planned: long, plan: plan)
        XCTAssertNil(d.fact("cadence"))
        XCTAssertEqual(d.fact("missing")?.kind, .missing([.cadence]))
        XCTAssertFalse(DebriefText.text(d).contains("spm"))
        assertDebriefContract(d)
    }

    func testCadenceWithoutFadeReadsSteady() {
        let (long, run, plan) = longRun(F.RunSpec(cadenceFade: 0))
        let (d, _) = debrief(run, planned: long, plan: plan)
        XCTAssertEqual(d.fact("cadence")?.value(.cadenceFade) ?? .nan, 0, accuracy: 0.05)
        XCTAssertTrue(DebriefText.text(d).contains("held steady from the first third"), DebriefText.text(d))
        assertDebriefContract(d)
    }

    func testPatchyHeartRateIsNotAveraged() {
        let (long, run, plan) = longRun()
        // Heart rate drops out for long stretches: 120 s of every 160 s.
        let patchy = withSamples(run) { s, i in if (i / 8) % 4 != 0 { s.heartRate = nil } }
        let (d, _) = debrief(patchy, planned: long, plan: plan)
        XCTAssertNil(d.fact("heartRate"))
        XCTAssertEqual(d.fact("patchy")?.kind, .patchy([.heartRate]))
        XCTAssertTrue(DebriefText.text(d).contains("Heart rate dropped out"), DebriefText.text(d))
        assertDebriefContract(d)
    }

    func testTreadmillPaceIsNotCompared() {
        let t = F.threshold("t0", week: 0, day: 1)
        let (d, _) = debrief(F.run(for: t, F.RunSpec(isTreadmill: true)), planned: t, plan: [t])
        XCTAssertEqual(d.fact("pace")?.kind, .paceNotCompared(.treadmill))
        XCTAssertTrue(d.fact("pace")?.values.isEmpty ?? false, "treadmill pace is not stated until the offset exists")
        let text = DebriefText.text(d)
        XCTAssertFalse(text.contains("/km"), text)
        XCTAssertTrue(text.contains("Treadmill pace is not compared"), text)
        assertDebriefContract(d)
    }

    func testHillyRouteWithoutUsableAltitudeStatesRawPaceWithoutJudgingIt() throws {
        // A hilly route (the climb shows in the warm-up and cool-down) whose altitude drops out for
        // every other 2 min of the session's main part: grade-adjusted pace is unavailable, so the
        // debrief keeps stating raw pace without judging it (F7 part 1: unchanged behaviour).
        let t = F.threshold("t0", week: 0, day: 1)
        let hilly = withSamples(F.run(for: t, F.RunSpec(climbPerKm: 30))) { s, _ in
            if s.t >= 600, Int(s.t / 120) % 2 == 1 { s.altitude = nil }
        }
        let (d, o) = debrief(hilly, planned: t, plan: [t])
        let m = try XCTUnwrap(o.assessment?.metrics)
        let pace = try XCTUnwrap(d.fact("pace"))
        XCTAssertNil(m.gradeAdjusted)
        XCTAssertEqual(pace.kind, .paceNotCompared(.hilly))
        XCTAssertNil(pace.comparison)
        XCTAssertEqual(pace.value(.climb), m.climbMetersPerKm)
        XCTAssertEqual(try XCTUnwrap(pace.value(.pace)), 1000 / (m.key?.speed ?? .nan), accuracy: 1e-9)
        XCTAssertTrue(DebriefText.text(d).contains("raw pace is not compared"), DebriefText.text(d))
        assertDebriefContract(d)
    }

    func testVeryShortRunStatesOnlyTimeDistanceAndPace() {
        let easy = F.easy("e0a", week: 0, day: 3, minutes: 60)
        let (d, _) = debrief(F.run(for: easy, F.RunSpec(durationScale: 0.1)), planned: easy, plan: [easy])
        XCTAssertNotNil(d.fact("tooShort"))
        XCTAssertNil(d.fact("heartRate")); XCTAssertNil(d.fact("drift")); XCTAssertNil(d.fact("cadence"))
        XCTAssertEqual(d.fact("tooShort")?.value(.minimumTime), DebriefHeuristics.default.minimumMovingSeconds)
        XCTAssertEqual(topics(d), [.run, .dataGap, .plan])
        XCTAssertTrue(DebriefText.text(d).contains("too short"), DebriefText.text(d))
        assertDebriefContract(d)
    }

    func testUnplannedRunHasNoTargetOrReading() {
        let planned = F.easy("e0a", week: 0, day: 3, minutes: 45)
        let other = F.easy("x", week: 0, day: 2, minutes: 50)   // a Wednesday with nothing planned
        let (d, o) = debrief(F.run(for: other), planned: nil, plan: [planned])
        XCTAssertNil(o.assessment?.plannedWorkoutID)
        XCTAssertEqual(d.fact("run")?.kind, .run(planned: nil))
        XCTAssertEqual(d.fact("pace")?.kind, .pace(.afterWarmUp))
        XCTAssertNil(d.fact("pace")?.comparison)
        XCTAssertNil(d.fact("heartRate")?.comparison)
        XCTAssertNil(d.fact("assessment"))
        let text = DebriefText.text(d)
        XCTAssertTrue(text.contains("not matched to a planned session"), text)
        XCTAssertFalse(text.contains("target"), text)
        assertDebriefContract(d)
    }

    func testPlannedSessionOtherThanTheEngineMatchedIsIgnored() {
        let (long, run, plan) = longRun()
        let o = AdaptationEngine.processRun(run, state: AdaptationState(), plan: plan, history: [], context: wideShare)
        let wrong = F.threshold("t9", week: 0, day: 5)
        XCTAssertEqual(o.assessment?.plannedWorkoutID, long.id)
        for planned in [wrong, nil] {
            let d = DebriefFacts.build(run: run, planned: planned, outcome: o, previousOutcome: nil, context: wideShare)
            XCTAssertEqual(d.fact("run")?.kind, .run(planned: .long), "the engine's match")
            XCTAssertNil(d.fact("pace")?.comparison, "no target from the wrong (or no) session")
            XCTAssertNil(d.fact("heartRate")?.comparison)
            assertDebriefContract(d)
        }
    }

    func testNonFiniteValuesNeverReachTheText() {
        let (long, run, _) = longRun()
        var broken = withSamples(run) { s, i in
            if i % 7 == 0 { s.heartRate = .nan }
            if i % 11 == 0 { s.speed = .infinity }
            if i % 13 == 0 { s.cadence = -.infinity }
            if i == 5 { s.t = .nan }
        }
        broken.activity.distanceMeters = .nan
        broken.activity.durationSeconds = .infinity
        let d = DebriefFacts.build(run: broken, planned: long, zones: F.zones, timeZone: F.tz)
        for f in d.facts { XCTAssertTrue(f.values.allSatisfy { $0.value.isFinite }, f.id) }
        XCTAssertNotNil(d.fact("run")?.value(.distance), "falls back to the distance stream")
        assertDebriefContract(d)
    }

    func testRunWithoutSamplesStatesElapsedTimeOnly() {
        let a = Activity(id: "bare", source: .healthKit, start: F.date(week: 0, day: 2), durationSeconds: 1800)
        let d = DebriefFacts.build(run: CompletedRun(activity: a), planned: nil, zones: F.zones, timeZone: F.tz)
        XCTAssertEqual(d.fact("run")?.values, [DebriefValue(name: .elapsedTime, value: 1800, unit: .seconds)])
        XCTAssertEqual(d.fact("missing")?.kind, .missing([.pace, .heartRate, .cadence]))
        XCTAssertEqual(topics(d), [.run, .dataGap])
        XCTAssertEqual(DebriefText.text(d),
                       "30:00 elapsed, not matched to a planned session.\nNo pace, heart rate or cadence was recorded, so they are left out.")
        assertDebriefContract(d)

        var empty = a
        empty.durationSeconds = .nan
        let none = DebriefFacts.build(run: CompletedRun(activity: empty), planned: nil, zones: F.zones, timeZone: F.tz)
        XCTAssertNil(none.fact("run"))
        assertDebriefContract(none)
    }

    func testNonRunActivityGetsNoDebrief() {
        var a = longRun().1.activity
        a.sport = .walk
        let d = DebriefFacts.build(run: CompletedRun(activity: a), planned: nil, zones: F.zones, timeZone: F.tz)
        XCTAssertTrue(d.facts.isEmpty)
        XCTAssertTrue(DebriefText.lines(d).isEmpty)
    }

    func testColdStartWithoutZonesStatesNoZone() {
        let (long, run, _) = longRun()
        let d = DebriefFacts.build(run: run, planned: long, zones: nil, timeZone: F.tz)
        XCTAssertNotNil(d.fact("heartRate"))
        XCTAssertNil(d.fact("heartRate")?.value(.zone))
        XCTAssertNil(d.fact("assessment"))
        XCTAssertFalse(topics(d).contains(.plan), "no outcome, no plan line")
        XCTAssertFalse(DebriefText.text(d).contains("zone"))
        assertDebriefContract(d)
    }

    // MARK: What changes this week

    func testBehindSessionsReportPaceAndVolumeChanges() throws {
        let plan = F.weeks(0..<4, easyMinutes: { $0 == 2 ? (62, 50) : (55, 45) })
        var drv = F.Driver(plan: plan, context: F.context())
        let behind: [String: F.RunSpec] = ["t0": F.RunSpec(pace: 1.04), "t1": F.RunSpec(hr: .high)]
        drv.follow(until: F.date(week: 1, day: 1, hour: 23)) { behind[$0.id] ?? F.RunSpec() }
        let i = try XCTUnwrap(drv.outcomes.firstIndex { $0.assessment?.activityID == "run-t1" })
        let o = drv.outcomes[i]
        let slower = try XCTUnwrap(o.changes.first { $0.kind == .paceTargetsSlower })
        let t1 = try XCTUnwrap(plan.first { $0.id == "t1" })
        let d = DebriefFacts.build(run: F.run(for: t1, behind["t1"]!), planned: t1, outcome: o,
                                   previousOutcome: drv.outcomes[i - 1], context: F.context())

        let pace = try XCTUnwrap(d.fact("change.paceTargetsSlower"))
        XCTAssertEqual(pace.value(.paceStep), AdaptationLimits.default.paceStep)
        XCTAssertEqual(pace.value(.sessions), Double(Set(slower.workoutIDs).count))
        let held = try XCTUnwrap(d.fact("change.volumeHeld"))
        XCTAssertEqual(held.value(.heldLevel), o.state.holds.last?.level)
        XCTAssertEqual(held.value(.holdEnd), o.state.holds.last?.interval.end.timeIntervalSince1970)
        let text = DebriefText.text(d)
        XCTAssertTrue(text.contains("Plan changes: quality pace targets move 1.5% slower on"), text)
        XCTAssertTrue(text.contains("weekly volume stays at or below 3 h 34 min until"), text)
        assertDebriefContract(d)

        // More change kinds than the template spells out are counted, not dropped.
        let one = DebriefFacts.build(run: F.run(for: t1, behind["t1"]!), planned: t1, outcome: o,
                                     previousOutcome: drv.outcomes[i - 1], context: F.context(),
                                     heuristics: DebriefHeuristics(maximumChangeClauses: 1))
        let kinds = Set(o.changes.map(\.kind))
        XCTAssertGreaterThan(kinds.count, 1)
        let first = PlanChange.Kind.allCases.first { kinds.contains($0) }!
        XCTAssertEqual(one.fact("moreChanges")?.value(.count), Double(o.changes.filter { $0.kind != first }.count))
        XCTAssertTrue(DebriefText.text(one).contains("more change"), DebriefText.text(one))
        assertDebriefContract(one)
    }

    /// Week 1 plans Tue threshold 54, Thu easy 55, Sat long 60, Sun easy 45; a
    /// 100 min hold with a 51 min long-run floor can't be met (105 min left).
    private func holdState(level minutes: Double) -> AdaptationState {
        let start = F.date(week: 1, day: 0, hour: 0)
        return AdaptationState(holds: [VolumeHold(interval: DateInterval(start: start, duration: 7 * 86_400),
                                                  level: minutes * 60, longRunFloorSeconds: 51 * 60)])
    }

    func testRepeatedHoldShortfallIsStatedOnlyWhenNewOrChanged() throws {
        let morning = AdaptationEngine.processDay(asOf: F.date(week: 1, day: 1, hour: 5), state: holdState(level: 100),
                                                  plan: F.weeks(0..<2), history: [], context: wideShare)
        XCTAssertTrue(morning.changes.contains { $0.kind == .holdShortfall })
        let t1 = try XCTUnwrap(morning.plan.first { $0.id == "t1" })
        let run = F.run(for: t1)
        // The engine itself now posts an unchanged shortfall only once (#51).
        let recorded = AdaptationEngine.processRun(run, state: morning.state, plan: morning.plan, history: morning.history,
                                                   context: wideShare)
        XCTAssertFalse(recorded.changes.contains { $0.kind == .holdShortfall }, "posted only when new or changed")
        // The debrief still de-duplicates on its own: an outcome from a state
        // with no record of the earlier post (say, one stored before the
        // engine kept that record) repeats it.
        var unrecorded = morning.state
        unrecorded.reportedHoldShortfalls = []
        let o = AdaptationEngine.processRun(run, state: unrecorded, plan: morning.plan, history: morning.history,
                                            context: wideShare)
        XCTAssertTrue(o.changes.contains { $0.kind == .holdShortfall })

        let repeated = DebriefFacts.build(run: run, planned: t1, outcome: o, previousOutcome: morning, context: wideShare)
        XCTAssertNil(repeated.fact("change.holdShortfall"))
        XCTAssertFalse(DebriefText.text(repeated).contains("volume hold"), DebriefText.text(repeated))
        assertDebriefContract(repeated)

        let fresh = DebriefFacts.build(run: run, planned: t1, outcome: o, previousOutcome: nil, context: wideShare)
        let s = try XCTUnwrap(fresh.fact("change.holdShortfall"))
        XCTAssertEqual(s.value(.overHeldLevel), 5 * 60)
        XCTAssertTrue(DebriefText.text(fresh).contains("the volume hold can't be fully met: 5 min stays over the held level"),
                      DebriefText.text(fresh))
        assertDebriefContract(fresh)

        // A shortfall that changed since the previous event is stated again.
        let changedState = holdState(level: 103)
        let earlier = AdaptationEngine.processDay(asOf: F.date(week: 1, day: 1, hour: 5), state: changedState,
                                                  plan: F.weeks(0..<2), history: [], context: wideShare)
        let changed = DebriefFacts.build(run: run, planned: t1, outcome: o, previousOutcome: earlier, context: wideShare)
        XCTAssertEqual(changed.fact("change.holdShortfall")?.value(.overHeldLevel), 5 * 60)
        assertDebriefContract(changed)
    }

    func testPainFreezeChangeStatesTheScore() {
        let (long, run, _) = longRun()
        let freeze = PlanChange(kind: .painVolumeFreeze, workoutIDs: [],
                                triggers: [TriggerMetric(metric: .painScore, value: 5, expectedHigh: 3, unit: .painScore, detail: "pain 5/10")],
                                rule: "SPEC 3.5 (heuristic), F9", explanation: "synthetic")
        let base = AdaptationEngine.processRun(run, state: AdaptationState(), plan: [long], history: [], context: wideShare)
        let o = AdaptationOutcome(state: base.state, plan: base.plan, history: base.history, assessment: base.assessment,
                                  changes: [freeze], guardrailReport: base.guardrailReport, suggestClinician: false,
                                  holdsSatisfied: true)
        let d = DebriefFacts.build(run: run, planned: long, outcome: o, previousOutcome: nil, context: wideShare)
        XCTAssertTrue(DebriefText.text(d).contains("volume growth is frozen after a pain score of 5/10"), DebriefText.text(d))
        assertDebriefContract(d)
    }

    // MARK: Shown numbers agree with the comparison (boundaries)

    private func facts(_ f: DebriefFact) -> DebriefFacts { DebriefFacts(activityID: "x", facts: [f], timeZone: F.tz) }
    private func line(_ f: DebriefFact) -> String { DebriefText.text(facts(f)) }

    private func hrFact(_ hr: Double, floor: Double?, ceiling: Double?, _ c: DebriefComparison) -> DebriefFact {
        var values = [DebriefValue(name: .heartRate, value: hr, unit: .bpm)]
        if let floor { values.append(DebriefValue(name: .bandFloor, value: floor, unit: .bpm)) }
        if let ceiling { values.append(DebriefValue(name: .bandCeiling, value: ceiling, unit: .bpm)) }
        return DebriefFact(id: "heartRate", kind: .heartRate(.mainPart), values: values, comparison: c, source: "test")
    }

    func testHeartRateNearTheCeilingShowsEnoughPrecision() {
        let near = hrFact(169.67, floor: 157, ceiling: 169.95, .within)
        XCTAssertEqual(line(near), "Heart rate averaged 169.7 bpm over the main part, inside the 157 to 170 bpm target band.")
        assertDebriefContract(facts(near))
        let capOnly = hrFact(148.6, floor: nil, ceiling: 148.62, .within)
        XCTAssertTrue(line(capOnly).contains("148.6 bpm over the main part, under the 149 bpm ceiling"), line(capOnly))
        assertDebriefContract(facts(capOnly))
        // A ceiling that rounds down below the value needs precision on both.
        let both = hrFact(169.3, floor: nil, ceiling: 169.4, .within)
        XCTAssertTrue(line(both).contains("169.3 bpm over the main part, under the 169.4 bpm ceiling"), line(both))
        assertDebriefContract(facts(both))
        assertDebriefContract(facts(capOnly))
        let floor = hrFact(156.6, floor: 156.7, ceiling: 170, .below)
        XCTAssertTrue(line(floor).contains("156.6 bpm"), line(floor))
        assertDebriefContract(facts(floor))
        // At the ceiling exactly the classifier says above, and "at or above" holds when rounded.
        let at = hrFact(169.6, floor: nil, ceiling: 169.55, .above)
        XCTAssertTrue(line(at).contains("170 bpm over the main part, at or above the 170 bpm ceiling"), line(at))
        assertDebriefContract(facts(at))
        // No precision separates them: boundary wording.
        let tie = hrFact(169.9999, floor: 157, ceiling: 170, .within)
        XCTAssertTrue(line(tie).contains("just inside the 157 to 170 bpm target band"), line(tie))
        assertDebriefContract(facts(tie))
    }

    func testHeartRateAtOrJustOverTheCeilingOfABand() {
        // The ceiling is exclusive, so a heart rate equal to it is already above the band.
        let at = hrFact(148.5, floor: 140, ceiling: 148.5, .above)
        XCTAssertEqual(line(at), "Heart rate averaged 149 bpm over the main part, at or above the top of the 140 to 149 bpm target band.")
        let over = hrFact(148.6, floor: 140, ceiling: 148.5, .above)
        XCTAssertTrue(line(over).contains("149 bpm over the main part, at or above the top of the 140 to 149 bpm target band"), line(over))
        for f in [at, over, hrFact(149, floor: 140, ceiling: 148.5, .above), hrFact(175, floor: 140, ceiling: 148.5, .above)] {
            XCTAssertEqual(facts(f).fact("heartRate").flatMap { DebriefText.heartRateLine(facts($0)) }?.comparisons.map(\.relation), [.atLeast])
            assertDebriefContract(facts(f))
        }
        // From the builder: an easy run whose heart rate sits exactly on the easy ceiling.
        let (long, run, _) = longRun()
        let onCap = withSamples(run) { s, _ in s.heartRate = F.zones.easyCeiling }
        let d = DebriefFacts.build(run: onCap, planned: long, zones: F.zones, timeZone: F.tz)
        XCTAssertEqual(d.fact("heartRate")?.comparison, .above)
        assertDebriefContract(d)
    }

    /// Paces across both ends of a target, with no tolerance and with 1%: every
    /// comparison the line states holds for the shown paces.
    func testPaceSweepAcrossBothTargetEnds() {
        let target = PaceTarget(fastestSecondsPerKm: 267, slowestSecondsPerKm: 275)
        for tolerance in [0.0, 0.01] {
            for pace in stride(from: 258.0, through: 284.0, by: 0.05) {
                let c = DebriefFacts.paceComparison(pace, target, tolerance: tolerance)
                let f = DebriefFact(id: "pace", kind: .pace(.mainPart), values: [
                    DebriefValue(name: .pace, value: pace, unit: .secondsPerKm),
                    DebriefValue(name: .targetFastest, value: 267, unit: .secondsPerKm),
                    DebriefValue(name: .targetSlowest, value: 275, unit: .secondsPerKm),
                    DebriefValue(name: .paceTolerance, value: tolerance, unit: .fraction),
                ], comparison: c, source: "test")
                for units in UnitPreference.allCases {
                    let l = DebriefText.runLine(facts(f), units: units)
                    XCTAssertEqual(l?.comparisons.isEmpty, false, "\(pace) \(tolerance) \(units)")
                    if c == .withinTolerance {
                        XCTAssertTrue(l?.text.contains("close enough to count as on pace") ?? false, l?.text ?? "")
                        XCTAssertFalse(l?.text.contains("%") ?? true, "no tolerance percent the shown paces could contradict")
                    }
                    assertDebriefContract(facts(f), units: units)
                }
            }
        }
        // Shown equal to an end yet outside it: boundary wording, not "inside".
        let edge = DebriefFact(id: "pace", kind: .pace(.mainPart), values: [
            DebriefValue(name: .pace, value: 275.4, unit: .secondsPerKm),
            DebriefValue(name: .targetFastest, value: 267, unit: .secondsPerKm),
            DebriefValue(name: .targetSlowest, value: 275, unit: .secondsPerKm),
        ], comparison: .withinTolerance, source: "test")
        XCTAssertTrue(line(edge).contains("4:35/km over the main part, just slower than the 4:27 to 4:35/km target"), line(edge))
    }

    private func driftFact(_ p: Double) -> DebriefFact {
        DebriefFact(id: "drift", kind: .decoupling(.pace, DecouplingClass(percent: p)), values: [
            DebriefValue(name: .decoupling, value: p, unit: .percent),
            DebriefValue(name: .goodLimit, value: 5, unit: .percent),
            DebriefValue(name: .highLimit, value: 10, unit: .percent),
        ], comparison: .below, source: "test")
    }

    func testDriftNearTheClassLimitsShowsEnoughPrecision() {
        let cases: [(Double, String)] = [
            (4.96, "was 4.96%: under 5%"),
            (10.04, "was 10.04%: over 10%"),
            (5, "was 5%: between 5% and 10%"),
            (10, "was 10%: between 5% and 10%"),
            (4.9999, "was 5%: just under 5%"),
            (-0.04, "was 0%: under 5%, good aerobic endurance at this effort."),
            (-1.5, "was -1.5%: under 5%, good aerobic endurance at this effort (efficiency rose in the second half)."),
        ]
        for (p, phrase) in cases {
            XCTAssertTrue(line(driftFact(p)).contains(phrase), "\(p): \(line(driftFact(p)))")
            assertDebriefContract(facts(driftFact(p)))
        }
        XCTAssertFalse(line(driftFact(-0.04)).contains("efficiency rose"), "a shown 0% is not a rise")
    }

    private func fadeFact(_ fade: Double, limit: Double = 3) -> DebriefFact {
        DebriefFact(id: "cadence", kind: .cadence(.mainPart), values: [
            DebriefValue(name: .cadence, value: 170, unit: .stepsPerMinute),
            DebriefValue(name: .cadenceFade, value: fade, unit: .percent),
            DebriefValue(name: .fadeLimit, value: limit, unit: .percent),
        ], comparison: fade >= limit ? .above : .within, source: "test")
    }

    func testCadenceFadeNearTheLimitShowsEnoughPrecision() {
        XCTAssertTrue(line(fadeFact(2.99)).contains("fell 2.99% from the first third to the final third, under the 3% fade"),
                      line(fadeFact(2.99)))
        XCTAssertTrue(line(fadeFact(3)).contains("fell 3% from the first third to the final third, at or above the 3% fade"),
                      line(fadeFact(3)))
        XCTAssertTrue(line(fadeFact(2.99999)).contains("just under the 3% fade"), line(fadeFact(2.99999)))
        for f in [2.99, 3, 2.99999, 0.02, -1.2] { assertDebriefContract(facts(fadeFact(f))) }
    }

    private func shortFact(_ moving: Double, minimum: Double = 600) -> DebriefFact {
        DebriefFact(id: "tooShort", kind: .tooShort, values: [
            DebriefValue(name: .movingTime, value: moving, unit: .seconds),
            DebriefValue(name: .minimumTime, value: minimum, unit: .seconds),
        ], comparison: .below, source: "test")
    }

    func testShortRunNearTheMinimumShowsTheClock() {
        XCTAssertTrue(line(shortFact(599.7)).hasPrefix("At 9:59 moving, the run is under 10:00"), line(shortFact(599.7)))
        XCTAssertTrue(line(shortFact(599.2, minimum: 599.8)).contains("just under 9:59"), line(shortFact(599.2, minimum: 599.8)))
        for (m, minimum) in [(599.7, 600.0), (599.2, 599.8), (240, 600)] { assertDebriefContract(facts(shortFact(m, minimum: minimum))) }
        // From the builder: a run just short of the minimum.
        let easy = F.easy("e0a", week: 0, day: 3, minutes: 9.995)
        let d = DebriefFacts.build(run: F.run(for: easy), planned: easy, zones: F.zones, timeZone: F.tz,
                                   heuristics: DebriefHeuristics(minimumMovingSeconds: 600))
        XCTAssertNotNil(d.fact("tooShort"))
        assertDebriefContract(d)
    }

    private func paceFact(_ pace: Double, _ c: DebriefComparison) -> DebriefFact {
        DebriefFact(id: "pace", kind: .pace(.mainPart), values: [
            DebriefValue(name: .pace, value: pace, unit: .secondsPerKm),
            DebriefValue(name: .targetFastest, value: 267, unit: .secondsPerKm),
            DebriefValue(name: .targetSlowest, value: 275, unit: .secondsPerKm),
            DebriefValue(name: .paceTolerance, value: 0, unit: .fraction),
        ], comparison: c, source: "test")
    }

    func testPaceNearTheTargetEndsUsesBoundaryWording() {
        XCTAssertTrue(line(paceFact(275.3, .above)).contains("4:35/km over the main part, just slower than the 4:27 to 4:35/km target"),
                      line(paceFact(275.3, .above)))
        XCTAssertTrue(line(paceFact(266.8, .below)).contains("just faster than the 4:27 to 4:35/km target"), line(paceFact(266.8, .below)))
        XCTAssertTrue(line(paceFact(280, .above)).contains("4:40/km over the main part, slower than"), line(paceFact(280, .above)))
        XCTAssertTrue(line(paceFact(275.4, .within)).contains("4:35/km over the main part, inside"), line(paceFact(275.4, .within)))
        for (p, c) in [(275.3, DebriefComparison.above), (266.8, .below), (280, .above), (275.4, .within)] {
            assertDebriefContract(facts(paceFact(p, c)))
        }
    }

    func testLongRunCapNearItsPlannedLengthUsesBoundaryWording() {
        func cap(_ allowed: Double, _ planned: Double) -> DebriefFacts {
            facts(DebriefFact(id: "change.longRunHeld", kind: .change(.longRunHeld), values: [
                DebriefValue(name: .allowedTime, value: allowed, unit: .seconds),
                DebriefValue(name: .plannedTime, value: planned, unit: .seconds),
            ], comparison: .below, source: "test"))
        }
        XCTAssertTrue(DebriefText.text(cap(5400, 6000)).contains("capped at 1 h 30 min instead of 1 h 40 min"))
        XCTAssertTrue(DebriefText.text(cap(5400, 5410)).contains("capped just under its planned 1 h 30 min"), DebriefText.text(cap(5400, 5410)))
        assertDebriefContract(cap(5400, 6000))
        assertDebriefContract(cap(5400, 5410))
    }

    func testEasyRunBelowTheClassifierFloorReadsBelowTheBand() {
        let (long, run, plan) = longRun(F.RunSpec(hr: .low))
        let (d, o) = debrief(run, planned: long, plan: plan)
        let t = o.assessment?.triggers.first { $0.metric == .heartRate }
        XCTAssertEqual(d.fact("heartRate")?.value(.bandFloor), t?.expectedLow)
        XCTAssertEqual(d.fact("heartRate")?.comparison, .below)
        XCTAssertTrue(DebriefText.text(d).contains("below the"), DebriefText.text(d))
        assertDebriefContract(d)
    }

    func testHoldShortfallCountsOnlyWeeksMeasuredOver() {
        let (long, run, _) = longRun()
        let measured = PlanChange(kind: .holdShortfall, workoutIDs: [], triggers: [
            TriggerMetric(metric: .weeklyVolume, value: 6300, expectedHigh: 6000, unit: .seconds, detail: "planned"),
            TriggerMetric(metric: .weeklyVolume, value: 6300, expectedHigh: 6000, unit: .seconds, detail: "left"),
        ], rule: "SPEC F4, section 8 (heuristic)", explanation: "synthetic")
        let unknown = PlanChange(kind: .holdShortfall, workoutIDs: [], triggers: [
            TriggerMetric(metric: .weeklyVolume, value: 6000, expectedHigh: 6000, unit: .seconds, detail: "unknown week"),
        ], rule: "SPEC F4, section 8 (heuristic)", explanation: "synthetic unknown")
        let base = AdaptationEngine.processRun(run, state: AdaptationState(), plan: [long], history: [], context: wideShare)
        func outcome(_ changes: [PlanChange]) -> AdaptationOutcome {
            AdaptationOutcome(state: base.state, plan: base.plan, history: base.history, assessment: base.assessment,
                              changes: changes, guardrailReport: base.guardrailReport, suggestClinician: false,
                              holdsSatisfied: false)
        }
        let both = DebriefFacts.build(run: run, planned: long, outcome: outcome([measured, unknown]), previousOutcome: nil,
                                      context: wideShare)
        let f = both.fact("change.holdShortfall")
        XCTAssertEqual(f?.value(.weeks), 1, "the unknown week is not counted as over")
        XCTAssertEqual(f?.value(.uncheckedWeeks), 1)
        XCTAssertEqual(f?.value(.overHeldLevel), 300)
        XCTAssertTrue(DebriefText.text(both).contains("5 min stays over the held level; it can't be checked in a week whose volume is unknown"),
                      DebriefText.text(both))
        assertDebriefContract(both)
        let onlyUnknown = DebriefFacts.build(run: run, planned: long, outcome: outcome([unknown]), previousOutcome: nil, context: wideShare)
        XCTAssertNil(onlyUnknown.fact("change.holdShortfall")?.value(.weeks))
        XCTAssertTrue(DebriefText.text(onlyUnknown).contains("the volume hold can't be checked in a week whose volume is unknown"))
        assertDebriefContract(onlyUnknown)
    }

    /// Engine-driven runs across drift, fade, heart rate and pace: the contract holds for every one.
    func testContractHoldsAcrossASweepOfRuns() {
        let long = F.long("l0", week: 0, day: 5, minutes: 60)
        let t = F.threshold("t0", week: 0, day: 1)
        var specs: [(PlannedWorkout, F.RunSpec)] = []
        for drift in stride(from: 0.0, through: 0.3, by: 0.025) {
            for fade in [0.0, 0.01, 0.03, 0.05] { specs.append((long, F.RunSpec(drift: drift, cadenceFade: fade))) }
        }
        for hr in [F.HR.low, .mid, .high] {
            for pace in stride(from: 0.94, through: 1.06, by: 0.01) { specs.append((t, F.RunSpec(pace: pace, hr: hr))) }
        }
        for (w, spec) in specs {
            let (d, _) = debrief(F.run(for: w, spec), planned: w, plan: [w])
            for units in UnitPreference.allCases { assertDebriefContract(d, units: units) }
        }
    }

    // MARK: Lines and formatting

    func testLineCapKeepsThePlanAndTheHighestPriorityTopics() {
        let (long, run, plan) = longRun()
        let (d, _) = debrief(run, planned: long, plan: plan)
        let h = DebriefHeuristics(maximumLines: 3)
        XCTAssertEqual(topics(d, h), [.run, .heartRate, .plan])
        XCTAssertEqual(topics(d, DebriefHeuristics(maximumLines: 0)), [.plan], "at least one line")
        assertDebriefContract(d, heuristics: h)
    }

    /// The easy-cap change with no easy pace targets left to move says heart
    /// rate, not pace, sets easy runs (SPEC 3.1, F6); with targets it states the move.
    func testEasyCapWithNoEasyTargetsToMoveLetsHeartRateSetEasyRuns() {
        func easyCap(sessions: Double) -> DebriefFacts {
            var values = [DebriefValue(name: .easyMeanHeartRate, value: 152.4, unit: .bpm),
                          DebriefValue(name: .easyCap, value: 150, unit: .bpm),
                          DebriefValue(name: .sessions, value: sessions, unit: .count)]
            if sessions > 0 { values.append(DebriefValue(name: .paceStep, value: 0.015, unit: .fraction)) }
            return DebriefFacts(activityID: "x", facts: [DebriefFact(id: "change.easyPaceSlower", kind: .change(.easyPaceSlower),
                                                                    values: values, comparison: .above, source: "test")], timeZone: F.tz)
        }
        let none = easyCap(sessions: 0)
        let text = DebriefText.text(none)
        XCTAssertTrue(text.contains("easy runs averaged 152 bpm, at or above the easy cap of 150 bpm, so let heart rate, not pace, set easy runs"), text)
        XCTAssertFalse(text.contains("easy pace targets move"), text)
        assertDebriefContract(none)

        let some = DebriefText.text(easyCap(sessions: 2))
        XCTAssertTrue(some.contains("so easy pace targets move 1.5% slower on 2 sessions"), some)
        XCTAssertFalse(some.contains("let heart rate, not pace"), some)
        assertDebriefContract(easyCap(sessions: 2))
    }

    func testDecouplingLimitsMatchTheClassifier() {
        XCTAssertEqual(DecouplingClass(percent: DebriefFacts.decouplingGoodLimit - 0.001), .good)
        XCTAssertEqual(DecouplingClass(percent: DebriefFacts.decouplingGoodLimit), .moderate)
        XCTAssertEqual(DecouplingClass(percent: DebriefFacts.decouplingHighLimit), .moderate)
        XCTAssertEqual(DecouplingClass(percent: DebriefFacts.decouplingHighLimit + 0.001), .aboveAerobicThreshold)
    }

    func testFormatterIsLocaleFreeAndRounds() {
        func s(_ v: Double, _ n: DebriefValue.Name, _ u: DebriefValue.Unit) -> String {
            DebriefFormat.string(DebriefValue(name: n, value: v, unit: u), timeZone: F.tz)
        }
        XCTAssertEqual(s(359.6, .pace, .secondsPerKm), "6:00")
        XCTAssertEqual(s(3725, .movingTime, .seconds), "1:02:05")
        XCTAssertEqual(s(5400, .allowedTime, .seconds), "1 h 30 min")
        XCTAssertEqual(s(8_240, .distance, .meters), "8.2 km")
        XCTAssertEqual(s(-0.04, .decoupling, .percent), "0")
        XCTAssertEqual(s(5, .goodLimit, .percent), "5")
        XCTAssertEqual(s(3.24, .decoupling, .percent), "3.2")
        XCTAssertEqual(s(0.015, .paceStep, .fraction), "1.5%")
        XCTAssertEqual(s(.nan, .pace, .secondsPerKm), "-")
        XCTAssertEqual(s(2, .zone, .zone), "2")
        XCTAssertEqual(s(Double(HRZone.z5b.rawValue), .zone, .zone), "5b")
        XCTAssertEqual(s(F.date(week: 0, day: 0).timeIntervalSince1970, .holdEnd, .date),
                       PlanFormatting.day(F.date(week: 0, day: 0), timeZone: F.tz))
    }
}

// MARK: - Contract check

extension XCTestCase {
    /// SPEC F6 acceptance: every line cites facts that exist; every number in
    /// a line is one of its cited facts' values as `DebriefFormat` writes it
    /// (at some precision it allows); every comparison a line states still
    /// holds for the numbers it shows (or the line says "just" because the
    /// shown numbers are equal); comparison words rest on a fact that computed
    /// them; and, when no line is capped away, every fact is stated.
    /// `units` checks the lines as written for that unit preference: the
    /// shown numbers are `DebriefFormat` in those units, so the contract
    /// holds for miles as it does for kilometres.
    func assertDebriefContract(_ d: DebriefFacts, heuristics: DebriefHeuristics = .default,
                               units: UnitPreference = .metric,
                               file: StaticString = #filePath, line: UInt = #line) {
        let lines = DebriefText.lines(d, heuristics: heuristics, units: units)
        XCTAssertLessThanOrEqual(lines.count, max(1, heuristics.maximumLines), file: file, line: line)
        let ids = d.facts.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "fact ids are unique", file: file, line: line)
        for f in d.facts {
            XCTAssertFalse(f.source.isEmpty, f.id, file: file, line: line)
            XCTAssertTrue(f.values.allSatisfy { $0.value.isFinite }, f.id, file: file, line: line)
        }
        func tokens(_ s: String) -> Set<String> {
            let re = try! NSRegularExpression(pattern: "\\d+(?:[.:]\\d+)*")
            return Set(re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } })
        }
        let comparisonWords = try! NSRegularExpression(pattern:
            "\\b(faster|slower|inside|within|above|below|under|over \\d|between \\d|rose|fell|ahead|behind|instead of|held steady)\\b")
        let notFinite = try! NSRegularExpression(pattern: "\\b(nan|inf|infinity)\\b", options: .caseInsensitive)
        /// Facts whose own kind states a direction (the engine's reading, a
        /// change that moves paces or caps a long run).
        func directional(_ f: DebriefFact) -> Bool {
            switch f.kind {
            case .assessment: return true
            case .change(let k): return [.paceTargetsFaster, .paceTargetsSlower, .easyPaceSlower, .longRunHeld].contains(k)
            default: return false
            }
        }
        var cited = Set<String>()
        for l in lines {
            XCTAssertFalse(l.factIDs.isEmpty, l.text, file: file, line: line)
            XCTAssertFalse(l.text.isEmpty, file: file, line: line)
            for id in l.factIDs { XCTAssertTrue(ids.contains(id), "\(id) in \(l.text)", file: file, line: line) }
            cited.formUnion(l.factIDs)
            let facts = d.facts.filter { l.factIDs.contains($0.id) }
            let allowed = facts.flatMap(\.values).reduce(into: Set<String>()) { acc, v in
                for e in 0...DebriefFormat.maximumExtraDecimals(v.unit) {
                    acc.formUnion(tokens(DebriefFormat.string(v, timeZone: d.timeZone, extraDecimals: e, units: units)))
                }
            }
            for t in tokens(l.text) {
                XCTAssertTrue(allowed.contains(t), "number \(t) in \"\(l.text)\" is not in its facts", file: file, line: line)
            }
            // Each stated comparison holds for the shown numbers, which the line shows.
            for c in l.comparisons {
                XCTAssertTrue(l.factIDs.contains(c.factID), file: file, line: line)
                XCTAssertTrue(l.text.contains(c.shownValue) && l.text.contains(c.shownLimit),
                              "\(c.shownValue) / \(c.shownLimit) not shown in \(l.text)", file: file, line: line)
                if c.isBoundary {
                    XCTAssertEqual(c.shownValueNumber, c.shownLimitNumber, l.text, file: file, line: line)
                    XCTAssertTrue(l.text.contains("just "), "boundary without boundary wording: \(l.text)", file: file, line: line)
                } else {
                    XCTAssertTrue(c.relation.holds(c.shownValueNumber, c.shownLimitNumber),
                                  "\(c.shownValue) \(c.relation) \(c.shownLimit) is false as shown: \(l.text)", file: file, line: line)
                }
                // The shown numbers are what the formatter shows for the fact's own values.
                let f = facts.first { $0.id == c.factID }
                let v = f?.values.first { $0.name == c.value }, lim = f?.values.first { $0.name == c.limit }
                XCTAssertTrue(v.map { v in (0...2).contains { DebriefFormat.number(v, extraDecimals: $0, units: units) == c.shownValueNumber } } ?? false,
                              file: file, line: line)
                XCTAssertTrue(lim.map { v in (0...2).contains { DebriefFormat.number(v, extraDecimals: $0, units: units) == c.shownLimitNumber } } ?? false,
                              file: file, line: line)
            }
            // A compared value with both ends (HR band, drift class, fade, time, pace) states its comparison.
            for f in facts where f.comparison != nil && f.comparison != .withinTolerance {
                if case .heartRate = f.kind, f.value(.bandFloor) == nil, f.value(.bandCeiling) == nil { continue }
                if case .cadence = f.kind, (f.value(.cadenceFade) ?? 0) < 0 || DebriefFormat.number(
                    DebriefValue(name: .cadenceFade, value: abs(f.value(.cadenceFade) ?? 0), unit: .percent), units: units) == 0 { continue }
                XCTAssertTrue(l.comparisons.contains { $0.factID == f.id }, "\(f.id) compared but not stated: \(l.text)",
                              file: file, line: line)
            }
            let range = NSRange(l.text.startIndex..., in: l.text)
            // Every phrase comparing a value with a limit is tied to the stated comparison
            // of that value with that limit, with the strict relation the phrase means.
            for v in debriefPhraseViolations(l) { XCTFail(v, file: file, line: line) }
            if comparisonWords.firstMatch(in: l.text, range: range) != nil {
                XCTAssertTrue(facts.contains { $0.comparison != nil || directional($0) },
                              "comparison without a computed comparison: \(l.text)", file: file, line: line)
            }
            XCTAssertNil(notFinite.firstMatch(in: l.text, range: range), l.text, file: file, line: line)
        }
        let all = DebriefText.lines(d, heuristics: DebriefHeuristics(maximumLines: .max), units: units)
        if all.count == lines.count {
            XCTAssertEqual(cited, Set(ids), "every fact is stated", file: file, line: line)
        }
    }
}

// MARK: - Limit phrases tied to their comparisons

private typealias Rel = DebriefStatedComparison.Relation
private typealias Nm = DebriefValue.Name

/// One comparison a phrase must rest on: the value compared, the limit it is
/// compared with, and the only relations the phrase allows.
private struct PhraseNeed {
    let value: Nm, relations: Set<Rel>, limit: Nm
    init(_ value: Nm, _ relations: Set<Rel>, _ limit: Nm) { (self.value, self.relations, self.limit) = (value, relations, limit) }
}

/// Phrase patterns and, for each, the alternative sets of comparisons any one
/// of which the phrase may state (all needs of an alternative must be met).
/// "faster" means strictly less time per km (`lessThan`), "slower" strictly
/// more (`greaterThan`); a range ("inside", "within", "between") needs its
/// floor and its ceiling, each of the fact it states.
private let debriefLimitPhrases: [(pattern: String, alternatives: [[PhraseNeed]])] = {
    let paceRange = [PhraseNeed(.pace, [.atLeast], .targetFastest), PhraseNeed(.pace, [.atMost], .targetSlowest)]
    let hrBand = [PhraseNeed(.heartRate, [.atLeast], .bandFloor), PhraseNeed(.heartRate, [.lessThan], .bandCeiling)]
    let driftRange = [PhraseNeed(.decoupling, [.atLeast], .goodLimit), PhraseNeed(.decoupling, [.atMost], .highLimit)]
    return [
        ("faster than", [[PhraseNeed(.pace, [.lessThan], .targetFastest)]]),
        ("slower than", [[PhraseNeed(.pace, [.greaterThan], .targetSlowest)]]),
        ("inside the", [paceRange, hrBand]),
        ("\\bwithin\\b", [paceRange, hrBand, driftRange]),
        ("between \\d", [driftRange]),
        ("at or above", [[PhraseNeed(.heartRate, [.atLeast], .bandCeiling)], [PhraseNeed(.heartRate, [.atLeast], .bandFloor)],
                         [PhraseNeed(.easyMeanHeartRate, [.atLeast], .easyCap)], [PhraseNeed(.cadenceFade, [.atLeast], .fadeLimit)]]),
        ("(?<!or )\\babove the", [[PhraseNeed(.pace, [.greaterThan], .targetSlowest)], [PhraseNeed(.decoupling, [.greaterThan], .highLimit)]]),
        ("\\bbelow the", [[PhraseNeed(.heartRate, [.lessThan], .bandFloor)]]),
        ("\\bunder (the |its |\\d)", [[PhraseNeed(.decoupling, [.lessThan], .goodLimit)], [PhraseNeed(.heartRate, [.lessThan], .bandCeiling)],
                                      [PhraseNeed(.cadenceFade, [.lessThan], .fadeLimit)], [PhraseNeed(.movingTime, [.lessThan], .minimumTime)],
                                      [PhraseNeed(.allowedTime, [.lessThan], .plannedTime)]]),
        ("\\bover \\d", [[PhraseNeed(.decoupling, [.greaterThan], .highLimit)]]),
        ("instead of", [[PhraseNeed(.allowedTime, [.lessThan], .plannedTime)]]),
    ]
}()

/// Problems with how a line's limit phrases rest on its stated comparisons;
/// empty when every phrase is tied to the comparison of the right value with
/// the right limit, with a strict relation that holds for the shown numbers
/// (or, for a boundary, "just " before the phrase).
private func debriefPhraseViolations(_ l: DebriefLine) -> [String] {
    // "above the aerobic threshold" names the drift class, stated as "over 10%".
    let plain = l.text.replacingOccurrences(of: "above the aerobic threshold", with: String(repeating: "_", count: 27))
    let text = plain as NSString
    func shows(_ window: String, _ token: String) -> Bool {
        let re = try! NSRegularExpression(pattern: "(?<![\\d.:])" + NSRegularExpression.escapedPattern(for: token) + "(?!\\d|[.:]\\d)")
        return re.firstMatch(in: window, range: NSRange(window.startIndex..., in: window)) != nil
    }
    var matches: [(location: Int, alternatives: [[PhraseNeed]], pattern: String)] = []
    for (pattern, alternatives) in debriefLimitPhrases {
        let re = try! NSRegularExpression(pattern: pattern)
        for m in re.matches(in: plain, range: NSRange(location: 0, length: text.length)) {
            matches.append((m.range.location, alternatives, pattern))
        }
    }
    matches.sort { $0.location < $1.location }
    var used = Set<Int>()
    var problems: [String] = []
    for m in matches {
        // The clause the phrase opens: up to the next comma, semicolon or sentence end.
        var window = text.substring(from: m.location)
        if let end = window.range(of: "(, |; |\\. |\\.$)", options: .regularExpression) { window = String(window[..<end.lowerBound]) }
        let before = text.substring(to: m.location)
        var matched = false
        for alt in m.alternatives {
            var picks: [Int] = []
            for need in alt {
                guard let i = l.comparisons.indices.first(where: { i in
                    let c = l.comparisons[i]
                    guard !used.contains(i), !picks.contains(i), c.value == need.value, c.limit == need.limit,
                          need.relations.contains(c.relation), shows(window, c.shownLimit) else { return false }
                    return c.isBoundary ? before.hasSuffix("just ") : c.relation.holds(c.shownValueNumber, c.shownLimitNumber)
                }) else { break }
                picks.append(i)
            }
            if picks.count == alt.count { used.formUnion(picks); matched = true; break }
        }
        if !matched { problems.append("\"\(m.pattern)\" at \(m.location) is not tied to a stated comparison with the right fact, strict relation and limit: \(l.text)") }
    }
    return problems
}

final class DebriefContractStrictnessTests: XCTestCase {
    private func cmp(_ r: Rel, _ value: Nm = .pace, _ limit: Nm = .targetFastest, shown: (String, Double) = ("6:10", 370),
                     limitShown: (String, Double) = ("6:00", 360), boundary: Bool = false) -> DebriefStatedComparison {
        DebriefStatedComparison(factID: "pace", value: value, relation: r, limit: limit, shownValue: shown.0, shownLimit: limitShown.0,
                                shownValueNumber: shown.1, shownLimitNumber: limitShown.1, isBoundary: boundary)
    }
    private func line(_ text: String, _ comparisons: [DebriefStatedComparison]) -> DebriefLine {
        DebriefLine(topic: .run, text: text, factIDs: ["pace"], comparisons: comparisons)
    }

    func testFasterIsStrictlyLessTimePerKm() {
        let text = "Pace was 5:50/km over the main part, faster than the 6:00 to 6:30/km target."
        let fast = cmp(.lessThan, shown: ("5:50", 350))
        XCTAssertEqual(debriefPhraseViolations(line(text, [fast])), [])
        // Equal shown paces without boundary wording are not "faster".
        let equal = cmp(.lessThan, shown: ("6:00", 360))
        XCTAssertFalse(debriefPhraseViolations(line(text, [equal])).isEmpty)
        // A slower pace is not faster.
        let slower = cmp(.lessThan, shown: ("6:10", 370))
        XCTAssertFalse(debriefPhraseViolations(line(text, [slower])).isEmpty)
        // A non-strict relation does not back "faster".
        let nonStrict = cmp(.atMost, shown: ("5:50", 350))
        XCTAssertFalse(debriefPhraseViolations(line(text, [nonStrict])).isEmpty)
    }

    func testSlowerIsStrictlyMoreTimePerKmAndTiedToTheSlowEnd() {
        let text = "Pace was 6:40/km over the main part, slower than the 6:00 to 6:30/km target."
        let slow = cmp(.greaterThan, .pace, .targetSlowest, shown: ("6:40", 400), limitShown: ("6:30", 390))
        XCTAssertEqual(debriefPhraseViolations(line(text, [slow])), [])
        XCTAssertFalse(debriefPhraseViolations(line(text, [cmp(.atLeast, .pace, .targetSlowest, shown: ("6:40", 400), limitShown: ("6:30", 390))])).isEmpty)
        // A comparison with the wrong limit (the fast end) or another value does not back it.
        XCTAssertFalse(debriefPhraseViolations(line(text, [cmp(.greaterThan, .pace, .targetFastest, shown: ("6:40", 400), limitShown: ("6:30", 390))])).isEmpty)
        XCTAssertFalse(debriefPhraseViolations(line(text, [cmp(.greaterThan, .heartRate, .targetSlowest, shown: ("6:40", 400), limitShown: ("6:30", 390))])).isEmpty)
        // A limit the phrase does not show is not tied to it.
        XCTAssertFalse(debriefPhraseViolations(line(text, [cmp(.greaterThan, .pace, .targetSlowest, shown: ("6:40", 400), limitShown: ("7:30", 450))])).isEmpty)
    }

    func testWithinNeedsBothEndsOfTheStatedRange() {
        let text = "Pace was 6:10/km over the main part, within the 6:00 to 6:30/km target."
        let lo = cmp(.atLeast, .pace, .targetFastest)
        let hi = cmp(.atMost, .pace, .targetSlowest, limitShown: ("6:30", 390))
        XCTAssertEqual(debriefPhraseViolations(line(text, [lo, hi])), [])
        XCTAssertFalse(debriefPhraseViolations(line(text, [lo])).isEmpty, "one end is not a range")
        // Any relation does not do: a strict "faster" relation on the fast end is not "within".
        XCTAssertFalse(debriefPhraseViolations(line(text, [cmp(.lessThan, .pace, .targetFastest), hi])).isEmpty)
        // Outside the range as shown.
        XCTAssertFalse(debriefPhraseViolations(line(text, [lo, cmp(.atMost, .pace, .targetSlowest, shown: ("6:40", 400), limitShown: ("6:30", 390))])).isEmpty)
    }

    func testBoundaryNeedsJustBeforeThePhrase() {
        let text = "Pace was 6:00/km over the main part, faster than the 6:00 to 6:30/km target."
        let c = cmp(.lessThan, shown: ("6:00", 360), boundary: true)
        XCTAssertFalse(debriefPhraseViolations(line(text, [c])).isEmpty)
        XCTAssertEqual(debriefPhraseViolations(line(text.replacingOccurrences(of: "faster", with: "just faster"), [c])), [])
    }
}
