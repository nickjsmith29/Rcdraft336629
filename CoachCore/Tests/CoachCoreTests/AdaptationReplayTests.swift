import XCTest
@testable import CoachCore

// F4 acceptance: replaying synthetic fixture runs through the engine gives
// sensible, explained changes, each citing its trigger metrics (SPEC 7, F4).
final class AdaptationReplayTests: XCTestCase {
    typealias F = AdaptFixture

    func testReplayOfPrerecordedEventsOnAHandBuiltPlan() {
        let plan = F.weeks(0..<3, easyMinutes: { _ in (65, 55) }, longMinutes: { _ in 55 })
        func s(_ id: String) -> PlannedWorkout { plan.first { $0.id == id }! }
        var events: [AdaptationReplay.Event] = [
            .run(F.run(for: s("t0"), F.RunSpec(pace: 0.97))),
            .run(F.run(for: s("e0a"))),
            .run(F.run(for: s("l0"))),
            .run(F.run(for: s("e0b"))),
            .run(F.run(for: s("t1"), F.RunSpec(pace: 0.97))),
            // e1a (Thursday) is skipped.
            .run(F.run(for: s("l1"))),
            .painCheckIn(PainCheckIn(date: F.date(week: 1, day: 5, hour: 10), score: 4)),
            .run(F.run(for: s("e1b"))),
            .day(F.date(week: 2, day: 0, hour: 6)),
        ]
        events.reverse()   // the harness orders events by time itself
        let steps = AdaptationReplay.replay(events, plan: plan, context: F.context(tracksPain: true))
        // One step per event plus a morning call for each day from Tuesday of week 0 to Monday of week 2.
        XCTAssertEqual(steps.filter { if case .day = $0.event { return false }; return true }.count, events.count - 1)
        XCTAssertEqual(steps.count, events.count + 14)
        XCTAssertEqual(steps.map(\.event.date), steps.map(\.event.date).sorted())
        let outcomes = steps.map(\.outcome)
        let changes = outcomes.flatMap(\.changes)
        let kinds = Set(changes.map(\.kind))
        XCTAssertTrue(kinds.isSuperset(of: [.paceTargetsFaster, .sessionDropped, .painVolumeFreeze, .qualitySwappedToEasy]),
                      "\(kinds)")
        XCTAssertEqual(changes.first { $0.kind == .paceTargetsFaster }?.workoutIDs, ["t2"])
        XCTAssertEqual(changes.filter { $0.kind == .sessionDropped }.flatMap(\.workoutIDs), ["e1a"])
        XCTAssertEqual(changes.first { $0.kind == .qualitySwappedToEasy }?.workoutIDs, ["t2"])
        // e1a was dropped by Friday's morning call, before Saturday's long run.
        let friday = steps.first { $0.event == .day(F.date(week: 1, day: 4, hour: 0)) }!
        // With e1a dropped, week 1 holds 2 h 44 min, and going straight back
        // to week 2's 3 h 49 min would be more than 20% more: a cut week
        // (SPEC 3.5 rule 6), so week 2 is held to the regrowth's bound.
        XCTAssertEqual(friday.outcome.changes.first?.kind, .sessionDropped)
        for c in friday.outcome.changes.dropFirst() {
            XCTAssertEqual(c.kind, .sessionShortened)
            XCTAssertTrue(c.explanation.contains("SPEC 3.5 rule 6"), c.explanation)
        }
        let t2 = outcomes.last!.plan.first { $0.id == "t2" }!
        XCTAssertEqual(t2.kind, .easy)
        XCTAssertEqual(outcomes.last!.history.count, 7)
        XCTAssertEqual(outcomes.last!.state.assessments.map(\.signal),
                       [.ahead, .onTrack, .onTrack, .onTrack, .ahead, .onTrack, .onTrack])
        assertAdaptationSound(outcomes)
    }

    func testReplayingAPlanBuilderPlanGivesSensibleExplainedChanges() throws {
        // A synthetic 4-day runner, half marathon in 16 weeks.
        let start = F.date(week: 8, day: 0, hour: 0)
        let history = PlanFixture.easyWeeks(Array(repeating: 240, count: 8), prefix: "h")
        let race = PlanCalendar.calendar(timeZone: F.tz).date(byAdding: .day, value: 15 * 7 + 6, to: start)!
            .addingTimeInterval(8 * 3600)
        let five = 24.0 * 60
        let input = PlanInput(raceDistanceMeters: Distance.halfMarathon, raceDate: race, startDate: start,
                              trainingDays: [.monday, .wednesday, .friday, .sunday], longRunDay: .sunday,
                              recentWeeklySeconds: 240 * 60, recentLongRunSeconds: 80 * 60, heartRateZones: F.zones,
                              easyPace: EasyPaceSample(secondsPerKm: 360, heartRate: 138),
                              fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: five),
                              predictedRaceSeconds: RacePredictor.riegel(knownMeters: Distance.fiveK, knownSeconds: five,
                                                                         targetMeters: Distance.halfMarathon))
        let plan = try XCTUnwrap(PlanBuilder.build(input, history: history, timeZone: F.tz).plan)
        let original = plan.workouts

        var d = F.Driver(plan: original, history: history, context: F.context(tracksPain: true))
        let skipID = try XCTUnwrap(original.first { $0.kind.isQuality && $0.date >= F.date(week: 12, day: 0) }).id
        let skipDate = original.first { $0.id == skipID }!.date
        func week(_ w: PlannedWorkout) -> Int {
            Int((PlanCalendar.weekStart(containing: w.date, timeZone: F.tz).timeIntervalSince(PlanFixture.firstMonday) / 86_400 / 7).rounded())
        }
        let spec: (PlannedWorkout) -> F.RunSpec? = { w in
            if w.id == skipID && w.date == skipDate { return nil }           // missed once
            guard w.kind.isQuality else { return F.RunSpec() }
            switch week(w) {
            case 10, 11: return F.RunSpec(pace: 0.97)                         // fitter than planned
            case 14...16: return F.RunSpec(pace: 1.05)                        // falling behind
            default: return F.RunSpec()
            }
        }
        d.follow(until: F.date(week: 13, day: 6, hour: 22), spec)
        d.checkIn(5, at: F.date(week: 13, day: 6, hour: 23))                  // pain after the long run
        d.follow(until: F.date(week: 16, day: 6, hour: 23), spec)
        d.day(F.date(week: 17, day: 0, hour: 6))

        // Weeks track the plan except where the runner's own data moved them:
        // no week grows past the plan, and the missed week loses at most a session's worth.
        for w in 8...23 {
            XCTAssertLessThanOrEqual(F.weekVolume(w, d.history + d.plan), F.weekVolume(w, original) + 1e-6, "week \(w)")
        }
        let changes = d.changes
        let kinds = Set(changes.map(\.kind))
        for k in [PlanChange.Kind.paceTargetsFaster, .painVolumeFreeze, .qualitySwappedToEasy, .paceTargetsSlower, .volumeHeld] {
            XCTAssertTrue(kinds.contains(k), "missing \(k) in \(kinds)")
        }
        XCTAssertTrue(changes.contains { [.sessionMoved, .sessionDropped].contains($0.kind) && $0.workoutIDs.first == skipID })
        // Faster first (weeks 10 to 11), slower later (weeks 14 on).
        let firstFaster = changes.firstIndex { $0.kind == .paceTargetsFaster }!
        let firstSlower = changes.firstIndex { $0.kind == .paceTargetsSlower }!
        XCTAssertLessThan(firstFaster, firstSlower)
        // Each pace change cites the sessions that agreed, with their pace and heart rate.
        for c in changes where [.paceTargetsFaster, .paceTargetsSlower].contains(c.kind) {
            XCTAssertGreaterThanOrEqual(c.triggers.first { $0.metric == .signalCount }!.value, 2)
            XCTAssertGreaterThanOrEqual(c.triggers.filter { $0.metric == .pace }.count, 2)
        }
        assertAdaptationSound(d.outcomes)
        let unmet = d.outcomes.flatMap(\.changes).filter { $0.kind == .holdShortfall }.map(\.explanation)
        XCTAssertTrue(d.outcomes.allSatisfy(\.holdsSatisfied), "\(unmet)")

        // Never two hard days back to back, across what was run and what is left.
        let cal = PlanCalendar.calendar(timeZone: F.tz)
        let hard = (d.history + d.plan).filter { $0.date >= start && ($0.kind.isQuality || $0.kind == .race) }
            .map { cal.startOfDay(for: $0.date) }.sorted()
        for (a, b) in zip(hard, hard.dropFirst()) {
            XCTAssertGreaterThan(cal.dateComponents([.day], from: a, to: b).day!, 1, "hard days \(a) and \(b)")
        }
        // The race is never touched.
        XCTAssertEqual(d.plan.first { $0.kind == .race }, original.first { $0.kind == .race })
        // Volume only ever went down from the plan (the engine never adds load).
        for w in d.plan {
            if let o = original.first(where: { $0.id == w.id }) { XCTAssertLessThanOrEqual(w.durationSeconds, o.durationSeconds + 1e-6) }
        }
    }
}
