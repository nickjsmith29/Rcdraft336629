import XCTest
@testable import CoachCore

// Issue #55: rebuilding a provisional plan (#48) on its first Monday.
//
// Synthetic runners and dates only: nothing here stands for a real person.
final class ProvisionalRebuildTests: XCTestCase {
    private let day = 86_400.0

    // MARK: Fixtures

    private func zone(_ id: String) -> TimeZone { TimeZone(identifier: id)! }

    private func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ tz: TimeZone) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        return PlanCalendar.calendar(timeZone: tz).date(from: c)!
    }

    /// A provisional plan shell: weeks from `firstMonday`, the last one the
    /// race week. Only the dates matter to `ProvisionalRebuild`.
    /// `raceWeekStart` overrides the race week's start (for corrupt dates).
    private func shell(firstMonday: Date, weeks: Int, rebuildDate: Date?, tz: TimeZone,
                       raceWeekStart: Date? = nil) -> TrainingPlan {
        var starts = [firstMonday]
        while starts.count < weeks { starts.append(PlanCalendar.nextWeekStart(after: starts.last!, timeZone: tz)) }
        if let raceWeekStart { starts[weeks - 1] = raceWeekStart }
        let ws = starts.enumerated().map { i, s in
            TrainingPlanWeek(index: i, weekStart: s, phase: i == weeks - 1 ? .taper : .base, isRecoveryWeek: false,
                             isRaceWeek: i == weeks - 1, workouts: [])
        }
        return TrainingPlan(category: .half, weeks: ws, raceSeconds: 6000,
                            guardrailReport: GuardrailReport(violations: [], notEvaluated: []), notes: [],
                            rebuildDate: rebuildDate)
    }

    private func refusal(_ issue: PlanBuildIssue) -> PlanBuildResult { .cannotBuild([issue]) }

    /// The F2 runner's usual Thursday, Saturday and Sunday after the Wednesday
    /// plan (`GoalFixture` runs 35, 35 and 80 minutes on those days).
    private func restOfWeek() -> [Activity] {
        let w = BaselineFixture.weeks
        return [GoalFixture.run("rest-thu", week: w, day: .thursday, minutes: 35),
                GoalFixture.run("rest-sat", week: w, day: .saturday, minutes: 35),
                GoalFixture.run("rest-sun", week: w, day: .sunday, minutes: 80, hour: 8)]
    }

    // MARK: The Monday 06:00 run (#55)

    /// A plan made midweek, then a run logged at 06:00 on the rebuild Monday.
    /// Rebuilt from now (10:00), the plan is provisional again; rebuilt with
    /// `today` = `rebuildDate` and a baseline as of then, it is final.
    func testRebuildAfterAMondaySixAMRunWithTodayAsTheRebuildDateIsFinal() throws {
        let tz = GoalFixture.timeZone
        let settings = GoalFixture.settings(distance: Distance.halfMarathon, weeksAhead: 14)
        let first = try XCTUnwrap(GoalPlanner.plan(settings: settings, baseline: GoalFixture.fixtureReport(),
                                                   today: GoalFixture.today).plan)
        let monday = try XCTUnwrap(first.rebuildDate)
        let early = GoalFixture.run("mon-early", week: BaselineFixture.weeks + 1, day: .monday, minutes: 40, hour: 6)
        XCTAssertGreaterThan(early.start, monday)
        XCTAssertEqual(PlanCalendar.weekStart(containing: early.start, timeZone: tz), monday)
        let now = monday.addingTimeInterval(10 * 3600)

        XCTAssertEqual(ProvisionalRebuild.due(plan: first, now: now, timeZone: tz), .rebuild(today: monday))

        // The trap: from now, the 06:00 run starts the plan next Monday.
        let fromNow = GoalFixture.fixtureReport(asOf: now) { $0 += self.restOfWeek() + [early] }
        let trap = try XCTUnwrap(GoalPlanner.plan(settings: settings, baseline: fromNow, today: now).plan)
        XCTAssertEqual(trap.rebuildDate, PlanCalendar.nextWeekStart(after: monday, timeZone: tz))

        // The rebuild: as of the rebuild date, the run is in the plan's first week.
        let asOfMonday = GoalFixture.fixtureReport(asOf: monday) { $0 += self.restOfWeek() + [early] }
        let attempt = GoalPlanner.plan(settings: settings, baseline: asOfMonday, today: monday)
        let rebuilt = try XCTUnwrap(attempt.plan, "\(attempt.issues)")
        XCTAssertNil(rebuilt.rebuildDate)
        XCTAssertFalse(rebuilt.plan.isProvisional)
        XCTAssertEqual(rebuilt.plan.weeks.first?.weekStart, monday)
        XCTAssertFalse(rebuilt.history.contains { $0.date >= monday }, "the Monday run is not history")
        XCTAssertFalse(rebuilt.plan.notes.contains { $0.contains("provisional") })

        let outcome = ProvisionalRebuild.resolve(provisional: first, attempt: attempt, now: now, timeZone: tz)
        XCTAssertTrue(outcome.isRebuilt)
        XCTAssertEqual(outcome.plan, rebuilt)
        XCTAssertNil(outcome.retryAt)
        XCTAssertNil(outcome.note)
        XCTAssertEqual(ProvisionalRebuild.due(plan: outcome.plan, now: now, timeZone: tz), .notNeeded)
    }

    /// The same through `PlanBuilder.build`: a start of `rebuildDate` ignores
    /// the 06:00 run as history and gives a final plan.
    func testPlanBuilderRebuildFromTheRebuildDateIgnoresTheMondayRun() throws {
        let tz = GoalFixture.timeZone
        let settings = GoalFixture.settings(distance: Distance.tenK, weeksAhead: 12)
        let first = try XCTUnwrap(GoalPlanner.plan(settings: settings, baseline: GoalFixture.fixtureReport(),
                                                   today: GoalFixture.today).plan)
        let monday = try XCTUnwrap(first.plan.rebuildDate)
        let early = GoalFixture.run("mon-early", week: BaselineFixture.weeks + 1, day: .monday, minutes: 40, hour: 6)
        let report = GoalFixture.fixtureReport(asOf: monday) { $0 += self.restOfWeek() }
        var input = BaselinePlanMapping.planInput(settings: settings, baseline: report, startDate: monday)
        let mondayRun = PlannedWorkout(id: early.id, date: early.start, kind: .easy, durationSeconds: 40 * 60)
        let history = BaselinePlanMapping.planHistory(from: report) + [mondayRun]
        let result = PlanBuilder.build(input, history: history, timeZone: tz)
        let plan = try XCTUnwrap(result.plan, "\(result.issues)")
        XCTAssertNil(result.rebuildDate)
        XCTAssertEqual(plan.weeks.first?.weekStart, monday)

        // From 10:00 instead, the same run makes it provisional again.
        input.startDate = monday.addingTimeInterval(10 * 3600)
        let late = PlanBuilder.build(input, history: history, timeZone: tz)
        let p = try XCTUnwrap(late.plan, "\(late.issues)")
        XCTAssertEqual(p.rebuildDate, PlanCalendar.nextWeekStart(after: monday, timeZone: tz))
    }

    // MARK: The missed week (#77)

    /// No rebuild during the plan's whole first week: on the next visit, a
    /// Wednesday, `due` gives the latest Monday. Through the real GoalPlanner
    /// with a baseline as of that Monday, the plan is final, the missed week's
    /// runs are history and this week's runs (Monday and Tuesday) are not.
    func testRebuildAfterAMissedWeekThroughGoalPlannerIsFinal() throws {
        let tz = GoalFixture.timeZone
        let settings = GoalFixture.settings(distance: Distance.halfMarathon, weeksAhead: 14)
        let first = try XCTUnwrap(GoalPlanner.plan(settings: settings, baseline: GoalFixture.fixtureReport(),
                                                   today: GoalFixture.today).plan)
        let monday = try XCTUnwrap(first.rebuildDate)
        let latest = PlanCalendar.nextWeekStart(after: monday, timeZone: tz)
        let w = BaselineFixture.weeks
        let missed = [GoalFixture.run("missed-tue", week: w + 1, day: .tuesday, minutes: 35),
                      GoalFixture.run("missed-thu", week: w + 1, day: .thursday, minutes: 35),
                      GoalFixture.run("missed-sat", week: w + 1, day: .saturday, minutes: 35),
                      GoalFixture.run("missed-sun", week: w + 1, day: .sunday, minutes: 80, hour: 8)]
        let current = [GoalFixture.run("now-mon", week: w + 2, day: .monday, minutes: 40, hour: 6),
                       GoalFixture.run("now-tue", week: w + 2, day: .tuesday, minutes: 35)]
        XCTAssertEqual(PlanCalendar.weekStart(containing: missed[0].start, timeZone: tz), monday)
        XCTAssertEqual(PlanCalendar.weekStart(containing: current[0].start, timeZone: tz), latest)
        let now = BaselineFixture.date(day: (w + 2) * 7 + PlanWeekday.wednesday.rawValue, hour: 9)

        XCTAssertEqual(ProvisionalRebuild.due(plan: first, now: now, timeZone: tz), .rebuild(today: latest))

        let report = GoalFixture.fixtureReport(asOf: latest) { $0 += self.restOfWeek() + missed + current }
        let attempt = GoalPlanner.plan(settings: settings, baseline: report, today: latest)
        let rebuilt = try XCTUnwrap(attempt.plan, "\(attempt.issues)")
        XCTAssertNil(rebuilt.rebuildDate)
        XCTAssertFalse(rebuilt.plan.isProvisional)
        XCTAssertEqual(rebuilt.plan.weeks.first?.weekStart, latest)
        let ids = Set(rebuilt.history.map(\.id))
        for run in missed { XCTAssertTrue(ids.contains(run.id), "\(run.id) is history") }
        for run in current { XCTAssertFalse(ids.contains(run.id), "\(run.id) is not history") }
        XCTAssertFalse(rebuilt.history.contains { $0.date >= latest })

        let outcome = ProvisionalRebuild.resolve(provisional: first, attempt: attempt, now: now, timeZone: tz)
        XCTAssertTrue(outcome.isRebuilt)
        XCTAssertFalse(outcome.isWiringError)
        XCTAssertEqual(outcome.plan, rebuilt)
        XCTAssertNil(outcome.retryAt)
        XCTAssertEqual(ProvisionalRebuild.due(plan: outcome.plan, now: now, timeZone: tz), .notNeeded)
    }

    // MARK: Due

    func testDueWaitsForTheRebuildDateAndIgnoresAFinalPlan() {
        let tz = zone("America/Chicago")
        let monday = local(2026, 6, 15, 0, 0, tz)
        let plan = shell(firstMonday: monday, weeks: 12, rebuildDate: monday, tz: tz)
        XCTAssertEqual(ProvisionalRebuild.due(plan: plan, now: monday.addingTimeInterval(-1), timeZone: tz),
                       .notYet(at: monday))
        XCTAssertEqual(ProvisionalRebuild.due(plan: plan, now: monday, timeZone: tz), .rebuild(today: monday))
        let final = shell(firstMonday: monday, weeks: 12, rebuildDate: nil, tz: tz)
        XCTAssertEqual(ProvisionalRebuild.due(plan: final, now: monday, timeZone: tz), .notNeeded)
    }

    /// Late in the first week, the rebuild still starts from the rebuild date.
    func testLateRebuildInTheFirstWeekStillPassesTheRebuildDate() {
        let tz = zone("America/Chicago")
        let monday = local(2026, 6, 15, 0, 0, tz)
        let plan = shell(firstMonday: monday, weeks: 12, rebuildDate: monday, tz: tz)
        for now in [local(2026, 6, 15, 6, 0, tz), local(2026, 6, 17, 21, 0, tz), local(2026, 6, 21, 23, 59, tz)] {
            XCTAssertEqual(ProvisionalRebuild.due(plan: plan, now: now, timeZone: tz), .rebuild(today: monday), "\(now)")
        }
    }

    /// After a whole week with no rebuild, the latest Monday is the start, so
    /// the plan's first week (now run) is closed history.
    func testRebuildAfterAMissedWeekStartsFromTheLatestMonday() {
        let tz = zone("America/Chicago")
        let monday = local(2026, 6, 15, 0, 0, tz)
        let plan = shell(firstMonday: monday, weeks: 12, rebuildDate: monday, tz: tz)
        XCTAssertEqual(ProvisionalRebuild.due(plan: plan, now: local(2026, 6, 24, 9, 0, tz), timeZone: tz),
                       .rebuild(today: local(2026, 6, 22, 0, 0, tz)))
    }

    func testNoRebuildOnceTheRaceWeekHasBegun() {
        let tz = zone("UTC")
        let monday = local(2026, 6, 15, 0, 0, tz)
        let plan = shell(firstMonday: monday, weeks: 3, rebuildDate: monday, tz: tz)
        let raceWeek = plan.weeks.last!.weekStart
        XCTAssertEqual(ProvisionalRebuild.due(plan: plan, now: raceWeek.addingTimeInterval(3600), timeZone: tz),
                       .raceWeekReached)
        XCTAssertEqual(ProvisionalRebuild.due(plan: plan, retryAt: raceWeek, now: monday, timeZone: tz),
                       .raceWeekReached)
        // The week before the race week is still a try.
        XCTAssertEqual(ProvisionalRebuild.due(plan: plan, now: raceWeek.addingTimeInterval(-3600), timeZone: tz),
                       .rebuild(today: plan.weeks[1].weekStart))
    }

    func testNonFiniteDatesAreRefused() {
        let tz = zone("UTC")
        let monday = local(2026, 6, 15, 0, 0, tz)
        let nan = Date(timeIntervalSinceReferenceDate: .nan)
        let inf = Date(timeIntervalSinceReferenceDate: .infinity)
        let plan = shell(firstMonday: monday, weeks: 12, rebuildDate: monday, tz: tz)
        XCTAssertEqual(ProvisionalRebuild.due(plan: plan, now: nan, timeZone: tz), .invalidDate)
        XCTAssertEqual(ProvisionalRebuild.due(plan: plan, now: inf, timeZone: tz), .invalidDate)
        XCTAssertEqual(ProvisionalRebuild.due(plan: plan, retryAt: nan, now: monday, timeZone: tz), .invalidDate)
        let bad = shell(firstMonday: monday, weeks: 12, rebuildDate: nan, tz: tz)
        XCTAssertEqual(ProvisionalRebuild.due(plan: bad, now: monday, timeZone: tz), .invalidDate)
        // A refusal with no valid now keeps the plan, with no retry date to guess.
        let kept = ProvisionalRebuild.resolve(provisional: plan, attempt: refusal(.missingRecentVolume), now: nan,
                                              timeZone: tz)
        XCTAssertFalse(kept.isRebuilt)
        XCTAssertEqual(kept.plan, plan)
        XCTAssertNil(kept.retryAt)
        XCTAssertNotNil(kept.note)
    }

    /// A non-finite race-week start: `due` refuses it and `resolve` keeps the
    /// plan with no retry, the same way as a non-finite `now` (#77).
    func testNonFiniteRaceWeekStartIsHandledAlikeByDueAndResolve() {
        let tz = zone("UTC")
        let monday = local(2026, 6, 15, 0, 0, tz)
        for bad in [Date(timeIntervalSinceReferenceDate: .nan), Date(timeIntervalSinceReferenceDate: .infinity),
                    Date(timeIntervalSinceReferenceDate: -.infinity)] {
            let plan = shell(firstMonday: monday, weeks: 12, rebuildDate: monday, tz: tz, raceWeekStart: bad)
            XCTAssertEqual(ProvisionalRebuild.due(plan: plan, now: monday, timeZone: tz), .invalidDate, "\(bad)")
            let out = ProvisionalRebuild.resolve(provisional: plan, attempt: refusal(.missingRecentVolume),
                                                 now: monday.addingTimeInterval(3600), timeZone: tz)
            XCTAssertFalse(out.isRebuilt)
            XCTAssertEqual(out.plan, plan)
            XCTAssertNil(out.retryAt, "\(bad)")
            XCTAssertEqual(out.note?.contains("stays in place"), true)
            XCTAssertEqual(out.note?.contains("tried again"), false)
        }
    }

    // MARK: Refused rebuilds

    func testRefusalKeepsTheProvisionalPlanAndRetriesNextMonday() {
        let tz = zone("America/Denver")
        let monday = local(2026, 6, 15, 0, 0, tz)
        let next = local(2026, 6, 22, 0, 0, tz)
        let plan = shell(firstMonday: monday, weeks: 12, rebuildDate: monday, tz: tz)
        let now = local(2026, 6, 15, 7, 30, tz)
        for issue in [PlanBuildIssue.noWorkableWeek(weekStart: monday, allowedSeconds: 900),
                      .recentVolumeTooLow(seconds: 1200, minimumSeconds: 3600)] {
            let out = ProvisionalRebuild.resolve(provisional: plan, attempt: refusal(issue), now: now, timeZone: tz)
            XCTAssertFalse(out.isRebuilt, "\(issue)")
            XCTAssertEqual(out.plan, plan, "the provisional plan stays")
            XCTAssertEqual(out.retryAt, next, "\(issue)")
            XCTAssertTrue(out.note?.contains("2026-06-22") ?? false, out.note ?? "")
            XCTAssertTrue(out.note?.contains("SPEC 3.5") ?? false)

            // The stored retry gates the next try, and then it starts from that Monday.
            XCTAssertEqual(ProvisionalRebuild.due(plan: plan, retryAt: out.retryAt, now: local(2026, 6, 18, 9, 0, tz),
                                                  timeZone: tz), .notYet(at: next))
            XCTAssertEqual(ProvisionalRebuild.due(plan: plan, retryAt: out.retryAt, now: local(2026, 6, 22, 5, 0, tz),
                                                  timeZone: tz), .rebuild(today: next))
        }
    }

    /// A refusal on the retry Monday itself (`now` exactly 00:00) waits a full week.
    func testRefusalAtMidnightRetriesTheFollowingMonday() {
        let tz = zone("UTC")
        let monday = local(2026, 6, 15, 0, 0, tz)
        let plan = shell(firstMonday: monday, weeks: 12, rebuildDate: monday, tz: tz)
        let out = ProvisionalRebuild.resolve(provisional: plan, attempt: refusal(.missingRecentVolume),
                                             now: local(2026, 6, 22, 0, 0, tz), timeZone: tz)
        XCTAssertEqual(out.retryAt, local(2026, 6, 29, 0, 0, tz))
    }

    func testARefusalsOwnLaterRebuildDateWins() {
        let tz = zone("UTC")
        let monday = local(2026, 6, 15, 0, 0, tz)
        let plan = shell(firstMonday: monday, weeks: 12, rebuildDate: monday, tz: tz)
        let later = local(2026, 6, 29, 0, 0, tz)
        let out = ProvisionalRebuild.resolve(provisional: plan, attempt: refusal(.historyVolumeUnknown(rebuildOn: later)),
                                             now: monday, timeZone: tz)
        XCTAssertEqual(out.retryAt, later)
        // An earlier one never pulls the retry before next Monday.
        let early = ProvisionalRebuild.resolve(provisional: plan,
                                               attempt: refusal(.startWeekWithoutReference(rebuildOn: monday)),
                                               now: monday, timeZone: tz)
        XCTAssertEqual(early.retryAt, local(2026, 6, 22, 0, 0, tz))
    }

    func testNoRetryWhenTheNextTryFallsInTheRaceWeek() {
        let tz = zone("UTC")
        let monday = local(2026, 6, 15, 0, 0, tz)
        let plan = shell(firstMonday: monday, weeks: 2, rebuildDate: monday, tz: tz)
        let out = ProvisionalRebuild.resolve(provisional: plan, attempt: refusal(.missingRecentVolume),
                                             now: monday.addingTimeInterval(3600), timeZone: tz)
        XCTAssertFalse(out.isRebuilt)
        XCTAssertNil(out.retryAt)
        XCTAssertTrue(out.note?.contains("runs to the race") ?? false)
    }

    func testGoalPlannerRefusalKeepsTheGoalPlan() throws {
        let tz = GoalFixture.timeZone
        let settings = GoalFixture.settings(distance: Distance.halfMarathon, weeksAhead: 14)
        let first = try XCTUnwrap(GoalPlanner.plan(settings: settings, baseline: GoalFixture.fixtureReport(),
                                                   today: GoalFixture.today).plan)
        let monday = try XCTUnwrap(first.rebuildDate)
        let attempt = GoalPlanResult.cannotPlan([.cannotBuild([.noWorkableWeek(weekStart: monday, allowedSeconds: 0)])])
        let out = ProvisionalRebuild.resolve(provisional: first, attempt: attempt, now: monday, timeZone: tz)
        XCTAssertFalse(out.isRebuilt)
        XCTAssertEqual(out.plan, first)
        XCTAssertEqual(out.retryAt, PlanCalendar.nextWeekStart(after: monday, timeZone: tz))
        XCTAssertEqual(ProvisionalRebuild.due(plan: first, retryAt: out.retryAt, now: monday, timeZone: tz),
                       .notYet(at: out.retryAt!))
        // A refusal outside the builder (here a baseline dated after today) keeps it too.
        let other = ProvisionalRebuild.resolve(provisional: first,
                                               attempt: .cannotPlan([.baselineAfterToday(asOf: monday)]),
                                               now: monday, timeZone: tz)
        XCTAssertEqual(other.plan, first)
        XCTAssertEqual(other.retryAt, out.retryAt)
    }

    // MARK: Wiring errors (#77)

    /// A baseline not built as of `today` can only come from the app's
    /// wiring. Through the real GoalPlanner, both kinds keep the plan and set
    /// the weekly retry like any refusal, but are flagged so they get noticed.
    func testBaselineWiringRefusalsKeepThePlanAndAreFlagged() throws {
        let tz = GoalFixture.timeZone
        let settings = GoalFixture.settings(distance: Distance.halfMarathon, weeksAhead: 14)
        let first = try XCTUnwrap(GoalPlanner.plan(settings: settings, baseline: GoalFixture.fixtureReport(),
                                                   today: GoalFixture.today).plan)
        let monday = try XCTUnwrap(first.rebuildDate)
        let now = monday.addingTimeInterval(10 * 3600)
        let next = PlanCalendar.nextWeekStart(after: monday, timeZone: tz)

        // Built as of now instead of as of `today`: dated after today.
        let afterToday = GoalPlanner.plan(settings: settings,
                                          baseline: GoalFixture.fixtureReport(asOf: now) { $0 += self.restOfWeek() },
                                          today: monday)
        // The stale baseline from the first plan (last Wednesday): out of date.
        let stale = GoalPlanner.plan(settings: settings, baseline: GoalFixture.fixtureReport(), today: monday)
        XCTAssertTrue(afterToday.issues.contains { if case .baselineAfterToday = $0 { return true }; return false },
                      "\(afterToday.issues)")
        XCTAssertTrue(stale.issues.contains { if case .baselineOutOfDate = $0 { return true }; return false },
                      "\(stale.issues)")

        for attempt in [afterToday, stale,
                        .cannotPlan([.baselineAfterToday(asOf: now)]),
                        .cannotPlan([.baselineOutOfDate(asOf: GoalFixture.today, today: monday)])] {
            let out = ProvisionalRebuild.resolve(provisional: first, attempt: attempt, now: now, timeZone: tz)
            XCTAssertTrue(out.isWiringError, "\(attempt)")
            XCTAssertFalse(out.isRebuilt)
            XCTAssertEqual(out.plan, first, "the provisional plan stays")
            XCTAssertEqual(out.retryAt, next)
            XCTAssertEqual(out.note?.contains("tried again"), true)
        }
        // Still flagged when the race week stops the retry.
        let late = ProvisionalRebuild.resolve(provisional: first, attempt: .cannotPlan([.baselineAfterToday(asOf: now)]),
                                              now: try XCTUnwrap(first.plan.weeks.last?.weekStart), timeZone: tz)
        XCTAssertTrue(late.isWiringError)
        XCTAssertNil(late.retryAt)
    }

    /// Refusals from the runner's data, and rebuilds, are not wiring errors.
    func testDataRefusalsAndRebuildsAreNotWiringErrors() throws {
        let tz = zone("UTC")
        let monday = local(2026, 6, 15, 0, 0, tz)
        let plan = shell(firstMonday: monday, weeks: 12, rebuildDate: monday, tz: tz)
        for issue in [PlanBuildIssue.noWorkableWeek(weekStart: monday, allowedSeconds: 0),
                      .recentVolumeTooLow(seconds: 1200, minimumSeconds: 3600), .missingRecentVolume] {
            XCTAssertFalse(ProvisionalRebuild.resolve(provisional: plan, attempt: refusal(issue), now: monday,
                                                      timeZone: tz).isWiringError, "\(issue)")
        }
        XCTAssertFalse(ProvisionalRebuild.resolve(provisional: plan, attempt: .plan(plan), now: monday,
                                                  timeZone: tz).isWiringError)

        let gtz = GoalFixture.timeZone
        let settings = GoalFixture.settings(distance: Distance.halfMarathon, weeksAhead: 14)
        let first = try XCTUnwrap(GoalPlanner.plan(settings: settings, baseline: GoalFixture.fixtureReport(),
                                                   today: GoalFixture.today).plan)
        let goalMonday = try XCTUnwrap(first.rebuildDate)
        let refused = GoalPlanResult.cannotPlan([.cannotBuild([.noWorkableWeek(weekStart: goalMonday, allowedSeconds: 0)])])
        XCTAssertFalse(ProvisionalRebuild.resolve(provisional: first, attempt: refused, now: goalMonday,
                                                  timeZone: gtz).isWiringError)
        XCTAssertFalse(ProvisionalRebuild.resolve(provisional: first, attempt: .plan(first), now: goalMonday,
                                                  timeZone: gtz).isWiringError)
    }

    // MARK: Time zones and daylight saving

    /// Rebuild weeks that hold a DST change (167 or 169 hours) and zones with
    /// non-hour offsets: the rebuild starts at local Monday 00:00 and the retry
    /// is the next local Monday 00:00, not 168 hours on.
    func testTimeZonesAndDaylightSavingWeeks() {
        let cases: [(String, (Int, Int, Int), (Int, Int, Int), Double)] = [
            ("America/New_York", (2026, 3, 2), (2026, 3, 9), 167),    // spring forward Sun Mar 8
            ("Europe/London", (2026, 10, 19), (2026, 10, 26), 169),   // fall back Sun Oct 25
            ("Australia/Sydney", (2026, 9, 28), (2026, 10, 5), 167),  // spring forward Sun Oct 4
            ("America/Sao_Paulo", (2026, 6, 15), (2026, 6, 22), 168), // no DST
            ("Asia/Kolkata", (2026, 6, 15), (2026, 6, 22), 168),      // +05:30
            ("Pacific/Chatham", (2026, 3, 30), (2026, 4, 6), 169),    // +13:45 to +12:45, Sun Apr 5
        ]
        for (id, a, b, hours) in cases {
            let tz = zone(id)
            let monday = local(a.0, a.1, a.2, 0, 0, tz)
            let next = local(b.0, b.1, b.2, 0, 0, tz)
            XCTAssertEqual(next.timeIntervalSince(monday) / 3600, hours, accuracy: 0.001, id)
            XCTAssertEqual(PlanCalendar.weekStart(containing: monday, timeZone: tz), monday, id)
            let plan = shell(firstMonday: monday, weeks: 10, rebuildDate: monday, tz: tz)

            XCTAssertEqual(ProvisionalRebuild.due(plan: plan, now: monday.addingTimeInterval(-60), timeZone: tz),
                           .notYet(at: monday), id)
            // Sunday 23:30 local, after the change: still the first week.
            let lateSunday = local(b.0, b.1, b.2, 0, 0, tz).addingTimeInterval(-1800)
            XCTAssertEqual(ProvisionalRebuild.due(plan: plan, now: lateSunday, timeZone: tz), .rebuild(today: monday), id)

            let out = ProvisionalRebuild.resolve(provisional: plan, attempt: refusal(.missingRecentVolume),
                                                 now: monday.addingTimeInterval(8 * 3600), timeZone: tz)
            XCTAssertEqual(out.retryAt, next, id)
            XCTAssertEqual(ProvisionalRebuild.due(plan: plan, retryAt: out.retryAt, now: lateSunday, timeZone: tz),
                           .notYet(at: next), id)
            XCTAssertEqual(ProvisionalRebuild.due(plan: plan, retryAt: out.retryAt, now: next, timeZone: tz),
                           .rebuild(today: next), id)
        }
    }

    /// A runner who changed time zone since the plan was built: the stored
    /// Monday is read as the nearest local Monday 00:00, so the rebuild still
    /// starts on a local Monday and is final, not provisional for a few hours.
    func testRunnerWhoChangedTimeZone() {
        let ny = zone("America/New_York"), london = zone("Europe/London"), la = zone("America/Los_Angeles")
        // Built in New York; now in London. NY Monday 00:00 is 05:00 in London.
        let nyMonday = local(2026, 6, 15, 0, 0, ny)
        let fromNY = shell(firstMonday: nyMonday, weeks: 12, rebuildDate: nyMonday, tz: ny)
        let londonMonday = local(2026, 6, 15, 0, 0, london)
        XCTAssertEqual(ProvisionalRebuild.due(plan: fromNY, now: local(2026, 6, 15, 1, 0, london), timeZone: london),
                       .rebuild(today: londonMonday))
        // Built in London; now in Los Angeles. London Monday 00:00 is Sunday 16:00 there.
        let fromLondon = shell(firstMonday: londonMonday, weeks: 12, rebuildDate: londonMonday, tz: london)
        let laMonday = local(2026, 6, 15, 0, 0, la)
        XCTAssertEqual(ProvisionalRebuild.due(plan: fromLondon, now: local(2026, 6, 14, 17, 0, la), timeZone: la),
                       .notYet(at: laMonday))
        XCTAssertEqual(ProvisionalRebuild.due(plan: fromLondon, now: laMonday, timeZone: la),
                       .rebuild(today: laMonday))
    }
}
