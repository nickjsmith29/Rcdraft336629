import XCTest
@testable import CoachCore

// #54, SPEC 3.5 rule 5 and F3 (owner's decision, Nov 24): no easy run is
// longer than the week's long run in plans the adaptation engine changes. A
// repair that cuts a long run settles the week in one pass (share read once,
// long run cut, easy runs and a quality session's easy extension capped at
// it, the cut time dropped), and the week keeps its time before the cap.
// Every number below is worked by hand in the comments. Synthetic runners only.
final class EasyRunCapAdaptedTests: XCTestCase {
    private typealias F = AdaptFixture
    private let tz = PlanFixture.utc

    /// The spike rule off, so only the share, weekly and cap rules act.
    private func context() -> AdaptationContext {
        var ctx = F.context()
        ctx.guardrails.maxSingleRunIncrease = .infinity
        return ctx
    }

    /// Four earlier weeks of four equal easy runs: `totals` minutes each (weeks 0 to 3).
    private func history(_ totals: [Double]) -> [PlannedWorkout] {
        PlanFixture.easyWeeks(totals, prefix: "h")
    }

    private func find(_ id: String, _ plan: [PlannedWorkout]) -> PlannedWorkout? { plan.first { $0.id == id } }

    private func minutes(_ w: PlannedWorkout?) -> Double? { w.map { $0.durationSeconds / 60 } }

    // MARK: A 3-day week with a missed run

    /// Week 4: easy Monday 60 (missed), easy Wednesday 60, long Saturday 90.
    /// With Monday dropped the week holds 60 + 90 = 150 min, a long-run share of 60%.
    /// The share repair: amount = (90 - 0.35 x 150) / 0.65 = 57.69 min, so the
    /// long run falls to 32.31, 32 whole minutes (32/92 = 34.8%, at most 35%).
    /// The cap: Wednesday's 60 becomes 32. The week holds 64 min, the long
    /// run is 50% of it, which is 1 / (1 + 1) for the one run the cap shortened.
    /// Before the cap it held 32 + 60 = 92 min; the cap cut 28.
    private func threeDayWeek() -> (plan: [PlannedWorkout], history: [PlannedWorkout]) {
        ([F.easy("mon", week: 4, day: 0, minutes: 60), F.easy("wed", week: 4, day: 2, minutes: 60),
          F.long("sat", week: 4, day: 5, minutes: 90)],
         history([100, 150, 150, 100]))
    }

    func testMissedRunThenLongRunCutThenEasyRunCappedInOnePass() throws {
        let (plan, hist) = threeDayWeek()
        let o = AdaptationEngine.processDay(asOf: F.date(week: 4, day: 1, hour: 6), state: AdaptationState(),
                                            plan: plan, history: hist, context: context())
        XCTAssertNil(find("mon", o.plan), "the missed run is dropped")
        XCTAssertEqual(minutes(find("sat", o.plan)), 32)
        XCTAssertEqual(minutes(find("wed", o.plan)), 32)
        XCTAssertEqual(F.weekVolume(4, o.plan) / 60, 64)
        // The share of the smaller week is 1 / (1 + 1), and the checker still passes.
        XCTAssertEqual(32.0 / 64, 1 / (1 + 1))
        XCTAssertTrue(o.guardrailReport.passed, "\(o.guardrailReport.violations.map(\.explanation))")
        // The week keeps its time before the cap: 92 min, 28 cut.
        let entry = try XCTUnwrap(o.state.preCap.week(PlanCalendar.weekStart(containing: F.date(week: 4, day: 0), timeZone: tz)))
        XCTAssertEqual(entry.secondsBeforeCap, 92 * 60)
        XCTAssertEqual(entry.secondsCut, 28 * 60)
        XCTAssertEqual(o.regrowth.preCap, o.state.preCap)
        // Read against the smaller week alone, the long run would be over its share.
        let own = GuardrailChecker.check(history: o.history, planned: o.plan, timeZone: tz, limits: context().guardrails)
        XCTAssertTrue(own.violations.contains { $0.rule == .longRunShare }, "the 50% share of the week as it now is")
        // The note says why the week is smaller, in the spec's words.
        let note = try XCTUnwrap(o.changes.first { $0.workoutIDs == ["wed"] })
        XCTAssertEqual(note.kind, .sessionShortened)
        XCTAssertEqual(note.explanation,
                       "Easy runs shortened to 32 minutes so that Saturday's long run, cut to fit its share of the week, stays the week's longest run. "
                       + "The 28 min this cuts is not moved to other runs, so the week of 2026-02-02 comes out smaller. (Heuristic, SPEC F3 and 3.5 rule 5, #54.)")
        XCTAssertFalse(note.triggers.isEmpty)
    }

    func testTheRepairSettlesAndRunningItAgainChangesNothing() throws {
        let (plan, hist) = threeDayWeek()
        let first = AdaptationEngine.processDay(asOf: F.date(week: 4, day: 1, hour: 6), state: AdaptationState(),
                                                plan: plan, history: hist, context: context())
        // Later the same day, then the next morning (before Wednesday's run).
        var state = first.state, current = first.plan
        for (day, hour) in [(1, 12), (2, 6)] {
            let again = AdaptationEngine.processDay(asOf: F.date(week: 4, day: day, hour: hour), state: state,
                                                    plan: current, history: first.history, context: context())
            XCTAssertEqual(again.plan, first.plan, "day \(day)")
            XCTAssertEqual(again.changes, [], "day \(day)")
            XCTAssertEqual(again.state.preCap, first.state.preCap, "day \(day)")
            XCTAssertTrue(again.guardrailReport.passed, "day \(day)")
            state = again.state
            current = again.plan
        }
        // The repair itself, run again on its output with the stored weeks, changes nothing.
        let first2 = GuardrailRepair.repair(plan: plan.filter { $0.id != "mon" }, history: hist, asOf: F.date(week: 4, day: 1, hour: 6),
                                            freezes: [], context: contextWithLimit())
        let second = GuardrailRepair.repair(plan: first2.plan, history: hist, asOf: F.date(week: 4, day: 1, hour: 6), freezes: [],
                                            context: contextWithLimit(), regrowth: GuardrailRegrowth(preCap: first2.preCap))
        XCTAssertEqual(second.plan, first2.plan)
        XCTAssertEqual(second.changes, [])
        XCTAssertEqual(second.preCap, first2.preCap)
        XCTAssertTrue(second.report.passed)
    }

    private func contextWithLimit() -> AdaptationContext {
        var ctx = context()
        ctx.guardrails.easyRunsWithinLongRun = true
        return ctx
    }

    // MARK: A new plan for a capped week

    /// The week-4 entry (92 min before the cap, 28 cut) belongs to the adapted
    /// plan it was recorded for. A fresh plan for that week (new ids: easy 25,
    /// easy 20, long 30, 75 min, a 40% share) is read at its own time. Worked:
    /// amount = (30 - 0.35 x 75) / 0.65 = 5.77 min, so the long run falls to
    /// 24.23, 24 whole minutes; the 25 min run is capped at 24, the 20 min run
    /// stays. Week 4 then holds 68 min (69 before this cap); week 5's 90 min is
    /// a 30% rise over it, so it is cut, which the old entry's 92 min would have
    /// let through (92 x 1.1 = 101.2).
    func testANewPlanForACappedWeekIsReadAtItsOwnTime() throws {
        let (plan, hist) = threeDayWeek()
        let first = AdaptationEngine.processDay(asOf: F.date(week: 4, day: 1, hour: 6), state: AdaptationState(),
                                                plan: plan, history: hist, context: context())
        let week4 = PlanCalendar.weekStart(containing: F.date(week: 4, day: 0), timeZone: tz)
        XCTAssertEqual(first.state.preCap.week(week4)?.secondsBeforeCap, 92 * 60)
        let fresh = [F.easy("n1", week: 4, day: 2, minutes: 25), F.easy("n2", week: 4, day: 3, minutes: 20),
                     F.long("n3", week: 4, day: 5, minutes: 30)]
            + (0..<3).map { F.easy("m\($0)", week: 5, day: $0 * 2, minutes: 30) }
        // Earlier weeks of 60, 120, 120 and 70 min: week 4's own 69 min is not a recovery week
        // (over 80% of 70), so week 5 is held to 10% over it, 75.9 min, not over the old 92.
        let hist2 = history([60, 120, 120, 70])
        let o = AdaptationEngine.processDay(asOf: F.date(week: 4, day: 1, hour: 12), state: first.state,
                                            plan: fresh, history: hist2, context: context())
        XCTAssertEqual(minutes(find("n3", o.plan)), 24, "the share is read at the week's own 75 min, not the old 92")
        XCTAssertEqual(minutes(find("n1", o.plan)), 24)
        XCTAssertEqual(minutes(find("n2", o.plan)), 20)
        let entry = try XCTUnwrap(o.state.preCap.week(week4))
        XCTAssertEqual(entry.secondsBeforeCap, 69 * 60, "a new entry for the new plan, not the old 92")
        XCTAssertLessThan(F.weekVolume(5, o.plan), 90 * 60, "week 5 is held to 10% over week 4's own time")
        XCTAssertLessThanOrEqual(F.weekVolume(5, o.plan), 1.1 * 69 * 60 + 1e-6)
        // Weeks before the new plan are history and keep their entries.
        var state = first.state
        state.preCap = GuardrailPreCap(weeks: [PreCapWeek(weekStart: PlanCalendar.weekStart(containing: F.date(week: 2, day: 0), timeZone: tz),
                                                           secondsBeforeCap: 100, secondsCut: 10)])
        let kept = AdaptationEngine.processDay(asOf: F.date(week: 4, day: 1, hour: 12), state: state,
                                               plan: fresh, history: hist2, context: context())
        XCTAssertEqual(kept.state.preCap.weeks.first?.secondsBeforeCap, 100)
    }

    // MARK: The pain freeze holds a week to what was run

    /// Week 4 ran 90 min but its entry reads 130 before the cap (40 cut). The
    /// freeze (3.5 rule 7) holds week 5 to what was actually run, 90 min, not
    /// to 130: a planned 120 is a violation, allowed 90.
    private func frozenWeekFive() -> (history: [PlannedWorkout], plan: [PlannedWorkout], regrowth: GuardrailRegrowth, freeze: DateInterval) {
        let hist = history([100, 100, 100, 100, 90])
        let plan = (0..<3).map { F.easy("f\($0)", week: 5, day: $0 * 2, minutes: 40) }
        let week4 = PlanCalendar.weekStart(containing: F.date(week: 4, day: 0), timeZone: tz)
        let entry = PreCapWeek(weekStart: week4, secondsBeforeCap: 130 * 60, secondsCut: 40 * 60)
        let week5 = PlanCalendar.weekStart(containing: F.date(week: 5, day: 0), timeZone: tz)
        let week6 = PlanCalendar.weekStart(containing: F.date(week: 6, day: 0), timeZone: tz)
        return (hist, plan, GuardrailRegrowth(preCap: GuardrailPreCap(weeks: [entry])), DateInterval(start: week5, end: week6))
    }

    func testTheVolumeFreezeReadsACappedWeekAtWhatWasRun() throws {
        let f = frozenWeekFive()
        let r = GuardrailChecker.check(history: f.history, planned: f.plan, timeZone: tz, limits: context().guardrails,
                                       freezes: [f.freeze], regrowth: f.regrowth)
        let v = try XCTUnwrap(r.violations.first { $0.rule == .volumeFreeze })
        XCTAssertEqual(v.measured, 120 * 60)
        XCTAssertEqual(v.allowed, 90 * 60)
    }

    func testRepairHoldsTheWeekAfterACappedWeekToWhatWasRun() {
        let f = frozenWeekFive()
        let r = GuardrailRepair.repair(plan: f.plan, history: f.history, asOf: F.date(week: 5, day: 0, hour: 6), freezes: [f.freeze],
                                       context: contextWithLimit(), regrowth: f.regrowth)
        XCTAssertLessThanOrEqual(F.weekVolume(5, r.plan), 90 * 60 + 1e-6)
        XCTAssertFalse(r.report.violations.contains { $0.rule == .volumeFreeze })
    }

    // MARK: A new plan that starts after a capped future week

    func testANewPlanStartingLaterDropsTheEntriesOfWeeksBetween() {
        func entry(_ week: Int) -> PreCapWeek {
            PreCapWeek(weekStart: PlanCalendar.weekStart(containing: F.date(week: week, day: 0), timeZone: tz),
                       secondsBeforeCap: 6000, secondsCut: 600)
        }
        var state = AdaptationState()
        state.preCap = GuardrailPreCap(weeks: [entry(2), entry(6)])
        let fresh = (0..<2).map { F.easy("x\($0)", week: 7, day: $0 * 2, minutes: 30) }
        let o = AdaptationEngine.processDay(asOf: F.date(week: 4, day: 1, hour: 6), state: state, plan: fresh,
                                            history: history([100, 100, 100, 100]), context: context())
        XCTAssertEqual(o.state.preCap.weeks.map(\.weekStart), [entry(2).weekStart],
                       "week 6 lies between today and the new plan's first week: it is no longer the week that was capped")
    }

    // MARK: The share bound with two capped runs, and rounding

    /// The share cut can only cap one run: with 35% the long run stays above
    /// 0.35 x others / 0.65, more than half of the other runs together, so two
    /// easy runs cannot both be longer than it. A cut by the load guardrails can
    /// leave two: easy 50 and 50 beside a long run cut to 36. The cap takes both
    /// to 36: the week holds 108 and the long run is 36/108 = 1/3 = 1/(1 + 2),
    /// n = 2 runs shortened. Before the cap it held 136 (cut 28).
    func testTwoCappedRunsLeaveTheLongRunAtOneThirdOfTheWeek() throws {
        let plan = [F.easy("a", week: 4, day: 1, minutes: 50), F.easy("b", week: 4, day: 2, minutes: 50),
                    F.long("sat", week: 4, day: 5, minutes: 36)]
        let week = PlanCalendar.weekStart(containing: F.date(week: 4, day: 0), timeZone: tz)
        let cap = try XCTUnwrap(GuardrailRepair.capEasyRuns(week: week, plan: plan, history: [], asOf: F.date(week: 4, day: 0, hour: 6),
                                                            longRunCut: .guardrails, preCap: .none, context: contextWithLimit()))
        for id in ["a", "b", "sat"] { XCTAssertEqual(minutes(find(id, cap.plan)), 36, id) }
        XCTAssertEqual(F.weekVolume(4, cap.plan) / 60, 108)
        XCTAssertEqual(36.0 / 108, 1.0 / (1 + 2), accuracy: 1e-12)
        let entry = try XCTUnwrap(cap.preCap.weeks.first)
        XCTAssertEqual(entry.secondsBeforeCap, 136 * 60)
        XCTAssertEqual(entry.secondsCut, 28 * 60)
        XCTAssertEqual(cap.changes.first?.workoutIDs, ["a", "b"])
        XCTAssertTrue(cap.changes.first?.explanation.contains("stay inside the load guardrails") ?? false)
    }

    /// A long run of 36.5 min (a handed-in plan) with an easy run of 50: the cap
    /// is the long run's whole minutes, 36, so the easy run is 36 and the long run
    /// 36.5. Rounding down keeps every run at most the long run, but the share
    /// of the smaller week, 36.5 / 72.5 = 50.3%, is a hair over 1 / (1 + 1) =
    /// 50% (n = 1). That is the cost of whole minutes; the week is read at its
    /// 86.5 min before the cap (42.2%). That is over the 35% limit, so in the
    /// engine a share repair would come first; this test calls `capEasyRuns`
    /// directly, after such a repair, to show the cap itself.
    func testAFractionalLongRunCapsAtWholeMinutesAndTheShareIsReadBeforeTheCap() throws {
        let plan = [F.easy("e", week: 4, day: 1, minutes: 50), F.long("l", week: 4, day: 5, minutes: 36.5)]
        let week = PlanCalendar.weekStart(containing: F.date(week: 4, day: 0), timeZone: tz)
        let cap = try XCTUnwrap(GuardrailRepair.capEasyRuns(week: week, plan: plan, history: [], asOf: F.date(week: 4, day: 0, hour: 6),
                                                            longRunCut: .none, preCap: .none, context: contextWithLimit()))
        XCTAssertEqual(minutes(find("e", cap.plan)), 36)
        XCTAssertEqual(minutes(find("l", cap.plan)), 36.5)
        XCTAssertGreaterThan(36.5 / 72.5, 1.0 / (1 + 1), "whole-minute rounding puts the smaller week's share a hair over 1/(1+n)")
        let entry = try XCTUnwrap(cap.preCap.weeks.first)
        XCTAssertEqual(entry.secondsBeforeCap, 86.5 * 60)
        XCTAssertEqual(entry.secondsCut, 14 * 60)
        XCTAssertEqual(entry.reading(of: 72.5 * 60, .time) / 60, 86.5, accuracy: 1e-9)
    }

    // MARK: Marathon ceilings are read before the cap

    /// Week 4: easy Tuesday 60, long Saturday 100 (160 min, 62.5%), and a
    /// marathon on Sunday of week 5, so week 4 is a marathon-plan week: its
    /// ceiling is 45%. amount = (100 - 0.45 x 160) / 0.55 = 50.91 min, so the
    /// long run falls to 49.09, 49 whole minutes (49/109 = 44.95%). The cap
    /// takes Tuesday to 49. The week then holds 98 min and the long run is
    /// 50% of it, over 45%, but the checker reads the 109 min before the cap.
    func testMarathonCeilingsReadTheWeekBeforeTheCap() throws {
        let race = PlannedWorkout(id: "race", date: PlanFixture.date(week: 5, day: 6), kind: .race, durationSeconds: 4 * 3600,
                                  distanceMeters: 42_195)
        let plan = [F.easy("tue", week: 4, day: 1, minutes: 60), F.long("sat", week: 4, day: 5, minutes: 100), race]
        let hist = history([100, 150, 150, 100])
        let asOf = F.date(week: 4, day: 0, hour: 6)
        let r = GuardrailRepair.repair(plan: plan, history: hist, asOf: asOf, freezes: [], context: contextWithLimit())
        XCTAssertEqual(minutes(find("sat", r.plan)), 49)
        XCTAssertEqual(minutes(find("tue", r.plan)), 49)
        XCTAssertEqual(r.report.violations.filter { [.longRunShare, .easyRunLength].contains($0.rule) }, [])
        // The warning still shows, at the share before the cap: 49 / 109, not 49 / 98.
        let flag = try XCTUnwrap(r.report.informationFlags.first { $0.rule == .longRunShare })
        XCTAssertEqual(flag.measured, 49.0 / 109, accuracy: 1e-9)
        // Read at its own time the same plan breaks the 45% ceiling.
        let own = GuardrailChecker.check(history: hist, planned: r.plan, timeZone: tz, limits: contextWithLimit().guardrails)
        let v = try XCTUnwrap(own.violations.first { $0.rule == .longRunShare })
        XCTAssertEqual(v.measured, 0.5, accuracy: 1e-9)
        XCTAssertEqual(v.allowed, 0.45, accuracy: 1e-9)
        let entry = try XCTUnwrap(r.preCap.weeks.first)
        XCTAssertEqual(entry.secondsBeforeCap, 109 * 60)
        XCTAssertEqual(entry.secondsCut, 11 * 60)
    }

    // MARK: A quality session's easy extension

    /// Week 4: threshold Tuesday of 60 min (10 warm-up, 20 hard, 30 cool-down, the last
    /// 20 of it the easy extension, so a planned cool-down of 10), easy Thursday 40, long
    /// Saturday 80: 180 min, a share of 44%. amount = (80 - 0.35 x 180) / 0.65 = 26.15,
    /// so the long run falls to 53.85, 53 whole minutes. The quality session may be
    /// at most 53 long: its warm-up, hard part and planned cool-down hold 40, so the
    /// extension goes from 20 to 13 and the session to 53. Thursday's 40 stays.
    func testQualityCoolDownExtensionIsCutAndTheHardMinutesStay() throws {
        let quality = qualityWithExtension("tue", week: 4, day: 1, extensionMinutes: 20)
        XCTAssertEqual(quality.durationSeconds / 60, 60)
        XCTAssertEqual(quality.easyExtensionSeconds / 60, 20)
        let plan = [quality, F.easy("thu", week: 4, day: 3, minutes: 40), F.long("sat", week: 4, day: 5, minutes: 80)]
        let hist = history([120, 170, 170, 120])
        let o = AdaptationEngine.processDay(asOf: F.date(week: 4, day: 0, hour: 6), state: AdaptationState(),
                                            plan: plan, history: hist, context: context())
        XCTAssertEqual(minutes(find("sat", o.plan)), 53)
        XCTAssertEqual(minutes(find("thu", o.plan)), 40)
        let q = try XCTUnwrap(find("tue", o.plan))
        XCTAssertEqual(q.durationSeconds / 60, 53)
        XCTAssertEqual(q.easyExtensionSeconds / 60, 13)
        let segments = try XCTUnwrap(q.prescription?.segments)
        XCTAssertEqual(segments.map(\.role), [.warmUp, .work, .coolDown])
        XCTAssertEqual(segments.map(\.intensity), [.easy, .threshold, .easy])
        XCTAssertEqual(segments.map { $0.durationSeconds / 60 }, [10, 20, 23], "warm-up and hard part whole, cool-down 10 + 13")
        XCTAssertEqual(segments.reduce(0) { $0 + $1.durationSeconds }, q.durationSeconds)
        XCTAssertTrue(q.prescription?.purpose.contains("The last 13 min of the cool-down is easy running") ?? false)
        // Before the cap the week held 60 + 40 + 53 = 153 min; the cap cut 7.
        let entry = try XCTUnwrap(o.state.preCap.weeks.first)
        XCTAssertEqual(entry.secondsBeforeCap, 153 * 60)
        XCTAssertEqual(entry.secondsCut, 7 * 60)
        XCTAssertTrue(o.guardrailReport.passed, "\(o.guardrailReport.violations.map(\.explanation))")
        let note = try XCTUnwrap(o.changes.first { $0.workoutIDs == ["tue"] })
        XCTAssertTrue(note.explanation.contains("quality session's cool-down is shortened"), note.explanation)
        XCTAssertTrue(note.explanation.contains("warm-up, hard part and planned cool-down stay"), note.explanation)
        // And the next day changes nothing.
        let again = AdaptationEngine.processDay(asOf: F.date(week: 4, day: 1, hour: 6), state: o.state, plan: o.plan,
                                                history: o.history, context: context())
        XCTAssertEqual(again.plan, o.plan)
        XCTAssertEqual(again.changes, [])
    }

    func testAnExtensionWhoseSessionIsShorterThanTheLongRunIsLeftAlone() {
        let q = qualityWithExtension("tue", week: 4, day: 1, extensionMinutes: 20)
        XCTAssertEqual(q.cuttingEasyExtension(toSeconds: 20 * 60), q, "already at 20")
        XCTAssertEqual(q.cuttingEasyExtension(toSeconds: 25 * 60), q, "never lengthened")
        let none = F.threshold("t", week: 4, day: 1)
        XCTAssertEqual(none.easyExtensionSeconds, 0)
        XCTAssertEqual(none.cuttingEasyExtension(toSeconds: 0), none)
        let gone = q.cuttingEasyExtension(toSeconds: 0)
        XCTAssertEqual(gone.durationSeconds / 60, 40)
        XCTAssertEqual(gone.easyExtensionSeconds, 0)
        XCTAssertFalse(gone.prescription?.purpose.contains("The last") ?? true)
    }

    func testTheExtensionSentenceIsTheBuildersAndNeverReachesIntoTheHardPart() {
        XCTAssertEqual(EasyExtension.sentence(minutes: 36),
                       " The last 36 min of the cool-down is easy running, moved here from the easy runs so that none is longer than the long run.")
        XCTAssertEqual(EasyExtension.minutes(inPurpose: "Threshold." + EasyExtension.sentence(minutes: 36)), 36)
        XCTAssertNil(EasyExtension.minutes(inPurpose: "Threshold."))
        XCTAssertNil(EasyExtension.minutes(inPurpose: " The last x min of the cool-down is easy running, moved here"))
        // A purpose that claims more than the cool-down holds is read at the cool-down.
        var q = qualityWithExtension("q", week: 4, day: 1, extensionMinutes: 20)
        let p = q.prescription!
        q.prescription = WorkoutPrescription(purpose: "Threshold." + EasyExtension.sentence(minutes: 90), phase: p.phase,
                                             segments: p.segments, rules: p.rules)
        XCTAssertEqual(q.easyExtensionSeconds / 60, 30)
    }

    // MARK: Done runs are exempt

    /// Week 4: a done easy run of 90 min on Monday (history), a planned easy run of 70 on
    /// Wednesday and a planned long run of 60 on Saturday. The plan holds an easy run over its
    /// long run with no long-run cut: the planned run goes to 60, the done 90 stays as it ran.
    func testDoneRunsAreNeverChanged() throws {
        let done = PlannedWorkout(id: "done", date: F.date(week: 4, day: 0), kind: .easy, durationSeconds: 90 * 60)
        let plan = [F.easy("wed", week: 4, day: 2, minutes: 70), F.long("sat", week: 4, day: 5, minutes: 60)]
        let hist = history([160, 230, 230, 160]) + [done]
        let o = AdaptationEngine.processDay(asOf: F.date(week: 4, day: 1, hour: 6), state: AdaptationState(),
                                            plan: plan, history: hist, context: context())
        XCTAssertEqual(o.history, hist, "history is never touched")
        XCTAssertEqual(minutes(find("wed", o.plan)), 60)
        XCTAssertEqual(minutes(find("sat", o.plan)), 60)
        XCTAssertTrue(o.guardrailReport.passed, "\(o.guardrailReport.violations.map(\.explanation))")
        // Before the cap: 90 + 70 + 60 = 220 min; cut 10.
        let entry = try XCTUnwrap(o.state.preCap.weeks.first)
        XCTAssertEqual(entry.secondsBeforeCap, 220 * 60)
        XCTAssertEqual(entry.secondsCut, 10 * 60)
        // The checker reads only planned runs against the limit, so the done run is not a violation.
        let report = GuardrailChecker.check(history: o.history, planned: o.plan, timeZone: tz, limits: contextWithLimit().guardrails)
        XCTAssertEqual(report.violations.filter { $0.rule == .easyRunLength }, [])
    }

    func testARunLongerThanTheLongRunInHistoryIsNotReadAsALongRunCut() {
        // Only a planned long run that a repair shortened starts a cap.
        let before = [F.long("l", week: 4, day: 5, minutes: 90)]
        XCTAssertEqual(GuardrailRepair.weeksWithLongRunCut(before: before, after: before, timeZone: tz), [])
        XCTAssertEqual(GuardrailRepair.weeksWithLongRunCut(before: before, after: [F.long("l", week: 4, day: 5, minutes: 60)], timeZone: tz).count, 1)
        XCTAssertEqual(GuardrailRepair.weeksWithLongRunCut(before: before, after: [], timeZone: tz), [])
        XCTAssertEqual(GuardrailRepair.weeksWithLongRunCut(before: before, after: [before[0].swappedToEasy()], timeZone: tz), [])
    }

    // MARK: Reading a week with a stored time before the cap

    func testTheWeekAfterReadsItsTenPercentAndRollingChecksAgainstTheTimeBeforeTheCap() {
        // Week 4 held 150 min before a cap of 60 (it holds 90, not a recovery week after 100); week 5
        // plans 160. At its own time 90 x 1.1 = 99, so 160 breaks the 10% rule; read at 150 the limit is 165.
        let wk4 = (0..<3).map { F.easy("a\($0)", week: 4, day: $0 * 2, minutes: 30) }
        let wk5 = (0..<4).map { F.easy("b\($0)", week: 5, day: $0 * 2, minutes: 40) }
        let hist = history([100, 100, 100, 100])
        let start4 = PlanCalendar.weekStart(containing: F.date(week: 4, day: 0), timeZone: tz)
        let entry = PreCapWeek(weekStart: start4, secondsBeforeCap: 150 * 60, secondsCut: 60 * 60)
        let limits = GuardrailLimits()
        let plain = GuardrailChecker.check(history: hist, planned: wk4 + wk5, timeZone: tz, limits: limits)
        XCTAssertTrue(plain.violations.contains { $0.rule == .weeklyIncrease && $0.weekStart != start4 })
        let capped = GuardrailChecker.check(history: hist, planned: wk4 + wk5, timeZone: tz, limits: limits,
                                            regrowth: GuardrailRegrowth(preCap: GuardrailPreCap(weeks: [entry])))
        XCTAssertFalse(capped.violations.contains { $0.rule == .weeklyIncrease && $0.weekStart != start4 }, "\(capped.violations)")
    }

    func testAWeekReadsItsCutTimeBackOnlyWhileTheCutRunsStayCut() {
        let w = PreCapWeek(weekStart: PlanFixture.firstMonday, secondsBeforeCap: 9000, secondsCut: 1800)
        XCTAssertEqual(w.reading(of: 7200, .time), 9000, "unchanged: the time before the cap")
        XCTAssertEqual(w.reading(of: 6000, .time), 7500, "a run dropped since: the cut time counts in proportion (6000/7200 of 1800)")
        XCTAssertEqual(w.reading(of: 0, .time), 0, "a week that was missed reads as missed")
        XCTAssertEqual(w.reading(of: 8400, .time), 9000, "capped runs grown back: never above the time before the cap")
        XCTAssertEqual(w.reading(of: 9600, .time), 9600, "more run than that: its own time")
        XCTAssertEqual(w.reading(of: .nan, .time).isNaN, true)
        XCTAssertEqual(w.reading(of: 7200, .distance), 7200, "no distance kept: read at its own distance")
        XCTAssertEqual(GuardrailPreCap.none.extra(PlanFixture.firstMonday, actual: 5, .time), 0)
    }

    func testNothingIsRecordedForNoCut() {
        let none = GuardrailPreCap.none
        XCTAssertTrue(none.recording(weekStart: PlanFixture.firstMonday, secondsBefore: 100, secondsAfter: 100,
                                     metersBefore: nil, metersAfter: nil).isEmpty)
        XCTAssertTrue(none.recording(weekStart: PlanFixture.firstMonday, secondsBefore: .nan, secondsAfter: 1,
                                     metersBefore: nil, metersAfter: nil).isEmpty)
        let r = none.recording(weekStart: PlanFixture.firstMonday, secondsBefore: 100, secondsAfter: 60, metersBefore: 10_000, metersAfter: 7_000)
        XCTAssertEqual(r.weeks, [PreCapWeek(weekStart: PlanFixture.firstMonday, secondsBeforeCap: 100, secondsCut: 40,
                                            metersBeforeCap: 10_000, metersCut: 3_000)])
    }

    func testADistancePlanReadsTheWeekBeforeTheCapInMeters() throws {
        // A 10 km easy run of 60 min, a 6 km one of 36 min and a 7 km long run of 40 min: the
        // 60 min run is cut to 40 min (3 333.33 m less), the 36 min run stays.
        func run(_ id: String, _ day: Int, _ kind: PlannedWorkout.Kind, minutes: Double, km: Double) -> PlannedWorkout {
            PlanFixture.workout(id, week: 4, day: day, kind, minutes: minutes, km: km)
        }
        let plan = [run("a", 1, .easy, minutes: 60, km: 10), run("b", 3, .easy, minutes: 36, km: 6),
                    run("l", 5, .long, minutes: 40, km: 7)]
        let week = PlanCalendar.weekStart(containing: F.date(week: 4, day: 0), timeZone: tz)
        let cap = try XCTUnwrap(GuardrailRepair.capEasyRuns(week: week, plan: plan, history: [], asOf: F.date(week: 4, day: 0, hour: 6),
                                                            longRunCut: .guardrails, preCap: .none, context: contextWithLimit()))
        XCTAssertEqual(minutes(find("a", cap.plan)), 40, "capped at the long run")
        XCTAssertEqual(find("b", cap.plan)?.durationSeconds, 36 * 60, "shorter than the long run: untouched")
        XCTAssertEqual(find("a", cap.plan)?.distanceMeters ?? 0, 10_000 * 40.0 / 60, accuracy: 1e-6)
        let entry = try XCTUnwrap(cap.preCap.weeks.first)
        XCTAssertEqual(entry.secondsBeforeCap, 136 * 60)
        XCTAssertEqual(entry.secondsCut, 20 * 60)
        XCTAssertEqual(try XCTUnwrap(entry.metersBeforeCap), 23_000, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(entry.metersCut), 10_000 * 20.0 / 60, accuracy: 1e-6)
        XCTAssertEqual(entry.reading(of: 19_666.666, .distance), 23_000, accuracy: 1, "unchanged: the distance before the cap")
    }

    func testCappingNeedsALongRunAndKnownTimesAndNeverTouchesWhatItCannotRead() {
        let ctx = contextWithLimit()
        let asOf = F.date(week: 4, day: 0, hour: 6)
        func cap(_ plan: [PlannedWorkout], history: [PlannedWorkout] = []) -> GuardrailRepair.EasyCap? {
            GuardrailRepair.capEasyRuns(week: PlanCalendar.weekStart(containing: F.date(week: 4, day: 0), timeZone: tz), plan: plan,
                                        history: history, asOf: asOf, longRunCut: .guardrails, preCap: .none, context: ctx)
        }
        let easy = F.easy("e", week: 4, day: 1, minutes: 60)
        XCTAssertNil(cap([]), "an empty week")
        XCTAssertNil(cap([easy]), "no long run: F3's limits for such weeks apply")
        XCTAssertNil(cap([easy, F.long("l", week: 4, day: 5, minutes: 60)]), "nothing is longer than the long run")
        XCTAssertNil(cap([easy, F.long("l", week: 4, day: 5, minutes: 0.5)]), "a long run under a minute has no whole-minute length")
        let unknown = PlannedWorkout(id: "n", date: F.date(week: 4, day: 2), kind: .easy, durationSeconds: .nan)
        XCTAssertNil(cap([easy, unknown, F.long("l", week: 4, day: 5, minutes: 40)]), "a week of unknown time is not capped")
        XCTAssertNil(cap([PlannedWorkout(id: "i", date: F.date(week: 4, day: 2), kind: .easy, durationSeconds: .infinity),
                          F.long("l", week: 4, day: 5, minutes: 40)]))
        // A done long run is the week's long run too, and a run before today is left as it is.
        let doneLong = F.long("dl", week: 4, day: 0, minutes: 50)
        let c = cap([easy], history: [doneLong])
        XCTAssertEqual(c?.plan.first.map { $0.durationSeconds / 60 }, 50)
        let past = F.easy("p", week: 3 + 1, day: 0, minutes: 70)
        XCTAssertNil(GuardrailRepair.capEasyRuns(week: PlanCalendar.weekStart(containing: past.date, timeZone: tz), plan: [past],
                                                 history: [doneLong], asOf: F.date(week: 4, day: 3), longRunCut: .none,
                                                 preCap: .none, context: ctx), "the run's day has passed")
        // A race is neither capped nor the week's long run.
        let race = PlannedWorkout(id: "r", date: F.date(week: 4, day: 6), kind: .race, durationSeconds: 3 * 3600, distanceMeters: 42_195)
        XCTAssertNil(cap([easy, race, F.long("l", week: 4, day: 5, minutes: 60)]))
    }

    // MARK: Old stored state still decodes

    /// A state stored by format version 4, before `preCap` existed.
    private static let version4State = #"{"formatVersion":4,"assessments":[],"qualitySignals":[],"easyHeartRates":[],"longRuns":[],"painCheckIns":[{"date":100,"score":3}],"freezes":[],"holds":[],"qualityPaceFactor":0.985,"easyPaceFactor":1,"reportedHoldShortfalls":[],"painReports":[],"painRecovery":{"cannotEnd":false,"flaggedThisStop":false,"prePlanWeeks":[],"stopFromMovement":false,"usualSamples":[]},"planSnapshot":{"sessions":[],"earlier":[],"returned":[]}}"#

    func testAStateStoredBeforeTheCapStillDecodes() throws {
        let decoded = try JSONDecoder().decode(AdaptationState.self, from: Data(Self.version4State.utf8))
        XCTAssertEqual(decoded.preCap, .none)
        XCTAssertEqual(decoded.qualityPaceFactor, 0.985)
        XCTAssertEqual(decoded.painCheckIns.map(\.score), [3])
        // Every week reads at its own time, and the next event runs as before.
        let (plan, hist) = threeDayWeek()
        let o = AdaptationEngine.processDay(asOf: F.date(week: 4, day: 1, hour: 6), state: decoded, plan: plan, history: hist,
                                            context: context())
        XCTAssertEqual(minutes(find("wed", o.plan)), 32)
        // Written back it is the current version, with the stored weeks, and reads the same.
        let data = try JSONEncoder().encode(o.state)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"formatVersion\":\(AdaptationState.formatVersion)"))
        let back = try JSONDecoder().decode(AdaptationState.self, from: data)
        XCTAssertEqual(back, o.state)
        XCTAssertEqual(back.preCap.weeks.count, 1)
        XCTAssertEqual(AdaptationState.formatVersion, 5)
    }

    func testAStateFromANewerFormatIsStillRefused() {
        let data = Data("{\"formatVersion\": \(AdaptationState.formatVersion + 1)}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AdaptationState.self, from: data))
    }

    // MARK: Built plans (F3) behave exactly as before

    private func tenKInput(days: [PlanWeekday], weekly: Double) -> PlanInput {
        let monday = PlanFixture.date(week: 8, day: 0, hour: 0)
        let race = monday.addingTimeInterval(Double(11 * 7 + 6) * 86_400 + 8 * 3600)
        return PlanInput(raceDistanceMeters: Distance.tenK, raceDate: race, startDate: monday, trainingDays: Set(days),
                         longRunDay: days.last!, maxSessionSeconds: nil, recentWeeklySeconds: weekly * 60,
                         recentLongRunSeconds: nil, heartRateZones: HRZones(lthr: 168),
                         easyPace: EasyPaceSample(secondsPerKm: 360, heartRate: 140),
                         fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: 25 * 60))
    }

    /// Baseline 1, as on main: 330 min a week on Tue/Thu/Sat holds q103 e103 L103 in week 1, the
    /// quality session being 15 warm-up, 42 of reps and jogs, 46 easy cool-down (the easy time the
    /// limit held back, 36 of it the extension), and the builder's own check passes with the limit on.
    func testBaselineBuiltThreeDayPlanIsUnchanged() throws {
        let i = tenKInput(days: [.tuesday, .thursday, .saturday], weekly: 330)
        let plan = try XCTUnwrap(PlanBuilder.build(i, history: [], timeZone: tz).plan)
        let week = plan.weeks[0]
        XCTAssertEqual(week.workouts.map { [$0.kind == .long ? "L" : $0.kind == .easy ? "e" : "q", String(Int(($0.durationSeconds / 60).rounded()))] },
                       [["q", "103"], ["e", "103"], ["L", "103"]])
        let q = try XCTUnwrap(week.workouts.first { $0.kind.isQuality })
        XCTAssertEqual(q.prescription?.segments.map { Int($0.durationSeconds / 60) }, [15, 9, 2, 9, 2, 9, 2, 9, 46])
        XCTAssertTrue(q.prescription?.purpose.contains(EasyExtension.sentence(minutes: 36)) ?? false, q.prescription?.purpose ?? "")
        XCTAssertEqual(q.easyExtensionSeconds / 60, 36)
        var limits = GuardrailLimits()
        limits.easyRunsWithinLongRun = true
        XCTAssertTrue(GuardrailChecker.check(history: [], planned: plan.weeks.flatMap(\.workouts), timeZone: tz, limits: limits).passed)
    }

    /// Baseline 2, as on main: 400 min on Tue/Thu/Fri/Sun holds e105 q85 e105 L105 in week 1; the
    /// quality session's cool-down takes 18 min of the time the limit held back.
    func testBaselineBuiltFourDayPlanIsUnchanged() throws {
        let i = tenKInput(days: [.tuesday, .thursday, .friday, .sunday], weekly: 400)
        let plan = try XCTUnwrap(PlanBuilder.build(i, history: [], timeZone: tz).plan)
        let week = plan.weeks[0]
        XCTAssertEqual(week.workouts.map { Int(($0.durationSeconds / 60).rounded()) }, [105, 85, 105, 105])
        XCTAssertEqual(week.workouts.map(\.kind), [.easy, .quality(.threshold), .easy, .long])
        XCTAssertEqual(week.workouts.map(\.easyExtensionSeconds), [0, 1080, 0, 0])
        XCTAssertEqual(week.workouts.filter { $0.prescription?.purpose.contains("The last") ?? false }.count, 1)
    }

    // MARK: Helpers

    private func qualityWithExtension(_ id: String, week: Int, day: Int, extensionMinutes: Int) -> PlannedWorkout {
        let segments = [F.segment(.warmUp, .easy, 10), F.segment(.work, .threshold, 20),
                        F.segment(.coolDown, .easy, Double(10 + extensionMinutes))]
        let p = WorkoutPrescription(purpose: "Threshold." + EasyExtension.sentence(minutes: extensionMinutes), phase: .build,
                                    segments: segments, rules: [.periodization])
        return PlannedWorkout(id: id, date: F.date(week: week, day: day), kind: .quality(.threshold),
                              durationSeconds: p.durationSeconds, prescription: p)
    }
}
