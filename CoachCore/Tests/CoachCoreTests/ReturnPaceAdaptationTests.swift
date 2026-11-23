import XCTest
@testable import CoachCore

// Paces after a break in an adapted plan (F4; SPEC 3.5 rule 4, #28), on the
// synthetic weekly plan of `AdaptFixture`: Tue threshold, Thu easy, Sat long,
// Sun easy. Every pace is read against the same session of the original plan.
final class ReturnPaceAdaptationTests: XCTestCase {
    typealias F = AdaptFixture

    private let original = F.weeks(0..<16)

    private func session(_ id: String, _ plan: [PlannedWorkout]) -> PlannedWorkout? { plan.first { $0.id == id } }

    private func pace(_ intensity: WorkoutIntensity, of w: PlannedWorkout?) -> Double? {
        w?.prescription?.segments.first { $0.intensity == intensity }?.target.pace?.fastestSecondsPerKm
    }

    /// `id`'s threshold and easy pace targets divided by the original plan's: 1 / the factor in force.
    private func slowdown(_ id: String, _ plan: [PlannedWorkout], file: StaticString = #filePath, line: UInt = #line) -> Double? {
        guard let now = session(id, plan), let was = session(id, original) else { XCTFail("no \(id)", file: file, line: line); return nil }
        let intensity: WorkoutIntensity = now.kind.isQuality ? .threshold : .easy
        guard let a = pace(intensity, of: now), let b = pace(intensity, of: was) else { return nil }
        return a / b
    }

    private func assertFactor(_ id: String, _ plan: [PlannedWorkout], _ f: Double, file: StaticString = #filePath, line: UInt = #line) {
        guard let r = slowdown(id, plan, file: file, line: line) else { return XCTFail("no pace for \(id)", file: file, line: line) }
        XCTAssertEqual(r, 1 / f, accuracy: 1e-9, id, file: file, line: line)
        let applied = session(id, plan)?.prescription?.returnPaceFactor
        XCTAssertEqual(applied ?? 1, f, accuracy: 1e-12, "\(id) records the factor applied", file: file, line: line)
    }

    /// Runs of weeks `weeks` as completed sessions: each session of the original plan, as run.
    private func ran(_ weeks: Range<Int>, from first: Date = F.date(week: 0, day: 0, hour: 0), before end: Date = .distantFuture) -> [PlannedWorkout] {
        original.filter { w in
            let week = Int(w.date.timeIntervalSince(PlanFixture.firstMonday) / (7 * 86_400))
            return weeks.contains(week) && w.date >= first && w.date < end
        }.map { PlannedWorkout(id: "run-\($0.id)", date: $0.date, kind: $0.kind, durationSeconds: $0.durationSeconds) }
    }

    /// One morning call at `date` on the plan from week 3 (week 3 not run).
    private func morning(_ date: Date, state: AdaptationState = AdaptationState(), plan: [PlannedWorkout]? = nil,
                         history: [PlannedWorkout]) -> AdaptationOutcome {
        AdaptationEngine.processDay(asOf: date, state: state, plan: plan ?? F.weeks(3..<16), history: history, context: F.context())
    }

    /// Every session of weeks `weeks` that still has the original's shape (the return ramp may swap or cut others) is at factor `f`.
    private func assertWeeks(_ weeks: ClosedRange<Int>, _ plan: [PlannedWorkout], _ f: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        var checked = 0
        for w in plan {
            let week = Int(w.date.timeIntervalSince(PlanFixture.firstMonday) / (7 * 86_400))
            guard weeks.contains(week), let was = session(w.id, original),
                  was.kind == w.kind, was.prescription?.segments.count == w.prescription?.segments.count,
                  w.prescription?.segments.contains(where: { $0.target.pace != nil }) == true else { continue }
            assertFactor(w.id, plan, f, file: file, line: line)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "weeks \(weeks)", file: file, line: line)
    }

    // MARK: A mid-plan break of about 10 days

    func testAShortMidPlanBreakSlowsTheReturnAndLiftsItOverThreeWeeks() {
        // Weeks 0 to 2 run, then 8 days off through the Monday of week 4: week 4 is week 1 back.
        let history = ran(0..<3)
        let tue = morning(F.date(week: 4, day: 1, hour: 6), history: history)
        let f = BreakPaceFactor.factor(daysOff: 8)
        XCTAssertLessThan(f, 1)
        // Week 1 back is at the factor, week 2 halfway, week 3 on at 1.0.
        for id in ["t4", "e4a", "l4", "e4b"] { assertFactor(id, tue.plan, f) }
        for id in ["t5", "e5a", "l5", "e5b"] { assertFactor(id, tue.plan, (f + 1) / 2) }
        for id in ["t6", "e6a", "l6", "t9", "l15"] { assertFactor(id, tue.plan, 1) }
        let moves = tue.changes.filter { $0.kind == .returnPaces }
        XCTAssertFalse(moves.isEmpty)
        XCTAssertTrue(moves.allSatisfy { $0.rule.contains("3.5 rule 4") && !$0.triggers.isEmpty })
        XCTAssertEqual(session("t4", tue.plan)?.prescription?.returnPaceFactor, f)
        XCTAssertTrue(tue.state.planSnapshot.sessions.contains { $0.id == "t5" && $0.prescription?.returnPaceFactor != nil })

        // The runner runs week 4 and the next morning is the same: the step changes nothing.
        let week4 = ran(3..<5, from: F.date(week: 4, day: 0, hour: 0))
        let next = morning(F.date(week: 5, day: 0, hour: 6), state: tue.state, plan: tue.plan, history: history + week4)
        XCTAssertFalse(next.changes.contains { $0.kind == .returnPaces })
        for id in ["t5", "l5"] { assertFactor(id, next.plan, (f + 1) / 2) }
        // Two weeks on the lift is complete and the original paces are back.
        let week5 = ran(5..<6)
        let later = morning(F.date(week: 6, day: 0, hour: 6), state: next.state, plan: next.plan, history: history + week4 + week5)
        for id in ["t6", "l6", "t7"] { assertFactor(id, later.plan, 1) }
    }

    func testNoBreakChangesNoPace() {
        let o = morning(F.date(week: 3, day: 1, hour: 6), plan: F.weeks(0..<8) .filter { $0.date >= F.date(week: 3, day: 0, hour: 0) },
                        history: ran(0..<3))
        XCTAssertFalse(o.changes.contains { $0.kind == .returnPaces })
        XCTAssertTrue(o.plan.allSatisfy { $0.prescription?.returnPaceFactor == nil })
    }

    // MARK: A longer break holds until a marked race

    func testALongerBreakHoldsUntilAMarkedRace() {
        // Weeks 3 to 6 not run, the Thursday of week 7 the first run back: 4 break weeks, 31 days off.
        let history = ran(0..<3)
        let thu = morning(F.date(week: 7, day: 3, hour: 6), history: history)
        let f = BreakPaceFactor.factor(daysOff: 31)
        XCTAssertLessThan(f, 1)
        assertWeeks(7...15, thu.plan, f)

        // Two weeks of running, one hard training run that is not a race: the factor holds.
        let back = ran(7..<9, from: F.date(week: 7, day: 3, hour: 0))
        let best = PlannedWorkout(id: "best", date: F.date(week: 8, day: 1), kind: .quality(.threshold), durationSeconds: 3000)
        let held = morning(F.date(week: 9, day: 0, hour: 6), state: thu.state, plan: thu.plan, history: history + back + [best])
        assertWeeks(9...15, held.plan, f)

        // A race after the break is the anchor: the factor ends, for every week after it.
        let race = PlannedWorkout(id: "race", date: F.date(week: 9, day: 5), kind: .race, durationSeconds: 3000,
                                  distanceMeters: Distance.tenK)
        let ended = morning(F.date(week: 10, day: 0, hour: 6), state: held.state, plan: held.plan,
                            history: history + back + [best, race])
        assertWeeks(10...15, ended.plan, 1)
    }

    // MARK: Faster steps stop at the pre-break target in weeks 1 to 3 back

    /// Week 5 back from a break (the runner ran week 4), with one earlier quality signal `signal`
    /// and the week-5 threshold run as `spec`.
    private func afterRun(_ earlier: RunSignal, _ spec: F.RunSpec) throws -> (AdaptationOutcome, f: Double) {
        let history = ran(0..<3) + ran(3..<5, from: F.date(week: 4, day: 0, hour: 0))
        let tue = morning(F.date(week: 4, day: 1, hour: 6), history: ran(0..<3))
        var state = tue.state
        state.qualitySignals = [SignalRecord(activityID: "run-t4", date: F.date(week: 4, day: 1), signal: earlier, triggers: [])]
        let day = morning(F.date(week: 5, day: 0, hour: 6), state: state, plan: tue.plan, history: history)
        let t5 = try XCTUnwrap(session("t5", day.plan))
        let run = F.run(for: t5, spec)
        let o = AdaptationEngine.processRun(run, state: day.state, plan: day.plan, history: day.history, context: F.context())
        return (o, BreakPaceFactor.factor(daysOff: 8))
    }

    func testAFasterStepNeverPassesThePreBreakTargetInTheFirstThreeWeeksBack() throws {
        let (o, _) = try afterRun(.ahead, F.RunSpec(pace: 0.97))
        let step = F.context().limits.paceStep
        let moves = o.changes.filter { $0.kind == .paceTargetsFaster }
        XCTAssertEqual(moves.count, 1, "2 of the last 2 quality sessions were ahead")
        // t6 is in week 3 back at its pre-break target: not faster. Week 7 is past the cap.
        XCTAssertFalse(moves[0].workoutIDs.contains("t6"))
        let t6 = try XCTUnwrap(pace(.threshold, of: session("t6", o.plan)))
        XCTAssertEqual(t6, try XCTUnwrap(pace(.threshold, of: session("t6", original))), accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(pace(.threshold, of: session("t7", o.plan))),
                       try XCTUnwrap(pace(.threshold, of: session("t7", original))) * (1 - step), accuracy: 1e-9)
        XCTAssertTrue(moves[0].workoutIDs.contains("t7"))
        // The pre-break target also bounds it in the snapshot the plan grows back to.
        let snap = try XCTUnwrap(o.state.planSnapshot.sessions.first { $0.id == "t6" })
        XCTAssertEqual(try XCTUnwrap(pace(.threshold, of: snap)), t6, accuracy: 1e-9)
    }

    func testASlowerStepStillWorksInTheFirstThreeWeeksBack() throws {
        let (o, _) = try afterRun(.behind, F.RunSpec(pace: 1.06))
        let step = F.context().limits.paceStep
        let moves = o.changes.filter { $0.kind == .paceTargetsSlower }
        XCTAssertEqual(moves.count, 1)
        XCTAssertTrue(moves[0].workoutIDs.contains("t6"))
        XCTAssertEqual(try XCTUnwrap(pace(.threshold, of: session("t6", o.plan))),
                       try XCTUnwrap(pace(.threshold, of: session("t6", original))) * (1 + step), accuracy: 1e-9)
    }

    func testAFasterStepInWeekTwoBackStopsAtTheOriginalPace() {
        // Direct: a session slowed by 3% (applied factor) may go at most 3% faster in the capped weeks.
        let w = session("t5", original)!
        let slowed = w.returningPaces(toFactor: 0.97)!
        XCTAssertEqual(slowed.prescription?.returnPaceFactor, 0.97)
        XCTAssertEqual(pace(.threshold, of: slowed)!, pace(.threshold, of: w)! / 0.97, accuracy: 1e-9)
        // And the factor lifts back exactly.
        let back = slowed.returningPaces(toFactor: 1)!
        XCTAssertEqual(pace(.threshold, of: back)!, pace(.threshold, of: w)!, accuracy: 1e-9)
        XCTAssertNil(back.prescription?.returnPaceFactor)
        XCTAssertNil(w.returningPaces(toFactor: 1))
    }

    // MARK: Coding

    func testTheAppliedFactorSurvivesTheStateRoundTrip() throws {
        let slowed = session("t5", original)!.returningPaces(toFactor: 0.95)!
        let coded = PrescriptionCoding(try XCTUnwrap(slowed.prescription))
        let data = try JSONEncoder().encode(coded)
        let back = try JSONDecoder().decode(PrescriptionCoding.self, from: data).value()
        XCTAssertEqual(back.returnPaceFactor, 0.95)
        XCTAssertEqual(back, slowed.prescription)
        // A prescription stored before the field decodes with none.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "returnPaceFactor")
        let old = try JSONDecoder().decode(PrescriptionCoding.self, from: JSONSerialization.data(withJSONObject: json)).value()
        XCTAssertNil(old.returnPaceFactor)
    }
}
