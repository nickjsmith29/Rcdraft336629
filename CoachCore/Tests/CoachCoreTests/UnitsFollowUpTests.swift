import Foundation
import XCTest
@testable import CoachCore

// Synthetic values only: no real runner's paces, races, routes or history (#71).
final class UnitsFollowUpTests: XCTestCase {
    private let utc = PlanFixture.utc
    private let distanceLimits = GuardrailLimits(measure: .distance)

    private func run(_ id: String, week: Int, day: Int, _ kind: PlannedWorkout.Kind, minutes: Double, km: Double) -> PlannedWorkout {
        PlanFixture.workout(id, week: week, day: day, kind, minutes: minutes, km: km)
    }

    /// Four weeks of 4 x 10 km in 60 min (the second a recovery week of
    /// 4 x 7.5 km in 45 min), then a planned week of 4 x 12 km in 60 min: flat
    /// in time, 20% up in distance, with no run past the spike limit in time
    /// and every run 20% past it in distance.
    private func distanceRise() -> (history: [PlannedWorkout], plan: [PlannedWorkout]) {
        let history = (0..<4).flatMap { w in
            (0..<4).map { run("h\(w)-\($0)", week: w, day: $0 * 2, .easy, minutes: w == 1 ? 45 : 60, km: w == 1 ? 7.5 : 10) }
        }
        let plan = (0..<4).map { run("p\($0)", week: 4, day: $0 * 2, .easy, minutes: 60, km: 12) }
        return (history, plan)
    }

    /// `text` states a distance in `units` and none in the other system.
    private func assertReads(_ text: String, _ units: UnitPreference, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(text.contains(" " + UnitFormatting.distanceUnit(units)), text, file: file, line: line)
        assertNoOther(text, units, file: file, line: line)
    }

    /// `text` states no distance in the system other than `units`.
    private func assertNoOther(_ text: String, _ units: UnitPreference, file: StaticString = #filePath, line: UInt = #line) {
        let other = " " + UnitFormatting.distanceUnit(units == .metric ? .imperial : .metric)
        XCTAssertFalse([" ", ".", ")", ","].contains { text.contains(other + $0) }, text, file: file, line: line)
    }

    // MARK: GuardrailChecker texts

    func testWeeklyRiseInDistanceReadsInTheRunnersUnits() throws {
        let (h, p) = distanceRise()
        let metric = GuardrailChecker.check(history: h, planned: p, timeZone: utc, limits: distanceLimits)
        let imperial = GuardrailChecker.check(history: h, planned: p, timeZone: utc, limits: distanceLimits, units: .imperial)
        let m = try XCTUnwrap(metric.violations.first { $0.rule == .weeklyIncrease })
        let i = try XCTUnwrap(imperial.violations.first { $0.rule == .weeklyIncrease })
        XCTAssertEqual(m.explanation, GuardrailChecker.check(history: h, planned: p, timeZone: utc, limits: distanceLimits,
                                                             units: .metric).violations.first { $0.rule == .weeklyIncrease }?.explanation,
                       "metric is the default")
        XCTAssertTrue(m.explanation.contains("volume 48.0 km is 20% above the week before (40.0 km)"), m.explanation)
        XCTAssertTrue(m.explanation.hasSuffix("so at most 44.0 km. (Heuristic guardrail, SPEC 3.5.)"), m.explanation)
        // 48 km = 29.8 mi, 40 km = 24.9 mi, 44 km = 27.3 mi, each converted before rounding.
        XCTAssertTrue(i.explanation.contains("volume 29.8 mi is 20% above the week before (24.9 mi)"), i.explanation)
        XCTAssertTrue(i.explanation.hasSuffix("so at most 27.3 mi. (Heuristic guardrail, SPEC 3.5.)"), i.explanation)
        for v in imperial.violations { assertNoOther(v.explanation, .imperial) }
        for v in metric.violations { assertNoOther(v.explanation, .metric) }
        // Only the words change: same rules, weeks, numbers and skips.
        XCTAssertEqual(metric.violations.map { [$0.rule.rawValue, "\($0.weekStart)", "\($0.measured)", "\($0.allowed)", "\($0.unit)"] },
                       imperial.violations.map { [$0.rule.rawValue, "\($0.weekStart)", "\($0.measured)", "\($0.allowed)", "\($0.unit)"] })
        XCTAssertEqual(metric.notEvaluated, imperial.notEvaluated)
        XCTAssertEqual(metric.passed, imperial.passed)
    }

    func testTimeVolumeTextsReadTheSameInBothSystems() {
        let (h, p) = distanceRise()
        let longer = p.map { $0.resized(toSeconds: 70 * 60) }
        let metric = GuardrailChecker.check(history: h, planned: longer, timeZone: utc)
        let imperial = GuardrailChecker.check(history: h, planned: longer, timeZone: utc, units: .imperial)
        let weekly = metric.violations.filter { $0.rule == .weeklyIncrease }
        XCTAssertFalse(weekly.isEmpty)
        XCTAssertEqual(weekly, imperial.violations.filter { $0.rule == .weeklyIncrease }, "minutes have no unit system")
    }

    func testSpikeTextInDistanceReadsInTheRunnersUnitsWhateverTheMeasure() throws {
        // Time is flat, so the spike is in distance even under the default time measure.
        let (h, p) = distanceRise()
        for limits in [GuardrailLimits.default, distanceLimits] {
            let metric = GuardrailChecker.check(history: h, planned: p, timeZone: utc, limits: limits)
            let imperial = GuardrailChecker.check(history: h, planned: p, timeZone: utc, limits: limits, units: .imperial)
            let m = try XCTUnwrap(metric.violations.first { $0.rule == .singleRunSpike })
            let i = try XCTUnwrap(imperial.violations.first { $0.rule == .singleRunSpike })
            XCTAssertEqual(m.unit, .meters)
            XCTAssertTrue(m.explanation.contains("(12.0 km) is 20% longer than the longest run"), m.explanation)
            XCTAssertTrue(m.explanation.contains("(10.0 km on "), m.explanation)
            XCTAssertTrue(m.explanation.contains("so at most 11.0 km."), m.explanation)
            XCTAssertTrue(i.explanation.contains("(7.5 mi) is 20% longer than the longest run"), i.explanation)
            XCTAssertTrue(i.explanation.contains("(6.2 mi on "), i.explanation)
            XCTAssertTrue(i.explanation.contains("so at most 6.8 mi."), i.explanation)
            assertReads(i.explanation, .imperial)
            XCTAssertEqual(m.measured, i.measured)
            XCTAssertEqual(m.allowed, i.allowed)
        }
    }

    func testRaceSpikeFlagReadsInTheRunnersUnits() throws {
        let (h, _) = distanceRise()
        let race = run("race", week: 4, day: 6, .race, minutes: 60, km: 15)
        let i = GuardrailChecker.check(history: h, planned: [race], timeZone: utc, units: .imperial)
        let flag = try XCTUnwrap(i.informationFlags.first { $0.rule == .singleRunSpike })
        XCTAssertTrue(flag.explanation.contains("(9.3 mi)"), flag.explanation)
        assertReads(flag.explanation, .imperial)
        let m = GuardrailChecker.check(history: h, planned: [race], timeZone: utc)
        XCTAssertTrue(try XCTUnwrap(m.informationFlags.first).explanation.contains("(15.0 km)"))
    }

    // MARK: GuardrailRepair passes the units through

    func testRepairChangeTextsReadInTheContextUnits() throws {
        let (h, p) = distanceRise()
        let asOf = PlanFixture.date(week: 4, day: 0, hour: 0)
        func repair(_ units: UnitPreference) throws -> GuardrailRepair.Result {
            let context = AdaptationContext(zones: try XCTUnwrap(HRZones(lthr: 165)), timeZone: utc, tracksPain: false,
                                            guardrails: distanceLimits, units: units)
            return GuardrailRepair.repair(plan: p, history: h, asOf: asOf, freezes: [], context: context)
        }
        let metric = try repair(.metric)
        let imperial = try repair(.imperial)
        XCTAssertFalse(imperial.changes.isEmpty)
        XCTAssertEqual(metric.plan, imperial.plan, "units never change the repair")
        XCTAssertEqual(metric.changes.map(\.kind), imperial.changes.map(\.kind))
        XCTAssertEqual(metric.changes.map(\.workoutIDs), imperial.changes.map(\.workoutIDs))
        for c in imperial.changes {
            assertNoOther(c.explanation, .imperial)
            for t in c.triggers { assertNoOther(t.detail, .imperial) }
        }
        for c in metric.changes {
            assertNoOther(c.explanation, .metric)
            for t in c.triggers { assertNoOther(t.detail, .metric) }
        }
        // The change texts carry the checker's distance wording through.
        XCTAssertTrue(imperial.changes.contains { $0.explanation.contains(" mi") }, "\(imperial.changes.map(\.explanation))")
        XCTAssertTrue(metric.changes.contains { $0.explanation.contains(" km") }, "\(metric.changes.map(\.explanation))")
        XCTAssertTrue(imperial.changes.flatMap(\.triggers).contains { $0.detail.contains(" mi") })
        for v in imperial.report.violations { assertNoOther(v.explanation, .imperial) }
    }

    func testAdaptationContextDefaultsToMetricTexts() {
        let context = AdaptationContext(zones: HRZones(lthr: 165)!, timeZone: utc, tracksPain: false)
        XCTAssertEqual(context.units, .metric)
    }

    // MARK: Watch purpose

    private func raceWorkout(meters: Double, purpose: String) -> PlannedWorkout {
        let zones = HRZones(lthr: 160)!
        let target = WorkoutTarget(heartRate: HeartRateTarget(zones: .z4 ... .z5a, floorBPM: zones.lowerBound(.z4),
                                                              ceilingBPM: zones.lowerBound(.z5b)),
                                   pace: PaceTarget(fastestSecondsPerKm: 280, slowestSecondsPerKm: 290), primary: .pace)
        let seg = WorkoutSegment(role: .main, intensity: .race, durationSeconds: 6000, target: target)
        let p = WorkoutPrescription(purpose: purpose, phase: .taper, segments: [seg], rules: [.goalRace])
        return PlannedWorkout(id: "race", date: PlanFixture.date(week: 2, day: 6), kind: .race, durationSeconds: 6000,
                              distanceMeters: meters, prescription: p)
    }

    func testWatchRaceDayPurposeReadsInTheRunnersUnits() throws {
        let race = raceWorkout(meters: Distance.halfMarathon, purpose: "Race day: your half marathon (21.1 km).")
        let zones = WatchSyncZones(heartRate: HRZones(lthr: 160)!)
        func mapped(_ options: WatchSyncOptions) throws -> WatchWorkout {
            guard case .workout(let w) = WatchSyncMapper.workout(for: race, zones: zones, timeZone: utc, options: options) else {
                XCTFail("expected a workout")
                throw CancellationError()
            }
            return w
        }
        let metric = try mapped(WatchSyncOptions())
        let imperial = try mapped(WatchSyncOptions(units: .imperial))
        XCTAssertEqual(WatchSyncOptions().units, .metric)
        XCTAssertEqual(metric.purpose, "Race day: your half marathon (21.1 km).")
        XCTAssertEqual(imperial.purpose, "Race day: your half marathon (13.1 mi).")
        // The goal stays a distance in metres; only the text changes.
        XCTAssertEqual(imperial.blocks, metric.blocks)
        XCTAssertEqual(imperial.warmup, metric.warmup)
        XCTAssertEqual(imperial.cooldown, metric.cooldown)
        XCTAssertEqual(imperial.id, metric.id)
        XCTAssertEqual(imperial.displayName, metric.displayName)
        // The batch path carries the option too.
        let batch = WatchSyncMapper.batch(for: [race], zones: zones, from: PlanFixture.date(week: 2, day: 0, hour: 0),
                                          timeZone: utc, options: WatchSyncOptions(units: .imperial))
        XCTAssertEqual(batch.workouts.map(\.purpose), ["Race day: your half marathon (13.1 mi)."])
    }

    func testWatchPurposeWithoutAUnitIsUnchangedAndNilStaysNil() throws {
        let zones = WatchSyncZones(heartRate: HRZones(lthr: 160)!)
        var other = raceWorkout(meters: Distance.tenK, purpose: "Race day: go well.")
        guard case .workout(let w) = WatchSyncMapper.workout(for: other, zones: zones, timeZone: utc,
                                                            options: WatchSyncOptions(units: .imperial)) else {
            return XCTFail("expected a workout")
        }
        XCTAssertEqual(w.purpose, "Race day: go well.")
        other = PlannedWorkout(id: "bare", date: other.date, kind: .easy, durationSeconds: 1800)
        guard case .workout(let bare) = WatchSyncMapper.workout(for: other, zones: zones, timeZone: utc,
                                                               options: WatchSyncOptions(units: .imperial)) else {
            return XCTFail("expected a workout")
        }
        XCTAssertNil(bare.purpose)
    }

    // MARK: PlanBuilder's race-day wording, named by the race's own distance (#89)

    func testPlanBuilderRaceDayWordingMatchesThePurposeRewrite() throws {
        let start = PlanFixture.date(week: 8, day: 0, hour: 0)
        let history = PlanFixture.easyWeeks([240, 240, 240, 240], start: 4)
        let cases: [(Double, String, String, String)] = [
            (Distance.fiveK, "5K", "5.0 km", "3.1 mi"),
            (Distance.tenK, "10K", "10.0 km", "6.2 mi"),
            (Distance.halfMarathon, "half marathon", "21.1 km", "13.1 mi"),
            (Distance.tenMiles, "10-mile race", "16.1 km", "10.0 mi"), // named by its own distance, not its category (#89)
            (15_000, "15K", "15.0 km", "9.3 mi"),
            (30_000, "30K", "30.0 km", "18.6 mi"),
            (Distance.marathon, "marathon", "42.2 km", "26.2 mi"),
        ]
        for (meters, name, km, mi) in cases {
            let input = PlanInput(raceDistanceMeters: meters, raceDate: PlanFixture.date(week: 19, day: 6, hour: 8),
                                  startDate: start, trainingDays: [.tuesday, .thursday, .saturday, .sunday], longRunDay: .sunday,
                                  recentWeeklySeconds: 240 * 60, recentLongRunSeconds: 80 * 60,
                                  heartRateZones: HRZones(lthr: 165), easyPace: EasyPaceSample(secondsPerKm: 360, heartRate: 138),
                                  fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: 24 * 60))
            guard case .plan(let plan) = PlanBuilder.build(input, history: history, timeZone: utc) else {
                return XCTFail("\(meters) m: expected a plan")
            }
            let race = try XCTUnwrap(plan.workouts.first { $0.kind == .race })
            XCTAssertEqual(race.distanceMeters, meters)
            XCTAssertEqual(race.prescription?.raceDistanceMeters, meters)
            XCTAssertEqual(race.prescription?.purpose, "Race day: your \(name) (\(km)).", "PlanBuilder's wording is pinned")
            XCTAssertEqual(PlanFormatting.purpose(of: race), "Race day: your \(name) (\(km)).")
            XCTAssertEqual(PlanFormatting.purpose(of: race, units: .imperial), "Race day: your \(name) (\(mi)).")
        }
    }

    // MARK: Progress paces as clocks

    func testProgressPaceLevelsReadAsClocks() {
        XCTAssertEqual(ProgressText.value(330, .secondsPerKilometer), "5:30/km")
        XCTAssertEqual(ProgressText.value(330, .secondsPerKilometer, .imperial), "8:51/mi") // 531.1 s/mi
        XCTAssertEqual(ProgressText.range(300...310, .secondsPerKilometer), "5:00-5:10/km")
        XCTAssertEqual(ProgressText.range(300...310, .secondsPerKilometer, .imperial), "8:03-8:19/mi")
        // A change of pace stays in seconds.
        XCTAssertEqual(ProgressText.amount(8, .secondsPerKilometer), "8.0 s/km")
        XCTAssertEqual(ProgressText.amount(8, .secondsPerKilometer, .imperial), "12.9 s/mi")
        XCTAssertEqual(ProgressText.value(.nan, .secondsPerKilometer, .imperial), "-")
        XCTAssertEqual(ProgressText.value(.infinity, .secondsPerKilometer), "-")
    }
}
