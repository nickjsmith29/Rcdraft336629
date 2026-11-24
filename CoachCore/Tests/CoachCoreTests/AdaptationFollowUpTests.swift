import XCTest
@testable import CoachCore

// Follow-ups from the #47 reviews (issue #51): hard sessions run on another
// day, `AdaptationState` persistence, hold shortfalls posted once, and the
// interplay of pain swaps, holds and guardrail repair. Synthetic plans only.
final class AdaptationFollowUpTests: XCTestCase {
    typealias F = AdaptFixture

    private func find(_ id: String, _ plan: [PlannedWorkout]) -> PlannedWorkout? { plan.first { $0.id == id } }

    /// A run of `w` started on another day and named for `w` by the app.
    private func run(_ w: PlannedWorkout, on day: Int, week: Int, _ spec: F.RunSpec = F.RunSpec()) -> CompletedRun {
        var moved = w
        moved.date = F.date(week: week, day: day)
        var r = F.run(for: moved, spec)
        r.plannedWorkoutID = w.id
        return r
    }

    private func assertNoStackedHardDays(_ o: AdaptationOutcome, file: StaticString = #filePath, line: UInt = #line) {
        let cal = PlanCalendar.calendar(timeZone: F.tz)
        let hard = (o.history + o.plan).filter { $0.kind.isQuality || $0.kind == .race }
            .map { cal.startOfDay(for: $0.date) }.sorted()
        for (a, b) in zip(hard, hard.dropFirst()) {
            XCTAssertGreaterThan(cal.dateComponents([.day], from: a, to: b).day!, 1, "hard days \(a) and \(b)",
                                 file: file, line: line)
        }
    }

    // MARK: A hard session run on another day (#51 item 1)

    /// Tue threshold t0, Thu threshold q0, Sat long, Sun easy.
    private var twoQualityWeek: [PlannedWorkout] {
        [F.threshold("t0", week: 0, day: 1), F.threshold("q0", week: 0, day: 3),
         // 59 min: within 10% of the 54-minute sessions before it (3.5 rule 1).
         F.long("l0", week: 0, day: 5, minutes: 59), F.easy("e0b", week: 0, day: 6, minutes: 45)]
    }

    func testQualityRunADayLateTurnsTheNextDaysQualityEasy() throws {
        let plan = twoQualityWeek
        let r = run(plan[0], on: 2, week: 0)   // Tuesday's session, run on Wednesday
        let o = AdaptationEngine.processRun(r, state: AdaptationState(), plan: plan, history: [], context: F.context())
        XCTAssertEqual(o.assessment?.plannedWorkoutID, "t0")
        XCTAssertEqual(o.history.map(\.date), [F.date(week: 0, day: 2)], "logged on the day it was run")

        let q0 = try XCTUnwrap(find("q0", o.plan))
        XCTAssertEqual(q0.kind, .easy)
        XCTAssertEqual(q0.durationSeconds, plan[1].durationSeconds, "same length: no load added or removed")
        XCTAssertEqual(q0.date, plan[1].date)
        XCTAssertEqual(q0.prescription?.segments.map(\.intensity), [.easy])
        XCTAssertEqual(find("l0", o.plan), plan[2])

        let swap = try XCTUnwrap(o.changes.first { $0.kind == .qualitySwappedToEasy })
        XCTAssertEqual(swap.workoutIDs, ["q0"])
        XCTAssertTrue(swap.rule.contains("F4"))
        let t = try XCTUnwrap(swap.triggers.first)
        XCTAssertEqual(t.metric, .daysBetweenHardDays)
        XCTAssertEqual(t.value, 1)
        XCTAssertEqual(t.expectedLow, 2)
        XCTAssertEqual(t.unit, .days)
        XCTAssertEqual(t.sourceID, r.activity.id)
        XCTAssertTrue(swap.explanation.contains("planned for"), swap.explanation)
        assertNoStackedHardDays(o)
        assertAdaptationSound([o])
    }

    func testQualityRunOnTheDayOfTheNextQualityTurnsThatOneEasy() {
        let plan = twoQualityWeek
        let o = AdaptationEngine.processRun(run(plan[0], on: 3, week: 0), state: AdaptationState(), plan: plan, history: [],
                                            context: F.context())
        XCTAssertEqual(find("q0", o.plan)?.kind, .easy)
        XCTAssertEqual(o.changes.first { $0.kind == .qualitySwappedToEasy }?.triggers.first?.value, 0)
        assertNoStackedHardDays(o)
    }

    func testQualityRunEarlyAgainstItsOwnDayIsJudgedByTheDayRun() {
        // Thursday's q0 run on Monday: Tuesday's t0 is now the day after a hard day.
        let plan = twoQualityWeek
        let o = AdaptationEngine.processRun(run(plan[1], on: 0, week: 0), state: AdaptationState(), plan: plan, history: [],
                                            context: F.context())
        XCTAssertEqual(o.assessment?.plannedWorkoutID, "q0")
        XCTAssertEqual(find("t0", o.plan)?.kind, .easy)
        XCTAssertNil(find("q0", o.plan))
        assertNoStackedHardDays(o)
    }

    func testQualityRunTwoDaysFromTheNextHardDayChangesNothing() {
        // Tuesday's t0 run on Wednesday, the next quality on Friday.
        let plan = [F.threshold("t0", week: 0, day: 1), F.threshold("q0", week: 0, day: 4),
                    F.easy("e0b", week: 0, day: 6, minutes: 45)]
        let o = AdaptationEngine.processRun(run(plan[0], on: 2, week: 0), state: AdaptationState(), plan: plan, history: [],
                                            context: F.context())
        XCTAssertEqual(find("q0", o.plan), plan[1])
        XCTAssertFalse(o.changes.contains { $0.kind == .qualitySwappedToEasy })
    }

    func testQualityRunOnItsPlannedDayChangesNothing() {
        let plan = twoQualityWeek
        let on = AdaptationEngine.processRun(run(plan[0], on: 1, week: 0), state: AdaptationState(), plan: plan,
                                             history: [], context: F.context())
        XCTAssertEqual(find("q0", on.plan), plan[1])
        XCTAssertFalse(on.changes.contains { $0.kind == .qualitySwappedToEasy })
    }

    func testARaceIsNeverChangedByAQualityRunOnTheDayBefore() {
        let race = PlannedWorkout(id: "r", date: F.date(week: 0, day: 3, hour: 8), kind: .race, durationSeconds: 90 * 60)
        let plan = [F.threshold("t0", week: 0, day: 1), race]
        let o = AdaptationEngine.processRun(run(plan[0], on: 2, week: 0), state: AdaptationState(), plan: plan, history: [],
                                            context: F.context())
        XCTAssertEqual(find("r", o.plan), race)
        XCTAssertFalse(o.changes.contains { $0.kind == .qualitySwappedToEasy })
    }

    // MARK: AdaptationState persistence (#51 item 2)

    private func json(_ state: AdaptationState) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(state)
    }

    private func roundTrip(_ state: AdaptationState) throws -> AdaptationState {
        try JSONDecoder().decode(AdaptationState.self, from: try json(state))
    }

    /// Two quality sessions behind (a hold), a pain check-in (a freeze and a
    /// swap), long runs with decoupling, then the rest of three weeks.
    private func events(_ plan: [PlannedWorkout]) -> (before: [AdaptationReplay.Event], after: [AdaptationReplay.Event]) {
        func s(_ id: String) -> PlannedWorkout { plan.first { $0.id == id }! }
        let before: [AdaptationReplay.Event] = [
            .run(F.run(for: s("t0"), F.RunSpec(pace: 1.05))),
            .run(F.run(for: s("e0a"))),
            .run(F.run(for: s("l0"), F.RunSpec(drift: 0.02))),
            .run(F.run(for: s("e0b"))),
            .run(F.run(for: s("t1"), F.RunSpec(pace: 1.05))),
            .run(F.run(for: s("e1a"))),
            .run(F.run(for: s("l1"))),
            .painCheckIn(PainCheckIn(date: F.date(week: 1, day: 5, hour: 10), score: 5)),
        ]
        let after: [AdaptationReplay.Event] = [
            .run(F.run(for: s("e1b"))),
            .run(F.run(for: s("e2a"))),
            .painCheckIn(PainCheckIn(date: F.date(week: 2, day: 3, hour: 10), score: 1)),
            .run(F.run(for: s("l2"))),
            .day(F.date(week: 3, day: 0, hour: 6)),
        ]
        return (before, after)
    }

    func testStateRoundTripsThroughJSONAndReplayContinuesTheSame() throws {
        let plan = F.weeks(0..<3, easyMinutes: { _ in (55, 45) })
        let context = F.context(tracksPain: true)
        let (before, after) = events(plan)
        let first = AdaptationReplay.replay(before, plan: plan, context: context)
        let mid = try XCTUnwrap(first.last).outcome
        // The state holds something of every kind worth storing.
        XCTAssertFalse(mid.state.holds.isEmpty, "a hold after two sessions behind")
        XCTAssertFalse(mid.state.freezes.isEmpty, "a freeze after the check-in")
        XCTAssertNotNil(mid.state.appliedPainResponse?.swap)
        XCTAssertNotNil(mid.state.lastAppliedCheckIn)
        XCTAssertEqual(mid.state.assessments.count, 7)
        XCTAssertTrue(mid.state.assessments.contains { $0.metrics.decoupling != nil })
        XCTAssertTrue(mid.state.assessments.contains { $0.kind.isQuality })
        XCTAssertFalse(mid.state.longRuns.isEmpty)
        XCTAssertNotEqual(mid.state.qualityPaceFactor, 1)
        XCTAssertEqual(mid.history.count, 7)

        let decoded = try roundTrip(mid.state)
        XCTAssertEqual(decoded, mid.state)
        XCTAssertEqual(try json(decoded), try json(mid.state), "encoding is stable")

        // Carrying on from the decoded state gives exactly what carrying on from the original gives.
        let fromOriginal = AdaptationReplay.replay(after, plan: mid.plan, history: mid.history, state: mid.state, context: context)
        let fromDecoded = AdaptationReplay.replay(after, plan: mid.plan, history: mid.history, state: decoded, context: context)
        XCTAssertEqual(fromDecoded, fromOriginal)
        XCTAssertGreaterThan(fromDecoded.count, after.count)
        // And every state along the way round-trips too.
        for step in first + fromDecoded {
            XCTAssertEqual(try roundTrip(step.outcome.state), step.outcome.state)
        }
    }

    func testRecordedHoldShortfallsRoundTrip() throws {
        let start = F.date(week: 1, day: 0, hour: 0)
        let state = AdaptationState(holds: [VolumeHold(interval: DateInterval(start: start, duration: 7 * 86_400),
                                                       level: 100 * 60, longRunFloorSeconds: 51 * 60)])
        let o = AdaptationEngine.processDay(asOf: F.date(week: 1, day: 0, hour: 6), state: state, plan: F.weeks(0..<2),
                                            history: [], context: wideShare)
        XCTAssertFalse(o.state.reportedHoldShortfalls.isEmpty)
        let decoded = try roundTrip(o.state)
        XCTAssertEqual(decoded, o.state)
        let next = AdaptationEngine.processDay(asOf: F.date(week: 1, day: 1, hour: 6), state: decoded, plan: o.plan,
                                               history: o.history, context: wideShare)
        XCTAssertEqual(next.changes, [], "a restored state still knows the shortfall was posted")
    }

    func testEmptyStoredStateDecodesToTheDefault() throws {
        let decoded = try JSONDecoder().decode(AdaptationState.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, AdaptationState())
        XCTAssertEqual(try roundTrip(AdaptationState()), AdaptationState())
    }

    func testStateFromANewerFormatIsRefused() {
        let data = Data("{\"formatVersion\": \(AdaptationState.formatVersion + 1)}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AdaptationState.self, from: data))
    }

    func testUnknownStoredValuesAreRefusedNotGuessed() throws {
        let plan = F.weeks(0..<1)
        let o = AdaptationEngine.processRun(F.run(for: plan[0]), state: AdaptationState(), plan: plan, history: [],
                                            context: F.context())
        let text = try XCTUnwrap(String(data: try json(o.state), encoding: .utf8))
        XCTAssertTrue(text.contains("\"quality.threshold\""), text)
        for (from, to) in [("\"quality.threshold\"", "\"quality.sprint\""), ("\"quality.threshold\"", "\"jog\""),
                           ("\"signal\":\"onTrack\"", "\"signal\":\"sideways\"")] where text.contains(from) {
            let broken = Data(text.replacingOccurrences(of: from, with: to).utf8)
            XCTAssertThrowsError(try JSONDecoder().decode(AdaptationState.self, from: broken), to)
        }
    }

    // MARK: Hold shortfalls posted once (#51 item 3)

    /// The long-run share guardrail is lifted so the hold alone shapes the week.
    private let wideShare = AdaptationContext(zones: F.zones, timeZone: F.tz, tracksPain: false,
                                              guardrails: GuardrailLimits(maxLongRunShare: 1))

    private func hold(level: Double, floorMinutes: Double? = 51) -> VolumeHold {
        VolumeHold(interval: DateInterval(start: F.date(week: 1, day: 0, hour: 0), duration: 7 * 86_400),
                   level: level, longRunFloorSeconds: floorMinutes.map { $0 * 60 })
    }

    func testShortfallIsPostedAgainOnlyWhenItChanges() throws {
        let plan = F.weeks(0..<2)
        let first = AdaptationEngine.processDay(asOf: F.date(week: 1, day: 0, hour: 6),
                                                state: AdaptationState(holds: [hold(level: 100 * 60)]),
                                                plan: plan, history: [], context: wideShare)
        let posted = try XCTUnwrap(first.changes.first { $0.kind == .holdShortfall })
        XCTAssertEqual(first.state.reportedHoldShortfalls, [posted])

        // Unchanged on the next events (Tuesday before its 07:00 threshold):
        // not posted, still unsatisfied.
        var o = first
        for h in 1...3 {
            o = AdaptationEngine.processDay(asOf: F.date(week: 1, day: 1, hour: h), state: o.state, plan: o.plan,
                                            history: o.history, context: wideShare)
            XCTAssertFalse(o.holdsSatisfied)
            XCTAssertFalse(o.changes.contains { $0.kind == .holdShortfall }, "hour \(h)")
        }

        // Changed (a lower level leaves more over it): posted again, with the new numbers.
        var lower = o.state
        lower.holds = [hold(level: 97 * 60)]
        let changed = AdaptationEngine.processDay(asOf: F.date(week: 1, day: 1, hour: 4), state: lower, plan: o.plan,
                                                  history: o.history, context: wideShare)
        let again = try XCTUnwrap(changed.changes.first { $0.kind == .holdShortfall })
        XCTAssertNotEqual(again, posted)
        XCTAssertEqual(again.triggers.last.map { $0.value - ($0.expectedHigh ?? 0) }, 8 * 60)

        // Gone (the hold ended): the record clears, so a later shortfall is new again.
        var ended = changed.state
        ended.holds = []
        let clear = AdaptationEngine.processDay(asOf: F.date(week: 1, day: 1, hour: 5), state: ended, plan: changed.plan,
                                                history: changed.history, context: wideShare)
        XCTAssertTrue(clear.holdsSatisfied)
        XCTAssertEqual(clear.state.reportedHoldShortfalls, [])
        var back = clear.state
        back.holds = [hold(level: 97 * 60)]
        let reappeared = AdaptationEngine.processDay(asOf: F.date(week: 1, day: 1, hour: 6), state: back, plan: clear.plan,
                                                     history: clear.history, context: wideShare)
        XCTAssertTrue(reappeared.changes.contains { $0.kind == .holdShortfall })
    }

    func testShortfallInAWeekOfUnknownVolumeCitesNoVolume() throws {
        // Measured by distance, and the synthetic sessions carry none.
        let byDistance = AdaptationContext(zones: F.zones, timeZone: F.tz, tracksPain: false,
                                           guardrails: GuardrailLimits(measure: .distance))
        let o = AdaptationEngine.processDay(asOf: F.date(week: 1, day: 0, hour: 6),
                                            state: AdaptationState(holds: [hold(level: 30_000)]),
                                            plan: F.weeks(0..<2), history: [], context: byDistance)
        XCTAssertFalse(o.holdsSatisfied)
        let s = try XCTUnwrap(o.changes.first { $0.kind == .holdShortfall })
        XCTAssertEqual(s.triggers.count, 1)
        let t = try XCTUnwrap(s.triggers.first)
        XCTAssertEqual(t.metric, .unmeasuredSessions, "not a volume: none was measured")
        XCTAssertEqual(t.unit, .count)
        XCTAssertEqual(t.value, 4, "the four sessions of the week with no distance")
        XCTAssertEqual(t.expectedHigh, 0)
        XCTAssertEqual(t.sourceID, "t1")
        XCTAssertFalse(s.triggers.contains { $0.metric == .weeklyVolume })
        XCTAssertTrue(t.detail.contains("no known distance"), t.detail)
        XCTAssertTrue(s.explanation.contains("can't be measured"), s.explanation)

        // The debrief still reads it as a week it can't check, not a week over.
        let facts = DebriefFacts.changeFacts(o, previous: nil, limits: .default, measure: .distance, heuristics: .default)
        let f = try XCTUnwrap(facts.first { $0.id == "change.holdShortfall" })
        XCTAssertEqual(f.value(.uncheckedWeeks), 1)
        XCTAssertNil(f.value(.overHeldLevel))

        let next = AdaptationEngine.processDay(asOf: F.date(week: 1, day: 1, hour: 6), state: o.state, plan: o.plan,
                                               history: o.history, context: byDistance)
        XCTAssertEqual(next.changes, [], "posted once")
        XCTAssertFalse(next.holdsSatisfied)
    }

    // MARK: Pain swaps, holds and guardrails (#51 items 6 and docs)

    func testPainSwappedSessionCanBeTrimmedAsAnEasyRunButNeverBack() throws {
        // Week 0 ran 184 min; week 1 plans 214 min, with its threshold turned
        // easy by a pain check-in on Monday. The freeze holds week 1 to week 0's
        // 184 min, so 30 min come off the easy runs, the swapped one included.
        let history = F.weeks(0..<1, easyMinutes: { _ in (40, 30) })
        let o = AdaptationEngine.processCheckIn(PainCheckIn(date: F.date(week: 1, day: 0, hour: 8), score: 5),
                                                state: AdaptationState(), plan: F.weeks(1..<2), history: history,
                                                context: F.context(tracksPain: true))
        XCTAssertEqual(o.changes.first { $0.kind == .qualitySwappedToEasy }?.workoutIDs, ["t1"])
        let t1 = try XCTUnwrap(find("t1", o.plan))
        XCTAssertEqual(t1.kind, .easy, "still easy: a trim never restores quality")
        XCTAssertLessThan(t1.durationSeconds, 54 * 60, "trimmed as an easy run")
        XCTAssertGreaterThanOrEqual(t1.durationSeconds, PlanHeuristics.minimumEasyRunSeconds)
        XCTAssertTrue(o.changes.contains { $0.kind == .sessionShortened && $0.workoutIDs.contains("t1") })
        XCTAssertLessThanOrEqual(F.weekVolume(1, o.plan), 184 * 60 + 1e-6)
        XCTAssertTrue(o.guardrailReport.passed, "\(o.guardrailReport.violations.map(\.explanation))")

        // A hold trims it the same way; it never comes back as quality.
        let held = AdaptationEngine.processDay(asOf: F.date(week: 1, day: 0, hour: 9),
                                               state: { var s = o.state; s.holds = [hold(level: 150 * 60)]; return s }(),
                                               plan: o.plan, history: o.history, context: F.context(tracksPain: true))
        let after = try XCTUnwrap(find("t1", held.plan))
        XCTAssertEqual(after.kind, .easy)
        XCTAssertLessThanOrEqual(after.durationSeconds, t1.durationSeconds)
        XCTAssertLessThanOrEqual(F.weekVolume(1, held.plan), 150 * 60 + 1e-6)
        assertAdaptationSound([o, held])
    }

    func testLongRunShareGuardrailWinsOverTheHoldFloor() throws {
        // A 100 min hold with a 51 min floor leaves the threshold (54) and the
        // long run (51): 49% of the week. The 35% share guardrail then cuts the
        // long run below the hold's floor, which is allowed (it only lowers load).
        let o = AdaptationEngine.processDay(asOf: F.date(week: 1, day: 0, hour: 6),
                                            state: AdaptationState(holds: [hold(level: 100 * 60)]),
                                            plan: F.weeks(0..<2), history: [], context: F.context())
        let l1 = try XCTUnwrap(find("l1", o.plan))
        XCTAssertLessThan(l1.durationSeconds, 51 * 60)
        let total = F.weekVolume(1, o.plan)
        XCTAssertLessThanOrEqual(l1.durationSeconds, 0.35 * total + 1e-6)
        XCTAssertTrue(o.guardrailReport.passed)
        XCTAssertTrue(o.holdsSatisfied, "the guardrail's cut also brings the week under the hold")
        XCTAssertEqual(find("t1", o.plan)?.durationSeconds, 54 * 60)
    }

    func testMarathonLongRunShareCeilingStillWinsOverTheHoldFloor() throws {
        // The same hold in a marathon plan (a marathon race in week 2): the
        // long run may take up to 45% of the week (3.5 rule 5, #62), so the
        // repair cuts it less than in the test above, but still below the
        // hold's floor, since 49% is over the marathon ceiling too.
        let race = PlannedWorkout(id: "race", date: F.date(week: 2, day: 6, hour: 8), kind: .race,
                                  durationSeconds: 210 * 60, distanceMeters: Distance.marathon)
        let o = AdaptationEngine.processDay(asOf: F.date(week: 1, day: 0, hour: 6),
                                            state: AdaptationState(holds: [hold(level: 100 * 60)]),
                                            plan: F.weeks(0..<2) + [race], history: [], context: F.context())
        let l1 = try XCTUnwrap(find("l1", o.plan))
        XCTAssertLessThan(l1.durationSeconds, 51 * 60)
        let total = F.weekVolume(1, o.plan)
        XCTAssertLessThanOrEqual(l1.durationSeconds, 0.45 * total + 1e-6)
        XCTAssertGreaterThan(l1.durationSeconds, 0.35 * total, "the marathon ceiling, not the usual share, sets the cut")
        XCTAssertTrue(o.guardrailReport.passed)
        XCTAssertTrue(o.guardrailReport.informationFlags.contains { $0.rule == .longRunShare && $0.workoutID == "l1" })
        XCTAssertTrue(o.holdsSatisfied)
        XCTAssertEqual(find("t1", o.plan)?.durationSeconds, 54 * 60)
    }
    // MARK: Power-to-HR against the runner's own history (#51 item 4)

    /// `r` with power at `ratio` watts per beat of its heart rate, sample by sample.
    private func withPower(_ r: CompletedRun, ratio: Double) -> CompletedRun {
        var out = r
        out.activity.samples = r.activity.samples.map { s in
            var s = s
            s.power = s.heartRate.map { $0 * ratio }
            return s
        }
        return out
    }

    /// Assessments of threshold sessions t0 to t2 at `ratio`, one a week.
    private func thresholdHistory(ratio: Double, weeks: Range<Int> = 0..<3) -> [RunAssessment] {
        F.weeks(weeks).filter { $0.kind.isQuality }.map {
            RunClassifier.assess(withPower(F.run(for: $0), ratio: ratio), planned: $0, zones: F.zones)
        }
    }

    func testPowerToHeartRateBaselineUsesOnlyRecentSessionsOfTheSameKind() throws {
        let history = thresholdHistory(ratio: 1.6)
        let now = F.date(week: 3, day: 1)
        let base = try XCTUnwrap(RunClassifier.powerToHeartRateBaseline(kind: .quality(.threshold), before: now, history: history))
        XCTAssertEqual(base.mean, 1.6, accuracy: 1e-9)
        XCTAssertEqual(base.count, 3)

        // Too few, another kind, unplanned, without power, or too long ago: no comparison.
        XCTAssertNil(RunClassifier.powerToHeartRateBaseline(kind: .quality(.threshold), before: now, history: Array(history.prefix(2))))
        XCTAssertNil(RunClassifier.powerToHeartRateBaseline(kind: .quality(.intervals), before: now, history: history))
        XCTAssertNil(RunClassifier.powerToHeartRateBaseline(kind: .quality(.threshold), before: F.date(week: 0, day: 1), history: history),
                     "only sessions before the run count")
        let easy = F.weeks(0..<3).filter { $0.kind == .easy }.map {
            RunClassifier.assess(withPower(F.run(for: $0), ratio: 1.6), planned: $0, zones: F.zones)
        }
        XCTAssertNil(RunClassifier.powerToHeartRateBaseline(kind: .quality(.threshold), before: now, history: easy))
        let unplanned = F.weeks(0..<3).filter { $0.kind.isQuality }.map {
            RunClassifier.assess(withPower(F.run(for: $0), ratio: 1.6), planned: nil, zones: F.zones)
        }
        XCTAssertNil(RunClassifier.powerToHeartRateBaseline(kind: .quality(.threshold), before: now, history: unplanned))
        XCTAssertNil(RunClassifier.powerToHeartRateBaseline(kind: .quality(.threshold), before: now,
                                                            history: F.weeks(0..<3).filter { $0.kind.isQuality }.map {
                                                                RunClassifier.assess(F.run(for: $0), planned: $0, zones: F.zones)
                                                            }), "no power stream")
        let late = F.date(week: 9, day: 0)   // 42 days after week 3's Monday
        XCTAssertNil(RunClassifier.powerToHeartRateBaseline(kind: .quality(.threshold), before: late, history: history))
        XCTAssertNil(RunClassifier.powerToHeartRateBaseline(kind: .quality(.threshold), before: now, history: history,
                                                            limits: AdaptationLimits(powerHistoryRuns: 0)))

        // The most recent sessions only: an old high level drops out.
        let mixed = thresholdHistory(ratio: 2.0, weeks: 0..<1) + thresholdHistory(ratio: 1.6, weeks: 1..<4)
        let recent = try XCTUnwrap(RunClassifier.powerToHeartRateBaseline(kind: .quality(.threshold), before: F.date(week: 4, day: 1),
                                                                         history: mixed, limits: AdaptationLimits(powerHistoryRuns: 3)))
        XCTAssertEqual(recent.mean, 1.6, accuracy: 1e-9)
    }

    func testPowerToHeartRateBelowTheRunnersOwnLevelIsAStrainMarker() throws {
        let history = thresholdHistory(ratio: 1.6)
        let t3 = try XCTUnwrap(F.weeks(3..<4).first { $0.kind.isQuality })
        // Faster than the target at heart rate in band: ahead, unless power-to-HR fell.
        let fast = F.run(for: t3, F.RunSpec(pace: 0.97))
        let steady = RunClassifier.assess(withPower(fast, ratio: 1.6 * 0.97), planned: t3, zones: F.zones, history: history)
        XCTAssertEqual(steady.signal, .ahead, "a 3% dip is under the 5% limit")
        XCTAssertFalse(steady.triggers.contains { $0.metric == .powerToHeartRateDrop })

        let dropped = RunClassifier.assess(withPower(fast, ratio: 1.6 * 0.9), planned: t3, zones: F.zones, history: history)
        let marker = try XCTUnwrap(dropped.triggers.first { $0.metric == .powerToHeartRateDrop })
        XCTAssertEqual(marker.value, 10, accuracy: 1e-6)
        XCTAssertEqual(marker.expectedHigh, 5)
        XCTAssertEqual(marker.unit, .percent)
        XCTAssertTrue(marker.detail.contains("heuristic"), marker.detail)
        XCTAssertEqual(dropped.signal, .onTrack, "a strain marker rules out ahead")

        // With heart rate above the band too, it is overreached.
        let hot = RunClassifier.assess(withPower(F.run(for: t3, F.RunSpec(hr: .high)), ratio: 1.6 * 0.9), planned: t3,
                                       zones: F.zones, history: history)
        XCTAssertEqual(hot.signal, .overreached)

        // No history, or no power on this run: nothing to compare.
        XCTAssertFalse(RunClassifier.assess(withPower(fast, ratio: 1.4), planned: t3, zones: F.zones).triggers
            .contains { $0.metric == .powerToHeartRateDrop })
        XCTAssertFalse(RunClassifier.assess(fast, planned: t3, zones: F.zones, history: history).triggers
            .contains { $0.metric == .powerToHeartRateDrop })
    }

    func testEngineComparesPowerToHeartRateWithTheRunnersEarlierSessions() throws {
        let plan = F.weeks(0..<4)
        // Every session is run, so no week is low: a low week would turn the
        // quality sessions after it easy (SPEC 3.5 rule 6, #64).
        let events = plan.map { w -> AdaptationReplay.Event in
            w.kind.isQuality ? .run(withPower(F.run(for: w), ratio: w.id == "t3" ? 1.6 * 0.92 : 1.6)) : .run(F.run(for: w))
        }
        let steps = AdaptationReplay.replay(events, plan: plan, context: F.context())
        let assessments = steps.compactMap(\.outcome.assessment).filter { $0.activityID.hasPrefix("run-t") }
        XCTAssertEqual(assessments.map(\.activityID), ["run-t0", "run-t1", "run-t2", "run-t3"])
        XCTAssertTrue(assessments.prefix(3).allSatisfy { !$0.triggers.contains { $0.metric == .powerToHeartRateDrop } })
        let drop = try XCTUnwrap(assessments.last?.triggers.first { $0.metric == .powerToHeartRateDrop })
        XCTAssertEqual(drop.value, 8, accuracy: 1e-6)
        XCTAssertEqual(drop.sourceID, "run-t3")
    }
    // MARK: A low week plus a pain freeze (#51 item 5, #64)

    /// After a low week and a pain freeze, a week that can't meet the
    /// guardrails with its quality sessions whole turns them into easy runs
    /// before it is trimmed, so every outcome passes (no ramp-quality
    /// violation is left); the plan then grows back to the original plan,
    /// never above it, and the freeze holds (SPEC 3.5 rule 6, #64).
    func testLowFrozenWeekGrowsBackToThePlanAndNeverAddsLoad() throws {
        // A synthetic 4-day runner, half marathon in 16 weeks (as in the replay tests).
        let start = F.date(week: 8, day: 0, hour: 0)
        let history = PlanFixture.easyWeeks(Array(repeating: 240, count: 8), prefix: "h")
        let race = PlanCalendar.calendar(timeZone: F.tz).date(byAdding: .day, value: 15 * 7 + 6, to: start)!
            .addingTimeInterval(8 * 3600)
        let five = 24.0 * 60
        let input = PlanInput(raceDistanceMeters: Distance.halfMarathon, raceDate: race, startDate: start,
                              trainingDays: [.monday, .wednesday, .friday, .sunday], longRunDay: .sunday,
                              recentWeeklySeconds: 240 * 60, recentLongRunSeconds: 80 * 60, heartRateZones: F.zones,
                              easyPace: EasyPaceSample(secondsPerKm: 360, heartRate: 138),
                              fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: five),
                              predictedRaceSeconds: RacePredictor.riegel(knownMeters: Distance.fiveK, knownSeconds: five,
                                                                         targetMeters: Distance.halfMarathon))
        let original = try XCTUnwrap(PlanBuilder.build(input, history: history, timeZone: F.tz).plan).workouts
        let lowWeek = F.date(week: 11, day: 0, hour: 0), afterLow = F.date(week: 12, day: 0, hour: 0)
        let cal = PlanCalendar.calendar(timeZone: F.tz)

        var d = F.Driver(plan: original, history: history, context: F.context(tracksPain: true))
        // Week 11: only the quality session is run. Then pain 5/10 on Sunday night.
        d.follow(until: F.date(week: 11, day: 6, hour: 22)) { w in
            w.date >= lowWeek && !w.kind.isQuality ? nil : F.RunSpec()
        }
        d.checkIn(5, at: F.date(week: 11, day: 6, hour: 23))
        let frozen = try XCTUnwrap(d.outcomes.last)
        d.follow(until: F.date(week: 15, day: 6, hour: 23)) { _ in F.RunSpec() }

        func volume(_ from: Date, _ all: [PlannedWorkout]) -> Double {
            all.filter { PlanCalendar.weekStart(containing: $0.date, timeZone: F.tz) == from }.reduce(0) { $0 + $1.durationSeconds }
        }
        func week(_ n: Int) -> Date { cal.date(byAdding: .day, value: 7 * (n - 8), to: start)! }
        let ran = (8...15).map { (volume(week($0), d.history) / volume(week($0), original) * 100).rounded() }
        print("low week plus freeze, % of plan run, weeks 8-15: \(ran)")
        XCTAssertLessThan(volume(afterLow, frozen.history + frozen.plan), volume(afterLow, original) / 2, "the frozen week is cut")
        XCTAssertFalse(d.outcomes.contains { $0.guardrailReport.violations.contains { $0.rule == .volumeFreeze } },
                       "the freeze always holds")
        func rampQuality(_ v: GuardrailViolation) -> Bool { v.rule == .qualitySessions && v.explanation.contains("return ramp") }
        XCTAssertFalse(d.outcomes.contains { $0.guardrailReport.violations.contains(where: rampQuality) },
                       "quality sessions over the ramp's limit become easy runs")
        assertAdaptationSound(d.outcomes)
        // Never more load than planned.
        for w in 8...17 {
            XCTAssertLessThanOrEqual(volume(week(w), d.history + d.plan), volume(week(w), original) + 1e-6, "week \(w)")
        }
        // The weeks after grow back toward the plan by the return steps
        // (before #64 they stayed at 29 to 43% of plan through race week).
        // Week 12, the frozen week, was run as the freeze planned it, so the
        // steps go on: week 13 is step 2 (82.5% of plan, owner decision Nov
        // 21, #107, #109). The recovery cadence (3.5) then makes week 14 a
        // recovery week at about 80% of week 13, and week 15 comes back near
        // plan.
        // #170: the 20-minute long run of the cut week was easy, so it now
        // counts toward the long-run gate (before, a run under 40 min never
        // did) and week 13's long run is held less (77 min, not 70). The
        // guardrails then fit the easy runs around it, so the week lands near
        // 75% of plan rather than 82%.
        XCTAssertGreaterThanOrEqual(volume(week(13), d.history), 0.7 * volume(week(13), original), "\(ran)")
        XCTAssertGreaterThanOrEqual(volume(week(14), d.history), 0.8 * volume(week(13), d.history) - 10 * 60, "\(ran)")
        XCTAssertGreaterThanOrEqual(volume(week(15), d.history), 0.8 * volume(week(15), original), "\(ran)")
        XCTAssertGreaterThanOrEqual(volume(week(16), d.plan), 0.85 * volume(week(16), original))
        // The pain check-in swapped one quality session; any other that
        // turned easy is rule 6's swap, made before any trimming.
        let swaps = d.changes.filter { $0.kind == .qualitySwappedToEasy }
        func rule6(_ c: PlanChange) -> Bool { c.rule.contains("3.5 rule 6") || c.rule.contains("rules 4 and 6") }
        XCTAssertEqual(swaps.filter { !rule6($0) }.count, 1, "\(swaps.map(\.rule))")
        for o in d.outcomes {
            for q in o.plan where q.kind.isQuality {
                // Only a session's easy extension may be cut (#54: easy running within the long run).
                let was = try XCTUnwrap(original.first { $0.id == q.id })
                XCTAssertLessThanOrEqual(q.durationSeconds, was.durationSeconds, q.id)
                XCTAssertGreaterThanOrEqual(q.durationSeconds, was.durationSeconds - was.easyExtensionSeconds, q.id)
            }
        }
    }
}
