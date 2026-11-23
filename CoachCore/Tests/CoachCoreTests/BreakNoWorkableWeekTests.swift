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

    /// The last full week of the baseline before `asOf`, in minutes.
    private func lastFullWeekMinutes(_ h: [PlannedWorkout], before asOf: Date) -> Double {
        let monday = PlanCalendar.weekStart(containing: asOf, timeZone: tz)
        let previous = PlanCalendar.weekStart(weeks: -1, after: monday, timeZone: tz)
        return h.filter { $0.date >= previous && $0.date < monday }.reduce(0) { $0 + $1.durationSeconds } / 60
    }

    /// Builds the plan and checks it: it builds, it passes the guardrail checker (3.5), and (SPEC 3.5 rule 4,
    /// "longer than 14 days: normal progression") its first full week is sized from the weeks run since the
    /// break: at most 10% over the last full week back (rule 2, heuristic).
    private func assertBuilds(_ name: String, _ s: Shape, _ distance: Double, breakWeeks: Int, back: Int,
                              file: StaticString = #filePath, line: UInt = #line) {
        let label = "\(name), \(Int(distance)) m, \(breakWeeks) break weeks, \(back) weeks back"
        let (r, h) = build(s, distance: distance, breakWeeks: breakWeeks, back: back)
        guard let plan = r.plan else { return XCTFail("\(label): \(r.issues)", file: file, line: line) }
        let report = GuardrailChecker.check(history: h, planned: plan.workouts, timeZone: tz)
        XCTAssertTrue(report.passed, "\(label): \(report.violations.map(\.explanation))", file: file, line: line)
        let last = lastFullWeekMinutes(h, before: baseline(s, breakWeeks: breakWeeks, back: back).asOf)
        let first = minutes(plan.weeks[0])
        XCTAssertGreaterThan(first, 0, label, file: file, line: line)
        XCTAssertLessThanOrEqual(first, 1.1 * last + 1e-6, "\(label): week 1 \(first) min after a week of \(last)", file: file, line: line)
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
}
