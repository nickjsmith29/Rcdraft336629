import XCTest
@testable import CoachCore

extension AdaptFixture.Driver {
    /// A pain report (SPEC 3.5 rule 7), after the morning calls up to its day.
    mutating func report(_ r: PainReport) {
        mornings(through: r.date)
        take(AdaptationEngine.processPainReport(r, state: state, plan: plan, history: history, context: context))
    }
}

// SPEC 3.5 rule 7, the pain stop rule, inside the F4 engine. Synthetic plans
// and reports only.
final class AdaptationPainStopTests: XCTestCase {
    typealias F = AdaptFixture
    private let anyRunner = AdaptFixture.context(tracksPain: false)
    private let tracker = AdaptFixture.context(tracksPain: true)

    /// Tuesday of week 0, just after the threshold session t0 (07:00, 54 min).
    private var afterRun: Date { F.date(week: 0, day: 1, hour: 9) }
    /// Wednesday morning of week 0.
    private var nextMorning: Date { F.date(week: 0, day: 2, hour: 7) }

    private func afterRunReport(at date: Date? = nil, pain: Bool = true, worsened: Bool = false, moved: Bool = false,
                                score: Int? = nil) -> PainReport {
        PainReport(date: date ?? afterRun, timing: .afterRun, hasPain: pain, worsenedDuringRun: worsened,
                   changedMovement: moved, score: score, activityID: "run-t0")
    }

    private func morningReport(at date: Date? = nil, pain: Bool) -> PainReport {
        PainReport(date: date ?? nextMorning, timing: .nextMorning, hasPain: pain)
    }

    /// Runs week 0's Tuesday threshold session, then sends `reports` in order.
    private func driver(_ plan: [PlannedWorkout] = F.weeks(0..<3), context: AdaptationContext? = nil,
                        reports: [PainReport]) -> F.Driver {
        var d = F.Driver(plan: plan, context: context ?? anyRunner)
        d.follow(until: F.date(week: 0, day: 1, hour: 8)) { _ in F.RunSpec() }
        for r in reports { d.report(r) }
        return d
    }

    private func assertStopped(_ d: F.Driver, mode: PainStopMode, triggers: [PainStopTrigger], since: Date,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard let stop = d.state.painStop else { return XCTFail("no stop", file: file, line: line) }
        XCTAssertEqual(stop.mode, mode, file: file, line: line)
        XCTAssertEqual(stop.triggers, triggers, file: file, line: line)
        XCTAssertEqual(stop.since, since, file: file, line: line)
        XCTAssertTrue(d.state.progressionStopped, file: file, line: line)
        XCTAssertNotNil(stop.level, "the pre-stop weekly level is known", file: file, line: line)
        XCTAssertEqual(d.state.freezeIntervals(at: since), d.state.activeFreezes(at: since).map(\.interval),
                       "the stop's ceiling is not a chained freeze", file: file, line: line)
        XCTAssertFalse(d.plan.contains { $0.kind.isQuality }, "no quality while stopped", file: file, line: line)
        if mode == .rest {
            XCTAssertTrue(d.plan.allSatisfy { $0.kind == .rest || $0.kind == .race }, file: file, line: line)
        }
    }

    // MARK: Each trigger alone

    func testPainThatWorsenedDuringTheRunStopsProgressionEasyOnly() {
        let d = driver(reports: [afterRunReport(worsened: true)])
        assertStopped(d, mode: .easyOnly, triggers: [.worsenedDuringRun], since: afterRun)
        let o = d.outcomes.last!
        let stop = o.changes.first { $0.kind == .painStop }!
        XCTAssertEqual(stop.workoutIDs, [])
        XCTAssertEqual(stop.triggers.first?.metric, .painStopTriggers)
        XCTAssertEqual(stop.triggers.first?.value, 1)
        XCTAssertEqual(stop.triggers.first?.sourceID, "run-t0")
        XCTAssertTrue(stop.rule.contains("3.5 rule 7"))
        XCTAssertTrue(stop.explanation.contains("got worse during the run"))
        XCTAssertTrue(stop.explanation.contains("not a diagnosis"))
        // Every later quality session is an easy run of the same length, with an easy HR cap.
        let swapped = o.changes.filter { $0.kind == .qualitySwappedToEasy }.flatMap(\.workoutIDs)
        XCTAssertEqual(swapped, ["t1", "t2"])
        let t1 = d.plan.first { $0.id == "t1" }!
        XCTAssertEqual(t1.kind, .easy)
        XCTAssertEqual(t1.durationSeconds, 54 * 60)
        XCTAssertEqual(t1.prescription?.segments.map(\.intensity), [.easy])
        XCTAssertEqual(t1.prescription?.segments.first?.target.heartRate.ceilingBPM, F.zones.easyCeiling)
        XCTAssertFalse(o.adviseClinician)
        assertAdaptationSound(d.outcomes)
    }

    func testPainThatChangedMovementStopsRunning() {
        let d = driver(reports: [afterRunReport(moved: true)])
        assertStopped(d, mode: .rest, triggers: [.changedMovement], since: afterRun)
        let rested = d.outcomes.last!.changes.filter { $0.kind == .sessionRested }.flatMap(\.workoutIDs)
        XCTAssertEqual(Set(rested), Set(F.weeks(0..<3).map(\.id)).subtracting(["t0"]))
        XCTAssertTrue(d.plan.allSatisfy { $0.durationSeconds == 0 && $0.volume(.time) == 0 })
        XCTAssertTrue(d.outcomes.last!.changes.first { $0.kind == .painStop }!.explanation.contains("rest day"))
        assertAdaptationSound(d.outcomes)
    }

    func testPainStillThereTheNextMorningStopsProgression() {
        let d = driver(reports: [morningReport(pain: true)])
        assertStopped(d, mode: .easyOnly, triggers: [.stillThereNextMorning], since: nextMorning)
        XCTAssertTrue(d.outcomes.last!.changes.first { $0.kind == .painStop }!.explanation.contains("above your usual level the next morning"))
        assertAdaptationSound(d.outcomes)
    }

    /// SPEC 3.5 rule 7 v0.5 (#73): with usual 0, a next-morning 1 freezes
    /// growth rather than stopping; 2 or more (usual + 2) stops; pain of
    /// unknown size is read as a stop.
    func testNextMorningScoresAgainstUsualZero() {
        func r(_ score: Int?, pain: Bool = false) -> PainReport {
            PainReport(date: nextMorning, timing: .nextMorning, hasPain: pain, score: score)
        }
        XCTAssertEqual(r(1).stopTriggers, [])
        XCTAssertEqual(r(2).stopTriggers, [.stillThereNextMorning])
        XCTAssertEqual(r(0).stopTriggers, [])
        XCTAssertEqual(r(nil, pain: true).stopTriggers, [.stillThereNextMorning])
    }

    // MARK: Combinations

    func testWorseAndChangedMovementTogetherMeanRest() {
        let d = driver(reports: [afterRunReport(worsened: true, moved: true)])
        assertStopped(d, mode: .rest, triggers: [.worsenedDuringRun, .changedMovement], since: afterRun)
        XCTAssertEqual(d.outcomes.last!.changes.first { $0.kind == .painStop }!.triggers.first?.value, 2)
    }

    func testWorseDuringTheRunThenStillThereNextMorningEscalatesToRest() {
        var d = driver(reports: [afterRunReport(worsened: true)])
        XCTAssertEqual(d.state.painStop?.mode, .easyOnly)
        d.report(morningReport(pain: true))
        assertStopped(d, mode: .rest, triggers: [.worsenedDuringRun, .stillThereNextMorning], since: afterRun)
        XCTAssertEqual(d.state.painStop?.lastTriggered, nextMorning)
        let o = d.outcomes.last!
        let stop = o.changes.first { $0.kind == .painStop }!
        XCTAssertTrue(stop.explanation.contains("stopped since"), stop.explanation)
        XCTAssertFalse(o.changes.filter { $0.kind == .sessionRested }.isEmpty)
        XCTAssertEqual(d.changes.filter { $0.kind == .painStop }.count, 2)
        assertAdaptationSound(d.outcomes)
    }

    func testTheSameTriggerAgainChangesNothingAndAStopNeverSoftens() {
        var d = driver(reports: [afterRunReport(worsened: true)])
        let plan = d.plan
        d.report(afterRunReport(at: F.date(week: 0, day: 3, hour: 9), worsened: true))
        XCTAssertTrue(d.outcomes.last!.changes.isEmpty)
        XCTAssertEqual(d.plan, plan)
        // Pain-free and mild reports later never lift or soften the stop.
        var r = driver(reports: [afterRunReport(moved: true)])
        r.report(morningReport(pain: false))
        r.report(afterRunReport(at: F.date(week: 0, day: 3, hour: 9), pain: true))
        assertStopped(r, mode: .rest, triggers: [.changedMovement], since: afterRun)
    }

    func testModeTable() {
        let L = PainStopLimits.default
        XCTAssertNil(PainStopRule.mode(for: [], limits: L))
        XCTAssertEqual(PainStopRule.mode(for: [.worsenedDuringRun], limits: L), .easyOnly)
        XCTAssertEqual(PainStopRule.mode(for: [.stillThereNextMorning], limits: L), .easyOnly)
        XCTAssertEqual(PainStopRule.mode(for: [.changedMovement], limits: L), .rest)
        XCTAssertEqual(PainStopRule.mode(for: [.worsenedDuringRun, .worsenedDuringRun], limits: L), .easyOnly)
        XCTAssertEqual(PainStopRule.mode(for: [.worsenedDuringRun, .stillThereNextMorning], limits: L), .rest)
        XCTAssertEqual(PainStopRule.mode(for: [.worsenedDuringRun, .stillThereNextMorning],
                                         limits: PainStopLimits(restTriggerCount: 3)), .easyOnly)
    }

    // MARK: Any runner, and the check-in

    func testRunnerWithNoPainHistoryIsStoppedButGetsNoCheckInFreeze() {
        let d = driver(context: anyRunner, reports: [afterRunReport(worsened: true, score: 6)])
        assertStopped(d, mode: .easyOnly, triggers: [.worsenedDuringRun], since: afterRun)
        let o = d.outcomes.last!
        XCTAssertFalse(o.changes.contains { $0.kind == .painVolumeFreeze }, "the check-in rule is for pain trackers only")
        XCTAssertNil(o.state.appliedPainResponse)
        XCTAssertEqual(o.state.painCheckIns, [PainCheckIn(date: afterRun, score: 6)])
        XCTAssertEqual(o.state.painReports.count, 1)
    }

    func testAReportWithAScoreIsAlsoTheCheckInForAPainTracker() {
        // High score, no stop trigger: the check-in rule alone.
        let freeze = driver(context: tracker, reports: [afterRunReport(score: 6)])
        XCTAssertNil(freeze.state.painStop)
        XCTAssertTrue(freeze.outcomes.last!.changes.contains { $0.kind == .painVolumeFreeze })
        XCTAssertEqual(freeze.state.appliedPainResponse?.checkIn, PainCheckIn(date: afterRun, score: 6))
        // High score and a stop trigger: both.
        let both = driver(context: tracker, reports: [afterRunReport(worsened: true, score: 6)])
        XCTAssertNotNil(both.state.painStop)
        XCTAssertTrue(both.outcomes.last!.changes.contains { $0.kind == .painVolumeFreeze })
        XCTAssertFalse(both.plan.contains { $0.kind.isQuality })
        assertAdaptationSound(freeze.outcomes + both.outcomes)
    }

    // MARK: Pain that clears versus pain that stays

    func testMildStablePainAloneDoesNotStop() {
        let d = driver(reports: [afterRunReport(pain: true, score: 3)])
        XCTAssertNil(d.state.painStop)
        XCTAssertTrue(d.outcomes.last!.changes.isEmpty)
        XCTAssertEqual(d.plan.first { $0.id == "t1" }?.kind, .quality(.threshold))
    }

    func testPainThatClearsByTheNextMorningDoesNotStop() {
        let d = driver(reports: [afterRunReport(pain: true), morningReport(pain: false)])
        XCTAssertNil(d.state.painStop)
        XCTAssertFalse(d.changes.contains { $0.kind == .painStop })
        XCTAssertTrue(d.plan.contains { $0.kind.isQuality })
    }

    func testPainStillThereTheNextMorningAfterMildPainStops() {
        let d = driver(reports: [afterRunReport(pain: true), morningReport(pain: true)])
        assertStopped(d, mode: .easyOnly, triggers: [.stillThereNextMorning], since: nextMorning)
        assertAdaptationSound(d.outcomes)
    }

    // MARK: Clinician flag (about a week)

    private func lasting(_ days: [Int], pain: Bool = true, extra: [PainReport] = [], checkIns: [PainCheckIn] = [],
                         asOf: Date? = nil) -> LastingPain? {
        let reports = days.map { PainReport(date: F.date(week: 1, day: 0, hour: 7).addingTimeInterval(Double($0) * 86_400),
                                            timing: .afterRun, hasPain: pain) } + extra
        return PainStopRule.lastingPain(reports: reports, checkIns: checkIns, asOf: asOf ?? F.date(week: 4, day: 0),
                                        timeZone: F.tz)
    }

    func testClinicianFlagAtTheOneWeekBoundaryWithDailyReports() {
        XCTAssertNil(lasting(Array(0...6)), "6 days is not yet a week")
        let seven = lasting(Array(0...7))
        XCTAssertEqual(seven?.days, 7)
        XCTAssertEqual(seven?.reportDays, 8)
        XCTAssertEqual(seven?.since, F.date(week: 1, day: 0, hour: 7))
        XCTAssertEqual(lasting(Array(0...8))?.days, 8)
    }

    func testClinicianFlagNeedsReportsOnMostDays() {
        XCTAssertNil(lasting([0, 3, 7]), "scattered: 3 of 8 days")
        XCTAssertNil(lasting([0, 3, 5, 7]), "half the days is not most days")
        XCTAssertEqual(lasting([0, 2, 3, 5, 7])?.reportDays, 5)
        XCTAssertNil(lasting([0, 8]), "two reports a week apart")
        XCTAssertEqual(lasting([0, 1, 2, 4, 5, 6, 8])?.days, 8)
        XCTAssertNotNil(lasting([0, 2, 4, 6, 8]), "every other day over 8 days: 5 of 9")
        XCTAssertNil(lasting([0, 3, 6, 8]), "4 of 9")
        XCTAssertNotNil(lasting([0, 2, 3, 4, 6, 8]), "6 of 9")
    }

    func testAPainFreeReportEndsTheStretch() {
        let free = PainReport(date: F.date(week: 1, day: 3, hour: 12), timing: .nextMorning, hasPain: false)
        XCTAssertNil(lasting(Array(0...8), extra: [free]))
        // A pain-free check-in (score 0) does the same; one above 0 is pain.
        XCTAssertNil(lasting(Array(0...8), checkIns: [PainCheckIn(date: F.date(week: 1, day: 3, hour: 12), score: 0)]))
        XCTAssertNotNil(lasting([0, 1, 2, 4, 5, 7], checkIns: [PainCheckIn(date: F.date(week: 1, day: 3, hour: 12), score: 2),
                                                              PainCheckIn(date: F.date(week: 1, day: 6, hour: 12), score: 1)]))
        // Pain and pain-free at the same instant: the pain-free one is ignored.
        let same = PainReport(date: F.date(week: 1, day: 0, hour: 7).addingTimeInterval(8 * 86_400), timing: .afterRun, hasPain: false)
        XCTAssertNotNil(lasting(Array(0...8), extra: [same]))
        // Only reports up to asOf count.
        XCTAssertNil(lasting(Array(0...8), asOf: F.date(week: 1, day: 6, hour: 12)))
        XCTAssertNil(lasting([], extra: []))
        XCTAssertNil(lasting(Array(0...8), pain: false))
    }

    func testClinicianFlagThroughTheEngine() {
        // A stop, then the morning question every day: still there for a week.
        var d = driver(reports: [afterRunReport(worsened: true)])
        var flags: [Bool] = []
        for day in 1...8 {
            d.report(morningReport(at: afterRun.addingTimeInterval(Double(day) * 86_400 - 2 * 3_600), pain: true))
            flags.append(d.outcomes.last!.adviseClinician)
        }
        // First pain on Tuesday 09:00; the mornings are Wednesday 07:00 onward.
        XCTAssertEqual(flags, [false, false, false, false, false, false, true, true])
        XCTAssertEqual(d.outcomes.last!.lastingPain?.days, 8)
        XCTAssertFalse(d.outcomes.last!.suggestClinician, "the check-in prompt is separate")
        // It stays on a quiet day, and the stop is still in force.
        d.day(afterRun.addingTimeInterval(9 * 86_400))
        XCTAssertNotNil(d.outcomes.last!.lastingPain)
        XCTAssertNotNil(d.state.painStop)
        // A pain-free morning ends it; the stop stays until the return (#64).
        d.report(morningReport(at: afterRun.addingTimeInterval(10 * 86_400), pain: false))
        XCTAssertNil(d.outcomes.last!.lastingPain)
        XCTAssertNotNil(d.state.painStop)
        assertAdaptationSound(d.outcomes)
    }

    // MARK: A stop never raises load

    func testAStopNeverRaisesLoad() {
        // A plan that grows about 4 to 5% a week.
        let plan = F.weeks(0..<4, easyMinutes: { w in (55 + 5 * Double(w), 45 + 4 * Double(w)) })
        for report in [afterRunReport(worsened: true), afterRunReport(moved: true), morningReport(pain: true)] {
            var d = F.Driver(plan: plan, context: anyRunner)
            d.follow(until: F.date(week: 0, day: 1, hour: 8)) { _ in F.RunSpec() }
            let before = d.plan
            d.report(report)
            let after = d.outcomes.last!
            for w in after.plan {
                let old = before.first { $0.id == w.id }!
                XCTAssertLessThanOrEqual(w.durationSeconds, old.durationSeconds, "\(w.id)")
                XCTAssertLessThanOrEqual(w.volume(.time) ?? 0, old.volume(.time) ?? 0, "\(w.id)")
            }
            XCTAssertFalse(after.changes.contains { $0.kind == .paceTargetsFaster })
            // Running on through the plan: no week goes above the pre-stop level or its own plan.
            let level = d.state.painStop!.level!
            d.follow(until: F.date(week: 3, day: 6, hour: 23)) { $0.kind == .rest ? nil : F.RunSpec() }
            let all = d.history + d.plan
            for week in 1..<4 {
                XCTAssertLessThanOrEqual(F.weekVolume(week, all), min(level, F.weekVolume(week, plan)) + 1e-6, "week \(week)")
            }
            XCTAssertFalse(d.history.contains { $0.kind.isQuality && $0.date > report.date })
            assertAdaptationSound(d.outcomes)
        }
    }

    func testAPlanHandedBackWithQualityIsStoppedAgain() {
        var d = driver(reports: [afterRunReport(worsened: true)])
        // A goal edit (F2) re-plans and hands back the original sessions.
        d.plan = F.weeks(0..<3).filter { $0.date > afterRun }
        let first = d.outcomes.count
        d.day(F.date(week: 0, day: 2, hour: 6))
        let o = d.outcomes.last!
        XCTAssertFalse(o.plan.contains { $0.kind.isQuality })
        let swaps = d.outcomes[first...].flatMap(\.changes).filter { $0.kind == .qualitySwappedToEasy }
        XCTAssertEqual(swaps.flatMap(\.workoutIDs), ["t1", "t2"])
        XCTAssertTrue(swaps.allSatisfy { $0.triggers.first?.metric == .painStopTriggers && $0.rule.contains("3.5 rule 7") })
        // A plan already in the stop's shape gets no change.
        d.day(F.date(week: 0, day: 2, hour: 12))
        XCTAssertTrue(d.outcomes.last!.changes.isEmpty)
        assertAdaptationSound(d.outcomes)
    }

    func testRacesStayAsTheRunnerSetThem() {
        var plan = F.weeks(0..<2)
        plan.append(PlannedWorkout(id: "race", date: F.date(week: 1, day: 6, hour: 9), kind: .race, durationSeconds: 25 * 60))
        plan.removeAll { $0.id == "e1b" }
        let d = driver(plan, reports: [afterRunReport(moved: true)])
        XCTAssertEqual(d.plan.first { $0.id == "race" }?.kind, .race)
        XCTAssertTrue(d.outcomes.last!.changes.first { $0.kind == .painStop }!.explanation.contains("race"))
        assertStopped(d, mode: .rest, triggers: [.changedMovement], since: afterRun)
    }

    // MARK: Invalid and repeated input

    func testInvalidAndRepeatedReports() {
        var d = driver(reports: [afterRunReport(worsened: true, score: 11)])
        XCTAssertNotNil(d.state.painStop)
        XCTAssertTrue(d.state.painCheckIns.isEmpty, "a score outside 0 to 10 is not a check-in")
        // The same report again (a re-sync) changes nothing.
        let state = d.state
        d.report(afterRunReport(worsened: true, score: 11))
        XCTAssertEqual(d.state, state)
        XCTAssertTrue(d.outcomes.last!.changes.isEmpty)

        let nan = PainReport(date: Date(timeIntervalSinceReferenceDate: .nan), timing: .afterRun, hasPain: true,
                             changedMovement: true)
        XCTAssertFalse(nan.isValid)
        XCTAssertNil(PainStopRule.stop(after: nan, current: nil))
        let o = AdaptationEngine.processPainReport(nan, state: AdaptationState(), plan: F.weeks(0..<1), history: [],
                                                   context: anyRunner)
        XCTAssertNil(o.state.painStop)
        XCTAssertTrue(o.state.painReports.isEmpty)
        XCTAssertTrue(o.changes.isEmpty)
        XCTAssertNil(PainStopRule.lastingPain(reports: [nan], checkIns: [], asOf: .distantFuture, timeZone: F.tz))
    }

    func testAnEarlierReportMovesTheStopsStartBack() {
        let later = PainStopRule.stop(after: afterRunReport(at: nextMorning, worsened: true), current: nil)!
        let s = PainStopRule.stop(after: afterRunReport(at: afterRun, moved: true), current: later)!
        XCTAssertEqual(s.since, afterRun)
        XCTAssertEqual(s.lastTriggered, nextMorning)
        XCTAssertEqual(s.mode, .rest)
    }

    // MARK: Replay, debrief and storage

    func testReplayCarriesPainReports() {
        let plan = F.weeks(0..<2)
        let steps = AdaptationReplay.replay([.run(F.run(for: plan[0])), .painReport(afterRunReport(worsened: true))],
                                            plan: plan, context: anyRunner)
        XCTAssertEqual(steps.last?.event.date, afterRun)
        XCTAssertEqual(steps.last?.outcome.state.painStop?.mode, .easyOnly)
        XCTAssertFalse(steps.last!.outcome.plan.contains { $0.kind.isQuality })
    }

    func testDebriefStatesTheStop() {
        let d = driver(reports: [afterRunReport(moved: true)])
        let o = d.outcomes.last!
        let run = F.run(for: F.threshold("t0", week: 0, day: 1))
        let facts = DebriefFacts.build(run: run, planned: nil, outcome: o, previousOutcome: nil, context: anyRunner)
        let text = DebriefText.text(facts)
        XCTAssertTrue(text.contains("progression has stopped since"), text)
        assertDebriefContract(facts)
    }

    private func roundTrip(_ s: AdaptationState) throws -> AdaptationState {
        try JSONDecoder().decode(AdaptationState.self, from: try JSONEncoder().encode(s))
    }

    func testFormatVersion1StateDecodesWithNoStop() throws {
        let v1 = """
        {"formatVersion":1,"assessments":[],"qualitySignals":[],"easyHeartRates":[],"longRuns":[],
         "painCheckIns":[{"date":100,"score":3}],"lastAppliedCheckIn":100,"freezes":[],"holds":[],
         "qualityPaceFactor":0.985,"easyPaceFactor":1,"reportedHoldShortfalls":[]}
        """
        let decoded = try JSONDecoder().decode(AdaptationState.self, from: Data(v1.utf8))
        XCTAssertEqual(decoded, AdaptationState(painCheckIns: [PainCheckIn(date: Date(timeIntervalSinceReferenceDate: 100), score: 3)],
                                                lastAppliedCheckIn: Date(timeIntervalSinceReferenceDate: 100),
                                                qualityPaceFactor: 0.985))
        XCTAssertTrue(decoded.painReports.isEmpty)
        XCTAssertNil(decoded.painStop)
        // A decoded version 1 state takes a pain report like any other.
        let o = AdaptationEngine.processPainReport(afterRunReport(worsened: true), state: decoded, plan: F.weeks(0..<2),
                                                   history: [], context: anyRunner)
        XCTAssertEqual(o.state.painStop?.mode, .easyOnly)
        // Written back, it is the current version.
        let text = String(data: try JSONEncoder().encode(o.state), encoding: .utf8)!
        XCTAssertTrue(text.contains("\"formatVersion\":\(AdaptationState.formatVersion)"), text)
    }

    func testStateWithAStopRoundTrips() throws {
        var d = driver(reports: [afterRunReport(worsened: true, score: 5)])
        d.report(morningReport(pain: true))
        XCTAssertNotNil(d.state.painStop)
        let decoded = try roundTrip(d.state)
        XCTAssertEqual(decoded, d.state)
        XCTAssertEqual(decoded.painReports.count, 2)
        // Carrying on from the decoded state is the same as from the original.
        let a = AdaptationEngine.processDay(asOf: F.date(week: 0, day: 3), state: d.state, plan: d.plan, history: d.history,
                                            context: anyRunner)
        let b = AdaptationEngine.processDay(asOf: F.date(week: 0, day: 3), state: decoded, plan: d.plan, history: d.history,
                                            context: anyRunner)
        XCTAssertEqual(a, b)
        let broken = String(data: try JSONEncoder().encode(d.state), encoding: .utf8)!
            .replacingOccurrences(of: "\"mode\":\"rest\"", with: "\"mode\":\"walk\"")
        XCTAssertThrowsError(try JSONDecoder().decode(AdaptationState.self, from: Data(broken.utf8)))
    }

    // MARK: The ceiling over a long plan with recovery weeks (review of #72)

    /// Weeks of a Tuesday threshold session (54 min), a Saturday long run of
    /// about 30% of the week, and Thursday and Sunday easy runs for the rest.
    /// The Thursday run is at least the long run / 1.1, so the long run stays
    /// within the single-run spike rule (3.5 rule 1) even in week 0, which has
    /// no history before it.
    static func plan(totals: [Double]) -> [PlannedWorkout] {
        totals.enumerated().flatMap { (w, total) -> [PlannedWorkout] in
            let long = (0.3 * total).rounded(.down)
            let easy = total - 54 - long
            let a = max((easy * 0.55).rounded(), (long / 1.1).rounded(.up))
            return [F.threshold("t\(w)", week: w, day: 1),
                    F.easy("e\(w)a", week: w, day: 3, minutes: a),
                    F.long("l\(w)", week: w, day: 5, minutes: long),
                    F.easy("e\(w)b", week: w, day: 6, minutes: easy - a)]
        }
    }

    /// The probe from the review: about 5% growth a week, recovery weeks 3, 7 and 11.
    static let probeTotals: [Double] = [204, 211, 219, 169, 236, 245, 255, 194, 275, 286, 298, 225]

    func testAStopHoldsAFixedCeilingThroughRecoveryWeeks() {
        let plan = Self.plan(totals: Self.probeTotals)
        XCTAssertTrue(GuardrailChecker.check(history: [], planned: plan, timeZone: F.tz).passed, "the probe plan is sound")
        var d = driver(plan, reports: [afterRunReport(worsened: true)])
        let level = d.state.painStop!.level!
        XCTAssertEqual(level, 204 * 60, accuracy: 1)
        d.follow(until: F.date(week: 11, day: 6, hour: 23)) { _ in F.RunSpec() }
        XCTAssertTrue(d.plan.isEmpty)
        let recovery: Set<Int> = [3, 7, 11]
        let cap = (GuardrailLimits.default.maxLongRunShare * level / 60).rounded(.down) * 60
        var weeks: [Double] = []
        for week in 0..<12 {
            let v = F.weekVolume(week, d.history)
            weeks.append(v / 60)
            let ceiling = min(level, Self.probeTotals[week] * 60)
            XCTAssertLessThanOrEqual(v, ceiling + 1, "week \(week)")
            if !recovery.contains(week) {
                XCTAssertGreaterThanOrEqual(v, ceiling - 5 * 60, "week \(week) fell below min(plan, level)")   // whole-minute rounding
                let long = d.history.first { $0.id == "run-l\(week)" }!.durationSeconds
                XCTAssertGreaterThanOrEqual(long, min(cap, (0.3 * Self.probeTotals[week]).rounded(.down) * 60) - 60, "long run, week \(week)")
            }
        }
        // Recovery weeks stay recovery weeks and never pull the ceiling down after them.
        XCTAssertLessThan(weeks[3], weeks[2])
        XCTAssertEqual(weeks[4], weeks[2], accuracy: 2)
        XCTAssertEqual(weeks[8], weeks[2], accuracy: 2)
        XCTAssertFalse(d.history.contains { $0.kind.isQuality && $0.date > afterRun })
        assertAdaptationSound(d.outcomes)
    }

    // MARK: No-op events while stopped (review of #72)

    func testNoOpEventsAfterARePlanStillEnforceTheStop() {
        let plan = F.weeks(0..<3)
        var base = F.Driver(plan: plan, context: anyRunner)
        base.follow(until: F.date(week: 0, day: 1, hour: 8)) { _ in F.RunSpec() }
        let run = F.run(for: plan[0])
        base.report(afterRunReport(worsened: true))
        let replanned = plan.filter { $0.date > afterRun }
        let events: [(String, (F.Driver) -> AdaptationOutcome)] = [
            ("duplicate report", { d in AdaptationEngine.processPainReport(self.afterRunReport(worsened: true), state: d.state,
                                                                          plan: replanned, history: d.history, context: d.context) }),
            ("duplicate run", { d in AdaptationEngine.processRun(run, state: d.state, plan: replanned, history: d.history,
                                                                 context: d.context) }),
            ("invalid report", { d in AdaptationEngine.processPainReport(
                PainReport(date: Date(timeIntervalSinceReferenceDate: .nan), timing: .afterRun, hasPain: true),
                state: d.state, plan: replanned, history: d.history, context: d.context) }),
        ]
        for (name, event) in events {
            let o = event(base)
            XCTAssertFalse(o.plan.contains { $0.kind.isQuality }, name)
            XCTAssertEqual(o.changes.filter { $0.kind == .qualitySwappedToEasy }.flatMap(\.workoutIDs), ["t1", "t2"], name)
            XCTAssertEqual(o.state.painStop, base.state.painStop, name)
            XCTAssertEqual(o.history, base.history, name)
            XCTAssertTrue(o.guardrailReport.passed, name)
            for w in o.plan { XCTAssertLessThanOrEqual(w.durationSeconds, replanned.first { $0.id == w.id }!.durationSeconds, name) }
        }
        // Without a stop, the same no-op events still change nothing.
        let quiet = AdaptationEngine.processRun(run, state: AdaptationState(assessments: base.state.assessments), plan: replanned,
                                                history: base.history, context: anyRunner)
        XCTAssertEqual(quiet.plan, replanned)
        XCTAssertTrue(quiet.changes.isEmpty)
    }

    // MARK: Fuzz: nothing in a stopped state schedules a quality session

    private struct SplitMix {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func chance(_ p: Double) -> Bool { Double(next() % 10_000) / 10_000 < p }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    /// 8 to 12 weeks growing 3 to 5% a week, with a recovery week (about 75%
    /// of the week before) every fourth week.
    private func randomPlan(_ rng: inout SplitMix) -> [PlannedWorkout] {
        var totals: [Double] = [Double(180 + rng.int(40))]
        var lastBuild = totals[0]
        for w in 1..<(8 + rng.int(5)) {
            if w % 4 == 3 {
                totals.append((lastBuild * 0.75).rounded(.down))
            } else {
                lastBuild = (lastBuild * (1.03 + Double(rng.int(3)) / 100)).rounded(.down)
                totals.append(lastBuild)
            }
        }
        return Self.plan(totals: totals)
    }

    func testFuzzStoppedStateNeverSchedulesQualityOrAddsLoad() {
        var rng = SplitMix(state: 68)
        var stops = 0, rests = 0, noOps = 0
        for trial in 0..<8 {
            let original = randomPlan(&rng)
            var d = F.Driver(plan: original, context: rng.chance(0.5) ? anyRunner : tracker)
            var stoppedPlan: [String: Double]?
            var lastRun: CompletedRun?
            func checkStopped(_ note: String) {
                guard let stop = d.state.painStop else { return }
                let o = d.outcomes.last!
                XCTAssertFalse(o.plan.contains { $0.kind.isQuality }, "trial \(trial) \(note): quality while stopped")
                if stop.mode == .rest {
                    XCTAssertTrue(o.plan.allSatisfy { $0.kind == .rest || $0.kind == .race }, "trial \(trial) \(note)")
                }
                // Nothing to come is ever longer than when the stop began.
                if let seen = stoppedPlan {
                    for w in o.plan { XCTAssertLessThanOrEqual(w.durationSeconds, (seen[w.id] ?? .infinity) + 1e-6, "trial \(trial) \(w.id)") }
                }
                stoppedPlan = Dictionary(o.plan.map { ($0.id, $0.durationSeconds) }, uniquingKeysWith: min)
                // No week to come plans more than the pre-stop level.
                if let level = stop.level, o.holdsSatisfied {
                    let first = PlanCalendar.weekStart(containing: stop.since, timeZone: F.tz)
                    for w in o.plan where w.date >= first {
                        let week = PlanCalendar.weekStart(containing: w.date, timeZone: F.tz)
                        let v = (o.history + o.plan).filter { PlanCalendar.weekStart(containing: $0.date, timeZone: F.tz) == week }
                            .reduce(0) { $0 + ($1.volume(.time) ?? 0) }
                        XCTAssertLessThanOrEqual(v, level + 1, "trial \(trial) \(note): week of \(w.id) above the ceiling")
                    }
                }
            }
            for w in original {
                guard let current = d.plan.first(where: { $0.id == w.id }) else { continue }
                if rng.chance(0.85), current.kind != .rest {
                    d.mornings(through: current.date)
                    guard let now = d.plan.first(where: { $0.id == w.id }), now.kind != .rest else { continue }
                    let run = F.run(for: now)
                    lastRun = run
                    d.take(AdaptationEngine.processRun(run, state: d.state, plan: d.plan, history: d.history, context: d.context))
                    checkStopped("run \(w.id)")
                    let r = PainReport(date: now.date.addingTimeInterval(now.durationSeconds + 600), timing: .afterRun,
                                       hasPain: rng.chance(0.4), worsenedDuringRun: rng.chance(0.04),
                                       changedMovement: rng.chance(0.015), score: rng.chance(0.3) ? rng.int(12) : nil,
                                       activityID: "run-\(w.id)")
                    d.report(r)
                    checkStopped("report after \(w.id)")
                }
                // The next morning, sometimes.
                if rng.chance(0.5) {
                    let morning = PlanCalendar.calendar(timeZone: F.tz).startOfDay(for: w.date).addingTimeInterval(86_400 + 6.5 * 3_600)
                    d.report(PainReport(date: morning, timing: .nextMorning, hasPain: rng.chance(0.08)))
                    checkStopped("morning after \(w.id)")
                }
                // Now and then a re-plan hands the original sessions back, with
                // a quiet day or one of the events the engine treats as a no-op.
                if rng.chance(0.12) {
                    let now = d.history.map(\.date).max() ?? w.date
                    d.plan = original.filter { $0.date > now }
                    stoppedPlan = nil   // the app's new plan is the new baseline
                    switch rng.int(4) {
                    case 0:
                        d.day(now.addingTimeInterval(60))
                    case 1:
                        if let dup = d.state.painReports.last { d.report(dup) } else { d.day(now.addingTimeInterval(60)) }
                    case 2:
                        if let run = lastRun {
                            d.take(AdaptationEngine.processRun(run, state: d.state, plan: d.plan, history: d.history, context: d.context))
                        } else { d.day(now.addingTimeInterval(60)) }
                    default:
                        d.take(AdaptationEngine.processPainReport(
                            PainReport(date: Date(timeIntervalSinceReferenceDate: .nan), timing: .afterRun, hasPain: true),
                            state: d.state, plan: d.plan, history: d.history, context: d.context))
                    }
                    if d.state.painStop != nil { noOps += 1 }
                    checkStopped("re-plan after \(w.id)")
                }
            }
            if let s = d.state.painStop { stops += 1; if s.mode == .rest { rests += 1 } }
            for o in d.outcomes { for c in o.changes { XCTAssertFalse(c.triggers.isEmpty, "\(c.kind)") } }
        }
        XCTAssertGreaterThan(stops, 3, "the fuzz should reach stopped states")
        XCTAssertGreaterThan(rests, 0)
        XCTAssertGreaterThan(noOps, 3, "the fuzz should re-plan while stopped")
    }
}
