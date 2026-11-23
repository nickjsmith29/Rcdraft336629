import XCTest
@testable import CoachCore

// SPEC 3.5 rule 7's pure rules (#73): usual pain, the next-morning trigger,
// the end path, the return steps and the clinician flag. Synthetic values only.
final class PainRecoveryRuleTests: XCTestCase {
    typealias F = AdaptFixture
    let L = PainRecoveryLimits.default

    func sample(_ day: Int, _ score: Int) -> UsualPainSample {
        UsualPainSample(date: F.date(week: 0, day: day), score: score)
    }

    // MARK: Usual pain

    func testMedianRoundsAHalfPointDown() {
        XCTAssertNil(UsualPain.median([]))
        XCTAssertEqual(UsualPain.median([3]), 3)
        XCTAssertEqual(UsualPain.median([1, 2]), 1)            // 1.5 rounds down
        XCTAssertEqual(UsualPain.median([3, 1, 2]), 2)
        XCTAssertEqual(UsualPain.median([1, 2, 3, 4]), 2)      // 2.5 rounds down
        XCTAssertEqual(UsualPain.median([2, 2, 3, 3]), 2)
        XCTAssertEqual(UsualPain.median([4, 4, 5, 5]), 4)
        XCTAssertEqual(UsualPain.median([0, 10]), 5)
        XCTAssertEqual(UsualPain.median([-1, 11, 4]), 4, "scores outside 0...10 are ignored")
        XCTAssertNil(UsualPain.median([-1, 11]))
    }

    func testUsualIsZeroWithoutAPainHistory() {
        XCTAssertEqual(UsualPain.value(samples: [sample(0, 5), sample(1, 5), sample(2, 5)], seed: 4, tracksPain: false), 0)
    }

    func testUsualIsTheSeedUntilThreeStableCheckIns() {
        XCTAssertEqual(UsualPain.value(samples: [], seed: 3, tracksPain: true), 3)
        XCTAssertEqual(UsualPain.value(samples: [sample(0, 1), sample(1, 1)], seed: 3, tracksPain: true), 3)
        XCTAssertEqual(UsualPain.value(samples: [sample(0, 1), sample(1, 1), sample(2, 2)], seed: 3, tracksPain: true), 1)
        // A seed outside 0...10, or none, starts at 0 (the strictest level).
        XCTAssertEqual(UsualPain.value(samples: [], seed: 11, tracksPain: true), 0)
        XCTAssertEqual(UsualPain.value(samples: [], seed: -1, tracksPain: true), 0)
        XCTAssertEqual(UsualPain.value(samples: [], seed: nil, tracksPain: true), 0)
        XCTAssertEqual(UsualPain.value(samples: [], seed: 0, tracksPain: true), 0)
        XCTAssertEqual(UsualPain.value(samples: [], seed: 10, tracksPain: true), 10)
    }

    func testUsualUsesAllCheckInsWhileThreeOrFourThenTheLastFive() {
        let four = [sample(0, 1), sample(1, 2), sample(2, 3), sample(3, 4)]
        XCTAssertEqual(UsualPain.value(samples: four, seed: 0, tracksPain: true), 2)   // 2.5 rounds down
        let six = four + [sample(4, 4), sample(5, 4)]   // last five: 2, 3, 4, 4, 4
        XCTAssertEqual(UsualPain.value(samples: six, seed: 0, tracksPain: true), 4)
        // Order of the samples doesn't matter: the latest five by date count.
        XCTAssertEqual(UsualPain.value(samples: six.reversed(), seed: 0, tracksPain: true), 4)
        // Invalid samples are ignored (NaN date, score outside 0...10).
        let bad = [UsualPainSample(date: Date(timeIntervalSinceReferenceDate: .nan), score: 1), sample(6, 11), sample(7, -2)]
        XCTAssertEqual(UsualPain.value(samples: bad + [sample(0, 2), sample(1, 2)], seed: 5, tracksPain: true), 5)
    }

    // MARK: Next-morning trigger

    func morning(_ score: Int?, pain: Bool = false, at date: Date? = nil) -> PainReport {
        PainReport(date: date ?? F.date(week: 0, day: 2, hour: 6), timing: .nextMorning, hasPain: pain, score: score)
    }

    func testNextMorningBoundaries() {
        typealias V = NextMorningRule.Verdict
        func v(_ score: Int?, usual: Int, hours: Double? = 22, pain: Bool = false) -> V {
            NextMorningRule.verdict(morning(score, pain: pain), usual: usual, hoursSinceRun: hours)
        }
        // At or below usual: nothing.
        XCTAssertEqual(v(2, usual: 2), .none)
        XCTAssertEqual(v(0, usual: 0), .none)
        XCTAssertEqual(v(1, usual: 2, hours: 100), .none, "at or below usual is never a trigger, however late")
        // usual + 1 freezes; usual + 2 stops.
        XCTAssertEqual(v(3, usual: 2), .freeze)
        XCTAssertEqual(v(4, usual: 2), .stop)
        XCTAssertEqual(v(1, usual: 0), .freeze)
        XCTAssertEqual(v(2, usual: 0), .stop)
        // 4/10 or more stops even at usual + 1.
        XCTAssertEqual(v(4, usual: 3), .stop)
        XCTAssertEqual(v(5, usual: 4), .stop)
        XCTAssertEqual(v(4, usual: 4), .stop, "4/10 or more stops even at usual (rule 7 as written)")
        // 48 hours after the run, anything above usual stops.
        XCTAssertEqual(v(3, usual: 2, hours: 47.99), .freeze)
        XCTAssertEqual(v(3, usual: 2, hours: 48), .stop)
        XCTAssertEqual(v(3, usual: 2, hours: nil), .freeze, "no known run: the 48-hour limit can't apply")
        XCTAssertEqual(v(3, usual: 2, hours: .infinity), .freeze, "a non-finite time is ignored")
        XCTAssertEqual(v(3, usual: 2, hours: .nan), .freeze)
        // Pain of unknown size is read as a stop; no pain at all is nothing.
        XCTAssertEqual(v(nil, usual: 5, pain: true), .stop)
        XCTAssertEqual(v(nil, usual: 0, pain: false), .none)
        XCTAssertEqual(v(11, usual: 2, pain: false), .none, "an invalid score with no pain is no pain")
        // An after-run report or a NaN date is never judged here.
        let after = PainReport(date: F.date(week: 0, day: 1), timing: .afterRun, hasPain: true, score: 9)
        XCTAssertEqual(NextMorningRule.verdict(after, usual: 0, hoursSinceRun: 1), .none)
        let nan = PainReport(date: Date(timeIntervalSinceReferenceDate: .nan), timing: .nextMorning, hasPain: true, score: 9)
        XCTAssertEqual(NextMorningRule.verdict(nan, usual: 0, hoursSinceRun: 1), .none)
    }

    func testStopTriggersCombineEveryRule() {
        let r = PainReport(date: F.date(week: 0, day: 2, hour: 6), timing: .nextMorning, hasPain: true, worsenedDuringRun: true,
                           changedMovement: true, score: 6, redFlags: [.swelling])
        XCTAssertEqual(r.stopTriggers(usual: 2, hoursSinceRun: 10),
                       [.worsenedDuringRun, .changedMovement, .stillThereNextMorning, .redFlag])
        XCTAssertEqual(morning(3).stopTriggers(usual: 2, hoursSinceRun: 10), [])
        XCTAssertEqual(morning(3).stopTriggers(usual: 2, hoursSinceRun: 50), [.stillThereNextMorning])
        XCTAssertEqual(PainStopRule.mode(for: [.redFlag]), .rest)
        XCTAssertEqual(PainStopRule.mode(for: [.lastingAboveUsual]), .easyOnly)
        XCTAssertEqual(PainStopRule.mode(for: [.recurredInReturn]), .easyOnly)
    }

    func testRisingOverSuccessiveWeeks() {
        func m(_ week: Int, _ score: Int) -> PainReport { morning(score, at: F.date(week: week, day: 2, hour: 6)) }
        let asOf = F.date(week: 2, day: 6)
        XCTAssertTrue(NextMorningRule.risingOverWeeks([m(0, 1), m(1, 2), m(2, 3)], asOf: asOf, timeZone: F.tz))
        XCTAssertFalse(NextMorningRule.risingOverWeeks([m(0, 1), m(1, 2), m(2, 2)], asOf: asOf, timeZone: F.tz), "flat is not rising")
        XCTAssertFalse(NextMorningRule.risingOverWeeks([m(0, 3), m(1, 2), m(2, 3)], asOf: asOf, timeZone: F.tz))
        XCTAssertFalse(NextMorningRule.risingOverWeeks([m(0, 1), m(2, 3)], asOf: asOf, timeZone: F.tz), "a week with no report breaks it")
        XCTAssertFalse(NextMorningRule.risingOverWeeks([m(0, 1), m(1, 2), m(2, 3)], asOf: F.date(week: 2, day: 0), timeZone: F.tz),
                       "reports after asOf are ignored")
        // The week's highest score counts.
        XCTAssertTrue(NextMorningRule.risingOverWeeks([m(0, 1), m(1, 0), m(1, 2), m(2, 3)], asOf: asOf, timeZone: F.tz))
        XCTAssertFalse(NextMorningRule.risingOverWeeks([], asOf: asOf, timeZone: F.tz))
    }

    // MARK: Ending a stop

    func walkMorning(day: Int, _ score: Int?, walking: Int?, moved: Bool = false, flags: [PainRedFlag] = [],
                     hour: Int = 6) -> PainReport {
        PainReport(date: F.date(week: 0, day: day, hour: hour), timing: .nextMorning, hasPain: (score ?? 1) > 0,
                   changedMovement: moved, score: score, walkingScore: walking, redFlags: flags)
    }

    func testTwoMorningsInARowAtOrBelowUsualWithWalkingAtTwoOrLess() {
        let from = F.date(week: 0, day: 1, hour: 9)
        func ready(_ r: [PainReport], usual: Int = 2) -> Date? {
            PainStopEndRule.readySince(reports: r, from: from, usual: usual, timeZone: F.tz)
        }
        XCTAssertEqual(ready([walkMorning(day: 2, 2, walking: 2), walkMorning(day: 3, 1, walking: 0)]), F.date(week: 0, day: 3, hour: 6))
        XCTAssertNil(ready([walkMorning(day: 2, 2, walking: 2)]), "one morning is not enough")
        XCTAssertNil(ready([walkMorning(day: 2, 2, walking: 2), walkMorning(day: 4, 2, walking: 2)]), "a missed day restarts the count")
        XCTAssertNil(ready([walkMorning(day: 2, 3, walking: 2), walkMorning(day: 3, 2, walking: 2)]), "a morning above usual")
        XCTAssertNil(ready([walkMorning(day: 2, 2, walking: 3), walkMorning(day: 3, 2, walking: 2)]), "walking at 3")
        XCTAssertNil(ready([walkMorning(day: 2, 2, walking: nil), walkMorning(day: 3, 2, walking: 2)]), "walking unknown")
        XCTAssertNil(ready([walkMorning(day: 2, 2, walking: 11), walkMorning(day: 3, 2, walking: 2)]), "walking outside 0...10")
        XCTAssertNil(ready([walkMorning(day: 2, 2, walking: 0, moved: true), walkMorning(day: 3, 2, walking: 0)]))
        XCTAssertNil(ready([walkMorning(day: 2, 2, walking: 0, flags: [.sharpPain]), walkMorning(day: 3, 2, walking: 0)]))
        XCTAssertNil(ready([walkMorning(day: 2, nil, walking: 0), walkMorning(day: 3, 2, walking: 0)]), "pain of unknown size")
        // The latest mornings decide: a bad one after two good ones restarts it.
        XCTAssertNil(ready([walkMorning(day: 2, 2, walking: 2), walkMorning(day: 3, 2, walking: 2), walkMorning(day: 4, 3, walking: 2)]))
        XCTAssertNotNil(ready([walkMorning(day: 2, 3, walking: 2), walkMorning(day: 3, 2, walking: 2), walkMorning(day: 4, 2, walking: 2)]))
        // Two reports on one day count as the worse of them.
        XCTAssertNil(ready([walkMorning(day: 2, 2, walking: 2), walkMorning(day: 3, 1, walking: 0),
                            walkMorning(day: 3, 3, walking: 0, hour: 10)]))
        // Only mornings after `from` count; after-run reports never do.
        XCTAssertNil(ready([walkMorning(day: 1, 0, walking: 0, hour: 9), walkMorning(day: 2, 0, walking: 0)]))
        let afterRun = PainReport(date: F.date(week: 0, day: 3, hour: 6), timing: .afterRun, hasPain: false, score: 0, walkingScore: 0)
        XCTAssertNil(ready([walkMorning(day: 2, 0, walking: 0), afterRun]))
        XCTAssertNil(ready([]))
        // Usual 0 needs mornings at 0.
        XCTAssertNil(ready([walkMorning(day: 2, 1, walking: 0), walkMorning(day: 3, 1, walking: 0)], usual: 0))
        XCTAssertNotNil(ready([walkMorning(day: 2, 0, walking: 0), walkMorning(day: 3, 0, walking: 0)], usual: 0))
    }

    func testTestRunLength() {
        XCTAssertEqual(PainStopEndRule.testSeconds(usualEasySeconds: nil), 20 * 60)
        XCTAssertEqual(PainStopEndRule.testSeconds(usualEasySeconds: 80 * 60), 30 * 60)
        XCTAssertEqual(PainStopEndRule.testSeconds(usualEasySeconds: 60 * 60), 30 * 60)
        XCTAssertEqual(PainStopEndRule.testSeconds(usualEasySeconds: 50 * 60), 25 * 60)
        XCTAssertEqual(PainStopEndRule.testSeconds(usualEasySeconds: 30 * 60), 15 * 60, "half a usual easy run when that is shorter")
        XCTAssertEqual(PainStopEndRule.testSeconds(usualEasySeconds: 12 * 60), 10 * 60, "never below the minimum")
        for bad in [0, -60, Double.nan, .infinity] {
            XCTAssertEqual(PainStopEndRule.testSeconds(usualEasySeconds: bad), 20 * 60)
        }
    }

    func testTestRunLimits() {
        func pass(_ score: Int?, usual: Int, movementStop: Bool = false, worsened: Bool = false, moved: Bool = false,
                  flags: [PainRedFlag] = []) -> Bool {
            let r = PainReport(date: F.date(week: 0, day: 3, hour: 8), timing: .afterRun, hasPain: (score ?? 1) > 0,
                               worsenedDuringRun: worsened, changedMovement: moved, score: score, redFlags: flags)
            return PainStopEndRule.inRunPasses(r, usual: usual, stopFromMovement: movementStop)
        }
        XCTAssertTrue(pass(3, usual: 2))
        XCTAssertFalse(pass(4, usual: 3), "never above 3/10")
        XCTAssertTrue(pass(3, usual: 3))
        XCTAssertTrue(pass(2, usual: 1))
        XCTAssertFalse(pass(3, usual: 1), "at most usual + 1")
        XCTAssertTrue(pass(1, usual: 0))
        XCTAssertFalse(pass(2, usual: 0))
        XCTAssertTrue(pass(0, usual: 0))
        XCTAssertTrue(pass(3, usual: 2, worsened: true), "pain that got worse is judged only by the limits")
        XCTAssertFalse(pass(0, usual: 2, moved: true))
        XCTAssertFalse(pass(0, usual: 2, flags: [.numbnessOrTingling]))
        XCTAssertFalse(pass(nil, usual: 2), "pain of unknown size fails")
        // After a movement-change stop, pain must stay at or below usual.
        XCTAssertTrue(pass(2, usual: 2, movementStop: true))
        XCTAssertFalse(pass(3, usual: 2, movementStop: true))
    }

    // MARK: The return

    func testReturnCeilings() {
        XCTAssertEqual(PainReturnRule.planVolumeStep(), 3)
        XCTAssertEqual(PainReturnRule.ceilingFraction(step: 1, daysOff: nil), 0.65)
        XCTAssertEqual(PainReturnRule.ceilingFraction(step: 0, daysOff: nil), 0.65)
        XCTAssertEqual(PainReturnRule.ceilingFraction(step: -3, daysOff: 10), 0.65)
        XCTAssertEqual(PainReturnRule.ceilingFraction(step: 2, daysOff: nil)!, 0.825, accuracy: 1e-12)
        XCTAssertEqual(PainReturnRule.ceilingFraction(step: 2, daysOff: 3)!, 0.825, accuracy: 1e-12)
        XCTAssertEqual(PainReturnRule.ceilingFraction(step: 2, daysOff: 10)!, 0.825, accuracy: 1e-12, "the lower of regrowth and the ramp")
        XCTAssertNil(PainReturnRule.ceilingFraction(step: 3, daysOff: 10))
        XCTAssertNil(PainReturnRule.ceilingFraction(step: 9, daysOff: nil))
        // When rule 4's week-2 step is lower, it wins, but only for 6 to 14 days off.
        var l = PainRecoveryLimits()
        l.rampWeek2Fraction = 0.8
        XCTAssertEqual(PainReturnRule.ceilingFraction(step: 2, daysOff: 6, limits: l), 0.8)
        XCTAssertEqual(PainReturnRule.ceilingFraction(step: 2, daysOff: 14, limits: l), 0.8)
        XCTAssertEqual(PainReturnRule.ceilingFraction(step: 2, daysOff: 5, limits: l)!, 0.825, accuracy: 1e-12)
        XCTAssertEqual(PainReturnRule.ceilingFraction(step: 2, daysOff: 15, limits: l)!, 0.825, accuracy: 1e-12)
        // A one-week regrowth still waits for rule 4's week 3.
        l = PainRecoveryLimits()
        l.regrowthWeeks = 1
        XCTAssertEqual(PainReturnRule.planVolumeStep(l), 3)
        XCTAssertNil(PainReturnRule.ceilingFraction(step: 2, daysOff: nil, limits: l))
        l.regrowthWeeks = 3
        XCTAssertEqual(PainReturnRule.planVolumeStep(l), 4)
        XCTAssertEqual(PainReturnRule.ceilingFraction(step: 3, daysOff: nil, limits: l)!, 0.65 + 0.35 * 2 / 3, accuracy: 1e-12)
        // A week-1 share that isn't a finite number is stored as its default (#133).
        l.week1Fraction = .nan
        XCTAssertEqual(l.week1Fraction, PainRecoveryLimits.default.week1Fraction)
        XCTAssertEqual(PainReturnRule.ceilingFraction(step: 1, daysOff: nil, limits: l), 0.65)
    }

    func testReturnSymptoms() {
        func s(_ level: Int?, step: Int, usual: Int, moved: Bool = false) -> Bool {
            PainReturnRule.symptoms(level: level, changedMovement: moved, step: step, usual: usual)
        }
        // Week 1 allows usual + 1, at most 3/10.
        XCTAssertFalse(s(3, step: 1, usual: 2))
        XCTAssertTrue(s(4, step: 1, usual: 2))
        XCTAssertTrue(s(4, step: 1, usual: 3), "above 3/10")
        XCTAssertFalse(s(1, step: 1, usual: 0))
        XCTAssertTrue(s(2, step: 1, usual: 0))
        // Later, anything above usual.
        XCTAssertFalse(s(2, step: 2, usual: 2))
        XCTAssertTrue(s(3, step: 2, usual: 2))
        XCTAssertTrue(s(1, step: 3, usual: 0))
        XCTAssertTrue(s(0, step: 2, usual: 2, moved: true))
        XCTAssertTrue(s(nil, step: 2, usual: 5))
    }

    func testReturnStepsRunInPlanWeeks() {
        let w0 = PlanCalendar.weekStart(containing: F.date(week: 0, day: 0), timeZone: F.tz)
        let w1 = PlanCalendar.weekStart(containing: F.date(week: 1, day: 0), timeZone: F.tz)
        let w3 = PlanCalendar.weekStart(containing: F.date(week: 3, day: 0), timeZone: F.tz)
        let r = PainReturn(start: F.date(week: 0, day: 4), level: 100, preStopLongRun: 30, daysOff: 2, fromMovement: false,
                           step: 1, stepWeek: w1)
        XCTAssertEqual(r.step(atWeek: w0, timeZone: F.tz), 1, "the part week before stepWeek takes the step")
        XCTAssertEqual(r.step(atWeek: w1, timeZone: F.tz), 1)
        XCTAssertEqual(r.step(atWeek: PlanCalendar.weekStart(containing: F.date(week: 2, day: 0), timeZone: F.tz), timeZone: F.tz), 2)
        XCTAssertEqual(r.step(atWeek: w3, timeZone: F.tz), 3)
        XCTAssertEqual(r.step(atWeek: PlanCalendar.weekStart(containing: F.date(week: 9, day: 0), timeZone: F.tz), timeZone: F.tz), 3,
                       "capped at full plan volume")
        XCTAssertEqual(r.planVolumeWeek(timeZone: F.tz), w3)
        var back = r
        back.step = 2
        back.stepWeek = w3
        XCTAssertEqual(back.planVolumeWeek(timeZone: F.tz), PlanCalendar.weekStart(containing: F.date(week: 4, day: 0), timeZone: F.tz))
    }

    // MARK: Clinician flag and coding

    func testFlagClearsOnlyWithThreeReportsAndAPassedTest() {
        XCTAssertFalse(ClinicianFlag(raisedAt: F.date(week: 0, day: 0), reasons: [.redFlag], streak: 9).clears())
        XCTAssertFalse(ClinicianFlag(raisedAt: F.date(week: 0, day: 0), reasons: [.redFlag], streak: 2, streakHasPassedTest: true).clears())
        XCTAssertTrue(ClinicianFlag(raisedAt: F.date(week: 0, day: 0), reasons: [.redFlag], streak: 3, streakHasPassedTest: true).clears())
    }

    func testRecoveryStateAndOldReportsDecode() throws {
        let rec = PainRecovery(usualSamples: [sample(0, 2)], frozenUsual: 2, countFrom: F.date(week: 0, day: 1),
                               test: PainTestRun(workoutID: "e0a", offeredAt: F.date(week: 0, day: 3), seconds: 1200,
                                                 activityID: "run-e0a", ranAt: F.date(week: 0, day: 3), inRunPassed: true),
                               cannotEnd: true, stopFromMovement: true, preStopLongRun: 3600, flaggedThisStop: true,
                               painReturn: PainReturn(start: F.date(week: 0, day: 4), level: 100, preStopLongRun: 30, daysOff: nil,
                                                      fromMovement: true, step: 2, stepWeek: F.date(week: 1, day: 0),
                                                      failedSteps: [2], restDay: F.date(week: 1, day: 2, hour: 0)),
                               flag: ClinicianFlag(raisedAt: F.date(week: 0, day: 0), reasons: [.redFlag, .reopened], streak: 1,
                                                   lastReport: F.date(week: 0, day: 2), askedAt: nil),
                               flagEnded: ClinicianFlagEnd(date: F.date(week: 0, day: 0), how: .closedUnresolved))
        let back = try JSONDecoder().decode(PainRecovery.self, from: try JSONEncoder().encode(rec))
        XCTAssertEqual(back, rec)
        XCTAssertEqual(try JSONDecoder().decode(PainRecovery.self, from: Data("{}".utf8)), PainRecovery())
        // A report stored before the walking score and red flags existed.
        let old = #"{"date":100,"timing":"nextMorning","hasPain":true,"worsenedDuringRun":false,"changedMovement":false}"#
        let r = try JSONDecoder().decode(PainReport.self, from: Data(old.utf8))
        XCTAssertEqual(r, PainReport(date: Date(timeIntervalSinceReferenceDate: 100), timing: .nextMorning, hasPain: true))
        let full = PainReport(date: Date(timeIntervalSinceReferenceDate: 100), timing: .nextMorning, hasPain: true, score: 3,
                              walkingScore: 1, redFlags: [.cannotBearWeight, .lastingMovementChange])
        XCTAssertEqual(try JSONDecoder().decode(PainReport.self, from: try JSONEncoder().encode(full)), full)
        XCTAssertThrowsError(try JSONDecoder().decode(PainReport.self, from: Data(#"{"date":1,"timing":"x","hasPain":true}"#.utf8)))
    }

    func testPainLevelAndAboveUsual() {
        let none = PainReport(date: F.date(week: 0, day: 0), timing: .afterRun, hasPain: false)
        XCTAssertEqual(none.painLevel, 0)
        XCTAssertFalse(none.isAbove(usual: 0))
        let unknown = PainReport(date: F.date(week: 0, day: 0), timing: .afterRun, hasPain: true)
        XCTAssertNil(unknown.painLevel)
        XCTAssertTrue(unknown.isAbove(usual: 10), "unknown size is read as above usual")
        let flagged = PainReport(date: F.date(week: 0, day: 0), timing: .afterRun, hasPain: false, redFlags: [.swelling])
        XCTAssertTrue(flagged.isPain)
        XCTAssertEqual(PainReport(date: F.date(week: 0, day: 0), timing: .afterRun, hasPain: true, score: 2).painLevel, 2)
        XCTAssertNil(PainReport(date: F.date(week: 0, day: 0), timing: .afterRun, hasPain: false, walkingScore: -1).validWalkingScore)
    }

    func testLastingPainCountsOnlyAboveUsualAndAfterTheLastFlag() {
        func r(_ day: Int, _ score: Int) -> PainReport {
            PainReport(date: F.date(week: 0, day: 0, hour: 12).addingTimeInterval(Double(day) * 86_400), timing: .afterRun,
                       hasPain: score > 0, score: score)
        }
        let daily2 = (0...7).map { r($0, 2) }
        XCTAssertNotNil(PainStopRule.lastingPain(reports: daily2, checkIns: [], asOf: F.date(week: 2, day: 0), timeZone: F.tz))
        XCTAssertNil(PainStopRule.lastingPain(reports: daily2, checkIns: [], asOf: F.date(week: 2, day: 0), timeZone: F.tz, usual: 2),
                     "pain at usual is not lasting pain")
        XCTAssertNotNil(PainStopRule.lastingPain(reports: daily2, checkIns: [], asOf: F.date(week: 2, day: 0), timeZone: F.tz, usual: 1))
        XCTAssertNil(PainStopRule.lastingPain(reports: daily2, checkIns: [], asOf: F.date(week: 2, day: 0), timeZone: F.tz, usual: 1,
                                              after: F.date(week: 0, day: 2)), "only reports after the last flag count")
        // A report at usual ends the stretch.
        XCTAssertNil(PainStopRule.lastingPain(reports: daily2 + [r(8, 1)], checkIns: [], asOf: F.date(week: 2, day: 0),
                                              timeZone: F.tz, usual: 1))
    }

    func testTheReturnReferenceIsTheLevelOrALowerPrePlanWeek() {
        let w0 = PlanFixture.date(week: 0, day: 0, hour: 0), w1 = PlanFixture.date(week: 1, day: 0, hour: 0)
        let w2 = PlanFixture.date(week: 2, day: 0, hour: 0)
        let r = PainReturn(start: w0, level: 200, preStopLongRun: nil, daysOff: nil, fromMovement: false, stepWeek: w0,
                           planWeeks: [PlanWeekVolume(week: w0, volume: 250), PlanWeekVolume(week: w1, volume: 150),
                                       PlanWeekVolume(week: w2, volume: 0)])
        XCTAssertEqual(r.reference(forWeek: w0), 200, "a plan week above the level: the level")
        XCTAssertEqual(r.reference(forWeek: w1), 150, "a recovery week planned lower: the plan week")
        XCTAssertEqual(r.reference(forWeek: w2), 200, "a week planned at 0 doesn't lower it")
        XCTAssertEqual(r.reference(forWeek: PlanFixture.date(week: 3, day: 0, hour: 0)), 200, "not recorded: the level")
        for bad in [nil, 0, -1, Double.nan, .infinity] as [Double?] {
            let n = PainReturn(start: w0, level: bad, preStopLongRun: nil, daysOff: nil, fromMovement: false, stepWeek: w0)
            XCTAssertNil(n.reference(forWeek: w0), "no known level: no week can count")
        }
    }
}
