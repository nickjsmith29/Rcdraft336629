import XCTest
@testable import CoachCore

// #122: a long-run day the engine made an easy run stays inside the long-run
// share (SPEC 3.5 rule 5). Before, regrowth (`growBack`, #64) put the day back
// as an easy run at its long-run length, and repair's own long-to-easy swap
// (#64) kept the long run's length; the share counts only long runs, so
// neither was checked against it. Now regrowth restores the day as the long
// run, so the share reads it, and an easy run in place of a long run is no
// longer than the 20-minute floor or what the share leaves for the day,
// whichever is more (3.5 rule 6: swap first, then trim). #101's floor and
// week-1 cap, and every bound regrowth keeps, still hold. Synthetic runners
// and plans only; every threshold is a heuristic.
final class RegrowthLongRunShareTests: XCTestCase {
    typealias F = AdaptFixture
    private let floor = PlanHeuristics.minimumEasyRunSeconds
    private let share = GuardrailLimits.default.maxLongRunShare

    private func weekStart(_ d: Date) -> Date { PlanCalendar.weekStart(containing: d, timeZone: F.tz) }

    /// Every easy or recovery run still to come on a long-run day of `original`
    /// is at most the floor or `share` of its week's time (3.5 rule 5, #122).
    private func assertLongRunDaysInsideTheShare(_ outcomes: [AdaptationOutcome], original: [PlannedWorkout],
                                                 file: StaticString = #filePath, line: UInt = #line) {
        let longs = Set(original.filter { $0.kind == .long }.map(\.id))
        for (k, o) in outcomes.enumerated() {
            let asOf = o.history.map(\.date).max() ?? .distantPast
            let test = o.state.painRecovery.test?.workoutID
            for w in o.plan where (w.kind == .easy || w.kind == .recovery) && longs.contains(w.id) && w.date > asOf && w.id != test {
                let week = weekStart(w.date)
                let total = (o.history + o.plan).filter { weekStart($0.date) == week }.reduce(0) { $0 + ($1.volume(.time) ?? 0) }
                let inside = w.durationSeconds <= floor + 1e-6 || w.durationSeconds <= share * total + 1e-6
                XCTAssertTrue(inside, "outcome \(k): \(w.id) is an easy run of \(w.durationSeconds / 60) min, "
                              + "\(Int((w.durationSeconds / total * 100).rounded()))% of the week's \(total / 60) min",
                              file: file, line: line)
            }
        }
    }

    private func assertNoRunUnderTheFloor(_ outcomes: [AdaptationOutcome], file: StaticString = #filePath, line: UInt = #line) {
        for (k, o) in outcomes.enumerated() {
            let test = o.state.painRecovery.test?.workoutID
            for w in o.plan where w.kind != .rest && w.kind != .race && w.id != test {
                XCTAssertGreaterThanOrEqual(w.durationSeconds, floor - 1e-6, "outcome \(k): \(w.id) is \(w.durationSeconds / 60) min",
                                            file: file, line: line)
            }
        }
    }

    // MARK: The length an easy run on a long-run day may have

    func testTheEasyRunOnALongRunDayIsTheFloorOrWhatTheShareLeaves() {
        let w = F.long("l", week: 1, day: 5, minutes: 50)
        let s = GuardrailRepair.longRunDayEasySeconds
        // 35% of the week beside 60 min of other running: 0.35 / 0.65 x 60 = 32.3, so 32 min.
        XCTAssertEqual(s(w, 60 * 60, 0.35, floor), 32 * 60)
        // Beside 20 min, the share leaves 10.8 min: the floor.
        XCTAssertEqual(s(w, 20 * 60, 0.35, floor), floor)
        // The only run of its week: the floor.
        XCTAssertEqual(s(w, 0, 0.35, floor), floor)
        // Never longer than the run was.
        XCTAssertEqual(s(w, 600 * 60, 0.35, floor), 50 * 60)
        XCTAssertEqual(s(F.long("s", week: 1, day: 5, minutes: 15), 60 * 60, 0.35, floor), 15 * 60, "never lengthened to the floor")
        // At the boundary: 0.35 / 0.65 x 37.14 min is exactly 20 min.
        XCTAssertEqual(s(w, 20 * 60 * 0.65 / 0.35, 0.35, floor), floor)
    }

    func testTheEasyRunLengthRejectsInvalidInput() {
        let w = F.long("l", week: 1, day: 5, minutes: 50)
        let s = GuardrailRepair.longRunDayEasySeconds
        for bad in [Double.nan, .infinity, -0.1, 1, 1.5] {
            XCTAssertEqual(s(w, 60 * 60, bad, floor), floor, "share \(bad): only the floor")
        }
        for bad in [Double.nan, .infinity, -60] {
            XCTAssertEqual(s(w, bad, 0.35, floor), floor, "other running \(bad): only the floor")
        }
        for bad in [Double.nan, .infinity, 0, -60] {
            XCTAssertEqual(s(w, 60 * 60, 0.35, bad), 50 * 60, "floor \(bad): nothing to trim to")
        }
        var nan = w
        nan.durationSeconds = .nan
        XCTAssertTrue(s(nan, 60 * 60, 0.35, floor).isNaN, "a run of no valid length is left as it is")
    }

    // MARK: Repair's long-to-easy swap (#64)

    func testRepairsSwapKeepsTheLongRunDayInsideTheShare() {
        let history = (0..<4).map { F.easy("h\($0)", week: 0, day: $0 * 2, minutes: 50.0) }   // 200 min
        let asOf = F.date(week: 1, day: 0, hour: 6)
        // Beside 20 min of other running: an easy run at the floor, not 50 min (71% of the week).
        let thin = [F.easy("e1", week: 1, day: 2, minutes: 20), F.long("l1", week: 1, day: 6, minutes: 50)]
        let t = GuardrailRepair.repair(plan: thin, history: history, asOf: asOf, freezes: [], context: F.context())
        XCTAssertTrue(t.report.passed, "\(t.report.violations.map(\.explanation))")
        let l1 = t.plan.first { $0.id == "l1" }
        XCTAssertEqual(l1?.kind, .easy)
        XCTAssertEqual(l1?.durationSeconds, floor)
        XCTAssertEqual(l1?.prescription?.segments.map(\.durationSeconds), [floor])
        XCTAssertEqual(l1?.prescription?.rules, [.easyByHeartRate])
        XCTAssertEqual(t.plan.first { $0.id == "e1" }?.durationSeconds, 20 * 60, "the other run is left as it is")
        let c = t.changes.first { $0.kind == .longRunSwappedToEasy }
        XCTAssertEqual(c?.workoutIDs, ["l1"])
        XCTAssertEqual(c?.triggers.first?.metric, .longRunShare)
        XCTAssertTrue(c?.explanation.contains("20 min") ?? false, c?.explanation ?? "")
        XCTAssertTrue(c?.rule.contains("SPEC 3.5 rules 5 and 6") ?? false)

        // A long run already at the floor keeps its length.
        let atFloor = [F.easy("e1", week: 1, day: 2, minutes: 20), F.long("l1", week: 1, day: 6, minutes: 20)]
        let a = GuardrailRepair.repair(plan: atFloor, history: history, asOf: asOf, freezes: [], context: F.context())
        XCTAssertTrue(a.report.passed, "\(a.report.violations.map(\.explanation))")
        XCTAssertEqual(a.plan.first { $0.id == "l1" }?.kind, .easy)
        XCTAssertEqual(a.plan.first { $0.id == "l1" }?.durationSeconds, floor)
        XCTAssertTrue(a.changes.first { $0.kind == .longRunSwappedToEasy }?.explanation.contains("same length") ?? false)
    }

    func testRepairsSwapInDistanceScalesTheDistance() {
        var ctx = F.context()
        ctx.guardrails.measure = .distance
        func withDistance(_ w: PlannedWorkout) -> PlannedWorkout {
            var w = w
            w.distanceMeters = w.durationSeconds / 360 * 1000   // 6:00/km
            return w
        }
        let history = (0..<4).map { withDistance(F.easy("h\($0)", week: 0, day: $0 * 2, minutes: 50.0)) }
        let plan = [F.easy("e1", week: 1, day: 2, minutes: 20), F.long("l1", week: 1, day: 6, minutes: 60)].map(withDistance)
        let r = GuardrailRepair.repair(plan: plan, history: history, asOf: F.date(week: 1, day: 0, hour: 6), freezes: [], context: ctx)
        XCTAssertTrue(r.report.passed, "\(r.report.violations.map(\.explanation))")
        let l1 = r.plan.first { $0.id == "l1" }
        XCTAssertEqual(l1?.kind, .easy)
        XCTAssertEqual(l1?.durationSeconds, floor)
        XCTAssertEqual(l1?.distanceMeters ?? 0, floor / 360 * 1000, accuracy: 1e-6)
    }

    /// The time a shortening swap frees goes back to the week's runs this
    /// repair cut, never past their length before repair (#122). Week 0 ran
    /// 60 min (45 + 15), so week 1 may hold 66 min (10%). Week 1's 40-minute
    /// easy run is cut to 26 min for the weekly rise; then its 40-minute long
    /// run can't fit the share above the floor and becomes an easy run of
    /// 20 min. The 20 min that frees gives the easy run back its 14 min.
    func testASwapGivesTheTimeItFreesBackToTheRunsRepairCut() {
        let history = [F.easy("h0", week: 0, day: 1, minutes: 45), F.easy("h1", week: 0, day: 4, minutes: 15)]
        let plan = [F.easy("e1", week: 1, day: 2, minutes: 40), F.long("l1", week: 1, day: 6, minutes: 40)]
        let r = GuardrailRepair.repair(plan: plan, history: history, asOf: F.date(week: 1, day: 0, hour: 6), freezes: [], context: F.context())
        XCTAssertTrue(r.report.passed, "\(r.report.violations.map(\.explanation))")
        XCTAssertEqual(r.plan.first { $0.id == "l1" }?.kind, .easy)
        XCTAssertEqual(r.plan.first { $0.id == "l1" }?.durationSeconds, floor)
        XCTAssertEqual(r.plan.first { $0.id == "e1" }?.durationSeconds, 40 * 60, "given back, never past its length before repair")
        XCTAssertEqual(r.plan.reduce(0) { $0 + $1.durationSeconds }, 60 * 60, "under the 66 min the week may hold")
        let c = r.changes.first { $0.kind == .longRunSwappedToEasy }
        XCTAssertTrue(c?.explanation.contains("goes back") ?? false, c?.explanation ?? "")
        XCTAssertEqual(c?.workoutIDs, ["l1", "e1"])
    }

    /// The give-back keeps the guardrails: here the easy run was cut for the
    /// spike rule (30-minute runs before, so at most 33 min), and none of
    /// the freed time can go back to it.
    func testTheGiveBackKeepsTheSpikeRule() {
        let history = [F.easy("h0", week: 0, day: 1, minutes: 30), F.easy("h1", week: 0, day: 4, minutes: 30)]
        let plan = [F.easy("e1", week: 1, day: 2, minutes: 45), F.long("l1", week: 1, day: 6, minutes: 33)]
        let r = GuardrailRepair.repair(plan: plan, history: history, asOf: F.date(week: 1, day: 0, hour: 6), freezes: [], context: F.context())
        XCTAssertTrue(r.report.passed, "\(r.report.violations.map(\.explanation))")
        XCTAssertEqual(r.plan.first { $0.id == "e1" }?.durationSeconds, 33 * 60)
        XCTAssertEqual(r.plan.first { $0.id == "l1" }?.kind, .easy)
        XCTAssertEqual(r.plan.first { $0.id == "l1" }?.durationSeconds, floor)
        XCTAssertFalse(r.changes.contains { $0.explanation.contains("goes back") })
    }

    // MARK: Regrowth (growBack) restores the day as the long run

    /// Four weeks of Tue threshold (54 min), Thu easy (55), Sat long (60), Sun
    /// easy (45), 214 min. Week 1 is missed, so weeks 2 and 3 grow back. On Monday of
    /// week 2 the engine's own plan holds Saturday's long run as a 20-minute
    /// easy run (as a swap or the floor leaves it), handed back unchanged.
    private func regrowing() -> (d: F.Driver, original: [PlannedWorkout]) {
        let original = F.weeks(0..<4)
        var d = F.Driver(plan: original, context: F.context())
        d.follow(until: F.date(week: 1, day: 6, hour: 23)) { w in self.weekStart(w.date) == self.weekStart(F.date(week: 1, day: 0)) ? nil : F.RunSpec() }
        d.day(F.date(week: 1, day: 6, hour: 23))
        let i = d.plan.firstIndex { $0.id == "l2" }!
        d.plan[i] = d.plan[i].resized(toSeconds: floor).swappedToEasy()
        d.state.planSnapshot.returned = PlanSnapshot.returned(d.plan)   // the engine's plan handed back, not a re-plan
        d.day(F.date(week: 2, day: 0, hour: 5))
        return (d, original)
    }

    /// The changes since the plan was handed back with the 20-minute easy run.
    private func changesSinceHandBack(_ d: F.Driver) -> [PlanChange] {
        d.outcomes.filter { $0.history.allSatisfy { weekStart($0.date) < weekStart(F.date(week: 2, day: 0)) } }
            .suffix(2).flatMap(\.changes)
    }

    func testRegrowthRestoresALongRunDayAsALongRunInsideTheShare() {
        let (d, original) = regrowing()
        let o = d.outcomes.last!
        XCTAssertFalse(o.regrowth.weeks.isEmpty, "week 2 is a regrowth week")
        let l2 = d.plan.first { $0.id == "l2" }
        let week = weekStart(F.date(week: 2, day: 0))
        let total = d.plan.filter { weekStart($0.date) == week }.reduce(0) { $0 + $1.durationSeconds }
        print("#122 regrowth: l2 \(l2.map { "\($0.kind) \($0.durationSeconds / 60) min" } ?? "none") of a week of \(total / 60) min")
        XCTAssertEqual(l2?.kind, .long, "the day comes back as the long run")
        XCTAssertLessThanOrEqual(l2?.durationSeconds ?? .infinity, share * total + 1e-6)
        XCTAssertGreaterThan(l2?.durationSeconds ?? 0, floor, "it grew back")
        XCTAssertTrue(changesSinceHandBack(d).contains { $0.kind == .sessionRegrown && $0.workoutIDs.contains("l2") },
                      "\(changesSinceHandBack(d).map(\.kind))")
        assertLongRunDaysInsideTheShare(d.outcomes, original: original)
        assertNoRunUnderTheFloor(d.outcomes)
        assertAdaptationSound(d.outcomes)
        for w in 2..<4 {
            XCTAssertLessThanOrEqual(F.weekVolume(w, d.history + d.plan), F.weekVolume(w, original) + 1e-6, "week \(w): never above the plan")
        }
    }

    func testTheRestoredWeekKeepsTheRegrowthBound() {
        let (d, _) = regrowing()
        let o = d.outcomes.last!
        let week = weekStart(F.date(week: 2, day: 0))
        guard let g = o.regrowth.week(week) else { return XCTFail("week 2 is a regrowth week") }
        let held = (d.history + d.plan).filter { weekStart($0.date) == week }.reduce(0) { $0 + $1.durationSeconds }
        // Week 1 was missed: the bound is the higher of 20% over 0 and the 65% step.
        let bound = g.allowed(previous: F.weekVolume(1, d.history)) ?? 0
        XCTAssertLessThanOrEqual(held, bound + 1e-6)
        XCTAssertTrue(o.guardrailReport.passed, "\(o.guardrailReport.violations.map(\.explanation))")
        XCTAssertTrue(o.holdsSatisfied)
    }

    /// Following the regrowth to its end: no outcome leaves an easy run on a
    /// long-run day outside the share, and every bound still holds.
    func testARegrowthRunToItsEndKeepsEveryLongRunDayInsideTheShare() {
        var (d, original) = regrowing()
        d.follow(until: F.date(week: 3, day: 6, hour: 23)) { $0.kind == .rest ? nil : F.RunSpec() }
        assertLongRunDaysInsideTheShare(d.outcomes, original: original)
        assertNoRunUnderTheFloor(d.outcomes)
        assertAdaptationSound(d.outcomes)
        XCTAssertTrue(d.outcomes.last!.holdsSatisfied)
        for w in 0..<4 {
            XCTAssertLessThanOrEqual(F.weekVolume(w, d.history + d.plan), F.weekVolume(w, original) + 1e-6, "week \(w)")
        }
    }

    // MARK: The return after a pain stop (the #117 review's probe)

    private func context() -> AdaptationContext {
        AdaptationContext(zones: F.zones, timeZone: F.tz, tracksPain: true, usualPainSeed: 2)
    }

    /// Stopped by pain that got worse during Tuesday's threshold session of
    /// week 0, then two good mornings and a passed test run: the return's
    /// week 1 runs to the end of week 1, then weeks 2 to 4 grow back. Every
    /// run is run as planned.
    private func returning(long: Double) -> (d: F.Driver, original: [PlannedWorkout]) {
        let original = F.weeks(0..<6, longMinutes: { _ in long })
        var d = F.Driver(plan: original, context: context())
        d.follow(until: F.date(week: 0, day: 1, hour: 8)) { _ in F.RunSpec() }
        d.afterRun(week: 0, day: 1, 3, worsened: true, activityID: "run-t0")
        d.morning(week: 0, day: 2, 2, walking: 1)
        d.morning(week: 0, day: 3, 1, walking: 0)
        d.runTest(3, worsened: true)
        d.morning(week: 0, day: 4, 2)
        return (d, original)
    }

    func testTheReturnWeeksKeepEveryLongRunDayInsideTheShare() {
        for long in [28.0, 40, 60, 90] {
            var (d, original) = returning(long: long)
            XCTAssertNotNil(d.state.painRecovery.painReturn, "long \(long): the return has begun")
            d.follow(until: F.date(week: 4, day: 6, hour: 23)) { $0.kind == .rest ? nil : F.RunSpec() }
            print("#122 return, long \(long): weeks 1-4 ran \((1...4).map { F.weekVolume($0, d.history) / 60 }) min; long-run days "
                  + "\(d.history.filter { $0.id.hasPrefix("run-l") }.map { "\($0.id) \($0.kind) \(Int($0.durationSeconds / 60))" })")
            assertLongRunDaysInsideTheShare(d.outcomes, original: original)
            assertNoRunUnderTheFloor(d.outcomes)
            assertAdaptationSound(d.outcomes)
            for w in 1...5 {
                XCTAssertLessThanOrEqual(F.weekVolume(w, d.history + d.plan), F.weekVolume(w, original) + 1e-6, "long \(long), week \(w)")
            }
        }
    }

    /// The #117 review's probe: in return weeks 2 to 4 the runner misses the
    /// Tuesday and Thursday runs, so by Saturday the long run has too little
    /// running around it for a long run above the floor, and repair swaps it
    /// for an easy run (#64). Before #122 that easy run kept the long run's
    /// length outside the share (28 min, 38% of its week, for a 28-minute
    /// long run); now the day comes back as the long run, inside the share.
    func testThinReturnWeeksSwapTheLongRunForAnEasyRunAtTheFloor() {
        for long in [28.0, 40, 60] {
            var (d, original) = returning(long: long)
            d.follow(until: F.date(week: 4, day: 6, hour: 23)) { w in
                let day = PlanCalendar.calendar(timeZone: F.tz).component(.weekday, from: w.date)   // 3 Tue, 5 Thu
                let thin = w.date >= F.date(week: 2, day: 0, hour: 0) && (day == 3 || day == 5)
                return w.kind == .rest || thin ? nil : F.RunSpec()
            }
            print("#122 thin return, long \(long): weeks 1-4 ran \((1...4).map { F.weekVolume($0, d.history) / 60 }) min; long-run days "
                  + "\(d.history.filter { $0.id.hasPrefix("run-l") }.map { "\($0.id) \($0.kind) \(Int($0.durationSeconds / 60))" })")
            assertLongRunDaysInsideTheShare(d.outcomes, original: original)
            assertNoRunUnderTheFloor(d.outcomes)
            assertAdaptationSound(d.outcomes)
            for w in 1...5 {
                XCTAssertLessThanOrEqual(F.weekVolume(w, d.history + d.plan), F.weekVolume(w, original) + 1e-6, "long \(long), week \(w)")
            }
        }
    }

    func testTheWeekOneCapOnTheLongRunDayStillHolds() {
        // #101: 65% of a 28-minute pre-stop long run is under the floor, so
        // week 1's long-run day is an easy run at the floor; regrowth doesn't
        // bring it back as the long run while week 1 lasts.
        var (d, original) = returning(long: 28)
        d.day(F.date(week: 1, day: 0, hour: 5))
        d.day(F.date(week: 1, day: 4, hour: 5))
        let l1 = d.plan.first { $0.id == "l1" }
        XCTAssertEqual(l1?.kind, .easy)
        XCTAssertEqual(l1?.durationSeconds, floor)
        assertLongRunDaysInsideTheShare(d.outcomes, original: original)
        assertNoRunUnderTheFloor(d.outcomes)
        assertAdaptationSound(d.outcomes)
    }
}
