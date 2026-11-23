import XCTest
@testable import CoachCore

final class GoalInterviewTests: XCTestCase {
    let today = GoalFixture.today
    let tz = GoalFixture.timeZone

    func testBaselineAnswersAreNeverAsked() {
        let interview = GoalInterview(baseline: GoalFixture.fixtureReport())
        XCTAssertEqual(interview.pendingQuestions,
                       [.raceName, .raceDate, .raceDistance, .goalTime, .maxSessionLength, .painHistory])
        XCTAssertEqual(interview.source(of: .trainingDays), .baseline)
        XCTAssertEqual(interview.source(of: .longRunDay), .baseline)
        XCTAssertEqual(interview.source(of: .treadmillAccess), .baseline)
        XCTAssertEqual(interview.trainingDays, GoalFixture.fixtureDays)
        XCTAssertEqual(interview.longRunDay, .sunday)
        XCTAssertEqual(interview.hasTreadmillAccess, true)
    }

    func testWithNoDataEveryQuestionIsAskedInOrder() {
        let interview = GoalInterview(facts: .none, timeZone: tz)
        XCTAssertEqual(interview.pendingQuestions, GoalQuestion.allCases)
        XCTAssertEqual(interview.nextQuestion, .raceName)
        XCTAssertFalse(interview.isComplete)
        XCTAssertEqual(interview.result(today: today), .incomplete(GoalQuestion.allCases))
    }

    func testOneQuestionAtATimeUntilComplete() {
        var interview = GoalInterview(baseline: GoalFixture.fixtureReport())
        let race = GoalFixture.raceDay(weeksAhead: 14)
        let script: [GoalQuestion: GoalAnswer] = [
            .raceName: .raceName("  Synthetic Half "),
            .raceDate: .raceDate(race),
            .raceDistance: .raceDistance(meters: Distance.halfMarathon),
            .goalTime: .goalTime(.seconds(6600)),
            .maxSessionLength: .maxSessionLength(.seconds(120 * 60)),
            .painHistory: .painHistory(.recurring(areas: [" left knee ", ""])),
        ]
        var asked: [GoalQuestion] = []
        while let q = interview.nextQuestion {
            asked.append(q)
            XCTAssertEqual(interview.pendingQuestions.first, q)
            XCTAssertEqual(interview.answer(script[q]!, today: today), .accepted(cleared: []))
            XCTAssertLessThan(asked.count, 10, "the interview must end")
        }
        XCTAssertEqual(asked, [.raceName, .raceDate, .raceDistance, .goalTime, .maxSessionLength, .painHistory])
        XCTAssertTrue(interview.isComplete)
        let expected = GoalSettings(
            race: GoalRace(name: "Synthetic Half", date: race, distanceMeters: Distance.halfMarathon, time: .seconds(6600)),
            schedule: TrainingSchedule(trainingDays: GoalFixture.fixtureDays, longRunDay: .sunday, maxSession: .seconds(7200)),
            hasTreadmillAccess: true, painHistory: .recurring(areas: ["left knee"]))
        XCTAssertEqual(interview.result(today: today), .complete(expected))
    }

    func testAnswersAlreadyGivenAreSkipped() {
        var interview = GoalInterview(facts: .none, timeZone: tz, answers: GoalAnswers(raceName: "Synthetic 10K", treadmillAccess: false))
        XCTAssertEqual(interview.nextQuestion, .raceDate)
        XCTAssertFalse(interview.pendingQuestions.contains(.raceName))
        XCTAssertFalse(interview.pendingQuestions.contains(.treadmillAccess))
        // An answer out of order (the runner gave the distance early) is not asked again.
        interview.answer(.raceDistance(meters: Distance.tenK), today: today)
        interview.answer(.raceDate(GoalFixture.raceDay(weeksAhead: 10)), today: today)
        XCTAssertEqual(interview.nextQuestion, .goalTime)
        XCTAssertFalse(interview.pendingQuestions.contains(.raceDistance))
        XCTAssertEqual(interview.source(of: .raceDistance), .runner)
    }

    func testSavedSettingsResumeComplete() {
        let s = GoalFixture.settings()
        let interview = GoalInterview(facts: .none, timeZone: tz, answers: GoalAnswers(settings: s))
        XCTAssertTrue(interview.isComplete)
        XCTAssertEqual(interview.result(today: today), .complete(s))
    }

    func testRunnerAnswersOverrideTheBaseline() {
        var interview = GoalInterview(baseline: GoalFixture.fixtureReport())
        XCTAssertEqual(interview.answer(.trainingDays([.monday, .wednesday, .friday, .saturday]), today: today),
                       .accepted(cleared: []))
        XCTAssertEqual(interview.source(of: .trainingDays), .runner)
        // The baseline's Sunday long run is no longer a training day, so it is asked.
        XCTAssertNil(interview.longRunDay)
        XCTAssertTrue(interview.pendingQuestions.contains(.longRunDay))
        XCTAssertEqual(interview.answer(.longRunDay(.sunday), today: today), .rejected(.longRunDayNotATrainingDay))
        XCTAssertEqual(interview.answer(.longRunDay(.saturday), today: today), .accepted(cleared: []))
        XCTAssertEqual(interview.longRunDay, .saturday)
        interview.answer(.treadmillAccess(false), today: today)
        XCTAssertEqual(interview.hasTreadmillAccess, false)
        XCTAssertEqual(interview.source(of: .treadmillAccess), .runner)
    }

    func testInvalidAnswersAreRejectedAndStayOpen() {
        var i = GoalInterview(facts: .none, timeZone: tz)
        XCTAssertEqual(i.answer(.raceName("   "), today: today), .rejected(.emptyRaceName))
        XCTAssertEqual(i.answer(.raceDate(today), today: today), .rejected(.raceDateNotAfterToday))
        XCTAssertEqual(i.answer(.raceDate(today.addingTimeInterval(-86_400)), today: today), .rejected(.raceDateNotAfterToday))
        for meters in [3000.0, 50_000, .nan, .infinity, -5000, 0] {
            guard case .rejected(.unsupportedDistance) = i.answer(.raceDistance(meters: meters), today: today) else {
                return XCTFail("distance \(meters) should be refused")
            }
        }
        for s in [Double.nan, .infinity, 0, -60] {
            XCTAssertEqual(i.answer(.goalTime(.seconds(s)), today: today), .rejected(.invalidGoalTime))
        }
        XCTAssertEqual(i.answer(.trainingDays([.monday, .friday]), today: today),
                       .rejected(.tooFewTrainingDays(count: 2, minimum: PlanHeuristics.minimumTrainingDays)))
        XCTAssertEqual(i.answer(.trainingDays([]), today: today),
                       .rejected(.tooFewTrainingDays(count: 0, minimum: PlanHeuristics.minimumTrainingDays)))
        XCTAssertEqual(i.answer(.maxSessionLength(.seconds(30 * 60)), today: today),
                       .rejected(.sessionLimitTooShort(seconds: 1800, minimumSeconds: PlanHeuristics.minimumSessionSeconds)))
        XCTAssertEqual(i.answer(.maxSessionLength(.seconds(.nan)), today: today), .rejected(.invalidSessionLimit))
        XCTAssertEqual(i.answer(.maxSessionLength(.seconds(-1)), today: today), .rejected(.invalidSessionLimit))
        XCTAssertEqual(i.answer(.painHistory(.recurring(areas: [])), today: today), .rejected(.noPainArea))
        XCTAssertEqual(i.answer(.painHistory(.recurring(areas: [" ", "\n"])), today: today), .rejected(.noPainArea))
        XCTAssertEqual(i.pendingQuestions, GoalQuestion.allCases, "nothing rejected was saved")

        // Boundaries that pass.
        XCTAssertEqual(i.answer(.raceDistance(meters: Distance.fiveK), today: today), .accepted(cleared: []))
        XCTAssertEqual(i.answer(.maxSessionLength(.seconds(PlanHeuristics.minimumSessionSeconds)), today: today), .accepted(cleared: []))
        XCTAssertEqual(i.answer(.maxSessionLength(.noLimit), today: today), .accepted(cleared: []))
        XCTAssertEqual(i.answer(.trainingDays([.monday, .wednesday, .friday]), today: today), .accepted(cleared: []))
        XCTAssertEqual(i.answer(.painHistory(.none), today: today), .accepted(cleared: []))
        XCTAssertEqual(i.answer(.goalTime(.bestPossible), today: today), .accepted(cleared: []))
    }

    func testGoalTimeMustBePlausibleForTheDistance() {
        var i = GoalInterview(facts: .none, timeZone: tz)
        i.answer(.raceDistance(meters: Distance.tenK), today: today)
        // 10 km in 10 minutes is 16.7 m/s.
        XCTAssertEqual(i.answer(.goalTime(.seconds(600)), today: today),
                       .rejected(.implausibleGoalTime(seconds: 600, distanceMeters: Distance.tenK)))
        // 10 km in 4 hours is 0.69 m/s, slower than a walk.
        XCTAssertEqual(i.answer(.goalTime(.seconds(4 * 3600)), today: today),
                       .rejected(.implausibleGoalTime(seconds: 14_400, distanceMeters: Distance.tenK)))
        XCTAssertEqual(i.answer(.goalTime(.seconds(50 * 60)), today: today), .accepted(cleared: []))
    }

    func testNewDistanceClearsAGoalTimeThatNoLongerFits() {
        var i = GoalInterview(facts: .none, timeZone: tz)
        // Goal time before the distance: only the number is checked.
        XCTAssertEqual(i.answer(.goalTime(.seconds(20 * 60)), today: today), .accepted(cleared: []))
        XCTAssertEqual(i.answer(.raceDistance(meters: Distance.fiveK), today: today), .accepted(cleared: []))
        XCTAssertEqual(i.answers.goalTime, .seconds(1200))
        // A marathon in 20 minutes is impossible, so the goal time is asked again.
        XCTAssertEqual(i.answer(.raceDistance(meters: Distance.marathon), today: today), .accepted(cleared: [.goalTime]))
        XCTAssertNil(i.answers.goalTime)
        XCTAssertTrue(i.pendingQuestions.contains(.goalTime))
        // "Best possible" fits any distance.
        i.answer(.goalTime(.bestPossible), today: today)
        XCTAssertEqual(i.answer(.raceDistance(meters: Distance.fiveK), today: today), .accepted(cleared: []))
    }

    func testNewTrainingDaysClearALongRunDayOutsideThem() {
        var i = GoalInterview(facts: .none, timeZone: tz)
        // A long-run day given before any training days is kept for now.
        XCTAssertEqual(i.answer(.longRunDay(.sunday), today: today), .accepted(cleared: []))
        XCTAssertEqual(i.answer(.trainingDays([.monday, .wednesday, .friday]), today: today),
                       .accepted(cleared: [.longRunDay]))
        XCTAssertNil(i.longRunDay)
        XCTAssertEqual(i.answer(.longRunDay(.friday), today: today), .accepted(cleared: []))
        XCTAssertEqual(i.answer(.trainingDays([.monday, .wednesday, .friday, .sunday]), today: today),
                       .accepted(cleared: []))
        XCTAssertEqual(i.longRunDay, .friday)
    }

    func testSavedAnswersAreCheckedAgainOnTheDay() {
        let s = GoalFixture.settings(weeksAhead: 8)
        let interview = GoalInterview(facts: .none, timeZone: tz, answers: GoalAnswers(settings: s))
        XCTAssertEqual(interview.result(today: today), .complete(s))
        let afterRace = s.race.date.addingTimeInterval(3600)
        XCTAssertEqual(interview.result(today: afterRace), .invalid([.raceDateNotAfterToday]))
    }

    func testSettingsProblemsListEveryIssue() {
        var s = GoalFixture.settings()
        s.race.name = ""
        s.race.distanceMeters = 1000
        s.schedule.trainingDays = [.monday, .tuesday]
        s.schedule.longRunDay = .sunday
        s.schedule.maxSession = .seconds(10 * 60)
        s.painHistory = .recurring(areas: [])
        XCTAssertEqual(s.problems(today: today, timeZone: tz), [
            .emptyRaceName, .unsupportedDistance(meters: 1000),
            .tooFewTrainingDays(count: 2, minimum: PlanHeuristics.minimumTrainingDays),
            .longRunDayNotATrainingDay,
            .sessionLimitTooShort(seconds: 600, minimumSeconds: PlanHeuristics.minimumSessionSeconds),
            .noPainArea,
        ])
        XCTAssertEqual(GoalFixture.settings().problems(today: today, timeZone: tz), [])
        XCTAssertTrue(GoalFixture.settings(pain: .recurring(areas: ["calf"])).painHistory.tracksPain)
        XCTAssertFalse(GoalFixture.settings().painHistory.tracksPain)
    }
    func testRaceDateMustBeFiniteAndInsideThePlanLeadTime() {
        var i = GoalInterview(facts: .none, timeZone: tz)
        for t in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(i.answer(.raceDate(Date(timeIntervalSinceReferenceDate: t)), today: today), .rejected(.invalidRaceDate))
        }
        // No distance yet: the shortest minimum of any distance (the 5K's 4 weeks).
        XCTAssertEqual(i.answer(.raceDate(GoalFixture.raceDay(weeksAhead: 3)), today: today),
                       .rejected(.leadTimeTooShort(weeks: 3, minimumWeeks: 4)))
        XCTAssertEqual(i.answer(.raceDate(GoalFixture.raceDay(weeksAhead: 53)), today: today),
                       .rejected(.leadTimeTooLong(weeks: 53, maximumWeeks: PlanHeuristics.maximumWeeks)))
        XCTAssertEqual(i.answer(.raceDate(GoalFixture.raceDay(weeksAhead: 52)), today: today), .accepted(cleared: []))
        XCTAssertEqual(i.answer(.raceDate(GoalFixture.raceDay(weeksAhead: 5)), today: today), .accepted(cleared: []))

        // A half needs 6 weeks: the 5-week date is cleared and asked again.
        XCTAssertEqual(i.answer(.raceDistance(meters: Distance.halfMarathon), today: today), .accepted(cleared: [.raceDate]))
        XCTAssertNil(i.answers.raceDate)
        XCTAssertEqual(i.answer(.raceDate(GoalFixture.raceDay(weeksAhead: 5)), today: today),
                       .rejected(.leadTimeTooShort(weeks: 5, minimumWeeks: 6)))
        XCTAssertEqual(i.answer(.raceDate(GoalFixture.raceDay(weeksAhead: 6)), today: today), .accepted(cleared: []))
        XCTAssertEqual(i.answer(.raceDistance(meters: Distance.tenK), today: today), .accepted(cleared: []))
    }

    func testLeadTimeCountsWeeksLikeThePlanBuilder() throws {
        // Parity with PlanBuilder's own lead-time check, at both edges for every distance.
        let report = GoalFixture.fixtureReport()
        let nextMonday = PlanCalendar.nextWeekStart(after: PlanCalendar.weekStart(containing: today, timeZone: tz), timeZone: tz)
        // From Wednesday noon, and from a Monday at 09:00 (whose own week counts).
        for start in [today, nextMonday.addingTimeInterval(9 * 3600)] {
        for c in RaceCategory.allCases {
            let meters: Double = [.fiveK: Distance.fiveK, .tenK: Distance.tenK,
                                  .half: Distance.halfMarathon, .marathon: Distance.marathon][c]!
            for weeks in [PlanHeuristics.minimumWeeks(c) - 1, PlanHeuristics.minimumWeeks(c),
                          PlanHeuristics.maximumWeeks, PlanHeuristics.maximumWeeks + 1] {
                let s = GoalFixture.settings(distance: meters, weeksAhead: weeks)
                let refusedHere = s.problems(today: start, timeZone: tz).contains {
                    if case .leadTimeTooShort = $0 { return true }
                    if case .leadTimeTooLong = $0 { return true }
                    return false
                }
                let input = BaselinePlanMapping.planInput(settings: s, baseline: report, startDate: start)
                let issues = PlanBuilder.build(input, history: BaselinePlanMapping.planHistory(from: report),
                                               timeZone: tz).issues
                let refusedThere = issues.contains {
                    if case .leadTimeTooShort = $0 { return true }
                    if case .leadTimeTooLong = $0 { return true }
                    return false
                }
                XCTAssertEqual(refusedHere, refusedThere, "\(c) \(weeks) weeks from \(start): \(issues)")
            }
        }
        }
        // A Monday no later than noon counts its own week; after noon it doesn't.
        let monday = PlanCalendar.nextWeekStart(after: PlanCalendar.weekStart(containing: today, timeZone: tz), timeZone: tz)
        let sunday = monday.addingTimeInterval(6 * 86_400 + 8 * 3600)
        XCTAssertEqual(GoalValidation.planWeeks(today: monday.addingTimeInterval(9 * 3600), race: sunday, timeZone: tz), 1)
        XCTAssertEqual(GoalValidation.planWeeks(today: monday.addingTimeInterval(12 * 3600), race: sunday, timeZone: tz), 1)
        XCTAssertEqual(GoalValidation.planWeeks(today: monday.addingTimeInterval(13 * 3600), race: sunday, timeZone: tz), 0)
    }
}
