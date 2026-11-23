import XCTest
@testable import CoachCore

// #30: SPEC 3.5 rule 5's marathon allowances (the 45% long-run share
// ceiling, the 180-minute cap and their wording) apply only to a race of
// marathon distance, within 0.5% of 42,195 m. A race from 30 km up to that
// is planned like any other non-marathon race. Synthetic runners only.
final class MarathonDistanceOnlyTests: XCTestCase {
    private typealias F = PlanFixture
    private let utc = PlanFixture.utc

    // MARK: Predicate

    func testIsMarathonDistance() {
        XCTAssertTrue(RaceCategory.isMarathonDistance(meters: Distance.marathon))
        XCTAssertTrue(RaceCategory.isMarathonDistance(meters: 42_000))
        XCTAssertTrue(RaceCategory.isMarathonDistance(meters: 42_195 * 1.005))
        XCTAssertTrue(RaceCategory.isMarathonDistance(meters: 42_195 * 0.995))
        XCTAssertFalse(RaceCategory.isMarathonDistance(meters: 41_900))
        XCTAssertFalse(RaceCategory.isMarathonDistance(meters: 42_195 * 1.006))
        XCTAssertFalse(RaceCategory.isMarathonDistance(meters: 30_000))
        XCTAssertFalse(RaceCategory.isMarathonDistance(meters: Distance.halfMarathon))
        XCTAssertFalse(RaceCategory.isMarathonDistance(meters: nil))
        XCTAssertFalse(RaceCategory.isMarathonDistance(meters: .nan))
        XCTAssertFalse(RaceCategory.isMarathonDistance(meters: .infinity))
        XCTAssertFalse(RaceCategory.isMarathonDistance(meters: -42_195))
    }

    func testLongRunCapIs150MinutesBelowMarathonDistance() {
        XCTAssertEqual(PlanHeuristics.longRunCap(.marathon, isMarathonDistance: true), 180 * 60)
        XCTAssertEqual(PlanHeuristics.longRunCap(.marathon, isMarathonDistance: false), 150 * 60)
        XCTAssertEqual(PlanHeuristics.longRunCap(.half, isMarathonDistance: false), 135 * 60)
    }

    // MARK: Guardrail share and wording

    private func shareWeeks(raceKm: Double?) -> [PlannedWorkout] {
        // Week 0: 120 min of easy running and an 80-minute long run (40% of 200).
        var w = (0..<3).map { F.workout("e\($0)", week: 0, day: $0 * 2, .easy, minutes: 40) }
        w.append(F.workout("l0", week: 0, day: 5, .long, minutes: 80))
        w.append(F.workout("race", week: 1, day: 6, .race, minutes: 150, km: raceKm))
        return w
    }

    func testThirtyKGetsTheUsualShareAndNoMarathonWording() {
        let r = GuardrailChecker.check(history: [], planned: shareWeeks(raceKm: 30), timeZone: utc)
        let v = r.violations.filter { $0.rule == .longRunShare }
        XCTAssertEqual(v.count, 1, "\(r.violations.map(\.explanation))")
        XCTAssertFalse(v[0].explanation.lowercased().contains("marathon"), v[0].explanation)
        XCTAssertTrue(r.informationFlags.filter { $0.rule == .longRunShare }.isEmpty)
    }

    func testMarathonAndWithinToleranceKeepTheWarning() {
        for km in [42.195, 42.0] {
            let r = GuardrailChecker.check(history: [], planned: shareWeeks(raceKm: km), timeZone: utc)
            XCTAssertTrue(r.violations.filter { $0.rule == .longRunShare }.isEmpty, "\(km)")
            let f = r.informationFlags.filter { $0.rule == .longRunShare }
            XCTAssertEqual(f.count, 1, "\(km)")
            XCTAssertTrue(f.first?.explanation.contains("Marathon plans allow up to") ?? false)
        }
    }

    func testJustOutsideToleranceAndUnknownDistanceAreNotMarathon() {
        for km in [41.9, nil] as [Double?] {
            let r = GuardrailChecker.check(history: [], planned: shareWeeks(raceKm: km), timeZone: utc)
            XCTAssertEqual(r.violations.filter { $0.rule == .longRunShare }.count, 1, "\(String(describing: km))")
        }
        let nan = shareWeeks(raceKm: nil).map { w -> PlannedWorkout in
            var x = w; if x.kind == .race { x.distanceMeters = .nan }; return x
        }
        let r = GuardrailChecker.check(history: [], planned: nan, timeZone: utc)
        XCTAssertEqual(r.violations.filter { $0.rule == .longRunShare }.count, 1)
    }

    // MARK: Plan builder

    private var planMonday: Date { F.date(week: 8, day: 0, hour: 0) }

    private func build(distance: Double, weekly: Double = 240, weeks: Int = 16) -> PlanBuildResult {
        let days: [PlanWeekday] = [.tuesday, .thursday, .saturday]
        var h: [PlannedWorkout] = []
        for k in 0..<4 {
            let week = 4 + k
            for d in days {
                h.append(F.workout("h\(k)-\(d.rawValue)", week: week, day: d.rawValue, d == .saturday ? .long : .easy,
                                   minutes: d == .saturday ? weekly * 0.30 : weekly * 0.35))
            }
        }
        let race = planMonday.addingTimeInterval(Double((weeks - 1) * 7 + 6) * 86_400 + 8 * 3600)
        let i = PlanInput(raceDistanceMeters: distance, raceDate: race, startDate: planMonday,
                          trainingDays: Set(days), longRunDay: .saturday, recentWeeklySeconds: weekly * 60,
                          heartRateZones: HRZones(lthr: 168),
                          easyPace: EasyPaceSample(secondsPerKm: 360, heartRate: 140),
                          fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: 25 * 60))
        return PlanBuilder.build(i, history: h, timeZone: utc)
    }

    private func longRuns(_ p: TrainingPlan) -> [PlannedWorkout] {
        p.weeks.compactMap { $0.workouts.first { $0.kind == .long } }
    }

    func testThirtyKPlanHasNoMarathonAllowanceAndTheDefaultCap() throws {
        let r = build(distance: 30_000)
        let p = try XCTUnwrap(r.plan, "\(r.issues)")
        for l in longRuns(p) { XCTAssertLessThanOrEqual(l.durationSeconds, 150 * 60 + 1e-9) }
        XCTAssertTrue(p.guardrailReport.violations.isEmpty, "\(p.guardrailReport.violations.map(\.explanation))")
        XCTAssertTrue(p.guardrailReport.informationFlags.filter { $0.rule == .longRunShare }.isEmpty)
        for w in p.weeks {
            let total = w.workouts.reduce(0) { $0 + $1.durationSeconds }
            guard let l = w.workouts.first(where: { $0.kind == .long }), total > 0 else { continue }
            XCTAssertLessThanOrEqual(l.durationSeconds / total, GuardrailLimits.default.maxLongRunShare + 1e-9)
        }
    }

    func testThirtyKNotesDoNotCallTheRaceAMarathon() throws {
        // An anchor with no easy pace leaves no prediction; the note must not say marathon.
        let days: [PlanWeekday] = [.tuesday, .thursday, .saturday]
        let race = planMonday.addingTimeInterval(Double(15 * 7 + 6) * 86_400 + 8 * 3600)
        let i = PlanInput(raceDistanceMeters: 30_000, raceDate: race, goalSeconds: 9_000, startDate: planMonday,
                          trainingDays: Set(days), longRunDay: .saturday, recentWeeklySeconds: 240 * 60,
                          heartRateZones: HRZones(lthr: 168), easyPace: nil,
                          fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: 25 * 60))
        let r = PlanBuilder.build(i, history: [], timeZone: utc)
        let p = try XCTUnwrap(r.plan, "\(r.issues)")
        XCTAssertTrue(p.notes.contains { $0.contains("No race-time prediction is made for this distance") }, "\(p.notes)")
        XCTAssertFalse(p.notes.joined(separator: " ").lowercased().contains("marathon prediction"), "\(p.notes)")
        let m = PlanBuilder.build(PlanInput(raceDistanceMeters: Distance.marathon, raceDate: race, goalSeconds: 13_500, startDate: planMonday,
                          trainingDays: Set(days), longRunDay: .saturday, recentWeeklySeconds: 240 * 60,
                          heartRateZones: HRZones(lthr: 168), easyPace: nil,
                          fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: 25 * 60)),
                                  history: [], timeZone: utc)
        XCTAssertTrue(try XCTUnwrap(m.plan).notes.joined(separator: " ").contains("No marathon prediction"))
    }

    /// Anchor and easy pace, no predictedRaceSeconds and no goal: the race session
    /// length then shows which prediction path ran.
    private func plan(distance: Double) throws -> TrainingPlan {
        let days: [PlanWeekday] = [.tuesday, .thursday, .saturday]
        let race = planMonday.addingTimeInterval(Double(15 * 7 + 6) * 86_400 + 8 * 3600)
        let i = PlanInput(raceDistanceMeters: distance, raceDate: race, startDate: planMonday,
                          trainingDays: Set(days), longRunDay: .saturday, recentWeeklySeconds: 240 * 60,
                          heartRateZones: HRZones(lthr: 168), easyPace: EasyPaceSample(secondsPerKm: 360, heartRate: 140),
                          fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: 25 * 60))
        let r = PlanBuilder.build(i, history: [], timeZone: utc)
        return try XCTUnwrap(r.plan, "\(r.issues)")
    }

    private func raceSeconds(_ p: TrainingPlan) throws -> Double {
        try XCTUnwrap(p.workouts.first { $0.kind == .race }).durationSeconds
    }

    func testVickersVertosickRunsOnlyAtMarathonDistance() throws {
        let note = "No race-time prediction is made for this distance"
        for d in [25_000.0, 30_000, 41_900] {
            let p = try plan(distance: d)
            XCTAssertTrue(p.notes.contains { $0.contains(note) }, "\(d): \(p.notes)")
            XCTAssertFalse(p.notes.joined().contains("No marathon prediction"), "\(d)")
            XCTAssertEqual(try raceSeconds(p), d / 1000 * 360, accuracy: 1, "\(d)")
        }
        let m = try plan(distance: Distance.marathon)
        XCTAssertFalse(m.notes.joined().contains("No marathon prediction"), "\(m.notes)")
        XCTAssertFalse(m.notes.joined().contains(note))
        let miles = 240 * 60 / 360.0 * 1000 / Distance.mile
        let vv = try XCTUnwrap(VickersVertosick.marathonSeconds(raceMeters: Distance.fiveK, raceSeconds: 25 * 60,
                                                                weeklyMiles: miles))
        XCTAssertEqual(try raceSeconds(m), vv, accuracy: 1)
    }

    func testMarathonPlanKeepsTheExtraRoomAndTheCap() throws {
        for d in [Distance.marathon, 42_000] {
            let p = try XCTUnwrap(build(distance: d, weekly: 200).plan)
            XCTAssertTrue(p.guardrailReport.violations.isEmpty)
            XCTAssertTrue(longRuns(p).allSatisfy { $0.durationSeconds <= 180 * 60 + 1e-9 })
        }
    }

    func testJustUnderMarathonDistanceIsPlannedAsNonMarathon() throws {
        let p = try XCTUnwrap(build(distance: 41_900).plan)
        for l in longRuns(p) { XCTAssertLessThanOrEqual(l.durationSeconds, 150 * 60 + 1e-9) }
        XCTAssertTrue(p.guardrailReport.informationFlags.filter { $0.rule == .longRunShare }.isEmpty)
    }
}
