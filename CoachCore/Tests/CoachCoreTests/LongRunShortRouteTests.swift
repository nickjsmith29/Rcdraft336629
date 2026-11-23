import XCTest
@testable import CoachCore

// #170 (owner's decision, SPEC 3.3): a long run with at most 40 minutes of
// moving time (decoupling needs strictly more) counts toward the long-run gate
// when it met the completion share and its main-part average heart rate stayed
// below the top of zone 2 (exclusive), judged against the zones in use when it
// was recorded. A longer run still needs decoupling under the limit. Synthetic
// records and plans only; no real runner is here.
final class LongRunShortRouteTests: XCTestCase {
    typealias F = AdaptFixture
    private let ceiling = F.zones.easyCeiling
    private let limits = AdaptationLimits.default

    private func record(_ id: String, week: Int, planned: Double, moving: Double? = nil, hr: Double?, decoupling: Double? = nil,
                        ceiling: Double? = nil) -> LongRunRecord {
        LongRunRecord(activityID: id, date: F.date(week: week, day: 5), plannedSeconds: planned * 60,
                      movingSeconds: (moving ?? planned) * 60, decouplingPercent: decoupling,
                      averageHeartRate: hr, easyCeiling: ceiling ?? self.ceiling)
    }

    /// Two records before week 0, then the morning of week 0 with a 60-minute long run planned.
    private func monday(_ records: [LongRunRecord], long: Double = 60) -> F.Driver {
        var d = F.Driver(plan: F.weeks(0..<2, longMinutes: { _ in long }), context: F.context())
        d.state.longRuns = records
        d.day(F.date(week: 0, day: 0, hour: 5))
        return d
    }

    private func l0(_ d: F.Driver) -> PlannedWorkout? { d.plan.first { $0.id == "l0" } }

    private func pair(moving: Double, planned: Double? = nil, hr: Double?, decoupling: Double? = nil) -> [LongRunRecord] {
        [record("a", week: -2, planned: planned ?? moving, moving: moving, hr: hr, decoupling: decoupling),
         record("b", week: -1, planned: planned ?? moving, moving: moving, hr: hr, decoupling: decoupling)]
    }

    // MARK: The rule

    func testAShortLongRunFinishedEasyOpensTheGate() throws {
        let d = monday(pair(moving: 30, hr: ceiling - 10))
        XCTAssertEqual(try XCTUnwrap(l0(d)).durationSeconds, 40 * 60, "30 min plus the 10 min step")
        XCTAssertTrue(d.changes.contains { $0.kind == .longRunHeld }, "held at the step, not at the plan of 60")
        assertAdaptationSound(d.outcomes)
    }

    func testHeartRateEqualToTheTopOfZoneTwoDoesNotQualify() throws {
        let d = monday(pair(moving: 30, hr: ceiling))
        XCTAssertEqual(try XCTUnwrap(l0(d)).durationSeconds, 30 * 60, "zone 3 starts at the ceiling: held")
        let c = try XCTUnwrap(d.changes.first { $0.kind == .longRunHeld })
        XCTAssertTrue(c.triggers.contains { $0.detail.contains("at or above the top of zone 2") }, c.explanation)
        let just = monday(pair(moving: 30, hr: ceiling.nextDown))
        XCTAssertEqual(try XCTUnwrap(l0(just)).durationSeconds, 40 * 60)
    }

    func testNoHeartRateOrNonFiniteHeartRateDoesNotQualify() throws {
        for hr in [nil, Double.nan, .infinity] {
            let d = monday(pair(moving: 30, hr: hr))
            XCTAssertEqual(try XCTUnwrap(l0(d)).durationSeconds, 30 * 60, "hr \(String(describing: hr))")
        }
        let none = monday(pair(moving: 30, hr: nil))
        let c = try XCTUnwrap(none.changes.first { $0.kind == .longRunHeld })
        XCTAssertTrue(c.triggers.contains { $0.detail.contains("no heart rate recorded") }, c.explanation)
        XCTAssertTrue(c.explanation.contains("SPEC 3.3"), c.explanation)
    }

    func testMissingRecordedCeilingDoesNotQualify() throws {
        let rs = [LongRunRecord(activityID: "a", date: F.date(week: -2, day: 5), plannedSeconds: 1800, movingSeconds: 1800,
                                decouplingPercent: nil, averageHeartRate: 120, easyCeiling: nil),
                  LongRunRecord(activityID: "b", date: F.date(week: -1, day: 5), plannedSeconds: 1800, movingSeconds: 1800,
                                decouplingPercent: nil, averageHeartRate: 120, easyCeiling: nil)]
        XCTAssertEqual(try XCTUnwrap(l0(monday(rs))).durationSeconds, 30 * 60)
    }

    func testTheZonesInUseWhenRecordedAreTheOnesJudged() throws {
        // The run's own recorded ceiling decides, not today's zones.
        let low = pair(moving: 30, hr: 140).map { r in
            LongRunRecord(activityID: r.activityID, date: r.date, plannedSeconds: r.plannedSeconds, movingSeconds: r.movingSeconds,
                          decouplingPercent: nil, averageHeartRate: 140, easyCeiling: 138)
        }
        XCTAssertEqual(try XCTUnwrap(l0(monday(low))).durationSeconds, 30 * 60, "140 is above a recorded ceiling of 138")
    }

    func testNotFinishedWithEasyHeartRateDoesNotQualify() throws {
        // 20 of 30 planned minutes: under the completion share.
        let share = limits.longRunCompletionShare
        XCTAssertLessThan(20.0 / 30, share)
        let d = monday(pair(moving: 20, planned: 30, hr: ceiling - 10))
        XCTAssertEqual(try XCTUnwrap(l0(d)).durationSeconds, 30 * 60, "held at the planned level, no step")
        let done = monday(pair(moving: share * 30, planned: 30, hr: ceiling - 10))
        XCTAssertEqual(try XCTUnwrap(l0(done)).durationSeconds, 40 * 60, "exactly the share qualifies")
    }

    func testOneNonQualifyingRunOfTheRecentOnesHoldsTheGate() throws {
        let rs = [record("a", week: -2, planned: 30, hr: ceiling - 10), record("b", week: -1, planned: 30, hr: ceiling + 5)]
        XCTAssertEqual(try XCTUnwrap(l0(monday(rs))).durationSeconds, 30 * 60)
    }

    // MARK: The 40-minute boundary goes by the record's moving time

    func testExactlyFortyMinutesTakesTheHeartRateRoute() throws {
        let d = monday(pair(moving: 40, hr: ceiling - 10))
        XCTAssertEqual(try XCTUnwrap(l0(d)).durationSeconds, 50 * 60, "40:00 is too short for decoupling: easy HR opens the gate")
        let hard = monday(pair(moving: 40, hr: ceiling + 3))
        XCTAssertEqual(try XCTUnwrap(l0(hard)).durationSeconds, 40 * 60)
    }

    func testAboveFortyMinutesNeedsDecoupling() throws {
        let minutes = 40.0 + 1.0 / 60
        for hr in [ceiling - 10, nil] {
            let none = monday(pair(moving: minutes, hr: hr, decoupling: nil))
            XCTAssertEqual(try XCTUnwrap(l0(none)).durationSeconds, (minutes * 60).rounded() , accuracy: 1, "easy HR alone is not enough")
            let bad = monday(pair(moving: minutes, hr: hr, decoupling: limits.longRunDecouplingLimit))
            XCTAssertEqual(try XCTUnwrap(l0(bad)).durationSeconds, (minutes * 60).rounded(), accuracy: 1)
            let good = monday(pair(moving: minutes, hr: hr, decoupling: limits.longRunDecouplingLimit - 1))
            XCTAssertEqual(try XCTUnwrap(l0(good)).durationSeconds, (minutes * 60).rounded() + 600, accuracy: 1)
        }
        let c = try XCTUnwrap(monday(pair(moving: minutes, hr: ceiling - 10)).changes.first { $0.kind == .longRunHeld })
        XCTAssertTrue(c.triggers.contains { $0.detail.contains("decoupling could not be measured") }, c.explanation)
    }

    func testTheGateGoesByTheRecordsMovingTimeNotTheRunMetricsOrDecouplingsOwn() throws {
        // RunMetrics' moving time and decoupling's own moving time come from the
        // same algorithm, so they cannot differ in practice; these seeded
        // records pin that the gate goes by the record's moving time. A run
        // whose record says 39:59 moving time but whose planned time was
        // 41 min: the record decides, so it takes the heart-rate route even
        // though decoupling was computed (it is ignored below the line).
        let d = monday(pair(moving: 40 - 1.0 / 60, planned: 41, hr: ceiling - 10, decoupling: 9))
        XCTAssertEqual(try XCTUnwrap(l0(d)).durationSeconds, 51 * 60, "reference 41 plus 10: decoupling of 9% is not looked at")
        // And one at 40:01 with easy HR and a bad decoupling is held.
        let e = monday(pair(moving: 40 + 1.0 / 60, planned: 41, hr: ceiling - 10, decoupling: 9))
        XCTAssertEqual(try XCTUnwrap(l0(e)).durationSeconds, 41 * 60)
    }

    func testAShortRecordNeedsEasyHeartRateWhateverItsDecoupling() throws {
        let good = limits.longRunDecouplingLimit - 1
        for (moving, hr) in [(38.0, Double?.none), (38, ceiling), (38, ceiling + 5), (40 - 1.0 / 60, ceiling), (40 - 1.0 / 60, ceiling + 5)] {
            let d = monday(pair(moving: moving, hr: hr, decoupling: good))
            XCTAssertEqual(try XCTUnwrap(l0(d)).durationSeconds, (moving * 60).rounded(), accuracy: 1,
                           "moving \(moving), hr \(String(describing: hr)): held despite good decoupling")
        }
        let noCeiling = pair(moving: 38, hr: 120, decoupling: good).map { r in
            LongRunRecord(activityID: r.activityID, date: r.date, plannedSeconds: r.plannedSeconds, movingSeconds: r.movingSeconds,
                          decouplingPercent: good, averageHeartRate: 120, easyCeiling: nil)
        }
        XCTAssertEqual(try XCTUnwrap(l0(monday(noCeiling))).durationSeconds, 38 * 60)
    }

    func testAnUnfinishedShortRunWithEasyHeartRateSaysSo() throws {
        let d = monday(pair(moving: 20, planned: 30, hr: ceiling - 10))
        let c = try XCTUnwrap(d.changes.first { $0.kind == .longRunHeld })
        XCTAssertTrue(c.triggers.contains { $0.detail.contains("below the top of zone 2") && $0.detail.contains("but not finished") }, c.explanation)
    }

    // MARK: Codable

    func testARecordSavedBeforeTheNewFieldsDecodesAndDoesNotQualify() throws {
        let json = """
        {"activityID":"old","date":0,"plannedSeconds":1800,"movingSeconds":1800,"decouplingPercent":null}
        """
        let r = try JSONDecoder().decode(LongRunRecord.self, from: Data(json.utf8))
        XCTAssertNil(r.averageHeartRate)
        XCTAssertNil(r.easyCeiling)
        var d = F.Driver(plan: F.weeks(0..<2, longMinutes: { _ in 60 }), context: F.context())
        d.state.longRuns = [r, r]
        d.day(F.date(week: 0, day: 0, hour: 5))
        XCTAssertEqual(try XCTUnwrap(l0(d)).durationSeconds, 30 * 60, "held: nothing says it was easy")
    }

    func testRecordRoundTripsWithTheNewFields() throws {
        let r = record("x", week: -1, planned: 30, hr: 131.5)
        let back = try JSONDecoder().decode(LongRunRecord.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back, r)
        XCTAssertEqual(back.averageHeartRate, 131.5)
        XCTAssertEqual(back.easyCeiling, ceiling)
    }

    // MARK: End to end: six weeks of short long runs

    func testSixWeeksOfShortLongRunsGrowByTheStepThenNeedDecouplingPastFortyMinutes() throws {
        // Prior long runs of 25 min, easy; the plan asks for 60. The gate lets
        // each next long run grow by the 10 min step while the runs are easy.
        // A run over 40 min needs decoupling: those here drift (HR climbs over
        // the second half), so growth stops there.
        var d = F.Driver(plan: F.weeks(0..<6, longMinutes: { _ in 60 }), context: F.context())
        d.state.longRuns = [record("s1", week: -2, planned: 25, hr: ceiling - 10), record("s2", week: -1, planned: 25, hr: ceiling - 10)]
        d.day(F.date(week: 0, day: 0, hour: 5))
        d.follow(until: F.date(week: 5, day: 6, hour: 23)) { w in
            w.kind == .long && w.durationSeconds > 40 * 60 ? F.RunSpec(drift: 0.2) : F.RunSpec()
        }
        let longs = d.state.longRuns.dropFirst(2)
        XCTAssertEqual(longs.count, 6, "every long run was run and recorded")
        let minutes = longs.map { $0.plannedSeconds / 60 }
        XCTAssertEqual(Array(minutes.prefix(2)), [35, 45], "25 to 35 by the step, then 45 (the first over 40 min)")
        for (a, b) in zip(minutes, minutes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b, a, "never shrinks: \(minutes)")
            XCTAssertLessThanOrEqual(b - a, limits.longRunStepSeconds / 60 + 1e-6, "at most the step: \(minutes)")
        }
        XCTAssertEqual(minutes.last, 45, "a drifting run over 40 min does not open the gate: \(minutes)")
        assertAdaptationSound(d.outcomes)
    }

    func testShortLongRunsStayInsideTheGuardrailsWhileTheyGrow() throws {
        var d = F.Driver(plan: F.weeks(0..<6, longMinutes: { _ in 60 }), context: F.context())
        d.state.longRuns = [record("s1", week: -2, planned: 25, hr: ceiling - 10), record("s2", week: -1, planned: 25, hr: ceiling - 10)]
        d.day(F.date(week: 0, day: 0, hour: 5))
        d.follow(until: F.date(week: 3, day: 6, hour: 23)) { _ in F.RunSpec() }
        assertAdaptationSound(d.outcomes)
    }
}
