import XCTest
@testable import CoachCore

final class PainCheckInTests: XCTestCase {
    private let utc = PlanFixture.utc
    private typealias F = PlanFixture

    private func checkIn(day: Int, _ score: Int) -> PainCheckIn {
        PainCheckIn(date: F.date(week: 0, day: 0, hour: 9).addingTimeInterval(Double(day) * 86_400), score: score)
    }

    /// Quality sessions on days 1, 4 and 8, easy runs between.
    private let plan: [PlannedWorkout] = [
        F.workout("q-early", week: 0, day: 1, .quality(.tempo), minutes: 50),
        F.workout("easy", week: 0, day: 2, .easy, minutes: 40),
        F.workout("q-next", week: 0, day: 4, .quality(.intervals), minutes: 55, km: 11),
        F.workout("long", week: 0, day: 6, .long, minutes: 100),
        F.workout("q-later", week: 1, day: 1, .quality(.hills), minutes: 50)
    ]

    /// `asOf` defaults to an hour after the latest check-in.
    private func evaluate(_ checkIns: [PainCheckIn], tracks: Bool = true, plan: [PlannedWorkout]? = nil,
                          asOf: Date? = nil, applied: Date? = nil) -> PainCheckInOutcome {
        let now = asOf ?? (checkIns.map(\.date).max() ?? F.firstMonday).addingTimeInterval(3600)
        return PainCheckInRule.evaluate(tracksPain: tracks, checkIns: checkIns, plan: plan ?? self.plan,
                                        asOf: now, lastAppliedCheckIn: applied, timeZone: utc)
    }

    private func at(day: Int, hour: Int = 9) -> Date {
        F.date(week: 0, day: 0, hour: hour).addingTimeInterval(Double(day) * 86_400)
    }

    private func response(_ outcome: PainCheckInOutcome, file: StaticString = #filePath, line: UInt = #line) throws -> PainResponse {
        guard case .act(let r) = outcome else {
            XCTFail("expected an action, got \(outcome)", file: file, line: line)
            throw XCTSkip("no action")
        }
        return r
    }

    // MARK: Tracking flag

    func testUntrackedPainNeverFires() {
        XCTAssertEqual(evaluate([checkIn(day: 1, 9)], tracks: false), .notTracked)
        XCTAssertEqual(evaluate([checkIn(day: 1, 0), checkIn(day: 2, 10)], tracks: false), .notTracked)
        XCTAssertEqual(evaluate([], tracks: false), .notTracked)
    }

    func testTrackedWithoutValidCheckIns() {
        XCTAssertEqual(evaluate([]), .noCheckIns)
        XCTAssertEqual(evaluate([checkIn(day: 1, -1), checkIn(day: 2, 11)]), .noCheckIns)
    }

    // MARK: Score threshold (4)

    func testScoreThreeDoesNotFire() {
        XCTAssertEqual(evaluate([checkIn(day: 3, 3)]), .noAction)
    }

    func testScoreFourFires() throws {
        let r = try response(evaluate([checkIn(day: 3, 4)]))
        XCTAssertEqual(r.triggers, [.scoreAtOrAbove(threshold: 4)])
        XCTAssertEqual(r.checkIn.score, 4)
    }

    func testHighButFallingScoreStillFires() throws {
        let r = try response(evaluate([checkIn(day: 1, 8), checkIn(day: 3, 5)]))
        XCTAssertEqual(r.triggers, [.scoreAtOrAbove(threshold: 4)])
    }

    // MARK: Rise (2)

    func testRiseOfTwoFires() throws {
        let r = try response(evaluate([checkIn(day: 1, 1), checkIn(day: 3, 3)]))
        XCTAssertEqual(r.triggers, [.rise(previous: 1, rise: 2)])
    }

    func testRiseOfOneDoesNotFire() {
        XCTAssertEqual(evaluate([checkIn(day: 1, 1), checkIn(day: 3, 2)]), .noAction)
    }

    func testBothTriggers() throws {
        let r = try response(evaluate([checkIn(day: 1, 2), checkIn(day: 3, 5)]))
        XCTAssertEqual(r.triggers, [.scoreAtOrAbove(threshold: 4), .rise(previous: 2, rise: 3)])
    }

    func testOnlyTheLatestCheckInCounts() {
        // An earlier spike is past; the latest check-in is low and flat.
        XCTAssertEqual(evaluate([checkIn(day: 0, 1), checkIn(day: 1, 6), checkIn(day: 2, 2), checkIn(day: 3, 2)]), .noAction)
    }

    func testInputOrderDoesNotMatterAndInvalidScoresAreSkipped() throws {
        // Sorted: 1 (day 1), [12 ignored], 3 (day 3) → rise of 2.
        let r = try response(evaluate([checkIn(day: 3, 3), checkIn(day: 2, 12), checkIn(day: 1, 1)]))
        XCTAssertEqual(r.triggers, [.rise(previous: 1, rise: 2)])
    }

    // MARK: Action

    func testFreezesSevenDaysAndSwapsNextQuality() throws {
        let c = checkIn(day: 3, 5)
        let r = try response(evaluate([c]))
        XCTAssertEqual(r.freezeStart, c.date)
        XCTAssertEqual(r.freezeEnd.timeIntervalSince(c.date), 7 * 86_400)
        let swap = try XCTUnwrap(r.swap)
        XCTAssertEqual(swap.original.id, "q-next")
        XCTAssertEqual(swap.replacement.kind, .easy)
        XCTAssertEqual(swap.replacement.id, "q-next")
        XCTAssertEqual(swap.replacement.durationSeconds, 55 * 60)
        XCTAssertTrue(r.explanation.contains("2026-01-09"), r.explanation) // the swapped session's day
        XCTAssertTrue(r.explanation.contains("not a diagnosis"), r.explanation)
        XCTAssertFalse(r.suggestClinician)
    }

    func testNoQualityAheadMeansNoSwap() throws {
        let r = try response(evaluate([checkIn(day: 3, 6)], plan: plan.filter { !$0.kind.isQuality }))
        XCTAssertNil(r.swap)
        XCTAssertTrue(r.explanation.contains("none is swapped"), r.explanation)
    }

    func testFreezeDaysAreConfigurable() throws {
        let outcome = PainCheckInRule.evaluate(tracksPain: true, checkIns: [checkIn(day: 3, 4)], plan: plan,
                                               asOf: at(day: 3, hour: 10), lastAppliedCheckIn: nil,
                                               timeZone: utc, limits: PainRuleLimits(freezeDays: 10))
        XCTAssertEqual(try response(outcome).freeze.duration, 10 * 86_400)
    }

    func testPersistentPainSuggestsClinician() throws {
        let r = try response(evaluate([checkIn(day: 0, 4), checkIn(day: 2, 5), checkIn(day: 3, 4)]))
        XCTAssertTrue(r.suggestClinician)
        XCTAssertTrue(r.explanation.contains("clinician"), r.explanation)
    }

    func testBrokenStreakDoesNotSuggestClinician() throws {
        let r = try response(evaluate([checkIn(day: 0, 5), checkIn(day: 2, 2), checkIn(day: 3, 5)]))
        XCTAssertFalse(r.suggestClinician)
    }

    func testFreezeFeedsTheGuardrailChecker() throws {
        // The response's freeze makes the checker reject growth in the following week.
        let r = try response(evaluate([checkIn(day: 6, 5)]))
        let report = GuardrailChecker.check(history: F.easyWeek(0, minutes: 300, prefix: "h"),
                                            planned: F.easyWeek(1, minutes: 320, prefix: "p"),
                                            timeZone: utc, freezes: [r.freeze])
        XCTAssertEqual(report.violations.map(\.rule), [.volumeFreeze])
    }

    // MARK: Acting once per check-in

    func testReEvaluatingAfterApplyingGivesNoSecondSwap() throws {
        let c = checkIn(day: 3, 5)
        let r = try response(evaluate([c]))
        let swap = try XCTUnwrap(r.swap)
        let applied = plan.map { $0.id == swap.original.id ? swap.replacement : $0 }
        // Same check-in, plan already changed, later in the freeze: nothing more to do.
        XCTAssertEqual(evaluate([c], plan: applied, asOf: at(day: 5), applied: c.date), .noAction)
    }

    func testANewCheckInAfterTheAppliedOneActsAgain() throws {
        let first = checkIn(day: 3, 5)
        let second = checkIn(day: 5, 6)
        let r = try response(evaluate([first, second], applied: first.date))
        XCTAssertEqual(r.checkIn, second)
        XCTAssertEqual(r.swap?.original.id, "q-later")
    }

    func testStaleCheckInAfterTheFreezeGivesNothing() throws {
        let c = checkIn(day: 3, 6)
        XCTAssertEqual(evaluate([c], asOf: at(day: 10)), .noAction) // exactly 7 days later: freeze over
        XCTAssertEqual(evaluate([c], asOf: at(day: 20)), .noAction)
        _ = try response(evaluate([c], asOf: at(day: 10).addingTimeInterval(-60)))
    }

    func testPastQualitySessionIsNotReplacedByALaterOne() throws {
        // q-next (day 4) is already past at day 5: freeze only, and q-later is never swapped.
        let r = try response(evaluate([checkIn(day: 3, 5)], asOf: at(day: 5)))
        XCTAssertNil(r.swap)
        XCTAssertTrue(r.explanation.contains("already passed"), r.explanation)
    }

    func testCheckInsAfterAsOfAreIgnored() {
        XCTAssertEqual(evaluate([checkIn(day: 3, 2), checkIn(day: 5, 8)], asOf: at(day: 4)), .noAction)
        XCTAssertEqual(evaluate([checkIn(day: 5, 8)], asOf: at(day: 4)), .noCheckIns)
    }
}
