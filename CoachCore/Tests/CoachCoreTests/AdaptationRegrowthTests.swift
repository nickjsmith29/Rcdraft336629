import XCTest
@testable import CoachCore

// SPEC 3.5 rule 6 (#64): after a missed, cut or painful week, quality sessions
// become easy runs before a week is trimmed, and the plan grows back to the
// original plan over 1 to 2 weeks, never above it. Synthetic runners and plans
// only; every threshold is a heuristic.
final class AdaptationRegrowthTests: XCTestCase {
    typealias F = AdaptFixture

    private var cal: Calendar { PlanCalendar.calendar(timeZone: F.tz) }
    private func weekStart(_ week: Int) -> Date { PlanCalendar.weekStart(containing: F.date(week: week, day: 0), timeZone: F.tz) }
    private func volume(_ week: Int, _ all: [PlannedWorkout]) -> Double {
        all.filter { PlanCalendar.weekStart(containing: $0.date, timeZone: F.tz) == weekStart(week) && $0.kind != .race }
            .reduce(0) { $0 + $1.durationSeconds }
    }

    /// A synthetic 4-day runner, half marathon in 16 weeks from week 8, with
    /// 8 easy weeks of 240 min before (as in the replay tests).
    private func halfPlan() throws -> (plan: [PlannedWorkout], history: [PlannedWorkout]) {
        let start = F.date(week: 8, day: 0, hour: 0)
        let history = PlanFixture.easyWeeks(Array(repeating: 240, count: 8), prefix: "h")
        let race = cal.date(byAdding: .day, value: 15 * 7 + 6, to: start)!.addingTimeInterval(8 * 3600)
        let five = 24.0 * 60
        let input = PlanInput(raceDistanceMeters: Distance.halfMarathon, raceDate: race, startDate: start,
                              trainingDays: [.monday, .wednesday, .friday, .sunday], longRunDay: .sunday,
                              recentWeeklySeconds: 240 * 60, recentLongRunSeconds: 80 * 60, heartRateZones: F.zones,
                              easyPace: EasyPaceSample(secondsPerKm: 360, heartRate: 138),
                              fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: five),
                              predictedRaceSeconds: RacePredictor.riegel(knownMeters: Distance.fiveK, knownSeconds: five,
                                                                         targetMeters: Distance.halfMarathon))
        return (try XCTUnwrap(PlanBuilder.build(input, history: history, timeZone: F.tz).plan).workouts, history)
    }

    /// `assertAdaptationSound`, except that a long-run share violation in
    /// the missed week itself is let through: once every other run of a week
    /// is missed, its long run is all of the week's running, which no cut can
    /// bring under 35% (the same on main before #64; a separate gap).
    private func assertSound(_ outcomes: [AdaptationOutcome], missedWeek: Int, file: StaticString = #filePath, line: UInt = #line) {
        for (i, o) in outcomes.enumerated() {
            let left = o.guardrailReport.violations.filter { !($0.rule == .longRunShare && $0.weekStart == weekStart(missedWeek)) }
            XCTAssertTrue(left.isEmpty, "outcome \(i): \(left.map(\.explanation))", file: file, line: line)
            XCTAssertTrue(o.regrowth.weeks.allSatisfy { ($0.allowed(previous: 1e12) ?? 0) <= $0.original + 1e-6 }, file: file, line: line)
            for c in o.changes {
                XCTAssertFalse(c.triggers.isEmpty, "\(c.kind) cites no trigger", file: file, line: line)
                XCTAssertTrue(c.rule.contains("SPEC"), file: file, line: line)
            }
        }
    }

    private func assertNeverAbovePlan(_ d: F.Driver, _ original: [PlannedWorkout], weeks: ClosedRange<Int>,
                                      file: StaticString = #filePath, line: UInt = #line) {
        for w in weeks {
            XCTAssertLessThanOrEqual(volume(w, d.history + d.plan), volume(w, original) + 1e-6, "week \(w)", file: file, line: line)
        }
    }

    // MARK: The issue's scenarios

    /// One missed week with no pain (vacation or illness). The missed week
    /// is a short break (3.5 rule 4) as well as a cut week (rule 6), so the
    /// three weeks after take the lower of the ramp (70%, 90%, 100% of the
    /// pre-break level, with its own rise limits) and the regrowth (the same
    /// steps of the original plan); the recovery cadence may then make one a
    /// recovery week. Every outcome passes (before #64 the ramp's quality
    /// limit and the cadence left the plan red), never above the plan.
    func testOneMissedWeekReturnsByTheRampAndStaysGreen() throws {
        let (original, history) = try halfPlan()
        var d = F.Driver(plan: original, history: history, context: F.context())
        d.follow(until: F.date(week: 15, day: 6, hour: 23)) { w in
            PlanCalendar.weekStart(containing: w.date, timeZone: F.tz) == self.weekStart(11) ? nil : F.RunSpec()
        }
        let ran = (8...15).map { (volume($0, d.history) / volume($0, original) * 100).rounded() }
        print("one missed week, % of plan run, weeks 8-15: \(ran)")
        XCTAssertEqual(volume(11, d.history), 0, "week 11 is missed")
        assertSound(d.outcomes, missedWeek: 11)
        assertNeverAbovePlan(d, original, weeks: 8...17)
        let pre = (7...10).map { volume($0, history + d.history) }.reduce(0, +) / 4
        // The easy-run cap (#54) drops the time it cuts from a week, so a capped week is read
        // with that time added back: the ramp's floor is on the week before the cap.
        func cut(_ w: Int) -> Double { d.state.preCap.week(weekStart(w))?.secondsCut ?? 0 }
        let w12 = volume(12, d.history) + cut(12), w13 = volume(13, d.history) + cut(13)
        let minute = 60.0
        // Ramp week 1: the lower of 70% of the pre-break level and of the original week.
        XCTAssertGreaterThanOrEqual(w12, 0.9 * min(0.7 * pre, 0.7 * volume(12, original)), "\(ran)")
        // Ramp week 2: also at most 90/70 of week 1.
        XCTAssertGreaterThanOrEqual(w13, 0.9 * min(0.9 * pre, 0.9 / 0.7 * w12, 0.9 * volume(13, original)), "\(ran)")
        XCTAssertGreaterThanOrEqual(volume(14, d.history), 0.8 * w13 - 5 * minute, "a recovery week at the least, \(ran)")
        XCTAssertGreaterThanOrEqual(volume(15, d.history), 1.1 * w13 - 5 * minute, "\(ran)")
        XCTAssertTrue(d.outcomes.contains { !$0.regrowth.weeks.isEmpty })
    }

    /// A freeze after a normal week: the frozen week holds, and the weeks
    /// after it are back at the plan, with no lasting effect.
    func testAFreezeAfterANormalWeekHasNoLastingEffect() throws {
        let (original, history) = try halfPlan()
        var d = F.Driver(plan: original, history: history, context: F.context(tracksPain: true))
        d.follow(until: F.date(week: 10, day: 6, hour: 22)) { _ in F.RunSpec() }
        d.checkIn(5, at: F.date(week: 10, day: 6, hour: 23))
        XCTAssertFalse(d.state.freezes.isEmpty)
        d.follow(until: F.date(week: 14, day: 6, hour: 23)) { _ in F.RunSpec() }
        let ran = (8...14).map { (volume($0, d.history) / volume($0, original) * 100).rounded() }
        print("freeze after a normal week, % of plan run, weeks 8-14: \(ran)")
        XCTAssertFalse(d.outcomes.contains { $0.guardrailReport.violations.contains { $0.rule == .volumeFreeze } })
        assertAdaptationSound(d.outcomes)
        assertNeverAbovePlan(d, original, weeks: 8...16)
        XCTAssertLessThanOrEqual(volume(11, d.history), volume(10, d.history) + 1e-6, "the freeze holds week 11")
        XCTAssertGreaterThanOrEqual(volume(13, d.history), 0.9 * volume(13, original), "\(ran)")
        XCTAssertGreaterThanOrEqual(volume(14, d.history), 0.9 * volume(14, original), "\(ran)")
        XCTAssertGreaterThanOrEqual(volume(15, d.plan), 0.9 * volume(15, original))
    }

    // MARK: The spike rule on the first long run back (owner's condition, #75)

    /// Long runs missed for 4 weeks while the easy runs are kept: the weeks
    /// grow back, and the first long run back still passes the 30-day spike
    /// rule (3.5 rule 1), measured against the longest run of the 30 days
    /// before it, not the original plan.
    func testTheFirstLongRunBackPassesTheSpikeRule() {
        // Threshold Tuesday, easy Thursday and Friday, long run Sunday (so a
        // missed one is not moved); recovery weeks 3 and 7; the long run
        // grows 5 min a week otherwise.
        let plan = (0..<10).flatMap { w -> [PlannedWorkout] in
            let rec = w % 4 == 3
            return [F.threshold("t\(w)", week: w, day: 1), F.easy("a\(w)", week: w, day: 3, minutes: rec ? 35 : 55),
                    F.easy("b\(w)", week: w, day: 4, minutes: rec ? 30 : 45),
                    F.long("l\(w)", week: w, day: 6, minutes: rec ? 60 : 70 + 5 * Double(w))]
        }
        var d = F.Driver(plan: plan, context: F.context())
        func week(_ w: PlannedWorkout) -> Int {
            (cal.dateComponents([.day], from: weekStart(0), to: w.date).day ?? 0) / 7
        }
        d.follow(until: F.date(week: 8, day: 6, hour: 23)) { w in
            w.kind == .long && (2...5).contains(week(w)) ? nil : F.RunSpec()
        }
        assertAdaptationSound(d.outcomes)
        XCTAssertTrue(d.outcomes.contains { !$0.regrowth.weeks.isEmpty }, "weeks 2 to 5 are cut weeks")
        let longsBack = d.history.filter { $0.kind == .long && week($0) >= 6 }.sorted { $0.date < $1.date }
        guard let first = longsBack.first else { return XCTFail("a long run comes back") }
        let day = cal.startOfDay(for: first.date)
        let window = cal.date(byAdding: .day, value: -GuardrailLimits.default.spikeWindowDays, to: day)!
        let longest = d.history.filter { $0.date >= window && $0.date < day }.map(\.durationSeconds).max() ?? 0
        let planned = plan.filter { $0.kind == .long && week($0) == week(first) }.map(\.durationSeconds).max() ?? 0
        print("first long run back: \(first.durationSeconds / 60) min of \(planned / 60) planned; longest of the 30 days before \(longest / 60) min")
        XCTAssertLessThanOrEqual(first.durationSeconds, (1 + GuardrailLimits.default.maxSingleRunIncrease) * longest + 1e-6)
        XCTAssertLessThan(first.durationSeconds, planned, "not the next scheduled long run")
        for w in 0..<10 {
            XCTAssertLessThanOrEqual(volume(w, d.history + d.plan), volume(w, plan) + 1e-6, "week \(w)")
        }
    }

    // MARK: Never above the original plan

    /// A missed week in a plain plan with a recovery week: every regrowth
    /// week's bound is a step of the original plan's week and never above it,
    /// and no week ever holds more than the original plan.
    func testRegrowthNeverExceedsTheOriginalPlan() {
        let plan = F.weeks(0..<7, easyMinutes: { w in w == 3 ? (35, 30) : (50 + 3 * Double(w), 40 + 3 * Double(w)) },
                           longMinutes: { $0 == 3 ? 50 : 60 + 4 * Double($0) })
        var d = F.Driver(plan: plan, context: F.context())
        d.follow(until: F.date(week: 5, day: 6, hour: 23)) { w in
            PlanCalendar.weekStart(containing: w.date, timeZone: F.tz) == self.weekStart(1) ? nil : F.RunSpec()
        }
        print("plain plan, one missed week, minutes a week: \((0..<7).map { self.volume($0, d.history + d.plan) / 60 }) of \((0..<7).map { self.volume($0, plan) / 60 })")
        assertSound(d.outcomes, missedWeek: 1)
        var seen = 0
        for o in d.outcomes {
            for g in o.regrowth.weeks {
                let w = (cal.dateComponents([.day], from: weekStart(0), to: g.weekStart).day ?? 0) / 7
                XCTAssertEqual(g.original, volume(w, plan), accuracy: 1e-6, "the original week \(w)")
                XCTAssertEqual(g.maxRise, GuardrailLimits.default.regrowthMaxWeeklyRise)
                XCTAssertLessThanOrEqual(g.allowed(previous: 1e12) ?? .infinity, g.original + 1e-6)
                seen += 1
            }
        }
        XCTAssertGreaterThan(seen, 0)
        for w in 0..<7 {
            XCTAssertLessThanOrEqual(volume(w, d.history + d.plan), volume(w, plan) + 1e-6, "week \(w)")
        }
    }

    // MARK: Repair: quality becomes easy before a week is trimmed

    /// A week that can't meet the 10% rule with its quality sessions whole:
    /// they become easy runs of the same length, then the week is trimmed.
    /// A week that can is cut as before, its quality session kept.
    func testRepairTurnsQualityEasyOnlyWhenTheWeekCantFitWithIt() {
        let history = [F.easy("h1", week: 0, day: 1, minutes: 40), F.easy("h2", week: 0, day: 4, minutes: 40)]   // 80 min
        let hard = [F.threshold("q1", week: 1, day: 1), F.threshold("q2", week: 1, day: 3), F.easy("e1", week: 1, day: 5, minutes: 40)]
        let asOf = F.date(week: 1, day: 0, hour: 6)
        let r = GuardrailRepair.repair(plan: hard, history: history, asOf: asOf, freezes: [], context: F.context())
        XCTAssertTrue(r.report.passed, "\(r.report.violations.map(\.explanation))")
        XCTAssertFalse(r.plan.contains { $0.kind.isQuality }, "both quality sessions become easy")
        let swaps = r.changes.filter { $0.kind == .qualitySwappedToEasy }
        XCTAssertEqual(Set(swaps.flatMap(\.workoutIDs)), ["q1", "q2"])
        XCTAssertTrue(swaps.allSatisfy { $0.rule.contains("SPEC 3.5 rule") }, "\(swaps.map(\.rule))")
        XCTAssertLessThanOrEqual(r.plan.reduce(0) { $0 + $1.durationSeconds }, 1.1 * 80 * 60 + 1e-6)
        for s in r.plan { XCTAssertLessThanOrEqual(s.durationSeconds, hard.first { $0.id == s.id }!.durationSeconds) }

        let light = [F.threshold("q1", week: 1, day: 1), F.easy("e1", week: 1, day: 3, minutes: 60), F.easy("e2", week: 1, day: 5, minutes: 60)]
        let q = light[0].durationSeconds
        let roomy = [F.easy("h1", week: 0, day: 1, minutes: 60), F.easy("h2", week: 0, day: 4, minutes: (q / 60 + 60) / 1.0)]
        let k = GuardrailRepair.repair(plan: light, history: roomy, asOf: asOf, freezes: [], context: F.context())
        XCTAssertTrue(k.report.passed, "\(k.report.violations.map(\.explanation))")
        XCTAssertEqual(k.plan.first { $0.id == "q1" }?.kind, light[0].kind, "the quality session is kept")
        XCTAssertFalse(k.changes.contains { $0.kind == .qualitySwappedToEasy })
    }

    // MARK: The snapshot of the original plan

    func testTheSnapshotKeepsThePlanAsHandedInAndAReplanReplacesIt() throws {
        let plan = F.weeks(0..<4)
        let o = AdaptationEngine.processDay(asOf: F.date(week: 0, day: 2, hour: 6), state: AdaptationState(), plan: plan,
                                            history: [], context: F.context())
        XCTAssertEqual(o.state.planSnapshot.sessions.map(\.id), plan.map(\.id), "the plan as handed in, missed sessions too")
        XCTAssertNotEqual(o.plan.map(\.id), plan.map(\.id), "the engine dropped or cut what was missed")
        XCTAssertEqual(o.state.planSnapshot.returned, PlanSnapshot.returned(o.plan))
        // The plan handed back keeps the snapshot.
        let o2 = AdaptationEngine.processDay(asOf: F.date(week: 0, day: 3, hour: 6), state: o.state, plan: o.plan,
                                             history: o.history, context: F.context())
        XCTAssertEqual(o2.state.planSnapshot.sessions, o.state.planSnapshot.sessions)
        // A new plan from the app replaces it; the old plan's earlier days are kept as weekly volumes.
        let fresh = F.weeks(1..<4, easyMinutes: { _ in (50, 40) })
        let o3 = AdaptationEngine.processDay(asOf: F.date(week: 1, day: 0, hour: 6), state: o2.state, plan: fresh,
                                             history: o2.history, context: F.context())
        XCTAssertEqual(o3.state.planSnapshot.sessions.map(\.id), fresh.map(\.id))
        XCTAssertEqual(o3.state.planSnapshot.earlier.map(\.week), [weekStart(0)])
        XCTAssertEqual(o3.state.planSnapshot.earlier.first?.volume ?? 0, volume(0, plan), accuracy: 1e-6)
        // The record of the plan returned doesn't depend on order.
        XCTAssertEqual(PlanSnapshot.returned(plan), PlanSnapshot.returned(plan.reversed()))
        XCTAssertNotEqual(PlanSnapshot.returned(plan), PlanSnapshot.returned(fresh))
    }

    /// The app may drop sessions dated before the event's day from the plan
    /// it hands back: that is still the plan the engine returned, so the
    /// snapshot stays. A session from the event's day on dropped or changed
    /// is a re-plan, and the plan handed in becomes the snapshot.
    func testDroppingPastSessionsKeepsTheSnapshotAndAChangeToComeReplacesIt() {
        let plan = F.weeks(0..<4)
        let o = AdaptationEngine.processDay(asOf: F.date(week: 0, day: 1, hour: 6), state: AdaptationState(), plan: plan,
                                            history: [], context: F.context())
        let later = F.date(week: 0, day: 4, hour: 6)
        let today = cal.startOfDay(for: later)
        XCTAssertTrue(o.plan.contains { $0.date < today }, "the plan returned holds days now past")
        let kept = o.plan.filter { $0.date >= today }
        let o2 = AdaptationEngine.processDay(asOf: later, state: o.state, plan: kept, history: o.history, context: F.context())
        XCTAssertEqual(o2.state.planSnapshot.sessions, o.state.planSnapshot.sessions, "past sessions dropped: the same plan")
        XCTAssertTrue(o.state.planSnapshot.isReturnedPlan(o.plan, from: .distantPast))
        XCTAssertFalse(o.state.planSnapshot.isReturnedPlan(kept, from: .distantPast), "with no event day, nothing may be dropped")

        // A session to come dropped: a re-plan.
        var dropped = kept
        dropped.remove(at: 0)
        XCTAssertFalse(o.state.planSnapshot.isReturnedPlan(dropped, from: today))
        let o3 = AdaptationEngine.processDay(asOf: later, state: o.state, plan: dropped, history: o.history, context: F.context())
        XCTAssertEqual(o3.state.planSnapshot.sessions.map(\.id), dropped.map(\.id))
        // A session to come changed: a re-plan.
        var changed = kept
        let last = changed.count - 1
        changed[last] = changed[last].resized(toSeconds: changed[last].durationSeconds + 600)
        XCTAssertFalse(o.state.planSnapshot.isReturnedPlan(changed, from: today))
        let o4 = AdaptationEngine.processDay(asOf: later, state: o.state, plan: changed, history: o.history, context: F.context())
        XCTAssertEqual(o4.state.planSnapshot.sessions.last?.durationSeconds, changed[last].durationSeconds)
        // A session the engine never returned: a re-plan.
        XCTAssertFalse(o.state.planSnapshot.isReturnedPlan(kept + [F.easy("new", week: 3, day: 2, minutes: 30)], from: today))
        XCTAssertFalse(PlanSnapshot().isReturnedPlan([], from: today), "nothing returned yet")
    }

    // MARK: The regrowth bound (owner decision Nov 21, #107)

    private func week(original: Double, step: Int = 3, previousOriginal: Double? = nil, maxRise: Double? = 0.2) -> GuardrailRegrowth.Week {
        GuardrailRegrowth.Week(weekStart: weekStart(1), step: step, original: original, previousOriginal: previousOriginal, maxRise: maxRise)
    }

    /// The named constants (owner decision Nov 21, #107).
    func testTheRegrowthConstantsAreNamed() {
        XCTAssertEqual(PlanHeuristics.regrowthMaxWeeklyRise, 0.20)
        XCTAssertEqual(PlanHeuristics.regrowthReturnSteps, [0.65, 0.825, 1.0])
        XCTAssertEqual(GuardrailLimits.default.regrowthMaxWeeklyRise, 0.20)
        XCTAssertEqual(GuardrailLimits.default.regrowthReturnSteps, [0.65, 0.825, 1.0])
        XCTAssertEqual(GuardrailRegrowth.stepShare(1, steps: [0.65, 0.825, 1.0]), 0.65)
        XCTAssertEqual(GuardrailRegrowth.stepShare(2, steps: [0.65, 0.825, 1.0]), 0.825)
        XCTAssertEqual(GuardrailRegrowth.stepShare(3, steps: [0.65, 0.825, 1.0]), 1.0)
        XCTAssertEqual(GuardrailRegrowth.stepShare(9, steps: [0.65, 0.825, 1.0]), 1.0, "the last step from then on")
        XCTAssertEqual(GuardrailRegrowth.stepShare(0, steps: [0.65, 0.825, 1.0]), 0)
        XCTAssertEqual(GuardrailRegrowth.stepShare(1, steps: []), 0)
        XCTAssertEqual(GuardrailRegrowth.stepShare(1, steps: [.nan]), 0)
        XCTAssertEqual(GuardrailRegrowth.stepShare(1, steps: [1.5]), 1)
    }

    /// Each regrowth week as run at its bound, from a cut week run at
    /// `share` of a flat original plan of 100: what weeks 1 to 4 may hold.
    private func returnFrom(_ share: Double, original: Double = 100) -> [Double] {
        var previous = share * original
        return (1...4).map { step in
            previous = week(original: original, step: step).allowed(previous: previous) ?? .nan
            return previous
        }
    }

    /// A fully missed week returns as 65, 82.5, 100 (the return steps); a
    /// week at 26% has no cliff (the same steps as a missed week, never
    /// less); a week at 70% returns as 84 (20% over it), then 100.8 capped to
    /// the plan's 100 (owner decision Nov 21, #107).
    func testTheReturnStepsAfterAMissedAShortAndANearlyFullWeek() {
        for (got, want) in zip(returnFrom(0), [65.0, 82.5, 100, 100]) { XCTAssertEqual(got, want, accuracy: 1e-9, "missed: \(returnFrom(0))") }
        for (got, want) in zip(returnFrom(0.26), [65.0, 82.5, 100, 100]) { XCTAssertEqual(got, want, accuracy: 1e-9, "26%: \(returnFrom(0.26))") }
        for (got, want) in zip(returnFrom(0.70), [84.0, 100, 100, 100]) { XCTAssertEqual(got, want, accuracy: 1e-9, "70%: \(returnFrom(0.70))") }
        XCTAssertEqual(week(original: 100, step: 2).allowed(previous: 84) ?? 0, 100, accuracy: 1e-9, "100.8 capped to the plan's 100")
        // No cliff: the bound never falls as the week before rises, and a
        // week run at almost nothing returns as a missed one does.
        for step in 1...3 {
            var last = 0.0
            for p in stride(from: 0.0, through: 120.0, by: 0.5) {
                let a = week(original: 100, step: step).allowed(previous: p) ?? .nan
                XCTAssertGreaterThanOrEqual(a, last - 1e-9, "step \(step), \(p) run")
                last = a
            }
            XCTAssertEqual(week(original: 100, step: step).allowed(previous: 1e-9) ?? 0,
                           week(original: 100, step: step).allowed(previous: 0) ?? 1, accuracy: 1e-6)
        }
        // The step wins below 54.17% (65 / 1.2), the 20% rise above it.
        XCTAssertEqual(week(original: 100, step: 1).allowed(previous: 65 / 1.2) ?? 0, 65, accuracy: 1e-9)
        XCTAssertEqual(week(original: 100, step: 1).allowed(previous: 60) ?? 0, 72, accuracy: 1e-9)
    }

    /// The higher of 20% over the week before and the return step, never
    /// above the original plan; exactly 20% is allowed. Where the original
    /// plan itself rises more (after a planned recovery week run at plan),
    /// as much as the plan does.
    func testTheBoundIsTwentyPercentOverTheWeekBeforeOrTheStepAndNeverAbovePlan() {
        XCTAssertEqual(week(original: 200, step: 1).allowed(previous: 100) ?? 0, 130, accuracy: 1e-9, "step 1: 65% of 200 over 120")
        XCTAssertEqual(week(original: 200, step: 2).allowed(previous: 100) ?? 0, 165, accuracy: 1e-9, "step 2: 82.5% of 200")
        XCTAssertEqual(week(original: 200, step: 2).allowed(previous: 150) ?? 0, 180, accuracy: 1e-9, "20% over 150 beats the step")
        XCTAssertEqual(week(original: 200, step: 3).allowed(previous: 100) ?? 0, 200, accuracy: 1e-9, "step 3: the plan")
        XCTAssertEqual(week(original: 120, step: 1).allowed(previous: 100) ?? 0, 120, accuracy: 1e-9, "exactly 20%: the plan")
        XCTAssertEqual(week(original: 119, step: 1).allowed(previous: 100) ?? 0, 119, accuracy: 1e-9)
        // The plan's own rise after a week at plan (a planned recovery week).
        XCTAssertEqual(week(original: 150, step: 1, previousOriginal: 100).allowed(previous: 100) ?? 0, 150, accuracy: 1e-9,
                       "the plan's own 50% rise after a planned recovery week run at plan")
        XCTAssertEqual(week(original: 150, step: 1, previousOriginal: 100).allowed(previous: 98) ?? 0, 147, accuracy: 1e-9,
                       "98% of plan counts as at plan")
        XCTAssertEqual(week(original: 150, step: 1, previousOriginal: 100).allowed(previous: 80) ?? 0, 97.5, accuracy: 1e-9,
                       "below plan: no planned rise, the step (65% of 150) over 20% (96)")
        XCTAssertEqual(week(original: 300, step: 1, previousOriginal: 100).allowed(previous: 80) ?? 0, 195, accuracy: 1e-9)
        // The plan already at or below what was run.
        XCTAssertEqual(week(original: 200, step: 1).allowed(previous: 300) ?? 0, 200, accuracy: 1e-9)
        XCTAssertEqual(week(original: 200, step: 1).allowed(previous: 200) ?? 0, 200, accuracy: 1e-9)
        // Nothing run the week before (or less than nothing): the step alone.
        XCTAssertEqual(week(original: 200, step: 1).allowed(previous: 0) ?? 0, 130, accuracy: 1e-9)
        XCTAssertEqual(week(original: 200, step: 1).allowed(previous: -5) ?? 0, 130, accuracy: 1e-9)
        // Unknown week before: nil, the plain rules apply.
        XCTAssertNil(week(original: 200).allowed(previous: nil))
        XCTAssertNil(week(original: 200).allowed(previous: .nan))
        XCTAssertNil(week(original: 200).allowed(previous: .infinity))
        // After a pain stop of more than 14 days: no weekly bound but the plan.
        XCTAssertEqual(week(original: 200, step: 1, maxRise: nil).allowed(previous: 10) ?? 0, 200, accuracy: 1e-9)
        XCTAssertEqual(week(original: 200, step: 1, maxRise: nil).allowed(previous: nil) ?? 0, 200, accuracy: 1e-9)
        // Invalid inputs.
        XCTAssertNil(week(original: .nan).allowed(previous: 100))
        XCTAssertNil(week(original: -1).allowed(previous: 100))
        XCTAssertEqual(week(original: 0).allowed(previous: 100), 0)
        XCTAssertEqual(week(original: 200, step: 1, maxRise: .nan).allowed(previous: 150) ?? 0, 150, accuracy: 1e-9,
                       "a rise that isn't a number allows none: the higher of 150 and the step's 130")
        XCTAssertEqual(week(original: 200, step: 1, maxRise: -0.5).allowed(previous: 150) ?? 0, 150, accuracy: 1e-9)
        XCTAssertEqual(week(original: 150, step: 1, previousOriginal: .nan).allowed(previous: 100) ?? 0, 120, accuracy: 1e-9)
        XCTAssertEqual(GuardrailRegrowth.Week(weekStart: weekStart(1), step: 1, original: 200, returnSteps: [])
                        .allowed(previous: 100) ?? 0, 120, accuracy: 1e-9, "no steps: 20% alone")
    }

    /// The checker reads a regrowth week at its bound over the week before
    /// as run, in place of the plain 10% check, never above the plan; with
    /// the week before unknown, the plain check applies. The spike rule
    /// still applies to every run, even where the bound is the whole plan.
    func testTheCheckerUsesTheRegrowthBound() {
        let history = [F.easy("h1", week: 0, day: 1, minutes: 50), F.easy("h2", week: 0, day: 4, minutes: 50)]   // 100 min
        let plan = [F.easy("p1", week: 1, day: 1, minutes: 100), F.easy("p2", week: 1, day: 3, minutes: 100),
                    F.easy("p3", week: 1, day: 5, minutes: 100)]   // 300 min
        func report(_ g: GuardrailRegrowth.Week, history: [PlannedWorkout] = history) -> GuardrailReport {
            GuardrailChecker.check(history: history, planned: plan, timeZone: F.tz, limits: .default,
                                   regrowth: GuardrailRegrowth(weeks: [g]))
        }
        func check(_ g: GuardrailRegrowth.Week, history: [PlannedWorkout] = history) -> GuardrailViolation? {
            report(g, history: history).violations.first { $0.rule == .weeklyIncrease }
        }
        XCTAssertEqual(check(week(original: 150 * 60, step: 1))?.allowed ?? 0, 120 * 60, accuracy: 1e-6, "20% over the 100 min run")
        XCTAssertEqual(check(week(original: 200 * 60, step: 1))?.allowed ?? 0, 130 * 60, accuracy: 1e-6, "the return step: 65% of 200")
        XCTAssertEqual(check(week(original: 200 * 60, step: 2))?.allowed ?? 0, 165 * 60, accuracy: 1e-6, "82.5% of 200")
        XCTAssertEqual(check(week(original: 110 * 60, step: 1))?.allowed ?? 0, 110 * 60, accuracy: 1e-6, "never above the plan")
        XCTAssertEqual(check(week(original: 250 * 60, step: 1, maxRise: nil))?.allowed ?? 0, 250 * 60, accuracy: 1e-6)
        XCTAssertTrue(check(week(original: 250 * 60, step: 1, maxRise: nil))?.explanation.contains("more than 14 days") ?? false)
        XCTAssertNil(check(week(original: 300 * 60, step: 1, maxRise: nil)), "300 min within a plan of 300 with no weekly bound")
        if let plain = check(week(original: 300 * 60, step: 1), history: []) {
            XCTAssertFalse(plain.explanation.contains("regrowth"), "no week before: not the regrowth's bound")
        }
        let v = check(week(original: 150 * 60, step: 1))
        XCTAssertTrue(v?.explanation.contains("20%") ?? false)
        XCTAssertTrue(v?.explanation.contains("return step") ?? false, v?.explanation ?? "")
        XCTAssertTrue(v?.explanation.contains("never above the original plan") ?? false)
        // Step 3: the bound is the whole plan, yet the first 100-min run is
        // more than 10% over the longest run of the 30 days before (50 min).
        let atPlan = report(week(original: 300 * 60, step: 3))
        XCTAssertFalse(atPlan.violations.contains { $0.rule == .weeklyIncrease })
        XCTAssertTrue(atPlan.violations.contains { $0.rule == .singleRunSpike && $0.workoutID == "p1" }, "the spike rule still applies")
    }

    /// The spike rule still trims a long run where the regrowth's bound is
    /// the whole plan: repair cuts it to 10% over the longest run of the 30
    /// days before, and the week passes.
    func testTheSpikeRuleStillTrimsALongRunInARegrowthWeek() {
        let history = [F.easy("h1", week: 0, day: 1, minutes: 55), F.easy("h2", week: 0, day: 3, minutes: 55),
                       F.easy("h3", week: 0, day: 5, minutes: 60)]   // 170 min, longest 60
        let plan = [F.easy("p1", week: 1, day: 1, minutes: 55), F.easy("p2", week: 1, day: 2, minutes: 55),
                    F.easy("p3", week: 1, day: 4, minutes: 55), F.long("l1", week: 1, day: 6, minutes: 80)]   // 245 min, an 80-min long run
        let g = GuardrailRegrowth(weeks: [week(original: 245 * 60, step: 3)])
        let before = GuardrailChecker.check(history: history, planned: plan, timeZone: F.tz, limits: .default, regrowth: g)
        XCTAssertFalse(before.violations.contains { $0.rule == .weeklyIncrease }, "within the regrowth")
        XCTAssertTrue(before.violations.contains { $0.rule == .singleRunSpike && $0.workoutID == "l1" })
        let r = GuardrailRepair.repair(plan: plan, history: history, asOf: F.date(week: 1, day: 0, hour: 6), freezes: [],
                                       context: F.context(), regrowth: g)
        let long = r.plan.first { $0.id == "l1" }
        XCTAssertNotNil(long)
        XCTAssertLessThanOrEqual(long?.durationSeconds ?? .infinity, 66 * 60 + 1e-6, "trimmed to 10% over 60 min")
        XCTAssertGreaterThan(long?.durationSeconds ?? 0, 60 * 60, "trimmed, not dropped")
        XCTAssertTrue(r.report.violations.isEmpty, "\(r.report.violations.map(\.explanation))")
    }

    // MARK: What counts as a cut week (owner decision Nov 21, #107)

    /// The regrowth read on Monday of week 1, with `ran` run in week 0 and
    /// the original plan: week 0 as `week0` (minutes of easy runs), weeks 1
    /// to 3 as `next` each.
    private func readRegrowth(ran: [Double], week0: [Double] = [40, 40, 40], next: [Double] = [40, 40, 40]) -> GuardrailRegrowth {
        let days = [1, 3, 5]
        let plan = week0.enumerated().map { F.easy("o0-\($0.offset)", week: 0, day: days[$0.offset], minutes: $0.element) }
            + (1..<4).flatMap { w in next.enumerated().map { F.easy("o\(w)-\($0.offset)", week: w, day: days[$0.offset], minutes: $0.element) } }
        let history = ran.enumerated().map { F.easy("r\($0.offset)", week: 0, day: $0.offset * 2, minutes: $0.element) }
        let asOf = F.date(week: 1, day: 0, hour: 6)
        let work = AdaptationEngine.Work(state: AdaptationState(), plan: plan, history: history, context: F.context(), asOf: asOf)
        return work.regrowth(asOf: asOf)
    }

    private func isCut(_ r: GuardrailRegrowth) -> Bool { r.week(weekStart(1)) != nil }

    /// Straight back to the plan rising exactly 20% over what was run is not
    /// a cut week; more than 20% is.
    func testACutWeekAtTheTwentyPercentBoundary() {
        XCTAssertFalse(isCut(readRegrowth(ran: [50, 50])), "120 min after 100: exactly 20%")
        XCTAssertTrue(isCut(readRegrowth(ran: [49.5, 49.5])), "120 min after 99: more than 20%")
        let r = readRegrowth(ran: [49.5, 49.5])
        XCTAssertEqual(r.week(weekStart(1))?.step, 1)
        XCTAssertEqual(r.week(weekStart(1))?.original ?? 0, 120 * 60, accuracy: 1e-6)
        XCTAssertNotNil(r.cutOriginal(weekStart(0)), "the cut week counts at the plan in the rolling check")
        XCTAssertEqual(r.week(weekStart(1))?.allowed(previous: 99 * 60) ?? 0, 118.8 * 60, accuracy: 1e-6, "20% over 99 beats the step's 78")
        // The regrowth stays on ahead, to the end of the plan.
        XCTAssertEqual(r.weeks.map(\.step), [1, 2, 3])
    }

    /// Straight back to the plan with a run exactly 10% longer than the
    /// longest run of the last 30 days is not a cut week; longer is, even
    /// when the week's volume was at plan.
    func testACutWeekAtTheSpikeBoundary() {
        XCTAssertFalse(isCut(readRegrowth(ran: [40, 40, 40], next: [44, 38, 38])), "44 min after a longest of 40: exactly 10%")
        XCTAssertTrue(isCut(readRegrowth(ran: [40, 40, 40], next: [44.5, 37.75, 37.75])), "44.5 min: more than 10%")
    }

    /// A week run at or above the plan is not cut, nor one whose plan the
    /// week after is no more than what was run; a week with nothing run is.
    func testACutWeekWithZeroUnknownOrAmpleWeeks() {
        XCTAssertFalse(isCut(readRegrowth(ran: [40, 40, 40])), "at plan")
        XCTAssertFalse(isCut(readRegrowth(ran: [50, 50, 50])), "above plan: the plan is below what was run")
        XCTAssertFalse(isCut(readRegrowth(ran: [55, 55], week0: [60, 60, 60], next: [40, 40, 40])),
                       "below its own plan, but the plan the week after is below what was run")
        let none = readRegrowth(ran: [])
        XCTAssertTrue(isCut(none), "nothing run: any rise is more than 20%")
        XCTAssertEqual(none.week(weekStart(1))?.allowed(previous: 0) ?? 0, 0.65 * 120 * 60, accuracy: 1e-6,
                       "no rise to measure from nothing: the return step bounds it (with rule 4's ramp in the checker)")
        XCTAssertEqual(none.weeks.map(\.step), [1, 2, 3])
        XCTAssertEqual(none.weeks.map { $0.allowed(previous: 0) ?? 0 }, [78.0 * 60, 99.0 * 60, 120.0 * 60], "65, 82.5, 100% of 120 min")
        // A run of unknown time: the week can't be read, so no regrowth starts.
        var unknown = F.easy("r0", week: 0, day: 0, minutes: 40)
        unknown.durationSeconds = .nan
        let days = [1, 3, 5]
        let plan = (0..<4).flatMap { w in (0..<3).map { F.easy("o\(w)-\($0)", week: w, day: days[$0], minutes: 40) } }
        let asOf = F.date(week: 1, day: 0, hour: 6)
        let work = AdaptationEngine.Work(state: AdaptationState(), plan: plan, history: [unknown], context: F.context(), asOf: asOf)
        XCTAssertTrue(work.regrowth(asOf: asOf).isEmpty)
    }

    // MARK: When the steps go on and when they start again (#109)

    /// The regrowth read on Monday of week `asOf`, for a plan of 3 × 40 min
    /// easy runs a week from week 1 on: week 0 run as planned, week 1
    /// missed (the cut week), then week 2 run at `week2` minutes and week 3
    /// at `week3` (if given), with each regrowth week's own planned volume
    /// recorded as `planned` (minutes by week).
    private func steps(week2: Double, week3: Double? = nil, planned: [Int: Double], asOf: Int) -> GuardrailRegrowth {
        let days = [1, 3, 5]
        let plan = (1..<8).flatMap { w in (0..<3).map { F.easy("o\(w)-\($0)", week: w, day: days[$0], minutes: 40) } }
        var history = (0..<3).map { F.easy("r0-\($0)", week: 0, day: days[$0], minutes: 40) }
        for (w, m) in [(2, week2), (3, week3)] {
            guard let m else { continue }
            history += [F.easy("r\(w)-a", week: w, day: 1, minutes: m / 2), F.easy("r\(w)-b", week: w, day: 3, minutes: m / 2)]
        }
        var state = AdaptationState()
        state.planSnapshot = PlanSnapshot(planned: planned.keys.sorted().map { PlanWeekVolume(week: weekStart($0), volume: planned[$0]! * 60) })
        let at = F.date(week: asOf, day: 0, hour: 6)
        let work = AdaptationEngine.Work(state: state, plan: plan, history: history, context: F.context(), asOf: at)
        return work.regrowth(asOf: at)
    }

    /// A regrowth week run as planned at its 65% step goes on to the 82.5%
    /// step, then 100%.
    func testARegrowthWeekRunAsPlannedGoesOnToTheNextStep() {
        let r = steps(week2: 78, planned: [2: 78], asOf: 3)
        XCTAssertEqual(r.week(weekStart(2))?.step, 1)
        let w3 = r.week(weekStart(3))
        XCTAssertEqual(w3?.step, 2, "\(r.weeks.map(\.step))")
        XCTAssertEqual(w3?.allowed(previous: 78 * 60) ?? 0, 99 * 60, accuracy: 1e-6, "82.5% of 120 min")
        let r4 = steps(week2: 78, week3: 99, planned: [2: 78, 3: 99], asOf: 4)
        XCTAssertEqual(r4.week(weekStart(4))?.step, 3)
        XCTAssertEqual(r4.week(weekStart(4))?.allowed(previous: 99 * 60) ?? 0, 120 * 60, accuracy: 1e-6)
    }

    /// Step 2 run at 30% of the plan (36 of its planned 99 min) is a new cut
    /// week: the steps start again from it, at 65% (the higher of that and
    /// 20% over 36), not straight back to 100%.
    func testAWeekRunAtThirtyPercentStartsTheStepsAgain() {
        let r = steps(week2: 78, week3: 36, planned: [2: 78, 3: 99], asOf: 4)
        let w4 = r.week(weekStart(4))
        XCTAssertEqual(w4?.step, 1, "\(r.weeks.map(\.step))")
        XCTAssertEqual(w4?.allowed(previous: 36 * 60) ?? 0, 78 * 60, accuracy: 1e-6, "65% of 120 min, not 120")
        XCTAssertNotNil(r.cutOriginal(weekStart(3)), "the new cut week counts at the plan in the rolling check")
    }

    /// The boundary is 1 / (1 + 20%) of the week's own planned volume,
    /// derived from `regrowthMaxWeeklyRise`: 65 of a planned 78 min (exactly
    /// 78 / 1.2) goes on; less starts again.
    func testTheStepsGoOnAtExactlyOneOverOnePointTwoOfThePlannedWeek() {
        XCTAssertEqual(78 / (1 + GuardrailLimits.default.regrowthMaxWeeklyRise), 65, accuracy: 1e-9)
        XCTAssertEqual(steps(week2: 65, planned: [2: 78], asOf: 3).week(weekStart(3))?.step, 2, "exactly 65 of 78: the steps go on")
        XCTAssertEqual(steps(week2: 64.5, planned: [2: 78], asOf: 3).week(weekStart(3))?.step, 1, "64.5 of 78: a new cut week")
        // With no planned volume recorded, the regrowth's bound stands in for it (78 min here).
        XCTAssertEqual(steps(week2: 65, planned: [:], asOf: 3).week(weekStart(3))?.step, 2)
        XCTAssertEqual(steps(week2: 64.5, planned: [:], asOf: 3).week(weekStart(3))?.step, 1)
    }

    /// A break of more than 14 days without pain keeps rule 4's "normal
    /// progression under rules 1 and 2": no regrowth (owner decision Nov
    /// 21, #107). A break of 14 days or fewer is a cut and starts one.
    func testABreakOfMoreThan14DaysWithoutPainStartsNoRegrowth() {
        let days = [1, 3, 5]
        let plan = (0..<6).flatMap { w in (0..<3).map { F.easy("o\(w)-\($0)", week: w, day: days[$0], minutes: 40) } }
        func regrowth(lastRun: Date) -> GuardrailRegrowth {
            let history = [F.easy("r0", week: 0, day: 1, minutes: 40), F.easy("r1", week: 0, day: 3, minutes: 40),
                           PlannedWorkout(id: "r2", date: lastRun, kind: .easy, durationSeconds: 40 * 60)]
            let asOf = F.date(week: 3, day: 0, hour: 6)
            let work = AdaptationEngine.Work(state: AdaptationState(), plan: plan, history: history, context: F.context(), asOf: asOf)
            return work.regrowth(asOf: asOf)
        }
        // Last run Wednesday of week 0, nothing until Monday of week 3: 18 days off.
        XCTAssertTrue(regrowth(lastRun: F.date(week: 0, day: 3, hour: 7)).weeks.isEmpty, "more than 14 days off: rule 4, no regrowth")
        // Last run Wednesday of week 1: 11 days off, weeks 1 and 2 cut.
        let short = regrowth(lastRun: F.date(week: 1, day: 2, hour: 7))
        XCTAssertFalse(short.weeks.isEmpty, "14 days or fewer: a regrowth")
        XCTAssertEqual(short.week(weekStart(3))?.step, 1)

        // Rule 4's weekly reading: three break weeks in a row (20 min each,
        // at most 25% of the pre-break 120) are a longer break, though no gap
        // is over 14 days; two are a short break, and a regrowth follows.
        func weekly(breakWeeks: Int) -> GuardrailRegrowth {
            let plan = (4..<10).flatMap { w in (0..<3).map { F.easy("p\(w)-\($0)", week: w, day: days[$0], minutes: 40) } }
            let history = (0..<4).flatMap { w in (0..<3).map { F.easy("h\(w)-\($0)", week: w, day: days[$0], minutes: 40) } }
                + (4..<(4 + breakWeeks)).map { F.easy("b\($0)", week: $0, day: 3, minutes: 20) }
            let asOf = F.date(week: 4 + breakWeeks, day: 0, hour: 6)
            let work = AdaptationEngine.Work(state: AdaptationState(), plan: plan, history: history,
                                             context: F.context(), asOf: asOf)
            return work.regrowth(asOf: asOf)
        }
        XCTAssertTrue(weekly(breakWeeks: 3).weeks.isEmpty, "a longer break by the weekly reading: no regrowth")
        XCTAssertEqual(weekly(breakWeeks: 2).week(weekStart(6))?.step, 1, "a short break: a regrowth")
    }

    /// After a planned recovery week the original plan rises more than 20%;
    /// a recovery week run at plan is not cut, and one run short is.
    func testAPlannedRecoveryWeekRunAtPlanIsNotCut() {
        XCTAssertFalse(isCut(readRegrowth(ran: [45, 45], week0: [30, 30, 30])), "90 min as planned, 120 after: the plan's own rise")
        XCTAssertTrue(isCut(readRegrowth(ran: [40, 40], week0: [30, 30, 30])), "80 of 90 min, 120 after")
        let r = readRegrowth(ran: [40, 40], week0: [30, 30, 30])
        XCTAssertEqual(r.week(weekStart(1))?.allowed(previous: 80 * 60) ?? 0, 96 * 60, accuracy: 1e-6,
                       "run short of the plan: 20% over what was run (the plan's own rise only after a week at plan)")
    }

    // MARK: Repair: a lone long run becomes an easy run

    /// A week whose only run is the long run: it is all of the week's
    /// running, so no cut fits the long-run share; it becomes an easy run at
    /// the 20-minute floor (#122: an easy run on the long-run day stays inside
    /// the share, or at the floor) and the week passes. With enough other
    /// running in the week the long run is cut as before, not swapped; with
    /// too little for a long run above its floor, it is swapped too.
    func testRepairTurnsALoneLongRunIntoAnEasyRunAtTheFloor() {
        let history = (0..<4).map { F.easy("h\($0)", week: 0, day: $0 * 2, minutes: 50.0) }   // 200 min
        let asOf = F.date(week: 1, day: 0, hour: 6)
        let lone = [F.long("l1", week: 1, day: 6, minutes: 50)]
        let r = GuardrailRepair.repair(plan: lone, history: history, asOf: asOf, freezes: [], context: F.context())
        XCTAssertTrue(r.report.passed, "\(r.report.violations.map(\.explanation))")
        XCTAssertEqual(r.plan.map(\.kind), [.easy])
        XCTAssertEqual(r.plan.first?.durationSeconds, PlanHeuristics.minimumEasyRunSeconds, "#122: not 50 min, all of the week")
        XCTAssertEqual(r.plan.first?.id, "l1")
        XCTAssertEqual(r.plan.first?.date, lone[0].date)
        let c = r.changes.first { $0.kind == .longRunSwappedToEasy }
        XCTAssertEqual(c?.workoutIDs, ["l1"])
        XCTAssertEqual(c?.triggers.first?.metric, .longRunShare)
        XCTAssertTrue(c?.rule.contains("SPEC 3.5 rules 5 and 6") ?? false)

        let paired = [F.easy("e1", week: 1, day: 2, minutes: 40), F.long("l1", week: 1, day: 6, minutes: 50)]
        let k = GuardrailRepair.repair(plan: paired, history: history, asOf: asOf, freezes: [], context: F.context())
        XCTAssertTrue(k.report.passed, "\(k.report.violations.map(\.explanation))")
        XCTAssertEqual(k.plan.first { $0.id == "l1" }?.kind, .long, "cut, not swapped")
        XCTAssertFalse(k.changes.contains { $0.kind == .longRunSwappedToEasy })
        // Too little other running for a long run above its floor: swapped too.
        let thin = [F.easy("e1", week: 1, day: 2, minutes: 20), F.long("l1", week: 1, day: 6, minutes: 50)]
        let t = GuardrailRepair.repair(plan: thin, history: history, asOf: asOf, freezes: [], context: F.context())
        XCTAssertTrue(t.report.passed, "\(t.report.violations.map(\.explanation))")
        XCTAssertEqual(t.plan.first { $0.id == "l1" }?.kind, .easy)
        XCTAssertEqual(t.plan.first { $0.id == "l1" }?.durationSeconds ?? 0, PlanHeuristics.minimumEasyRunSeconds, accuracy: 1e-6,
                       "#122: at the floor, not 50 min outside the long-run share")
        XCTAssertTrue(t.changes.contains { $0.kind == .longRunSwappedToEasy })
        // A long run already run is history: nothing to swap.
        let past = GuardrailRepair.repair(plan: [], history: history + [F.long("l0", week: 1, day: 0, minutes: 50)],
                                          asOf: F.date(week: 1, day: 1, hour: 6), freezes: [], context: F.context())
        XCTAssertFalse(past.changes.contains { $0.kind == .longRunSwappedToEasy })
    }

    func testTheSnapshotIsStoredAndAVersion3StateDecodesWithoutOne() throws {
        let o = AdaptationEngine.processDay(asOf: F.date(week: 0, day: 2, hour: 6), state: AdaptationState(), plan: F.weeks(0..<3),
                                            history: [], context: F.context())
        XCTAssertEqual(AdaptationState.formatVersion, 5)
        let data = try JSONEncoder().encode(o.state)
        let back = try JSONDecoder().decode(AdaptationState.self, from: data)
        XCTAssertEqual(back.planSnapshot, o.state.planSnapshot)
        XCTAssertEqual(back, o.state)

        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json["formatVersion"] = 3
        json.removeValue(forKey: "planSnapshot")
        let v3 = try JSONDecoder().decode(AdaptationState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(v3.planSnapshot, PlanSnapshot())
        // A version 3 state takes the plan handed in as the original plan.
        let next = AdaptationEngine.processDay(asOf: F.date(week: 0, day: 3, hour: 6), state: v3, plan: o.plan, history: o.history,
                                               context: F.context())
        XCTAssertEqual(next.state.planSnapshot.sessions.map(\.id), o.plan.map(\.id))
    }

    /// A state written by the version 3 build (main before #64, synthetic
    /// fixture: week 0's Tuesday threshold run and a check-in, dates in
    /// ISO 8601) decodes with an empty snapshot, and the next event takes
    /// the plan handed in as the original plan.
    func testARealVersion3StateDecodes() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let v3 = try decoder.decode(AdaptationState.self, from: Data(Self.version3State.utf8))
        XCTAssertEqual(v3.planSnapshot, PlanSnapshot())
        XCTAssertEqual(v3.assessments.map(\.plannedWorkoutID), ["t0"])
        XCTAssertEqual(v3.painCheckIns.count, 1)
        let asOf = F.date(week: 0, day: 2, hour: 6)
        let plan = F.weeks(0..<3).filter { $0.date >= cal.startOfDay(for: asOf) }
        let next = AdaptationEngine.processDay(asOf: asOf, state: v3, plan: plan, history: [], context: F.context(tracksPain: true))
        XCTAssertEqual(next.state.planSnapshot.sessions.map(\.id), plan.map(\.id))
        XCTAssertEqual(next.state.planSnapshot.returned, PlanSnapshot.returned(next.plan))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let again = try decoder.decode(AdaptationState.self, from: encoder.encode(next.state))
        XCTAssertEqual(again, next.state)
    }

    static let version3State = #"{"assessments":[{"activityID":"run-t0","date":"2026-01-06T07:00:00Z","kind":"quality.threshold","metrics":{"activityID":"run-t0","cadenceFadePercent":0,"climbMetersPerKm":0,"key":{"cadence":170,"heartRate":163.35000000000002,"seconds":1620,"speed":3.6852773171181354},"movingSeconds":3240,"paceSecondsPerKm":271.3499999999984,"plannedKeySeconds":1620,"plannedSeconds":3240},"plannedWorkoutID":"t0","signal":"onTrack","triggers":[{"detail":"pace 4:31\/km against a target of 4:27 to 4:35\/km","expectedHigh":275.4,"expectedLow":267.3,"metric":"pace","sourceID":"run-t0","unit":"secondsPerKm","value":271.3499999999984},{"detail":"heart rate 163 bpm against 157 to 170 bpm","expectedHigh":169.95000000000002,"expectedLow":156.75,"metric":"heartRate","sourceID":"run-t0","unit":"bpm","value":163.35000000000002}]}],"easyHeartRates":[],"easyPaceFactor":1,"formatVersion":3,"freezes":[],"holds":[],"longRuns":[],"painCheckIns":[{"date":"2026-01-06T20:00:00Z","score":3}],"painRecovery":{"cannotEnd":false,"flaggedThisStop":false,"prePlanWeeks":[],"stopFromMovement":false,"usualSamples":[{"date":"2026-01-06T20:00:00Z","score":3}]},"painReports":[],"qualityPaceFactor":1,"qualitySignals":[{"activityID":"run-t0","date":"2026-01-06T07:00:00Z","signal":"onTrack","triggers":[{"detail":"pace 4:31\/km against a target of 4:27 to 4:35\/km","expectedHigh":275.4,"expectedLow":267.3,"metric":"pace","sourceID":"run-t0","unit":"secondsPerKm","value":271.3499999999984},{"detail":"heart rate 163 bpm against 157 to 170 bpm","expectedHigh":169.95000000000002,"expectedLow":156.75,"metric":"heartRate","sourceID":"run-t0","unit":"bpm","value":163.35000000000002}]}],"reportedHoldShortfalls":[]}"#
}
