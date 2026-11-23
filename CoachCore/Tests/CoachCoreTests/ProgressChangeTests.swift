import XCTest
@testable import CoachCore

// Direction, noise threshold and change-span rules for F13. Values are synthetic.

final class ProgressChangeTests: XCTestCase {
    private let noise = NoiseThreshold(absolute: 1)

    func testLowerIsBetterSign() {
        XCTAssertEqual(ProgressChange.assess(earlier: 300, latest: 290, polarity: .lowerIsBetter, noise: noise).direction,
                       .improving)
        XCTAssertEqual(ProgressChange.assess(earlier: 290, latest: 300, polarity: .lowerIsBetter, noise: noise).direction,
                       .worse)
    }

    func testHigherIsBetterSign() {
        XCTAssertEqual(ProgressChange.assess(earlier: 50, latest: 60, polarity: .higherIsBetter, noise: noise).direction,
                       .improving)
        XCTAssertEqual(ProgressChange.assess(earlier: 60, latest: 50, polarity: .higherIsBetter, noise: noise).direction,
                       .worse)
    }

    func testChangeAtTheThresholdIsNoChangeAndJustAboveCounts() {
        let at = ProgressChange.assess(earlier: 50, latest: 51, polarity: .higherIsBetter, noise: noise)
        XCTAssertEqual(at.direction, .noChange)
        XCTAssertEqual(at.delta, 1)
        XCTAssertEqual(at.threshold, 1)
        XCTAssertEqual(ProgressChange.assess(earlier: 50, latest: 51.001, polarity: .higherIsBetter, noise: noise).direction,
                       .improving)
        XCTAssertEqual(ProgressChange.assess(earlier: 50, latest: 49.5, polarity: .lowerIsBetter, noise: noise).direction,
                       .noChange)
    }

    func testRelativeThresholdUsesTheEarlierValueAndTheLargerOfTheTwo() {
        let n = NoiseThreshold(absolute: 2, relative: 0.02)
        XCTAssertEqual(n.threshold(from: 300), 6)
        XCTAssertEqual(n.threshold(from: 50), 2)
        XCTAssertEqual(n.threshold(from: -300), 6)
        XCTAssertEqual(ProgressChange.assess(earlier: 300, latest: 295, polarity: .lowerIsBetter, noise: n).direction,
                       .noChange)
        XCTAssertEqual(ProgressChange.assess(earlier: 300, latest: 293, polarity: .lowerIsBetter, noise: n).direction,
                       .improving)
    }

    func testTowardRange() {
        let p = ProgressPolarity.towardRange(0.75...0.85)
        let n = NoiseThreshold(absolute: 0.02)
        XCTAssertEqual(ProgressChange.assess(earlier: 0.60, latest: 0.70, polarity: p, noise: n).direction, .improving)
        XCTAssertEqual(ProgressChange.assess(earlier: 0.95, latest: 0.86, polarity: p, noise: n).direction, .improving)
        XCTAssertEqual(ProgressChange.assess(earlier: 0.76, latest: 0.84, polarity: p, noise: n).direction, .noChange,
                       "moving inside the range is no change")
        XCTAssertEqual(ProgressChange.assess(earlier: 0.80, latest: 0.60, polarity: p, noise: n).direction, .worse)
        XCTAssertEqual(ProgressChange.assess(earlier: 0.70, latest: 0.90, polarity: p, noise: n).direction, .noChange,
                       "5 points short to 5 points over is the same distance from the range")
        XCTAssertEqual(ProgressChange.assess(earlier: 0.74, latest: 0.75, polarity: p, noise: n).direction, .noChange)
        let crossing = ProgressChange.assess(earlier: 0.70, latest: 0.95, polarity: p, noise: n)
        XCTAssertEqual(crossing.delta, 0.25, accuracy: 1e-12)
        XCTAssertEqual(crossing.gain, -0.05, accuracy: 1e-12, "rated by distance from the range, not the raw change")
        XCTAssertEqual(crossing.target, 0.75...0.85)
        XCTAssertEqual(crossing.direction, .worse)
    }

    func testInformationalIsNeverRated() {
        let a = ProgressChange.assess(earlier: 100, latest: 200, polarity: .informational, noise: noise)
        XCTAssertEqual(a.direction, .notRated)
        XCTAssertEqual(a.delta, 100)
        XCTAssertEqual(a.gain, 0)
        XCTAssertNil(a.target)
        let lower = ProgressChange.assess(earlier: 300, latest: 290, polarity: .lowerIsBetter, noise: noise)
        XCTAssertEqual(lower.gain, 10)
        XCTAssertEqual(lower.earlier, 300)
        XCTAssertEqual(lower.latest, 290)
    }

    func testNonFiniteValueBecomesInvalidInput() {
        for bad in [Double.nan, .infinity, -.infinity] {
            let p = ProgressPoint(asOf: Date(), reading: .value(bad))
            XCTAssertNil(p.value)
            XCTAssertEqual(p.gap, .insufficient(InsufficientData(.invalidInput)))
        }
    }

    private func metric(_ values: [Double?]) -> ProgressMetric {
        let base = Date(timeIntervalSince1970: 0)
        let series = values.enumerated().map { i, v in
            ProgressPoint(asOf: base.addingTimeInterval(Double(i) * 7 * 86_400),
                          reading: v.map { .value($0) } ?? .missing(.baseline(.noRuns)),
                          evidence: ProgressEvidence(activityIDs: ["r\(i)"]))
        }
        return ProgressMetric(id: .easyPace, unit: .secondsPerKilometer, polarity: .lowerIsBetter,
                              noise: NoiseThreshold(absolute: 1), series: series, changeWeeks: [4, 12])
    }

    func testChangeComparesThePointThatManyWeeksBackAndCitesBoth() {
        let m = metric([310, 309, 308, 307, 306, 300])
        let c = m.change(overWeeks: 4)
        XCTAssertEqual(c.earlier?.value, 309)
        XCTAssertEqual(c.latest?.value, 300)
        XCTAssertEqual(c.delta, -9)
        XCTAssertEqual(c.direction, .improving)
        XCTAssertEqual(c.evidence.activityIDs, ["r5", "r1"])
        XCTAssertEqual(m.changes.map(\.weeks), [4, 12])
        XCTAssertEqual(m.changes[1].outcome, .unavailable(.notInSeries))
    }

    func testChangeSpansOutOfRangeAndMissingEnds() {
        let m = metric([nil, 300, 301, 302, 303, nil])
        XCTAssertEqual(m.change(overWeeks: 0).outcome, .unavailable(.notInSeries))
        XCTAssertEqual(m.change(overWeeks: -1).outcome, .unavailable(.notInSeries))
        XCTAssertEqual(m.change(overWeeks: 6).outcome, .unavailable(.notInSeries))
        XCTAssertEqual(m.change(overWeeks: 4).outcome, .unavailable(.latestMissing(.baseline(.noRuns))))
        let m2 = metric([nil, 300, 301, 302, 303, 304])
        XCTAssertEqual(m2.change(overWeeks: 5).outcome, .unavailable(.earlierMissing(.baseline(.noRuns))))
        let empty = ProgressMetric(id: .hrv, unit: .milliseconds, polarity: .higherIsBetter, noise: .init(),
                                   series: [], changeWeeks: [4])
        XCTAssertNil(empty.latest)
        XCTAssertEqual(empty.change(overWeeks: 4).outcome, .unavailable(.notInSeries))
    }

    func testEvidenceMergeKeepsOrderWithoutRepeats() {
        let d1 = Date(timeIntervalSince1970: 86_400), d0 = Date(timeIntervalSince1970: 0)
        let a = ProgressEvidence(activityIDs: ["a", "b"], days: [d1], plannedWorkoutIDs: ["p1"])
        let b = ProgressEvidence(activityIDs: ["b", "c"], days: [d0, d1], plannedWorkoutIDs: ["p1", "p2"])
        let m = a.merged(with: b)
        XCTAssertEqual(m.activityIDs, ["a", "b", "c"])
        XCTAssertEqual(m.days, [d0, d1])
        XCTAssertEqual(m.plannedWorkoutIDs, ["p1", "p2"])
        XCTAssertTrue(ProgressEvidence.none.isEmpty)
    }

    func testMetricNames() {
        XCTAssertEqual(ProgressMetricID.bestEffort(meters: Distance.fiveK).name, "Best 5K effort")
        XCTAssertEqual(ProgressMetricID.predictedTime(meters: Distance.halfMarathon).name, "Predicted half marathon time")
        XCTAssertEqual(ProgressMetricID.bestEffort(meters: 3000).name, "Best 3.0 km effort")
        XCTAssertEqual(ProgressMetricID.bestEffort(meters: .nan).name, "Best unknown distance effort")
    }
}
