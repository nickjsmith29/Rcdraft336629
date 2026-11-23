import XCTest
@testable import CoachCore

// The F13 acceptance check on synthetic 4-week windows: at least one improving
// metric, or a plain statement that nothing moved and why.

private typealias F = ProgressFixture

private func improvedIDs(_ s: ProgressSummary) -> [ProgressMetricID] {
    if case .improving(let m) = s.verdict { return m.map(\.id) }
    return []
}

private func reasons(_ s: ProgressSummary) -> [StillReason] {
    if case .nothingMoved(let r) = s.verdict { return r }
    return []
}

private func kind(_ s: ProgressSummary, _ id: ProgressMetricID) -> StillKind? {
    for r in reasons(s) { if case .metric(id, _, let k) = r { return k } }
    return nil
}

final class ProgressSummaryTests: XCTestCase {
    private let flatHealth = F.health(days: 400, before: F.asOf(week: 40))

    func testImprovingWindowNamesTheImprovedMetrics() throws {
        let s = F.dashboard(F.trend(12, start: 2.9, rate: 0.01), asOfWeek: 12, health: flatHealth).summary()
        let ids = improvedIDs(s)
        XCTAssertTrue(ids.contains(.easyPace))
        XCTAssertTrue(ids.contains(.bestEffort(meters: Distance.fiveK)))
        XCTAssertTrue(ids.contains(.predictedTime(meters: Distance.fiveK)))
        XCTAssertFalse(ids.contains(.restingHeartRate), "flat readings are not progress")
        XCTAssertFalse(ids.contains(.weeklyLoad), "informational metrics never count")
        XCTAssertEqual(s.windowWeeks, 4)
        XCTAssertEqual(s.windowEnd, F.asOf(week: 12))
        XCTAssertEqual(s.windowStart, F.asOf(week: 8))
        XCTAssertEqual(s.runsInWindow.count, 15, "week 8's Thursday to Sunday and weeks 9 to 11")
        guard case .improving(let metrics) = s.verdict else { return XCTFail() }
        for m in metrics {
            XCTAssertEqual(m.change.direction, .improving)
            XCTAssertFalse(m.change.evidence.isEmpty, "every improvement cites its runs or days")
        }
        let easy = try XCTUnwrap(metrics.first { $0.id == .easyPace })
        XCTAssertTrue(easy.plainText.hasPrefix("Easy pace at a fixed heart rate improved by "))
        XCTAssertTrue(easy.plainText.hasSuffix(" s/km over 4 weeks."))
        XCTAssertEqual(s.plainText.count, metrics.count + s.sharedEvidence.count)
    }

    func testFlatWindowSaysNothingMovedAndWhy() throws {
        let s = F.dashboard(F.trend(12, start: 3.0, rate: 0), asOfWeek: 12, health: flatHealth).summary()
        XCTAssertTrue(improvedIDs(s).isEmpty)
        let r = reasons(s)
        XCTAssertFalse(r.isEmpty)
        XCTAssertFalse(r.contains(.noRunsInWindow))
        for id: ProgressMetricID in [.easyPace, .longRunDecoupling, .restingHeartRate, .hrv,
                                     .bestEffort(meters: Distance.fiveK), .predictedTime(meters: Distance.tenK)] {
            guard case .withinNoise(let a)? = kind(s, id) else {
                return XCTFail("\(id) should be within noise, got \(String(describing: kind(s, id)))")
            }
            XCTAssertLessThanOrEqual(abs(a.gain), a.threshold)
        }
        XCTAssertFalse(r.contains { if case .metric(_, _, .worse) = $0 { return true }; return false })
        // No LTHR, so easy share says what it needs.
        XCTAssertEqual(kind(s, .easyShare), .notEnoughData(.latestMissing(.baseline(.needsLTHR))))
        let text = s.plainText
        XCTAssertEqual(text.first, "Nothing moved in the last 4 weeks.")
        XCTAssertTrue(text.contains { $0.hasPrefix("Easy pace at a fixed heart rate changed by 0.0 s/km over 4 weeks, within the ") })
        XCTAssertTrue(text.contains("Easy-intensity share: not enough data now (heart-rate zones need a race or time trial first)."))
        XCTAssertTrue(text.allSatisfy { !$0.isEmpty })
    }

    func testWorseningWindowSaysWhatGotWorse() throws {
        let health = F.health(days: 160, before: F.asOf(week: 12), resting: { 55 - 0.1 * Double($0) })
        let s = F.dashboard(F.trend(12, start: 3.2, rate: -0.01), asOfWeek: 12, health: health).summary()
        XCTAssertTrue(improvedIDs(s).isEmpty)
        guard case .worse(let d)? = kind(s, .easyPace) else { return XCTFail("easy pace should be worse") }
        XCTAssertGreaterThan(d.delta, 0, "slower pace is more s/km")
        guard case .worse(let rhr)? = kind(s, .restingHeartRate) else { return XCTFail("resting HR should be worse") }
        XCTAssertEqual(rhr.delta, 2.8, accuracy: 1e-9)
        XCTAssertTrue(s.plainText.contains("Resting heart rate (7-day average) is 2.8 bpm worse than 4 weeks ago."))
    }

    func testOneImprovingMetricIsEnough() throws {
        // Pace, efforts and readings flat; the long-run drift shrinks from 12 bpm to 1.
        let weeks = (0..<12).map { ProgressFixture.Week.easy(3.0, drift: 12 - Double($0)) }
        let d = F.dashboard(weeks, asOfWeek: 12, health: flatHealth)
        XCTAssertEqual(improvedIDs(d.summary()), [.longRunDecoupling])
        let c = try XCTUnwrap(d.metric(.longRunDecoupling)).change(overWeeks: 4)
        XCTAssertEqual(c.latest?.evidence.activityIDs, ["w8-sun", "w9-sun", "w10-sun", "w11-sun"])
    }

    func testSparseHistorySaysThereIsNotEnoughData() throws {
        // One week of runs, no earlier history and no readings.
        let s = ProgressBuilder.build(activities: F.history([.easy(3.0)], firstWeek: 11),
                                      options: F.options(asOf: F.asOf(week: 12))).summary()
        XCTAssertTrue(improvedIDs(s).isEmpty)
        let r = reasons(s)
        XCTAssertFalse(r.isEmpty)
        XCTAssertTrue(r.allSatisfy { if case .metric(_, _, .notEnoughData) = $0 { return true }; return false })
        XCTAssertEqual(kind(s, .easyPace), .notEnoughData(.earlierMissing(.baseline(.noRuns))))
        XCTAssertTrue(s.plainText.contains("Easy pace at a fixed heart rate: not enough data 4 weeks ago (no runs)."))

        // Two runs in the window: too few for a typical easy pace.
        let two = Array(F.history([.easy(3.0)], firstWeek: 11).prefix(2))
        let s2 = ProgressBuilder.build(activities: two, options: F.options(asOf: F.asOf(week: 12))).summary()
        guard case .notEnoughData(.latestMissing(.insufficient(let why)))? = kind(s2, .easyPace) else {
            return XCTFail("expected latest missing")
        }
        XCTAssertEqual(why.reason, .tooFewRuns(have: 2, need: 3))
        XCTAssertTrue(s2.plainText.contains("Easy pace at a fixed heart rate: not enough data now (2 usable runs of the 3 needed)."))
    }

    func testWindowWithoutRunsSaysSoFirst() throws {
        let weeks = F.trend(8, start: 3.0, rate: 0) + Array(repeating: ProgressFixture.Week.off, count: 4)
        let s = F.dashboard(weeks, asOfWeek: 12).summary()
        XCTAssertTrue(s.runsInWindow.isEmpty)
        XCTAssertEqual(reasons(s).first, .noRunsInWindow)
        XCTAssertEqual(s.plainText[1], "No runs in the last 4 weeks, so there is no training to compare.")

        let empty = ProgressBuilder.build(activities: [], options: F.options(asOf: F.asOf(week: 12))).summary()
        XCTAssertEqual(reasons(empty).first, .noRunsInWindow)
        XCTAssertGreaterThan(reasons(empty).count, 1)
    }

    func testOtherWindowLengths() throws {
        let d = F.dashboard(F.trend(16, start: 2.9, rate: 0.01), asOfWeek: 16)
        XCTAssertTrue(improvedIDs(d.summary(windowWeeks: 12)).contains(.easyPace))
        XCTAssertEqual(d.summary(windowWeeks: 12).windowStart, F.asOf(week: 4))
        let tooLong = d.summary(windowWeeks: 13)
        XCTAssertEqual(kind(tooLong, .easyPace), .notEnoughData(.notInSeries))
        XCTAssertTrue(tooLong.plainText.contains("Easy pace at a fixed heart rate: the dashboard's series doesn't cover 13 weeks."))
        let zero = d.summary(windowWeeks: 0)
        XCTAssertEqual(zero.windowStart, zero.windowEnd)
        XCTAssertEqual(kind(zero, .easyPace), .notEnoughData(.notInSeries))
    }

    private func still(_ id: ProgressMetricID, _ range: ClosedRange<Double>, _ noise: Double,
                       _ from: Double, _ to: Double) -> String {
        let a = ProgressChange.assess(earlier: from, latest: to, polarity: .towardRange(range),
                                      noise: NoiseThreshold(absolute: noise))
        switch a.direction {
        case .improving:
            return ImprovedMetric(id: id, unit: .ratio,
                                  change: ProgressChange(weeks: 4, earlier: nil, latest: nil, outcome: .measured(a))).plainText
        case .worse: return StillReason.metric(id, .ratio, .worse(a)).plainText(windowWeeks: 4)
        case .noChange: return StillReason.metric(id, .ratio, .withinNoise(a)).plainText(windowWeeks: 4)
        case .notRated: return "not rated"
        }
    }

    /// A target-range metric is worded by its distance from the range, so a
    /// value that crosses the range reads truthfully in both directions, and
    /// the sentence says it crossed (#44).
    func testRangeMetricsCrossingTheTargetReadTruthfully() {
        let share = (ProgressMetricID.easyShare, 0.75...0.85, 0.02)
        XCTAssertEqual(still(share.0, share.1, share.2, 0.70, 0.90),
                       "Easy-intensity share crossed the 75.0-85.0% target from below to above over 4 weeks "
                       + "(70.0% then, 90.0% now), but its distance from the target changed by 0.0 points, "
                       + "within the 2.0 points noise threshold, so it counts as no change.")
        XCTAssertEqual(still(share.0, share.1, share.2, 0.90, 0.70),
                       "Easy-intensity share crossed the 75.0-85.0% target from above to below over 4 weeks "
                       + "(90.0% then, 70.0% now), but its distance from the target changed by 0.0 points, "
                       + "within the 2.0 points noise threshold, so it counts as no change.")
        XCTAssertEqual(still(share.0, share.1, share.2, 0.95, 0.70),
                       "Easy-intensity share moved from 95.0% to 70.0%, crossing the 75.0-85.0% target from above to below, "
                       + "5.0 points closer to it, over 4 weeks.")
        XCTAssertEqual(still(share.0, share.1, share.2, 0.70, 0.95),
                       "Easy-intensity share crossed the 75.0-85.0% target from below to above and is 5.0 points "
                       + "further from it than 4 weeks ago (70.0% then, 95.0% now).")
        XCTAssertEqual(still(share.0, share.1, share.2, 0.60, 0.70),
                       "Easy-intensity share moved from 60.0% to 70.0%, 10.0 points closer to the 75.0-85.0% target, over 4 weeks.",
                       "no crossing, no crossing clause")
        XCTAssertEqual(still(share.0, share.1, share.2, 0.80, 0.60),
                       "Easy-intensity share is 15.0 points further from the 75.0-85.0% target than 4 weeks ago (80.0% then, 60.0% now).")
        XCTAssertEqual(still(share.0, share.1, share.2, 0.60, 0.615),
                       "Easy-intensity share moved from 60.0% to 61.5% over 4 weeks; its distance from the 75.0-85.0% "
                       + "target changed by 1.5 points, within the 2.0 points noise threshold, so it counts as no change.")

        let plan = (ProgressMetricID.loadVersusPlan, 0.9...1.1, 0.05)
        XCTAssertEqual(still(plan.0, plan.1, plan.2, 0.85, 1.15),
                       "Weekly load versus plan crossed the 90.0-110.0% target from below to above over 4 weeks "
                       + "(85.0% then, 115.0% now), but its distance from the target changed by 0.0 points, "
                       + "within the 5.0 points noise threshold, so it counts as no change.")
        XCTAssertEqual(still(plan.0, plan.1, plan.2, 1.15, 0.85),
                       "Weekly load versus plan crossed the 90.0-110.0% target from above to below over 4 weeks "
                       + "(115.0% then, 85.0% now), but its distance from the target changed by 0.0 points, "
                       + "within the 5.0 points noise threshold, so it counts as no change.")
        XCTAssertEqual(still(plan.0, plan.1, plan.2, 1.30, 0.85),
                       "Weekly load versus plan moved from 130.0% to 85.0%, crossing the 90.0-110.0% target from above "
                       + "to below, 15.0 points closer to it, over 4 weeks.")
        XCTAssertEqual(still(plan.0, plan.1, plan.2, 0.85, 1.30),
                       "Weekly load versus plan crossed the 90.0-110.0% target from below to above and is 15.0 points "
                       + "further from it than 4 weeks ago (85.0% then, 130.0% now).")
    }

    /// F13 acceptance: for every 4-week window across a history that improves,
    /// plateaus, stops and declines, the summary either names an improving
    /// metric with evidence or says plainly that nothing moved and why.
    func testEveryFourWeekWindowShowsProgressOrSaysWhyNot() throws {
        var weeks = F.trend(10, start: 2.9, rate: 0.01)                         // weeks 0-9 improving
        let top = try XCTUnwrap(weeks.last?.easySpeed)
        weeks += Array(repeating: .easy(top), count: 8)                          // 10-17 flat
        weeks += Array(repeating: .off, count: 5)                                // 18-22 off
        weeks += (0..<8).map { .easy(top * pow(0.99, Double($0 + 1))) }          // 23-30 declining
        let acts = F.history(weeks)
        var verdicts: [Int: ProgressSummary] = [:]
        for end in 1...31 {
            let s = ProgressBuilder.build(activities: acts, dailyHealth: flatHealth,
                                          options: F.options(asOf: F.asOf(week: end)) {
                                              // Only the 4-week change is checked, so a short series keeps the test quick.
                                              $0.seriesWeeks = 4; $0.changeWeeks = [4]
                                          }).summary()
            verdicts[end] = s
            switch s.verdict {
            case .improving(let metrics):
                XCTAssertFalse(metrics.isEmpty)
                for m in metrics {
                    XCTAssertEqual(m.change.direction, .improving)
                    XCTAssertFalse(m.change.evidence.isEmpty, "week \(end): \(m.id) cites nothing")
                }
            case .nothingMoved(let why):
                XCTAssertFalse(why.isEmpty, "week \(end): nothing moved but no reason")
                XCTAssertTrue(s.plainText.count == why.count + 1 + s.sharedEvidence.count
                              && s.plainText.allSatisfy { !$0.isEmpty })
                if s.runsInWindow.isEmpty { XCTAssertEqual(why.first, .noRunsInWindow) }
            }
        }
        XCTAssertTrue(improvedIDs(verdicts[10]!).contains(.easyPace))
        XCTAssertTrue(improvedIDs(verdicts[18]!).isEmpty, "a plateau is not progress")
        XCTAssertEqual(reasons(verdicts[22]!).first, .noRunsInWindow)
        XCTAssertTrue(improvedIDs(verdicts[31]!).isEmpty)
        guard case .worse? = kind(verdicts[31]!, .easyPace) else { return XCTFail("decline should read as worse") }
    }
}
