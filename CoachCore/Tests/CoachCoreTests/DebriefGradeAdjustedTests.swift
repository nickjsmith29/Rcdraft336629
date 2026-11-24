import Foundation
import XCTest
@testable import CoachCore

// Synthetic runs only (AdaptFixture): F6 on hilly routes with grade-adjusted pace (F7 part 1, 3.6).
private typealias F = AdaptFixture

final class DebriefGradeAdjustedTests: XCTestCase {
    private let context = AdaptationContext(zones: F.zones, timeZone: F.tz, tracksPain: false,
                                            guardrails: GuardrailLimits(maxLongRunShare: 1))
    private let session = F.threshold("t0", week: 0, day: 1)

    private func debrief(_ run: CompletedRun) -> (DebriefFacts, RunMetrics?) {
        let o = AdaptationEngine.processRun(run, state: AdaptationState(), plan: [session], history: [], context: context)
        let d = DebriefFacts.build(run: run, planned: session, outcome: o, previousOutcome: nil, context: context)
        return (d, o.assessment?.metrics)
    }

    /// The planned pace target of the session's key (threshold) segments.
    private var target: PaceTarget { F.targets.target(.threshold).pace! }

    /// A hilly run whose grade-adjusted pace is `gapFactor` times the middle of the target. The
    /// fixture's climb is a triangle wave (about +/-6%); speed is uniform, so grade-adjusted pace
    /// scales exactly with the raw pace multiplier, which is calibrated from a probe run.
    private func hillyRun(gapFactor: Double, climbPerKm: Double = 30) throws -> CompletedRun {
        let probe = F.run(for: session, F.RunSpec(climbPerKm: climbPerKm))
        let probeGAP = try XCTUnwrap(RunMetrics.measure(probe, planned: session).gradeAdjusted).paceSecondsPerKm
        let mid = (target.fastestSecondsPerKm + target.slowestSecondsPerKm) / 2
        return F.run(for: session, F.RunSpec(pace: gapFactor * mid / probeGAP, climbPerKm: climbPerKm))
    }

    func testHillyRunWithGAPInsideTheBandReadsWithinTarget() throws {
        let run = try hillyRun(gapFactor: 1)
        let (d, m) = debrief(run)
        let gap = try XCTUnwrap(m?.gradeAdjusted)
        let pace = try XCTUnwrap(d.fact("pace"))
        XCTAssertEqual(pace.kind, .paceGradeAdjusted(.reps))
        XCTAssertEqual(pace.comparison, .within)
        XCTAssertEqual(pace.value(.pace), gap.paceSecondsPerKm)
        XCTAssertEqual(pace.value(.targetFastest), target.fastestSecondsPerKm)
        XCTAssertEqual(pace.value(.targetSlowest), target.slowestSecondsPerKm)
        XCTAssertEqual(pace.value(.climb), m?.climbMetersPerKm)
        XCTAssertNil(m?.paceSecondsPerKm, "raw pace is still not compared on a hilly route")
        // Raw pace is faster than the band's slow end would allow only because the route climbs:
        // the raw pace is slower than GAP, so the raw pace alone would have misjudged the run.
        XCTAssertGreaterThan(gap.rawPaceSecondsPerKm, gap.paceSecondsPerKm)
        let text = DebriefText.text(d)
        XCTAssertTrue(text.contains("Grade-adjusted pace was"), text)
        XCTAssertTrue(text.contains("inside the"), text)
        XCTAssertTrue(text.contains("on a route that climbed"), text)
        XCTAssertFalse(text.contains("not compared"), text)
        assertContract(d)
    }

    func testHillyRunTooSlowOnGAPReadsSlower() throws {
        let run = try hillyRun(gapFactor: 1.15)
        let (d, _) = debrief(run)
        let pace = try XCTUnwrap(d.fact("pace"))
        XCTAssertEqual(pace.kind, .paceGradeAdjusted(.reps))
        XCTAssertEqual(pace.comparison, .above)
        let text = DebriefText.text(d)
        XCTAssertTrue(text.contains("Grade-adjusted pace was"), text)
        XCTAssertTrue(text.contains("slower than the"), text)
        assertContract(d)
    }

    func testHillyRunTooFastOnGAPReadsFaster() throws {
        let (d, _) = debrief(try hillyRun(gapFactor: 0.85))
        XCTAssertEqual(d.fact("pace")?.comparison, .below)
        XCTAssertTrue(DebriefText.text(d).contains("faster than the"), DebriefText.text(d))
        assertContract(d)
    }

    func testToleranceIsTheFlatRunsTolerance() throws {
        // 0.5% over the slow end: inside the classifier's 1% tolerance, as on a flat run.
        let slow = target.slowestSecondsPerKm, mid = (target.fastestSecondsPerKm + slow) / 2
        let (d, _) = debrief(try hillyRun(gapFactor: slow * 1.005 / mid))
        XCTAssertEqual(d.fact("pace")?.comparison, .withinTolerance)
        XCTAssertEqual(d.fact("pace")?.value(.paceTolerance), AdaptationLimits.default.paceTolerance)
        assertContract(d)
    }

    func testImperialUnitsStateTheGradeAdjustedPaceInMiles() throws {
        let (d, _) = debrief(try hillyRun(gapFactor: 1))
        let text = DebriefText.text(d, units: .imperial)
        XCTAssertTrue(text.contains("Grade-adjusted pace was"), text)
        XCTAssertTrue(text.contains("/mi"), text)
        XCTAssertTrue(text.contains("ft per mi"), text)
        assertContract(d, units: .imperial)
    }

    func testGAPChangesNoTrainingSignal() throws {
        // The adaptation engine still ignores pace on a hilly route: same reading with or without GAP.
        let run = try hillyRun(gapFactor: 1.15)
        let withGAP = RunClassifier.assess(run, planned: session, zones: F.zones)
        XCTAssertNotNil(withGAP.metrics.gradeAdjusted)
        XCTAssertNil(withGAP.metrics.paceSecondsPerKm)
        XCTAssertNil(withGAP.triggers.first { $0.metric == .pace }, "no pace trigger on a hilly run")
    }

    func testFlatRunIsUnchanged() throws {
        let flat = F.run(for: session, F.RunSpec(climbPerKm: 5))
        let (d, m) = debrief(flat)
        XCTAssertNil(m?.gradeAdjusted, "GAP is measured only on hilly routes")
        XCTAssertNil(m?.paceNotComparableReason)
        XCTAssertEqual(d.fact("pace")?.kind, .pace(.reps))
        XCTAssertEqual(d.fact("pace")?.value(.pace), m?.paceSecondsPerKm)
        XCTAssertFalse(DebriefText.text(d).contains("Grade-adjusted"))
    }

    func testTreadmillRunIsUnchangedEvenWithAltitude() throws {
        let tread = F.run(for: session, F.RunSpec(climbPerKm: 30, isTreadmill: true))
        let (d, m) = debrief(tread)
        XCTAssertNil(m?.gradeAdjusted)
        XCTAssertEqual(d.fact("pace")?.kind, .paceNotCompared(.treadmill))
        XCTAssertFalse(DebriefText.text(d).contains("Grade-adjusted"))
    }

    func testMetricsRoundTripThroughStoredState() throws {
        let run = try hillyRun(gapFactor: 1)
        let o = AdaptationEngine.processRun(run, state: AdaptationState(), plan: [session], history: [], context: context)
        let data = try JSONEncoder().encode(o.state)
        let back = try JSONDecoder().decode(AdaptationState.self, from: data)
        XCTAssertNotNil(o.assessment?.metrics.gradeAdjusted)
        XCTAssertEqual(back.assessments.last?.metrics.gradeAdjusted, o.assessment?.metrics.gradeAdjusted)
        XCTAssertEqual(back, o.state)
    }

    // MARK: Contract

    /// Every number in the text comes from the fact's values, and every stated comparison holds.
    private func assertContract(_ d: DebriefFacts, units: UnitPreference = .metric,
                                file: StaticString = #filePath, line: UInt = #line) {
        let lines = DebriefText.lines(d, units: units)
        let ids = Set(d.facts.map(\.id))
        for l in lines {
            XCTAssertTrue(l.factIDs.allSatisfy(ids.contains), l.text, file: file, line: line)
            for c in l.comparisons {
                XCTAssertTrue(c.isBoundary || c.relation.holds(c.shownValueNumber, c.shownLimitNumber), l.text, file: file, line: line)
                XCTAssertTrue(l.text.contains(c.shownValue) && l.text.contains(c.shownLimit), l.text, file: file, line: line)
            }
        }
        XCTAssertTrue(d.facts.allSatisfy { $0.values.allSatisfy { $0.value.isFinite } && !$0.source.isEmpty }, file: file, line: line)
    }
}
