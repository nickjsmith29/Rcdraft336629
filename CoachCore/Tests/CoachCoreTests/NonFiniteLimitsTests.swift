import XCTest
@testable import CoachCore

// #133: a tunable limit set to NaN or infinity used to crash the adaptation
// engine ("Double value cannot be converted to Int") where it rounds a limit
// or a length built from one, or stall it. On main: `minimumTrimmedSeconds`
// (NaN, +inf crash; -inf stalls), `longRunDecouplingLimit` (NaN, ±inf), and in
// `PainRecoveryLimits` `testMaxSeconds` (NaN, -inf), `rampWeek2Fraction` (-inf)
// and `week1Fraction` (NaN, ±inf stall). Every `Double` limit of
// `AdaptationLimits` and `PainRecoveryLimits` that isn't a finite number, or is
// below 0, is now stored as its default; finite values at or above 0 are kept,
// and a finite `minimumTrimmedSeconds` of 0 or less still applies no floor.
// Synthetic plans and runs only; every limit is a heuristic (SPEC F4, section
// 8, 3.3, 3.5 rules 4, 6 and 7).
final class NonFiniteLimitsTests: XCTestCase {
    typealias F = AdaptFixture
    typealias Field = (name: String, path: WritableKeyPath<AdaptationLimits, Double>)

    private let bad: [Double] = [.nan, .infinity, -.infinity]

    private let fields: [Field] = [
        ("paceTolerance", \.paceTolerance), ("paceStep", \.paceStep),
        ("strainDecouplingPercent", \.strainDecouplingPercent), ("strainCadenceFadePercent", \.strainCadenceFadePercent),
        ("longRunDecouplingLimit", \.longRunDecouplingLimit), ("longRunCompletionShare", \.longRunCompletionShare),
        ("longRunStepSeconds", \.longRunStepSeconds), ("holdLongRunFloorShare", \.holdLongRunFloorShare),
        ("hillyClimbMetersPerKm", \.hillyClimbMetersPerKm), ("minimumKeyShare", \.minimumKeyShare),
        ("minimumTrimmedSeconds", \.minimumTrimmedSeconds), ("powerToHeartRateDropPercent", \.powerToHeartRateDropPercent),
        ("regrowthAtPlanShare", \.regrowthAtPlanShare),
    ]

    private func limits(_ path: WritableKeyPath<AdaptationLimits, Double>, _ value: Double) -> AdaptationLimits {
        var l = AdaptationLimits()
        l[keyPath: path] = value
        return l
    }

    // MARK: Scenarios that reach a limit's Int conversion

    /// A week whose other running (20 min) is too little for a long run
    /// above the floor: repair swaps the long run for an easy run and says
    /// why, naming the floor in minutes (`GuardrailRepair.swapLongRunToEasy`).
    /// A non-finite floor crashed here on main.
    private func thinWeek(_ limits: AdaptationLimits) -> F.Driver {
        let history = (0..<4).map { F.easy("h\($0)", week: 0, day: $0 * 2, minutes: 50.0) }
        let plan = [F.easy("e1", week: 1, day: 2, minutes: 20), F.long("l1", week: 1, day: 6, minutes: 50)]
        var d = F.Driver(plan: plan, history: history, context: F.context(limits: limits))
        d.day(F.date(week: 1, day: 0, hour: 6))
        return d
    }

    /// Two recent long runs that didn't qualify: the long-run gate (3.3) holds
    /// the next long run and says why, naming the decoupling limit in whole
    /// percent and the step in minutes.
    private func heldGate(_ limits: AdaptationLimits) -> F.Driver {
        var d = F.Driver(plan: F.weeks(0..<2), context: F.context(limits: limits))
        d.state.longRuns = [-2, -1].map { w in
            LongRunRecord(activityID: "old-l\(-w)", date: F.date(week: w, day: 5), plannedSeconds: 40 * 60,
                          movingSeconds: 40 * 60, decouplingPercent: 8)
        }
        d.day(F.date(week: 0, day: 0, hour: 5))
        return d
    }

    /// Two quality sessions behind: paces slow and volume is held.
    private func behind(_ limits: AdaptationLimits) -> F.Driver {
        var d = F.Driver(plan: F.weeks(0..<4, easyMinutes: { $0 == 2 ? (62, 50) : (55, 45) }), context: F.context(limits: limits))
        let specs: [String: F.RunSpec] = ["t0": F.RunSpec(pace: 1.04), "t1": F.RunSpec(hr: .high)]
        d.follow(until: F.date(week: 2, day: 6, hour: 23)) { specs[$0.id] ?? F.RunSpec() }
        return d
    }

    // MARK: The crash, reproduced and fixed

    func testANonFiniteFloorNoLongerCrashesTheEngine() throws {
        let expected = thinWeek(.default)
        XCTAssertEqual(expected.changes.map(\.kind), [.longRunSwappedToEasy])
        XCTAssertTrue(expected.changes[0].explanation.contains("a long run of even 20 min"), expected.changes[0].explanation)
        for v in bad {
            // Set where the limits are built, and set afterwards.
            let built = thinWeek(AdaptationLimits(minimumTrimmedSeconds: v))
            let set = thinWeek(limits(\.minimumTrimmedSeconds, v))
            XCTAssertEqual(built.outcomes, expected.outcomes, "minimumTrimmedSeconds \(v) reads as the default")
            XCTAssertEqual(set.outcomes, expected.outcomes, "minimumTrimmedSeconds \(v) reads as the default")
            XCTAssertEqual(built.plan.first { $0.id == "l1" }?.durationSeconds, PlanHeuristics.minimumEasyRunSeconds)
            assertAdaptationSound(built.outcomes)
        }
    }

    func testANonFiniteGateLimitNoLongerCrashesTheGate() throws {
        let expected = heldGate(.default)
        let held = try XCTUnwrap(expected.changes.first { $0.kind == .longRunHeld })
        XCTAssertTrue(held.explanation.contains("decoupling under 5%"), held.explanation)
        for (name, path) in [("longRunDecouplingLimit", \AdaptationLimits.longRunDecouplingLimit),
                             ("longRunStepSeconds", \.longRunStepSeconds),
                             ("longRunCompletionShare", \.longRunCompletionShare)] as [Field] {
            for v in bad + [-1] {
                XCTAssertEqual(heldGate(limits(path, v)).outcomes, expected.outcomes, "\(name) \(v) reads as the default")
            }
        }
    }

    func testEveryBadDoubleLimitRunsTheEngineAsTheDefault() {
        let thin = thinWeek(.default).outcomes, gate = heldGate(.default).outcomes, slow = behind(.default).outcomes
        XCTAssertTrue(behind(.default).changes.contains { $0.kind == .paceTargetsSlower })
        for (name, path) in fields {
            for v in bad {
                let l = limits(path, v)
                XCTAssertEqual(thinWeek(l).outcomes, thin, "\(name) \(v)")
                XCTAssertEqual(heldGate(l).outcomes, gate, "\(name) \(v)")
                XCTAssertEqual(behind(l).outcomes, slow, "\(name) \(v)")
            }
        }
    }

    // MARK: Where the limits are built

    func testEveryBadDoubleLimitFallsBackToItsDefault() {
        for (name, path) in fields {
            let negatives: [Double] = name == "minimumTrimmedSeconds" ? [] : [-1, -.leastNonzeroMagnitude]
            for v in bad + negatives {
                XCTAssertEqual(limits(path, v)[keyPath: path], AdaptationLimits.default[keyPath: path], "\(name) \(v)")
                XCTAssertEqual(limits(path, v), .default, "\(name) \(v): only that limit was bad")
            }
        }
        // The same when the bad value is handed to the initializer.
        let nan = Double.nan
        let built = AdaptationLimits(paceTolerance: nan, paceStep: nan, strainDecouplingPercent: nan,
                                     strainCadenceFadePercent: nan, longRunDecouplingLimit: nan, longRunCompletionShare: nan,
                                     longRunStepSeconds: nan, holdLongRunFloorShare: nan, hillyClimbMetersPerKm: nan,
                                     minimumKeyShare: nan, minimumTrimmedSeconds: nan, powerToHeartRateDropPercent: nan,
                                     regrowthAtPlanShare: nan)
        XCTAssertEqual(built, .default)
        let negative = AdaptationLimits(paceTolerance: -1, paceStep: -1, strainDecouplingPercent: -1,
                                        strainCadenceFadePercent: -1, longRunDecouplingLimit: -1, longRunCompletionShare: -1,
                                        longRunStepSeconds: -1, holdLongRunFloorShare: -1, hillyClimbMetersPerKm: -1,
                                        minimumKeyShare: -1, powerToHeartRateDropPercent: -1, regrowthAtPlanShare: -1)
        XCTAssertEqual(negative, .default)
        XCTAssertEqual(AdaptationLimits(minimumTrimmedSeconds: .infinity).minimumTrimmedSeconds, PlanHeuristics.minimumEasyRunSeconds)
    }

    func testTheDefaultsAreUnchanged() {
        let d = AdaptationLimits.default
        XCTAssertEqual(d.paceTolerance, 0.01)
        XCTAssertEqual(d.paceStep, 0.015)
        XCTAssertEqual(d.strainDecouplingPercent, 10)
        XCTAssertEqual(d.strainCadenceFadePercent, 3)
        XCTAssertEqual(d.longRunDecouplingLimit, 5)
        XCTAssertEqual(d.longRunCompletionShare, 0.95)
        XCTAssertEqual(d.longRunStepSeconds, PlanHeuristics.longRunStepSeconds)
        XCTAssertEqual(d.holdLongRunFloorShare, 0.85)
        XCTAssertEqual(d.hillyClimbMetersPerKm, 15)
        XCTAssertEqual(d.minimumKeyShare, 0.5)
        XCTAssertEqual(d.minimumTrimmedSeconds, PlanHeuristics.minimumEasyRunSeconds)
        XCTAssertEqual(d.powerToHeartRateDropPercent, 5)
        XCTAssertEqual(d.regrowthAtPlanShare, 0.98)
        XCTAssertEqual(AdaptationLimits(), d)
    }

    func testFiniteLimitsAreKeptAsTheyAre() {
        for (name, path) in fields {
            for v in [0, 0.5, 1, 42, 1e6] {
                XCTAssertEqual(limits(path, v)[keyPath: path], v, "\(name) \(v)")
            }
        }
        XCTAssertEqual(AdaptationLimits(paceStep: 0.02).paceStep, 0.02)
        XCTAssertEqual(AdaptationLimits(minimumTrimmedSeconds: 15 * 60).minimumTrimmedSeconds, 15 * 60)
        // A finite floor of 0 or less still applies no floor (`runFloorSeconds`).
        for v in [0.0, -60] {
            XCTAssertEqual(AdaptationLimits(minimumTrimmedSeconds: v).minimumTrimmedSeconds, v)
            XCTAssertEqual(limits(\.minimumTrimmedSeconds, v).minimumTrimmedSeconds, v)
        }
        // A finite limit still changes what the engine does: a 25-minute floor.
        let l1 = thinWeek(AdaptationLimits(minimumTrimmedSeconds: 25 * 60)).plan.first { $0.id == "l1" }
        XCTAssertEqual(l1?.durationSeconds, 25 * 60)
    }

    // MARK: The pain stop's return (PainRecoveryLimits, 3.5 rule 7)

    typealias RecoveryField = (name: String, path: WritableKeyPath<PainRecoveryLimits, Double>)
    private let recoveryFields: [RecoveryField] = [
        ("persistHours", \.persistHours), ("testMaxSeconds", \.testMaxSeconds), ("testDefaultSeconds", \.testDefaultSeconds),
        ("testShareOfEasy", \.testShareOfEasy), ("testMinSeconds", \.testMinSeconds), ("week1Fraction", \.week1Fraction),
        ("rampWeek2Fraction", \.rampWeek2Fraction), ("fullWeekShare", \.fullWeekShare),
        ("unknownLevelSeconds", \.unknownLevelSeconds), ("unknownLevelMetres", \.unknownLevelMetres),
    ]

    private func recovery(_ path: WritableKeyPath<PainRecoveryLimits, Double>, _ value: Double) -> PainRecoveryLimits {
        var l = PainRecoveryLimits()
        l[keyPath: path] = value
        return l
    }

    /// Pain that worsened on a run stops running; pain-free mornings end it
    /// with a test run; the return then runs weeks 1 and 2 (3.5 rule 7).
    private func painStop(_ limits: PainRecoveryLimits) -> F.Driver {
        var c = F.context(tracksPain: true)
        c.painRecoveryLimits = limits
        var d = F.Driver(plan: F.weeks(0..<4), context: c)
        d.follow(until: F.date(week: 0, day: 6, hour: 23)) { _ in F.RunSpec() }
        d.afterRun(week: 0, day: 6, 6, worsened: true, hour: 10)
        for day in 0..<7 { d.morning(week: 1, day: day, 0) }
        if d.testSession != nil { d.runTest(0) }
        for day in 0..<7 { d.morning(week: 2, day: day, 0) }
        d.follow(until: F.date(week: 3, day: 6, hour: 23)) { _ in F.RunSpec() }
        return d
    }

    func testBadReturnLimitsNoLongerCrashOrStallThePainStop() {
        let expected = painStop(.default)
        XCTAssertTrue(expected.changes.contains { $0.kind == .painStopEnded }, "\(expected.changes.map(\.kind))")
        for (name, path) in [("testMaxSeconds", \PainRecoveryLimits.testMaxSeconds), ("rampWeek2Fraction", \.rampWeek2Fraction),
                             ("week1Fraction", \.week1Fraction)] as [RecoveryField] {
            for v in bad {
                XCTAssertEqual(painStop(recovery(path, v)).outcomes, expected.outcomes, "\(name) \(v) reads as the default")
            }
        }
    }

    func testEveryBadReturnLimitFallsBackToItsDefault() {
        for (name, path) in recoveryFields {
            for v in bad + [-1] {
                XCTAssertEqual(recovery(path, v)[keyPath: path], PainRecoveryLimits.default[keyPath: path], "\(name) \(v)")
                XCTAssertEqual(recovery(path, v), .default, "\(name) \(v): only that limit was bad")
            }
            for v in [0, 0.5, 1, 1e6] {
                XCTAssertEqual(recovery(path, v)[keyPath: path], v, "\(name) \(v) is kept")
            }
        }
        let nan = Double.nan
        XCTAssertEqual(PainRecoveryLimits(persistHours: nan, testMaxSeconds: nan, testDefaultSeconds: nan, testShareOfEasy: nan,
                                          testMinSeconds: nan, week1Fraction: nan, rampWeek2Fraction: nan, fullWeekShare: nan,
                                          unknownLevelSeconds: nan, unknownLevelMetres: nan), .default)
        XCTAssertEqual(PainRecoveryLimits(testMaxSeconds: 25 * 60).testMaxSeconds, 25 * 60)
        let d = PainRecoveryLimits.default
        XCTAssertEqual([d.persistHours, d.testMaxSeconds, d.testDefaultSeconds, d.testShareOfEasy, d.testMinSeconds,
                        d.week1Fraction, d.rampWeek2Fraction, d.fullWeekShare, d.unknownLevelSeconds, d.unknownLevelMetres],
                       [48.0, 30.0 * 60, 20.0 * 60, 0.5, 10.0 * 60, 0.65, 0.85, 0.9, 90.0 * 60, 15_000.0], "the defaults are unchanged")
    }
}
