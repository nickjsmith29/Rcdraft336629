import XCTest
@testable import CoachCore

// #138: a spike violation's `measured` is the worse of the run's time
// (seconds) and distance (meters) under one key, so two reports can give it
// in different units. The give-back's "no worse" check (#131) compares
// `measured / allowed`, which is the same in either unit. Synthetic numbers
// only; the spike limit is a heuristic (SPEC 3.5 rule 1).
final class SpikeUnitComparisonTests: XCTestCase {
    private let week = Date(timeIntervalSince1970: 0)

    private func spike(_ measured: Double, _ allowed: Double, _ unit: GuardrailViolation.Unit,
                       rule: GuardrailRule = .singleRunSpike) -> GuardrailViolation {
        GuardrailViolation(rule: rule, weekStart: week, measured: measured, allowed: allowed, unit: unit,
                           explanation: "", workoutID: "r1")
    }

    private func values(_ vs: [GuardrailViolation]) -> [String: Double?] {
        Dictionary(vs.map { (GuardrailRepair.key($0), Optional(GuardrailRepair.comparable($0))) }, uniquingKeysWith: { a, _ in a })
    }

    /// The worse measure flips from time to distance and the run got better:
    /// 2000 s over 1000 s allowed (2.0x) becomes 12000 m over 10000 m (1.2x).
    /// Compared raw, 12000 > 2000 reads as worse.
    func testFlipFromTimeToDistanceThatImprovesIsNoWorse() {
        let old = values([spike(2000, 1000, .seconds)])
        let new = values([spike(12000, 10000, .meters)])
        XCTAssertEqual(new.keys, old.keys, "one key for both units")
        XCTAssertTrue(GuardrailRepair.noWorse(new, than: old))
    }

    /// The other way: 12000 m over 10000 m (1.2x) becomes 1500 s over 1000 s
    /// (1.5x), worse. Compared raw, 1500 < 12000 reads as no worse.
    func testFlipFromDistanceToTimeThatWorsensIsWorse() {
        let old = values([spike(12000, 10000, .meters)])
        let new = values([spike(1500, 1000, .seconds)])
        XCTAssertFalse(GuardrailRepair.noWorse(new, than: old))
    }

    func testSameUnitAndSameRatioIsNoWorse() {
        XCTAssertTrue(GuardrailRepair.noWorse(values([spike(1500, 1000, .seconds)]), than: values([spike(1500, 1000, .seconds)])))
        XCTAssertFalse(GuardrailRepair.noWorse(values([spike(1600, 1000, .seconds)]), than: values([spike(1500, 1000, .seconds)])))
    }

    func testOtherRulesAreComparedAsMeasured() {
        let v = spike(5000, 4000, .seconds, rule: .weeklyIncrease)
        XCTAssertEqual(GuardrailRepair.comparable(v), 5000)
    }

    func testEdgesCountAsMoreOrEqual() {
        // Allowed 0 (never emitted by the checker) has no ratio, so it counts
        // as more, even against itself, and growth can't hide behind it.
        let stuck = values([spike(600, 0, .seconds)])
        XCTAssertTrue(GuardrailRepair.comparable(spike(600, 0, .seconds)).isNaN)
        XCTAssertFalse(GuardrailRepair.noWorse(stuck, than: stuck))
        XCTAssertFalse(GuardrailRepair.noWorse(values([spike(900, 0, .seconds)]), than: stuck))
        XCTAssertTrue(GuardrailRepair.comparable(spike(600, .infinity, .seconds)).isNaN)
        XCTAssertFalse(GuardrailRepair.noWorse(values([spike(.nan, 1000, .seconds)]), than: values([spike(1500, 1000, .seconds)])))
        XCTAssertFalse(GuardrailRepair.noWorse(values([spike(1500, .nan, .seconds)]), than: values([spike(1500, 1000, .seconds)])))
        // A violation the old report lacked is new, so worse.
        XCTAssertFalse(GuardrailRepair.noWorse(values([spike(1500, 1000, .seconds)]), than: [:]))
    }
}
