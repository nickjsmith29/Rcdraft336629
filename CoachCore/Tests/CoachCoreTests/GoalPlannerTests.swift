import XCTest
@testable import CoachCore

final class GoalPlannerTests: XCTestCase {
    let report = GoalFixture.fixtureReport()
    var today: Date { GoalFixture.today }

    func plan(_ s: GoalSettings, baseline: BaselineReport? = nil, today: Date? = nil,
              freezes: [DateInterval] = []) -> GoalPlanResult {
        GoalPlanner.plan(settings: s, baseline: baseline ?? report, today: today ?? self.today, freezes: freezes)
    }

    func assertGuardrailChecked(_ p: GoalPlan, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(p.guardrailReport.passed, file: file, line: line)
        XCTAssertTrue(p.plan.guardrailReport.passed, file: file, line: line)
        // The checker, run again from outside, agrees.
        let again = GuardrailChecker.check(history: p.history, planned: p.plan.workouts, timeZone: report.timeZone)
        XCTAssertTrue(again.passed, "\(again.violations)", file: file, line: line)
    }

    func testInterviewToPlan() throws {
        var interview = GoalInterview(baseline: report)
        interview.answer(.raceName("Synthetic Half"), today: today)
        interview.answer(.raceDate(GoalFixture.raceDay(weeksAhead: 14)), today: today)
        interview.answer(.raceDistance(meters: Distance.halfMarathon), today: today)
        interview.answer(.goalTime(.bestPossible), today: today)
        interview.answer(.maxSessionLength(.noLimit), today: today)
        interview.answer(.painHistory(.none), today: today)
        guard case .complete(let settings) = interview.result(today: today) else { return XCTFail("interview incomplete") }
        let p = try XCTUnwrap(plan(settings).plan, "\(plan(settings).issues)")
        assertGuardrailChecked(p)
        XCTAssertEqual(p.plan.category, .half)
        XCTAssertFalse(p.tracksPain)
        XCTAssertNil(p.input.goalSeconds)
        XCTAssertNotNil(p.input.fitnessAnchor)
        XCTAssertTrue(p.plan.workouts.allSatisfy { $0.date > today })
        XCTAssertTrue(p.history.allSatisfy { $0.date < today })
        XCTAssertEqual(p.plan.workouts.last?.kind, .race)
        // Sessions fall on the runner's days, the long run on the long-run day.
        for w in p.plan.workouts where w.kind != .race {
            XCTAssertTrue(GoalFixture.fixtureDays.contains(PlanWeekday(of: w.date, timeZone: report.timeZone)))
            if w.kind == .long { XCTAssertEqual(PlanWeekday(of: w.date, timeZone: report.timeZone), .sunday) }
        }
    }

    func testEveryDistanceAndGoalPlansWithinTheGuardrails() throws {
        let goals: [(Double, Int, GoalTime)] = [
            (Distance.fiveK, 8, .bestPossible), (Distance.fiveK, 10, .seconds(23 * 60)),
            (Distance.tenK, 12, .seconds(50 * 60)), (Distance.halfMarathon, 16, .seconds(6900)),
            (Distance.marathon, 20, .bestPossible),
        ]
        for (meters, weeks, time) in goals {
            let result = plan(GoalFixture.settings(distance: meters, weeksAhead: weeks, time: time))
            let p = try XCTUnwrap(result.plan, "\(meters) m: \(result.issues)")
            assertGuardrailChecked(p)
            XCTAssertEqual(p.plan.category, RaceCategory(meters: meters))
        }
    }

    func testGoalEditReplansFromTodayAndExplains() throws {
        let original = GoalFixture.settings(weeksAhead: 12)
        let first = try XCTUnwrap(plan(original).plan)
        // Two days later the runner moves the race three weeks back and sets a
        // time goal; the app rebuilds the baseline as of that moment.
        let later = today.addingTimeInterval(2 * 86_400)
        let current = GoalFixture.fixtureReport(asOf: later)
        var edited = original
        edited.race.date = GoalFixture.raceDay(weeksAhead: 15)
        edited.race.time = .seconds(6900)
        let replan = GoalPlanner.replan(from: original, previousPlan: first.plan, to: edited,
                                        baseline: current, today: later)
        let p = try XCTUnwrap(replan.result.plan, "\(replan.result.issues)")
        assertGuardrailChecked(p)
        XCTAssertEqual(replan.changes, [.raceDate(from: original.race.date, to: edited.race.date),
                                        .goalTime(from: .bestPossible, to: .seconds(6900))])
        XCTAssertEqual(p.input.startDate, later)
        XCTAssertEqual(p.input.goalSeconds, 6900)
        XCTAssertTrue(p.plan.workouts.allSatisfy { $0.date > later }, "nothing before today is re-planned")
        XCTAssertEqual(p.plan.weeks.first?.weekStart,
                       PlanCalendar.nextWeekStart(after: PlanCalendar.weekStart(containing: later, timeZone: report.timeZone),
                                                  timeZone: report.timeZone))
        XCTAssertEqual(PlanCalendar.weekStart(containing: try XCTUnwrap(p.plan.workouts.last).date, timeZone: report.timeZone),
                       PlanCalendar.weekStart(containing: edited.race.date, timeZone: report.timeZone))
        let summary = try XCTUnwrap(replan.planChanges)
        XCTAssertEqual(summary.previousWeeks, first.plan.weeks.count)
        XCTAssertEqual(summary.newWeeks, first.plan.weeks.count + 3)
        XCTAssertEqual(replan.explanation.count, 4)
        XCTAssertTrue(replan.explanation[0].hasPrefix("Race date moved from "))
        XCTAssertEqual(replan.explanation[1], "Goal changed from best possible to 1:55:00.")
        XCTAssertTrue(replan.explanation[2].contains("weeks to race day (was \(first.plan.weeks.count))"))
        XCTAssertEqual(replan.explanation[3], "Every week passes the load guardrails (SPEC 3.5).")
    }

    func testDistanceAndScheduleEditsReplan() throws {
        let original = GoalFixture.settings(weeksAhead: 12)
        let first = try XCTUnwrap(plan(original).plan)
        var edited = original
        edited.race.name = "Synthetic 10K"
        edited.race.distanceMeters = Distance.tenK
        edited.schedule = TrainingSchedule(trainingDays: [.monday, .wednesday, .friday, .saturday],
                                           longRunDay: .saturday, maxSession: .seconds(90 * 60))
        edited.painHistory = .recurring(areas: ["calf"])
        let replan = GoalPlanner.replan(from: original, previousPlan: first.plan, to: edited, baseline: report, today: today)
        let p = try XCTUnwrap(replan.result.plan, "\(replan.result.issues)")
        assertGuardrailChecked(p)
        XCTAssertEqual(p.plan.category, .tenK)
        XCTAssertTrue(p.tracksPain)
        XCTAssertEqual(replan.changes.count, 6)
        XCTAssertTrue(replan.explanation.contains("Race distance changed from 21.1 km to 10.0 km."))
        XCTAssertTrue(replan.explanation.contains("Long run moved from Sunday to Saturday."))
        XCTAssertTrue(replan.explanation.contains("Training days changed from Tuesday, Thursday, Saturday, Sunday to Monday, Wednesday, Friday, Saturday."))
        XCTAssertTrue(replan.explanation.contains("Longest session changed from no limit to 1 h 30 min."))
        XCTAssertTrue(replan.explanation.contains { $0.hasPrefix("Recurring pain reported (calf)") })
        // Training sessions fall on the new days (the race is on its own date, a Sunday).
        for w in p.plan.workouts where w.kind != .race {
            XCTAssertTrue(edited.schedule.trainingDays.contains(PlanWeekday(of: w.date, timeZone: report.timeZone)))
            XCTAssertLessThanOrEqual(w.durationSeconds, 90 * 60 + 1e-6)
        }
    }

    func testUnchangedSettingsStillReplanFromToday() throws {
        let s = GoalFixture.settings()
        let replan = GoalPlanner.replan(from: s, previousPlan: nil, to: s, baseline: report, today: today)
        XCTAssertEqual(replan.changes, [])
        XCTAssertNotNil(replan.result.plan)
        XCTAssertNil(replan.planChanges, "no previous plan to compare")
        XCTAssertEqual(replan.explanation.first, "No goal settings changed; the plan was rebuilt from today.")
    }

    func testEditThatCannotBeBuiltKeepsThePreviousPlan() throws {
        let original = GoalFixture.settings(weeksAhead: 12)
        let first = try XCTUnwrap(plan(original).plan)
        var edited = original
        edited.race.date = GoalFixture.raceDay(weeksAhead: 2)
        // Too close for a half: refused before building, with the reason.
        let tooClose = GoalPlanner.replan(from: original, previousPlan: first.plan, to: edited, baseline: report, today: today)
        XCTAssertEqual(tooClose.result.issues, [.invalidSettings([.leadTimeTooShort(weeks: 2, minimumWeeks: 6)])])
        XCTAssertNil(tooClose.planChanges)
        XCTAssertEqual(tooClose.explanation.last,
                       "No new plan could be built from these settings, so the previous plan stays in place.")

        // Valid settings the builder can't plan (no LTHR in this baseline).
        let coldStart = GoalFixture.fixtureReport(marks: false)
        let replan = GoalPlanner.replan(from: original, previousPlan: first.plan, to: original, baseline: coldStart, today: today)
        XCTAssertNil(replan.result.plan)
        guard case .cannotBuild(let issues)? = replan.result.issues.first else { return XCTFail("\(replan.result.issues)") }
        XCTAssertTrue(issues.contains(.missingHeartRateZones))
        XCTAssertNil(replan.planChanges)
    }

    func testInvalidEditIsRefusedBeforeBuilding() {
        var s = GoalFixture.settings()
        s.race.date = today.addingTimeInterval(-86_400)
        s.race.name = " "
        XCTAssertEqual(plan(s).issues, [.invalidSettings([.emptyRaceName, .raceDateNotAfterToday])])
    }

    func testBaselineMustBeFromToday() throws {
        let s = GoalFixture.settings()
        let tz = report.timeZone
        let cal = PlanCalendar.calendar(timeZone: tz)
        let before = today.addingTimeInterval(-3600)
        XCTAssertEqual(plan(s, today: before).issues, [.baselineAfterToday(asOf: report.asOf)])
        // The next calendar day in the runner's time zone is out of date, even a minute after midnight.
        let nextDay = cal.startOfDay(for: today).addingTimeInterval(86_400 + 60)
        XCTAssertEqual(plan(s, today: nextDay).issues, [.baselineOutOfDate(asOf: report.asOf, today: nextDay)])
        XCTAssertEqual(plan(s, today: today.addingTimeInterval(7 * 86_400)).issues,
                       [.baselineOutOfDate(asOf: report.asOf, today: today.addingTimeInterval(7 * 86_400))])
        XCTAssertEqual(plan(s, today: Date(timeIntervalSinceReferenceDate: .nan)).issues,
                       [.invalidSettings([.raceDateNotAfterToday])])

        // Later the same day is out of date too, past the short tolerance.
        let tolerance = GoalHeuristics.maximumBaselineAgeSeconds
        let late = today.addingTimeInterval(tolerance + 1)
        XCTAssertEqual(plan(s, today: late).issues, [.baselineOutOfDate(asOf: report.asOf, today: late)])

        // The tolerance itself is allowed, and the plan is sized from the
        // runner's recent load, not from weeks it hasn't seen. Today's week is
        // still open and this history has no recovery week, so the first plan
        // week is a recovery week against the least a finished build week can
        // be, 80% of the week before (#48), and the plan grows from there.
        let edge = today.addingTimeInterval(tolerance)
        let p = try XCTUnwrap(plan(s, today: edge).plan, "\(plan(s, today: edge).issues)")
        let recent = try XCTUnwrap(p.input.recentWeeklySeconds)
        let firstWeek = try XCTUnwrap(p.plan.weeks.first)
        XCTAssertLessThanOrEqual(firstWeek.trainingSeconds, 0.8 * 0.8 * recent)
        XCTAssertGreaterThan(firstWeek.trainingSeconds, 0.5 * recent)
        // That plan is provisional. Rebuilt at the start of its first Monday,
        // after the usual rest of the week, it builds above the recent load.
        let monday = try XCTUnwrap(p.rebuildDate)
        let w = BaselineFixture.weeks
        let rest = [GoalFixture.run("rest-thu", week: w, day: .thursday, minutes: 35),
                    GoalFixture.run("rest-sat", week: w, day: .saturday, minutes: 35),
                    GoalFixture.run("rest-sun", week: w, day: .sunday, minutes: 80, hour: 8)]
        let fresh = GoalFixture.fixtureReport(asOf: monday) { $0 += rest }
        let rebuilt = try XCTUnwrap(plan(s, baseline: fresh, today: monday).plan, "\(plan(s, baseline: fresh, today: monday).issues)")
        XCTAssertNil(rebuilt.rebuildDate)
        let rebuiltRecent = try XCTUnwrap(rebuilt.input.recentWeeklySeconds)
        let peak = try XCTUnwrap(rebuilt.plan.weeks.map(\.trainingSeconds).max())
        XCTAssertGreaterThan(peak, rebuiltRecent)
        XCTAssertGreaterThan(try XCTUnwrap(p.plan.weeks.last).trainingSeconds, 0, "race week still has training")
    }

    func testColdStartAsksForAFieldTestRatherThanGuessing() {
        let noMarks = GoalFixture.fixtureReport(marks: false)
        let result = GoalPlanner.plan(settings: GoalFixture.settings(), baseline: noMarks, today: today)
        guard case .cannotBuild(let issues)? = result.issues.first else { return XCTFail("\(result)") }
        XCTAssertTrue(issues.contains(.missingHeartRateZones))
    }

    func testPainFreezeIsCheckedOnTheNewPlan() throws {
        let s = GoalFixture.settings(weeksAhead: 14, pain: .recurring(areas: ["shin"]))
        let p = try XCTUnwrap(plan(s).plan)
        let tz = report.timeZone
        // Volume per plan week, with the history week before the first.
        let all = p.history + p.plan.workouts
        let weeks = PlanWeek.weeks(from: all, timeZone: tz)
        let planWeeks = weeks.filter { $0.weekStart >= p.plan.weeks[0].weekStart }
        let growing = try XCTUnwrap(planWeeks.indices.dropFirst().first {
            (planWeeks[$0].volume(.time) ?? 0) > (planWeeks[$0 - 1].volume(.time) ?? 0) + 60
        }, "the plan grows somewhere")
        let flat = planWeeks.indices.dropFirst().first {
            (planWeeks[$0].volume(.time) ?? 0) < (planWeeks[$0 - 1].volume(.time) ?? 0)
        }

        let freeze = DateInterval(start: planWeeks[growing].weekStart, end: planWeeks[growing].weekEnd)
        guard case .failsGuardrails(let report)? = plan(s, freezes: [freeze]).issues.first else {
            return XCTFail("a freeze over a growing week must be caught")
        }
        XCTAssertEqual(Set(report.violations.map(\.rule)), [.volumeFreeze])

        if let flat {
            let ok = DateInterval(start: planWeeks[flat].weekStart, end: planWeeks[flat].weekEnd)
            XCTAssertNotNil(plan(s, freezes: [ok]).plan, "a freeze over a week that doesn't grow passes")
        }
    }

    // MARK: Runs synced after the baseline (review probes)

    /// A plan from a fresh baseline that includes the run passes the checker
    /// against the full history; the baseline built before the run is refused.
    func assertFreshBaselineIsSafe(staleAsOf: Date, planAt: Date, extraRun: Activity?,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let change: (inout [Activity]) -> Void = { acts in if let r = extraRun { acts.append(r) } }
        let stale = GoalFixture.fixtureReport(asOf: staleAsOf, change: change)
        let fresh = GoalFixture.fixtureReport(asOf: planAt, change: change)
        let s = GoalFixture.settings(weeksAhead: 14)
        XCTAssertEqual(GoalPlanner.plan(settings: s, baseline: stale, today: planAt).issues,
                       [.baselineOutOfDate(asOf: staleAsOf, today: planAt)], file: file, line: line)
        let result = GoalPlanner.plan(settings: s, baseline: fresh, today: planAt)
        let p = try XCTUnwrap(result.plan, "\(result.issues)", file: file, line: line)
        let full = BaselinePlanMapping.planHistory(from: fresh)
        if let r = extraRun { XCTAssertTrue(full.contains { $0.id == r.id }, file: file, line: line) }
        let report = GuardrailChecker.check(history: full, planned: p.plan.workouts, timeZone: fresh.timeZone)
        XCTAssertTrue(report.passed, "\(report.violations)", file: file, line: line)
    }

    func testMondayRunAfterTheBaselineIsNotMissed() throws {
        // Monday of the week after the fixture: baseline 07:00, run 08:00, plan 09:00.
        let monday = BaselineFixture.date(day: BaselineFixture.weeks * 7, hour: 7)
        for minutes in [60.0, 120.0] {
            let run = BaselineFixture.run("mon-\(Int(minutes))", start: monday.addingTimeInterval(3600),
                                          seconds: minutes * 60, speed: BaselineFixture.easySpeed,
                                          hr: { _ in BaselineFixture.hr(atSpeed: BaselineFixture.easySpeed) },
                                          cadence: 170)
            try assertFreshBaselineIsSafe(staleAsOf: monday, planAt: monday.addingTimeInterval(2 * 3600), extraRun: run)
        }
    }

    func testSundayLongRunAfterTheBaselineIsNotMissed() throws {
        // The fixture's last Sunday: baseline 07:00, its long run at 08:00, plan at 20:00.
        let sunday = BaselineFixture.date(day: (BaselineFixture.weeks - 1) * 7 + 6, hour: 7)
        try assertFreshBaselineIsSafe(staleAsOf: sunday, planAt: sunday.addingTimeInterval(13 * 3600), extraRun: nil)
    }

    // MARK: The rest of the current week on a re-plan

    func testKeptSessionsAreCheckedWithTheNewPlan() throws {
        // First plan built on the Monday two weeks before the fixture's last
        // Wednesday; the re-plan comes that Wednesday at noon.
        let monday = BaselineFixture.date(day: (BaselineFixture.weeks - 2) * 7, hour: 6)
        let original = GoalFixture.settings(weeksAhead: 14)
        let first = try XCTUnwrap(GoalPlanner.plan(settings: original, baseline: GoalFixture.fixtureReport(asOf: monday),
                                                   today: monday).plan)
        var edited = original
        edited.race.time = .seconds(6900)
        let replan = GoalPlanner.replan(from: original, previousPlan: first.plan, to: edited, baseline: report, today: today)
        let p = try XCTUnwrap(replan.result.plan, "\(replan.result.issues)")
        let firstWeek = try XCTUnwrap(p.plan.weeks.first).weekStart
        let rest = first.plan.workouts.filter { $0.date >= today && $0.date < firstWeek }
        XCTAssertFalse(rest.isEmpty, "the old plan has sessions left this week")
        XCTAssertEqual(Set(replan.keptThisWeek + replan.droppedThisWeek), Set(rest))
        // Whatever is kept passes with the history and the new plan.
        let all = GuardrailChecker.check(history: p.history, planned: replan.keptThisWeek + p.plan.workouts,
                                         timeZone: report.timeZone)
        XCTAssertTrue(all.passed, "\(all.violations)")
        // In this probe they would break 3.5, so they are dropped and the runner is told.
        let withAll = GuardrailChecker.check(history: p.history, planned: rest + p.plan.workouts, timeZone: report.timeZone)
        XCTAssertFalse(withAll.passed)
        XCTAssertEqual(replan.keptThisWeek, [])
        XCTAssertEqual(replan.droppedThisWeek, rest.sorted { $0.date < $1.date })
        XCTAssertTrue(replan.explanation.contains {
            $0.hasSuffix("left this week from the previous plan were dropped: with them, the new plan would break the load guardrails (SPEC 3.5).")
        })
    }

    func testKeptSessionsOffTheNewDaysAreDropped() throws {
        let monday = BaselineFixture.date(day: (BaselineFixture.weeks - 2) * 7, hour: 6)
        let original = GoalFixture.settings(weeksAhead: 14)
        let first = try XCTUnwrap(GoalPlanner.plan(settings: original, baseline: GoalFixture.fixtureReport(asOf: monday),
                                                   today: monday).plan)
        var edited = original
        edited.schedule = TrainingSchedule(trainingDays: [.monday, .wednesday, .friday, .saturday],
                                           longRunDay: .saturday, maxSession: .noLimit)
        let replan = GoalPlanner.replan(from: original, previousPlan: first.plan, to: edited, baseline: report, today: today)
        XCTAssertNotNil(replan.result.plan)
        let tz = report.timeZone
        for w in replan.keptThisWeek {
            XCTAssertTrue(edited.schedule.trainingDays.contains(PlanWeekday(of: w.date, timeZone: tz)))
        }
        XCTAssertTrue(replan.droppedThisWeek.contains { !edited.schedule.trainingDays.contains(PlanWeekday(of: $0.date, timeZone: tz)) })
        XCTAssertTrue(replan.explanation.contains { $0.hasSuffix("fell on days you no longer train, so they were dropped.") })
    }

    // MARK: Every session of the current week is kept or dropped (#15)

    /// A plan built on the Monday two weeks before the fixture's last
    /// Wednesday, with the race `weeksAhead` weeks after this week's Sunday.
    func oldPlan(_ settings: GoalSettings, weeksBefore: Int = 2) throws -> TrainingPlan {
        let monday = BaselineFixture.date(day: (BaselineFixture.weeks - weeksBefore) * 7, hour: 6)
        let r = GoalPlanner.plan(settings: settings, baseline: GoalFixture.fixtureReport(asOf: monday), today: monday)
        return try XCTUnwrap(r.plan, "old plan: \(r.issues)").plan
    }

    func testOldRaceInTheCurrentWeekIsDropped() throws {
        let original = GoalFixture.settings(distance: Distance.fiveK, weeksAhead: 0)
        let old = try oldPlan(original, weeksBefore: 4)
        let race = try XCTUnwrap(old.workouts.first { $0.kind == .race })
        XCTAssertGreaterThan(race.date, today)
        var edited = original
        edited.race.date = GoalFixture.raceDay(weeksAhead: 12)
        let replan = GoalPlanner.replan(from: original, previousPlan: old, to: edited, baseline: report, today: today)
        let p = try XCTUnwrap(replan.result.plan, "\(replan.result.issues)")
        let firstWeek = try XCTUnwrap(p.plan.weeks.first).weekStart
        XCTAssertTrue(replan.droppedThisWeek.contains(race))
        XCTAssertFalse(replan.keptThisWeek.contains(race))
        // Together the two lists cover everything the old plan had left this week.
        let rest = old.workouts.filter { $0.date >= today && $0.date < firstWeek }
        XCTAssertEqual(Set(replan.keptThisWeek + replan.droppedThisWeek), Set(rest))
        XCTAssertTrue(replan.explanation.contains { $0.contains("race in the previous plan") })
    }

    func testUndoneSessionFromEarlierTodayIsDropped() throws {
        var days = GoalFixture.fixtureDays
        days.insert(.wednesday)
        let original = GoalFixture.settings(weeksAhead: 14, days: days)
        let old = try oldPlan(original)
        // The old plan's sessions are at noon; the re-plan comes that evening.
        let evening = BaselineFixture.date(day: BaselineFixture.weeks * 7 + 2, hour: 18)
        let report = GoalFixture.fixtureReport(asOf: evening)
        let earlier = old.workouts.filter { $0.date >= BaselineFixture.date(day: BaselineFixture.weeks * 7 + 2, hour: 0) && $0.date < evening }
        XCTAssertFalse(earlier.isEmpty, "the old plan had a session this morning: \(old.workouts.map(\.date))")
        var edited = original
        edited.race.time = .seconds(6900)
        let replan = GoalPlanner.replan(from: original, previousPlan: old, to: edited, baseline: report, today: evening)
        XCTAssertNotNil(replan.result.plan)
        for s in earlier { XCTAssertTrue(replan.droppedThisWeek.contains(s)) }
        XCTAssertTrue(replan.keptThisWeek.allSatisfy { $0.date >= evening })
        XCTAssertTrue(replan.explanation.contains { $0.contains("from earlier today") })

        // A run logged today means the session was done: it is neither kept nor dropped.
        let done = GoalFixture.fixtureReport(asOf: evening, change: { acts in
            acts.append(BaselineFixture.run("done-today", start: BaselineFixture.date(day: BaselineFixture.weeks * 7 + 2, hour: 7),
                                            seconds: 1800, speed: BaselineFixture.easySpeed,
                                            hr: { _ in BaselineFixture.hr(atSpeed: BaselineFixture.easySpeed) },
                                            cadence: 170, outdoor: true))
        })
        let after = GoalPlanner.replan(from: original, previousPlan: old, to: edited, baseline: done, today: evening)
        for s in earlier {
            XCTAssertFalse(after.droppedThisWeek.contains(s))
            XCTAssertFalse(after.keptThisWeek.contains(s))
        }
    }

    func testKeptEqualsTheRemainingSessionsWhenTheyFit() throws {
        let original = GoalFixture.settings(weeksAhead: 14)
        let old = try oldPlan(original)
        // Same goal: the rest of the week stays as planned.
        let replan = GoalPlanner.replan(from: original, previousPlan: old, to: original, baseline: report, today: today)
        let p = try XCTUnwrap(replan.result.plan, "\(replan.result.issues)")
        let firstWeek = try XCTUnwrap(p.plan.weeks.first).weekStart
        let rest = old.workouts.filter { $0.date >= today && $0.date < firstWeek }
        XCTAssertFalse(rest.isEmpty)
        if replan.droppedThisWeek.isEmpty {
            XCTAssertEqual(replan.keptThisWeek, rest.sorted { $0.date < $1.date })
        } else {
            XCTAssertEqual(Set(replan.keptThisWeek + replan.droppedThisWeek), Set(rest))
        }
    }
}
