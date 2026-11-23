import XCTest
@testable import CoachCore

// #79: no drafted run, the long run included, is shorter than the builder's
// easy-run floor (`PlanHeuristics.minimumEasyRunSeconds`). A long run under
// the floor is raised to it when every long-run limit allows; otherwise the
// week goes without one and says why. Easy time too short for a run of its
// own is never left out silently.
// Synthetic runners and weeks only; no real runner's training is here.
final class PlanBuilderLongRunFloorTests: XCTestCase {
    private let utc = PlanFixture.utc
    private typealias F = PlanFixture
    private let floor = PlanHeuristics.minimumEasyRunSeconds

    /// Plan start: Monday of fixture week 8, at midnight.
    private var planMonday: Date { F.date(week: 8, day: 0, hour: 0) }

    /// Race on the Sunday of plan week `weeks - 1`, at 08:00.
    private func raceDate(weeks: Int) -> Date {
        planMonday.addingTimeInterval(Double((weeks - 1) * 7 + 6) * 86_400 + 8 * 3600)
    }

    /// `weeks` weeks of `minutes` a week before the plan over `days`. With a
    /// `longShare`, the long-run day takes that share as a long run and the
    /// other days split the rest; without one, every day is the same easy run.
    private func history(minutes: Double, weeks: Int, days: [PlanWeekday], longDay: PlanWeekday,
                         longShare: Double?) -> [PlannedWorkout] {
        var out: [PlannedWorkout] = []
        for k in 0..<weeks {
            for d in days {
                let isLong = longShare != nil && d == longDay
                let m = longShare.map { isLong ? minutes * $0 : minutes * (1 - $0) / Double(days.count - 1) }
                    ?? minutes / Double(days.count)
                out.append(F.workout("h\(k)-\(d.rawValue)", week: 8 - weeks + k, day: d.rawValue,
                                     isLong ? .long : .easy, minutes: m))
            }
        }
        return out
    }

    private func input(days: [PlanWeekday], longDay: PlanWeekday, weekly: Double, distance: Double,
                       weeks: Int, recentLong: Double?, maxSession: Double? = nil) -> PlanInput {
        PlanInput(raceDistanceMeters: distance, raceDate: raceDate(weeks: weeks), startDate: planMonday,
                  trainingDays: Set(days), longRunDay: longDay, maxSessionSeconds: maxSession.map { $0 * 60 },
                  recentWeeklySeconds: weekly * 60, recentLongRunSeconds: recentLong.map { $0 * 60 },
                  heartRateZones: HRZones(lthr: 168), easyPace: EasyPaceSample(secondsPerKm: 360, heartRate: 140),
                  fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: 25 * 60))
    }

    /// Training sessions (not the race) shorter than the floor.
    private func runsUnderTheFloor(_ p: TrainingPlan) -> [String] {
        p.workouts.filter { $0.kind != .race && $0.durationSeconds < floor - 1e-6 }
            .map { "\($0.id): \(Int($0.durationSeconds / 60)) min" }
    }

    private func shape(_ w: TrainingPlanWeek) -> String {
        w.workouts.map { x -> String in
            let tag = x.kind == .long ? "L" : x.kind == .easy ? "e" : x.kind == .race ? "R" : "q"
            return "\(tag)\(Int(x.durationSeconds / 60))"
        }.joined(separator: " ")
    }

    // MARK: The issue's case: the long run is raised to the floor

    /// Six days (Tuesday to Sunday), 4 weeks at 120 min with a 36-min
    /// Saturday long run, no recent long run given: week 0 is a recovery
    /// week whose long run (80% of 20 min) came out at 16 min (q29 e39 L16).
    /// 20 min fits its share, the spike allowance, the F3 step and the
    /// session cap, so it is raised to 20.
    func testSixDaysAt120MinutesRaisesTheLongRunToTheFloor() throws {
        let days: [PlanWeekday] = [.tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]
        let h = history(minutes: 120, weeks: 4, days: days, longDay: .saturday, longShare: 0.3)
        for distance in [Distance.fiveK, Distance.tenK, Distance.halfMarathon, Distance.marathon] {
            let i = input(days: days, longDay: .saturday, weekly: 120, distance: distance, weeks: 12, recentLong: nil)
            let r = PlanBuilder.build(i, history: h, timeZone: utc)
            let p = try XCTUnwrap(r.plan, "\(Int(distance)) m: \(r.issues)")
            XCTAssertEqual(runsUnderTheFloor(p), [], "\(Int(distance)) m")
            let week0 = p.weeks[0]
            XCTAssertTrue(week0.isRecoveryWeek)
            let long = try XCTUnwrap(week0.workouts.first { $0.kind == .long }, shape(week0))
            XCTAssertEqual(long.durationSeconds, floor, shape(week0))
            XCTAssertEqual(PlanWeekday(of: long.date, timeZone: utc), .saturday)
            XCTAssertLessThanOrEqual(long.durationSeconds, 0.33 * week0.trainingSeconds + 1e-6, shape(week0))
            // The raise takes its time from easy running: the week keeps its size.
            XCTAssertGreaterThanOrEqual(week0.trainingSeconds, 80 * 60, shape(week0))
            XCTAssertFalse(week0.workouts.contains { ($0.prescription?.purpose ?? "").contains("long run would be under") })
            // The guardrails and the 3.1 band still hold.
            let report = GuardrailChecker.check(history: h, planned: p.workouts, timeZone: utc)
            XCTAssertTrue(report.passed, "\(report.violations.map(\.explanation))")
            let share = try XCTUnwrap(week0.easyShare)
            XCTAssertTrue((0.75...0.85).contains(share), "\(share) \(shape(week0))")
        }
    }

    // MARK: A week too small for a long run at the floor skips it

    /// Five days, 4 weeks of equal 24-min runs: week 0 is a recovery week the
    /// spike rule holds to about 50 min, where 20 min would be over a third
    /// of the week (3.5 rule 5). It goes without a long run, and the easy run
    /// on the long run's day says why.
    func testAWeekTooSmallForTheFloorSkipsItsLongRunAndSaysWhy() throws {
        let days: [PlanWeekday] = [.monday, .tuesday, .thursday, .friday, .sunday]
        let h = history(minutes: 120, weeks: 4, days: days, longDay: .sunday, longShare: nil)
        let i = input(days: days, longDay: .sunday, weekly: 120, distance: Distance.fiveK, weeks: 10, recentLong: 24)
        let r = PlanBuilder.build(i, history: h, timeZone: utc)
        let p = try XCTUnwrap(r.plan, "\(r.issues)")
        XCTAssertEqual(runsUnderTheFloor(p), [])
        let week0 = p.weeks[0]
        XCTAssertFalse(week0.workouts.contains { $0.kind == .long }, shape(week0))
        XCTAssertGreaterThan(floor, 0.33 * week0.trainingSeconds, shape(week0))
        let onLongDay = try XCTUnwrap(week0.workouts.first { PlanWeekday(of: $0.date, timeZone: utc) == .sunday },
                                      shape(week0))
        XCTAssertEqual(onLongDay.kind, .easy)
        let purpose = onLongDay.prescription?.purpose ?? ""
        XCTAssertTrue(purpose.hasPrefix("Easy run in place of the long run"), purpose)
        XCTAssertTrue(purpose.contains("under \(Int(floor / 60)) min"), purpose)
        let report = GuardrailChecker.check(history: h, planned: p.workouts, timeZone: utc)
        XCTAssertTrue(report.passed, "\(report.violations.map(\.explanation))")
        // Later weeks with room for one still get a long run.
        XCTAssertTrue(p.weeks.dropFirst().contains { $0.workouts.contains { $0.kind == .long } })
    }

    // MARK: Easy time with no run of its own is never left out silently

    /// The same five days at 120 min for a marathon: week 0 holds a quality
    /// session and a 20-min long run, and the easy time left over is too
    /// short for a run, too much for the long run's share and the cool-down.
    /// The week says how much it left out.
    func testEasyTimeLeftOutIsStated() throws {
        let days: [PlanWeekday] = [.monday, .tuesday, .thursday, .friday, .sunday]
        let h = history(minutes: 120, weeks: 4, days: days, longDay: .sunday, longShare: nil)
        let i = input(days: days, longDay: .sunday, weekly: 120, distance: Distance.marathon, weeks: 10, recentLong: 24)
        let r = PlanBuilder.build(i, history: h, timeZone: utc)
        let p = try XCTUnwrap(r.plan, "\(r.issues)")
        XCTAssertEqual(runsUnderTheFloor(p), [])
        let week0 = p.weeks[0]
        let notes = week0.workouts.compactMap { $0.prescription?.purpose }.filter { $0.contains("leaves out") }
        XCTAssertEqual(notes.count, 1, shape(week0))
        let note = try XCTUnwrap(notes.first)
        XCTAssertTrue(note.contains("min of easy running: too little for a run of at least \(Int(floor / 60)) min"), note)
        let report = GuardrailChecker.check(history: h, planned: p.workouts, timeZone: utc)
        XCTAssertTrue(report.passed, "\(report.violations.map(\.explanation))")
    }

    // MARK: Plans whose total moves most against main

    /// The two inputs of a wider grid whose plan totals moved most against
    /// main (e197ae8), pinned so they can be reproduced: four weeks of equal
    /// easy runs, a 12-week plan. Six days at 180 min with a 45-min cap (5K)
    /// went from 1342 to 1019 min in all; seven days at 240 min (marathon)
    /// from 1654 to 2585. In both, week 0 or 2 on main was q25 e16 L19, and
    /// the new shape (q25 e35 or q37 L23) changes the longest recent run the
    /// spike rule measures later weeks against, and so where `composeWeek`
    /// settles them. Only the invariants are asserted here, not the totals.
    func testThePlansWhoseTotalsMovedMostStillHoldTheFloorAndGuardrails() throws {
        let all: [PlanWeekday] = [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]
        for (count, weekly, distance, maxSession) in [(6, 180.0, Distance.fiveK, 45.0 as Double?),
                                                     (7, 240.0, Distance.marathon, nil)] {
            let days = Array(all.prefix(count))
            let h = history(minutes: weekly, weeks: 4, days: days, longDay: days.last!, longShare: nil)
            let i = input(days: days, longDay: days.last!, weekly: weekly, distance: distance, weeks: 12,
                          recentLong: weekly / Double(count), maxSession: maxSession)
            let r = PlanBuilder.build(i, history: h, timeZone: utc)
            let p = try XCTUnwrap(r.plan, "\(r.issues)")
            assertHolds(p, input: i, history: h, label: "\(count) days, \(Int(weekly)) min")
        }
    }

    // MARK: Sweep: low weekly volumes × day counts

    private static let daySets: [[PlanWeekday]] = [
        [.tuesday, .thursday, .saturday],
        [.monday, .wednesday, .friday, .sunday],
        [.monday, .tuesday, .thursday, .friday, .sunday],
        [.tuesday, .wednesday, .thursday, .friday, .saturday, .sunday],
        [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]
    ]

    func testLowVolumeSweepDraftsNoRunUnderTheFloor() {
        var built = 0
        var builtByDays: [Int: Int] = [:]
        var weeksWithoutLongRun = 0
        var raisedLongRuns = 0
        for days in Self.daySets {
            let longDay = days.last!
            for weekly in stride(from: 90.0, through: 210, by: 15) {
                for distance in [Distance.fiveK, Distance.tenK, Distance.halfMarathon, Distance.marathon] {
                    // Even weeks of equal runs, weeks with a 30% long run,
                    // only two weeks of history, and none (the week held
                    // together on its own, `holdTogether`).
                    let cases: [(String, Int, Double?, Double?)] = [
                        ("even", 4, nil, weekly / Double(days.count)),
                        ("long", 4, 0.3, nil),
                        ("two", 2, nil, weekly / Double(days.count)),
                        ("none", 0, nil, nil)
                    ]
                    for (name, weeks, longShare, recentLong) in cases {
                        for maxSession in [nil, 45.0] as [Double?] {
                            let h = history(minutes: weekly, weeks: weeks, days: days, longDay: longDay,
                                            longShare: longShare)
                            let i = input(days: days, longDay: longDay, weekly: weekly, distance: distance, weeks: 10,
                                          recentLong: recentLong, maxSession: maxSession)
                            let label = "\(days.count) days, \(Int(weekly)) min, \(Int(distance)) m, \(name), max \(maxSession ?? 0)"
                            guard let p = PlanBuilder.build(i, history: h, timeZone: utc).plan else { continue }
                            built += 1
                            builtByDays[days.count, default: 0] += 1
                            assertHolds(p, input: i, history: h, label: label)
                            raisedLongRuns += p.workouts.filter { $0.kind == .long && $0.durationSeconds == floor }.count
                            weeksWithoutLongRun += p.weeks.filter { w in
                                !w.isRaceWeek && !w.workouts.contains { $0.kind == .long }
                            }.count
                        }
                    }
                }
            }
        }
        // The sweep is not vacuous: plans build at every day count, some long
        // runs sit at the floor and some weeks go without one.
        XCTAssertGreaterThan(built, 400)
        for days in Self.daySets { XCTAssertGreaterThan(builtByDays[days.count] ?? 0, 0, "\(days.count) days") }
        XCTAssertGreaterThan(weeksWithoutLongRun, 0)
        XCTAssertGreaterThan(raisedLongRuns, 0)
    }

    /// The floor and the guardrails a built plan keeps.
    private func assertHolds(_ p: TrainingPlan, input i: PlanInput, history h: [PlannedWorkout], label: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        // #79: no training run, in any week, under the floor.
        XCTAssertEqual(runsUnderTheFloor(p), [], label, file: file, line: line)
        // 3.5: the checker passes, run independently.
        let report = GuardrailChecker.check(history: h, planned: p.workouts, timeZone: utc)
        XCTAssertTrue(report.passed, "\(label): \(report.violations.map(\.explanation))", file: file, line: line)
        for w in p.weeks where !w.isRaceWeek {
            // 3.1 band, except an all-easy week 1 back (3.5 rule 4).
            if let share = w.easyShare, !(share == 1 && !w.workouts.contains { $0.kind.isQuality }) {
                XCTAssertTrue((0.75...0.85).contains(share), "\(label): week \(w.index) \(shape(w))", file: file, line: line)
            }
            XCTAssertLessThanOrEqual(w.workouts.filter { $0.kind == .long }.count, 1, label, file: file, line: line)
            // A week drafted without a long run says why.
            if !w.workouts.contains(where: { $0.kind == .long }) {
                XCTAssertTrue(w.workouts.contains { ($0.prescription?.purpose ?? "").contains("long run would be under") },
                              "\(label): week \(w.index) \(shape(w))", file: file, line: line)
            }
        }
        // F3: the long run grows at most 10 minutes over the longest so far,
        // and sits on the long-run day outside race week.
        var longest = i.recentLongRunSeconds ?? 0
        for w in p.workouts where w.kind == .long {
            if i.recentLongRunSeconds != nil {
                XCTAssertLessThanOrEqual(w.durationSeconds, longest + PlanHeuristics.longRunStepSeconds + 1e-6,
                                         "\(label): \(w.id)", file: file, line: line)
            }
            longest = max(longest, w.durationSeconds)
        }
        for w in p.workouts where w.kind != .race {
            XCTAssertTrue(i.trainingDays.contains(PlanWeekday(of: w.date, timeZone: utc)), "\(label): \(w.id)",
                          file: file, line: line)
            if let m = i.maxSessionSeconds {
                XCTAssertLessThanOrEqual(w.durationSeconds, m, "\(label): \(w.id)", file: file, line: line)
            }
        }
    }
}
