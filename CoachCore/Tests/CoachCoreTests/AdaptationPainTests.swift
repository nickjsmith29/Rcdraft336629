import XCTest
@testable import CoachCore

// SPEC 3.5 pain check-in inside the F4 engine, on synthetic plans only. These
// cover the review notes on #30: the engine stores the response it applied,
// keeps its freeze in force until it ends, passes the applied check-in back as
// `lastAppliedCheckIn`, and evaluates every new check-in.
final class AdaptationPainTests: XCTestCase {
    typealias F = AdaptFixture
    private let pain = AdaptFixture.context(tracksPain: true)

    /// Week 1 plans about 5% more than week 0 (224 against 214 minutes).
    private var growingPlan: [PlannedWorkout] { F.weeks(0..<3, easyMinutes: { $0 == 1 ? (60, 50) : (55, 45) }) }
    private var checkInDate: Date { F.date(week: 0, day: 5, hour: 10) }   // Saturday, after the long run

    private func find(_ id: String, _ plan: [PlannedWorkout]) -> PlannedWorkout? { plan.first { $0.id == id } }

    func testHighScoreStoresResponseSwapsNextQualityAndFreezesVolume() {
        var d = F.Driver(plan: growingPlan, context: pain)
        d.follow(until: F.date(week: 0, day: 5, hour: 9)) { _ in F.RunSpec() }
        d.checkIn(5, at: checkInDate)
        let o = d.outcomes.last!

        // Stored response and the date passed back to the rule.
        XCTAssertEqual(d.state.appliedPainResponse?.checkIn, PainCheckIn(date: checkInDate, score: 5))
        XCTAssertEqual(d.state.lastAppliedCheckIn, checkInDate)
        let freeze = d.state.freezes.first { $0.checkIn == checkInDate }!
        XCTAssertEqual(freeze.interval.end, F.date(week: 1, day: 5, hour: 10))
        XCTAssertEqual(d.state.freezeIntervals(at: checkInDate), [freeze.interval])

        // The next quality session is easy now, same id, date and length, with an easy HR cap.
        let t1 = find("t1", d.plan)!
        XCTAssertEqual(t1.kind, .easy)
        XCTAssertEqual(t1.date, F.date(week: 1, day: 1))
        XCTAssertEqual(t1.prescription?.segments.map(\.intensity), [.easy])
        XCTAssertEqual(t1.prescription?.segments.first?.target.heartRate.ceilingBPM, F.zones.easyCeiling)
        let swap = o.changes.first { $0.kind == .qualitySwappedToEasy }!
        XCTAssertEqual(swap.workoutIDs, ["t1"])
        XCTAssertEqual(swap.triggers.first?.metric, .painScore)
        XCTAssertEqual(swap.triggers.first?.value, 5)
        XCTAssertTrue(swap.explanation.contains("not a diagnosis"))
        XCTAssertTrue(o.changes.contains { $0.kind == .painVolumeFreeze })

        // Week 1 overlaps the freeze, so its planned growth is cut back to week 0.
        XCTAssertLessThanOrEqual(F.weekVolume(1, d.plan), F.weekVolume(0, d.history + d.plan) + 1e-6)
        XCTAssertFalse(o.suggestClinician)
        assertAdaptationSound(d.outcomes)
    }

    func testOneCheckInSwapsOneQualitySessionOnly() {
        var d = F.Driver(plan: growingPlan, context: pain)
        d.follow(until: F.date(week: 0, day: 5, hour: 9)) { _ in F.RunSpec() }
        d.checkIn(5, at: checkInDate)
        // The same check-in delivered again (the app re-syncs) is not acted on twice.
        d.checkIn(5, at: checkInDate)
        XCTAssertTrue(d.outcomes.last!.changes.filter { $0.kind == .qualitySwappedToEasy }.isEmpty)
        // Runs through the freeze and beyond never swap another session.
        d.follow(until: F.date(week: 2, day: 1, hour: 6)) { _ in F.RunSpec() }
        XCTAssertEqual(d.changes.filter { $0.kind == .qualitySwappedToEasy }.flatMap(\.workoutIDs), ["t1"])
        XCTAssertEqual(find("t2", d.plan)?.kind, .quality(.threshold))
        XCTAssertEqual(d.state.lastAppliedCheckIn, checkInDate)
        assertAdaptationSound(d.outcomes)
    }

    func testFreezeIsEnforcedUntilItEnds() {
        var d = F.Driver(plan: growingPlan, context: pain)
        d.follow(until: F.date(week: 0, day: 5, hour: 9)) { _ in F.RunSpec() }
        d.checkIn(5, at: checkInDate)
        d.follow(until: F.date(week: 0, day: 6, hour: 23)) { _ in F.RunSpec() }
        let week0 = F.weekVolume(0, d.history)

        // A plan handed back with extra running in the frozen week (say a re-plan)
        // is cut back on the next event.
        var during = d
        during.plan.append(F.easy("x1", week: 1, day: 4, minutes: 30))
        let before = during.outcomes.count
        during.day(F.date(week: 1, day: 0, hour: 6))
        XCTAssertLessThanOrEqual(F.weekVolume(1, during.plan), week0 + 1e-6)
        XCTAssertTrue(during.outcomes[before...].flatMap(\.changes).contains { $0.kind == .sessionShortened || $0.kind == .sessionDropped })

        // Once the freeze has ended, the same kind of addition within 10% stays.
        d.follow(until: F.date(week: 1, day: 5, hour: 23)) { _ in F.RunSpec() }
        d.plan.append(F.easy("x2", week: 1, day: 6, minutes: 15, hour: 18))
        d.day(F.date(week: 1, day: 6, hour: 6))
        XCTAssertTrue(d.state.freezes.isEmpty, "an ended freeze is dropped")
        XCTAssertNotNil(d.state.appliedPainResponse, "the applied response is kept for lastAppliedCheckIn")
        XCTAssertEqual(find("x2", d.plan)?.durationSeconds, 15 * 60)
        assertAdaptationSound(d.outcomes)
    }

    func testRePlanDuringFreezeGetsTheSwapAgain() {
        let plan = F.weeks(0..<2)
        let monday = F.date(week: 0, day: 0, hour: 8)
        let first = AdaptationEngine.processCheckIn(PainCheckIn(date: monday, score: 6), state: AdaptationState(),
                                                    plan: plan, history: [], context: pain)
        XCTAssertEqual(find("t0", first.plan)?.kind, .easy)
        // A goal edit (F2) re-plans and hands back t0 as quality.
        var replanned = first.plan
        replanned[replanned.firstIndex { $0.id == "t0" }!] = plan.first { $0.id == "t0" }!
        let again = AdaptationEngine.processDay(asOf: F.date(week: 0, day: 0, hour: 12), state: first.state,
                                                plan: replanned, history: first.history, context: pain)
        XCTAssertEqual(find("t0", again.plan)?.kind, .easy)
        XCTAssertEqual(again.changes.map(\.kind), [.qualitySwappedToEasy])
        XCTAssertEqual(again.changes[0].triggers.first?.metric, .painScore)
    }

    func testEveryCheckInIsEvaluatedSoAHighScoreIsNotLost() {
        let plan = F.weeks(0..<2)
        let high = PainCheckIn(date: F.date(week: 0, day: 0, hour: 8), score: 5)
        let low = PainCheckIn(date: F.date(week: 0, day: 0, hour: 9), score: 3)
        // Evaluating only the latest later on would lose the high score:
        let lateOnly = PainCheckInRule.evaluate(tracksPain: true, checkIns: [high, low], plan: plan, asOf: low.date,
                                                lastAppliedCheckIn: nil, timeZone: F.tz)
        XCTAssertEqual(lateOnly, .noAction)
        // The engine evaluates each one as it arrives.
        let outcomes = AdaptationReplay.replay([.painCheckIn(low), .painCheckIn(high)], plan: plan, context: pain)
            .filter { if case .painCheckIn = $0.event { return true }; return false }.map(\.outcome)
        XCTAssertEqual(outcomes[0].state.appliedPainResponse?.checkIn, high, "replay orders events by time")
        XCTAssertEqual(outcomes[0].changes.first { $0.kind == .qualitySwappedToEasy }?.workoutIDs, ["t0"])
        XCTAssertTrue(outcomes[1].changes.isEmpty)
        XCTAssertEqual(outcomes[1].state.lastAppliedCheckIn, high.date)
        XCTAssertEqual(outcomes[1].state.painCheckIns, [high, low])
    }

    func testSameTimestampPrefersTheHigherScoreInEitherOrder() {
        let plan = F.weeks(0..<2)
        let t = F.date(week: 0, day: 0, hour: 8)
        for order in [[5, 2], [2, 5]] {
            var state = AdaptationState(), p = plan
            var swaps = 0
            for score in order {
                let o = AdaptationEngine.processCheckIn(PainCheckIn(date: t, score: score), state: state, plan: p,
                                                        history: [], context: pain)
                state = o.state; p = o.plan
                swaps += o.changes.filter { $0.kind == .qualitySwappedToEasy }.count
            }
            XCTAssertEqual(state.appliedPainResponse?.checkIn.score, 5, "order \(order)")
            XCTAssertEqual(swaps, 1, "order \(order)")
            XCTAssertEqual(state.painCheckIns.map(\.score), [2, 5])
        }
    }

    func testNoPainHistoryMeansNoAction() {
        let o = AdaptationEngine.processCheckIn(PainCheckIn(date: F.date(week: 0, day: 0), score: 9),
                                                state: AdaptationState(), plan: F.weeks(0..<2), history: [],
                                                context: F.context(tracksPain: false))
        XCTAssertTrue(o.changes.isEmpty)
        XCTAssertNil(o.state.appliedPainResponse)
        XCTAssertNil(o.state.lastAppliedCheckIn)
        XCTAssertTrue(o.state.freezes.isEmpty)
    }

    func testInvalidScoreIsIgnored() {
        let o = AdaptationEngine.processCheckIn(PainCheckIn(date: F.date(week: 0, day: 0), score: 11),
                                                state: AdaptationState(), plan: F.weeks(0..<2), history: [], context: pain)
        XCTAssertTrue(o.changes.isEmpty)
        XCTAssertNil(o.state.appliedPainResponse)
    }

    func testPersistentPainPromptsAClinician() {
        var state = AdaptationState(), plan = F.weeks(0..<3)
        var prompts: [Bool] = []
        for day in [0, 2, 4] {
            let o = AdaptationEngine.processCheckIn(PainCheckIn(date: F.date(week: 0, day: day, hour: 6), score: 5),
                                                    state: state, plan: plan, history: [], context: pain)
            state = o.state; plan = o.plan
            prompts.append(o.suggestClinician)
        }
        XCTAssertEqual(prompts, [false, false, true])
        XCTAssertTrue(state.appliedPainResponse!.explanation.contains("clinician"))
    }
}
