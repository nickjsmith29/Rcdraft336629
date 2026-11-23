import XCTest
@testable import CoachCore

// One moving-time rule (#40): the baseline's weekly load (F1) and the history
// volume the guardrails (3.5) and the plan builder (F3) read agree for runs
// with pauses. Synthetic runs only.

final class MovingTimeAgreementTests: XCTestCase {
    private let tz = TimeZone(identifier: "UTC")!
    /// A Monday, 00:00 UTC.
    private let firstMonday = Date(timeIntervalSince1970: 1_767_571_200) // 2026-01-05

    private func day(_ d: Int, hour: Int = 7) -> Date {
        firstMonday.addingTimeInterval(Double(d) * 86_400 + Double(hour) * 3600)
    }

    /// A run with three ways to pause: moving every 10 s for `firstMinutes`,
    /// silent until a paused sample 300 s later, paused for 200 s, moving for
    /// 800 s with a paused duplicate at one timestamp (a stop the source
    /// reports beside a moving sample), then done.
    private func pausedRun(_ id: String, start: Date, firstMinutes: Double) -> Activity {
        let firstEnd = firstMinutes * 60
        var samples: [StreamSample] = stride(from: 0.0, through: firstEnd, by: 10).map {
            StreamSample(t: $0, speed: 3, distance: 3 * $0)
        }
        samples.append(StreamSample(t: firstEnd + 300, isMoving: false))
        samples.append(StreamSample(t: firstEnd + 400, isMoving: false))
        let resume = firstEnd + 500
        for t in stride(from: resume, through: resume + 800, by: 10) {
            samples.append(StreamSample(t: t, speed: 3, distance: 3 * (t - 500)))
            if t == resume + 400 { samples.append(StreamSample(t: t, isMoving: false)) }
        }
        return Activity(id: id, source: .healthKit, start: start, durationSeconds: resume + 800,
                        distanceMeters: 3 * (firstEnd + 800), samples: samples)
    }

    /// Four complete weeks of three paused runs each, plus one run with no
    /// streams (elapsed time is all there is).
    private func history() -> [Activity] {
        var runs: [Activity] = []
        for w in 0..<4 {
            runs.append(pausedRun("w\(w)-mon", start: day(7 * w), firstMinutes: 20))
            runs.append(pausedRun("w\(w)-wed", start: day(7 * w + 2), firstMinutes: 25))
            runs.append(pausedRun("w\(w)-sat", start: day(7 * w + 5), firstMinutes: 40 + Double(w)))
        }
        runs.append(Activity(id: "no-streams", source: .healthKit, start: day(10), durationSeconds: 1500,
                             distanceMeters: 4500))
        return runs
    }

    private func options(hold: Double? = nil) -> BaselineOptions {
        var o = BaselineOptions(asOf: day(7 * 4 + 2, hour: 12), timeZone: tz)
        if let hold { o.decoupling.maximumHoldSeconds = hold }
        return o
    }

    func testOnePausedRunHasTheSameMovingTimeEverywhere() throws {
        let run = pausedRun("r", start: day(0), firstMinutes: 20)
        // 1200 s moving, 30 s held into the stop, then the second part: 400 s
        // up to the paused duplicate (whose 10 s interval before it counts), and
        // 400 s after it less the 10 s that starts at the paused point.
        let expected = 1200.0 + 30 + 800 - 10
        XCTAssertEqual(MovingTime.seconds(of: run), expected)
        XCTAssertEqual(try XCTUnwrap(PlannedWorkout(activity: run, kind: .easy)).durationSeconds, expected)
        let report = BaselineBuilder.build(activities: [run], options: options())
        XCTAssertEqual(try XCTUnwrap(report.runs.first).movingSeconds, expected)
    }

    func testBaselineWeeklyLoadAndGuardrailHistoryVolumeAgree() throws {
        let runs = history()
        let report = BaselineBuilder.build(activities: runs, options: options())
        let load = try XCTUnwrap(report.weeklyLoad.value)

        // History as the adaptation engine records it, and as the goal planner
        // maps it from the baseline: the same moving time per run.
        let fromActivities = runs.compactMap { PlannedWorkout(activity: $0, kind: .easy) }
        let fromBaseline = BaselinePlanMapping.planHistory(from: report)
        XCTAssertEqual(fromActivities.count, runs.count)
        let mapped = Dictionary(uniqueKeysWithValues: fromBaseline.map { ($0.id, $0.durationSeconds) })
        for w in fromActivities {
            XCTAssertEqual(mapped[w.id], w.durationSeconds, w.id)
        }

        // Each week's history volume is the baseline's weekly load for that week.
        let weeks = PlanWeek.weeks(from: fromActivities, timeZone: tz)
        var compared = 0
        for loadWeek in load.weeks where loadWeek.runCount > 0 {
            let week = try XCTUnwrap(weeks.first { $0.weekStart == loadWeek.weekStart })
            XCTAssertEqual(try XCTUnwrap(week.volume(.time)), loadWeek.movingSeconds, accuracy: 1e-9)
            compared += 1
        }
        XCTAssertEqual(compared, 4)
        let basis = weeks.filter { load.basisWeekStarts.contains($0.weekStart) }.compactMap { $0.volume(.time) }
        XCTAssertEqual(basis.reduce(0, +) / Double(basis.count), load.currentWeeklyMovingSeconds, accuracy: 1e-9)

        // The guardrail checker measures the next week against the same number:
        // a planned week far above the last history week is held to 110 % of
        // the baseline's load for that week.
        let lastWeek = try XCTUnwrap(load.weeks.last { $0.runCount > 0 })
        let planned = [PlannedWorkout(id: "p1", date: day(28), kind: .easy,
                                      durationSeconds: 2 * lastWeek.movingSeconds)]
        let report35 = GuardrailChecker.check(history: fromActivities, planned: planned, timeZone: tz)
        let rise = try XCTUnwrap(report35.violations.first { $0.rule == .weeklyIncrease })
        XCTAssertEqual(rise.allowed, lastWeek.movingSeconds * (1 + GuardrailLimits.default.maxWeeklyIncrease),
                       accuracy: 1e-6)
        XCTAssertEqual(rise.measured, 2 * lastWeek.movingSeconds, accuracy: 1e-6)
    }

    func testAgreementHoldsWithANonDefaultHoldLimit() throws {
        let runs = history()
        let report = BaselineBuilder.build(activities: runs, options: options(hold: 90))
        let load = try XCTUnwrap(report.weeklyLoad.value)
        let history = runs.compactMap { PlannedWorkout(activity: $0, kind: .easy, maximumHoldSeconds: 90) }
        let weeks = PlanWeek.weeks(from: history, timeZone: tz)
        for loadWeek in load.weeks where loadWeek.runCount > 0 {
            let week = try XCTUnwrap(weeks.first { $0.weekStart == loadWeek.weekStart })
            XCTAssertEqual(try XCTUnwrap(week.volume(.time)), loadWeek.movingSeconds, accuracy: 1e-9)
        }
        // The longer hold counts 60 s more for each run's stop into a pause.
        let defaultLoad = try XCTUnwrap(BaselineBuilder.build(activities: runs, options: options()).weeklyLoad.value)
        XCTAssertEqual(load.weeks[0].movingSeconds - defaultLoad.weeks[0].movingSeconds, 3 * 60, accuracy: 1e-9)
    }
}
