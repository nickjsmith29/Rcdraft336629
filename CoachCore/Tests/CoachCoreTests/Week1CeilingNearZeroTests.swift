import XCTest
@testable import CoachCore

/// Holds a value handed back from another thread.
private final class Box<T>: @unchecked Sendable {
    var value: T?
}

// #143: a `PainRecoveryLimits.week1Fraction` near zero (0, 1e-9, 0.05) "hung
// the engine" in the pain-stop return. Each engine call returned in well
// under a second; what never ended was `AdaptFixture.Driver.follow`. Week 1
// of the return under such a ceiling plans no runs, so its Sunday easy run
// became a rest day, `follow` ran the rest day, the engine (rightly) kept the
// rest day in the plan, and `follow` picked it again: every later pass was a
// re-sync of a run already seen, a no-op, forever. Values from 0.1 up leave
// that Sunday an easy run, which is why they finished. Every test here is
// bounded in time, so a regression fails instead of hanging CI.
// Synthetic plans and reports only; every limit is a heuristic (SPEC 3.5
// rules 4, 6 and 7).
final class Week1CeilingNearZeroTests: XCTestCase {
    typealias F = AdaptFixture

    /// Longest a scenario may take. Each takes about 1 s in a debug build.
    private let bound: TimeInterval = 20

    /// `body` on a background thread, or nil when it hasn't returned within `bound`.
    private func bounded<T>(_ body: @escaping () -> T) -> T? {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.value = body()
            done.signal()
        }
        thread.stackSize = 16 << 20
        thread.start()
        return done.wait(timeout: .now() + bound) == .success ? box.value : nil
    }

    /// The reviewer's probe (#140): pain that worsened on a run stops running;
    /// pain-free mornings end the stop with a test run; the return then runs
    /// weeks 2 and 3, every planned session run as planned (rest days too).
    private func painStop(week1Fraction: Double) -> F.Driver {
        var limits = PainRecoveryLimits()
        limits.week1Fraction = week1Fraction
        var c = F.context(tracksPain: true)
        c.painRecoveryLimits = limits
        var d = F.Driver(plan: F.weeks(0..<4), context: c)
        d.follow(until: F.date(week: 0, day: 6, hour: 23)) { _ in F.RunSpec() }
        d.afterRun(week: 0, day: 6, 6, worsened: true, hour: 10)
        for day in 0..<7 { d.morning(week: 1, day: day, 0) }
        if d.testSession != nil { d.runTest(0) }
        for day in 0..<7 { d.morning(week: 2, day: day, 0) }
        d.follow(until: F.date(week: 3, day: 6, hour: 23)) { _ in F.RunSpec() }
        return d
    }

    private func isRun(_ w: PlannedWorkout) -> Bool { w.kind != .rest && w.kind != .race }

    func testANearZeroWeekOneCeilingFinishesWithARunFreeWeekOne() throws {
        let floor = PlanHeuristics.minimumEasyRunSeconds
        for v in [0, 1e-9, 0.05] {
            let d = try XCTUnwrap(bounded { self.painStop(week1Fraction: v) }, "week1Fraction \(v) finishes within \(bound) s")
            XCTAssertTrue(d.changes.contains { $0.kind == .painStopEnded }, "week1Fraction \(v): the stop ended")
            // The run rest day was re-synced once and then skipped: that is
            // what ends `follow` here (before #143 it looped on it).
            XCTAssertFalse(d.skipped.isEmpty, "week1Fraction \(v): a session kept after its run was skipped")
            for (n, o) in d.outcomes.enumerated() {
                XCTAssertTrue(o.guardrailReport.passed, "week1Fraction \(v), event \(n): \(o.guardrailReport.violations)")
                let test = o.state.painRecovery.test?.workoutID
                for w in o.plan where isRun(w) && w.id != test {
                    XCTAssertGreaterThanOrEqual(w.durationSeconds, floor - 1e-6,
                                                "week1Fraction \(v), event \(n): \(w.id) is planned under the \(floor / 60)-minute floor")
                }
            }
            // While the return is at step 1, its ceiling (at most 5% of the
            // pre-stop level here) is under the 20-minute floor, so no run is
            // planned for it, and the plan says why in plain words.
            let step1 = try XCTUnwrap(d.outcomes.last { $0.painCourse.returnStep == 1 }, "week1Fraction \(v): the return reached step 1")
            let r = try XCTUnwrap(step1.state.painRecovery.painReturn)
            let start = Calendar(identifier: .gregorian).startOfDay(for: r.start)
            let week1Runs = step1.plan.filter {
                isRun($0) && $0.date >= start && $0.id != step1.state.painRecovery.test?.workoutID
                    && r.step(atWeek: PlanCalendar.weekStart(containing: $0.date, timeZone: F.tz), timeZone: F.tz,
                              limits: d.context.painRecoveryLimits) <= 1
            }
            XCTAssertEqual(week1Runs.map(\.id), [], "week1Fraction \(v): no run planned in week 1 of the return")
            XCTAssertTrue(d.changes.contains {
                ($0.kind == .sessionDropped || $0.kind == .sessionRested)
                    && $0.explanation.contains("return after the pain stop") && $0.rule == AdaptationEngine.Work.stopRule
            }, "week1Fraction \(v): a dropped or rested run gives the return as its reason")
        }
    }

    func testNormalWeekOneFractionsStillFinishAndTheDefaultIsUnchanged() throws {
        for v in [0.1, 0.65, 1, 2] {
            let d = try XCTUnwrap(bounded { self.painStop(week1Fraction: v) }, "week1Fraction \(v) finishes within \(bound) s")
            XCTAssertTrue(d.changes.contains { $0.kind == .painStopEnded }, "week1Fraction \(v): the stop ended")
            XCTAssertTrue(d.outcomes.allSatisfy(\.guardrailReport.passed), "week1Fraction \(v)")
        }
        // 0.65 is the default, so setting it changes nothing.
        let set = try XCTUnwrap(bounded { self.painStop(week1Fraction: 0.65) })
        let defaults = try XCTUnwrap(bounded { self.painStop(week1Fraction: PainRecoveryLimits.default.week1Fraction) })
        XCTAssertEqual(set.outcomes, defaults.outcomes)
    }
}
