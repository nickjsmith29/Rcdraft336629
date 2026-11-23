import XCTest
@testable import CoachCore

// Edge cases from the #47 review: re-synced runs, volume holds that can't be
// met, missed sessions around a race, same-time pain check-ins and a replay
// across a daylight-saving change. Synthetic plans only.
final class AdaptationEdgeCaseTests: XCTestCase {
    typealias F = AdaptFixture

    private func find(_ id: String, _ plan: [PlannedWorkout]) -> PlannedWorkout? { plan.first { $0.id == id } }
    private func race(_ id: String, week: Int, day: Int, minutes: Double) -> PlannedWorkout {
        PlannedWorkout(id: id, date: F.date(week: week, day: day, hour: 8), kind: .race, durationSeconds: minutes * 60)
    }

    // MARK: Re-synced runs

    func testReSyncedQualityRunIsANoOp() {
        let plan = F.weeks(0..<2)
        let run = F.run(for: plan.first { $0.id == "t0" }!, F.RunSpec(pace: 0.97))
        let first = AdaptationEngine.processRun(run, state: AdaptationState(), plan: plan, history: [], context: F.context())
        XCTAssertEqual(first.history.map(\.id), [run.activity.id])
        XCTAssertEqual(first.state.qualitySignals.count, 1)

        let again = AdaptationEngine.processRun(run, state: first.state, plan: first.plan, history: first.history,
                                                context: F.context())
        XCTAssertTrue(again.changes.isEmpty)
        XCTAssertNil(again.assessment)
        XCTAssertEqual(again.state, first.state)
        XCTAssertEqual(again.plan, first.plan)
        XCTAssertEqual(again.history, first.history)
        XCTAssertTrue(again.state.easyHeartRates.isEmpty, "not logged a second time as an unplanned easy run")
        XCTAssertTrue(again.guardrailReport.passed)

        // Known only from history (say, state restored from an older copy) is still a no-op.
        let fromHistory = AdaptationEngine.processRun(run, state: AdaptationState(), plan: first.plan,
                                                      history: first.history, context: F.context())
        XCTAssertEqual(fromHistory.history, first.history)
        XCTAssertTrue(fromHistory.changes.isEmpty)
    }

    func testUnplannedHardRunStaysOutOfTheEasyCapCheck() {
        let hard = F.run(for: F.threshold("u", week: 0, day: 2), F.RunSpec(hr: .high))   // Wednesday, nothing planned
        let o = AdaptationEngine.processRun(hard, state: AdaptationState(), plan: F.weeks(0..<2), history: [],
                                            context: F.context())
        XCTAssertNil(o.assessment?.plannedWorkoutID)
        XCTAssertTrue(o.state.easyHeartRates.isEmpty)
    }

    // MARK: Volume holds

    /// The long-run share guardrail (35%) would cut a long run below a hold's
    /// floor once easy runs go; these tests lift it to see the hold alone.
    private let wideShare = AdaptationContext(zones: F.zones, timeZone: F.tz, tracksPain: false,
                                              guardrails: GuardrailLimits(maxLongRunShare: 1))

    /// Week 1 plans Tue threshold 54, Thu easy 55, Sat long 60, Sun easy 45 (214 min).
    private func hold(level minutes: Double, floor: Double?) -> AdaptationState {
        let start = F.date(week: 1, day: 0, hour: 0)
        return AdaptationState(holds: [VolumeHold(interval: DateInterval(start: start, duration: 7 * 86_400),
                                                  level: minutes * 60, longRunFloorSeconds: floor.map { $0 * 60 })])
    }

    func testHoldThatCannotBeMetReportsTheShortfall() throws {
        // Quality 54 plus the long run's floor of 51 is 105 min, above a 100 min hold.
        let o = AdaptationEngine.processDay(asOf: F.date(week: 1, day: 0, hour: 6), state: hold(level: 100, floor: 51),
                                            plan: F.weeks(0..<2), history: [], context: wideShare)
        XCTAssertFalse(o.holdsSatisfied)
        XCTAssertEqual(find("t1", o.plan)?.durationSeconds, 54 * 60, "a hold never cuts quality")
        XCTAssertEqual(find("l1", o.plan)?.durationSeconds, 51 * 60, "a long run stops at its floor")
        XCTAssertNil(find("e1a", o.plan)); XCTAssertNil(find("e1b", o.plan))
        let shortfalls = o.changes.filter { $0.kind == .holdShortfall }
        XCTAssertEqual(shortfalls.count, 1)
        let s = try XCTUnwrap(shortfalls.first)
        // The cuts cite the 214 min planned; the shortfall cites the plan as it now stands.
        XCTAssertEqual(o.changes.first { $0.kind == .sessionDropped && $0.triggers.first?.metric == .weeklyVolume }?.triggers.first?.value, 214 * 60)
        XCTAssertEqual(s.triggers.first?.value, 105 * 60, "the planned volume")
        XCTAssertEqual(s.triggers.first?.expectedHigh, 100 * 60, "the held level")
        XCTAssertEqual(s.triggers.last?.value, 105 * 60, "what is left after cutting")
        XCTAssertTrue(s.explanation.contains("5 min over"), s.explanation)
        XCTAssertTrue(o.guardrailReport.passed)

        // The next event finds the same shortfall: still unsatisfied, but not
        // posted again (#51), and nothing more is cut.
        let next = AdaptationEngine.processDay(asOf: F.date(week: 1, day: 1, hour: 6), state: o.state, plan: o.plan,
                                               history: o.history, context: wideShare)
        XCTAssertFalse(next.holdsSatisfied)
        XCTAssertEqual(next.changes, [])
        XCTAssertEqual(next.state.reportedHoldShortfalls, [s])
        XCTAssertEqual(next.plan, o.plan)
    }

    func testHoldThatCanBeMetIsSatisfied() {
        // Week 0 was run (history), so its long run stays the 30-day reference (3.5 rule 1).
        let o = AdaptationEngine.processDay(asOf: F.date(week: 1, day: 0, hour: 6), state: hold(level: 180, floor: 51),
                                            plan: F.weeks(1..<2), history: F.weeks(0..<1), context: F.context())
        XCTAssertTrue(o.holdsSatisfied)
        XCTAssertFalse(o.changes.contains { $0.kind == .holdShortfall })
        XCTAssertLessThanOrEqual(F.weekVolume(1, o.plan), 180 * 60)
        XCTAssertEqual(find("l1", o.plan)?.durationSeconds, 60 * 60, "easy runs go first")
        XCTAssertTrue(AdaptationEngine.processDay(asOf: F.date(week: 1, day: 0, hour: 6), state: AdaptationState(),
                                                  plan: F.weeks(0..<2), history: [], context: F.context()).holdsSatisfied)
    }

    func testHoldWithoutAFloorLeavesTheLongRunAlone() {
        let o = AdaptationEngine.processDay(asOf: F.date(week: 1, day: 0, hour: 6), state: hold(level: 100, floor: nil),
                                            plan: F.weeks(1..<2), history: F.weeks(0..<1), context: wideShare)
        XCTAssertEqual(find("l1", o.plan)?.durationSeconds, 60 * 60)
        XCTAssertFalse(o.holdsSatisfied)
        XCTAssertEqual(o.changes.first { $0.kind == .holdShortfall }?.triggers.last?.value, 114 * 60)
    }

    func testHoldShortfallWithTheDefaultGuardrails() {
        // Two threshold sessions (108 min) can't fit a 100 min hold; the easy run goes.
        let week1 = [F.threshold("t1", week: 1, day: 1), F.threshold("q1", week: 1, day: 3),
                     F.easy("e1", week: 1, day: 5, minutes: 40)]
        let o = AdaptationEngine.processDay(asOf: F.date(week: 1, day: 0, hour: 6), state: hold(level: 100, floor: 51),
                                            plan: F.weeks(0..<1) + week1, history: [], context: F.context())
        XCTAssertFalse(o.holdsSatisfied)
        XCTAssertNil(find("e1", o.plan))
        XCTAssertEqual(o.plan.filter { $0.kind.isQuality && $0.date >= F.date(week: 1, day: 0) }, Array(week1.prefix(2)))
        let s = o.changes.first { $0.kind == .holdShortfall }
        XCTAssertEqual(o.changes.first { $0.kind == .sessionDropped && $0.triggers.first?.metric == .weeklyVolume }?.triggers.first?.value, 148 * 60)
        XCTAssertEqual(s?.triggers.first?.value, 108 * 60)
        XCTAssertEqual(s?.triggers.last?.value, 108 * 60)
        XCTAssertTrue(s?.explanation.contains("8 min over") ?? false, s?.explanation ?? "")
        assertAdaptationSound([o])
    }

    func testHoldInRaceWeekComparesOnlyNonRaceVolume() {
        // Race week: Tue threshold 54, Thu easy 40, Sun race 90.
        let week1 = [F.threshold("t1", week: 1, day: 1), F.easy("e1a", week: 1, day: 3, minutes: 40),
                     race("r", week: 1, day: 6, minutes: 90)]
        let plan = F.weeks(0..<1) + week1
        let asOf = F.date(week: 1, day: 0, hour: 6)

        // 94 min outside the race is under a 100 min hold: nothing is cut.
        let under = AdaptationEngine.processDay(asOf: asOf, state: hold(level: 100, floor: 51), plan: plan, history: [],
                                                context: F.context())
        XCTAssertTrue(under.holdsSatisfied)
        XCTAssertEqual(under.plan.filter { $0.date >= asOf }, week1)

        // An 80 min hold trims the easy run to 26 min and never touches the race or the quality session.
        let trimmed = AdaptationEngine.processDay(asOf: asOf, state: hold(level: 80, floor: 51), plan: plan, history: [],
                                                  context: F.context())
        XCTAssertTrue(trimmed.holdsSatisfied)
        XCTAssertEqual(find("e1a", trimmed.plan)?.durationSeconds, 26 * 60)
        XCTAssertEqual(find("r", trimmed.plan), week1[2])
        XCTAssertEqual(find("t1", trimmed.plan), week1[0])

        // A 50 min hold can't be met without cutting quality: reported, race and quality kept.
        let short = AdaptationEngine.processDay(asOf: asOf, state: hold(level: 50, floor: 51), plan: plan, history: [],
                                                context: F.context())
        XCTAssertFalse(short.holdsSatisfied)
        XCTAssertEqual(find("r", short.plan), week1[2])
        XCTAssertEqual(find("t1", short.plan), week1[0])
        let s = short.changes.first { $0.kind == .holdShortfall }
        XCTAssertEqual(s?.triggers.last?.value, 54 * 60, "only the quality session is left outside the race")
        XCTAssertTrue(s?.explanation.contains("outside the race") ?? false)
    }

    // MARK: Missed sessions around a race

    func testMissedLongRunInRaceWeekIsDroppedRatherThanPutNextToTheRace() {
        // Mon long (missed), Sat easy, Sun race.
        let plan = [F.long("l1", week: 1, day: 0, minutes: 60), F.easy("e1b", week: 1, day: 5, minutes: 40),
                    race("r", week: 1, day: 6, minutes: 90)]
        let o = AdaptationEngine.processDay(asOf: F.date(week: 1, day: 1, hour: 6), state: AdaptationState(), plan: plan,
                                            history: [], context: F.context())
        XCTAssertEqual(o.plan.map(\.id), ["e1b", "r"])
        XCTAssertEqual(find("e1b", o.plan)?.kind, .easy)
        let drop = o.changes.first { $0.kind == .sessionDropped }
        XCTAssertEqual(drop?.workoutIDs, ["l1"])
        XCTAssertTrue(drop?.explanation.contains("race") ?? false, drop?.explanation ?? "")
        XCTAssertFalse(o.changes.contains { $0.kind == .sessionMoved })
    }

    func testMissedQualityInRaceWeekIsNotPutNextToTheRace() {
        // Tue threshold (missed), Sat easy, Sun race.
        let plan = [F.threshold("t1", week: 1, day: 1), F.easy("e1b", week: 1, day: 5, minutes: 40),
                    race("r", week: 1, day: 6, minutes: 90)]
        let o = AdaptationEngine.processDay(asOf: F.date(week: 1, day: 2, hour: 6), state: AdaptationState(), plan: plan,
                                            history: [], context: F.context())
        XCTAssertEqual(find("e1b", o.plan)?.kind, .easy)
        XCTAssertEqual(o.changes.first { $0.kind == .sessionDropped }?.workoutIDs, ["t1"])
    }

    func testMissedLongRunInTheWeekBeforeAMondayRace() {
        let monday = race("r", week: 1, day: 0, minutes: 90)
        // Tue long (missed), Sun easy (the day before the race).
        let alone = [F.long("l0", week: 0, day: 1, minutes: 60), F.easy("e0b", week: 0, day: 6, minutes: 40), monday]
        let dropped = AdaptationEngine.processDay(asOf: F.date(week: 0, day: 2, hour: 6), state: AdaptationState(),
                                                  plan: alone, history: [], context: F.context())
        XCTAssertEqual(find("e0b", dropped.plan)?.kind, .easy)
        XCTAssertEqual(dropped.changes.first { $0.kind == .sessionDropped }?.workoutIDs, ["l0"])
        XCTAssertTrue(dropped.changes.first { $0.kind == .sessionDropped }?.explanation.contains("race") ?? false)

        // With a Thursday easy run too, the long run takes Thursday, away from the race.
        let withThursday = alone + [F.easy("e0a", week: 0, day: 3, minutes: 40)]
        let moved = AdaptationEngine.processDay(asOf: F.date(week: 0, day: 2, hour: 6), state: AdaptationState(),
                                                plan: withThursday, history: [], context: F.context())
        XCTAssertEqual(moved.changes.first { $0.kind == .sessionMoved }?.workoutIDs, ["l0", "e0a"])
        XCTAssertEqual(find("l0", moved.plan)?.date, F.date(week: 0, day: 3))
        XCTAssertEqual(find("e0b", moved.plan)?.kind, .easy)
    }

    // MARK: Pain check-ins at the same time

    func testZeroAndTwoAtTheSameTimeAreNoRise() {
        let t = F.date(week: 0, day: 0, hour: 8)
        for order in [[0, 2], [2, 0]] {
            var state = AdaptationState(), plan = F.weeks(0..<2)
            var changes: [PlanChange] = []
            for score in order {
                let o = AdaptationEngine.processCheckIn(PainCheckIn(date: t, score: score), state: state, plan: plan,
                                                        history: [], context: F.context(tracksPain: true))
                state = o.state; plan = o.plan; changes += o.changes
            }
            XCTAssertTrue(changes.isEmpty, "order \(order): \(changes.map(\.kind))")
            XCTAssertNil(state.appliedPainResponse)
            XCTAssertEqual(state.painCheckIns.count, 2, "both are kept as received")
        }
        // A real rise, an hour later, still fires.
        let later = AdaptationReplay.replay([.painCheckIn(PainCheckIn(date: t, score: 0)),
                                             .painCheckIn(PainCheckIn(date: t, score: 2)),
                                             .painCheckIn(PainCheckIn(date: t.addingTimeInterval(3600), score: 2))],
                                            plan: F.weeks(0..<2), mornings: false, context: F.context(tracksPain: true))
        XCTAssertNil(later.last?.outcome.state.appliedPainResponse, "2 after 2 is no rise")
    }

    // MARK: Daylight saving

    func testReplayAcrossTheEndOfDaylightSavingInNewYork() throws {
        let ny = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let cal = PlanCalendar.calendar(timeZone: ny)
        // Week 0 starts Monday 19 October 2026; clocks go back at 02:00 on Sunday 1 November (week 1, day 6).
        let monday = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 10, day: 19)))
        func local(_ w: PlannedWorkout) -> PlannedWorkout {
            let offset = w.date.timeIntervalSince(PlanFixture.firstMonday)
            let days = Int(offset / 86_400), seconds = offset - Double(days) * 86_400
            var moved = w
            moved.date = cal.date(byAdding: .day, value: days, to: monday)!.addingTimeInterval(seconds)
            return moved
        }
        // Thursday of week 0 runs late: 55 min from 23:30, across midnight.
        var source = F.weeks(0..<3).filter { $0.id != "e0a" }
        source.append(F.easy("e0a", week: 0, day: 3, minutes: 55, hour: 23).moved(by: 1800))
        let plan = source.map(local).sorted { $0.date < $1.date }
        let context = AdaptationContext(zones: F.zones, timeZone: ny, tracksPain: false, limits: .default)

        // Run everything in weeks 0 and 1 except Sunday 1 November's easy run.
        let events = plan.filter { $0.date < cal.date(byAdding: .day, value: 14, to: monday)! && $0.id != "e1b" }
            .map { AdaptationReplay.Event.run(F.run(for: $0)) }
            + [.day(cal.date(byAdding: .day, value: 14, to: monday)!.addingTimeInterval(6 * 3600))]
        let steps = AdaptationReplay.replay(events, plan: plan, context: context)

        // A morning call at each local midnight, one per calendar day, the DST day 25 hours long.
        let mornings = steps.compactMap { s -> Date? in if case .day(let d) = s.event, cal.startOfDay(for: d) == d { return d }; return nil }
        XCTAssertEqual(mornings.first, cal.date(byAdding: .day, value: 1, to: monday))
        XCTAssertEqual(mornings.last, cal.date(byAdding: .day, value: 14, to: monday))
        XCTAssertEqual(mornings.count, 14)
        for (a, b) in zip(mornings, mornings.dropFirst()) {
            XCTAssertEqual(cal.dateComponents([.day], from: a, to: b).day, 1)
        }
        let nov1 = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        let nov2 = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 11, day: 2)))
        XCTAssertTrue(mornings.contains(nov1) && mornings.contains(nov2))
        XCTAssertEqual(nov2.timeIntervalSince(nov1), 25 * 3600)

        // The late Thursday run is matched to its own session, not logged as unplanned.
        let late = steps.compactMap(\.outcome.assessment).first { $0.activityID == "run-e0a" }
        XCTAssertEqual(late?.plannedWorkoutID, "e0a")

        // The DST-day easy run is dropped by Monday 2 November's morning call.
        let dropStep = try XCTUnwrap(steps.first { $0.outcome.changes.contains { $0.kind == .sessionDropped } })
        XCTAssertEqual(dropStep.event, .day(nov2))
        XCTAssertEqual(dropStep.outcome.changes.first { $0.kind == .sessionDropped }?.workoutIDs, ["e1b"])

        // Week maths in local time: Sunday 1 November belongs to the week of 26 October.
        let sunday = try XCTUnwrap(plan.first { $0.id == "e1b" }).date
        XCTAssertEqual(PlanCalendar.weekStart(containing: sunday, timeZone: ny), cal.date(byAdding: .day, value: 7, to: monday))
        let final = try XCTUnwrap(steps.last).outcome
        func week(_ n: Int, _ all: [PlannedWorkout]) -> Double {
            let start = cal.date(byAdding: .day, value: 7 * n, to: monday)!
            return all.filter { PlanCalendar.weekStart(containing: $0.date, timeZone: ny) == start }.reduce(0) { $0 + $1.durationSeconds }
        }
        XCTAssertEqual(week(0, final.history), week(0, plan), accuracy: 60)
        XCTAssertEqual(week(1, final.history), week(1, plan) - 45 * 60, accuracy: 60)
        XCTAssertEqual(final.history.count, 7)
        for s in steps {
            XCTAssertTrue(s.outcome.guardrailReport.passed, "\(s.event): \(s.outcome.guardrailReport.violations.map(\.explanation))")
            XCTAssertTrue(s.outcome.changes.allSatisfy { !$0.triggers.isEmpty })
        }
    }
}

private extension PlannedWorkout {
    func moved(by seconds: TimeInterval) -> PlannedWorkout {
        var w = self
        w.date = date.addingTimeInterval(seconds)
        return w
    }
}
