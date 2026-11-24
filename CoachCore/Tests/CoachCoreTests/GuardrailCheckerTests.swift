import XCTest
@testable import CoachCore

final class GuardrailCheckerTests: XCTestCase {
    private let utc = PlanFixture.utc
    private typealias F = PlanFixture

    private func check(history: [Double], planned: [Double], limits: GuardrailLimits = .default,
                       freezes: [DateInterval] = []) -> GuardrailReport {
        GuardrailChecker.check(history: F.easyWeeks(history, prefix: "h"),
                               planned: F.easyWeeks(planned, start: history.count, prefix: "p"),
                               timeZone: utc, limits: limits, freezes: freezes)
    }

    private func violations(_ r: GuardrailReport, _ rule: GuardrailRule) -> [GuardrailViolation] {
        r.violations.filter { $0.rule == rule }
    }

    private func skips(_ r: GuardrailReport, _ rule: GuardrailRule) -> [GuardrailSkip] {
        r.notEvaluated.filter { $0.rule == rule }
    }

    // MARK: General

    func testEmptyPlanPassesWithNothingChecked() {
        let r = GuardrailChecker.check(history: F.easyWeeks([300, 300]), planned: [], timeZone: utc)
        XCTAssertTrue(r.passed)
        XCTAssertTrue(r.notEvaluated.isEmpty)
    }

    func testHistoryWeeksAreContextNotChecked() {
        // Three quality sessions in a past week are not reported; only planned weeks are.
        let history = [
            F.workout("h1", week: 0, day: 1, .quality(.tempo), minutes: 50),
            F.workout("h2", week: 0, day: 3, .quality(.intervals), minutes: 50),
            F.workout("h3", week: 0, day: 5, .quality(.hills), minutes: 50)
        ]
        let r = GuardrailChecker.check(history: history, planned: F.easyWeek(1, minutes: 150), timeZone: utc)
        XCTAssertTrue(violations(r, .qualitySessions).isEmpty)
    }

    func testExplanationsNameTheWeekAndTheHeuristic() throws {
        let r = check(history: [300], planned: [340])
        let v = try XCTUnwrap(violations(r, .weeklyIncrease).first)
        XCTAssertTrue(v.explanation.contains("Week of 2026-01-12"), v.explanation)
        XCTAssertTrue(v.explanation.contains("Heuristic"), v.explanation)
        XCTAssertTrue(v.explanation.contains("10%"), v.explanation)
    }

    // MARK: Week over week (10%)

    func testExactlyTenPercentPasses() {
        XCTAssertTrue(violations(check(history: [300], planned: [330]), .weeklyIncrease).isEmpty)
    }

    func testJustOverTenPercentFails() throws {
        let v = try XCTUnwrap(violations(check(history: [300], planned: [331]), .weeklyIncrease).first)
        XCTAssertEqual(v.measured, 331 * 60, accuracy: 1e-6)
        XCTAssertEqual(v.allowed, 330 * 60, accuracy: 1e-6)
        XCTAssertEqual(v.unit, .seconds)
        XCTAssertEqual(v.weekStart, F.date(week: 1, day: 0, hour: 0))
    }

    func testDecreaseAndFlatPass() {
        XCTAssertTrue(violations(check(history: [300], planned: [300, 250]), .weeklyIncrease).isEmpty)
    }

    func testReturnAfterRecoveryWeekComparesWithWeekBeforeIt() {
        // 300, recovery 240 (exactly 80%), then 330 = +10% over 300: passes.
        XCTAssertTrue(violations(check(history: [300, 240], planned: [330]), .weeklyIncrease).isEmpty)
    }

    func testOvershootAfterRecoveryWeekFails() throws {
        let v = try XCTUnwrap(violations(check(history: [300, 240], planned: [340]), .weeklyIncrease).first)
        XCTAssertEqual(v.allowed, 330 * 60, accuracy: 1e-6)
        XCTAssertTrue(v.explanation.contains("recovery week"), v.explanation)
    }

    func testNotARecoveryWeekWhenAboveEightyPercent() {
        // 300 then 241 (80.3%) is not a recovery week, so 330 is compared with 241 and fails.
        XCTAssertEqual(violations(check(history: [300, 241], planned: [330]), .weeklyIncrease).count, 1)
    }

    func testFirstWeekWithoutHistoryIsNotEvaluated() {
        let r = check(history: [], planned: [300])
        XCTAssertTrue(violations(r, .weeklyIncrease).isEmpty)
        XCTAssertEqual(skips(r, .weeklyIncrease).count, 1)
    }

    func testZeroReferenceWeekIsNotEvaluated() {
        // Three empty weeks are a longer break (3.5 rule 4, SPEC 0.8, #32): the
        // plain 10% check would have no reference (a zero week), so week 1
        // back is bounded by its step instead, 65% of the pre-break 300.
        let history = F.easyWeek(0, minutes: 300, prefix: "h")
        let r = GuardrailChecker.check(history: history, planned: F.easyWeek(4, minutes: 400), timeZone: utc)
        XCTAssertEqual(violations(r, .weeklyIncrease).first?.allowed ?? 0, 0.65 * 300 * 60, accuracy: 1e-6)
        XCTAssertTrue(skips(r, .weeklyIncrease).isEmpty)
        // With the longer-break return off, the plain rules: the reference
        // (one step back past a zero week) is still zero, so not evaluated.
        let off = GuardrailChecker.check(history: history, planned: F.easyWeek(4, minutes: 400), timeZone: utc,
                                         limits: GuardrailLimits(longerBreakReturnSteps: []))
        XCTAssertTrue(violations(off, .weeklyIncrease).isEmpty)
        XCTAssertTrue(skips(off, .weeklyIncrease).first?.reason.contains("no volume") ?? false)
        // Two empty weeks, exactly 14 days off here (the last run on the
        // Sunday, the first back on a Monday), are a short break: the return ramp applies (#62).
        let short = GuardrailChecker.check(history: history, planned: F.easyWeek(3, minutes: 400), timeZone: utc)
        XCTAssertEqual(violations(short, .weeklyIncrease).first?.allowed ?? 0, 0.7 * 300 * 60, accuracy: 1e-6)
    }

    func testOneMissedWeekComparesWithTheWeekBeforeIt() {
        // With the return ramp switched off (3.5 rule 4's plain rules).
        let plain = GuardrailLimits(maxShortBreakWeeks: 0)
        let history = F.easyWeek(0, minutes: 300, prefix: "h")
        let ok = GuardrailChecker.check(history: history, planned: F.easyWeek(2, minutes: 330), timeZone: utc, limits: plain)
        XCTAssertTrue(violations(ok, .weeklyIncrease).isEmpty)
        let bad = GuardrailChecker.check(history: history, planned: F.easyWeek(2, minutes: 400), timeZone: utc, limits: plain)
        XCTAssertEqual(violations(bad, .weeklyIncrease).count, 1)
        // By default one missed week is a short break: week 1 back may hold
        // at most 70% of the pre-break week (#62).
        let ramp = GuardrailChecker.check(history: history, planned: F.easyWeek(2, minutes: 210), timeZone: utc)
        XCTAssertTrue(violations(ramp, .weeklyIncrease).isEmpty)
        let over = GuardrailChecker.check(history: history, planned: F.easyWeek(2, minutes: 211), timeZone: utc)
        XCTAssertEqual(violations(over, .weeklyIncrease).count, 1)
    }

    func testConfigurableWeeklyLimit() {
        let strict = GuardrailLimits(maxWeeklyIncrease: 0.05)
        XCTAssertEqual(violations(check(history: [300], planned: [320], limits: strict), .weeklyIncrease).count, 1)
        XCTAssertTrue(violations(check(history: [300], planned: [315], limits: strict), .weeklyIncrease).isEmpty)
    }

    // MARK: Rolling 4 weeks (30%)

    func testFourWeekTotalExactlyThirtyPercentPasses() {
        let r = check(history: [300, 300, 300, 300, 390, 390, 390], planned: [390])
        XCTAssertTrue(violations(r, .fourWeekIncrease).isEmpty)
        XCTAssertTrue(skips(r, .fourWeekIncrease).isEmpty)
    }

    func testFourWeekTotalOverThirtyPercentFails() throws {
        let r = check(history: [300, 300, 300, 300, 390, 390, 390], planned: [394])
        let v = try XCTUnwrap(violations(r, .fourWeekIncrease).first)
        XCTAssertEqual(v.measured, (390 * 3 + 394) * 60, accuracy: 1e-6)
        XCTAssertEqual(v.allowed, 1560 * 60, accuracy: 1e-6)
    }

    func testSteadyTenPercentGrowthWithoutRecoveryBreaksFourWeekRule() {
        // Every week passes the 10% rule, but four weeks of compounding growth do not.
        var totals: [Double] = [300]
        for _ in 1..<8 { totals.append(totals.last! * 1.1) }
        let r = check(history: Array(totals.prefix(7)), planned: [totals[7]])
        XCTAssertTrue(violations(r, .weeklyIncrease).isEmpty)
        XCTAssertEqual(violations(r, .fourWeekIncrease).count, 1)
    }

    func testBuildWithRecoveryWeeksPassesFourWeekRule() {
        // 3 build weeks at +10% then a recovery week, repeated: no false alarm.
        let r = check(history: [300, 330, 363, 290, 363, 399, 439], planned: [351])
        XCTAssertTrue(violations(r, .fourWeekIncrease).isEmpty)
    }

    func testFewerThanEightWeeksIsNotEvaluated() {
        let r = check(history: [300, 300, 300], planned: [300])
        XCTAssertEqual(skips(r, .fourWeekIncrease).count, 1)
        XCTAssertTrue(violations(r, .fourWeekIncrease).isEmpty)
    }

    // MARK: Long run share (35%)

    private func longRunWeek(longMinutes: Double, total: Double, km: (long: Double, easy: Double)? = nil) -> [PlannedWorkout] {
        let easy = (total - longMinutes) / 3
        return (0..<3).map { F.workout("e\($0)", week: 1, day: $0 * 2, .easy, minutes: easy, km: km?.easy) }
            + [F.workout("long", week: 1, day: 6, .long, minutes: longMinutes, km: km?.long)]
    }

    func testLongRunExactlyThirtyFivePercentPasses() {
        let r = GuardrailChecker.check(history: [], planned: longRunWeek(longMinutes: 140, total: 400), timeZone: utc)
        XCTAssertTrue(violations(r, .longRunShare).isEmpty)
    }

    func testLongRunOverThirtyFivePercentFails() throws {
        let r = GuardrailChecker.check(history: [], planned: longRunWeek(longMinutes: 141, total: 400), timeZone: utc)
        let v = try XCTUnwrap(violations(r, .longRunShare).first)
        XCTAssertEqual(v.measured, 141.0 / 400, accuracy: 1e-9)
        XCTAssertEqual(v.allowed, 0.35)
        XCTAssertEqual(v.unit, .fraction)
        XCTAssertTrue(v.explanation.contains("35%"), v.explanation)
    }

    func testLongRunShareIsOfWeeklyTimeEvenWhenVolumeIsDistance() {
        // SPEC 3.5 rule 5 states the share of weekly time. By time the long
        // run is 35%; by distance it would be 16 of 40 km = 40%. Both measures
        // read it in time, so neither flags it.
        let planned = longRunWeek(longMinutes: 140, total: 400, km: (long: 16, easy: 8))
        let byTime = GuardrailChecker.check(history: [], planned: planned, timeZone: utc)
        XCTAssertTrue(violations(byTime, .longRunShare).isEmpty)
        let byDistance = GuardrailChecker.check(history: [], planned: planned, timeZone: utc,
                                                limits: GuardrailLimits(measure: .distance))
        XCTAssertTrue(violations(byDistance, .longRunShare).isEmpty)
        // And a time share over the limit is flagged in distance mode too.
        let over = GuardrailChecker.check(history: [], planned: longRunWeek(longMinutes: 141, total: 400, km: (long: 10, easy: 10)),
                                          timeZone: utc, limits: GuardrailLimits(measure: .distance))
        let v = violations(over, .longRunShare).first
        XCTAssertEqual(v?.measured ?? 0, 141.0 / 400, accuracy: 1e-9)
        XCTAssertEqual(v?.unit, .fraction)
        XCTAssertTrue(v?.explanation.contains("weekly time") ?? false, v?.explanation ?? "")
    }

    func testMissingDistanceLeavesTheLongRunShareToTime() {
        // No distances at all: in distance mode the weekly volume is unknown,
        // but the share is read in time, so it is still checked (200 of 400 min).
        let planned = longRunWeek(longMinutes: 200, total: 400)
        let r = GuardrailChecker.check(history: [], planned: planned, timeZone: utc,
                                       limits: GuardrailLimits(measure: .distance))
        XCTAssertEqual(violations(r, .longRunShare).first?.measured ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertTrue(skips(r, .longRunShare).isEmpty)
        // A session of unknown time leaves the share not evaluated.
        var unknown = planned
        unknown[0].durationSeconds = .nan
        let u = GuardrailChecker.check(history: [], planned: unknown, timeZone: utc, limits: GuardrailLimits(measure: .distance))
        XCTAssertTrue(violations(u, .longRunShare).isEmpty)
        XCTAssertEqual(skips(u, .longRunShare).count, 1)
    }

    func testInvalidDurationIsNotEvaluated() {
        // A week with a session of unknown time is read at its known part
        // (#40): within the limits there, the rules are not evaluated.
        var planned = longRunWeek(longMinutes: 100, total: 400)
        planned[0].durationSeconds = .nan
        // A 100-minute run in the history keeps the spike rule (3.5 rule 1) out of it.
        let history = F.easyWeek(0, minutes: 300) + [F.workout("h-long", week: 0, day: 6, .long, minutes: 100)]
        let r = GuardrailChecker.check(history: history, planned: planned, timeZone: utc)
        XCTAssertTrue(r.passed)
        XCTAssertFalse(skips(r, .longRunShare).isEmpty)
        XCTAssertFalse(skips(r, .weeklyIncrease).isEmpty)
    }

    func testInvalidDurationIsFlaggedWhenTheKnownPartBreaksARule() {
        // At least 333 min known after 300 (over 330): a sure rise. The long
        // run's share has no upper bound on the week, so it is not evaluated.
        var planned = longRunWeek(longMinutes: 200, total: 400)
        planned[0].durationSeconds = .nan
        let r = GuardrailChecker.check(history: F.easyWeek(0, minutes: 300), planned: planned, timeZone: utc)
        XCTAssertFalse(violations(r, .weeklyIncrease).isEmpty)
        XCTAssertTrue(violations(r, .longRunShare).isEmpty)
        XCTAssertFalse(skips(r, .longRunShare).isEmpty)
    }

    // MARK: Recovery week cadence

    func testFourthBuildWeekInARowFails() throws {
        let r = check(history: [300, 310, 320], planned: [330])
        let v = try XCTUnwrap(violations(r, .recoveryWeek).first)
        XCTAssertEqual(v.measured, 4)
        XCTAssertEqual(v.allowed, 3)
        XCTAssertEqual(v.unit, .weeks)
    }

    func testRecoveryAsFourthWeekPasses() {
        XCTAssertTrue(violations(check(history: [300, 310, 320], planned: [256]), .recoveryWeek).isEmpty) // exactly 80%
    }

    func testRecoveryJustAboveEightyPercentFails() {
        XCTAssertEqual(violations(check(history: [300, 310, 320], planned: [257]), .recoveryWeek).count, 1)
    }

    func testRecoveryEveryThirdWeekPasses() {
        XCTAssertTrue(violations(check(history: [300, 330, 260], planned: [330, 360, 280, 360]), .recoveryWeek).isEmpty)
    }

    func testEveryWeekPastTheLimitIsReported() {
        let r = check(history: [], planned: [300, 300, 300, 300, 300])
        XCTAssertEqual(violations(r, .recoveryWeek).map(\.measured), [4, 5])
    }

    func testEmptyWeekCountsAsRecovery() {
        let history = F.easyWeeks([300, 300, 300], prefix: "h")
        let r = GuardrailChecker.check(history: history, planned: F.easyWeeks([300, 300], start: 4), timeZone: utc)
        XCTAssertTrue(violations(r, .recoveryWeek).isEmpty)
    }

    // MARK: Quality sessions (2 a week)

    private func qualityWeek(quality: Int, races: Int = 0) -> [PlannedWorkout] {
        var w = (0..<quality).map { F.workout("q\($0)", week: 0, day: $0, .quality(.threshold), minutes: 50) }
        w += (0..<races).map { F.workout("r\($0)", week: 0, day: 6 - $0, .race, minutes: 40) }
        return w
    }

    func testTwoQualitySessionsPass() {
        let r = GuardrailChecker.check(history: [], planned: qualityWeek(quality: 2), timeZone: utc)
        XCTAssertTrue(violations(r, .qualitySessions).isEmpty)
    }

    func testThreeQualitySessionsFail() throws {
        let r = GuardrailChecker.check(history: [], planned: qualityWeek(quality: 3), timeZone: utc)
        let v = try XCTUnwrap(violations(r, .qualitySessions).first)
        XCTAssertEqual(v.measured, 3)
        XCTAssertEqual(v.allowed, 2)
        XCTAssertEqual(v.unit, .sessions)
    }

    func testRaceCountsAsQualityByDefault() {
        let planned = qualityWeek(quality: 2, races: 1)
        XCTAssertEqual(violations(GuardrailChecker.check(history: [], planned: planned, timeZone: utc), .qualitySessions).count, 1)
        let lenient = GuardrailLimits(racesCountAsQuality: false)
        XCTAssertTrue(violations(GuardrailChecker.check(history: [], planned: planned, timeZone: utc, limits: lenient),
                                 .qualitySessions).isEmpty)
    }

    func testMidWeekReplanCountsDoneAndPlannedSessionsTogether() {
        let done = [F.workout("done-q", week: 0, day: 1, .quality(.tempo), minutes: 50)]
        let planned = [F.workout("p-q1", week: 0, day: 3, .quality(.intervals), minutes: 50),
                       F.workout("p-q2", week: 0, day: 5, .quality(.hills), minutes: 50)]
        let r = GuardrailChecker.check(history: done, planned: planned, timeZone: utc)
        XCTAssertEqual(violations(r, .qualitySessions).first?.measured, 3)
    }

    // MARK: Volume freeze (pain check-in)

    func testGrowthDuringFreezeFails() throws {
        let freeze = DateInterval(start: F.date(week: 0, day: 6), duration: 7 * 86_400)
        let r = check(history: [300], planned: [310], freezes: [freeze])
        let v = try XCTUnwrap(violations(r, .volumeFreeze).first)
        XCTAssertEqual(v.allowed, 300 * 60, accuracy: 1e-6)
        XCTAssertTrue(violations(r, .weeklyIncrease).isEmpty) // 3% is fine outside a freeze
    }

    func testHoldingVolumeDuringFreezePasses() {
        let freeze = DateInterval(start: F.date(week: 0, day: 6), duration: 7 * 86_400)
        XCTAssertTrue(violations(check(history: [300], planned: [300], freezes: [freeze]), .volumeFreeze).isEmpty)
    }

    func testFreezeOnlyAppliesToOverlappingWeeks() {
        // History 300, then planned 300 and 330 (+10%). A freeze inside week 1 leaves week 2 free...
        let week1 = DateInterval(start: F.date(week: 1, day: 0), duration: 3 * 86_400)
        let free = check(history: [300], planned: [300, 330], freezes: [week1])
        XCTAssertTrue(violations(free, .volumeFreeze).isEmpty)
        XCTAssertTrue(skips(free, .volumeFreeze).isEmpty)
        // ...while the same freeze moved into week 2 flags its rise.
        let week2 = DateInterval(start: F.date(week: 2, day: 0), duration: 3 * 86_400)
        XCTAssertEqual(violations(check(history: [300], planned: [300, 330], freezes: [week2]), .volumeFreeze).count, 1)
    }

    func testFreezeAfterRecoveryWeekHoldsToTheRecoveryVolume() throws {
        // 300, recovery 240, then a frozen week: the 10% rule would allow a return to 300,
        // but a freeze holds to last week's actual 240, so any rise flags.
        let freeze = DateInterval(start: F.date(week: 2, day: 0), duration: 7 * 86_400)
        let v = try XCTUnwrap(violations(check(history: [300, 240], planned: [241], freezes: [freeze]), .volumeFreeze).first)
        XCTAssertEqual(v.allowed, 240 * 60, accuracy: 1e-6)
        XCTAssertTrue(violations(check(history: [300, 240], planned: [240], freezes: [freeze]), .volumeFreeze).isEmpty)
    }

    func testSwappedWeekStaysEvaluableInDistanceMode() {
        let history = (0..<4).map { F.workout("h\($0)", week: 0, day: $0 * 2, .easy, minutes: 50, km: 10) }
        let quality = F.workout("q", week: 1, day: 2, .quality(.intervals), minutes: 50, km: 10)
        let planned = (0..<3).map { F.workout("p\($0)", week: 1, day: $0 * 2 + 1, .easy, minutes: 50, km: 10) }
            + [quality.swappedToEasy()]
        let r = GuardrailChecker.check(history: history, planned: planned, timeZone: utc,
                                       limits: GuardrailLimits(measure: .distance))
        XCTAssertTrue(skips(r, .weeklyIncrease).isEmpty)
        XCTAssertTrue(r.passed)
    }

    // MARK: Unknown volume and the recovery count

    func testUnknownVolumeWeekCountsAsABuildWeek() throws {
        var history = F.easyWeeks([300, 300, 300], prefix: "h")
        history[8].durationSeconds = .nan // week 2 has unknown volume (at least 225 min known)
        let r = GuardrailChecker.check(history: history, planned: F.easyWeeks([300, 300], start: 3), timeZone: utc)
        // Count: 1, 2, 3 (unknown: it may have been a build week, #40), 4, 5.
        let v = try XCTUnwrap(violations(r, .recoveryWeek).first)
        XCTAssertEqual(v.measured, 4)
        XCTAssertEqual(v.weekStart, F.date(week: 3, day: 0, hour: 0))
        // At most 80% of the known 225 min, week 3 is a recovery week whatever week 2 held.
        let rec = GuardrailChecker.check(history: history, planned: F.easyWeeks([180, 198], start: 3), timeZone: utc)
        XCTAssertTrue(violations(rec, .recoveryWeek).isEmpty)
        let over = GuardrailChecker.check(history: history, planned: F.easyWeeks([181], start: 3), timeZone: utc)
        XCTAssertFalse(violations(over, .recoveryWeek).isEmpty)
    }
}
