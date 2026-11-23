import XCTest
@testable import CoachCore

// A run with no usable time (no streams, and an elapsed duration that is NaN,
// infinite or negative) through the 3.5 guardrails (#40 reviews). Its week's
// time volume is unknown but at least L, the total of the week's sessions
// with a known time. The rules hold for every true volume: the 10% reference
// over it is the least it can be as a build week, max(L, 80% of the week
// before), and a reference of 0 resting on it allows nothing; it counts as a
// build week; the week after recovers only at most 80% of L; the rolling
// 4-week rule reads it at L. The one exception: the rolling rule for a week
// whose recent 4 hold an unknown week, reported as not evaluated unless over
// the limit even at L. Synthetic runs only.

final class UnknownTimeGuardrailTests: XCTestCase {
    private let utc = PlanFixture.utc
    private func date(_ week: Int, _ day: Int) -> Date { PlanFixture.date(week: week, day: day) }
    private func monday(_ week: Int) -> Date { PlanFixture.date(week: week, day: 0, hour: 0) }

    private func activity(_ id: String, week: Int, day: Int, minutes: Double) -> Activity {
        Activity(id: id, source: .healthKit, start: date(week, day), durationSeconds: minutes * 60,
                 distanceMeters: minutes * 60 * 3)
    }

    /// The broken run: a source that sent a duration of NaN and no samples.
    private func corrupt(_ id: String = "corrupt", week: Int, day: Int = 4) -> Activity {
        Activity(id: id, source: .healthKit, start: date(week, day), durationSeconds: .nan, distanceMeters: 61 * 60 * 3)
    }

    private func history(_ activities: [Activity]) -> [PlannedWorkout] {
        activities.compactMap { PlannedWorkout(activity: $0, kind: .easy) }
    }

    /// One planned easy session per week, starting at `week`.
    private func planned(_ minutes: [Double], from week: Int) -> [PlannedWorkout] {
        minutes.enumerated().map { k, m in
            PlanFixture.workout("p\(week + k)", week: week + k, day: 2, .easy, minutes: m)
        }
    }

    /// Weeks of one known run each (0 leaves a week empty); `unknownL` adds a
    /// broken run to a week, the number being that week's known minutes (nil
    /// for none).
    private func weeks(_ minutes: [Double?], unknownL: [Int: Double] = [:]) -> [Activity] {
        var out: [Activity] = []
        for (w, m) in minutes.enumerated() {
            if let m, m > 0 { out.append(activity("k\(w)", week: w, day: 1, minutes: m)) }
            if let l = unknownL[w] {
                if l > 0 { out.append(activity("k\(w)", week: w, day: 1, minutes: l)) }
                out.append(corrupt("u\(w)", week: w))
            }
        }
        return out
    }

    private func check(_ runs: [Activity], _ plan: [PlannedWorkout]) -> GuardrailReport {
        GuardrailChecker.check(history: history(runs), planned: plan, timeZone: utc)
    }

    private func weeks(of r: GuardrailReport, _ rule: GuardrailRule) -> [Date] {
        r.violations.filter { $0.rule == rule }.map(\.weekStart)
    }

    // MARK: 10% reference over an unknown week

    func testRoundOneProbeIsFlaggedAtEveryWeek() {
        // 100, 110, then 60 known plus the broken run, then 3 x 121. Week 2 may
        // have been a build week of just over 88 min (80% of 110), so week 3 is
        // allowed 96.8 min, and weeks 3 to 5 are builds 4 to 6.
        let r = check(weeks([100, 110, nil], unknownL: [2: 60]), planned([121, 121, 121], from: 3))
        XCTAssertEqual(weeks(of: r, .recoveryWeek), [monday(3), monday(4), monday(5)])
        let rise = r.violations.first { $0.rule == .weeklyIncrease }
        XCTAssertEqual(rise?.weekStart, monday(3))
        XCTAssertEqual(rise?.allowed ?? 0, 88 * 60 * 1.1, accuracy: 1e-6)
    }

    func testReviewerProbeAfterARecoveryWeek() throws {
        // 300, 200 (a recovery week), unknown with 140 known, then 330: the
        // unknown week may have been a build week of just over 160 (80% of 200).
        let runs = weeks([300, 200, nil], unknownL: [2: 140])
        let v = try XCTUnwrap(check(runs, planned([330], from: 3)).violations.first { $0.rule == .weeklyIncrease })
        XCTAssertEqual(v.allowed, 176 * 60, accuracy: 1e-6)
        XCTAssertTrue(v.explanation.contains("unknown"), v.explanation)
        XCTAssertFalse(check(runs, planned([176], from: 3)).violations.contains { $0.rule == .weeklyIncrease })
    }

    func testReviewerProbeKnownPartAboveTheRecoveryLine() throws {
        // 100, unknown with 60 known, then 110. The unknown week may have been
        // 81 min (a build week), which allows 89.1: the bound is 88.
        let runs = weeks([100, nil], unknownL: [1: 60])
        let v = try XCTUnwrap(check(runs, planned([110], from: 2)).violations.first { $0.rule == .weeklyIncrease })
        XCTAssertEqual(v.allowed, 88 * 60, accuracy: 1e-6)
        // When the known part is over the line it is the bound: 100, unknown with 95 known.
        let high = weeks([100, nil], unknownL: [1: 95])
        let w = try XCTUnwrap(check(high, planned([110], from: 2)).violations.first { $0.rule == .weeklyIncrease })
        XCTAssertEqual(w.allowed, 95 * 60 * 1.1, accuracy: 1e-6)
    }

    func testOnlyTheBrokenRunInItsWeek() throws {
        // 100, 110, the broken run alone: still at least 88 as a build week.
        let runs = weeks([100, 110, nil], unknownL: [2: 0])
        let v = try XCTUnwrap(check(runs, planned([200], from: 3)).violations.first { $0.rule == .weeklyIncrease })
        XCTAssertEqual(v.allowed, 88 * 60 * 1.1, accuracy: 1e-6)
        XCTAssertEqual(v.measured, 200 * 60, accuracy: 1e-9)
    }

    func testEmptyWeekAfterAnUnknownWeek() throws {
        // 100, unknown with 60 known, an empty week (a recovery week), then 80:
        // the reference is the week before the recovery week, at least 60.
        let runs = weeks([100, nil, 0], unknownL: [1: 60])
        let v = try XCTUnwrap(check(runs, planned([80], from: 3)).violations.first { $0.rule == .weeklyIncrease })
        XCTAssertEqual(v.allowed, 66 * 60, accuracy: 1e-6)
        // With nothing known in the unknown week it may have been almost
        // nothing, so no rise over it is known to be safe: allowed 0.
        let none = check(weeks([100, nil, 0], unknownL: [1: 0]), planned([80], from: 3))
        let z = try XCTUnwrap(none.violations.first { $0.rule == .weeklyIncrease && $0.weekStart == monday(3) })
        XCTAssertEqual(z.allowed, 0)
    }

    // MARK: A reference of 0 over an unknown week (round-3 probes)

    private func assertAllowsNothing(_ runs: [Activity], planWeek: Int,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let r = check(runs, planned([300], from: planWeek))
        let v = try XCTUnwrap(r.violations.first { $0.rule == .weeklyIncrease && $0.weekStart == monday(planWeek) },
                              "\(r.notEvaluated.map(\.reason))", file: file, line: line)
        XCTAssertEqual(v.allowed, 0, file: file, line: line)
        XCTAssertEqual(v.measured, 300 * 60, accuracy: 1e-9, file: file, line: line)
        XCTAssertTrue(v.explanation.contains("unknown"), v.explanation, file: file, line: line)
    }

    func testProbeEmptyThenCorruptOnlyWeek() throws {
        // (a) 100, empty, the broken run alone, then 300.
        try assertAllowsNothing(weeks([100, 0, nil], unknownL: [2: 0]), planWeek: 3)
    }

    func testProbeCorruptOnlyWeekThenEmpty() throws {
        // (b) 100, the broken run alone, empty (a recovery week), then 300.
        try assertAllowsNothing(weeks([100, nil, 0], unknownL: [1: 0]), planWeek: 3)
    }

    func testProbeCorruptOnlyFirstWeek() throws {
        // (c) the broken run alone in the first week, then 300.
        try assertAllowsNothing(weeks([nil], unknownL: [0: 0]), planWeek: 1)
    }

    func testKnownEmptyWeekStillSkips() {
        // A known zero week gives no percentage to measure, as before (three
        // empty weeks, a long break under 3.5 rule 4: the plain rules apply).
        let r = check(weeks([100, 0, 0, 0]), planned([300], from: 4))
        XCTAssertFalse(r.violations.contains { $0.rule == .weeklyIncrease })
        XCTAssertTrue(r.notEvaluated.contains { $0.rule == .weeklyIncrease && $0.weekStart == monday(4) })
        // Two empty weeks are a short break: the return ramp caps the week (#62).
        let short = check(weeks([100, 0, 0]), planned([300], from: 3))
        XCTAssertEqual(short.violations.first { $0.rule == .weeklyIncrease }?.allowed ?? 0, 70 * 60, accuracy: 1e-6)
    }

    func testBuilderWaitsAWeekAfterACorruptOnlyWeek() {
        // The builder refuses with a wait-a-week reason, not noWorkableWeek.
        for (label, runs) in [("a", weeks([200, 200, 200, 0, nil], unknownL: [4: 0])),
                              ("b", weeks([200, 200, 200, nil, 0], unknownL: [3: 0]))] {
            let start = PlanFixture.date(week: 5, day: 0, hour: 6)
            let result = PlanBuilder.build(input(start: start, recentWeekly: 200 * 60), history: history(runs), timeZone: utc)
            XCTAssertEqual(result.issues, [.historyVolumeUnknown(rebuildOn: monday(6))], label)
        }
    }

    func testTwoUnknownWeeksInARow() throws {
        // 100, unknown (60 known), unknown (30 known), then 60: the second may
        // have been a build week just over 80% of the first's least, 48.
        let runs = weeks([100, nil, nil], unknownL: [1: 60, 2: 30])
        let v = try XCTUnwrap(check(runs, planned([60], from: 3)).violations.first { $0.rule == .weeklyIncrease })
        XCTAssertEqual(v.allowed, 48 * 60 * 1.1, accuracy: 1e-6)
    }

    // MARK: Recovery cadence

    func testUnknownWeekCountsAsABuildWeek() {
        // 3 builds, an unknown week (90 known), then a build: 5 in a row.
        let runs = weeks([100, 100, 100, nil], unknownL: [3: 90])
        XCTAssertEqual(weeks(of: check(runs, planned([90], from: 4)), .recoveryWeek), [monday(4)])
        // At most 80% of the known 90 min, the week after is a recovery week
        // whatever the unknown week held.
        XCTAssertTrue(weeks(of: check(runs, planned([72], from: 4)), .recoveryWeek).isEmpty)
        XCTAssertEqual(weeks(of: check(runs, planned([73], from: 4)), .recoveryWeek), [monday(4)])
    }

    // MARK: Rolling 4 weeks

    func testRollingCheckRunsWithAnUnknownWeekInTheEarlierFour() throws {
        // 8 weeks: 4 earlier (one unknown with 50 known) and 4 recent.
        // Earlier at least 100 + 50 + 100 + 100 = 350, so 455 is the most for the recent 4.
        let runs = weeks([100, nil, 100, 100, 110, 115, 120], unknownL: [1: 50])
        let r = check(runs, planned([125], from: 7))
        let v = try XCTUnwrap(r.violations.first { $0.rule == .fourWeekIncrease })
        XCTAssertEqual(v.allowed, 350 * 60 * 1.3, accuracy: 1e-6)
        XCTAssertEqual(v.measured, 470 * 60, accuracy: 1e-6)
        XCTAssertTrue(v.explanation.contains("at least"), v.explanation)
        // Known throughout, the same timeline is fine at 100 for week 1.
        XCTAssertFalse(check(weeks([100, 100, 100, 100, 110, 115, 120]), planned([125], from: 7))
            .violations.contains { $0.rule == .fourWeekIncrease })
    }

    func testRollingCheckWithAnUnknownWeekInTheRecentFour() {
        // The unknown week is in the recent 4: a total over the limit even at
        // its known part is a violation; otherwise the check is not evaluated.
        let runs = weeks([100, 100, 100, 100, 100, nil, 100], unknownL: [5: 100])
        let fine = check(runs, planned([100], from: 7))
        XCTAssertFalse(fine.violations.contains { $0.rule == .fourWeekIncrease })
        XCTAssertTrue(fine.notEvaluated.contains { $0.rule == .fourWeekIncrease && $0.weekStart == monday(7) })
        let over = check(weeks([100, 100, 100, 100, 100, nil, 100], unknownL: [5: 200]), planned([130], from: 7))
        XCTAssertTrue(over.violations.contains { $0.rule == .fourWeekIncrease })
    }

    // MARK: Both history paths

    func testBaselinePlanHistoryBehavesTheSameAsTheActivityPath() throws {
        let runs = weeks([100, 110, nil], unknownL: [2: 60])
        let opts = BaselineOptions(asOf: monday(3).addingTimeInterval(3600), timeZone: utc)
        let report = BaselineBuilder.build(activities: runs, options: opts)
        let run = try XCTUnwrap(report.runs.first { $0.activityID == "u2" })
        XCTAssertFalse(run.movingTimeIsKnown)
        XCTAssertEqual(run.movingSeconds, 0, "the weekly load still counts it as 0")

        let fromBaseline = BaselinePlanMapping.planHistory(from: report)
        let fromActivities = history(runs)
        XCTAssertEqual(fromBaseline.count, fromActivities.count, "the broken run is kept, not left out")
        for w in fromActivities {
            let b = try XCTUnwrap(fromBaseline.first { $0.id == w.id && $0.date == w.date })
            XCTAssertEqual(b.volume(.time), w.volume(.time), w.id)
        }
        let plan = planned([121, 121, 121], from: 3)
        XCTAssertEqual(GuardrailChecker.check(history: fromActivities, planned: plan, timeZone: utc),
                       GuardrailChecker.check(history: fromBaseline, planned: plan, timeZone: utc))
    }

    // MARK: AdaptationEngine

    func testAdaptationRepairsOrFlagsAfterABrokenRun() throws {
        let done = history(weeks([100, 110, 60]))
        let plan = planned([121, 121, 121], from: 3)
        let zones = try XCTUnwrap(HRZones(lthr: 165))
        let context = AdaptationContext(zones: zones, timeZone: utc, tracksPain: false)
        let o = AdaptationEngine.processRun(CompletedRun(activity: corrupt(week: 2)), state: AdaptationState(),
                                            plan: plan, history: done, context: context)
        XCTAssertNil(try XCTUnwrap(o.history.first { $0.id == "corrupt" }).volume(.time))
        let recheck = GuardrailChecker.check(history: o.history, planned: o.plan, timeZone: utc)
        XCTAssertEqual(recheck.violations, o.guardrailReport.violations)
        if o.guardrailReport.passed {
            let volumes = PlanWeek.weeks(from: o.plan, timeZone: utc).compactMap { $0.volume(.time) }
            XCTAssertNotEqual(volumes, [121.0 * 60, 121.0 * 60, 121.0 * 60], "the plan must change")
            XCTAssertFalse(o.changes.isEmpty)
        } else {
            XCTAssertFalse(o.guardrailReport.violations.isEmpty)
        }
        // A known 0-minute run instead: week 2 is a 60-min recovery week and nothing changes.
        let o0 = AdaptationEngine.processRun(CompletedRun(activity: activity("tiny", week: 2, day: 4, minutes: 0)),
                                             state: AdaptationState(), plan: plan, history: done, context: context)
        XCTAssertTrue(o0.guardrailReport.passed)
    }

    func testAdaptationLeavesAZeroReferenceUncutAndSaysWhenToRebuild() throws {
        // The round-4 probe: 100, then an empty week and a week whose only run
        // is the broken one (both orders), the broken run being processed.
        // Ahead, weeks 3 to 6 that keep every other rule: 3 easy runs and a
        // long run, 220 min, with week 5 a 170-min recovery week. (The
        // reviewer's 2 x 50 + 90 also breaks the long-run share and, with
        // four builds in a row, the cadence, which repair rightly fixes.)
        let zones = try XCTUnwrap(HRZones(lthr: 165))
        let context = AdaptationContext(zones: zones, timeZone: utc, tracksPain: false)
        var plan: [PlannedWorkout] = []
        for w in 3...6 {
            let (easy, long): (Double, Double) = w == 5 ? (40, 50) : (50, 70)
            for (k, day) in [1, 2, 4].enumerated() {
                plan.append(PlanFixture.workout("e\(w)\(k)", week: w, day: day, .easy, minutes: easy))
            }
            plan.append(PlanFixture.workout("l\(w)", week: w, day: 6, .long, minutes: long))
        }
        for (label, brokenWeek) in [("empty, then broken", 2), ("broken, then empty", 1)] {
            let done = history([activity("k0", week: 0, day: 1, minutes: 100)])
            let o = AdaptationEngine.processRun(CompletedRun(activity: corrupt(week: brokenWeek)), state: AdaptationState(),
                                                plan: plan, history: done, context: context)
            let before = GuardrailChecker.check(history: o.history, planned: plan, timeZone: utc)
            XCTAssertEqual(o.plan, plan, "\(label): \(o.changes.map(\.explanation))")
            XCTAssertTrue(o.changes.isEmpty, label)
            XCTAssertEqual(o.guardrailReport.violations, before.violations, label)
            XCTAssertEqual(o.guardrailReport.violations.count, 1, label)
            let v = try XCTUnwrap(o.guardrailReport.violations.first { $0.rule == .weeklyIncrease }, label)
            XCTAssertEqual(v.weekStart, monday(3), label)
            XCTAssertEqual(v.allowed, 0, label)
            XCTAssertEqual(v.rebuildOn, monday(4), label)
            XCTAssertEqual(o.rebuildOn, monday(4), label)
        }
        // A known 200-min week instead, under the plain rules (the return ramp
        // off): the plan passes and there is no signal.
        let plainContext = AdaptationContext(zones: zones, timeZone: utc, tracksPain: false,
                                             guardrails: GuardrailLimits(maxShortBreakWeeks: 0))
        let known = AdaptationEngine.processRun(CompletedRun(activity: activity("k2", week: 2, day: 4, minutes: 200)),
                                                state: AdaptationState(), plan: plan,
                                                history: history([activity("k0", week: 0, day: 1, minutes: 100)]),
                                                context: plainContext)
        XCTAssertTrue(known.guardrailReport.passed, "\(known.guardrailReport.violations.map(\.explanation))")
        XCTAssertEqual(known.plan, plan)
        XCTAssertNil(known.rebuildOn)
        // By default the empty week 1 is a short break after 100 min (3.5 rule
        // 4, #62): week 3 is week 2 back, at most 90% of the pre-break 100 min.
        let ramp = GuardrailChecker.check(history: known.history, planned: plan, timeZone: utc)
        let v = try XCTUnwrap(ramp.violations.first { $0.rule == .weeklyIncrease })
        XCTAssertEqual(v.weekStart, monday(3))
        XCTAssertEqual(v.allowed, 90 * 60, accuracy: 1e-6)
    }

    // MARK: Pain freeze after an unknown week (round 5)

    /// A freeze over weeks `from` to `through` (Monday of `from` to the Monday after `through`).
    private func freeze(_ from: Int, through: Int) -> DateInterval {
        DateInterval(start: monday(from), end: monday(through + 1))
    }

    private func checkFrozen(_ runs: [Activity], _ plan: [PlannedWorkout], frozen: Int) -> GuardrailReport {
        GuardrailChecker.check(history: history(runs), planned: plan, timeZone: utc,
                               freezes: [freeze(frozen, through: frozen)])
    }

    func testFreezeHoldsToTheKnownPartOfAnUnknownWeek() throws {
        // The reviewer's probe: 100, then 100 known plus the broken run, then a
        // frozen week of 109. Were the broken run 0.5 min, 109 would grow.
        let runs = weeks([100, nil], unknownL: [1: 100])
        let r = checkFrozen(runs, planned([109], from: 2), frozen: 2)
        let v = try XCTUnwrap(r.violations.first { $0.rule == .volumeFreeze })
        XCTAssertEqual(v.allowed, 100 * 60, accuracy: 1e-9)
        XCTAssertEqual(v.measured, 109 * 60, accuracy: 1e-9)
        XCTAssertNil(v.rebuildOn)
        XCTAssertTrue(v.explanation.contains("unknown"), v.explanation)
        XCTAssertFalse(r.notEvaluated.contains { $0.rule == .volumeFreeze })
        // At the known part it holds.
        XCTAssertFalse(checkFrozen(runs, planned([100], from: 2), frozen: 2).violations.contains { $0.rule == .volumeFreeze })
    }

    func testFreezeAfterACorruptOnlyWeekAllowsNothing() throws {
        let r = checkFrozen(weeks([100, nil], unknownL: [1: 0]), planned([60], from: 2), frozen: 2)
        let v = try XCTUnwrap(r.violations.first { $0.rule == .volumeFreeze })
        XCTAssertEqual(v.allowed, 0)
        XCTAssertEqual(v.rebuildOn, monday(3))
    }

    func testFreezeAfterAKnownWeekIsUnchanged() throws {
        let r = checkFrozen(weeks([100, 100]), planned([109], from: 2), frozen: 2)
        let v = try XCTUnwrap(r.violations.first { $0.rule == .volumeFreeze })
        XCTAssertEqual(v.allowed, 100 * 60, accuracy: 1e-9)
        XCTAssertNil(v.rebuildOn)
        XCTAssertFalse(v.explanation.contains("unknown"), v.explanation)
        XCTAssertFalse(checkFrozen(weeks([100, 100]), planned([100], from: 2), frozen: 2)
            .violations.contains { $0.rule == .volumeFreeze })
        // A known empty week before: still not evaluated.
        let empty = checkFrozen(weeks([100, 0, 0]), planned([60], from: 3), frozen: 3)
        XCTAssertFalse(empty.violations.contains { $0.rule == .volumeFreeze })
        XCTAssertTrue(empty.notEvaluated.contains { $0.rule == .volumeFreeze && $0.weekStart == monday(3) })
    }

    func testRepairCutsAFreezeToTheKnownPartAndLeavesAZeroOneAlone() throws {
        let zones = try XCTUnwrap(HRZones(lthr: 165))
        let context = AdaptationContext(zones: zones, timeZone: utc, tracksPain: false)
        // Week 2 frozen, planned 3 x 25 easy and a 34-min long run (109 min).
        let plan = [PlanFixture.workout("e1", week: 2, day: 1, .easy, minutes: 25),
                    PlanFixture.workout("e2", week: 2, day: 2, .easy, minutes: 25),
                    PlanFixture.workout("e3", week: 2, day: 4, .easy, minutes: 25),
                    PlanFixture.workout("l", week: 2, day: 6, .long, minutes: 34)]
        let freezes = [freeze(2, through: 2)]
        let asOf = PlanFixture.date(week: 2, day: 0, hour: 0)
        // L = 100: cut to at most 100 and the freeze holds.
        let h = history(weeks([100, nil], unknownL: [1: 100]))
        let cut = GuardrailRepair.repair(plan: plan, history: h, asOf: asOf, freezes: freezes, context: context)
        XCTAssertFalse(cut.report.violations.contains { $0.rule == .volumeFreeze }, "\(cut.report.violations)")
        let total = cut.plan.reduce(0) { $0 + $1.durationSeconds }
        XCTAssertLessThanOrEqual(total, 100 * 60)
        XCTAssertGreaterThan(total, 90 * 60, "cut to the known part, not to the floors")
        XCTAssertFalse(cut.changes.isEmpty)
        // L = 0: left as it is, the violation kept with its rebuild date. The
        // week plans 80 min, within the 10% rule's own bound (88), so the
        // freeze is the only rule broken.
        let light = plan.map { $0.resized(toSeconds: 20 * 60) }
        let h0 = history(weeks([100, nil], unknownL: [1: 0]))
        let kept = GuardrailRepair.repair(plan: light, history: h0, asOf: asOf, freezes: freezes, context: context)
        XCTAssertEqual(kept.plan, light)
        XCTAssertEqual(kept.report.violations.count, 1, "\(kept.report.violations)")
        XCTAssertTrue(kept.changes.isEmpty)
        let v = try XCTUnwrap(kept.report.violations.first { $0.rule == .volumeFreeze })
        XCTAssertEqual(v.rebuildOn, monday(3))
    }

    // MARK: The checked week itself unknown (round 6)

    /// History plus a broken run in `week`, and sessions of that week still to come.
    private func mixed(_ before: [Double?], brokenWeek: Int) -> [PlannedWorkout] {
        history(weeks(before) + [corrupt(week: brokenWeek, day: 0)])
    }

    func testRiseInAnUnknownWeekIsFlaggedAtItsKnownPart() throws {
        // 100, then a broken run plus 60 + 60 + 60 planned: at least 180 > 110.
        let h = mixed([100], brokenWeek: 1)
        let plan = [PlanFixture.workout("a", week: 1, day: 1, .easy, minutes: 60),
                    PlanFixture.workout("b", week: 1, day: 3, .easy, minutes: 60),
                    PlanFixture.workout("l", week: 1, day: 6, .long, minutes: 60)]
        let r = GuardrailChecker.check(history: h, planned: plan, timeZone: utc)
        let v = try XCTUnwrap(r.violations.first { $0.rule == .weeklyIncrease })
        XCTAssertEqual(v.measured, 180 * 60, accuracy: 1e-9)
        XCTAssertEqual(v.allowed, 110 * 60, accuracy: 1e-6)
        XCTAssertTrue(v.explanation.contains("at least"), v.explanation)
        // Within the allowance at its known part: not evaluated, not passed.
        let low = GuardrailChecker.check(history: h, planned: Array(plan.prefix(1)), timeZone: utc)
        XCTAssertFalse(low.violations.contains { $0.rule == .weeklyIncrease })
        XCTAssertTrue(low.notEvaluated.contains { $0.rule == .weeklyIncrease && $0.weekStart == monday(1) })
    }

    func testFreezeOverAMixedWeek() throws {
        let h = mixed([100], brokenWeek: 1)
        let freezes = [freeze(1, through: 1)]
        let over = [PlanFixture.workout("a", week: 1, day: 2, .easy, minutes: 60),
                    PlanFixture.workout("b", week: 1, day: 4, .easy, minutes: 60)]
        let r = GuardrailChecker.check(history: h, planned: over, timeZone: utc, freezes: freezes)
        let v = try XCTUnwrap(r.violations.first { $0.rule == .volumeFreeze })
        XCTAssertEqual(v.measured, 120 * 60, accuracy: 1e-9)
        XCTAssertEqual(v.allowed, 100 * 60, accuracy: 1e-9)
        XCTAssertNil(v.rebuildOn)
        let within = over.map { $0.resized(toSeconds: 40 * 60) }
        let w = GuardrailChecker.check(history: h, planned: within, timeZone: utc, freezes: freezes)
        XCTAssertFalse(w.violations.contains { $0.rule == .volumeFreeze })
        XCTAssertTrue(w.notEvaluated.contains { $0.rule == .volumeFreeze && $0.weekStart == monday(1) })
    }

    func testLongRunShareInAnUnknownWeekIsNotEvaluated() {
        // A broken run plus 20 min easy and an 80-min long run: 80% of the
        // known part is only the worst case (the broken run may have been
        // long), so the share is not evaluated, over or within it.
        let h = mixed([100], brokenWeek: 1)
        for (easy, long) in [(20.0, 80.0), (70, 30)] {
            let plan = [PlanFixture.workout("a", week: 1, day: 2, .easy, minutes: easy),
                        PlanFixture.workout("l", week: 1, day: 6, .long, minutes: long)]
            let r = GuardrailChecker.check(history: h, planned: plan, timeZone: utc)
            XCTAssertFalse(r.violations.contains { $0.rule == .longRunShare }, "\(easy) + \(long)")
            XCTAssertTrue(r.notEvaluated.contains { $0.rule == .longRunShare && $0.weekStart == monday(1) }, "\(easy) + \(long)")
        }
    }

    func testAdaptationKeepsTheLongRunInAnUnknownWeek() throws {
        // The round-7 probe: 300, 300, 240, 300, then a broken run done on
        // Monday with 30 min easy and a 90-min long run still to come. Were the
        // broken run 140 to 210 min, the plan keeps every rule; the long run
        // stays at 90.
        let zones = try XCTUnwrap(HRZones(lthr: 165))
        let context = AdaptationContext(zones: zones, timeZone: utc, tracksPain: false)
        // Probe 2: a lone 100-min long run still to come stays too (it keeps
        // every rule for a broken run of 190 to 230 min).
        let probes: [([PlannedWorkout], ClosedRange<Double>)] = [
            ([PlanFixture.workout("a", week: 4, day: 2, .easy, minutes: 30),
              PlanFixture.workout("l", week: 4, day: 6, .long, minutes: 90)], 140...210),
            ([PlanFixture.workout("l", week: 4, day: 6, .long, minutes: 100)], 190...230)]
        for (plan, passing) in probes {
            let o = AdaptationEngine.processRun(CompletedRun(activity: corrupt(week: 4, day: 0)), state: AdaptationState(),
                                                plan: plan, history: history(weeks([300, 300, 240, 300])), context: context)
            XCTAssertEqual(o.plan, plan, "\(o.changes.map(\.explanation))")
            XCTAssertTrue(o.changes.isEmpty)
            XCTAssertEqual(o.plan.first { $0.id == "l" }?.durationSeconds, plan.last?.durationSeconds)
            XCTAssertTrue(o.guardrailReport.notEvaluated.contains { $0.rule == .longRunShare && $0.weekStart == monday(4) })
            for m in stride(from: passing.lowerBound, through: passing.upperBound, by: 10) {
                let r = GuardrailChecker.check(history: resolved(o.history, minutes: m), planned: o.plan, timeZone: utc)
                XCTAssertTrue(r.passed, "\(Int(m)) min: \(r.violations.map(\.explanation))")
            }
        }
    }

    func testAdaptationCutsOnlySessionsToComeInAnUnknownWeek() throws {
        // The round-6 probe: 100, then a broken run on Monday of week 1 with
        // 60 + 60 easy and a 60-min long run still to come.
        let zones = try XCTUnwrap(HRZones(lthr: 165))
        let context = AdaptationContext(zones: zones, timeZone: utc, tracksPain: false)
        let plan = [PlanFixture.workout("a", week: 1, day: 1, .easy, minutes: 60),
                    PlanFixture.workout("b", week: 1, day: 3, .easy, minutes: 60),
                    PlanFixture.workout("l", week: 1, day: 6, .long, minutes: 60)]
        let o = AdaptationEngine.processRun(CompletedRun(activity: corrupt(week: 1, day: 0)), state: AdaptationState(),
                                            plan: plan, history: history(weeks([100])), context: context)
        // The run already done stays as it is; only sessions to come change.
        let done = try XCTUnwrap(o.history.first { $0.id == "corrupt" })
        XCTAssertTrue(done.durationSeconds.isNaN)
        XCTAssertFalse(o.changes.isEmpty)
        for c in o.changes { XCTAssertTrue(Set(c.workoutIDs).isSubset(of: ["a", "b", "l"]), "\(c.workoutIDs)") }
        let known = o.plan.reduce(0) { $0 + $1.durationSeconds }
        XCTAssertLessThanOrEqual(known, 110 * 60 + 1e-6)
        XCTAssertFalse(o.guardrailReport.violations.contains { $0.rule == .weeklyIncrease || $0.rule == .longRunShare },
                       "\(o.guardrailReport.violations.map(\.explanation))")
        XCTAssertEqual(o.guardrailReport.violations, GuardrailChecker.check(history: o.history, planned: o.plan, timeZone: utc).violations)
    }

    /// Adaptation path: a broken run done on Monday of the current week, with
    /// sessions to come that week and after. Whatever the broken run truly
    /// lasted, every rule broken by the adapted plan was flagged or reported
    /// not evaluated for that week; the run already done is never touched.
    func testAdaptationFuzzWithAnUnknownRunInTheCheckedWeek() throws {
        var state: UInt64 = 0x2545F4914F6CDD1D
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        let zones = try XCTUnwrap(HRZones(lthr: 165))
        let context = AdaptationContext(zones: zones, timeZone: utc, tracksPain: false)
        var changed = 0
        for c in 0..<40 {
            let n = 3 + Int(next() * 6)                 // history weeks before the current one
            let base = 120 + next() * 200
            var runs: [Activity] = []
            for w in 0..<n {
                let total = (base * (0.85 + 0.3 * next())).rounded()
                runs.append(activity("h\(w)a", week: w, day: 1, minutes: (total / 2).rounded()))
                runs.append(activity("h\(w)b", week: w, day: 4, minutes: (total / 2).rounded()))
            }
            var plan: [PlannedWorkout] = []
            for w in n...(n + 3) {
                let total = base * (0.7 + 0.8 * next())
                let longShare = 0.2 + 0.4 * next()
                let easy = (total * (1 - longShare) / 2).rounded(), long = (total * longShare).rounded()
                plan.append(PlanFixture.workout("p\(w)a", week: w, day: 2, .easy, minutes: max(20, easy)))
                plan.append(PlanFixture.workout("p\(w)b", week: w, day: 4, .easy, minutes: max(20, easy)))
                plan.append(PlanFixture.workout("p\(w)l", week: w, day: 6, .long, minutes: max(20, long)))
            }
            let o = AdaptationEngine.processRun(CompletedRun(activity: corrupt(week: n, day: 0)), state: AdaptationState(),
                                                plan: plan, history: history(runs), context: context)
            if !o.changes.isEmpty { changed += 1 }
            XCTAssertTrue(try XCTUnwrap(o.history.first { $0.id == "corrupt" }).durationSeconds.isNaN, "case \(c)")
            for ch in o.changes {
                XCTAssertTrue(ch.workoutIDs.allSatisfy { $0.hasPrefix("p") }, "case \(c): \(ch.workoutIDs)")
            }
            let asGiven = GuardrailChecker.check(history: o.history, planned: o.plan, timeZone: utc)
            func key(_ rule: GuardrailRule, _ week: Date) -> String { "\(rule.rawValue)@\(week.timeIntervalSince1970)" }
            let reported = Set(asGiven.violations.map { key($0.rule, $0.weekStart) })
                .union(asGiven.notEvaluated.map { key($0.rule, $0.weekStart) })
            for m in [0.5] + Array(stride(from: 15.0, through: 150, by: 15)) {
                let r = GuardrailChecker.check(history: resolved(o.history, minutes: m), planned: o.plan, timeZone: utc)
                let missed = r.violations.filter { !reported.contains(key($0.rule, $0.weekStart)) }
                XCTAssertTrue(missed.isEmpty, "case \(c), \(Int(m)) min: \(missed.map(\.explanation))")
            }
        }
        XCTAssertGreaterThan(changed, 5, "the fuzz should make the engine cut")
    }

    // MARK: PlanBuilder ledger

    func testLedgerUsesTheLowerBound() {
        typealias L = PlanBuilder.LoadLedger
        XCTAssertEqual(L(volumes: [6000, 6600, nil], limits: .default, lows: [6000, 6600, 3600]).nextCap,
                       6600 * 0.8 * 1.1, accuracy: 1e-6)
        XCTAssertEqual(L(volumes: [6000, 6600, nil], limits: .default, lows: [6000, 6600, 6000]).nextCap,
                       6000 * 1.1, accuracy: 1e-6)
        XCTAssertEqual(L(volumes: [6000, 6600, nil], limits: .default).streak, 3, "an unknown week is a build week")
        // Empty week after an unknown one: 110% of its known part, or nothing when none is known.
        // The empty week may also be a 1-week break after a pre-break mean of
        // at least 4800 (3.5 rule 4, #62): the return ramp then allows 70% of it.
        XCTAssertEqual(L(volumes: [6000, nil, 0], limits: .default, lows: [6000, 3600, 0]).nextCap, 0.7 * 4800, accuracy: 1e-6)
        XCTAssertEqual(L(volumes: [6000, nil, 0], limits: GuardrailLimits(maxShortBreakWeeks: 0), lows: [6000, 3600, 0]).nextCap,
                       3960, accuracy: 1e-6)
        XCTAssertEqual(L(volumes: [6000, nil, 0], limits: .default).nextCap, 0)
        // Recovery after an unknown week: at most 80% of its known part.
        XCTAssertTrue(L(volumes: [6000, nil, 2880], limits: .default, lows: [6000, 3600, 0]).isRecovery(2))
        XCTAssertFalse(L(volumes: [6000, nil, 2881], limits: .default, lows: [6000, 3600, 0]).isRecovery(2))
        XCTAssertFalse(L(volumes: [6000, nil, 1], limits: .default).isRecovery(2))
        // Rolling 4 weeks: the earlier window at its lower bound.
        let rolling = L(volumes: [6000, nil, 6000, 6000, 6600, 6900, 7200], limits: .default,
                        lows: [6000, 3000, 6000, 6000, 6600, 6900, 7200])
        XCTAssertEqual(rolling.nextCap, 21_000 * 1.3 - 20_700, accuracy: 1e-6)
    }

    func testOpenStartWeekAfterAnUnknownWeekWaitsForTheWeekToClose() throws {
        let set = PlanBuilder.ledgers(volumes: [6000, 6600, nil, 1800], lows: [6000, 6600, 3600, 1800],
                                      lastWeekOpen: true, recentWeekly: 6000, limits: .default)
        XCTAssertTrue(set.openWithoutReference)
        // Through the builder: 6 known weeks, an unknown one, then a Wednesday start.
        var runs = weeks([200, 200, 150, 200, 210, 220, nil], unknownL: [6: 100])
        runs.append(activity("mon", week: 7, day: 0, minutes: 40))
        let start = PlanFixture.date(week: 7, day: 2, hour: 9)
        let result = PlanBuilder.build(input(start: start, recentWeekly: 200 * 60), history: history(runs), timeZone: utc)
        XCTAssertEqual(result.issues, [.startWeekWithoutReference(rebuildOn: monday(8))])
    }

    // MARK: PlanBuilder

    private func input(start: Date, recentWeekly: Double, raceWeek: Int = 6 + 9) -> PlanInput {
        let five = 22.0 * 60
        return PlanInput(raceDistanceMeters: Distance.tenK, raceDate: PlanFixture.date(week: raceWeek, day: 6, hour: 8),
                         goalSeconds: nil, startDate: start,
                         trainingDays: [.tuesday, .thursday, .saturday, .sunday], longRunDay: .sunday,
                         maxSessionSeconds: nil, recentWeeklySeconds: recentWeekly, recentLongRunSeconds: 60 * 60,
                         heartRateZones: HRZones(lthr: 165),
                         easyPace: EasyPaceSample(secondsPerKm: 345, heartRate: 135),
                         fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: five),
                         predictedRaceSeconds: RacePredictor.riegel(knownMeters: Distance.fiveK, knownSeconds: five,
                                                                    targetMeters: Distance.tenK))
    }

    func testPlanBuilderOnBothHistoryPaths() throws {
        // 240, 240, 140 (recovery), 200, 220, then 120 known plus the broken run.
        // The unknown week is build 3, so plan week 0 recovers, at most 80% of 120.
        var runs: [Activity] = []
        for (w, minutes) in [240.0, 240, 140, 200, 220, 120].enumerated() {
            runs.append(activity("a\(w)", week: w, day: 1, minutes: minutes / 2))
            runs.append(activity("b\(w)", week: w, day: 5, minutes: minutes / 2))
        }
        runs.append(corrupt(week: 5, day: 3))
        let start = PlanFixture.date(week: 6, day: 0, hour: 6)
        let report = BaselineBuilder.build(activities: runs, options: BaselineOptions(asOf: start, timeZone: utc))
        let i = input(start: start, recentWeekly: try XCTUnwrap(report.weeklyLoad.value).currentWeeklyMovingSeconds)
        for (label, h) in [("activities", history(runs)), ("baseline", BaselinePlanMapping.planHistory(from: report))] {
            let result = PlanBuilder.build(i, history: h, timeZone: utc)
            let p = try XCTUnwrap(result.plan, "\(label): \(result.issues)")
            XCTAssertTrue(p.weeks[0].isRecoveryWeek, label)
            XCTAssertLessThanOrEqual(p.weeks[0].trainingSeconds, 0.8 * 120 * 60, label)
            assertHoldsForEveryTrueDuration(p, history: h, label: label)
        }
    }

    // MARK: Fuzz (the reviewer's method)

    /// Replaces each run with no usable time by `minutes` of known time.
    private func resolved(_ h: [PlannedWorkout], minutes: Double) -> [PlannedWorkout] {
        h.map { w in
            guard w.durationSeconds.isNaN else { return w }
            var t = w
            t.durationSeconds = minutes * 60
            return t
        }
    }

    /// 3.5 holds for the plan whatever the broken runs truly lasted: half a
    /// minute, and 15 to 150 min in 15-min steps. The one exception is the rolling 4-week rule for a
    /// week whose recent 4 hold an unknown week: the true total there has no
    /// upper bound, so the checker reports that check as not evaluated (it
    /// still flags a total over the limit at the known part).
    private func assertHoldsForEveryTrueDuration(_ p: TrainingPlan, history h: [PlannedWorkout], label: String,
                                                 file: StaticString = #filePath, line: UInt = #line) {
        let asGiven = GuardrailChecker.check(history: h, planned: p.workouts, timeZone: utc)
        let unevaluated = Set(asGiven.notEvaluated.filter { $0.rule == .fourWeekIncrease }.map(\.weekStart))
        for m in [0.5] + Array(stride(from: 15.0, through: 150, by: 15)) {
            let r = GuardrailChecker.check(history: resolved(h, minutes: m), planned: p.workouts, timeZone: utc)
            let broken = r.violations.filter { !($0.rule == .fourWeekIncrease && unevaluated.contains($0.weekStart)) }
            XCTAssertTrue(broken.isEmpty, "\(label), \(Int(m)) min: \(broken.map(\.explanation))", file: file, line: line)
        }
    }

    enum Placement: CaseIterable {
        case first, middle, twoInARow, lastBeforePlan, insideOpenStartWeek, beforeOpenStartWeek
        // L = 0: a week holding only the broken run, after or before an empty week.
        case corruptOnlyFirst, emptyThenCorruptOnly, corruptOnlyThenEmpty
        case emptyThenCorruptOnlyLast, corruptOnlyThenEmptyLast

        var leavesAZeroReference: Bool {
            self == .emptyThenCorruptOnlyLast || self == .corruptOnlyThenEmptyLast
        }
    }

    struct FuzzTally {
        var built = 0
        var builtBy: [Placement: Int] = [:]
        var refusals: [String: Int] = [:]
    }

    /// Random histories with broken runs at each placement; every built plan
    /// is re-checked with each true duration. Returns the tally for reporting.
    @discardableResult
    func fuzz(cases: Int, seed: UInt64) throws -> FuzzTally {
        var state = seed
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        var tally = FuzzTally()
        for c in 0..<cases {
            let placement = Placement.allCases[c % Placement.allCases.count]
            var n = 6 + Int(next() * 5)              // 6 to 10 history weeks
            // The L = 0 pairs in the middle sit at weeks 1 and 2 of 10, out of
            // every rolling window the plan is checked over. Inside one, two
            // weeks near 0 leave no workable week under the 4-week rule, and
            // rightly so: a known run of half a minute there gives the same
            // refusal. Those cases would test the rolling rule, not the
            // unknown week, so they are kept out.
            let early = placement == .emptyThenCorruptOnly || placement == .corruptOnlyThenEmpty
            if early { n = 10 }
            // Likewise a broken first week with nothing known: with 6 or 7
            // weeks it falls in the earlier window of the plan's first weeks,
            // where the 4-week rule may leave no workable week, as it does for
            // a known half-minute week there.
            if placement == .corruptOnlyFirst { n = max(n, 8) }
            let base = 150 + next() * 200            // minutes a week
            var totals: [Double] = []
            for w in 0..<n {
                let dip = w % 4 == 3 && next() < 0.6
                totals.append((base * (0.9 + 0.2 * next()) * (dip ? 0.7 : 1)).rounded())
            }
            var unknown: Set<Int> = []
            var corruptOnly: Set<Int> = []
            var empty: Set<Int> = []
            switch placement {
            case .first: unknown = [0]
            case .middle: unknown = [n / 2]
            case .twoInARow: unknown = [n - 3, n - 2]
            case .lastBeforePlan, .beforeOpenStartWeek: unknown = [n - 1]
            case .insideOpenStartWeek: unknown = []
            case .corruptOnlyFirst: corruptOnly = [0]
            case .emptyThenCorruptOnly: empty = [1]; corruptOnly = [2]
            case .corruptOnlyThenEmpty: corruptOnly = [1]; empty = [2]
            case .emptyThenCorruptOnlyLast: empty = [n - 2]; corruptOnly = [n - 1]
            case .corruptOnlyThenEmptyLast: corruptOnly = [n - 2]; empty = [n - 1]
            }
            var h: [PlannedWorkout] = []
            for w in 0..<n where !empty.contains(w) {
                if corruptOnly.contains(w) {
                    // The broken run alone: nothing of known time that week.
                    h.append(PlannedWorkout(id: "h\(w)-x", date: date(w, 3), kind: .easy, durationSeconds: .nan))
                    continue
                }
                // Three runs a week; in an unknown week one of them is broken.
                for (k, day) in [1, 3, 5].enumerated() {
                    let minutes = totals[w] / 3
                    let broken = unknown.contains(w) && k == 2
                    h.append(PlannedWorkout(id: "h\(w)-\(k)", date: date(w, day), kind: .easy,
                                            durationSeconds: broken ? .nan : minutes * 60))
                }
            }
            let open = placement == .insideOpenStartWeek || placement == .beforeOpenStartWeek
            let start: Date
            if open {
                start = PlanFixture.date(week: n, day: 2, hour: 9)
                h.append(PlannedWorkout(id: "open-mon", date: date(n, 0), kind: .easy, durationSeconds: 40 * 60))
                if placement == .insideOpenStartWeek {
                    h.append(PlannedWorkout(id: "open-tue", date: date(n, 1), kind: .easy, durationSeconds: .nan))
                }
            } else {
                start = PlanFixture.date(week: n, day: 0, hour: 6)
            }
            // The recent volume the history shows: empty weeks count as 0, and
            // weeks of unknown volume are left out.
            let known = totals.enumerated()
                .filter { !unknown.contains($0.offset) && !corruptOnly.contains($0.offset) }
                .map { empty.contains($0.offset) ? 0 : $0.element }
            let recent = known.suffix(4).reduce(0, +) / Double(max(1, min(4, known.count))) * 60
            let i = input(start: start, recentWeekly: recent, raceWeek: n + 9 + Int(next() * 6))
            let result = PlanBuilder.build(i, history: h, timeZone: utc)
            guard let p = result.plan else {
                for issue in result.issues {
                    let name = String(describing: issue).components(separatedBy: "(").first ?? "?"
                    tally.refusals["\(placement): \(name)", default: 0] += 1
                }
                continue
            }
            tally.built += 1
            tally.builtBy[placement, default: 0] += 1
            assertHoldsForEveryTrueDuration(p, history: h, label: "case \(c) \(placement)")
        }
        return tally
    }

    func testFuzzPlansHoldForEveryTrueDuration() throws {
        let t = try fuzz(cases: 60, seed: 0x9E3779B97F4A7C15)
        XCTAssertGreaterThan(t.built, 30, "\(t.refusals)")
        assertOnlyWaitsForTheStartWeek(t)
    }

    /// The long run of the same fuzz: `COACHCORE_SLOW_TESTS=1 swift test`.
    func testFuzzPlansHoldForEveryTrueDurationSlow() throws {
        guard ProcessInfo.processInfo.environment["COACHCORE_SLOW_TESTS"] == "1" else {
            throw XCTSkip("set COACHCORE_SLOW_TESTS=1 to run the long fuzz")
        }
        let t = try fuzz(cases: 600, seed: 0xD1B54A32D192ED03)
        print("fuzz: built \(t.built) of 600; refusals \(t.refusals.sorted { $0.key < $1.key })")
        XCTAssertGreaterThan(t.built, 300)
        assertOnlyWaitsForTheStartWeek(t)
    }

    /// The only refusals are waits of a week, never `noWorkableWeek`: an open
    /// start week after (or holding) an unknown week waits for that week to
    /// close, and a plan whose first reference is 0 over a week with nothing
    /// of known time waits for a week of known volume (`historyVolumeUnknown`).
    private func assertOnlyWaitsForTheStartWeek(_ t: FuzzTally, file: StaticString = #filePath, line: UInt = #line) {
        var allowed: Set<String> = ["beforeOpenStartWeek: startWeekWithoutReference",
                                    "insideOpenStartWeek: startWeekWithoutReference"]
        for p in Placement.allCases where p.leavesAZeroReference { allowed.insert("\(p): historyVolumeUnknown") }
        for key in t.refusals.keys {
            XCTAssertTrue(allowed.contains(key), key, file: file, line: line)
        }
        // A zero reference just before the plan is always refused.
        for p in Placement.allCases where p.leavesAZeroReference {
            let built = t.builtBy[p] ?? 0
            XCTAssertEqual(built, 0, "\(p) built \(built)", file: file, line: line)
        }
    }
}
