import XCTest
@testable import CoachCore

// Issue #77: the app's rebuild steps (`ProvisionalRebuild.run`, `CurrentPlan`)
// through the real GoalPlanner.
//
// Synthetic runners and dates only (`GoalFixture`): nothing here stands for a
// real person.
final class ProvisionalRebuildRunTests: XCTestCase {
    private let tz = GoalFixture.timeZone

    /// Problems passed to `log` and `fail`.
    private final class Recorder: @unchecked Sendable {
        var logged: [ProvisionalRebuild.Problem] = []
        var failed: [ProvisionalRebuild.Problem] = []
        var baselineOptions: [BaselineOptions] = []
    }

    private func provisionalPlan(weeksAhead: Int = 14) throws -> GoalPlan {
        let settings = GoalFixture.settings(distance: Distance.halfMarathon, weeksAhead: weeksAhead)
        let plan = try XCTUnwrap(GoalPlanner.plan(settings: settings, baseline: GoalFixture.fixtureReport(),
                                                  today: GoalFixture.today).plan)
        XCTAssertNotNil(plan.rebuildDate, "the fixture plan starts mid-week, so it is provisional")
        return plan
    }

    /// The fixture runner's usual Thursday, Saturday and Sunday after the
    /// Wednesday plan.
    private func restOfWeek() -> [Activity] {
        let w = BaselineFixture.weeks
        return [GoalFixture.run("rest-thu", week: w, day: .thursday, minutes: 35),
                GoalFixture.run("rest-sat", week: w, day: .saturday, minutes: 35),
                GoalFixture.run("rest-sun", week: w, day: .sunday, minutes: 80, hour: 8)]
    }

    /// The fixture runner's usual week in the plan's first week.
    private func firstWeek() -> [Activity] {
        let w = BaselineFixture.weeks + 1
        return [GoalFixture.run("first-tue", week: w, day: .tuesday, minutes: 35),
                GoalFixture.run("first-thu", week: w, day: .thursday, minutes: 35),
                GoalFixture.run("first-sat", week: w, day: .saturday, minutes: 35),
                GoalFixture.run("first-sun", week: w, day: .sunday, minutes: 80, hour: 8)]
    }

    /// `run` with a baseline built from the fixture runner plus `extra`, as of
    /// the options given (or as of `asOf` instead, to mimic a wiring bug).
    private func run(_ current: ProvisionalRebuild.CurrentPlan, now: Date, extra: [Activity] = [],
                     asOf: Date? = nil, recorder: Recorder) async -> ProvisionalRebuild.Attempt? {
        await ProvisionalRebuild.run(current, freezes: [], now: now, timeZone: tz,
                                     baseline: { options in
                                         recorder.baselineOptions.append(options)
                                         return GoalFixture.fixtureReport(asOf: asOf ?? options.asOf) { $0 += extra }
                                     },
                                     log: { recorder.logged.append($0) },
                                     fail: { recorder.failed.append($0) })
    }

    // MARK: Rebuild

    /// Due at 10:00 on the rebuild Monday: the baseline is built as of the
    /// rebuild date (`today`), not now; the rebuild replaces the plan and
    /// clears any retry and note.
    func testRebuildBuildsTheBaselineAsOfTodayAndReplacesThePlan() async throws {
        let first = try provisionalPlan()
        let monday = try XCTUnwrap(first.rebuildDate)
        let now = monday.addingTimeInterval(10 * 3600)
        var current = ProvisionalRebuild.CurrentPlan(first)
        let recorder = Recorder()

        let attempt = await run(current, now: now, extra: restOfWeek(), recorder: recorder)
        let a = try XCTUnwrap(attempt)
        XCTAssertEqual(recorder.baselineOptions.map(\.asOf), [monday], "as of today, not now")
        XCTAssertEqual(recorder.baselineOptions.first?.timeZone, tz)
        XCTAssertEqual(a.base, current)
        XCTAssertTrue(a.outcome.isRebuilt, "\(String(describing: a.outcome.note))")
        XCTAssertTrue(recorder.logged.isEmpty)
        XCTAssertTrue(recorder.failed.isEmpty)

        XCTAssertEqual(current.apply(a), .replaced)
        XCTAssertEqual(current.plan, a.outcome.plan)
        XCTAssertNil(current.plan.rebuildDate)
        XCTAssertEqual(current.plan.plan.weeks.first?.weekStart, monday)
        XCTAssertNil(current.retryAt)
        XCTAssertNil(current.refusalNote)

        // A final plan: nothing more to do.
        let again = await run(current, now: now, recorder: recorder)
        XCTAssertNil(again)
        XCTAssertEqual(recorder.baselineOptions.count, 1)
    }

    /// Before the rebuild date nothing is built, and a final plan never is.
    func testNothingIsBuiltBeforeTheRebuildDate() async throws {
        let first = try provisionalPlan()
        let monday = try XCTUnwrap(first.rebuildDate)
        let recorder = Recorder()
        for now in [GoalFixture.today, monday.addingTimeInterval(-1)] {
            let attempt = await run(.init(first), now: now, recorder: recorder)
            XCTAssertNil(attempt)
        }
        XCTAssertTrue(recorder.baselineOptions.isEmpty)
        XCTAssertTrue(recorder.logged.isEmpty)
    }

    /// The provisional note the refusal note stands in for is the plan's last
    /// note (SPEC F3, #102).
    func testTheProvisionalNoteIsTheLastNote() throws {
        let first = try provisionalPlan()
        XCTAssertTrue(first.plan.isProvisional)
        let last = try XCTUnwrap(first.plan.notes.last)
        XCTAssertTrue(last.contains("provisional"), last)
        XCTAssertEqual(first.plan.notes.filter { $0.contains("provisional") }, [last])
    }

    // MARK: Refusal, retry, keep

    /// A baseline built as of now (a wiring bug) is refused through the real
    /// GoalPlanner: the plan is kept with the next Monday's retry and the
    /// refusal note, the problem is logged and failed once, and the stored
    /// retry holds the next rebuild off until then. That rebuild, from the
    /// latest Monday with the first week as history, replaces the plan and
    /// clears the retry and the note.
    func testWiringRefusalIsKeptLoggedAndRetriedThenRebuilt() async throws {
        let first = try provisionalPlan()
        let monday = try XCTUnwrap(first.rebuildDate)
        let next = PlanCalendar.nextWeekStart(after: monday, timeZone: tz)
        let now = monday.addingTimeInterval(10 * 3600)
        var current = ProvisionalRebuild.CurrentPlan(first)
        let recorder = Recorder()

        let refusedAttempt = await run(current, now: now, extra: restOfWeek(), asOf: now, recorder: recorder)
        let refused = try XCTUnwrap(refusedAttempt)
        XCTAssertFalse(refused.outcome.isRebuilt)
        XCTAssertTrue(refused.outcome.isWiringError)
        XCTAssertEqual(recorder.logged.count, 1)
        XCTAssertEqual(recorder.failed, recorder.logged)
        guard case .wiringError(let issues)? = recorder.logged.first else {
            return XCTFail("\(recorder.logged)")
        }
        XCTAssertFalse(issues.isEmpty)
        XCTAssertTrue(issues.allSatisfy(ProvisionalRebuild.isWiringError))
        XCTAssertFalse(recorder.logged[0].message.isEmpty)

        XCTAssertEqual(current.apply(refused), .refusalStored, "kept, not replaced")
        XCTAssertEqual(current.plan, first)
        XCTAssertEqual(current.retryAt, next)
        XCTAssertEqual(current.refusalNote, refused.outcome.note)
        XCTAssertEqual(current.refusalNote?.contains("tried again"), true)

        // The stored retry holds it off for the rest of the week.
        for later in [now.addingTimeInterval(3600), next.addingTimeInterval(-1)] {
            let held = await run(current, now: later, recorder: recorder)
            XCTAssertNil(held)
        }
        XCTAssertEqual(recorder.baselineOptions.count, 1)

        // From the retry Monday (here on its Wednesday), rebuilt as of it.
        let wednesday = BaselineFixture.date(day: (BaselineFixture.weeks + 2) * 7 + PlanWeekday.wednesday.rawValue,
                                             hour: 9)
        XCTAssertEqual(PlanCalendar.weekStart(containing: wednesday, timeZone: tz), next)
        let retried = await run(current, now: wednesday, extra: restOfWeek() + firstWeek(), recorder: recorder)
        let rebuilt = try XCTUnwrap(retried)
        XCTAssertEqual(recorder.baselineOptions.last?.asOf, next)
        XCTAssertTrue(rebuilt.outcome.isRebuilt, "\(String(describing: rebuilt.outcome.note))")
        XCTAssertEqual(recorder.logged.count, 1, "no new problem")
        XCTAssertEqual(current.apply(rebuilt), .replaced)
        XCTAssertNil(current.retryAt)
        XCTAssertNil(current.refusalNote)
        XCTAssertNil(current.plan.rebuildDate)
        XCTAssertEqual(current.plan.plan.weeks.first?.weekStart, next)
    }

    /// `replace` (a goal edit or a new plan) clears a stored retry and note.
    func testReplaceClearsTheRetryAndTheNote() async throws {
        let first = try provisionalPlan()
        let monday = try XCTUnwrap(first.rebuildDate)
        var current = ProvisionalRebuild.CurrentPlan(first)
        let recorder = Recorder()
        let attempt = await run(current, now: monday.addingTimeInterval(3600), asOf: monday.addingTimeInterval(3600),
                                recorder: recorder)
        XCTAssertEqual(current.apply(try XCTUnwrap(attempt)), .refusalStored)
        XCTAssertNotNil(current.retryAt)
        XCTAssertNotNil(current.refusalNote)

        let edited = try provisionalPlan(weeksAhead: 16)
        current.replace(with: edited)
        XCTAssertEqual(current.plan, edited)
        XCTAssertNil(current.retryAt)
        XCTAssertNil(current.refusalNote)
    }

    // MARK: Stale attempts

    /// An attempt whose base is no longer the plan in use (a goal edit or a
    /// new plan, or another attempt applied, while the baseline was built)
    /// changes nothing.
    func testAStaleAttemptIsIgnored() async throws {
        let first = try provisionalPlan()
        let monday = try XCTUnwrap(first.rebuildDate)
        let now = monday.addingTimeInterval(10 * 3600)
        let base = ProvisionalRebuild.CurrentPlan(first)
        let recorder = Recorder()
        let rebuiltAttempt = await run(base, now: now, extra: restOfWeek(), recorder: recorder)
        let rebuilt = try XCTUnwrap(rebuiltAttempt)
        let refusedAttempt = await run(base, now: now, extra: restOfWeek(), asOf: now, recorder: recorder)
        let refused = try XCTUnwrap(refusedAttempt)
        XCTAssertTrue(rebuilt.outcome.isRebuilt)
        XCTAssertFalse(refused.outcome.isRebuilt)

        // A goal edit during the rebuild: neither attempt overwrites it.
        let edited = try provisionalPlan(weeksAhead: 16)
        var current = base
        current.replace(with: edited)
        let afterEdit = current
        XCTAssertEqual(current.apply(rebuilt), .stale)
        XCTAssertEqual(current.apply(refused), .stale)
        XCTAssertEqual(current, afterEdit)

        // Another attempt applied first (here the refusal): the rebuild from
        // the same base is stale too, and vice versa.
        var kept = base
        XCTAssertEqual(kept.apply(refused), .refusalStored)
        XCTAssertEqual(kept.plan, base.plan)
        XCTAssertEqual(kept.retryAt, refused.outcome.retryAt)
        XCTAssertNotNil(kept.retryAt)
        XCTAssertEqual(kept.refusalNote, refused.outcome.note)
        XCTAssertNotNil(kept.refusalNote)
        XCTAssertNotEqual(kept.token, base.token)
        let afterRefusal = kept
        XCTAssertEqual(kept.apply(rebuilt), .stale)
        XCTAssertEqual(kept.apply(refused), .stale, "applied once only")
        XCTAssertEqual(kept, afterRefusal)

        var replaced = base
        XCTAssertEqual(replaced.apply(rebuilt), .replaced)
        XCTAssertEqual(replaced.plan, rebuilt.outcome.plan)
        let afterRebuild = replaced
        XCTAssertEqual(replaced.apply(refused), .stale)
        XCTAssertEqual(replaced.apply(rebuilt), .stale, "applied once only")
        XCTAssertEqual(replaced, afterRebuild)
    }

    /// Unknown-time runs keep NaN durations in the plan's history (#40), so
    /// two copies of one plan built separately are not `==`. An attempt
    /// still applies to the same state restored from storage (the token
    /// round-tripped through JSON, the plan built again), and is still
    /// stale for a different state.
    func testAnAttemptAppliesToTheSameStateRestoredWithUnknownTimeRuns() async throws {
        let settings = GoalFixture.settings(distance: Distance.halfMarathon, weeksAhead: 14)
        let unknown = Activity(id: "unknown-time", source: .healthKit,
                               start: BaselineFixture.date(day: 1 * 7 + PlanWeekday.wednesday.rawValue, hour: 7),
                               durationSeconds: .nan, distanceMeters: 6000)
        func build() throws -> GoalPlan {
            let report = GoalFixture.fixtureReport { $0.append(unknown) }
            let result = GoalPlanner.plan(settings: settings, baseline: report, today: GoalFixture.today)
            return try XCTUnwrap(result.plan, "\(result.issues)")
        }
        let stored = try build()
        let loaded = try build()
        XCTAssertTrue(stored.history.contains { $0.id == unknown.id && $0.durationSeconds.isNaN })
        XCTAssertNotEqual(stored, loaded, "NaN history: equal in value, not ==")
        let monday = try XCTUnwrap(stored.rebuildDate)
        let now = monday.addingTimeInterval(10 * 3600)

        let base = ProvisionalRebuild.CurrentPlan(stored)
        let recorder = Recorder()
        let refusedAttempt = await run(base, now: now, extra: [unknown], asOf: now, recorder: recorder)
        let refused = try XCTUnwrap(refusedAttempt)
        XCTAssertFalse(refused.outcome.isRebuilt)

        // Restore the same state from storage: the token through JSON, the
        // plan rebuilt from the same inputs.
        let data = try JSONEncoder().encode(base.token)
        let token = try JSONDecoder().decode(ProvisionalRebuild.CurrentPlan.Token.self, from: data)
        var restored = ProvisionalRebuild.CurrentPlan(restoring: loaded, retryAt: base.retryAt,
                                                      refusalNote: base.refusalNote, token: token)
        XCTAssertEqual(restored.apply(refused), .refusalStored)
        XCTAssertEqual(restored.retryAt, PlanCalendar.nextWeekStart(after: monday, timeZone: tz))
        XCTAssertEqual(restored.refusalNote, refused.outcome.note)

        // Restored again after the refusal was stored, the next attempt
        // from that state applies too, and the refused one is stale.
        let data2 = try JSONEncoder().encode(restored.token)
        var again = ProvisionalRebuild.CurrentPlan(
            restoring: try build(), retryAt: restored.retryAt, refusalNote: restored.refusalNote,
            token: try JSONDecoder().decode(ProvisionalRebuild.CurrentPlan.Token.self, from: data2))
        XCTAssertEqual(again.apply(refused), .stale)
        let wednesday = BaselineFixture.date(day: (BaselineFixture.weeks + 2) * 7 + PlanWeekday.wednesday.rawValue,
                                             hour: 9)
        let rebuiltAttempt = await run(restored, now: wednesday, extra: [unknown] + restOfWeek() + firstWeek(),
                                       recorder: recorder)
        let rebuilt = try XCTUnwrap(rebuiltAttempt)
        XCTAssertTrue(rebuilt.outcome.isRebuilt, "\(String(describing: rebuilt.outcome.note))")
        XCTAssertEqual(again.apply(rebuilt), .replaced)
        XCTAssertNil(again.retryAt)
        XCTAssertNil(again.refusalNote)

        // A different state with an equal plan is still stale.
        var other = ProvisionalRebuild.CurrentPlan(loaded)
        XCTAssertEqual(other.apply(refused), .stale)
        XCTAssertNil(other.retryAt)
    }

    // MARK: Invalid dates

    /// A non-finite now is logged, not failed, and nothing is built or changed.
    func testNonFiniteNowIsLoggedAndNothingIsBuilt() async throws {
        let first = try provisionalPlan()
        let recorder = Recorder()
        for now in [Date(timeIntervalSinceReferenceDate: .nan), Date(timeIntervalSinceReferenceDate: .infinity)] {
            let attempt = await run(.init(first), now: now, recorder: recorder)
            XCTAssertNil(attempt)
        }
        XCTAssertEqual(recorder.logged, [.invalidDate, .invalidDate])
        XCTAssertTrue(recorder.failed.isEmpty)
        XCTAssertTrue(recorder.baselineOptions.isEmpty)
        XCTAssertFalse(ProvisionalRebuild.Problem.invalidDate.message.isEmpty)
    }

    /// Once the race week has begun, nothing is tried and nothing is logged.
    func testNothingIsTriedInTheRaceWeek() async throws {
        let first = try provisionalPlan()
        let raceWeek = try XCTUnwrap(first.plan.weeks.last?.weekStart)
        let recorder = Recorder()
        let attempt = await run(.init(first), now: raceWeek.addingTimeInterval(3600), recorder: recorder)
        XCTAssertNil(attempt)
        XCTAssertTrue(recorder.baselineOptions.isEmpty)
        XCTAssertTrue(recorder.logged.isEmpty)
    }
}
