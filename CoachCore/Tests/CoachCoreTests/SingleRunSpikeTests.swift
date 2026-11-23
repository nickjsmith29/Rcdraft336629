import XCTest
@testable import CoachCore

// SPEC 3.5 rule 1 (single-run spike rule), F3, F4, F9. Synthetic runs only:
// every duration, distance and heart rate below is made up.
final class SingleRunSpikeTests: XCTestCase {
    typealias P = PlanFixture
    typealias A = AdaptFixture
    private let utc = PlanFixture.utc

    private func spikes(_ r: GuardrailReport) -> [GuardrailViolation] { r.violations.filter { $0.rule == .singleRunSpike } }
    private func spikeSkips(_ r: GuardrailReport) -> [GuardrailSkip] { r.notEvaluated.filter { $0.rule == .singleRunSpike } }

    private func run(_ id: String, week: Int, day: Int, _ kind: PlannedWorkout.Kind = .easy, minutes: Double,
                     km: Double? = nil, hour: Int = 7) -> PlannedWorkout {
        PlannedWorkout(id: id, date: P.date(week: week, day: day, hour: hour), kind: kind,
                       durationSeconds: minutes * 60, distanceMeters: km.map { $0 * 1000 })
    }

    private func check(_ history: [PlannedWorkout], _ planned: [PlannedWorkout],
                       limits: GuardrailLimits = .default) -> GuardrailReport {
        GuardrailChecker.check(history: history, planned: planned, timeZone: utc, limits: limits)
    }

    // MARK: The 10% boundary

    func testExactlyTenPercentPassesAndJustOverFails() throws {
        let history = [run("h", week: 0, day: 5, .long, minutes: 60)]
        XCTAssertTrue(spikes(check(history, [run("p", week: 1, day: 5, .long, minutes: 66)])).isEmpty)

        var over = run("p", week: 1, day: 5, .long, minutes: 66)
        over.durationSeconds += 1
        let v = try XCTUnwrap(spikes(check(history, [over])).first)
        XCTAssertEqual(v.workoutID, "p")
        XCTAssertEqual(v.measured, 66 * 60 + 1)
        XCTAssertEqual(v.allowed, 66 * 60, accuracy: 1e-6)
        XCTAssertEqual(v.unit, .seconds)
        XCTAssertEqual(v.weekStart, P.date(week: 1, day: 0, hour: 0))
        XCTAssertTrue(v.explanation.contains("longest run of the 30 days"), v.explanation)
        XCTAssertTrue(v.explanation.contains("SPEC 3.5 rule 1"), v.explanation)
    }

    func testTheLimitIsConfigurable() {
        let history = [run("h", week: 0, day: 5, .long, minutes: 100)]
        let planned = [run("p", week: 1, day: 5, .long, minutes: 106)]
        XCTAssertTrue(spikes(check(history, planned)).isEmpty)
        XCTAssertEqual(spikes(check(history, planned, limits: GuardrailLimits(maxSingleRunIncrease: 0.05))).count, 1)
        XCTAssertTrue(spikes(check(history, planned, limits: GuardrailLimits(maxSingleRunIncrease: .infinity))).isEmpty)
    }

    func testEveryPlannedRunIsCheckedNotOnlyLongRuns() {
        let history = [run("h", week: 0, day: 5, .long, minutes: 40)]
        let planned = [run("q", week: 1, day: 1, .quality(.threshold), minutes: 50), run("e", week: 1, day: 3, minutes: 30)]
        XCTAssertEqual(spikes(check(history, planned)).map(\.workoutID), ["q"])
    }

    // MARK: The window: rolling 30 days back from each run

    func testDayThirtyCountsAndDayThirtyOneDoesNot() {
        // The planned run is on week 5 Monday (day 35) at 07:00; 30 days before is day 5.
        let planned = [run("p", week: 5, day: 0, .long, minutes: 99)]
        let filler = [run("f", week: 4, day: 0, minutes: 50)]
        let day30 = [run("h30", week: 0, day: 5, .long, minutes: 90, hour: 23)]  // 30 days back, later in the day
        let day31 = [run("h31", week: 0, day: 4, .long, minutes: 90, hour: 23)]  // 31 days back
        XCTAssertTrue(spikes(check(day30 + filler, planned)).isEmpty, "a run 30 days back is in the window")
        let out = spikes(check(day31 + filler, planned))
        XCTAssertEqual(out.map(\.workoutID), ["p"], "a run 31 days back is not")
        XCTAssertEqual(out.first?.allowed ?? 0, 55 * 60, accuracy: 1e-6)
    }

    func testTheWindowRollsWithEachRun() {
        // A 90-minute run covers runs up to 30 days later; after that the 50s set the reference.
        let history = [run("big", week: 0, day: 0, .long, minutes: 90)] + (0..<5).map { run("h\($0)", week: $0, day: 3, minutes: 50) }
        // Week 4 day 2 is 30 days after week 0 day 0: still in. Day 6 is 34 days after: out.
        XCTAssertTrue(spikes(check(history, [run("in", week: 4, day: 2, .long, minutes: 95)])).isEmpty)
        XCTAssertEqual(spikes(check(history, [run("out", week: 4, day: 6, .long, minutes: 95)])).first?.allowed ?? 0,
                       55 * 60, accuracy: 1e-6)
    }

    func testEarlierPlannedRunsCountAndSameDayEarlierRunsCount() {
        let history = [run("h", week: 0, day: 5, .long, minutes: 60)]
        let planned = [run("p1", week: 1, day: 5, .long, minutes: 66), run("p2", week: 2, day: 5, .long, minutes: 72.6)]
        XCTAssertTrue(spikes(check(history, planned)).isEmpty, "p1 is in p2's window")
        let doubles = [run("am", week: 1, day: 2, minutes: 60, hour: 6), run("pm", week: 1, day: 2, minutes: 66, hour: 18)]
        XCTAssertTrue(spikes(check([], doubles)).isEmpty)
    }

    // MARK: Empty history, unknown times, NaN and infinity

    func testEmptyHistoryIsNotEvaluatedNotGuessed() {
        let r = check([], [run("p", week: 1, day: 5, .long, minutes: 200)])
        XCTAssertTrue(spikes(r).isEmpty)
        XCTAssertEqual(spikeSkips(r).map(\.workoutID), ["p"])
        XCTAssertTrue(spikeSkips(r)[0].reason.contains("no run of known time"), spikeSkips(r)[0].reason)
    }

    func testHistoryOfOnlyUnknownTimesIsNotEvaluated() {
        var broken = run("h", week: 0, day: 5, .long, minutes: 60)
        broken.durationSeconds = .nan
        var infinite = run("i", week: 0, day: 3, minutes: 60)
        infinite.durationSeconds = .infinity
        var negative = run("n", week: 0, day: 1, minutes: 60)
        negative.durationSeconds = -60
        let r = check([broken, infinite, negative], [run("p", week: 1, day: 5, .long, minutes: 300)])
        XCTAssertTrue(spikes(r).isEmpty, "an unknown run never makes the reference look low")
        XCTAssertEqual(spikeSkips(r).map(\.workoutID), ["p"])
        XCTAssertNil(GuardrailChecker.spikeReference(before: P.date(week: 1, day: 5), measure: .time,
                                                     sessions: [broken, infinite, negative], timeZone: utc))
    }

    func testAnUnknownRunNeverCountsAsTheLongestAndIsNamed() throws {
        var broken = run("broken", week: 0, day: 6, .long, minutes: 120)
        broken.durationSeconds = .nan
        let history = [run("h", week: 0, day: 3, minutes: 60), broken]
        XCTAssertTrue(spikes(check(history, [run("ok", week: 1, day: 5, .long, minutes: 66)])).isEmpty)
        let v = try XCTUnwrap(spikes(check(history, [run("p", week: 1, day: 5, .long, minutes: 80)])).first)
        XCTAssertEqual(v.allowed, 66 * 60, accuracy: 1e-6, "measured against the longest known run")
        XCTAssertTrue(v.explanation.contains("no known time is left out"), v.explanation)
        let ref = try XCTUnwrap(GuardrailChecker.spikeReference(before: P.date(week: 1, day: 5), measure: .time,
                                                                sessions: history, timeZone: utc))
        XCTAssertEqual(ref.workoutID, "h")
        XCTAssertEqual(ref.unknownWorkoutIDs, ["broken"])
    }

    func testAPlannedRunOfUnknownLengthIsNeverFlagged() {
        let history = [run("h", week: 0, day: 5, .long, minutes: 60)]
        for bad in [Double.nan, .infinity, -.infinity, -1] {
            var p = run("p", week: 1, day: 5, .long, minutes: 60)
            p.durationSeconds = bad
            let r = check(history, [p])
            XCTAssertTrue(spikes(r).isEmpty, "\(bad)")
            XCTAssertEqual(spikeSkips(r).map(\.workoutID), ["p"], "\(bad)")
        }
    }

    /// An invalid limit (NaN, below 0, -inf) is stored as the default 10%
    /// (#142, `GuardrailLimits.valid`), so the rule still runs; before, it
    /// was skipped as not evaluated, and the checker's own skip for it is
    /// gone (#150). `.infinity` still switches it off, with no violation and
    /// no skip.
    func testAnInvalidLimitChecksAsTheDefault() {
        let history = [run("h", week: 0, day: 5, .long, minutes: 60)]
        let planned = [run("p", week: 1, day: 5, .long, minutes: 200)]
        let expected = check(history, planned)
        XCTAssertEqual(spikes(expected).map(\.workoutID), ["p"])
        for bad in [Double.nan, -0.1, -.infinity] {
            let r = check(history, planned, limits: GuardrailLimits(maxSingleRunIncrease: bad))
            XCTAssertEqual(r, expected, "\(bad)")
            XCTAssertTrue(spikeSkips(r).isEmpty, "\(bad)")
        }
        let off = check(history, planned, limits: GuardrailLimits(maxSingleRunIncrease: .infinity))
        XCTAssertTrue(spikes(off).isEmpty)
        XCTAssertTrue(spikeSkips(off).isEmpty)
    }

    func testRestDaysAreNotRuns() {
        let history = [run("h", week: 0, day: 5, .long, minutes: 60), run("rest", week: 1, day: 0, .rest, minutes: 600)]
        let planned = [run("r2", week: 1, day: 1, .rest, minutes: 999), run("p", week: 1, day: 5, .long, minutes: 67)]
        XCTAssertEqual(spikes(check(history, planned)).map(\.workoutID), ["p"])
    }

    // MARK: Distance

    func testDistanceIsCheckedWhenThePlanStatesOne() throws {
        let history = [run("h", week: 0, day: 5, .long, minutes: 60, km: 10)]
        XCTAssertTrue(spikes(check(history, [run("p", week: 1, day: 5, .long, minutes: 60, km: 11)])).isEmpty)
        let v = try XCTUnwrap(spikes(check(history, [run("p", week: 1, day: 5, .long, minutes: 60, km: 11.5)])).first)
        XCTAssertEqual(v.unit, .meters)
        XCTAssertEqual(v.allowed, 11_000, accuracy: 1e-6)
        // Over in both: the measure needing the larger cut is reported.
        let both = try XCTUnwrap(spikes(check(history, [run("p", week: 1, day: 5, .long, minutes: 70, km: 11.5)])).first)
        XCTAssertEqual(both.unit, .seconds, "70/66 is a bigger overrun than 11.5/11")
        // A plan without distances is checked in time only.
        XCTAssertTrue(spikes(check(history, [run("p", week: 1, day: 5, .long, minutes: 66)])).isEmpty)
    }

    // MARK: Races

    func testAPlannedRaceIsOnlyAnInformationFlag() throws {
        let history = [run("h", week: 0, day: 5, .long, minutes: 90)]
        let r = check(history, [run("easy", week: 1, day: 2, minutes: 40), run("race", week: 1, day: 6, .race, minutes: 125)])
        XCTAssertTrue(spikes(r).isEmpty, "a race is never blocked")
        XCTAssertTrue(spikeSkips(r).isEmpty)
        let f = try XCTUnwrap(r.informationFlags.first)
        XCTAssertEqual(f.rule, .singleRunSpike)
        XCTAssertEqual(f.workoutID, "race")
        XCTAssertEqual(f.allowed, 99 * 60, accuracy: 1e-6)
        XCTAssertTrue(f.explanation.contains("information"), f.explanation)
    }

    func testACompletedRaceInACheckedWeekIsFlaggedAndNeverRaisesTheReference() throws {
        let history = [run("h", week: 0, day: 5, .long, minutes: 90), run("race", week: 1, day: 0, .race, minutes: 130)]
        let planned = [run("after", week: 2, day: 5, .long, minutes: 120)]
        // The race week is not checked here (plan starts in week 2), so no flag; the race does not set the reference.
        let r = check(history, planned)
        XCTAssertEqual(spikes(r).first?.allowed ?? 0, 99 * 60, accuracy: 1e-6)
        XCTAssertTrue(spikes(r).first?.explanation.contains("1 h 30 min") ?? false)
        // Opting in lets the race set it.
        XCTAssertTrue(spikes(check(history, planned, limits: GuardrailLimits(racesSetSpikeReference: true))).isEmpty)
        // A race done in a checked week (a mid-week re-plan) is flagged.
        let midWeek = check(history, [run("rest-of-week", week: 1, day: 3, minutes: 40)])
        XCTAssertEqual(midWeek.informationFlags.map(\.workoutID), ["race"])
        XCTAssertTrue(spikes(midWeek).isEmpty)
    }

    // MARK: Plan builder (F3): no generated plan breaks the rule

    /// Independent brute-force reading of 3.5 rule 1 for plans in time.
    private func spikeBreaks(history: [PlannedWorkout], plan: [PlannedWorkout], tz: TimeZone) -> [String] {
        let cal = PlanCalendar.calendar(timeZone: tz)
        let all = history + plan
        func known(_ w: PlannedWorkout) -> Bool { w.durationSeconds.isFinite && w.durationSeconds > 0 }
        var out: [String] = []
        for r in plan where r.kind != .rest && r.kind != .race && known(r) {
            let from = cal.date(byAdding: .day, value: -30, to: cal.startOfDay(for: r.date))!
            let ref = all.filter { $0.date >= from && $0.date < r.date && $0.kind != .rest && $0.kind != .race && known($0) }
                .map(\.durationSeconds).max()
            if let ref, r.durationSeconds > ref * 1.1 + 1e-6 { out.append(r.id) }
        }
        return out
    }

    /// A small deterministic generator (an LCG), so the property test is repeatable.
    private struct Rng {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func pick<T>(_ xs: [T]) -> T { xs[min(xs.count - 1, Int(next() * Double(xs.count)))] }
    }

    func testNoGeneratedPlanBreaksTheSpikeRule() {
        var rng = Rng(state: 67)
        let monday = P.date(week: 10, day: 0, hour: 0)
        let cal = PlanCalendar.calendar(timeZone: utc)
        let dayChoices: [Set<PlanWeekday>] = [
            [.tuesday, .thursday, .saturday], [.monday, .wednesday, .friday, .sunday],
            [.tuesday, .wednesday, .thursday, .saturday, .sunday], [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday],
        ]
        var built = 0
        for n in 0..<120 {
            let days = rng.pick(dayChoices)
            let longDay = days.max()!
            let weekly = 120 + rng.next() * 360            // minutes
            let longShare = 0.25 + rng.next() * 0.12
            let historyWeeks = rng.pick([0, 2, 5, 8])
            let unknownRun = rng.next() < 0.25
            let historyRace = rng.next() < 0.2
            let distance = rng.pick([Distance.fiveK, Distance.tenK, Distance.halfMarathon, Distance.marathon])
            let leadWeeks = rng.pick([8, 12, 16, 24])
            var history: [PlannedWorkout] = []
            var weekTotals: [Double] = []
            for k in 0..<historyWeeks {
                let m = 0.85 + rng.next() * 0.2
                let total = weekly * m
                weekTotals.append(total)
                let long = total * longShare
                let others = days.filter { $0 != longDay }
                for d in days {
                    let minutes = d == longDay ? long : (total - long) / Double(others.count)
                    let date = cal.date(byAdding: .day, value: (k - historyWeeks) * 7 + d.rawValue, to: monday)!
                        .addingTimeInterval(7 * 3600)
                    history.append(PlannedWorkout(id: "h\(n)-\(k)-\(d.rawValue)", date: date, kind: d == longDay ? .long : .easy,
                                                  durationSeconds: minutes * 60))
                }
            }
            if unknownRun, !history.isEmpty { history[history.count - 1].durationSeconds = .nan }
            if historyRace, historyWeeks >= 2 {
                history.append(PlannedWorkout(id: "h\(n)-race", date: monday.addingTimeInterval(-10 * 86_400), kind: .race,
                                              durationSeconds: weekly * 0.6 * 60, distanceMeters: 21_097.5))
            }
            let recent = weekTotals.isEmpty ? weekly : weekTotals.suffix(4).reduce(0, +) / Double(min(4, weekTotals.count))
            let race = cal.date(byAdding: .day, value: (leadWeeks - 1) * 7 + 6, to: monday)!.addingTimeInterval(8 * 3600)
            let input = PlanInput(raceDistanceMeters: distance, raceDate: race, startDate: monday, trainingDays: days,
                                  longRunDay: longDay, maxSessionSeconds: rng.next() < 0.3 ? 150 * 60 : nil,
                                  recentWeeklySeconds: recent * 60,
                                  recentLongRunSeconds: rng.next() < 0.7 ? weekly * longShare * 60 : nil,
                                  heartRateZones: HRZones(lthr: 150 + rng.next() * 30),
                                  easyPace: EasyPaceSample(secondsPerKm: 330 + rng.next() * 90, heartRate: 120),
                                  fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: (19 + rng.next() * 12) * 60))
            let label = "#\(n) \(Int(weekly)) min \(historyWeeks)w history \(Int(distance)) m"
            let result = PlanBuilder.build(input, history: history, timeZone: utc)
            guard let plan = result.plan else {
                // Refusals are fine; the checker's safety net firing is not.
                XCTAssertFalse(result.issues.contains { if case .failsGuardrails = $0 { return true }; return false },
                               "\(label): \(result.issues)")
                continue
            }
            built += 1
            let report = GuardrailChecker.check(history: history, planned: plan.workouts, timeZone: utc)
            XCTAssertTrue(report.passed, "\(label): \(report.violations.map(\.explanation))")
            XCTAssertEqual(spikeBreaks(history: history, plan: plan.workouts, tz: utc), [], label)
            XCTAssertTrue(plan.guardrailReport.violations.isEmpty, label)
            // Races are only ever flags of the spike rule (a marathon plan's
            // long run above the usual share is a flag of rule 5, #62).
            XCTAssertTrue(plan.guardrailReport.informationFlags.filter { $0.rule == .singleRunSpike }
                .allSatisfy { $0.workoutID == "plan-race" }, label)
            XCTAssertTrue(plan.guardrailReport.informationFlags.allSatisfy { $0.rule == .singleRunSpike || $0.rule == .longRunShare },
                          label)
        }
        XCTAssertGreaterThan(built, 60, "most generated inputs should build")
    }

    func testLongRunsGrowWithinTheSpikeRuleFromTheHistory() throws {
        // History: weeks of 300 min with an 80-minute long run on Sunday, the
        // middle one a recovery week, so the plan's first week is a build week.
        let monday = P.date(week: 5, day: 0, hour: 0)
        let days: Set<PlanWeekday> = [.tuesday, .wednesday, .thursday, .saturday, .sunday]
        let history = (0..<5).flatMap { w -> [PlannedWorkout] in
            let m = w == 2 ? 0.75 : 1
            return [run("h\(w)a", week: w, day: 1, minutes: 55 * m), run("h\(w)b", week: w, day: 2, minutes: 55 * m),
                    run("h\(w)c", week: w, day: 3, minutes: 55 * m), run("h\(w)d", week: w, day: 5, minutes: 55 * m),
                    run("h\(w)l", week: w, day: 6, .long, minutes: 80 * m)]
        }
        let input = PlanInput(raceDistanceMeters: Distance.halfMarathon, raceDate: P.date(week: 5 + 15, day: 6, hour: 8),
                              startDate: monday, trainingDays: days, longRunDay: .sunday, recentWeeklySeconds: 300 * 60,
                              recentLongRunSeconds: 80 * 60, heartRateZones: HRZones(lthr: 165),
                              fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: 22 * 60))
        let plan = try XCTUnwrap(PlanBuilder.build(input, history: history, timeZone: utc).plan)
        let longs = plan.workouts.filter { $0.kind == .long }
        // The first long run: within 10% of 80 (88), under the 10-minute step's 90.
        XCTAssertFalse(plan.weeks[0].isRecoveryWeek)
        XCTAssertLessThanOrEqual(longs[0].durationSeconds, 88 * 60)
        XCTAssertGreaterThanOrEqual(longs[0].durationSeconds, 84 * 60)
        XCTAssertTrue(longs[0].prescription?.rules.contains(.singleRunSpike) ?? false)
        XCTAssertEqual(spikeBreaks(history: history, plan: plan.workouts, tz: utc), [])
    }

    func testAPlanWithNoHistoryHoldsItsFirstWeekTogether() throws {
        // No history: the first week's runs can only be measured against each other.
        let input = PlanInput(raceDistanceMeters: Distance.tenK, raceDate: P.date(week: 12, day: 6, hour: 8),
                              startDate: P.date(week: 0, day: 0, hour: 0), trainingDays: [.monday, .wednesday, .friday, .sunday],
                              longRunDay: .sunday, recentWeeklySeconds: 240 * 60, recentLongRunSeconds: 80 * 60,
                              heartRateZones: HRZones(lthr: 165),
                              fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: 24 * 60))
        let plan = try XCTUnwrap(PlanBuilder.build(input, history: [], timeZone: utc).plan)
        XCTAssertEqual(spikeBreaks(history: [], plan: plan.workouts, tz: utc), [])
        let report = plan.guardrailReport
        XCTAssertTrue(report.passed)
        // Only the very first session has nothing to compare with.
        XCTAssertEqual(spikeSkips(report).map(\.workoutID), [plan.workouts[0].id])
    }

    /// Totals of the training weeks (race week left out), in minutes.
    private func trainingWeekMinutes(_ plan: TrainingPlan) -> [Double] {
        plan.weeks.filter { !$0.isRaceWeek }.map { $0.workouts.reduce(0) { $0 + $1.durationSeconds } / 60 }
    }

    func testAnEmptyHistoryTenKKeepsItsFirstWeek() throws {
        // A 120-minute week over four days and nothing recorded before: the
        // first week is reshaped to hold together, not cut in half.
        let input = PlanInput(raceDistanceMeters: Distance.tenK, raceDate: P.date(week: 12, day: 6, hour: 8),
                              startDate: P.date(week: 0, day: 0, hour: 0), trainingDays: [.monday, .wednesday, .friday, .sunday],
                              longRunDay: .sunday, recentWeeklySeconds: 120 * 60, heartRateZones: HRZones(lthr: 165),
                              fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: 26 * 60))
        let plan = try XCTUnwrap(PlanBuilder.build(input, history: [], timeZone: utc).plan)
        XCTAssertEqual(spikeBreaks(history: [], plan: plan.workouts, tz: utc), [])
        XCTAssertTrue(plan.guardrailReport.passed)
        let weeks = trainingWeekMinutes(plan)
        XCTAssertGreaterThanOrEqual(weeks[0], 0.9 * 120, "\(weeks)")
        XCTAssertGreaterThanOrEqual(weeks.max() ?? 0, 120, "\(weeks)")
        XCTAssertEqual(plan.weeks[0].workouts.filter { $0.kind != .rest }.count, 4)
        for w in plan.workouts where w.kind == .easy {
            XCTAssertGreaterThanOrEqual(w.durationSeconds, PlanHeuristics.minimumEasyRunSeconds, w.id)
        }
    }

    func testAnEmptyHistoryMarathonIsAnchoredByTheRecentLongRun() throws {
        // 400 minutes over three days, a recent long run of 120 minutes and
        // nothing recorded: the recent long run sets the first week's cap.
        let input = PlanInput(raceDistanceMeters: Distance.marathon, raceDate: P.date(week: 16, day: 6, hour: 8),
                              startDate: P.date(week: 0, day: 0, hour: 0), trainingDays: [.tuesday, .thursday, .sunday],
                              longRunDay: .sunday, recentWeeklySeconds: 400 * 60, recentLongRunSeconds: 120 * 60,
                              heartRateZones: HRZones(lthr: 165), easyPace: EasyPaceSample(secondsPerKm: 330, heartRate: 125),
                              fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: 21 * 60))
        let plan = try XCTUnwrap(PlanBuilder.build(input, history: [], timeZone: utc).plan)
        XCTAssertEqual(spikeBreaks(history: [], plan: plan.workouts, tz: utc), [])
        XCTAssertTrue(plan.guardrailReport.passed)
        let weeks = trainingWeekMinutes(plan)
        // Three sessions of at most 130 min (120 + 9%), one of them a quality
        // session of fixed length and a long run within its share: about 300.
        XCTAssertGreaterThanOrEqual(weeks[0], 0.7 * 400, "\(weeks)")
        // Three days with no easy run past the long run (F3, #23) hold the
        // peak a little under the recent 400 (about 394): at least 95% of it.
        XCTAssertGreaterThanOrEqual(weeks.max() ?? 0, 0.95 * 400, "\(weeks)")
        for w in plan.weeks[0].workouts {
            XCTAssertLessThanOrEqual(w.durationSeconds, 120 * 60 * 1.1, w.id)
        }
        for w in plan.workouts where w.kind == .easy {
            XCTAssertGreaterThanOrEqual(w.durationSeconds, PlanHeuristics.minimumEasyRunSeconds, w.id)
        }
    }

    private static let sweepDays: [Set<PlanWeekday>] = [
        // Three days, some opening the week with the quality session.
        [.tuesday, .thursday, .sunday], [.tuesday, .thursday, .saturday], [.monday, .wednesday, .friday],
        [.monday, .thursday, .saturday], [.wednesday, .friday, .sunday], [.monday, .wednesday, .friday, .sunday],
        [.tuesday, .wednesday, .thursday, .saturday, .sunday], [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday],
    ]

    /// Builds `input` with the spike rule on and off and compares them, the
    /// rule-off plan as the baseline.
    /// - The rule binds in a week when some session of the plan is within 5%
    ///   of its limit over the plan's own earlier runs (the builder aims 1%
    ///   under it, in whole minutes), or, in a week with nothing before it,
    ///   within 5% of 10% over the recent long run; or when a session of the
    ///   baseline's week is over the limit after the plan's own runs, so the
    ///   builder drafted the week again under the cap (`spikeHolds`).
    /// - No week has a run under the easy floor that the baseline's week
    ///   doesn't have too (#79 tracks the ones both have).
    /// - Until the rule first binds, every week is at least 95% of the
    ///   baseline's week. After that, every week the rule doesn't bind (race
    ///   week aside) is at least 95% of the smaller of the baseline's week and
    ///   what the plan's own week before allows it: 10% more, or the builder's
    ///   recovery ratio of it in a recovery week (#87). Exempt is a week held
    ///   at the bottom of the 3.1 band by a full steady finish on a long run
    ///   shorter than the baseline's, which the rule held in earlier weeks;
    ///   such a week is still at least 90% of that smaller week (#99).
    /// - When the baseline never breaks the rule (nor the recent-long-run cap
    ///   of a week with nothing before it), the plan is the baseline exactly.
    /// - The rule never changes whether a plan builds (#87), and neither plan
    ///   fails the checker.
    /// Returns the two plans when both build.
    @discardableResult
    private func compareWithRuleOff(_ input: PlanInput, history: [PlannedWorkout],
                                    _ label: String) -> (on: TrainingPlan, off: TrainingPlan)? {
        let off = GuardrailLimits(maxSingleRunIncrease: .infinity)
        let result = PlanBuilder.build(input, history: history, timeZone: utc)
        let offResult = PlanBuilder.build(input, history: history, timeZone: utc, limits: off)
        let baseline = offResult.plan
        XCTAssertEqual(result.plan != nil, baseline != nil,
                       "\(label): the rule changes whether the plan builds: \(result.issues) vs \(offResult.issues)")
        for issues in [result.issues, offResult.issues] {
            XCTAssertFalse(issues.contains { if case .failsGuardrails = $0 { return true }; return false }, "\(label): \(issues)")
        }
        guard let plan = result.plan else { return nil }
        XCTAssertEqual(spikeBreaks(history: history, plan: plan.workouts, tz: utc), [], label)
        guard let base = baseline else { return nil }
        XCTAssertEqual(plan.weeks.count, base.weeks.count, label)

        let floor = PlanHeuristics.minimumEasyRunSeconds
        func short(_ w: TrainingPlanWeek) -> Int { w.workouts.filter { $0.kind != .race && $0.kind != .rest && $0.durationSeconds < floor }.count }
        func total(_ w: TrainingPlanWeek) -> Double { w.workouts.reduce(0) { $0 + $1.durationSeconds } }
        let all = history + plan.workouts
        let cal = PlanCalendar.calendar(timeZone: utc)
        func unanchored(_ w: PlannedWorkout, week: TrainingPlanWeek) -> Bool {
            // Nothing of known time in the 30 days before the week's Monday... up to the run's own window.
            let from = cal.date(byAdding: .day, value: -30, to: cal.startOfDay(for: w.date))!
            return !history.contains { $0.date >= from && $0.date < week.weekStart && $0.durationSeconds.isFinite && $0.durationSeconds > 0 && $0.kind != .race && $0.kind != .rest }
                && !plan.workouts.contains { $0.date >= from && $0.date < week.weekStart && $0.kind != .race && $0.kind != .rest }
        }
        func binds(_ w: TrainingPlanWeek, _ b: TrainingPlanWeek) -> Bool {
            let near = w.workouts.contains { s in
                guard s.kind != .race && s.kind != .rest else { return false }
                if let ref = GuardrailChecker.spikeReference(before: s.date, measure: .time, sessions: all, timeZone: utc),
                   s.durationSeconds >= 0.95 * ref.allowed { return true }
                if let r = input.recentLongRunSeconds, unanchored(s, week: w), s.durationSeconds >= 0.95 * r * 1.1 { return true }
                return false
            }
            // The baseline's week would break the rule after the plan's own
            // runs, so the builder drafted the week again under the cap.
            let redrafted = b.workouts.contains { s in
                guard s.kind != .race && s.kind != .rest else { return false }
                return GuardrailChecker.spikeReference(before: s.date, measure: .time, sessions: all, timeZone: utc)
                    .map { s.durationSeconds > $0.allowed } ?? false
            }
            return near || redrafted
        }
        // A week shortened to the bottom of the 3.1 band whose hard time ends
        // in a full steady finish on a long run shorter than the baseline's:
        // the rule held the earlier long runs (the recovery week's is 80% of
        // the last one), so the week follows them, not the week before it.
        func heldByShorterLongRun(_ w: TrainingPlanWeek, _ b: TrainingPlanWeek) -> Bool {
            guard let l = w.workouts.first(where: { $0.kind == .long }), let bl = b.workouts.first(where: { $0.kind == .long }),
                  l.durationSeconds < bl.durationSeconds, total(w) > 0 else { return false }
            let segments = w.workouts.flatMap { $0.prescription?.segments ?? [] }
            let hard = segments.filter { !$0.intensity.isBelowAerobicThreshold }.reduce(0) { $0 + $1.durationSeconds }
            let finish = (l.prescription?.segments ?? []).filter { $0.role == .finish }.reduce(0) { $0 + $1.durationSeconds }
            let fullFinish = finish > 0 && finish >= PlanBuilder.floorMinute(PlanHeuristics.longRunFinishShare * l.durationSeconds)
            return fullFinish && hard / total(w) < PlanHeuristics.hardShareBand.lowerBound + 0.01
        }
        var bound = false
        var previous: TrainingPlanWeek?
        for (w, b) in zip(plan.weeks, base.weeks) {
            let text = "\(label) week \(w.index): \(w.workouts.map { Int($0.durationSeconds / 60) }) vs \(b.workouts.map { Int($0.durationSeconds / 60) })"
            let bindsHere = binds(w, b)
            XCTAssertLessThanOrEqual(short(w), short(b), text)
            if !bound && !bindsHere {
                XCTAssertGreaterThanOrEqual(total(w), 0.95 * total(b), text)
            } else if !bindsHere, !w.isRaceWeek, let prev = previous {
                // A week the rule doesn't bind follows the smaller weeks before it, no further.
                let allows = total(prev) * (w.isRecoveryWeek ? PlanHeuristics.recoveryWeekRatio : 1 + GuardrailLimits.default.maxWeeklyIncrease)
                // An exempt week still has a floor, so a bigger shrink can't
                // hide behind the exemption (#99). On the sweeps the exempt
                // weeks are all recovery weeks, the lowest at about 0.908.
                let bar = heldByShorterLongRun(w, b) ? 0.90 : 0.95
                XCTAssertGreaterThanOrEqual(total(w), bar * min(total(b), allows), "\(text) after \(Int(total(prev) / 60)) min")
            }
            bound = bound || bindsHere
            previous = w
        }
        let baseBreaks = !spikeBreaks(history: history, plan: base.workouts, tz: utc).isEmpty
        let baseOverRecentLong = input.recentLongRunSeconds.map { r in
            base.weeks.contains { w in w.workouts.contains { $0.kind != .race && unanchored($0, week: w) && $0.durationSeconds > r * 1.1 } }
        } ?? false
        if !baseBreaks && !baseOverRecentLong {
            XCTAssertEqual(plan.workouts.map { "\($0.id) \($0.date) \($0.durationSeconds)" },
                           base.workouts.map { "\($0.id) \($0.date) \($0.durationSeconds)" }, "\(label): the rule never binds")
        }
        return (plan, base)
    }

    func testEmptyHistoryPlansKeepTheirVolume() {
        // Every distance, three to six days, small to large weeks, no history,
        // with and without a recent long run, against the plan with the rule
        // off (`compareWithRuleOff`). The first week keeps its volume (less
        // where a recent long run caps every session at 10% over it), and the
        // build still reaches the runner's current week.
        var built = 0
        for distance in [Distance.fiveK, Distance.tenK, Distance.halfMarathon, Distance.marathon] {
            for days in Self.sweepDays {
                for weekly in [60.0, 90, 100, 120, 150, 180, 240, 330, 420] {
                    // A recent long run at least a little over the average session.
                    for recentLong: Double? in [nil, weekly * max(0.3, 1.2 / Double(days.count))] {
                        let input = PlanInput(raceDistanceMeters: distance, raceDate: P.date(week: 16, day: 6, hour: 8),
                                              startDate: P.date(week: 0, day: 0, hour: 0), trainingDays: days,
                                              longRunDay: days.max()!, recentWeeklySeconds: weekly * 60,
                                              recentLongRunSeconds: recentLong.map { $0 * 60 }, heartRateZones: HRZones(lthr: 165),
                                              easyPace: EasyPaceSample(secondsPerKm: 340, heartRate: 125),
                                              fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: 23 * 60))
                        let label = "\(Int(distance)) m, \(days.count) days, \(Int(weekly)) min, long \(recentLong.map { "\(Int($0))" } ?? "none")"
                        guard let (plan, base) = compareWithRuleOff(input, history: [], label) else { continue }
                        built += 1
                        let weeks = trainingWeekMinutes(plan), baseWeeks = trainingWeekMinutes(base)
                        XCTAssertGreaterThanOrEqual(weeks[0], (recentLong == nil ? 0.95 : 0.8) * baseWeeks[0],
                                                    "\(label): \(weeks) vs \(baseWeeks)")
                        XCTAssertGreaterThanOrEqual(weeks.max() ?? 0, 0.97 * min(weekly, baseWeeks[0]),
                                                    "\(label): \(weeks) vs \(baseWeeks)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(built, 400)
    }

    func testPlansWithHistoryMatchTheRuleOffPlanWhereItDoesNotBind() {
        // Four weeks of history at the runner's volume (30% of it in the long
        // run, the rest spread evenly), then the same comparison.
        var built = 0
        for distance in [Distance.fiveK, Distance.tenK, Distance.halfMarathon, Distance.marathon] {
            for days in Self.sweepDays {
                for weekly in [60.0, 90, 120, 180, 240, 330] {
                    let longDay = days.max()!
                    let long = weekly * 0.3
                    let others = days.filter { $0 != longDay }
                    let history = (0..<4).flatMap { w in
                        days.map { d in
                            PlannedWorkout(id: "h\(w)-\(d.rawValue)", date: P.date(week: w, day: d.rawValue, hour: 7),
                                           kind: d == longDay ? .long : .easy,
                                           durationSeconds: (d == longDay ? long : (weekly - long) / Double(others.count)) * 60)
                        }
                    }
                    for recentLong: Double? in [nil, long] {
                        let input = PlanInput(raceDistanceMeters: distance, raceDate: P.date(week: 4 + 16, day: 6, hour: 8),
                                              startDate: P.date(week: 4, day: 0, hour: 0), trainingDays: days,
                                              longRunDay: longDay, recentWeeklySeconds: weekly * 60,
                                              recentLongRunSeconds: recentLong.map { $0 * 60 }, heartRateZones: HRZones(lthr: 165),
                                              easyPace: EasyPaceSample(secondsPerKm: 340, heartRate: 125),
                                              fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: 23 * 60))
                        let label = "history: \(Int(distance)) m, \(days.count) days, \(Int(weekly)) min, long \(recentLong.map { "\(Int($0))" } ?? "none")"
                        if compareWithRuleOff(input, history: history, label) != nil { built += 1 }
                    }
                }
            }
        }
        XCTAssertGreaterThan(built, 250)
    }

    func testALowVolumeRecoveryWeekKeepsItsSize() throws {
        // 90 minutes over four days. The spike limit in the recovery week is
        // far above every session, so it must not change how the week is
        // drafted: the recovery week stays within 5% of the rule-off one and
        // has no run under the floor.
        for distance in [Distance.fiveK, Distance.tenK, Distance.halfMarathon] {
            let input = PlanInput(raceDistanceMeters: distance, raceDate: P.date(week: 16, day: 6, hour: 8),
                                  startDate: P.date(week: 0, day: 0, hour: 0), trainingDays: [.monday, .wednesday, .friday, .sunday],
                                  longRunDay: .sunday, recentWeeklySeconds: 90 * 60, heartRateZones: HRZones(lthr: 165),
                                  easyPace: EasyPaceSample(secondsPerKm: 340, heartRate: 125),
                                  fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: 23 * 60))
            let (plan, base) = try XCTUnwrap(compareWithRuleOff(input, history: [], "\(Int(distance)) m at 90 min"))
            let recovery = try XCTUnwrap(plan.weeks.first { $0.isRecoveryWeek && $0.index > 0 })
            let minutes = recovery.workouts.map { Int($0.durationSeconds / 60) }
            let baseMinutes = base.weeks[recovery.index].workouts.map { Int($0.durationSeconds / 60) }
            XCTAssertGreaterThanOrEqual(minutes.reduce(0, +), baseMinutes.reduce(0, +) * 95 / 100, "\(minutes) vs \(baseMinutes)")
            XCTAssertTrue(recovery.workouts.allSatisfy { $0.durationSeconds >= PlanHeuristics.minimumEasyRunSeconds }, "\(minutes)")
        }
    }

    // MARK: Adaptation (F4): repair cuts a spiking run, never a completed one

    func testAMissedLongRunDoesNotLetTheNextOneSpike() throws {
        // Long runs 60, 65, 70: each within 10% of the one before. The
        // runner misses the 65; the 70 would then be 17% over the 60 run.
        var d = A.Driver(plan: A.weeks(0..<3, longMinutes: { [60, 65, 70][$0] }), context: A.context())
        d.follow(until: A.date(week: 2, day: 4, hour: 23)) { $0.id == "l1" ? nil : A.RunSpec() }
        d.day(A.date(week: 2, day: 5, hour: 5))
        XCTAssertFalse(d.history.contains { $0.id.contains("l1") }, "the long run was missed")
        let l2 = try XCTUnwrap(d.plan.first { $0.id == "l2" })
        let cal = PlanCalendar.calendar(timeZone: A.tz)
        let from = cal.date(byAdding: .day, value: -30, to: cal.startOfDay(for: l2.date))!
        let longest = try XCTUnwrap((d.history + d.plan).filter { $0.date >= from && $0.date < l2.date && $0.kind != .race }
            .map(\.durationSeconds).max())
        XCTAssertLessThanOrEqual(l2.durationSeconds, longest * 1.1 + 1e-6)
        XCTAssertLessThan(l2.durationSeconds, 70 * 60)
        let cut = try XCTUnwrap(d.changes.first { $0.kind == .sessionShortened && $0.workoutIDs.contains("l2") })
        XCTAssertEqual(cut.triggers.first?.metric, .singleRunSpike)
        XCTAssertTrue(cut.rule.contains("3.5 rule 1"), cut.rule)
        assertAdaptationSound(d.outcomes)
    }

    func testRepairRespectsTheFloorAndNeverCutsQualityRacesOrHistory() throws {
        let history = [run("done", week: 0, day: 0, minutes: 10)]
        let plan = [run("easy", week: 0, day: 1, minutes: 30), run("q", week: 0, day: 3, .quality(.threshold), minutes: 54),
                    run("race", week: 0, day: 6, .race, minutes: 90)]
        let o = AdaptationEngine.processDay(asOf: A.date(week: 0, day: 1, hour: 5), state: AdaptationState(), plan: plan,
                                            history: history, context: A.context())
        XCTAssertEqual(o.history, history, "completed runs are never touched")
        XCTAssertEqual(o.plan.first { $0.id == "easy" }?.durationSeconds, PlanHeuristics.minimumEasyRunSeconds,
                       "cut to the floor, not below")
        XCTAssertEqual(o.plan.first { $0.id == "q" }?.durationSeconds, 54 * 60, "quality sessions are not cut")
        XCTAssertEqual(o.plan.first { $0.id == "race" }?.durationSeconds, 90 * 60, "races are never cut")
        // The floor and the quality session leave spikes in the report; the race is a flag.
        XCTAssertEqual(Set(spikes(o.guardrailReport).compactMap(\.workoutID)), ["easy", "q"])
        XCTAssertEqual(o.guardrailReport.informationFlags.map(\.workoutID), ["race"])
    }
}
