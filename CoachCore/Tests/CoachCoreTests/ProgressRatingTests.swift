import XCTest
@testable import CoachCore

// Follow-ups from the #41 reviews (issue #44): the threshold tolerance, range
// wording, the decoupling floor and shared evidence between the two ends of a
// change. Values are synthetic.

private typealias F = ProgressFixture

final class ProgressRatingTests: XCTestCase {
    private let share = ProgressPolarity.towardRange(0.75...0.85)

    private func assess(_ from: Double, _ to: Double, _ polarity: ProgressPolarity,
                        _ noise: NoiseThreshold) -> ChangeAssessment {
        ProgressChange.assess(earlier: from, latest: to, polarity: polarity, noise: noise)
    }

    // MARK: - Threshold tolerance

    func testRangeGainExactlyAtTheThresholdIsNoChangeWhateverTheRounding() {
        let n = NoiseThreshold(absolute: 0.02)
        let up = assess(0.73, 0.75, share, n)
        XCTAssertGreaterThan(up.gain, up.threshold, "the raw sum rounds above the threshold")
        XCTAssertEqual(up.direction, .noChange)
        XCTAssertEqual(assess(0.75, 0.73, share, n).direction, .noChange)
        XCTAssertEqual(assess(0.87, 0.85, share, n).direction, .noChange)
        XCTAssertEqual(assess(0.7299, 0.75, share, n).direction, .improving, "just above still counts")
        XCTAssertEqual(assess(0.75, 0.7299, share, n).direction, .worse)

        let plan = ProgressPolarity.towardRange(0.9...1.1)
        let p = NoiseThreshold(absolute: 0.05)
        let down = assess(1.15, 1.10, plan, p)
        XCTAssertLessThan(down.gain, down.threshold, "the raw sum rounds below the threshold")
        XCTAssertEqual(down.direction, .noChange)
        XCTAssertEqual(assess(1.10, 1.15, plan, p).direction, .noChange)
        XCTAssertEqual(assess(0.85, 0.90, plan, p).direction, .noChange)
        XCTAssertEqual(assess(1.151, 1.10, plan, p).direction, .improving)
        XCTAssertEqual(assess(1.10, 1.151, plan, p).direction, .worse)
    }

    func testRelativeAndAbsoluteThresholdsAtTheBoundary() {
        let pace = NoiseThreshold(relative: 0.02)
        XCTAssertEqual(assess(300, 294, .lowerIsBetter, pace).direction, .noChange, "2% of 300 s/km is 6")
        XCTAssertEqual(assess(300, 306, .lowerIsBetter, pace).direction, .noChange)
        XCTAssertEqual(assess(300, 293.99, .lowerIsBetter, pace).direction, .improving)
        XCTAssertEqual(assess(300, 306.01, .lowerIsBetter, pace).direction, .worse)

        // The tolerance scales with the values, so long race times behave the same.
        let time = NoiseThreshold(relative: 0.01)
        XCTAssertEqual(assess(12_345.6, 12_345.6 * 0.99, .lowerIsBetter, time).direction, .noChange)
        XCTAssertEqual(assess(12_345.6, 12_345.6 * 0.99 - 0.01, .lowerIsBetter, time).direction, .improving)

        let hrv = NoiseThreshold(relative: 0.10)
        XCTAssertEqual(assess(43.3, 43.3 * 1.1, .higherIsBetter, hrv).direction, .noChange)
        XCTAssertEqual(assess(43.3, 43.3 * 1.1 + 0.001, .higherIsBetter, hrv).direction, .improving)

        let bpm = NoiseThreshold(absolute: 1)
        XCTAssertEqual(assess(55.3, 54.3, .lowerIsBetter, bpm).direction, .noChange)
        XCTAssertEqual(assess(54.3, 55.3, .lowerIsBetter, bpm).direction, .noChange)
        XCTAssertEqual(assess(0.1, 1.1, .higherIsBetter, bpm).direction, .noChange)
        XCTAssertEqual(assess(0, 0, .higherIsBetter, NoiseThreshold()).direction, .noChange, "a zero threshold")
        XCTAssertEqual(assess(0, 1e-6, .higherIsBetter, NoiseThreshold()).direction, .improving)
    }

    func testNonFiniteInputsAreNeverRatedAsAChange() {
        let n = NoiseThreshold(absolute: 1, relative: 0.01)
        for (a, b) in [(Double.nan, 300.0), (300, .nan), (.infinity, 300), (300, -.infinity)] {
            XCTAssertEqual(assess(a, b, .lowerIsBetter, n).direction, .noChange, "\(a) to \(b)")
            XCTAssertEqual(assess(a, b, .lowerIsBetterWithFloor(0), n).direction, .noChange, "\(a) to \(b)")
            XCTAssertEqual(assess(a, b, share, n).direction, .noChange, "\(a) to \(b)")
        }
    }

    // MARK: - Range positions and wording

    func testRangePositions() {
        let r = 0.75...0.85
        XCTAssertEqual(RangePosition.of(0.74, in: r), .below)
        XCTAssertEqual(RangePosition.of(0.75, in: r), .within)
        XCTAssertEqual(RangePosition.of(0.85, in: r), .within)
        XCTAssertEqual(RangePosition.of(0.86, in: r), .above)
        let crossing = assess(0.70, 0.90, share, NoiseThreshold(absolute: 0.02))
        XCTAssertEqual(crossing.earlierPosition, .below)
        XCTAssertEqual(crossing.latestPosition, .above)
        XCTAssertTrue(crossing.crossedTarget)
        XCTAssertTrue(assess(0.90, 0.70, share, NoiseThreshold()).crossedTarget)
        XCTAssertFalse(assess(0.70, 0.80, share, NoiseThreshold()).crossedTarget, "into the range is not across it")
        XCTAssertFalse(assess(0.70, 0.72, share, NoiseThreshold()).crossedTarget)
        let plain = assess(300, 290, .lowerIsBetter, NoiseThreshold())
        XCTAssertNil(plain.earlierPosition)
        XCTAssertNil(plain.latestPosition)
        XCTAssertFalse(plain.crossedTarget)
        let missing = assess(.nan, 0.80, share, NoiseThreshold())
        XCTAssertNil(missing.earlierPosition, "NaN is nowhere, not inside the range")
        XCTAssertEqual(missing.latestPosition, .within)
        XCTAssertTrue(ChangeAssessment.distance(.nan, from: 0.75...0.85).isNaN)
    }

    private func stillText(_ a: ChangeAssessment, _ id: ProgressMetricID = .easyShare,
                           _ unit: ProgressUnit = .ratio) -> String {
        switch a.direction {
        case .improving:
            return ImprovedMetric(id: id, unit: unit,
                                  change: ProgressChange(weeks: 4, earlier: nil, latest: nil, outcome: .measured(a))).plainText
        case .worse: return StillReason.metric(id, unit, .worse(a)).plainText(windowWeeks: 4)
        case .noChange: return StillReason.metric(id, unit, .withinNoise(a)).plainText(windowWeeks: 4)
        case .notRated: return "not rated"
        }
    }

    func testBothValuesInsideTheRangeStayedWithinTheTarget() {
        let n = NoiseThreshold(absolute: 0.02)
        XCTAssertEqual(stillText(assess(0.78, 0.82, share, n)),
                       "Easy-intensity share stayed within the 75.0-85.0% target over 4 weeks (78.0% then, 82.0% now), "
                       + "so it counts as no change.")
        XCTAssertEqual(stillText(assess(0.85, 0.75, share, n)),
                       "Easy-intensity share stayed within the 75.0-85.0% target over 4 weeks (85.0% then, 75.0% now), "
                       + "so it counts as no change.", "the bounds are inside")
        XCTAssertEqual(stillText(assess(0.80, 0.86, share, n)),
                       "Easy-intensity share moved from 80.0% to 86.0% over 4 weeks; its distance from the 75.0-85.0% "
                       + "target changed by 1.0 points, within the 2.0 points noise threshold, so it counts as no change.",
                       "leaving the range by less than the threshold keeps the distance wording")
    }

    func testCrossingAtTheSameDistanceSaysItCrossed() {
        let n = NoiseThreshold(absolute: 0.02)
        XCTAssertEqual(stillText(assess(0.74, 0.86, share, n)),
                       "Easy-intensity share crossed the 75.0-85.0% target from below to above over 4 weeks "
                       + "(74.0% then, 86.0% now), but its distance from the target changed by 0.0 points, "
                       + "within the 2.0 points noise threshold, so it counts as no change.")
    }

    // MARK: - Decoupling floor

    func testNegativeDecouplingRatesAsNoDrift() {
        let floor = ProgressPolarity.lowerIsBetterWithFloor(0)
        let n = NoiseThreshold(absolute: 1)
        let artefacts = assess(-4, -1, floor, n)
        XCTAssertEqual(artefacts.direction, .noChange, "both below 0 rate as 0")
        XCTAssertEqual(artefacts.gain, 0)
        XCTAssertEqual(artefacts.delta, 3, "the delta stays as measured")
        XCTAssertEqual(artefacts.floor, 0)
        XCTAssertTrue(artefacts.belowFloor)
        XCTAssertEqual(assess(0, -3, floor, n).direction, .noChange, "more negative is not better than none")
        XCTAssertEqual(assess(-3, 0, floor, n).direction, .noChange, "and not worse either")
        let toNegative = assess(2, -1, floor, n)
        XCTAssertEqual(toNegative.direction, .improving)
        XCTAssertEqual(toNegative.gain, 2, "rated down to 0, not to -1")
        let fromNegative = assess(-2, 3, floor, n)
        XCTAssertEqual(fromNegative.direction, .worse)
        XCTAssertEqual(fromNegative.gain, -3)
        XCTAssertEqual(assess(-2, 1, floor, n).direction, .noChange, "1 point above the floor is at the threshold")
        let positive = assess(5, 3, floor, n)
        XCTAssertEqual(positive.direction, .improving)
        XCTAssertEqual(positive.gain, 2)
        XCTAssertFalse(positive.belowFloor)
        XCTAssertFalse(assess(0, 0, floor, n).belowFloor, "the floor itself is not below it")

        let noFloor = assess(-4, -1, .lowerIsBetterWithFloor(.nan), n)
        XCTAssertNil(noFloor.floor, "a floor that isn't finite is ignored")
        XCTAssertEqual(noFloor.direction, .worse)
        XCTAssertNil(assess(300, 290, .lowerIsBetter, n).floor)
    }

    func testDecouplingFloorWording() {
        let floor = ProgressPolarity.lowerIsBetterWithFloor(0)
        let n = NoiseThreshold(absolute: 1)
        let id = ProgressMetricID.longRunDecoupling
        XCTAssertEqual(stillText(assess(-4, -1, floor, n), id, .percent),
                       "Heart-rate drift on long runs went from -4.0% to -1.0% over 4 weeks; values below 0.0% rate as "
                       + "0.0%, so the rated change is 0.0 points, within the 1.0 points noise threshold, so it counts as no change.")
        XCTAssertEqual(stillText(assess(2, -1, floor, n), id, .percent),
                       "Heart-rate drift on long runs improved by 2.0 points over 4 weeks (2.0% then, -1.0% now; "
                       + "values below 0.0% rate as 0.0%).")
        XCTAssertEqual(stillText(assess(-2, 3, floor, n), id, .percent),
                       "Heart-rate drift on long runs is 3.0 points worse than 4 weeks ago (-2.0% then, 3.0% now; "
                       + "values below 0.0% rate as 0.0%).")
        XCTAssertEqual(stillText(assess(5, 3, floor, n), id, .percent),
                       "Heart-rate drift on long runs improved by 2.0 points over 4 weeks.")
        XCTAssertEqual(stillText(assess(5, 4.5, floor, n), id, .percent),
                       "Heart-rate drift on long runs changed by 0.5 points over 4 weeks, within the 1.0 points noise "
                       + "threshold, so it counts as no change.")
    }

    func testDashboardRatesDecouplingWithAFloorOfZero() throws {
        let d = F.dashboard(F.trend(12, start: 3.0, rate: 0), asOfWeek: 12)
        XCTAssertEqual(try XCTUnwrap(d.metric(.longRunDecoupling)).polarity, .lowerIsBetterWithFloor(0))
        XCTAssertEqual(try XCTUnwrap(d.metric(.easyPace)).polarity, .lowerIsBetter)
    }

    // MARK: - Options

    func testFloorPolarityForCadenceMustBeFinite() {
        var o = F.options(asOf: F.asOf(week: 12))
        o.cadencePolarity = .lowerIsBetterWithFloor(0)
        XCTAssertTrue(o.isValid)
        o.cadencePolarity = .lowerIsBetterWithFloor(.nan)
        XCTAssertFalse(o.isValid)
        o.cadencePolarity = .lowerIsBetterWithFloor(.infinity)
        XCTAssertFalse(o.isValid)
    }

    func testInitWithBaselineOverwritesItsRecentDays() {
        var b = BaselineOptions(asOf: F.asOf(week: 12), timeZone: F.utc)
        b.recentDays = 42
        XCTAssertEqual(ProgressOptions(baseline: b).baseline.recentDays, 28)
        XCTAssertEqual(ProgressOptions(baseline: b, trailingWindowDays: b.recentDays).baseline.recentDays, 42)
    }

    // MARK: - Shared evidence

    private func point(_ week: Int, _ value: Double, _ ids: [String]) -> ProgressPoint {
        ProgressPoint(asOf: F.asOf(week: week), reading: .value(value), evidence: ProgressEvidence(activityIDs: ids))
    }

    func testSharedEvidenceCountsTheRunsBothEndsCite() throws {
        let change = ProgressChange(weeks: 4, earlier: point(8, 1300, ["a", "b", "c"]),
                                    latest: point(12, 1280, ["d", "b", "c"]),
                                    outcome: .measured(assess(1300, 1280, .lowerIsBetter, NoiseThreshold(relative: 0.01))))
        let five = ProgressMetricID.predictedTime(meters: Distance.fiveK)
        let s = try XCTUnwrap(SharedEvidence.of(change, id: five, lookbackDays: 120))
        XCTAssertEqual(s.sharedActivityIDs, ["b", "c"])
        XCTAssertEqual(s.totalActivityCount, 4)
        XCTAssertEqual(s.lookbackDays, 120)
        XCTAssertEqual(s.plainText, "Predicted 5K time: each prediction looks back 120 days, so the values 4 weeks "
                       + "apart share 2 of the 4 runs they draw on; the change comes from the other 2.")

        let other = try XCTUnwrap(SharedEvidence.of(change, id: .easyPace, lookbackDays: 120))
        XCTAssertNil(other.lookbackDays, "the lookback clause is for predicted times only")
        XCTAssertEqual(other.plainText, "Easy pace at a fixed heart rate: the values 4 weeks apart share 2 of the 4 "
                       + "runs they draw on; the change comes from the other 2.")

        let same = ProgressChange(weeks: 1, earlier: point(11, 1300, ["a"]), latest: point(12, 1299, ["a"]),
                                  outcome: .measured(assess(1300, 1299, .lowerIsBetter, NoiseThreshold())))
        XCTAssertEqual(try XCTUnwrap(SharedEvidence.of(same, id: five, lookbackDays: 90)).plainText,
                       "Predicted 5K time: each prediction looks back 90 days, so the values 1 week apart draw on the same run.")
    }

    func testNoSharedEvidenceWithoutOverlapOrAMeasuredChange() {
        let five = ProgressMetricID.predictedTime(meters: Distance.fiveK)
        let apart = ProgressChange(weeks: 4, earlier: point(8, 1300, ["a"]), latest: point(12, 1280, ["b"]),
                                   outcome: .measured(assess(1300, 1280, .lowerIsBetter, NoiseThreshold())))
        XCTAssertNil(SharedEvidence.of(apart, id: five, lookbackDays: 120))
        let missing = ProgressChange(weeks: 4, earlier: point(8, 1300, ["a"]),
                                     latest: ProgressPoint(asOf: F.asOf(week: 12), reading: .missing(.baseline(.noRuns))),
                                     outcome: .unavailable(.latestMissing(.baseline(.noRuns))))
        XCTAssertNil(SharedEvidence.of(missing, id: five, lookbackDays: 120))
        let empty = ProgressChange(weeks: 4, earlier: nil, latest: nil, outcome: .unavailable(.notInSeries))
        XCTAssertNil(SharedEvidence.of(empty, id: five, lookbackDays: 120))
    }

    /// With the default 120-day lookback, predictions 4 weeks apart on a flat
    /// history share best efforts, and the summary says so; easy pace uses a
    /// 28-day window, so its ends share no run.
    func testFlatHistorySummaryNotesSharedPredictionEvidence() throws {
        let health = F.health(days: 400, before: F.asOf(week: 40))
        let d = F.dashboard(F.trend(12, start: 3.0, rate: 0), asOfWeek: 12, health: health)
        XCTAssertEqual(d.predictionLookbackDays, BlendedPredictor.defaultLookbackDays)
        let s = d.summary()
        let predicted = s.sharedEvidence.filter { if case .predictedTime = $0.id { return true }; return false }
        XCTAssertFalse(predicted.isEmpty, "predictions 4 weeks apart share best efforts")
        XCTAssertFalse(s.sharedEvidence.contains { $0.id == .easyPace })
        for e in s.sharedEvidence {
            XCTAssertEqual(e.weeks, 4)
            XCTAssertFalse(e.sharedActivityIDs.isEmpty)
            XCTAssertLessThanOrEqual(e.sharedActivityIDs.count, e.totalActivityCount)
            let c = try XCTUnwrap(d.metric(e.id)).change(overWeeks: 4)
            let earlier = Set(c.earlier?.evidence.activityIDs ?? [])
            XCTAssertTrue(e.sharedActivityIDs.allSatisfy(earlier.contains))
            XCTAssertTrue(s.plainText.contains(e.plainText))
        }
        let first = try XCTUnwrap(predicted.first)
        XCTAssertEqual(first.lookbackDays, BlendedPredictor.defaultLookbackDays)
        XCTAssertTrue(first.plainText.contains("each prediction looks back \(BlendedPredictor.defaultLookbackDays) days"))
        XCTAssertEqual(Array(s.plainText.suffix(s.sharedEvidence.count)), s.sharedEvidence.map(\.plainText),
                       "the notes come after the verdict")
    }

    func testInvalidOptionsHaveNoSharedEvidence() {
        let s = ProgressBuilder.build(activities: [], options: F.options(asOf: F.asOf(week: 12)) { $0.seriesWeeks = 0 })
            .summary()
        XCTAssertEqual(s.sharedEvidence, [])
        XCTAssertEqual(s.plainText.count, 2)
    }
}
