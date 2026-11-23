import XCTest
@testable import CoachCore

// #23, SPEC F3 "Easy runs and the long run": no easy run is longer than the
// week's long run, nothing goes past the long-run cap (3.5 rule 5) or the
// max session length (F2), the race is exempt and is not the long run, and
// a week that doesn't fit is planned smaller, within 3.1's band, with a note.
// Synthetic runners only.
final class EasyRunLimitTests: XCTestCase {
    private let utc = PlanFixture.utc
    private typealias F = PlanFixture

    private var planMonday: Date { F.date(week: 8, day: 0, hour: 0) }

    private func raceDate(weeks: Int) -> Date {
        planMonday.addingTimeInterval(Double((weeks - 1) * 7 + 6) * 86_400 + 8 * 3600)
    }

    private static let dayPool: [PlanWeekday] = [.tuesday, .thursday, .saturday, .sunday]

    private func input(distance: Double, days: [PlanWeekday], weekly: Double, weeks: Int = 12,
                       maxSession: Double? = nil, recentLong: Double? = nil) -> PlanInput {
        PlanInput(raceDistanceMeters: distance, raceDate: raceDate(weeks: weeks), startDate: planMonday,
                  trainingDays: Set(days), longRunDay: days.last!, maxSessionSeconds: maxSession.map { $0 * 60 },
                  recentWeeklySeconds: weekly * 60, recentLongRunSeconds: recentLong.map { $0 * 60 },
                  heartRateZones: HRZones(lthr: 168), easyPace: EasyPaceSample(secondsPerKm: 360, heartRate: 140),
                  fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: 25 * 60))
    }

    private func build(_ i: PlanInput, history: [PlannedWorkout] = []) -> PlanBuildResult {
        PlanBuilder.build(i, history: history, timeZone: utc)
    }

    private func minutes(_ w: PlannedWorkout) -> Double { w.durationSeconds / 60 }

    /// The run cap the builder applies: the long-run cap or the max session length.
    private func runCap(_ i: PlanInput) -> Double {
        let cap = PlanHeuristics.longRunCap(RaceCategory(meters: i.raceDistanceMeters)!,
                                            isMarathonDistance: RaceCategory.isMarathonDistance(meters: i.raceDistanceMeters))
        return min(cap, i.maxSessionSeconds ?? .infinity)
    }

    /// Asserts F3's limits on every week of a plan; returns the failures.
    private func problems(_ plan: TrainingPlan, _ i: PlanInput, history: [PlannedWorkout] = []) -> [String] {
        var out: [String] = []
        let cap = runCap(i)
        for w in plan.weeks {
            let training = w.workouts.filter { $0.kind != .race }
            let long = training.filter { $0.kind == .long }.map(\.durationSeconds).max()
            for x in training {
                if x.durationSeconds > cap + 1 { out.append("w\(w.index) \(x.id) \(minutes(x)) min over the cap \(cap / 60)") }
                if x.kind == .easy, x.durationSeconds > (long ?? cap) + 1 {
                    out.append("w\(w.index) \(x.id) easy \(minutes(x)) min over long \((long ?? cap) / 60)")
                }
            }
            if !w.isRaceWeek, let s = w.easyShare, !(0.75...0.85).contains(s), w.workouts.contains(where: { $0.kind.isQuality || $0.kind == .long }) {
                // The all-easy return week is exempt (3.5 rule 4); a plan from scratch has none.
                out.append("w\(w.index) easy share \(s)")
            }
        }
        let limits = GuardrailLimits(maxTrainingRunSeconds: cap, easyRunsWithinLongRun: true)
        let report = GuardrailChecker.check(history: history, planned: plan.weeks.flatMap(\.workouts), timeZone: utc, limits: limits)
        if !report.passed { out.append("guardrails: \(report.violations.map(\.explanation))") }
        return out
    }

    // MARK: The issue's examples

    private func shape(_ w: TrainingPlanWeek) -> [String] {
        w.workouts.map { x in
            let tag = x.kind == .long ? "L" : x.kind == .easy ? "e" : x.kind == .race ? "R" : "q"
            return "\(tag)\(Int((x.durationSeconds / 60).rounded()))"
        }
    }

    /// Before (main): 330 min on Tue/Thu/Sat drafted e158 q67 L105; 400 min e228 q67 L105 (3 days), e114 q67 e114 L105 (4 days).
    func testTenKThreeDaysAt330KeepsItsVolumeWhereTheRulesAllow() throws {
        let i = input(distance: Distance.tenK, days: [.tuesday, .thursday, .saturday], weekly: 330)
        let plan = try XCTUnwrap(build(i).plan)
        XCTAssertEqual(problems(plan, i), [])
        let first = plan.weeks[0]
        // L near its 105-minute cap, the easy run and the quality day (its cool-down takes the
        // held-back time, the hard minutes unchanged) up to it: about 309 of 330.
        XCTAssertEqual(shape(first), ["q103", "e103", "L103"])
        XCTAssertEqual(first.trainingSeconds / 60, 309, accuracy: 3)
        let note = try XCTUnwrap(first.workouts.compactMap { $0.prescription?.purpose }.first { $0.contains("of 330 minutes") })
        XCTAssertTrue(note.contains("This week is 309 of 330 minutes so that no easy run is longer than the long run"), note)
        XCTAssertTrue(plan.notes.contains { $0.contains(PlanBuilder.easyRunLimitMarker) }, "\(plan.notes)")
        let share = try XCTUnwrap(first.easyShare)
        XCTAssertTrue((0.75...0.85).contains(share), "\(share)")
        // The long run does not collapse: every build week holds it near its cap.
        for w in plan.weeks where !w.isRaceWeek && !w.isRecoveryWeek {
            let long = try XCTUnwrap(w.workouts.first { $0.kind == .long }, "week \(w.index)")
            XCTAssertGreaterThanOrEqual(long.durationSeconds, 95 * 60, "week \(w.index)")
        }
    }

    func testTenKAt400OnThreeAndFourDays() throws {
        let three = input(distance: Distance.tenK, days: [.tuesday, .thursday, .saturday], weekly: 400)
        let p3 = try XCTUnwrap(build(three).plan)
        XCTAssertEqual(problems(p3, three), [])
        XCTAssertEqual(shape(p3.weeks[0]), ["q103", "e103", "L103"])
        XCTAssertEqual(p3.weeks[0].trainingSeconds / 60, 309, accuracy: 3)
        // Four days hold the whole 400: two easy runs at the cap beside the long run.
        let four = input(distance: Distance.tenK, days: [.tuesday, .thursday, .friday, .sunday], weekly: 400)
        let p4 = try XCTUnwrap(build(four).plan)
        XCTAssertEqual(problems(p4, four), [])
        XCTAssertEqual(shape(p4.weeks[0]), ["e105", "q85", "e105", "L105"])
        XCTAssertEqual(p4.weeks[0].trainingSeconds / 60, 400, accuracy: 3)
        XCTAssertFalse(p4.workouts.prefix(4).contains { $0.prescription?.purpose.contains("of 400 minutes") ?? false })
        for p in [p3, p4] {
            let all = p.weeks.flatMap { $0.workouts }.filter { $0.kind != .race }
            XCTAssertLessThanOrEqual(all.map { $0.durationSeconds }.max() ?? 0, 105 * 60 + 1)
        }
    }

    // MARK: Sweep

    private func sweepDays(_ n: Int) -> [PlanWeekday] {
        n == 5 ? [.monday, .tuesday, .thursday, .saturday, .sunday] : Array(Self.dayPool.suffix(n))
    }

    func testSweepOfHighVolumeLowDayPlans() throws {
        let distances = [Distance.fiveK, Distance.tenK, Distance.halfMarathon, Distance.marathon]
        var checked = 0
        var refused: [String] = []
        for distance in distances {
            for n in [3, 4, 5] {
                for weekly in [240.0, 300, 330, 400, 450, 520] {
                    for recentLong in [nil, 70.0] as [Double?] {
                        for maxSession in [nil, 120.0] as [Double?] {
                            let i = input(distance: distance, days: sweepDays(n), weekly: weekly, weeks: 10,
                                          maxSession: maxSession, recentLong: recentLong)
                            let label = "\(distance) m, \(n) days, \(weekly) min, long \(recentLong ?? 0), max \(maxSession ?? 0)"
                            let built = build(i)
                            guard let plan = built.plan else { refused.append("\(label) \(built.issues)"); continue }
                            checked += 1
                            XCTAssertEqual(problems(plan, i), [], label)
                        }
                    }
                }
            }
        }
        XCTAssertEqual(refused, [])
        XCTAssertEqual(checked, 288)
    }

    func testPlansBuiltOnHistoryHoldTheLimits() throws {
        // Four weeks of 330 min over three days before the plan (fixture weeks 4 to 7).
        let days: [PlanWeekday] = [.tuesday, .thursday, .saturday]
        let history = (4..<8).flatMap { w in
            [F.workout("h\(w)a", week: w, day: 1, .easy, minutes: 110), F.workout("h\(w)b", week: w, day: 3, .easy, minutes: 110),
             F.workout("h\(w)c", week: w, day: 5, .long, minutes: 110)]
        }
        for distance in [Distance.tenK, Distance.halfMarathon] {
            let i = input(distance: distance, days: days, weekly: 330, recentLong: 100)
            let plan = try XCTUnwrap(build(i, history: history).plan, "\(distance)")
            XCTAssertEqual(problems(plan, i, history: history), [], "\(distance)")
        }
    }

    func testTwoRunningDaysAreRefusedNotPiledUp() {
        let i = input(distance: Distance.tenK, days: [.thursday, .sunday], weekly: 400)
        XCTAssertEqual(build(i).issues, [.tooFewTrainingDays(available: 2, minimum: 3)])
    }

    // MARK: Race week and edge cases

    func testRaceIsExemptAndNotTheLongRun() {
        let race = F.workout("race", week: 1, day: 6, .race, minutes: 200)
        let easy = F.workout("e", week: 1, day: 1, .easy, minutes: 60)
        let limits = GuardrailLimits(maxTrainingRunSeconds: 105 * 60, easyRunsWithinLongRun: true)
        let r = GuardrailChecker.check(history: [], planned: [easy, race], timeZone: utc, limits: limits)
        XCTAssertTrue(r.violations.filter { $0.rule == .easyRunLength }.isEmpty, "\(r.violations)")
    }

    private let strict = GuardrailLimits(easyRunsWithinLongRun: true)

    func testEasyRunLimitIsOffByDefaultInTheChecker() {
        let long = F.workout("l", week: 1, day: 5, .long, minutes: 90)
        let easy = F.workout("e", week: 1, day: 1, .easy, minutes: 100)
        let r = GuardrailChecker.check(history: [], planned: [easy, long], timeZone: utc)
        XCTAssertTrue(r.violations.filter { $0.rule == .easyRunLength }.isEmpty)
    }

    func testCheckerFlagsEasyRunLongerThanLongRunAndOverCap() {
        let long = F.workout("l", week: 1, day: 5, .long, minutes: 90)
        let easy = F.workout("e", week: 1, day: 1, .easy, minutes: 100)
        var r = GuardrailChecker.check(history: [], planned: [easy, long], timeZone: utc, limits: strict)
        var v = r.violations.filter { $0.rule == .easyRunLength }
        XCTAssertEqual(v.count, 1)
        XCTAssertEqual(v.first?.workoutID, "e")
        XCTAssertEqual(v.first?.allowed, 90 * 60)
        XCTAssertTrue(v.first?.explanation.contains("longest run of the week") ?? false)
        // Equal passes; a cap catches any run, long or easy.
        let equal = F.workout("e2", week: 1, day: 1, .easy, minutes: 90)
        r = GuardrailChecker.check(history: [], planned: [equal, long], timeZone: utc, limits: strict)
        XCTAssertTrue(r.violations.filter { $0.rule == .easyRunLength }.isEmpty)
        r = GuardrailChecker.check(history: [], planned: [equal, long], timeZone: utc,
                                   limits: GuardrailLimits(maxTrainingRunSeconds: 80 * 60, easyRunsWithinLongRun: true))
        v = r.violations.filter { $0.rule == .easyRunLength }
        XCTAssertEqual(Set(v.compactMap(\.workoutID)), ["e2", "l"])
    }

    func testCheckerReadsOnlyPlannedRunsAndIgnoresUnknownTimes() {
        let long = F.workout("l", week: 1, day: 5, .long, minutes: 60)
        let doneEasy = F.workout("h", week: 1, day: 0, .easy, minutes: 120)
        let r = GuardrailChecker.check(history: [doneEasy], planned: [long], timeZone: utc, limits: strict)
        XCTAssertTrue(r.violations.filter { $0.rule == .easyRunLength }.isEmpty)
        let nan = PlannedWorkout(id: "n", date: F.date(week: 1, day: 2), kind: .easy, durationSeconds: .nan)
        let r2 = GuardrailChecker.check(history: [], planned: [nan, long], timeZone: utc, limits: strict)
        XCTAssertTrue(r2.violations.filter { $0.rule == .easyRunLength }.isEmpty)
    }

    func testNonFiniteCapIsOffAndBadValuesFallBack() {
        XCTAssertEqual(GuardrailLimits().maxTrainingRunSeconds, .infinity)
        XCTAssertEqual(GuardrailLimits(maxTrainingRunSeconds: .nan).maxTrainingRunSeconds, .infinity)
        XCTAssertEqual(GuardrailLimits(maxTrainingRunSeconds: -5).maxTrainingRunSeconds, .infinity)
        XCTAssertEqual(GuardrailLimits(maxTrainingRunSeconds: 0).maxTrainingRunSeconds, .infinity, "0 falls back like a negative value")
        let long = F.workout("l", week: 1, day: 5, .long, minutes: 60)
        let r = GuardrailChecker.check(history: [], planned: [long], timeZone: utc, limits: GuardrailLimits(maxTrainingRunSeconds: 0))
        XCTAssertTrue(r.violations.filter { $0.rule == .easyRunLength }.isEmpty, "0 means the default, no cap")
    }

    func testMaxSessionBelowTheLongRunCapHoldsEveryRun() throws {
        let i = input(distance: Distance.halfMarathon, days: [.tuesday, .thursday, .saturday], weekly: 300, maxSession: 75)
        let plan = try XCTUnwrap(build(i).plan)
        XCTAssertEqual(problems(plan, i), [])
        let longest = plan.weeks.flatMap { $0.workouts }.filter { $0.kind != .race }.map { $0.durationSeconds }.max() ?? 0
        XCTAssertLessThanOrEqual(longest, 75 * 60 + 1)
    }

    func testRaceWeekTrainingRunsHoldTheCapButNotTheRace() throws {
        let i = input(distance: Distance.fiveK, days: [.tuesday, .thursday, .saturday, .sunday], weekly: 300, weeks: 8)
        let plan = try XCTUnwrap(build(i).plan)
        let raceWeek = try XCTUnwrap(plan.weeks.last)
        XCTAssertTrue(raceWeek.isRaceWeek)
        XCTAssertFalse(raceWeek.workouts.contains { $0.kind == .long })
        for w in raceWeek.workouts where w.kind != .race { XCTAssertLessThanOrEqual(w.durationSeconds, 90 * 60 + 1) }
        XCTAssertEqual(problems(plan, i), [])
    }

    func testRepairShortensAnEasyRunOverTheLongRun() {
        let history = (0..<4).map { F.workout("h\($0)", week: 0, day: $0 * 2, .easy, minutes: 60) }
        let long = F.workout("l", week: 1, day: 5, .long, minutes: 40)
        let e1 = F.workout("e1", week: 1, day: 1, .easy, minutes: 60)
        let e2 = F.workout("e2", week: 1, day: 3, .easy, minutes: 55)
        var ctx = AdaptFixture.context()
        ctx.guardrails.easyRunsWithinLongRun = true
        let asOf = F.date(week: 1, day: 0, hour: 6)
        let r = GuardrailRepair.repair(plan: [e1, e2, long], history: history, asOf: asOf, freezes: [], context: ctx)
        XCTAssertTrue(r.report.passed, "\(r.report.violations.map(\.explanation))")
        for id in ["e1", "e2"] { XCTAssertEqual(r.plan.first { $0.id == id }?.durationSeconds, 40 * 60, id) }
        XCTAssertEqual(r.plan.first { $0.id == "l" }?.durationSeconds, 40 * 60)
        XCTAssertTrue(r.changes.contains { $0.kind == .sessionShortened && $0.explanation.contains("longer than the week's long run") })
        // Off by default: the same plan is left alone.
        let off = GuardrailRepair.repair(plan: [e1, e2, long], history: history, asOf: asOf, freezes: [], context: AdaptFixture.context())
        XCTAssertEqual(off.plan.first { $0.id == "e1" }?.durationSeconds, 60 * 60)
        XCTAssertTrue(GuardrailRepair.fixable.contains(.easyRunLength))
    }
}
