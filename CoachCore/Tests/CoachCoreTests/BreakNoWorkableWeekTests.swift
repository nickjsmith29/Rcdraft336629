import XCTest
@testable import CoachCore

// #79: a plan built a few weeks after a 3 to 4 week break (3.5 rule 4). Synthetic runners only.
// Weeks are Monday-start, week 0 being the week of BaselineFixture.date(day: 0).

final class BreakNoWorkableWeekTests: XCTestCase {
    private let tz = BaselineFixture.timeZone

    struct Shape {
        let days: [PlanWeekday: Double]       // a normal week, minutes by day
        let backDays: [PlanWeekday: Double]   // an easy week back, minutes by day
        let trainingDays: Set<PlanWeekday>
    }

    static let three = Shape(days: [.tuesday: 60, .thursday: 60, .saturday: 100],
                             backDays: [.tuesday: 50, .thursday: 50, .saturday: 80],
                             trainingDays: [.tuesday, .thursday, .saturday])
    static let five = Shape(days: [.monday: 40, .tuesday: 50, .thursday: 50, .friday: 40, .saturday: 100],
                            backDays: [.monday: 30, .tuesday: 35, .thursday: 35, .friday: 30, .saturday: 60],
                            trainingDays: [.monday, .tuesday, .thursday, .friday, .saturday])

    /// `normal` weeks, `breakWeeks` with no runs, `back` easy weeks, then `asOf` on the Wednesday of the next week.
    private func baseline(_ s: Shape, normal: Int = 8, breakWeeks: Int, back: Int) -> BaselineReport {
        var acts: [Activity] = []
        func add(_ w: Int, _ days: [PlanWeekday: Double], _ tag: String) {
            for (d, m) in days.sorted(by: { $0.key < $1.key }) {
                acts.append(GoalFixture.run("\(tag)\(w)-\(d.rawValue)", week: w, day: d, minutes: m))
            }
        }
        for w in 0..<normal { add(w, s.days, "n") }
        for w in 0..<back { add(normal + breakWeeks + w, s.backDays, "b") }
        let total = normal + breakWeeks + back
        return BaselineBuilder.build(activities: acts, efforts: [],
                                     options: BaselineOptions(asOf: BaselineFixture.date(day: total * 7 + 2, hour: 12), timeZone: tz))
    }

    private func settings(_ s: Shape, distance: Double, asOf: Date) -> GoalSettings {
        let race = asOf.addingTimeInterval((14 * 7 + 4) * 86_400 + 3600)
        return GoalSettings(race: GoalRace(name: "Synthetic", date: race, distanceMeters: distance, time: .bestPossible),
                            schedule: TrainingSchedule(trainingDays: s.trainingDays, longRunDay: .saturday, maxSession: .noLimit),
                            hasTreadmillAccess: false, painHistory: PainHistory.none)
    }

    private func build(_ s: Shape, distance: Double, breakWeeks: Int, back: Int) -> (PlanBuildResult, [PlannedWorkout]) {
        let report = baseline(s, breakWeeks: breakWeeks, back: back)
        var input = BaselinePlanMapping.planInput(settings: settings(s, distance: distance, asOf: report.asOf),
                                                  baseline: report, startDate: report.asOf)
        // The synthetic runs carry no marked races, so there is no LTHR; zones are a plain input here.
        input.heartRateZones = HRZones(lthr: 165)
        let history = BaselinePlanMapping.planHistory(from: report)
        return (PlanBuilder.build(input, history: history, timeZone: tz), history)
    }

    private func minutes(_ w: TrainingPlanWeek) -> Double { w.workouts.reduce(0) { $0 + $1.durationSeconds } / 60 }

    /// Builds the plan and checks it: it builds, it passes the guardrail checker (3.5), and its first weeks
    /// are bounded by the return's steps (3.5 rule 4, SPEC 0.8, owner's decision #32), worked out by hand:
    ///
    /// - The pre-break level L is the mean of the 4 weeks before the break: 220 minutes for the 3 day shape
    ///   (60 + 60 + 100) and 280 for the 5 day one (40 + 50 + 50 + 40 + 100). The steps are 65%, 82.5% and 100% of L:
    ///   143, 181.5 and 220 for 3 days, 182, 231 and 280 for 5 days.
    /// - The weeks back are run at 180 (3 days) and 190 minutes (5 days), 82% and 68% of L, and the start week,
    ///   a Wednesday, has no run yet. That is a return week run under 1/1.2 of its step's ceiling, so it is short:
    ///   the steps restart, and the plan's week 0 is step 1 (65% of L; the open week's own volume, 0, is under
    ///   that, so the ceiling is the step's). Week 1 is step 2 (82.5%) and week 2 step 3 (100%); planned weeks
    ///   are never short, so the return ends with week 2 and week 3 is held by the plain 10% check over the
    ///   week before it (or, past a recovery week, the one before that).
    /// - This replaces the first version of this test, which bounded week 0 at 10% over the last full week back:
    ///   that was the plain rule, which gave no workable week (#79).
    private func assertBuilds(_ name: String, _ s: Shape, _ distance: Double, breakWeeks: Int, back: Int,
                              file: StaticString = #filePath, line: UInt = #line) {
        let label = "\(name), \(Int(distance)) m, \(breakWeeks) break weeks, \(back) weeks back"
        let (r, h) = build(s, distance: distance, breakWeeks: breakWeeks, back: back)
        guard let plan = r.plan else { return XCTFail("\(label): \(r.issues)", file: file, line: line) }
        let report = GuardrailChecker.check(history: h, planned: plan.workouts, timeZone: tz)
        XCTAssertTrue(report.passed, "\(label): \(report.violations.map(\.explanation))", file: file, line: line)
        let level = s.days.values.reduce(0, +)
        let weeks = plan.weeks.map { minutes($0) }
        XCTAssertGreaterThan(weeks[0], 0, label, file: file, line: line)
        for (k, share) in [0.65, 0.825, 1.0].enumerated() {
            XCTAssertLessThanOrEqual(weeks[k], share * level + 1e-6,
                                     "\(label): week \(k) is \(weeks[k]) min, over step \(k + 1)'s \(share * level)", file: file, line: line)
        }
        XCTAssertLessThanOrEqual(weeks[3], 1.1 * max(weeks[1], weeks[2]) + 1e-6,
                                 "\(label): week 3 is \(weeks[3]) min after \(weeks[1]) and \(weeks[2])", file: file, line: line)
    }

    private let shapes: [(String, Shape)] = [("3 days", three), ("5 days", five)]
    private let distances = [Distance.tenK, Distance.halfMarathon]

    // MARK: The bug (#79): a 3 or 4 week break that ended 2 to 5 weeks before the start

    func testAThreeOrFourWeekBreakThatEndedTwoToFiveWeeksBeforeTheStartBuilds() {
        for (name, s) in shapes {
            for distance in distances {
                for brk in [3, 4] {
                    for back in [2, 3, 4] { assertBuilds(name, s, distance, breakWeeks: brk, back: back) }
                }
            }
        }
    }

    // MARK: Cases that already build and must keep building

    func testABreakThatEndedSixOrMoreWeeksBeforeTheStartBuilds() {
        for (name, s) in shapes {
            for distance in distances {
                for brk in [3, 4] {
                    for back in [5, 6] { assertBuilds(name, s, distance, breakWeeks: brk, back: back) }
                }
            }
        }
    }

    func testATwoWeekBreakBuildsWhateverTheWeeksBack() {
        for (name, s) in shapes {
            for distance in distances {
                for back in [2, 3, 4, 5, 6] { assertBuilds(name, s, distance, breakWeeks: 2, back: back) }
            }
        }
    }

    // MARK: No break: unchanged

    /// Twelve steady weeks (3 days: 60, 60 and 100 minutes, 220 a week), a plan for a 10K starting the next
    /// Monday. The first week's bound is worked out by hand: the open start week holds no run yet, so it may
    /// end as a recovery week; the plan's first week is then measured against the last full week, 220 minutes,
    /// plus 10%, 242 minutes at most. The weekly totals pinned below are the builder's output on main at
    /// 02e8f72 (a characterization: any change to a no-break plan shows up here).
    func testABaselineWithNoBreakBuildsAsBefore() throws {
        for (s, expected) in [(Self.three, Self.noBreakThree), (Self.five, Self.noBreakFive)] {
            let report = baseline(s, normal: 12, breakWeeks: 0, back: 0)
            var input = BaselinePlanMapping.planInput(settings: settings(s, distance: Distance.tenK, asOf: report.asOf),
                                                      baseline: report, startDate: report.asOf)
            input.heartRateZones = HRZones(lthr: 165)
            let history = BaselinePlanMapping.planHistory(from: report)
            let plan = try XCTUnwrap(PlanBuilder.build(input, history: history, timeZone: tz).plan)
            let week = s.days.values.reduce(0, +)
            XCTAssertLessThanOrEqual(minutes(plan.weeks[0]), 1.1 * week + 1e-6)
            XCTAssertEqual(plan.weeks.map { (minutes($0) * 10).rounded() / 10 }, expected)
            XCTAssertTrue(GuardrailChecker.check(history: history, planned: plan.workouts, timeZone: tz).passed)
        }
    }

    static let noBreakThree: [Double] = [135, 144, 153, 117, 162, 171, 177, 138, 189, 201, 156, 216, 153, 142.1]
    static let noBreakFive: [Double] = [176, 191, 207, 155, 225, 226, 228, 170, 247, 267, 210, 286, 214, 167.1]

    /// A one week break (7 days off, a short break by both measures) is not a longer break, so it keeps rule 4's
    /// short-break ramp and builds exactly as on main at 02e8f72 (pinned from main's output, a characterization).
    /// By hand: the level is 220 minutes (3 day shape) or 280 (5 day shape) and the three weeks back are the
    /// shape's easy week (180 and 220 minutes). The ramp caps return weeks 1 to 3 at 70, 90 and 100% of the level
    /// (154, 198, 220 and 196, 252, 280); the first planned weeks, 90, 96, 102 and 98, 105, 114 minutes, sit under
    /// them, as the plans sized from the recent weeks do.
    func testAOneWeekBreakBuildsAsBefore() throws {
        let pinned: [(Shape, [Double])] = [
            (Self.three, [90, 96, 102, 76, 108, 114, 117, 92, 126, 135, 105, 144, 99, 112.1]),
            (Self.five, [98, 105, 114, 85, 123, 122, 127, 95, 137, 149, 111, 158, 125, 120.1])]
        for (s, expected) in pinned {
            let (result, history) = build(s, distance: Distance.tenK, breakWeeks: 1, back: 3)
            let plan = try XCTUnwrap(result.plan)
            XCTAssertEqual(plan.weeks.map { (minutes($0) * 10).rounded() / 10 }, expected)
            let level = s.days.values.reduce(0, +)
            for (k, cap) in zip(0..<3, [0.7, 0.9, 1.0]) { XCTAssertLessThanOrEqual(minutes(plan.weeks[k]), cap * level + 1e-6) }
            XCTAssertTrue(GuardrailChecker.check(history: history, planned: plan.workouts, timeZone: tz).passed)
        }
    }
}
