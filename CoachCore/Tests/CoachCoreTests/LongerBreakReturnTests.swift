import XCTest
@testable import CoachCore

// SPEC.md 0.8, 3.5 rule 4 "Longer than 14 days" (owner's decision, #32; fixes
// #79): the return after more than 14 days off, or three or more break weeks
// in a row, goes by steps of 65 / 82.5 / 100% of the pre-break level, the
// steps replace the 10% check, and a week run short restarts them. Every
// expected number below is worked out by hand from the spec. Synthetic weeks
// only: the volumes are made up and stand for no real person.
//
// Fixture: `F.easyWeek` puts 4 equal easy runs on days 0, 2, 4 and 6 of a
// week, so a week of runs ends on its Sunday and starts on its Monday, and
// empty weeks between two of them are exactly 7 days off each.
final class LongerBreakReturnTests: XCTestCase {
    private let utc = PlanFixture.utc
    private typealias F = PlanFixture
    private let m = 60.0

    // MARK: Fixtures

    private func week(_ w: Int, _ easy: Double, prefix: String) -> [PlannedWorkout] {
        easy > 0 ? F.easyWeek(w, minutes: easy, prefix: prefix) : []
    }

    private func weeks(_ easy: [Double], start: Int = 0, prefix: String) -> [PlannedWorkout] {
        easy.enumerated().flatMap { k, v in week(start + k, v, prefix: prefix) }
    }

    /// A week whose `minutes` are split over runs on the given weekdays (0 = Monday).
    private func runs(_ w: Int, days: [Int], minutes: Double, prefix: String) -> [PlannedWorkout] {
        days.map { F.workout("\(prefix)\(w)-\($0)", week: w, day: $0, .easy, minutes: minutes / Double(days.count)) }
    }

    private func check(_ history: [PlannedWorkout], _ planned: [PlannedWorkout],
                       limits: GuardrailLimits = .default) -> GuardrailReport {
        GuardrailChecker.check(history: history, planned: planned, timeZone: utc, limits: limits)
    }

    private func weekly(_ r: GuardrailReport) -> [GuardrailViolation] { r.violations.filter { $0.rule == .weeklyIncrease } }
    private func rolling(_ r: GuardrailReport) -> [GuardrailViolation] { r.violations.filter { $0.rule == .fourWeekIncrease } }
    private func quality(_ r: GuardrailReport) -> [GuardrailViolation] { r.violations.filter { $0.rule == .qualitySessions } }

    /// Four weeks at 240 minutes, then three weeks off: the pre-break level is 240.
    private var afterThreeWeeksOff: [PlannedWorkout] { weeks([240, 240, 240, 240, 0, 0, 0], prefix: "h") }


    // MARK: The steps (3.5 rule 4)

    func testReturnWeek1HoldsAtMost65PercentOfThePreBreakLevel() throws {
        // 65% of 240 = 156. Plain rules gave no workable week here (#79: the
        // reference was a zero week).
        let h = afterThreeWeeksOff
        XCTAssertTrue(weekly(check(h, weeks([156], start: 7, prefix: "p"))).isEmpty)
        let v = try XCTUnwrap(weekly(check(h, weeks([157], start: 7, prefix: "p"))).first)
        XCTAssertEqual(v.allowed, 156 * m, accuracy: 1e-6)
        XCTAssertTrue(v.explanation.contains("longer break"), v.explanation)
    }

    func testTheStepsReplaceThe10PercentCheck() throws {
        // 156, then 198 (82.5% of 240), then 240: rises of 27% and 21%, which
        // the plain 10% check would refuse; the steps allow them.
        let h = afterThreeWeeksOff
        XCTAssertTrue(check(h, weeks([156, 198, 240], start: 7, prefix: "p")).violations.filter { $0.rule == .weeklyIncrease }.isEmpty)
        let two = try XCTUnwrap(weekly(check(h + weeks([156], start: 7, prefix: "h"), weeks([199], start: 8, prefix: "p"))).first)
        XCTAssertEqual(two.allowed, 198 * m, accuracy: 1e-6)
        let three = try XCTUnwrap(weekly(check(h + weeks([156, 198], start: 7, prefix: "h"), weeks([241], start: 9, prefix: "p"))).first)
        XCTAssertEqual(three.allowed, 240 * m, accuracy: 1e-6)
    }

    func testAStepIsACeilingNotATarget() {
        // A week held lower stays lower, and the next week still takes the
        // next step: week 1 at 100 minutes (over 1/1.2 of 156, so not short),
        // then step 2's 198, not 10% over 100.
        let h = afterThreeWeeksOff + weeks([140], start: 7, prefix: "h")
        XCTAssertTrue(weekly(check(h, weeks([198], start: 8, prefix: "p"))).isEmpty)
        XCTAssertEqual(weekly(check(h, weeks([199], start: 8, prefix: "p"))).allowedRounded, [198 * m])
    }

    func testAFourWeekBreakHasTheSameSteps() {
        // Four weeks off (240 level): the same steps.
        let h = weeks([240, 240, 240, 240, 0, 0, 0, 0], prefix: "h")
        XCTAssertEqual(weekly(check(h, weeks([157], start: 8, prefix: "p"))).allowedRounded, [156 * m])
    }

    // MARK: The end of the return, and the spec's worked examples

    func testTheReturnEndsWithAStep3WeekThatIsNotShort() {
        // 240 x4, 0, 0, 0, 156, 198, 240: the return ended with the 240. The
        // plain 10% check measures the next week from the week before: 264.
        let h = afterThreeWeeksOff + weeks([156, 198, 240], start: 7, prefix: "h")
        XCTAssertTrue(weekly(check(h, weeks([264], start: 10, prefix: "p"))).isEmpty)
        XCTAssertEqual(weekly(check(h, weeks([265], start: 10, prefix: "p"))).allowedRounded, [264 * m])
    }

    func testSpecExampleOneRollingWindowIsMeasuredAgainst960() throws {
        // SPEC rule 4: history 240 x4, 0, 0, 0, 156, 198, 240. The next
        // week's window holds the 4 weeks 3 to 6 at the pre-break level, 4 x
        // 240 = 960, so 1.3 x 960 = 1248 minutes in all; the 4 weeks ending
        // with it hold 156 + 198 + 240 + x, so x may be 654. Weekly check set
        // wide to isolate the rolling one.
        let h = afterThreeWeeksOff + weeks([156, 198, 240], start: 7, prefix: "h")
        let loose = GuardrailLimits(maxWeeklyIncrease: 10)
        XCTAssertTrue(rolling(check(h, weeks([654], start: 10, prefix: "p"), limits: loose)).isEmpty)
        let over = try XCTUnwrap(rolling(check(h, weeks([655], start: 10, prefix: "p"), limits: loose)).first)
        XCTAssertEqual(over.allowed, 1248 * m, accuracy: 1e-6)
        // Rather than 240 (weeks 4 to 6 at their zero volume): 312 minutes in all.
        let off = GuardrailLimits(maxWeeklyIncrease: 10, longerBreakReturnSteps: [])
        XCTAssertEqual(rolling(check(h, weeks([100], start: 10, prefix: "p"), limits: off)).allowedRounded, [312 * m])
    }

    func testSpecExampleTwoLowWeeksBackGiveACapOf658() throws {
        // SPEC rule 4: 240 x4, 0, 0, 0, then four weeks back at 96 (each short
        // of 156 / 1.2 = 130, so each restarts at step 1), and planned weeks
        // 156, 198 and 236. The next week may hold 1.3 x 960 - (156 + 198 +
        // 236) = 658 in the rolling check, not 1.3 x 384 - 590 = -91.
        let h = afterThreeWeeksOff + weeks([96, 96, 96, 96], start: 7, prefix: "h")
        let planned = weeks([156, 198, 236], start: 11, prefix: "p")
        // The three planned weeks are within step 1, 2 and 3 (a restart's step
        // 1 is 156: the week run, 96, is under it).
        XCTAssertTrue(weekly(check(h, planned)).isEmpty, "\(weekly(check(h, planned)).map(\.explanation))")
        let loose = GuardrailLimits(maxWeeklyIncrease: 10)
        XCTAssertTrue(rolling(check(h, planned + weeks([658], start: 14, prefix: "q"), limits: loose)).isEmpty)
        let over = try XCTUnwrap(rolling(check(h, planned + weeks([659], start: 14, prefix: "q"), limits: loose)).first)
        XCTAssertEqual(over.allowed, 1248 * m, accuracy: 1e-6)
        XCTAssertEqual(over.measured, (156 + 198 + 236 + 659) * m, accuracy: 1e-6)
    }

    // MARK: The restart

    func testAWeekRunUnder83PercentOfItsStepRestartsAtStep1() throws {
        // Return week 1 is step 1, 156. Run at 120 (under 156 / 1.2 = 130) it
        // is short: the next week is step 1 again, 156, not step 2's 198.
        let h = afterThreeWeeksOff + weeks([120], start: 7, prefix: "h")
        XCTAssertTrue(weekly(check(h, weeks([156], start: 8, prefix: "p"))).isEmpty)
        XCTAssertEqual(weekly(check(h, weeks([157], start: 8, prefix: "p"))).allowedRounded, [156 * m])
    }

    func testTheRestartBoundaryIsExactlyOneOver1Point2() {
        // Step 2's ceiling is 198; 198 / 1.2 = 165. Run at 165 the week is not
        // short, so the next week is step 3, 240. Just under it (164) is short.
        let first = afterThreeWeeksOff + weeks([156], start: 7, prefix: "h")
        let atLine = first + weeks([165], start: 8, prefix: "h")
        XCTAssertTrue(weekly(check(atLine, weeks([240], start: 9, prefix: "p"))).isEmpty)
        XCTAssertEqual(weekly(check(atLine, weeks([241], start: 9, prefix: "p"))).allowedRounded, [240 * m])
        let under = first + weeks([164], start: 8, prefix: "h")
        // Short: step 1 again, and its ceiling is never below the week run:
        // max(156, 164) = 164.
        XCTAssertTrue(weekly(check(under, weeks([164], start: 9, prefix: "p"))).isEmpty)
        XCTAssertEqual(weekly(check(under, weeks([165], start: 9, prefix: "p"))).allowedRounded, [164 * m])
    }

    func testTheRestartCeilingIsNeverBelowTheWeekRun() throws {
        // 156, then 160 in a step-2 week (160 < 165: short). The next week is
        // step 1, whose 156 is under the 160 run: the ceiling is 160.
        let h = afterThreeWeeksOff + weeks([156, 160], start: 7, prefix: "h")
        let v = try XCTUnwrap(weekly(check(h, weeks([161], start: 9, prefix: "p"))).first)
        XCTAssertEqual(v.allowed, 160 * m, accuracy: 1e-6)
        XCTAssertTrue(v.explanation.contains("restart"), v.explanation)
        XCTAssertTrue(weekly(check(h, weeks([160], start: 9, prefix: "p"))).isEmpty)
        // Then step 2 (198) and step 3 (240) follow, as planned weeks.
        let planned = weeks([160, 198, 240], start: 9, prefix: "p")
        XCTAssertTrue(weekly(check(h, planned)).isEmpty)
        XCTAssertEqual(weekly(check(h, weeks([160, 199], start: 9, prefix: "p"))).allowedRounded, [198 * m])
    }

    func testAPlannedWeekIsNeverShort() {
        // A week planned low (held by the spike rule, say) is run as planned:
        // the steps go on. 156, then a planned 120 at step 2, then step 3.
        let h = afterThreeWeeksOff + weeks([156], start: 7, prefix: "h")
        let planned = weeks([120, 240], start: 8, prefix: "p")
        XCTAssertTrue(weekly(check(h, planned)).isEmpty)
        XCTAssertEqual(weekly(check(h, weeks([120, 241], start: 8, prefix: "p"))).allowedRounded, [240 * m])
    }

    // MARK: Session limits go by return week

    func testNoQualityInReturnWeek1AndOneInWeek2AfterALongerBreak() {
        let h = afterThreeWeeksOff
        func withQuality(_ w: Int, count: Int, easy: Double) -> [PlannedWorkout] {
            runs(w, days: [0, 2], minutes: easy, prefix: "e")
                + (0..<count).map { F.workout("q\(w)-\($0)", week: w, day: 3 + $0, .quality(.tempo), minutes: 30) }
        }
        let week1 = check(h, withQuality(7, count: 1, easy: 100))
        XCTAssertEqual(quality(week1).allowedRounded, [0])
        XCTAssertTrue(quality(check(h, withQuality(7, count: 0, easy: 100))).isEmpty)
        // Return week 2 holds at most one, whatever step the restart gave it.
        let back = h + weeks([120], start: 7, prefix: "h")
        XCTAssertEqual(quality(check(back, withQuality(8, count: 2, easy: 100))).allowedRounded, [1])
        XCTAssertTrue(quality(check(back, withQuality(8, count: 1, easy: 100))).isEmpty)
        // From return week 3 the plain limit (2) applies, restart or not.
        let third = back + weeks([156], start: 8, prefix: "h")
        XCTAssertTrue(quality(check(third, withQuality(9, count: 2, easy: 100))).isEmpty)
    }

    // MARK: Breaks of 15 to 20 days in one or two break weeks (both short and longer)

    /// Four weeks at 240, two empty weeks, and the first run back on a Tuesday
    /// (15 days off: the last run on a Sunday, then 14 days and the Monday).
    private var fifteenDaysOff: [PlannedWorkout] { weeks([240, 240, 240, 240, 0, 0], prefix: "h") }

    func testFifteenDaysOffTakesTheLowerOfTheShortCapAndTheStep() throws {
        // Return week 1: the short break's cap is 70% of 240 = 168, the step
        // 65% = 156: the lower, 156 (a 14-day break keeps 168).
        let back = runs(6, days: [1, 3, 5], minutes: 157, prefix: "p")
        let v = try XCTUnwrap(weekly(check(fifteenDaysOff, back)).first)
        XCTAssertEqual(v.allowed, 156 * m, accuracy: 1e-6)
        XCTAssertTrue(v.explanation.contains("more than 14 days off"), v.explanation)
        XCTAssertTrue(weekly(check(fifteenDaysOff, runs(6, days: [1, 3, 5], minutes: 156, prefix: "p"))).isEmpty)
        // The same with the first run on the Monday: 14 days, a short break only.
        let fourteen = runs(6, days: [0, 2, 4], minutes: 168, prefix: "p")
        XCTAssertTrue(weekly(check(fifteenDaysOff, fourteen)).isEmpty)
        let over = runs(6, days: [0, 2, 4], minutes: 169, prefix: "p")
        XCTAssertEqual(weekly(check(fifteenDaysOff, over)).allowedRounded, [168 * m])
    }

    func testFromReturnWeek4AFifteenDayBreakStillReturnsBySteps() {
        // Three weeks back at 100 (each short of 130, so each restarts at step
        // 1): in return week 4 the short ramp has ended, but the break is
        // longer than 14 days, so the steps go on: step 1's 156, not the plain
        // 10% over 100 (110).
        let h = fifteenDaysOff + runs(6, days: [1, 3, 5], minutes: 100, prefix: "h")
            + runs(7, days: [1, 3, 5], minutes: 100, prefix: "h") + runs(8, days: [1, 3, 5], minutes: 100, prefix: "h")
        let ok = runs(9, days: [1, 3, 5], minutes: 150, prefix: "p")
        XCTAssertTrue(weekly(check(h, ok)).isEmpty, "\(weekly(check(h, ok)).map(\.explanation))")
        let over = runs(9, days: [1, 3, 5], minutes: 157, prefix: "p")
        XCTAssertEqual(weekly(check(h, over)).allowedRounded, [156 * m])
    }

    func testDaysOffAreCountedWithTheRunFreeDaysOnEitherSide() {
        // The last run on the Wednesday of week 3 and the first back on the
        // Wednesday of week 6: weeks 4 and 5 (14 days) plus Thursday to Sunday
        // before and Monday and Tuesday after, 20 days: longer than 14.
        var h = weeks([240, 240, 240], prefix: "h")
        h += runs(3, days: [0, 2], minutes: 240, prefix: "h")
        let back = runs(6, days: [2, 4], minutes: 157, prefix: "p")
        XCTAssertEqual(weekly(check(h, back)).allowedRounded, [156 * m])
        // One break week only is a short break (7 + 2 days here), unchanged.
        let oneWeek = weeks([240, 240, 240, 240, 0], prefix: "o")
        let after = runs(5, days: [2, 4], minutes: 169, prefix: "p")
        XCTAssertEqual(weekly(check(oneWeek, after)).allowedRounded, [168 * m])
    }

    // MARK: Switches and limits

    func testTheLongerBreakReturnCanBeSwitchedOff() {
        let h = afterThreeWeeksOff
        let off = GuardrailLimits(longerBreakReturnSteps: [])
        XCTAssertTrue(weekly(check(h, weeks([300], start: 7, prefix: "p"), limits: off)).isEmpty)
        let noRamp = GuardrailLimits(maxShortBreakWeeks: 0)
        XCTAssertTrue(weekly(check(h, weeks([300], start: 7, prefix: "p"), limits: noRamp)).isEmpty)
    }

    func testInvalidStepsFallBackToTheDefault() {
        let d = GuardrailLimits.default.longerBreakReturnSteps
        XCTAssertEqual(d, [0.65, 0.825, 1.0])
        XCTAssertEqual(GuardrailLimits(longerBreakReturnSteps: [.nan, 1]).longerBreakReturnSteps, d)
        XCTAssertEqual(GuardrailLimits(longerBreakReturnSteps: [-0.1]).longerBreakReturnSteps, d)
        XCTAssertEqual(GuardrailLimits(longerBreakReturnSteps: []).longerBreakReturnSteps, [])
        var l = GuardrailLimits()
        l.longerBreakReturnSteps = [.infinity]
        XCTAssertEqual(l.longerBreakReturnSteps, d)
    }

    func testAZeroStepOrNonFiniteVolumeNeverTraps() {
        // A step of 0 holds the week at 0 (every run is over it), without a trap.
        let zero = GuardrailLimits(longerBreakReturnSteps: [0, 0, 0])
        _ = check(afterThreeWeeksOff, weeks([100], start: 7, prefix: "p"), limits: zero)
        let nan = [PlannedWorkout(id: "n", date: F.date(week: 7, day: 1), kind: .easy, durationSeconds: .nan)]
        let r = check(afterThreeWeeksOff, nan)
        XCTAssertTrue(weekly(r).isEmpty)
    }

    // MARK: The plan builder's ledger reads the return the same way

    private func ledger(_ minutes: [Double], plannedFrom: Int = .max) -> PlanBuilder.LoadLedger {
        PlanBuilder.LoadLedger(volumes: minutes.map { $0 * m }, limits: .default, plannedFrom: plannedFrom)
    }

    func testTheLedgerCapsFollowTheSteps() {
        let brk: [Double] = [240, 240, 240, 240, 0, 0, 0]
        XCTAssertEqual(ledger(brk).nextCap, 156 * m, accuracy: 1e-6)
        XCTAssertEqual(ledger(brk + [156]).nextCap, 198 * m, accuracy: 1e-6)
        XCTAssertEqual(ledger(brk + [156, 198]).nextCap, 240 * m, accuracy: 1e-6)
        // The return ended with the 240: the plain 10% (264) is the weekly
        // cap, and the rolling window is the 654 of the spec's example.
        XCTAssertEqual(ledger(brk + [156, 198, 240]).nextCap, 264 * m, accuracy: 1e-6)
        // A restart: 156 then 160 (short of 165): step 1, raised to 160.
        XCTAssertEqual(ledger(brk + [156, 160]).nextCap, 160 * m, accuracy: 1e-6)
        XCTAssertEqual(ledger(brk + [120]).nextCap, 156 * m, accuracy: 1e-6)
    }

    func testTheLedgerQuality() {
        let brk: [Double] = [240, 240, 240, 240, 0, 0, 0]
        XCTAssertEqual(ledger(brk).nextReturnRampMaxQuality, 0)
        XCTAssertEqual(ledger(brk + [156]).nextReturnRampMaxQuality, 1)
        XCTAssertNil(ledger(brk + [156, 198]).nextReturnRampMaxQuality)
    }

    func testTheLedgerReadsTheRollingWindowOfTheSecondExample() {
        // 240 x4, 0, 0, 0, 96 x4 as history; planned weeks 156, 198, 236 are
        // after `plannedFrom` (never short). The next week's rolling cap is
        // 658 (the weekly cap is the plain 236 x 1.1 = 259.6).
        let hist: [Double] = [240, 240, 240, 240, 0, 0, 0, 96, 96, 96, 96, 156, 198, 236]
        let l = ledger(hist, plannedFrom: 11)
        XCTAssertEqual(l.nextCap, min(236 * 1.1, 658) * m, accuracy: 1e-6)
        var loose = PlanBuilder.LoadLedger(volumes: hist.map { $0 * m }, limits: GuardrailLimits(maxWeeklyIncrease: 10), plannedFrom: 11)
        XCTAssertEqual(loose.nextCap, 658 * m, accuracy: 1e-6)
        // The same weeks as history only: each of the planned ones was run
        // at its step (156 and 198 and 236 vs 240 / 1.2 = 200: not short).
        loose.plannedFrom = .max
        XCTAssertEqual(loose.nextCap, 658 * m, accuracy: 1e-6)
    }

    func testTheLedgerReadsADayCountedBreak() {
        // The ledger takes the days-off flag from the builder; with it, two
        // break weeks return by the lower of the ramp (168) and the step (156).
        var l = PlanBuilder.LoadLedger(volumes: [240, 240, 240, 240, 0, 0].map { $0 * m }, limits: .default)
        XCTAssertEqual(l.nextCap, 168 * m, accuracy: 1e-6)
        l.longerByDays = [4]
        XCTAssertEqual(l.nextCap, 156 * m, accuracy: 1e-6)
    }

    // MARK: Rule 4 baselines must not move

    func testNoBreakAndShortBreakWeeksAreUnchanged() {
        // No break: the plain 10%.
        let steady = weeks([240, 240, 240, 240], prefix: "h")
        XCTAssertEqual(weekly(check(steady, weeks([265], start: 4, prefix: "p"))).allowedRounded, [264 * m])
        // A one-week break: week 1 back at 70% (168), as on main.
        let one = weeks([240, 240, 240, 240, 0], prefix: "h")
        XCTAssertEqual(weekly(check(one, weeks([169], start: 5, prefix: "p"))).allowedRounded, [168 * m])
        // A two-week break of exactly 14 days (Sunday to Monday): 70%, 90%, 100%.
        let two = weeks([240, 240, 240, 240, 0, 0], prefix: "h")
        XCTAssertEqual(weekly(check(two, weeks([169], start: 6, prefix: "p"))).allowedRounded, [168 * m])
        // Week 2 back: 90% of 240 = 216, and the ramp's own rise over the
        // 168 run, 168 x 0.9 / 0.7 = 216 as well.
        let second = weekly(check(two + weeks([168], start: 6, prefix: "h"), weeks([217], start: 7, prefix: "p")))
        XCTAssertEqual(second.first?.allowed ?? 0, 216 * m, accuracy: 1e-6)
    }
}

private extension Array where Element == GuardrailViolation {
    /// The allowed volumes, rounded to a millionth, so floating-point noise
    /// (264 x 60 = 15840.000000000002) doesn't hide an exact match.
    var allowedRounded: [Double] { map { ($0.allowed * 1e6).rounded() / 1e6 } }
}
