import Foundation
import XCTest
@testable import CoachCore

// #142: more bad-limit guards, after #133 (`NonFiniteLimitsTests`).
//
// Before #142, a `GuardrailLimits` `maxWeeklyIncrease` or `maxLongRunShare`
// of -1 was used as it was, so the adaptation engine's outcomes through a
// pain stop and its return differed from the default's. (The stall once seen
// at -1 was the `follow` test-driver loop, which #148 fixed, not the engine.)
// A negative `PainRuleLimits.persistentCount` trapped in `suffix`, and an
// `Int.min` `highScore` or `minimumRise` overflowed where the engine cites the
// limit; and `PlanFormatting.volume` and `percent` trapped on a value that
// isn't finite, such as a large but finite limit times a volume. Every
// `GuardrailLimits` and `PainRuleLimits` limit that is NaN, below 0 or -inf is
// now stored as its default (+inf too, except `maxSingleRunIncrease`, where
// `.infinity` switches the spike rule off), and the two formatters show "-".
// Synthetic plans, runs and check-ins only; every limit is a heuristic (SPEC
// 3.5, F4, F9, section 8).

/// Where a background run leaves its result.
private final class Outcome<T>: @unchecked Sendable {
    var value: T?
}

final class LimitGuardTests: XCTestCase {
    typealias F = AdaptFixture

    /// Runs `work` on its own thread and waits at most `seconds` for it, so a
    /// stall fails the test instead of hanging the suite. Nil (and a
    /// failure) when it hasn't finished in time.
    private func bounded<T>(_ label: String, seconds: Double = 60, file: StaticString = #filePath, line: UInt = #line,
                            _ work: @escaping () -> T) -> T? {
        let out = Outcome<T>()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            out.value = work()
            done.signal()
        }
        thread.stackSize = 64 << 20
        thread.start()
        guard done.wait(timeout: .now() + seconds) == .success else {
            XCTFail("\(label): still running after \(Int(seconds)) s", file: file, line: line)
            return nil
        }
        return out.value
    }

    // MARK: Scenarios

    /// Pain that worsened on a run stops running; pain-free mornings end it
    /// with a test run; the return then runs weeks 1 and 2 (3.5 rule 7).
    private func painStop(_ guardrails: GuardrailLimits) -> F.Driver {
        var c = F.context(tracksPain: true)
        c.guardrails = guardrails
        var d = F.Driver(plan: F.weeks(0..<4), context: c)
        d.follow(until: F.date(week: 0, day: 6, hour: 23)) { _ in F.RunSpec() }
        d.afterRun(week: 0, day: 6, 6, worsened: true, hour: 10)
        for day in 0..<7 { d.morning(week: 1, day: day, 0) }
        if d.testSession != nil { d.runTest(0) }
        for day in 0..<7 { d.morning(week: 2, day: day, 0) }
        d.follow(until: F.date(week: 3, day: 6, hour: 23)) { _ in F.RunSpec() }
        return d
    }

    /// A week of threshold, easy and long runs missed (week 1), then the plan
    /// followed again: the cut week and its regrowth (3.5 rule 6).
    private func missedWeek(_ guardrails: GuardrailLimits) -> F.Driver {
        var c = F.context()
        c.guardrails = guardrails
        var d = F.Driver(plan: F.weeks(0..<4), context: c)
        d.follow(until: F.date(week: 2, day: 6, hour: 23)) { w in
            ["t1", "e1a", "e1b", "l1"].contains(w.id) ? nil : F.RunSpec()
        }
        return d
    }

    /// Three high check-ins after long runs (3.5): the response, and on the
    /// third the clinician prompt.
    private func checkIns(_ limits: PainRuleLimits) -> F.Driver {
        var c = F.context(tracksPain: true)
        c.painLimits = limits
        var d = F.Driver(plan: F.weeks(0..<3), context: c)
        d.follow(until: F.date(week: 0, day: 5, hour: 23)) { _ in F.RunSpec() }
        d.checkIn(6, at: F.date(week: 0, day: 5, hour: 12))
        d.checkIn(7, at: F.date(week: 0, day: 6, hour: 12))
        d.checkIn(7, at: F.date(week: 1, day: 0, hour: 12))
        d.follow(until: F.date(week: 1, day: 6, hour: 23)) { _ in F.RunSpec() }
        return d
    }

    /// Six weeks of history (a dip in week 4) and a plan of four quality
    /// sessions and a long run a week: every guardrail has something to report.
    private func report(_ limits: GuardrailLimits) -> [GuardrailReport] {
        let P = PlanFixture.self
        let history = (0..<6).flatMap { w in
            [P.workout("h\(w)a", week: w, day: 1, .easy, minutes: 100, km: 16),
             P.workout("h\(w)l", week: w, day: 5, .long, minutes: w == 4 ? 10 : 80, km: w == 4 ? 1.6 : 13)]
        }
        let plan = (6..<10).flatMap { w in
            [P.workout("p\(w)a", week: w, day: 1, .quality(.threshold), minutes: 120, km: 22),
             P.workout("p\(w)b", week: w, day: 3, .quality(.intervals), minutes: 60, km: 11),
             P.workout("p\(w)c", week: w, day: 4, .quality(.tempo), minutes: 60, km: 11),
             P.workout("p\(w)l", week: w, day: 5, .long, minutes: 200, km: 32)]
        }
        return [VolumeMeasure.time, .distance].map { m in
            var l = limits
            l.measure = m
            return GuardrailChecker.check(history: history, planned: plan, timeZone: P.utc, limits: l)
        }
    }

    // MARK: GuardrailLimits fields

    typealias DoubleField = (name: String, path: WritableKeyPath<GuardrailLimits, Double>)
    typealias IntField = (name: String, path: WritableKeyPath<GuardrailLimits, Int>)

    private let doubleFields: [DoubleField] = [
        ("maxWeeklyIncrease", \.maxWeeklyIncrease), ("maxFourWeekIncrease", \.maxFourWeekIncrease),
        ("maxLongRunShare", \.maxLongRunShare), ("marathonMaxLongRunShare", \.marathonMaxLongRunShare),
        ("recoveryWeekMaxRatio", \.recoveryWeekMaxRatio), ("maxSingleRunIncrease", \.maxSingleRunIncrease),
        ("breakWeekMaxRatio", \.breakWeekMaxRatio), ("regrowthMaxWeeklyRise", \.regrowthMaxWeeklyRise),
    ]
    private let intFields: [IntField] = [
        ("maxConsecutiveBuildWeeks", \.maxConsecutiveBuildWeeks), ("maxQualitySessionsPerWeek", \.maxQualitySessionsPerWeek),
        ("spikeWindowDays", \.spikeWindowDays), ("preBreakWeeks", \.preBreakWeeks), ("maxShortBreakWeeks", \.maxShortBreakWeeks),
    ]

    private func guardrails<V>(_ path: WritableKeyPath<GuardrailLimits, V>, _ value: V) -> GuardrailLimits {
        var l = GuardrailLimits()
        l[keyPath: path] = value
        return l
    }

    /// The values that fall back: NaN, below 0 and -inf, and +inf except
    /// where it switches a rule off.
    private func bad(_ name: String) -> [Double] {
        [.nan, -.infinity, -1, -.leastNonzeroMagnitude] + (name == "maxSingleRunIncrease" ? [] : [.infinity])
    }

    // MARK: A -1 limit through a pain stop

    /// A -1 `maxWeeklyIncrease`, `maxLongRunShare` or `recoveryWeekMaxRatio`,
    /// set or built, gives the same engine outcomes through a pain stop and
    /// its return as the default limits. Each run is time-bounded (`bounded`)
    /// so a regression fails instead of hanging the suite.
    func testANegativeGuardrailLimitGivesTheDefaultOutcomesThroughAPainStop() throws {
        let expected = try XCTUnwrap(bounded("default") { self.painStop(.default) })
        XCTAssertTrue(expected.changes.contains { $0.kind == .painStopEnded }, "\(expected.changes.map(\.kind))")
        for (name, path) in [("maxWeeklyIncrease", \GuardrailLimits.maxWeeklyIncrease), ("maxLongRunShare", \.maxLongRunShare),
                             ("recoveryWeekMaxRatio", \.recoveryWeekMaxRatio)] as [DoubleField] {
            let set = guardrails(path, -1)
            guard let d = bounded("\(name) -1", { self.painStop(set) }) else { continue }
            XCTAssertEqual(d.outcomes, expected.outcomes, "\(name) -1 reads as the default")
            assertAdaptationSound(d.outcomes)
        }
        let built = GuardrailLimits(maxWeeklyIncrease: -1, maxLongRunShare: -1, recoveryWeekMaxRatio: -1)
        if let d = bounded("built with -1", { self.painStop(built) }) {
            XCTAssertEqual(d.outcomes, expected.outcomes)
        }
    }

    func testEveryBadGuardrailLimitFallsBackToItsDefault() {
        for (name, path) in doubleFields {
            for v in bad(name) {
                XCTAssertEqual(guardrails(path, v)[keyPath: path], GuardrailLimits.default[keyPath: path], "\(name) \(v)")
                XCTAssertEqual(guardrails(path, v), .default, "\(name) \(v): only that limit was bad")
            }
        }
        for (name, path) in intFields {
            for v in [-1, Int.min] {
                XCTAssertEqual(guardrails(path, v), .default, "\(name) \(v)")
            }
        }
        for v: [Double] in [[.nan, 1], [-1], [0.7, .infinity], [0.7, -.infinity, 1]] {
            XCTAssertEqual(guardrails(\.breakReturnSteps, v), .default, "breakReturnSteps \(v)")
            XCTAssertEqual(guardrails(\.regrowthReturnSteps, v), .default, "regrowthReturnSteps \(v)")
        }
        XCTAssertEqual(guardrails(\.breakReturnMaxQualitySessions, [-1, 1]), .default)
        XCTAssertEqual(guardrails(\.breakReturnMaxQualitySessions, [0, Int.min]), .default)
        // The same when the bad values are handed to the initializer.
        let nan = Double.nan
        XCTAssertEqual(GuardrailLimits(maxWeeklyIncrease: nan, maxFourWeekIncrease: nan, maxLongRunShare: nan,
                                       recoveryWeekMaxRatio: nan, maxConsecutiveBuildWeeks: -1, maxQualitySessionsPerWeek: -1,
                                       maxSingleRunIncrease: nan, spikeWindowDays: -1, marathonMaxLongRunShare: nan,
                                       breakWeekMaxRatio: nan, preBreakWeeks: -1, maxShortBreakWeeks: -1,
                                       breakReturnSteps: [nan], breakReturnMaxQualitySessions: [-1],
                                       regrowthMaxWeeklyRise: nan, regrowthReturnSteps: [nan]), .default)
        let inf = Double.infinity
        XCTAssertEqual(GuardrailLimits(maxWeeklyIncrease: inf, maxFourWeekIncrease: inf, maxLongRunShare: inf,
                                       recoveryWeekMaxRatio: inf, marathonMaxLongRunShare: inf, breakWeekMaxRatio: inf,
                                       regrowthMaxWeeklyRise: inf), .default)
    }

    func testABadGuardrailLimitChecksAsTheDefault() {
        let expected = report(.default)
        XCTAssertTrue(expected.allSatisfy { !$0.violations.isEmpty })
        for (name, path) in doubleFields {
            for v in bad(name) { XCTAssertEqual(report(guardrails(path, v)), expected, "\(name) \(v)") }
        }
        for (name, path) in intFields { XCTAssertEqual(report(guardrails(path, -1)), expected, "\(name) -1") }
    }

    func testInfinityStillSwitchesTheSpikeRuleOff() {
        let off = GuardrailLimits(maxSingleRunIncrease: .infinity)
        XCTAssertEqual(off.maxSingleRunIncrease, .infinity)
        XCTAssertEqual(guardrails(\.maxSingleRunIncrease, .infinity).maxSingleRunIncrease, .infinity)
        let spikes = { (r: [GuardrailReport]) in r.flatMap(\.violations).filter { $0.rule == .singleRunSpike } }
        XCTAssertFalse(spikes(report(.default)).isEmpty)
        XCTAssertTrue(spikes(report(off)).isEmpty)
    }

    func testFiniteGuardrailLimitsAreKeptAsTheyAre() {
        for (name, path) in doubleFields {
            for v in [0, 0.05, 0.5, 1, 10, 1e6] {
                XCTAssertEqual(guardrails(path, v)[keyPath: path], v, "\(name) \(v)")
            }
        }
        for (name, path) in intFields {
            for v in [0, 1, 5, 42] { XCTAssertEqual(guardrails(path, v)[keyPath: path], v, "\(name) \(v)") }
        }
        // Empty lists still switch their ramp or limit off, and a 0 step is kept.
        XCTAssertEqual(GuardrailLimits(breakReturnSteps: []).breakReturnSteps, [])
        XCTAssertEqual(GuardrailLimits(regrowthReturnSteps: []).regrowthReturnSteps, [])
        XCTAssertEqual(GuardrailLimits(breakReturnMaxQualitySessions: []).breakReturnMaxQualitySessions, [])
        XCTAssertEqual(GuardrailLimits(breakReturnSteps: [0, 0.5, 1]).breakReturnSteps, [0, 0.5, 1])
        XCTAssertEqual(GuardrailLimits(breakReturnMaxQualitySessions: [0, 0, 3]).breakReturnMaxQualitySessions, [0, 0, 3])
        XCTAssertEqual(GuardrailLimits(regrowthReturnSteps: [0.5, 2]).regrowthReturnSteps, [0.5, 2])
        // A finite limit still changes what the checker does.
        XCTAssertNotEqual(report(GuardrailLimits(maxWeeklyIncrease: 0.05)), report(.default))
    }

    func testTheGuardrailDefaultsAreUnchanged() {
        let d = GuardrailLimits.default
        XCTAssertEqual(d.measure, .time)
        XCTAssertEqual([d.maxWeeklyIncrease, d.maxFourWeekIncrease, d.maxLongRunShare, d.marathonMaxLongRunShare,
                        d.recoveryWeekMaxRatio, d.maxSingleRunIncrease, d.breakWeekMaxRatio, d.regrowthMaxWeeklyRise],
                       [0.10, 0.30, 0.35, 0.45, 0.80, 0.10, 0.25, 0.20])
        XCTAssertEqual([d.maxConsecutiveBuildWeeks, d.maxQualitySessionsPerWeek, d.spikeWindowDays, d.preBreakWeeks,
                        d.maxShortBreakWeeks], [3, 2, 30, 4, 2])
        XCTAssertEqual(d.breakReturnSteps, [0.70, 0.90, 1.00])
        XCTAssertEqual(d.breakReturnMaxQualitySessions, [0, 1])
        XCTAssertEqual(d.regrowthReturnSteps, [0.65, 0.825, 1.0])
        XCTAssertTrue(d.racesCountAsQuality)
        XCTAssertFalse(d.racesSetSpikeReference)
        XCTAssertEqual(GuardrailLimits(), d)
    }

    // MARK: PainRuleLimits

    typealias PainField = (name: String, path: WritableKeyPath<PainRuleLimits, Int>)
    private let painFields: [PainField] = [
        ("highScore", \.highScore), ("minimumRise", \.minimumRise), ("freezeDays", \.freezeDays),
        ("persistentCount", \.persistentCount),
    ]

    private func pain(_ path: WritableKeyPath<PainRuleLimits, Int>, _ value: Int) -> PainRuleLimits {
        var l = PainRuleLimits()
        l[keyPath: path] = value
        return l
    }

    /// Three check-ins of 5, 7 and 6 on consecutive mornings, a quality
    /// session ahead, evaluated an hour after the last.
    private func evaluate(_ limits: PainRuleLimits) -> PainCheckInOutcome {
        let P = PlanFixture.self
        let start = P.date(week: 0, day: 0, hour: 9)
        let checkIns = [5, 7, 6].enumerated().map { PainCheckIn(date: start.addingTimeInterval(Double($0.offset) * 86_400), score: $0.element) }
        return PainCheckInRule.evaluate(tracksPain: true, checkIns: checkIns,
                                        plan: [P.workout("q", week: 0, day: 5, .quality(.tempo), minutes: 50)],
                                        asOf: start.addingTimeInterval(2 * 86_400 + 3600), lastAppliedCheckIn: nil,
                                        timeZone: P.utc, limits: limits)
    }

    func testANegativePersistentCountNoLongerCrashesThePainRule() throws {
        let expected = evaluate(.default)
        guard case .act(let r) = expected else { return XCTFail("expected an action, got \(expected)") }
        XCTAssertTrue(r.suggestClinician)
        for v in [-1, -3, Int.min] {
            XCTAssertEqual(evaluate(PainRuleLimits(persistentCount: v)), expected, "persistentCount \(v) reads as the default")
            XCTAssertEqual(evaluate(pain(\.persistentCount, v)), expected, "persistentCount \(v) reads as the default")
        }
        // 0 still never prompts a clinician visit.
        guard case .act(let none) = evaluate(PainRuleLimits(persistentCount: 0)) else { return XCTFail("expected an action") }
        XCTAssertFalse(none.suggestClinician)
    }

    func testANegativePainLimitActsAsTheDefault() {
        let expected = evaluate(.default)
        for (name, path) in painFields {
            for v in [-1, Int.min] {
                XCTAssertEqual(evaluate(pain(path, v)), expected, "\(name) \(v)")
            }
        }
        // On main a negative freeze ended before it began, so nothing was done.
        XCTAssertNotEqual(evaluate(PainRuleLimits(freezeDays: -7)), .noAction)
    }

    func testTheEngineCitesAPainLimitWithoutOverflow() throws {
        let expected = try XCTUnwrap(bounded("default") { self.checkIns(.default) })
        XCTAssertTrue(expected.changes.contains { $0.kind == .painVolumeFreeze }, "\(expected.changes.map(\.kind))")
        for (name, path) in painFields {
            let limits = pain(path, Int.min)
            guard let d = bounded("\(name) Int.min", { self.checkIns(limits) }) else { continue }
            XCTAssertEqual(d.outcomes, expected.outcomes, "\(name) Int.min reads as the default")
        }
    }

    func testEveryBadPainLimitFallsBackAndGoodOnesAreKept() {
        for (name, path) in painFields {
            for v in [-1, Int.min] {
                XCTAssertEqual(pain(path, v)[keyPath: path], PainRuleLimits.default[keyPath: path], "\(name) \(v)")
                XCTAssertEqual(pain(path, v), .default, "\(name) \(v): only that limit was bad")
            }
            for v in [0, 1, 5, 99] { XCTAssertEqual(pain(path, v)[keyPath: path], v, "\(name) \(v) is kept") }
        }
        XCTAssertEqual(PainRuleLimits(highScore: -1, minimumRise: -1, freezeDays: -1, persistentCount: -1), .default)
        let d = PainRuleLimits.default
        XCTAssertEqual([d.highScore, d.minimumRise, d.freezeDays, d.persistentCount], [4, 2, 7, 3], "the defaults are unchanged")
        XCTAssertEqual(PainRuleLimits(), d)
        // A finite limit still changes what the rule does.
        guard case .act(let r) = evaluate(PainRuleLimits(freezeDays: 10)) else { return XCTFail("expected an action") }
        XCTAssertEqual(r.freezeEnd.timeIntervalSince(r.freezeStart), 10 * 86_400, accuracy: 1)
    }

    // MARK: PlanFormatting

    func testVolumeAndPercentShowAPlaceholderForAValueTheyCantCount() {
        for v in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(PlanFormatting.volume(v, .distance), "-", "\(v) m")
            XCTAssertEqual(PlanFormatting.volume(v, .distance, units: .imperial), "-", "\(v) m")
        }
        // Not finite, or too large to count as a whole number of minutes or percent.
        for v in [Double.nan, .infinity, -.infinity, 1e300, -1e300] {
            XCTAssertEqual(PlanFormatting.volume(v, .time), "-", "\(v) s")
            XCTAssertEqual(PlanFormatting.percent(v), "-", "\(v)")
        }
        XCTAssertEqual(PlanFormatting.volume(.greatestFiniteMagnitude, .time), "-")
        XCTAssertEqual(PlanFormatting.percent(.greatestFiniteMagnitude), "-")
        // The debrief writes a fraction through `percent`.
        XCTAssertEqual(DebriefFormat.string(DebriefValue(name: .paceTolerance, value: 1e300, unit: .fraction), timeZone: PlanFixture.utc), "-")
    }

    func testFiniteVolumesAndPercentsReadAsBefore() {
        XCTAssertEqual(PlanFormatting.volume(45 * 60, .time), "45 min")
        XCTAssertEqual(PlanFormatting.volume(59 * 60 + 29, .time), "59 min")
        XCTAssertEqual(PlanFormatting.volume(245 * 60, .time), "4 h 05 min")
        XCTAssertEqual(PlanFormatting.volume(0, .time), "0 min")
        XCTAssertEqual(PlanFormatting.volume(12_345, .distance), "12.3 km")
        XCTAssertEqual(PlanFormatting.volume(12_345, .distance, units: .imperial), "7.7 mi")
        XCTAssertEqual(PlanFormatting.volume(1e12, .time), "277777777 h 47 min")
        XCTAssertEqual(PlanFormatting.percent(0.35), "35%")
        XCTAssertEqual(PlanFormatting.percent(0.1), "10%")
        XCTAssertEqual(PlanFormatting.percent(0.123), "12.3%")
        XCTAssertEqual(PlanFormatting.percent(0), "0%")
        XCTAssertEqual(PlanFormatting.percent(-0.2), "-20%")
        XCTAssertEqual(PlanFormatting.percent(1e6), "100000000%")
    }

    func testAHugeFiniteGuardrailLimitNoLongerCrashesThePlanText() throws {
        // A finite rise or ratio is kept; times a volume it overflows to
        // +inf, which the explanations used to round to a whole number.
        let expected = report(.default)
        let ratio = report(GuardrailLimits(recoveryWeekMaxRatio: 1e300))
        XCTAssertEqual(ratio.count, expected.count)
        XCTAssertTrue(ratio.flatMap(\.violations).allSatisfy { !$0.explanation.isEmpty })
        let base = try XCTUnwrap(bounded("default") { self.missedWeek(.default) })
        guard let huge = bounded("regrowthMaxWeeklyRise 1e300", { self.missedWeek(GuardrailLimits(regrowthMaxWeeklyRise: 1e300)) }) else { return }
        XCTAssertEqual(huge.outcomes.count, base.outcomes.count)
        XCTAssertTrue(huge.changes.allSatisfy { !$0.explanation.isEmpty })
    }
}
