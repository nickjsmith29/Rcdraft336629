import XCTest
@testable import CoachCore

// #106 (from #79): the "This week leaves out N min of easy running" note
// counts only easy time that was left with no run of its own, and gives a
// reason only when it holds. The minutes a long run gives up to stay within
// its share of the week (3.5 rule 5) are long-run time, not easy running, and
// are no longer stated as such.
// Synthetic runners and weeks only; no real runner's training is here.
final class PlanBuilderLeftOutNoteTests: XCTestCase {
    private let utc = PlanFixture.utc
    private typealias F = PlanFixture
    private typealias Reason = PlanBuilder.LeftOutReason
    private let floor = PlanHeuristics.minimumEasyRunSeconds

    // MARK: The reason

    func testReasonByAmountAndFreeDay() {
        XCTAssertEqual(Reason.of(seconds: 60, freeDay: true), .tooShort)
        XCTAssertEqual(Reason.of(seconds: 60, freeDay: false), .tooShort)
        // Boundary: just under the floor is too short, the floor itself isn't.
        XCTAssertEqual(Reason.of(seconds: floor - 1, freeDay: true), .tooShort)
        XCTAssertEqual(Reason.of(seconds: floor, freeDay: true), .sessionCap)
        XCTAssertEqual(Reason.of(seconds: floor, freeDay: false), .noFreeDay)
        XCTAssertEqual(Reason.of(seconds: 3 * floor, freeDay: false), .noFreeDay)
    }

    func testReasonIsNilForNoTimeOrTimeThatIsNotFinite() {
        for s in [0, -60, Double.nan, .infinity, -.infinity] {
            XCTAssertNil(Reason.of(seconds: s, freeDay: true), "\(s)")
            XCTAssertNil(PlanBuilder.leftOutNote(seconds: s, freeDay: true), "\(s)")
        }
    }

    // MARK: The note's wording

    func testNoteUnderAMinuteIsNotGiven() {
        XCTAssertNil(PlanBuilder.leftOutNote(seconds: 59, freeDay: true))
        XCTAssertNotNil(PlanBuilder.leftOutNote(seconds: 60, freeDay: true))
    }

    func testTooShortNoteGivesTheFloorAsItsReason() throws {
        let note = try XCTUnwrap(PlanBuilder.leftOutNote(seconds: floor - 1, freeDay: true))
        XCTAssertEqual(note, "This week leaves out \(Int(floor / 60) - 1) min of easy running: too little for a run "
                       + "of at least \(Int(floor / 60)) min, the shortest run the plan schedules.")
    }

    /// Time at the floor or more could make a run of its own, so the note
    /// never says it is too little for one.
    func testNoteAtTheFloorOrMoreGivesTheReasonThatHolds() throws {
        let noDay = try XCTUnwrap(PlanBuilder.leftOutNote(seconds: floor, freeDay: false))
        XCTAssertEqual(noDay, "This week leaves out \(Int(floor / 60)) min of easy running: "
                       + "no training day is free for another run.")
        let cap = try XCTUnwrap(PlanBuilder.leftOutNote(seconds: floor + 300, freeDay: true))
        XCTAssertTrue(cap.hasPrefix("This week leaves out \(Int(floor / 60) + 5) min of easy running: "), cap)
        XCTAssertTrue(cap.contains("longest session"), cap)
        XCTAssertTrue(cap.contains("is under \(Int(floor / 60)) min"), cap)
        for note in [noDay, cap] { XCTAssertFalse(note.contains("too little"), note) }
    }

    // MARK: In built plans

    /// Plan start: Monday of fixture week 8, at midnight.
    private var planMonday: Date { F.date(week: 8, day: 0, hour: 0) }

    private func raceDate(weeks: Int) -> Date {
        planMonday.addingTimeInterval(Double((weeks - 1) * 7 + 6) * 86_400 + 8 * 3600)
    }

    /// `weeks` weeks of equal easy runs, `minutes` a week over `days`.
    private func history(minutes: Double, weeks: Int, days: [PlanWeekday]) -> [PlannedWorkout] {
        (0..<weeks).flatMap { k in
            days.map { d in
                F.workout("h\(k)-\(d.rawValue)", week: 8 - weeks + k, day: d.rawValue, .easy,
                          minutes: minutes / Double(days.count))
            }
        }
    }

    private func input(days: [PlanWeekday], weekly: Double, distance: Double, weeks: Int = 10,
                       maxSession: Double? = nil, limits: GuardrailLimits = .default) -> PlanInput {
        PlanInput(raceDistanceMeters: distance, raceDate: raceDate(weeks: weeks), startDate: planMonday,
                  trainingDays: Set(days), longRunDay: days.last!, maxSessionSeconds: maxSession.map { $0 * 60 },
                  recentWeeklySeconds: weekly * 60, recentLongRunSeconds: weekly / Double(days.count) * 60,
                  heartRateZones: HRZones(lthr: 168), easyPace: EasyPaceSample(secondsPerKm: 360, heartRate: 140),
                  fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: 25 * 60))
    }

    private func notes(_ w: TrainingPlanWeek) -> [String] {
        w.workouts.compactMap { $0.prescription?.purpose }.filter { $0.contains("leaves out") }
    }

    private func noteMinutes(_ note: String) -> Int? {
        guard let r = note.range(of: "leaves out ") else { return nil }
        return Int(note[r.upperBound...].prefix { $0.isNumber })
    }

    /// Three days at 120 min for a 5K: on main, week 2 (q35 e46 L41) said it
    /// left out "1 min" of easy running "too little for a run of at least 20
    /// min", though its easy run took all the easy time; the minute was the
    /// long run's share trim. It now carries no note, and the plan holds.
    func testALongRunShareTrimIsNotStatedAsEasyRunningLeftOut() throws {
        let days: [PlanWeekday] = [.tuesday, .thursday, .saturday]
        let h = history(minutes: 120, weeks: 4, days: days)
        let i = input(days: days, weekly: 120, distance: Distance.fiveK)
        let p = try XCTUnwrap(PlanBuilder.build(i, history: h, timeZone: utc).plan)
        for w in p.weeks { XCTAssertEqual(notes(w), [], "week \(w.index)") }
        XCTAssertNotNil(p.weeks[2].workouts.first { $0.kind == .long })
        let report = GuardrailChecker.check(history: h, planned: p.workouts, timeZone: utc)
        XCTAssertTrue(report.passed, "\(report.violations.map(\.explanation))")
    }

    /// A sweep of small and mid-size weeks, the spike rule on and off, two
    /// session caps: every note's reason fits its minutes, a week carries at
    /// most one, and race weeks are covered too. Notes are now rare; the
    /// bound is a heuristic chosen for this test (the issue's grid had about
    /// 2.4% of weeks noted, nearly all "1 min" or "2 min" share trims).
    func testEveryNoteInASweepGivesAReasonThatHolds() {
        let ruleOff = GuardrailLimits(maxSingleRunIncrease: .infinity)
        let daySets: [[PlanWeekday]] = [
            [.tuesday, .thursday, .saturday],
            [.monday, .tuesday, .thursday, .friday, .sunday],
            [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]
        ]
        var weeks = 0, noted = 0, built = 0
        for days in daySets {
            for weekly in stride(from: 90.0, through: 330, by: 30) {
                for distance in [Distance.fiveK, Distance.marathon] {
                    for maxSession in [nil, 45.0] as [Double?] {
                        for limits in [GuardrailLimits.default, ruleOff] {
                            let h = history(minutes: weekly, weeks: 4, days: days)
                            let i = input(days: days, weekly: weekly, distance: distance, maxSession: maxSession)
                            guard let p = PlanBuilder.build(i, history: h, timeZone: utc, limits: limits).plan
                            else { continue }
                            built += 1
                            for w in p.weeks {
                                weeks += 1
                                let ns = notes(w)
                                XCTAssertLessThanOrEqual(ns.count, 1, "\(days.count) days, \(weekly), week \(w.index)")
                                for n in ns {
                                    noted += 1
                                    guard let m = noteMinutes(n) else { XCTFail(n); continue }
                                    XCTAssertGreaterThan(m, 0, n)
                                    XCTAssertEqual(n.contains("too little for a run"), Double(m) * 60 < floor, n)
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(built, 100)
        XCTAssertLessThan(Double(noted), 0.005 * Double(weeks), "\(noted) of \(weeks) weeks noted")
    }
}
