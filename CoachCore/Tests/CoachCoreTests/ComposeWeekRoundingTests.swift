import XCTest
@testable import CoachCore

// F3, SPEC 3.1 (hard share) and 3.5 (recovery weeks), #87: whole-minute reps
// must not shrink a small week to about hard / 0.165, with the spike rule on
// or off. Synthetic inputs only: every volume and heart rate below is made up.
final class ComposeWeekRoundingTests: XCTestCase {
    typealias P = PlanFixture
    private let utc = PlanFixture.utc
    private let ruleOff = GuardrailLimits(maxSingleRunIncrease: .infinity)

    private func input(_ distance: Double, days: Set<PlanWeekday>, weekly: Double, start: Int = 0, raceIn weeks: Int = 16,
                       recentLong: Double? = nil, maxSession: Double? = nil) -> PlanInput {
        PlanInput(raceDistanceMeters: distance, raceDate: P.date(week: start + weeks, day: 6, hour: 8),
                  startDate: P.date(week: start, day: 0, hour: 0), trainingDays: days, longRunDay: days.max()!,
                  maxSessionSeconds: maxSession.map { $0 * 60 }, recentWeeklySeconds: weekly * 60,
                  recentLongRunSeconds: recentLong.map { $0 * 60 }, heartRateZones: HRZones(lthr: 165),
                  easyPace: EasyPaceSample(secondsPerKm: 340, heartRate: 125),
                  fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: 23 * 60))
    }

    /// Four weeks at `weekly` minutes: 30% in the long run, the rest spread evenly.
    private func history(days: Set<PlanWeekday>, weekly: Double) -> [PlannedWorkout] {
        let longDay = days.max()!
        let others = Double(days.count - 1)
        return (0..<4).flatMap { w in
            days.map { d in
                PlannedWorkout(id: "h\(w)-\(d.rawValue)", date: P.date(week: w, day: d.rawValue, hour: 7),
                               kind: d == longDay ? .long : .easy,
                               durationSeconds: (d == longDay ? 0.3 * weekly : 0.7 * weekly / others) * 60)
            }
        }
    }

    private func minutes(_ w: TrainingPlanWeek) -> Double { w.workouts.reduce(0) { $0 + $1.durationSeconds } / 60 }

    private func hardShare(_ w: TrainingPlanWeek) -> Double {
        let hard = w.workouts.flatMap { $0.prescription?.segments ?? [] }.filter { !$0.intensity.isBelowAerobicThreshold }
            .reduce(0) { $0 + $1.durationSeconds }
        return hard / (minutes(w) * 60)
    }

    /// Recovery weeks before the taper, with the week before each.
    private func recoveryWeeks(_ plan: TrainingPlan) -> [(week: TrainingPlanWeek, before: TrainingPlanWeek)] {
        let taper = PlanHeuristics.taperWeeks(plan.category)
        let last = plan.weeks.count - taper
        guard last > 1 else { return [] }
        return (1..<last).compactMap { i in plan.weeks[i].isRecoveryWeek ? (plan.weeks[i], plan.weeks[i - 1]) : nil }
    }

    func testASmallRecoveryWeekIsNotShrunkByRounding() throws {
        // 5K, Monday, Wednesday and Friday, 120 minutes, nothing recorded.
        // Week 2 is 138 minutes, so the recovery week after it is about 103.
        // Its fartlek main set (17.5 minutes) rounds to four 2-minute surges,
        // 14 minutes of hard running, 13.6% of the week; the week used to be
        // shortened to 14 / 0.165, 84 minutes, a fifth under its size.
        for limits in [GuardrailLimits.default, ruleOff] {
            let plan = try XCTUnwrap(PlanBuilder.build(input(Distance.fiveK, days: [.monday, .wednesday, .friday], weekly: 120),
                                                       timeZone: utc, limits: limits).plan)
            XCTAssertTrue(plan.guardrailReport.passed)
            let week = plan.weeks[3], before = plan.weeks[2]
            XCTAssertTrue(week.isRecoveryWeek)
            XCTAssertGreaterThanOrEqual(minutes(week), 0.95 * PlanHeuristics.recoveryWeekRatio * minutes(before),
                                        "\(minutes(week)) after \(minutes(before))")
            XCTAssertTrue(PlanHeuristics.hardShareBand.contains(hardShare(week)), "\(hardShare(week))")
        }
    }

    func testARuleOffRecoveryWeekGetsTheRetryToo() throws {
        // 5K, Tuesday, Thursday and Sunday, 90 minutes after four weeks at 90:
        // week 0 must be a recovery week. At 75% its easy run fell under the
        // floor (16, 25 and 19 minutes, with the week shrunk by rounding); the
        // recovery limit's room (with margin) now applies whether or not the
        // spike rule binds, so neither plan has a run under the floor.
        let days: Set<PlanWeekday> = [.tuesday, .thursday, .sunday]
        let history = history(days: days, weekly: 90)
        let i = input(Distance.fiveK, days: days, weekly: 90, start: 4, raceIn: 10, recentLong: 27)
        for limits in [GuardrailLimits.default, ruleOff] {
            let plan = try XCTUnwrap(PlanBuilder.build(i, history: history, timeZone: utc, limits: limits).plan)
            XCTAssertTrue(plan.guardrailReport.passed)
            let week = plan.weeks[0]
            XCTAssertTrue(week.isRecoveryWeek)
            XCTAssertGreaterThanOrEqual(minutes(week), 0.95 * PlanHeuristics.recoveryWeekRatio * 90, "\(minutes(week))")
            for w in week.workouts {
                XCTAssertGreaterThanOrEqual(w.durationSeconds, PlanHeuristics.minimumEasyRunSeconds, w.id)
            }
        }
    }

    func testSmallPlansKeepTheirRecoveryWeeksWithTheRuleOnOrOff() {
        // Every distance, three to six days, 90 to 180 minutes, with and
        // without history and a 90-minute session cap: the rule never changes
        // whether a plan builds, both plans pass the checker, and with the
        // rule off no recovery week before the taper is shrunk under 95% of
        // 75% of the week before it (on main, many were cut to hard / 0.165).
        let daySets: [Set<PlanWeekday>] = [
            [.tuesday, .thursday, .sunday], [.monday, .wednesday, .friday], [.monday, .wednesday, .friday, .sunday],
            [.tuesday, .wednesday, .thursday, .saturday, .sunday], [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday],
        ]
        var built = 0
        for distance in [Distance.fiveK, Distance.tenK, Distance.halfMarathon, Distance.marathon] {
            for days in daySets {
                for weekly in [90.0, 110, 120, 150, 180] {
                    for withHistory in [false, true] {
                        for maxSession: Double? in [nil, 90] {
                            let i = input(distance, days: days, weekly: weekly, start: withHistory ? 4 : 0, maxSession: maxSession)
                            let h = withHistory ? history(days: days, weekly: weekly) : []
                            let label = "\(Int(distance)) m, \(days.count) days, \(Int(weekly)) min, history \(withHistory), cap \(maxSession.map { "\(Int($0))" } ?? "none")"
                            let on = PlanBuilder.build(i, history: h, timeZone: utc)
                            let off = PlanBuilder.build(i, history: h, timeZone: utc, limits: ruleOff)
                            XCTAssertEqual(on.plan != nil, off.plan != nil, "\(label): \(on.issues) vs \(off.issues)")
                            for plan in [on.plan, off.plan].compactMap({ $0 }) {
                                built += 1
                                XCTAssertTrue(plan.guardrailReport.passed, label)
                            }
                            // With the rule on, a week it binds may be smaller
                            // (SingleRunSpikeTests.compareWithRuleOff checks those).
                            for (week, before) in off.plan.map(recoveryWeeks) ?? [] {
                                XCTAssertGreaterThanOrEqual(minutes(week), 0.95 * PlanHeuristics.recoveryWeekRatio * minutes(before),
                                                            "\(label) week \(week.index): \(minutes(week)) after \(minutes(before))")
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(built, 600)
    }
}
