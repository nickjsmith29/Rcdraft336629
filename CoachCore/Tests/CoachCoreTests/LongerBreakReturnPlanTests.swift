import XCTest
@testable import CoachCore

// F3's accept case for the return after a break (#32, #79; SPEC.md 0.8, 3.5
// rule 4): for synthetic runners with a break of 15, 21 or 28 days off that
// ended 1 to 6 weeks before the plan starts, with the weeks back run at 30% to
// 85% of the pre-break level, on 3 and 5 day weeks, the plan builds and every
// week passes every check of 3.5; every return week holds at most its step's
// ceiling. Synthetic runners only: every run here is made up.
//
// The days: weeks 0 to 7 are normal (the shape's days), the last run is the
// Saturday of week 7, the break starts the Sunday after, and the first run back
// is the first training day on or after `daysOff` days later. The weeks back
// repeat the shape at `share` of its minutes. The plan starts on the Wednesday
// of the week `weeksBack` weeks after the first week back, which has no run
// yet (the start week is open, as in `BreakNoWorkableWeekTests`).
final class LongerBreakReturnPlanTests: XCTestCase {
    private let tz = BaselineFixture.timeZone
    private typealias Shape = BreakNoWorkableWeekTests.Shape

    private struct Case: CustomStringConvertible {
        let shape: Shape
        let name: String
        let daysOff: Int
        let weeksBack: Int
        let share: Double
        var description: String { "\(name), \(daysOff) days off, \(weeksBack) weeks back at \(Int(share * 100))%" }
    }

    /// Weekly minutes of the generated history, one per week from 0, and the
    /// activities, for `c`. The last entry is the open start week (no runs).
    private func history(_ c: Case) -> (activities: [Activity], weekly: [Double], startWeek: Int, asOf: Date) {
        var acts: [Activity] = []
        func add(_ day: Int, minutes: Double, _ tag: String) {
            acts.append(GoalFixture.run("\(tag)\(day)", week: day / 7, day: PlanWeekday(rawValue: day % 7)!, minutes: minutes))
        }
        var weekly = [Double](repeating: 0, count: 8)
        for w in 0..<8 {
            for (d, m) in c.shape.days.sorted(by: { $0.key < $1.key }) {
                add(w * 7 + d.rawValue, minutes: m, "n")
                weekly[w] += m
            }
        }
        let lastRun = 7 * 7 + PlanWeekday.saturday.rawValue
        var resume = lastRun + c.daysOff + 1
        while !c.shape.trainingDays.contains(PlanWeekday(rawValue: resume % 7)!) { resume += 1 }
        let startWeek = resume / 7 + c.weeksBack
        while weekly.count <= startWeek { weekly.append(0) }
        for day in resume..<(startWeek * 7) {
            guard let m = c.shape.days[PlanWeekday(rawValue: day % 7)!] else { continue }
            add(day, minutes: m * c.share, "b")
            weekly[day / 7] += m * c.share
        }
        return (acts, weekly, startWeek, BaselineFixture.date(day: startWeek * 7 + 2, hour: 12))
    }

    /// Independent hand model of the steps for the weeks of `weekly` from the
    /// first break week (week 8) on, for a pre-break level `level`: the chain
    /// of step ceilings (3.5 rule 4) through the history. Returns the step of
    /// the next week (the first planned one) and whether the return is still
    /// on, with the ceiling of that week and the two after it; nil when the
    /// return has already ended in the history.
    private func expectedCeilings(_ weekly: [Double], level: Double) -> [Double]? {
        let steps = [0.65, 0.825, 1.0]
        var j = 8
        while j < weekly.count, weekly[j] <= 0.25 * level { j += 1 }     // the break weeks
        var step = 0, floorVolume = 0.0
        for k in j..<weekly.count {
            let ceiling = max(steps[step] * level, floorVolume)
            let short = weekly[k] < ceiling / 1.2 - 1e-9
            if step == 2 && !short { return nil }                        // the return has ended
            if short { step = 0; floorVolume = weekly[k] } else { step += 1; floorVolume = 0 }
        }
        // The planned weeks: never short, so each takes the next step.
        let first = max(steps[step] * level, floorVolume)
        let rest = (step + 1..<3).map { steps[$0] * level }
        return [first] + rest
    }

    private func settings(_ s: Shape, asOf: Date) -> GoalSettings {
        let race = asOf.addingTimeInterval((14 * 7 + 4) * 86_400 + 3600)
        return GoalSettings(race: GoalRace(name: "Synthetic", date: race, distanceMeters: Distance.tenK, time: .bestPossible),
                            schedule: TrainingSchedule(trainingDays: s.trainingDays, longRunDay: .saturday, maxSession: .noLimit),
                            hasTreadmillAccess: false, painHistory: PainHistory.none)
    }

    private func minutes(_ w: TrainingPlanWeek) -> Double { w.workouts.reduce(0) { $0 + $1.durationSeconds } / 60 }

    /// Builds and checks `c`; returns nil when it builds, else the kind of refusal.
    private func run(_ c: Case, file: StaticString = #filePath, line: UInt = #line) -> String? {
        let h = history(c)
        let report = BaselineBuilder.build(activities: h.activities, efforts: [],
                                           options: BaselineOptions(asOf: h.asOf, timeZone: tz))
        var input = BaselinePlanMapping.planInput(settings: settings(c.shape, asOf: h.asOf), baseline: report, startDate: report.asOf)
        input.heartRateZones = HRZones(lthr: 165)
        let planHistory = BaselinePlanMapping.planHistory(from: report)
        let result = PlanBuilder.build(input, history: planHistory, timeZone: tz)
        guard let plan = result.plan else {
            // Two refusals are allowed, neither a guardrail one. F3's own minimum
            // for the recent weekly volume has nothing to do with the break: a
            // runner 30% back for a few weeks runs under it.
            let lowVolume = result.issues.allSatisfy {
                if case .recentVolumeTooLow = $0 { return true }
                return false
            }
            if lowVolume {
                XCTAssertLessThan(input.recentWeeklySeconds ?? 0, 5400, "\(c): refused with enough recent volume", file: file, line: line)
                return "recentVolumeTooLow"
            }
            // SPEC GAP (reported on #32): a 15 day break with a single week back is
            // both a short break by weeks (2 break weeks) and a longer one by days.
            // Its week after the open start week is return week 3 of the ramp, which
            // rises at most 1/0.9 over the week before; the builder sizes against
            // every way the empty start week can end, down to the least that is not
            // a break week (a quarter of a level diluted by the break's zeros, 23
            // minutes), so week 0 can only be 1/0.9 of that, under the 30 minute
            // floor. The checker refuses nothing it is given; no real week is
            // refused. Short breaks of 2 weeks with 1 week back behave the same on
            // main. Every other case must build.
            let gap = c.daysOff == 15 && c.weeksBack == 1
            let onlyNoWorkable = result.issues.allSatisfy {
                if case .noWorkableWeek = $0 { return true }
                return false
            }
            XCTAssertTrue(gap && onlyNoWorkable, "\(c): \(result.issues)", file: file, line: line)
            return "noWorkableWeek"
        }
        let check = GuardrailChecker.check(history: planHistory, planned: plan.workouts, timeZone: tz)
        XCTAssertTrue(check.passed, "\(c): \(check.violations.map(\.explanation))", file: file, line: line)
        // Every return week holds at most its step's ceiling (the hand model's).
        let level = c.shape.days.values.reduce(0, +)
        if let ceilings = expectedCeilings(h.weekly, level: level) {
            for (k, ceiling) in ceilings.enumerated() {
                XCTAssertLessThanOrEqual(minutes(plan.weeks[k]), ceiling + 1e-6,
                                         "\(c): plan week \(k) is \(minutes(plan.weeks[k])) min, over its ceiling \(ceiling)",
                                         file: file, line: line)
            }
        }
        return nil
    }

    private let shapes: [(String, Shape)] = [("3 days", BreakNoWorkableWeekTests.three), ("5 days", BreakNoWorkableWeekTests.five)]

    /// Every case builds and passes the checker, except exactly the refusals listed: F3's own minimum
    /// for the recent weekly volume (`recentVolumeTooLow`, under 5400 s) and the 15 day, 1 week back
    /// gap (`noWorkableWeek`, see `run`). A regression that refuses any other case, or builds one of
    /// these, fails here.
    func testBreaksOf15And21And28DaysEndingOneToSixWeeksBeforeTheStartBuild() {
        var refused: [String] = []
        for (name, s) in shapes {
            for daysOff in [15, 21, 28] {
                for back in [1, 2, 3, 4, 6] {
                    for share in [0.3, 0.5, 0.7, 0.85] {
                        let c = Case(shape: s, name: name, daysOff: daysOff, weeksBack: back, share: share)
                        if let kind = run(c) { refused.append("\(c): \(kind)") }
                    }
                }
            }
        }
        XCTAssertEqual(refused, Self.expectedRefusals)
    }

    static let expectedRefusals: [String] = [
        "3 days, 15 days off, 1 weeks back at 30%: recentVolumeTooLow",
        "3 days, 15 days off, 1 weeks back at 50%: recentVolumeTooLow",
        "3 days, 15 days off, 1 weeks back at 70%: noWorkableWeek",
        "3 days, 15 days off, 1 weeks back at 85%: noWorkableWeek",
        "3 days, 15 days off, 2 weeks back at 30%: recentVolumeTooLow",
        "3 days, 15 days off, 2 weeks back at 50%: recentVolumeTooLow",
        "3 days, 15 days off, 2 weeks back at 70%: recentVolumeTooLow",
        "3 days, 15 days off, 3 weeks back at 30%: recentVolumeTooLow",
        "3 days, 15 days off, 3 weeks back at 50%: recentVolumeTooLow",
        "3 days, 15 days off, 4 weeks back at 30%: recentVolumeTooLow",
        "3 days, 15 days off, 6 weeks back at 30%: recentVolumeTooLow",
        "3 days, 21 days off, 1 weeks back at 30%: recentVolumeTooLow",
        "3 days, 21 days off, 1 weeks back at 50%: recentVolumeTooLow",
        "3 days, 21 days off, 1 weeks back at 70%: recentVolumeTooLow",
        "3 days, 21 days off, 1 weeks back at 85%: recentVolumeTooLow",
        "3 days, 21 days off, 2 weeks back at 30%: recentVolumeTooLow",
        "3 days, 21 days off, 2 weeks back at 50%: recentVolumeTooLow",
        "3 days, 21 days off, 2 weeks back at 70%: recentVolumeTooLow",
        "3 days, 21 days off, 3 weeks back at 30%: recentVolumeTooLow",
        "3 days, 21 days off, 3 weeks back at 50%: recentVolumeTooLow",
        "3 days, 21 days off, 4 weeks back at 30%: recentVolumeTooLow",
        "3 days, 21 days off, 6 weeks back at 30%: recentVolumeTooLow",
        "3 days, 28 days off, 1 weeks back at 30%: recentVolumeTooLow",
        "3 days, 28 days off, 1 weeks back at 50%: recentVolumeTooLow",
        "3 days, 28 days off, 1 weeks back at 70%: recentVolumeTooLow",
        "3 days, 28 days off, 1 weeks back at 85%: recentVolumeTooLow",
        "3 days, 28 days off, 2 weeks back at 30%: recentVolumeTooLow",
        "3 days, 28 days off, 2 weeks back at 50%: recentVolumeTooLow",
        "3 days, 28 days off, 2 weeks back at 70%: recentVolumeTooLow",
        "3 days, 28 days off, 3 weeks back at 30%: recentVolumeTooLow",
        "3 days, 28 days off, 3 weeks back at 50%: recentVolumeTooLow",
        "3 days, 28 days off, 4 weeks back at 30%: recentVolumeTooLow",
        "3 days, 28 days off, 6 weeks back at 30%: recentVolumeTooLow",
        "5 days, 15 days off, 1 weeks back at 30%: noWorkableWeek",
        "5 days, 15 days off, 1 weeks back at 50%: noWorkableWeek",
        "5 days, 15 days off, 1 weeks back at 70%: noWorkableWeek",
        "5 days, 15 days off, 1 weeks back at 85%: noWorkableWeek",
        "5 days, 15 days off, 2 weeks back at 30%: recentVolumeTooLow",
        "5 days, 15 days off, 2 weeks back at 50%: recentVolumeTooLow",
        "5 days, 15 days off, 3 weeks back at 30%: recentVolumeTooLow",
        "5 days, 15 days off, 4 weeks back at 30%: recentVolumeTooLow",
        "5 days, 15 days off, 6 weeks back at 30%: recentVolumeTooLow",
        "5 days, 21 days off, 1 weeks back at 30%: recentVolumeTooLow",
        "5 days, 21 days off, 1 weeks back at 50%: recentVolumeTooLow",
        "5 days, 21 days off, 1 weeks back at 70%: recentVolumeTooLow",
        "5 days, 21 days off, 1 weeks back at 85%: recentVolumeTooLow",
        "5 days, 21 days off, 2 weeks back at 30%: recentVolumeTooLow",
        "5 days, 21 days off, 2 weeks back at 50%: recentVolumeTooLow",
        "5 days, 21 days off, 3 weeks back at 30%: recentVolumeTooLow",
        "5 days, 21 days off, 4 weeks back at 30%: recentVolumeTooLow",
        "5 days, 21 days off, 6 weeks back at 30%: recentVolumeTooLow",
        "5 days, 28 days off, 1 weeks back at 30%: recentVolumeTooLow",
        "5 days, 28 days off, 1 weeks back at 50%: recentVolumeTooLow",
        "5 days, 28 days off, 1 weeks back at 70%: recentVolumeTooLow",
        "5 days, 28 days off, 1 weeks back at 85%: recentVolumeTooLow",
        "5 days, 28 days off, 2 weeks back at 30%: recentVolumeTooLow",
        "5 days, 28 days off, 2 weeks back at 50%: recentVolumeTooLow",
        "5 days, 28 days off, 3 weeks back at 30%: recentVolumeTooLow",
        "5 days, 28 days off, 4 weeks back at 30%: recentVolumeTooLow",
        "5 days, 28 days off, 6 weeks back at 30%: recentVolumeTooLow"
    ]

    /// The reproduction of the reviewer's #80 round 2: 7 weeks of Mon 60 / Wed 60 / Sat 100, a
    /// 100 minute run on the Monday of week 7, week 8 empty, a plan starting on the Monday of week 9
    /// with the first training day on the Wednesday or later. Days off are the Tuesday to Sunday
    /// of week 7 (6), week 8 (7), and the Monday and Tuesday of week 9 (2): 15, a longer break by
    /// days though only one break week. The pre-break level is the mean of weeks 4 to 7,
    /// (220 + 220 + 220 + 100) / 4 = 190, so week 1 may hold 0.65 x 190 = 123.5 minutes, and the
    /// builder must agree with the checker on it (on main this built at the ramp's 70%).
    func testABreakThatRunsUpToTheStartAndPassesFourteenDaysBuildsWhatTheCheckerAccepts() throws {
        let sets: [(String, Set<PlanWeekday>, PlanWeekday)] = [
            ("3 days", [.wednesday, .friday, .sunday], .sunday),
            ("5 days", [.wednesday, .thursday, .friday, .saturday, .sunday], .sunday)]
        for (name, days, longDay) in sets {
            var acts: [Activity] = []
            for w in 0..<7 {
                for (d, m) in [(PlanWeekday.monday, 60.0), (.wednesday, 60), (.saturday, 100)] {
                    acts.append(GoalFixture.run("n\(w)\(d.rawValue)", week: w, day: d, minutes: m))
                }
            }
            acts.append(GoalFixture.run("m7", week: 7, day: .monday, minutes: 100))
            let asOf = BaselineFixture.date(day: 9 * 7, hour: 8)
            let report = BaselineBuilder.build(activities: acts, efforts: [], options: BaselineOptions(asOf: asOf, timeZone: tz))
            let race = asOf.addingTimeInterval((14 * 7 + 4) * 86_400 + 3600)
            let goal = GoalSettings(race: GoalRace(name: "Synthetic", date: race, distanceMeters: Distance.tenK, time: .bestPossible),
                                    schedule: TrainingSchedule(trainingDays: days, longRunDay: longDay, maxSession: .noLimit),
                                    hasTreadmillAccess: false, painHistory: PainHistory.none)
            var input = BaselinePlanMapping.planInput(settings: goal, baseline: report, startDate: report.asOf)
            input.heartRateZones = HRZones(lthr: 165)
            let history = BaselinePlanMapping.planHistory(from: report)
            let result = PlanBuilder.build(input, history: history, timeZone: tz)
            let plan = try XCTUnwrap(result.plan, "\(name): \(result.issues)")
            XCTAssertLessThanOrEqual(minutes(plan.weeks[0]), 123.5 + 1e-6, name)
            let check = GuardrailChecker.check(history: history, planned: plan.workouts, timeZone: tz)
            XCTAssertTrue(check.passed, "\(name): \(check.violations.map(\.explanation))")
        }
    }

    func testTheBreakWeeksAreWhatTheFixtureSays() {
        // 15 days off from the Sunday after week 7: the first training day on or
        // after day 7*7+5+16 = 70 (a Monday) is the Tuesday, 71 (3 days) and the
        // Monday, 70 (5 days): week 10. 28 days off from the same Sunday: day 83,
        // a Saturday... the first training day is the Saturday of week 11.
        let c3 = Case(shape: BreakNoWorkableWeekTests.three, name: "3", daysOff: 15, weeksBack: 2, share: 0.85)
        let h3 = history(c3)
        XCTAssertEqual(Array(h3.weekly[8...9]), [0, 0], "weeks 8 and 9 are empty")
        XCTAssertEqual(h3.startWeek, 12)
        XCTAssertEqual(h3.weekly[10], 0.85 * 220, accuracy: 1e-6)
        let c5 = Case(shape: BreakNoWorkableWeekTests.five, name: "5", daysOff: 15, weeksBack: 2, share: 0.85)
        XCTAssertEqual(history(c5).startWeek, 12)
        // 28 days off: 4 break weeks (8 to 11) for 3 days? Day 49+5+29 = 83: week 11, Saturday: weeks 8, 9, 10 empty.
        let c28 = Case(shape: BreakNoWorkableWeekTests.three, name: "3", daysOff: 28, weeksBack: 1, share: 0.85)
        let h28 = history(c28)
        XCTAssertEqual(Array(h28.weekly[8...10]), [0, 0, 0])
    }

    func testTheHandModelAgreesWithTheSpecsFirstExample() {
        // The model of this file reproduces the spec's steps: after three weeks
        // off the next planned week is step 1 (156 of 240), then 198, then 240.
        let weekly = [240, 240, 240, 240, 240, 240, 240, 240, 0, 0, 0.0]
        XCTAssertEqual(expectedCeilings(weekly, level: 240) ?? [], [156, 198, 240].map { $0 }, "")
        // A step-2 week run at 160 (under 165) restarts; the next ceiling is the week run.
        XCTAssertEqual(expectedCeilings(weekly + [156, 160], level: 240) ?? [], [160, 198, 240])
        // A return that ended in the history has no ceilings left to check.
        XCTAssertNil(expectedCeilings(weekly + [156, 198, 240], level: 240))
    }
}
