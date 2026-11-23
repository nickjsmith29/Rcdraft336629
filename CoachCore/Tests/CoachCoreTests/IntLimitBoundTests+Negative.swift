import Foundation
import XCTest
@testable import CoachCore

// #157: the limit guards #142 (`LimitGuardTests`) and #147 (`IntLimitBoundTests`)
// left out. On main:
// - a negative whole-number limit in `AdaptationLimits`, `PainRecoveryLimits`
//   or `PainStopLimits` was kept, and turned a rule inside out (a negative
//   `nextMorningHigh` stopped running on every morning report, a negative
//   `restTriggerCount` made every pain stop a rest stop);
// - `PainRecoveryLimits.rampDaysOff` took any range, `6...Int.max` included;
// - `PlanFormatting.volume` (time) printed a 32-bit-truncated number for a
//   large countable time, and `GoalPlanner.clock` trapped on a non-finite or
//   huge goal time.
// Each limit below 0 is now stored as its default, 0 is kept, `rampDaysOff`
// must lie in `PainRecoveryLimits.rampDaysOffBounds`, and both formatters print
// large values in full or "-". Synthetic values only; every limit is a
// heuristic (SPEC 3.5 rule 7, F4, section 8), and every bound is an
// input-sanity bound, not a training rule.
extension IntLimitBoundTests {
    typealias Neg = IntLimitBoundTests

    // MARK: Negative limits

    /// The two cases that crashed on main (#157), each in a child process:
    /// `holdVolumeDays` -1 and `flagCloseDays` `Int.min`. The sweep of every
    /// field is `testEveryWholeNumberLimitRunsBelowZeroInFull`, behind
    /// `COACHCORE_SLOW_TESTS` (#158): it adds minutes to the default run, and
    /// `testANegativeLimitIsStoredAsTheDefault` proves the fallback of every
    /// field in about a millisecond.
    func testTheNegativeLimitsThatCrashedOnMainRunToTheEnd() {
        runIsolated([("limits.holdVolumeDays", "-1"), ("painRecoveryLimits.flagCloseDays", String(Int.min))])
    }

    /// Every whole-number limit at -1 and `Int.min` runs everything it can
    /// reach, each in a child process, and (`testChildCase`) one that falls
    /// back is stored exactly as the default.
    /// `COACHCORE_SLOW_TESTS=1 swift test`.
    func testEveryWholeNumberLimitRunsBelowZeroInFull() throws {
        try requireSlowTests()
        runIsolated(Neg.fields.flatMap { [($0.name, "-1"), ($0.name, String(Int.min))] })
    }

    func testANegativeLimitIsStoredAsTheDefault() {
        for f in Neg.fields {
            for v in [-1, -7, Int.min] {
                var c = Neg.defaultContext()
                f.set(&c, v)
                XCTAssertEqual(f.get(c), f.get(Neg.defaultContext()), "\(f.name) \(v)")
                XCTAssertEqual(c, Neg.defaultContext(), "\(f.name) \(v): only that limit was bad")
            }
        }
        // The same when the values are handed to the initializers.
        let n = -1
        XCTAssertEqual(AdaptationLimits(signalWindow: n, signalsToMove: n, easyRunsForCapCheck: n, strainRPEMargin: n,
                                        overreachedRPEMargin: n, longRunQualifyingCount: n, longRunReferenceRuns: n,
                                        holdVolumeDays: n, powerHistoryRuns: n, powerHistoryDays: n,
                                        powerHistoryMinimumRuns: n, regrowthSnapshotWeeks: n), .default)
        XCTAssertEqual(PainRecoveryLimits(usualWindow: n, usualMinimumCheckIns: n, nextMorningRise: n, nextMorningHigh: n,
                                          risingWeeks: n, freezeDays: n, morningsToEnd: n, walkingMax: n,
                                          testAllowance: n, testMaxScore: n, cannotEndUsual: n, walkingStuck: n,
                                          stuckDays: n, regrowthWeeks: n, rampDaysOff: n...14, flagReportsToClear: n,
                                          flagAskDays: n, flagCloseDays: n, flagReopenDays: n), .default)
        XCTAssertEqual(PainStopLimits(clinicianDays: n, restTriggerCount: n), .default)
        XCTAssertEqual(PainStopLimits(clinicianDays: .min, restTriggerCount: .min), .default)
        // Each one alone falls back, and leaves the others as they were given.
        var a = AdaptationLimits(signalWindow: 4, strainRPEMargin: -2)
        XCTAssertEqual([a.signalWindow, a.strainRPEMargin], [4, 2])
        a.strainRPEMargin = 1
        a.overreachedRPEMargin = -3
        XCTAssertEqual([a.strainRPEMargin, a.overreachedRPEMargin], [1, 3])
        var r = PainRecoveryLimits(nextMorningHigh: -1, walkingMax: 1)
        XCTAssertEqual([r.nextMorningHigh, r.walkingMax], [4, 1])
        r.flagReopenDays = -42
        XCTAssertEqual(r.flagReopenDays, 42)
        var s = PainStopLimits(clinicianDays: 10, restTriggerCount: -1)
        XCTAssertEqual([s.clinicianDays, s.restTriggerCount], [10, 2])
        s.clinicianDays = -10
        XCTAssertEqual(s.clinicianDays, 7)
    }

    /// 0 is kept for every limit (`testValuesUpToTheBoundAreKept` sweeps it
    /// too), with the meaning the rules already give it: no power-to-HR
    /// comparison for `powerHistoryRuns` (`AdaptationFollowUpTests`), and a
    /// floor of 1 where a rule reads the limit through `max(1, ...)`.
    func testZeroIsKeptWithItsMeaning() {
        let zero = AdaptationLimits(signalWindow: 0, longRunQualifyingCount: 0, holdVolumeDays: 0, powerHistoryRuns: 0)
        XCTAssertEqual([zero.signalWindow, zero.longRunQualifyingCount, zero.holdVolumeDays, zero.powerHistoryRuns],
                       [0, 0, 0, 0])
        XCTAssertEqual(PainRecoveryLimits(walkingMax: 0, rampDaysOff: 0...0).walkingMax, 0)
        XCTAssertEqual(PainRecoveryLimits(rampDaysOff: 0...0).rampDaysOff, 0...0)
        XCTAssertEqual(PainStopLimits(clinicianDays: 0, restTriggerCount: 0).clinicianDays, 0)
        // A rest-trigger count of 0 reads as 1, as before: any trigger means rest.
        XCTAssertEqual(PainStopRule.mode(for: [.worsenedDuringRun], limits: PainStopLimits(restTriggerCount: 0)), .rest)
    }

    // MARK: What a negative limit did to the rules

    /// On main each of these ran the rule inside out; each now runs at the
    /// default, as an unset limit would.
    func testANegativeLimitNoLongerTurnsARuleInsideOut() {
        // One trigger that isn't a movement change or a red flag is easy-only
        // by default; a count of -1 read as 1 and made it rest.
        XCTAssertEqual(PainStopRule.mode(for: [.worsenedDuringRun], limits: PainStopLimits(restTriggerCount: -1)), .easyOnly)
        XCTAssertEqual(PainStopRule.mode(for: [.worsenedDuringRun], limits: .default), .easyOnly)

        // Pain above usual on two days in a row isn't lasting pain by default;
        // a clinician-days limit of -1 read as 1 and raised it.
        let utc = TimeZone(identifier: "UTC")!
        let start = Date(timeIntervalSince1970: 1_767_225_600)   // a Thursday, 00:00 UTC
        let reports = [0, 1].map {
            PainReport(date: start.addingTimeInterval(Double($0) * 86_400 + 8 * 3600), timing: .nextMorning,
                       hasPain: true, score: 3)
        }
        let asOf = start.addingTimeInterval(2 * 86_400)
        XCTAssertNil(PainStopRule.lastingPain(reports: reports, checkIns: [], asOf: asOf, timeZone: utc,
                                              limits: PainStopLimits(clinicianDays: -1)))
        XCTAssertNotNil(PainStopRule.lastingPain(reports: reports, checkIns: [], asOf: asOf, timeZone: utc,
                                                 limits: PainStopLimits(clinicianDays: 1)), "1 day still raises it")

        // Next-morning pain at usual is no trigger by default; a high limit of
        // -1 stopped running on every morning report.
        let morning = PainReport(date: start, timing: .nextMorning, hasPain: false, score: 0)
        XCTAssertEqual(NextMorningRule.verdict(morning, usual: 0, hoursSinceRun: 12,
                                               limits: PainRecoveryLimits(nextMorningHigh: -1)), .none)
        XCTAssertEqual(NextMorningRule.verdict(morning, usual: 0, hoursSinceRun: 12,
                                               limits: PainRecoveryLimits(nextMorningHigh: 0)), .stop, "0 is kept")

        // A test run passes within the default allowance; a top score of -1
        // failed every test run.
        let test = PainReport(date: start, timing: .afterRun, hasPain: true, score: 1)
        XCTAssertTrue(PainStopEndRule.inRunPasses(test, usual: 0, stopFromMovement: false,
                                                  limits: PainRecoveryLimits(testMaxScore: -1)))
    }

    // MARK: rampDaysOff

    func testRampDaysOffMustLieInItsBounds() {
        XCTAssertEqual(PainRecoveryLimits.rampDaysOffBounds, 0...730)
        XCTAssertEqual(PainRecoveryLimits.default.rampDaysOff, 6...14)
        // Out of range, at either end, is stored as the default.
        for bad in [-1...14, Int.min...14, 6...731, 6...Int.max, -1...Int.max, 731...731, Int.max...Int.max] {
            XCTAssertEqual(PainRecoveryLimits(rampDaysOff: bad).rampDaysOff, 6...14, "\(bad)")
            var l = PainRecoveryLimits(rampDaysOff: 7...10)
            l.rampDaysOff = bad
            XCTAssertEqual(l.rampDaysOff, 6...14, "\(bad) set")
            XCTAssertEqual(l, .default)
        }
        // Every range inside the bounds is kept, a single day and the whole span included.
        for good in [0...0, 0...14, 6...14, 1...30, 14...14, 730...730, 0...730] {
            XCTAssertEqual(PainRecoveryLimits(rampDaysOff: good).rampDaysOff, good, "\(good)")
            var l = PainRecoveryLimits.default
            l.rampDaysOff = good
            XCTAssertEqual(l.rampDaysOff, good, "\(good) set")
        }
    }

    /// The ramp's week-2 step applies only for days off in the range: on
    /// main `6...Int.max` applied it after any break of 6 days or more.
    func testAnOutOfRangeRampFallsBackToTheDefaultDays() {
        let ramp = 0.7   // below rule 6's week-2 share (0.825), so the ramp shows
        func step2(daysOff: Int, _ range: ClosedRange<Int>) -> Double? {
            PainReturnRule.ceilingFraction(step: 2, daysOff: daysOff,
                                           limits: PainRecoveryLimits(rampWeek2Fraction: ramp, rampDaysOff: range))
        }
        XCTAssertEqual(try XCTUnwrap(step2(daysOff: 10, 6...14)), ramp, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(step2(daysOff: 20, 6...14)), 0.825, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(step2(daysOff: 20, 6...Int.max)), 0.825, accuracy: 1e-12, "falls back to 6...14")
        XCTAssertEqual(try XCTUnwrap(step2(daysOff: 20, 6...30)), ramp, accuracy: 1e-12, "a valid range is used")
        XCTAssertEqual(try XCTUnwrap(step2(daysOff: 3, -5...14)), 0.825, accuracy: 1e-12, "falls back to 6...14")
    }

    // MARK: Formatting

    /// The new cases at NaN and the infinities: `GoalPlanner.clock` trapped
    /// converting to `Int` on main.
    func testNonFiniteTimesNoLongerCrashTheGoalFormatters() {
        let names = ["format.goal.clock", "format.goal.limit", "format.plan.volume", "format.plan.percent"]
        runIsolated(names.flatMap { n in ["nan", "inf", "-inf"].map { (n, $0) } })
    }

    func testPlanTextReadsAsBeforeForOrdinaryValues() {
        XCTAssertEqual(PlanFormatting.volume(45 * 60, .time), "45 min")
        XCTAssertEqual(PlanFormatting.volume(59 * 60, .time), "59 min")
        XCTAssertEqual(PlanFormatting.volume(60 * 60, .time), "1 h 00 min")
        XCTAssertEqual(PlanFormatting.volume(4 * 3600 + 5 * 60, .time), "4 h 05 min")
        XCTAssertEqual(PlanFormatting.volume(10 * 3600 + 59 * 60 + 40, .time), "11 h 00 min")
        XCTAssertEqual(PlanFormatting.volume(0, .time), "0 min")
        XCTAssertEqual(PlanFormatting.volume(12_300, .distance), "12.3 km")
        XCTAssertEqual(PlanFormatting.percent(0.35), "35%")
        XCTAssertEqual(PlanFormatting.percent(0.105), "10.5%")
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(PlanFormatting.day(Date(timeIntervalSince1970: 1_772_409_600), timeZone: utc), "2026-03-02")
        XCTAssertEqual(PlanFormatting.day(Date(timeIntervalSince1970: 0), timeZone: utc), "1970-01-01")
        XCTAssertEqual(GoalPlanner.clock(5_400), "1:30:00")
        XCTAssertEqual(GoalPlanner.clock(3_725.4), "1:02:05")
        XCTAssertEqual(GoalPlanner.clock(59.6), "0:01:00")
        XCTAssertEqual(GoalPlanner.clock(0), "0:00:00")
        XCTAssertEqual(GoalPlanner.limit(.seconds(90 * 60)), "1 h 30 min")
        XCTAssertEqual(GoalPlanner.describe(.goalTime(from: .seconds(6_300), to: .bestPossible), timeZone: utc),
                       "Goal changed from 1:45:00 to best possible.")
    }

    /// Large countable values print in full, not cut to 32 bits: on main
    /// about 1e17 s of volume read "-910844815 h ...".
    func testLargeCountableValuesPrintInFull() {
        XCTAssertEqual(PlanFormatting.volume(1e17, .time), "27777777777777 h 47 min")
        XCTAssertEqual(PlanFormatting.volume(1e13, .time), "2777777777 h 47 min")
        XCTAssertEqual(PlanFormatting.volume(-1e13, .time), "-166666666667 min")
        XCTAssertEqual(GoalPlanner.clock(1e13), "2777777777:46:40")
        XCTAssertEqual(GoalPlanner.limit(.seconds(1e17)), "27777777777777 h 47 min")
        // Past `Int`'s range, or not a number: "-", as `UnitFormatting` and the debrief show.
        for v in [Double.nan, .infinity, -.infinity, 1e300, -1e300, Double.greatestFiniteMagnitude, 1e19] {
            XCTAssertEqual(GoalPlanner.clock(v), "-", "\(v)")
            if abs(v) > 1e21 || !v.isFinite { XCTAssertEqual(PlanFormatting.volume(v, .time), "-", "\(v)") }
        }
        XCTAssertEqual(GoalPlanner.describe(.goalTime(from: .seconds(.nan), to: .seconds(1e300)), timeZone: .current),
                       "Goal changed from - to -.")
    }
}
