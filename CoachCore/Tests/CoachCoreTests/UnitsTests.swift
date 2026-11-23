import Foundation
import XCTest
@testable import CoachCore

// Synthetic values only: no real runner's paces, races or routes.
private typealias F = AdaptFixture

final class UnitsTests: XCTestCase {
    // MARK: The preference

    func testDefaultFollowsTheLocaleMeasurementSystem() {
        XCTAssertEqual(UnitPreference.default(for: Locale(identifier: "en_US")), .imperial)
        XCTAssertEqual(UnitPreference.default(for: Locale(identifier: "es_US")), .imperial)
        XCTAssertEqual(UnitPreference.default(for: Locale(identifier: "en_GB")), .metric)
        XCTAssertEqual(UnitPreference.default(for: Locale(identifier: "fr_FR")), .metric)
        XCTAssertEqual(UnitPreference.default(for: Locale(identifier: "de_DE")), .metric)
    }

    func testSavedChoiceWinsOverTheLocaleAndRoundTrips() throws {
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(UnitPreference.resolved(saved: nil, locale: us), .imperial)
        XCTAssertEqual(UnitPreference.resolved(saved: .metric, locale: us), .metric)
        XCTAssertEqual(UnitPreference.resolved(saved: .imperial, locale: Locale(identifier: "fr_FR")), .imperial)
        for u in UnitPreference.allCases {
            let data = try JSONEncoder().encode([u])
            XCTAssertEqual(try JSONDecoder().decode([UnitPreference].self, from: data), [u])
            XCTAssertEqual(UnitPreference(rawValue: u.rawValue), u)
        }
    }

    // MARK: The formatter

    func testConversionConstantsAreExact() {
        XCTAssertEqual(UnitFormatting.metersPerMile, 1609.344)
        XCTAssertEqual(UnitFormatting.metersPerFoot, 0.3048)
        XCTAssertEqual(UnitFormatting.distanceValue(1609.344, .imperial), 1)
        XCTAssertEqual(UnitFormatting.distanceValue(1609.344, .metric), 1.609344, accuracy: 1e-12)
        XCTAssertEqual(UnitFormatting.paceValue(300, .imperial), 482.8032, accuracy: 1e-9)
        XCTAssertEqual(UnitFormatting.paceValue(300, .metric), 300)
        // 1 m per km is 5.28 ft per mile exactly (5280 ft in a mile).
        XCTAssertEqual(UnitFormatting.climbValue(1, .imperial), 5.28, accuracy: 1e-9)
        XCTAssertEqual(UnitFormatting.climbValue(12, .metric), 12)
    }

    func testFormatterInBothUnits() {
        XCTAssertEqual(UnitFormatting.distance(8_240, .metric), "8.2 km")
        XCTAssertEqual(UnitFormatting.distance(8_240, .imperial), "5.1 mi")
        XCTAssertEqual(UnitFormatting.distance(Distance.halfMarathon, .imperial), "13.1 mi")
        XCTAssertEqual(UnitFormatting.distance(Distance.marathon, .imperial), "26.2 mi")
        XCTAssertEqual(UnitFormatting.distance(Distance.mile, .imperial, decimals: 2), "1.00 mi")
        XCTAssertEqual(UnitFormatting.distance(0, .imperial), "0.0 mi")
        XCTAssertEqual(UnitFormatting.distance(.nan, .imperial), "-")
        XCTAssertEqual(UnitFormatting.distance(.infinity, .metric), "-")
        XCTAssertEqual(UnitFormatting.pace(300, .metric), "5:00/km")
        XCTAssertEqual(UnitFormatting.pace(300, .imperial), "8:03/mi")
        XCTAssertEqual(UnitFormatting.paceClock(359.6, .metric), "6:00")
        XCTAssertEqual(UnitFormatting.pace(.nan, .imperial), "-")
        XCTAssertEqual(UnitFormatting.pace(0, .imperial), "-")
        XCTAssertEqual(UnitFormatting.pace(-5, .metric), "-")
        let t = PaceTarget(fastestSecondsPerKm: 267, slowestSecondsPerKm: 275)
        XCTAssertEqual(UnitFormatting.paceRange(t, .metric), "4:27 to 4:35/km")
        XCTAssertEqual(UnitFormatting.paceRange(t, .imperial), "7:10 to 7:23/mi")
        XCTAssertEqual(UnitFormatting.climb(12, .metric), "12 m per km")
        XCTAssertEqual(UnitFormatting.climb(12, .imperial), "63 ft per mi")
        XCTAssertEqual(UnitFormatting.climb(.nan, .imperial), "-")
    }

    // MARK: The debrief in miles

    private func facts(_ f: DebriefFact...) -> DebriefFacts { DebriefFacts(activityID: "x", facts: f, timeZone: F.tz) }

    private func paceFact(_ pace: Double, fastest: Double, slowest: Double, _ c: DebriefComparison) -> DebriefFact {
        DebriefFact(id: "pace", kind: .pace(.mainPart), values: [
            DebriefValue(name: .pace, value: pace, unit: .secondsPerKm),
            DebriefValue(name: .targetFastest, value: fastest, unit: .secondsPerKm),
            DebriefValue(name: .targetSlowest, value: slowest, unit: .secondsPerKm),
            DebriefValue(name: .paceTolerance, value: 0, unit: .fraction),
        ], comparison: c, source: "test")
    }

    func testDebriefFormatConvertsBeforeRounding() {
        func v(_ x: Double, _ n: DebriefValue.Name, _ u: DebriefValue.Unit) -> DebriefValue { DebriefValue(name: n, value: x, unit: u) }
        let pace = v(300, .pace, .secondsPerKm)
        XCTAssertEqual(DebriefFormat.string(pace, timeZone: F.tz, units: .imperial), "8:03")
        XCTAssertEqual(DebriefFormat.number(pace, units: .imperial), 483)
        XCTAssertEqual(DebriefFormat.number(pace), 300, "metric stays in s/km")
        let d = v(8_240, .distance, .meters)
        XCTAssertEqual(DebriefFormat.string(d, timeZone: F.tz, units: .imperial), "5.1 mi")
        XCTAssertEqual(DebriefFormat.number(d, units: .imperial), 5.1)
        XCTAssertEqual(DebriefFormat.number(d), 8_200, "metric stays in metres")
        let held = v(40_000, .heldLevel, .meters)
        XCTAssertEqual(DebriefFormat.string(held, timeZone: F.tz, units: .imperial), "24.9 mi")
        let climb = v(12.3, .climb, .metersPerKm)
        XCTAssertEqual(DebriefFormat.string(climb, timeZone: F.tz, units: .imperial), "65")
        XCTAssertEqual(DebriefFormat.string(climb, timeZone: F.tz, extraDecimals: 1, units: .imperial), "64.9")
        XCTAssertEqual(try XCTUnwrap(DebriefFormat.number(climb, extraDecimals: 2, units: .imperial)), 64.94, accuracy: 1e-9)
        XCTAssertEqual(DebriefFormat.string(v(.nan, .pace, .secondsPerKm), timeZone: F.tz, units: .imperial), "-")
        XCTAssertNil(DebriefFormat.number(v(.infinity, .distance, .meters), units: .imperial))
        // Units that don't depend on the system read the same.
        for (x, n, u) in [(169.67, DebriefValue.Name.heartRate, DebriefValue.Unit.bpm), (4.96, .decoupling, .percent),
                          (3725, .movingTime, .seconds), (5400, .allowedTime, .seconds), (0.015, .paceStep, .fraction)] {
            for e in 0...2 {
                XCTAssertEqual(DebriefFormat.string(v(x, n, u), timeZone: F.tz, extraDecimals: e, units: .imperial),
                               DebriefFormat.string(v(x, n, u), timeZone: F.tz, extraDecimals: e))
                XCTAssertEqual(DebriefFormat.number(v(x, n, u), extraDecimals: e, units: .imperial),
                               DebriefFormat.number(v(x, n, u), extraDecimals: e))
            }
        }
    }

    /// A limit is judged on the numbers shown in the runner's unit, not
    /// rounded in km and then converted.
    func testPaceNearALimitIsJudgedInTheShownUnit() {
        // 4:59.6/km against a 5:00/km fast end: equal once rounded in km
        // ("just faster"), but 8:02 against 8:03 in miles (plainly faster).
        let near = facts(paceFact(299.6, fastest: 300, slowest: 310, .below))
        XCTAssertTrue(DebriefText.text(near).contains("Pace was 5:00/km over the main part, just faster than the 5:00 to 5:10/km target"),
                      DebriefText.text(near))
        XCTAssertTrue(DebriefText.text(near, units: .imperial)
            .contains("Pace was 8:02/mi over the main part, faster than the 8:03 to 8:19/mi target"), DebriefText.text(near, units: .imperial))
        // The other way: 300.45 against 300.55 shows 5:00 against 5:01 in km,
        // but both are 8:04 in miles, so the line says "just".
        let tie = facts(paceFact(300.45, fastest: 300.55, slowest: 310, .below))
        XCTAssertTrue(DebriefText.text(tie).contains("5:00/km over the main part, faster than the 5:01 to 5:10/km target"), DebriefText.text(tie))
        XCTAssertTrue(DebriefText.text(tie, units: .imperial).contains("8:04/mi over the main part, just faster than the 8:04 to 8:19/mi target"),
                      DebriefText.text(tie, units: .imperial))
        for units in UnitPreference.allCases {
            assertDebriefContract(near, units: units)
            assertDebriefContract(tie, units: units)
        }
    }

    /// Paces across both ends of a 5:00 to 5:10/km target in steps of
    /// 0.01 s/km: every comparison holds on the shown min/mi paces.
    func testPaceSweepAroundAFiveMinuteTargetInMiles() {
        for pace in stride(from: 295.0, through: 315.0, by: 0.01) {
            let target = PaceTarget(fastestSecondsPerKm: 300, slowestSecondsPerKm: 310)
            let c = DebriefFacts.paceComparison(pace, target, tolerance: 0)
            let d = facts(paceFact(pace, fastest: 300, slowest: 310, c))
            let l = DebriefText.runLine(d, units: .imperial)
            XCTAssertEqual(l?.comparisons.isEmpty, false, "\(pace)")
            XCTAssertFalse(l?.text.contains("km") ?? true, l?.text ?? "")
            assertDebriefContract(d, units: .imperial)
        }
    }

    func testEngineDebriefReadsInMiles() throws {
        let long = F.long("l0", week: 0, day: 5, minutes: 60)
        let ctx = AdaptationContext(zones: F.zones, timeZone: F.tz, tracksPain: false,
                                    guardrails: GuardrailLimits(maxLongRunShare: 1), units: .imperial)
        let run = F.run(for: long, F.RunSpec(drift: 0.03, cadenceFade: 0.01))
        let o = AdaptationEngine.processRun(run, state: AdaptationState(), plan: [long], history: [], context: ctx)
        let d = DebriefFacts.build(run: run, planned: long, outcome: o, previousOutcome: nil, context: ctx)
        let text = DebriefText.text(d, units: .imperial)
        let meters = try XCTUnwrap(d.fact("run")?.value(.distance))
        XCTAssertTrue(text.hasPrefix(UnitFormatting.distance(meters, .imperial) + " in "), text)
        XCTAssertFalse(text.contains("km"), text)
        assertDebriefContract(d, units: .imperial)
        // The facts are the same in both units; only the wording changes.
        XCTAssertEqual(d, DebriefFacts.build(run: run, planned: long, outcome: o, previousOutcome: nil,
                                             context: AdaptationContext(zones: F.zones, timeZone: F.tz, tracksPain: false,
                                                                        guardrails: GuardrailLimits(maxLongRunShare: 1))))
    }

    func testHillyRouteAndDistanceHoldReadInMiles() {
        let hilly = facts(DebriefFact(id: "pace", kind: .paceNotCompared(.hilly), values: [
            DebriefValue(name: .pace, value: 330, unit: .secondsPerKm),
            DebriefValue(name: .climb, value: 30, unit: .metersPerKm),
        ], source: "test"))
        XCTAssertEqual(DebriefText.text(hilly, units: .imperial),
                       "Pace was 8:51/mi on a route that climbed 158 ft per mi; raw pace is not compared with the target until grade-adjusted pace exists.")
        XCTAssertEqual(DebriefText.text(hilly),
                       "Pace was 5:30/km on a route that climbed 30 m per km; raw pace is not compared with the target until grade-adjusted pace exists.")
        // As the builder gives it: the hold follows the engine's reading of the run.
        let hold = facts(DebriefFact(id: "assessment", kind: .assessment(.behind), values: [], source: "test"),
                         DebriefFact(id: "change.volumeHeld", kind: .change(.volumeHeld), values: [
            DebriefValue(name: .heldLevel, value: 40_000, unit: .meters),
            DebriefValue(name: .holdEnd, value: F.date(week: 2, day: 0).timeIntervalSince1970, unit: .date),
        ], source: "test"))
        XCTAssertTrue(DebriefText.text(hold, units: .imperial).contains("weekly volume stays at or below 24.9 mi until "),
                      DebriefText.text(hold, units: .imperial))
        for units in UnitPreference.allCases {
            assertDebriefContract(hilly, units: units)
            assertDebriefContract(hold, units: units)
        }
    }

    // MARK: Adaptation wording

    func testAdaptationTriggerDetailsUseTheUnits() throws {
        let t = F.threshold("t0", week: 0, day: 1)
        let run = F.run(for: t, F.RunSpec(pace: 1.05))
        let metric = RunClassifier.assess(run, planned: t, zones: F.zones)
        let imperial = RunClassifier.assess(run, planned: t, zones: F.zones, units: .imperial)
        let m = try XCTUnwrap(metric.triggers.first { $0.metric == .pace })
        let i = try XCTUnwrap(imperial.triggers.first { $0.metric == .pace })
        XCTAssertTrue(m.detail.hasSuffix("/km"), m.detail)
        XCTAssertTrue(i.detail.hasSuffix("/mi"), i.detail)
        XCTAssertEqual(i.value, m.value, "the trigger value stays in s/km")
        XCTAssertEqual(imperial.signal, metric.signal, "units never change the reading")
        let hilly = F.run(for: t, F.RunSpec(climbPerKm: 30))
        let reason = try XCTUnwrap(RunMetrics.measure(hilly, planned: t, units: .imperial).paceNotComparableReason)
        XCTAssertTrue(reason.contains("ft per mi of climb"), reason)
        XCTAssertTrue(try XCTUnwrap(RunMetrics.measure(hilly, planned: t).paceNotComparableReason).contains("m climb per km"))
        XCTAssertEqual(PlanFormatting.volume(40_000, .distance, units: .imperial), "24.9 mi")
        XCTAssertEqual(PlanFormatting.volume(40_000, .distance), "40.0 km")
        XCTAssertEqual(PlanFormatting.volume(5400, .time, units: .imperial), "1 h 30 min")
    }

    // MARK: Progress wording

    func testProgressSummaryStatesPaceInMiles() throws {
        let flat = ProgressFixture.health(days: 400, before: ProgressFixture.asOf(week: 40))
        let s = ProgressFixture.dashboard(ProgressFixture.trend(12, start: 2.9, rate: 0.01), asOfWeek: 12, health: flat).summary()
        guard case .improving(let metrics) = s.verdict else { return XCTFail("expected improvement") }
        let easy = try XCTUnwrap(metrics.first { $0.id == .easyPace })
        XCTAssertEqual(easy.plainText(units: .metric), easy.plainText)
        let text = easy.plainText(units: .imperial)
        XCTAssertTrue(text.hasSuffix(" s/mi over 4 weeks."), text)
        guard case .measured(let a) = easy.change.outcome else { return XCTFail() }
        XCTAssertTrue(text.contains(String(format: "improved by %.1f s/mi", abs(a.gain) * 1.609344)), text)
        XCTAssertEqual(s.plainText(units: .metric), s.plainText)
        XCTAssertEqual(s.plainText(units: .imperial).count, s.plainText.count)
        XCTAssertFalse(s.plainText(units: .imperial).contains { $0.contains("s/km") })
        XCTAssertEqual(ProgressMetricID.bestEffort(meters: 3000).name(units: .imperial), "Best 1.9 mi effort")
        XCTAssertEqual(ProgressMetricID.bestEffort(meters: Distance.fiveK).name(units: .imperial), "Best 5K effort")
        XCTAssertEqual(ProgressMetricID.predictedTime(meters: Distance.halfMarathon).name(units: .imperial), "Predicted half marathon time")
        XCTAssertEqual(ProgressUnit.secondsPerKilometer.symbol(units: .imperial), "s/mi")
        XCTAssertEqual(ProgressText.range(300...310, .secondsPerKilometer, .imperial), "8:03-8:19/mi")
        XCTAssertEqual(ProgressText.range(300...310, .secondsPerKilometer), "5:00-5:10/km")
        let still = StillReason.metric(.easyPace, .secondsPerKilometer, .worse(a))
        XCTAssertTrue(still.plainText(windowWeeks: 4, units: .imperial).contains("s/mi worse than 4 weeks ago"),
                      still.plainText(windowWeeks: 4, units: .imperial))
    }

    // MARK: Plan and goal wording

    func testRaceDayPurposeAndGoalEditReadInMiles() throws {
        let report = GoalFixture.fixtureReport()
        let original = GoalFixture.settings(weeksAhead: 12)
        let first = try XCTUnwrap(GoalPlanner.plan(settings: original, baseline: report, today: GoalFixture.today).plan)
        let race = try XCTUnwrap(first.plan.workouts.first { $0.kind == .race })
        let built = try XCTUnwrap(race.prescription?.purpose)
        XCTAssertTrue(built.hasSuffix(" (21.1 km)."), built)
        XCTAssertEqual(PlanFormatting.purpose(of: race), built)
        XCTAssertEqual(PlanFormatting.purpose(of: race, units: .imperial), String(built.dropLast(" (21.1 km).".count)) + " (13.1 mi).")
        XCTAssertEqual(PlanFormatting.distance(of: race, units: .imperial), "13.1 mi")
        let easy = try XCTUnwrap(first.plan.workouts.first { $0.kind == .easy })
        XCTAssertEqual(PlanFormatting.purpose(of: easy, units: .imperial), easy.prescription?.purpose, "no unit-dependent number")
        XCTAssertNil(PlanFormatting.distance(of: easy))
        if let p = first.plan.workouts.compactMap({ $0.prescription?.segments.compactMap(\.target.pace).first }).first {
            XCTAssertTrue(PlanFormatting.paceTarget(p, units: .imperial).hasSuffix("/mi"))
            XCTAssertEqual(PlanFormatting.paceTarget(p), UnitFormatting.paceRange(p, .metric))
        }

        var edited = original
        edited.race.distanceMeters = Distance.tenK
        let replan = GoalPlanner.replan(from: original, previousPlan: first.plan, to: edited, baseline: report,
                                        today: GoalFixture.today, units: .imperial)
        XCTAssertTrue(replan.explanation.contains("Race distance changed from 13.1 mi to 6.2 mi."), "\(replan.explanation)")
        let metric = GoalPlanner.replan(from: original, previousPlan: first.plan, to: edited, baseline: report, today: GoalFixture.today)
        XCTAssertEqual(metric.result, replan.result, "units never change the plan")
    }
}
