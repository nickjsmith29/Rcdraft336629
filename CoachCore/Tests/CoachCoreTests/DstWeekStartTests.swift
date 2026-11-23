import XCTest
@testable import CoachCore

// Issues #14 and #24 (numbers in this repo): a week start must stay that
// Monday's first instant in zones where a Monday has no 00:00. Asia/Tehran
// moved its clocks forward at midnight on Monday 2021-03-22 (00:00 became
// 01:00), so that Monday's first instant is 01:00. Adding 7 * 86,400 seconds
// or 7 calendar days to that 01:00 would carry the 01:00 into every later
// week. Synthetic runners and runs only (SPEC 3.5, F3, F4).
final class DstWeekStartTests: XCTestCase {
    private let tehran = TimeZone(identifier: "Asia/Tehran")!
    private let london = TimeZone(identifier: "Europe/London")!
    private let newYork = TimeZone(identifier: "America/New_York")!
    typealias F = AdaptFixture

    private func cal(_ tz: TimeZone) -> Calendar { PlanCalendar.calendar(timeZone: tz) }

    /// The first instant of the given calendar day, independent of the code under test.
    private func firstInstant(_ y: Int, _ m: Int, _ d: Int, _ tz: TimeZone) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        let c0 = cal(tz)
        return c0.startOfDay(for: c0.date(from: c)!)
    }

    /// Tehran Mondays around the jump: 03-08, 03-15, 03-22 (the jump), 03-29, 04-05, 04-12.
    private var tehranMondays: [Date] {
        [(3, 8), (3, 15), (3, 22), (3, 29), (4, 5), (4, 12)].map { firstInstant(2021, $0.0, $0.1, tehran) }
    }

    // MARK: PlanCalendar

    func testTheJumpMondayHasNoMidnight() {
        let jump = firstInstant(2021, 3, 22, tehran)
        let c = cal(tehran)
        XCTAssertEqual(c.component(.hour, from: jump), 1, "the zone's 2021-03-22 starts at 01:00; if this fails the tzdata changed")
        XCTAssertEqual(c.component(.weekday, from: jump), 2)
    }

    func testNextWeekStartIsAlwaysTheMondaysFirstInstantAcrossTheJump() {
        let mondays = tehranMondays
        for i in 0..<(mondays.count - 1) {
            XCTAssertEqual(PlanCalendar.nextWeekStart(after: mondays[i], timeZone: tehran), mondays[i + 1], "after Monday #\(i)")
        }
        // Chaining from the jump Monday's 01:00 does not carry the 01:00 forward.
        var w = mondays[2]
        for k in 3..<mondays.count {
            w = PlanCalendar.nextWeekStart(after: w, timeZone: tehran)
            XCTAssertEqual(w, mondays[k])
            XCTAssertEqual(cal(tehran).component(.hour, from: w), 0)
        }
    }

    func testWeekStartWeeksForwardAndBackwardAcrossTheJump() {
        let mondays = tehranMondays
        for from in 0..<mondays.count {
            for to in 0..<mondays.count {
                XCTAssertEqual(PlanCalendar.weekStart(weeks: to - from, after: mondays[from], timeZone: tehran), mondays[to],
                               "from #\(from) by \(to - from)")
            }
        }
        XCTAssertEqual(PlanCalendar.weekStart(weeks: 0, after: mondays[3], timeZone: tehran), mondays[3])
        // A drifted 01:00 input on an ordinary Monday is normalized too.
        let drifted = mondays[3].addingTimeInterval(3600)
        XCTAssertEqual(PlanCalendar.weekStart(weeks: 0, after: drifted, timeZone: tehran), mondays[3])
        XCTAssertEqual(PlanCalendar.weekStart(weeks: 1, after: drifted, timeZone: tehran), mondays[4])
        XCTAssertEqual(PlanCalendar.weekStart(weeks: -1, after: drifted, timeZone: tehran), mondays[2])
    }

    func testWeekStartContainingOnAndAroundTheJumpMonday() {
        let mondays = tehranMondays
        let c = cal(tehran)
        let jump = mondays[2]
        XCTAssertEqual(PlanCalendar.weekStart(containing: jump, timeZone: tehran), jump)
        XCTAssertEqual(PlanCalendar.weekStart(containing: jump.addingTimeInterval(12 * 3600), timeZone: tehran), jump)
        // Every day of that week, and the Sunday evening before it, group correctly.
        for d in 0..<7 {
            let day = c.date(byAdding: .day, value: d, to: jump)!.addingTimeInterval(10 * 3600)
            XCTAssertEqual(PlanCalendar.weekStart(containing: day, timeZone: tehran), jump, "day \(d)")
        }
        XCTAssertEqual(PlanCalendar.weekStart(containing: jump.addingTimeInterval(-1), timeZone: tehran), mondays[1])
        XCTAssertEqual(PlanCalendar.weekStart(containing: mondays[3].addingTimeInterval(-1), timeZone: tehran), jump)
    }

    func testWeekGroupingAcrossTheJumpHasNoGapsOrOverlaps() {
        let mondays = tehranMondays
        let workouts = mondays.enumerated().map { i, m in
            PlannedWorkout(id: "w\(i)", date: m.addingTimeInterval(8 * 3600), kind: .easy, durationSeconds: 1800)
        }
        let weeks = PlanWeek.weeks(from: workouts, timeZone: tehran)
        XCTAssertEqual(weeks.map(\.weekStart), mondays)
        XCTAssertEqual(weeks.map { $0.workouts.count }, Array(repeating: 1, count: mondays.count))
        for i in 1..<weeks.count { XCTAssertEqual(weeks[i - 1].weekEnd, weeks[i].weekStart) }
    }

    func testControlZonesStayOnMidnight() {
        for tz in [london, newYork] {
            // Weeks spanning both 2021 clock changes.
            var w = firstInstant(2021, 3, 1, tz)
            for k in 0..<30 {
                XCTAssertEqual(cal(tz).component(.hour, from: w), 0, "\(tz.identifier) week \(k)")
                XCTAssertEqual(cal(tz).component(.weekday, from: w), 2)
                let next = PlanCalendar.nextWeekStart(after: w, timeZone: tz)
                XCTAssertEqual(PlanCalendar.weekStart(weeks: 1, after: w, timeZone: tz), next)
                XCTAssertEqual(PlanCalendar.weekStart(weeks: -1, after: next, timeZone: tz), w)
                XCTAssertEqual(PlanCalendar.weekStart(containing: next.addingTimeInterval(-1), timeZone: tz), w)
                w = next
            }
        }
        // London's 2021-03-28 change is on a Sunday: the week is 167 hours.
        let mon = firstInstant(2021, 3, 22, london)
        XCTAssertEqual(PlanCalendar.nextWeekStart(after: mon, timeZone: london).timeIntervalSince(mon), 167 * 3600)
    }

    // MARK: PlanBuilder across the jump

    private func planInput(start: Date, race: Date) -> PlanInput {
        let lthr = 165.0, five = 24.0 * 60
        return PlanInput(raceDistanceMeters: Distance.tenK, raceDate: race, goalSeconds: nil, startDate: start,
                         trainingDays: [.monday, .wednesday, .friday, .sunday], longRunDay: .sunday, maxSessionSeconds: nil,
                         recentWeeklySeconds: 240 * 60, recentLongRunSeconds: 80 * 60,
                         heartRateZones: HRZones(lthr: lthr)!,
                         easyPace: EasyPaceSample(secondsPerKm: 360, heartRate: 138),
                         fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: five),
                         predictedRaceSeconds: RacePredictor.riegel(knownMeters: Distance.fiveK, knownSeconds: five,
                                                                    targetMeters: Distance.tenK))
    }

    func testPlanSpanningTheJumpKeepsTheRaceInItsOwnWeek() throws {
        // 12 weeks from Monday 2021-01-18; week 9 is the jump Monday 03-22 and
        // the race is on Sunday 2021-04-11 08:00, in week 11 (03-05 + ... 04-05).
        let c = cal(tehran)
        let start = firstInstant(2021, 1, 18, tehran)
        let raceDay = firstInstant(2021, 4, 11, tehran)
        let race = c.date(bySettingHour: 8, minute: 0, second: 0, of: raceDay)!
        let result = PlanBuilder.build(planInput(start: start, race: race), timeZone: tehran)
        let plan = try XCTUnwrap(result.plan, "\(result.issues)")
        XCTAssertEqual(plan.weeks.count, 12)
        XCTAssertEqual(plan.weeks[9].weekStart, firstInstant(2021, 3, 22, tehran))
        XCTAssertEqual(plan.weeks[10].weekStart, firstInstant(2021, 3, 29, tehran))
        XCTAssertEqual(plan.weeks[11].weekStart, firstInstant(2021, 4, 5, tehran))
        for w in plan.weeks {
            XCTAssertEqual(PlanCalendar.weekStart(containing: w.weekStart, timeZone: tehran), w.weekStart, "week \(w.index)")
            XCTAssertEqual(w.weekStart, c.startOfDay(for: w.weekStart))
        }
        let last = try XCTUnwrap(plan.weeks.last)
        XCTAssertTrue(last.isRaceWeek)
        XCTAssertGreaterThan(last.workouts.count, 1, "the last week has its own sessions, not just the race")
        XCTAssertEqual(last.workouts.last?.kind, .race)
        XCTAssertEqual(last.workouts.last?.date, race)
        XCTAssertEqual(plan.weeks.filter(\.isRaceWeek).count, 1)
        XCTAssertFalse(plan.weeks[10].isRaceWeek)
        XCTAssertEqual(plan.workouts.filter { $0.kind == .race }.count, 1)
    }

    func testControlPlanInLondonAndNewYork() throws {
        for tz in [london, newYork] {
            let c = cal(tz)
            let start = firstInstant(2021, 1, 18, tz)
            let race = c.date(bySettingHour: 8, minute: 0, second: 0, of: firstInstant(2021, 4, 11, tz))!
            let plan = try XCTUnwrap(PlanBuilder.build(planInput(start: start, race: race), timeZone: tz).plan)
            XCTAssertEqual(plan.weeks.count, 12, tz.identifier)
            XCTAssertTrue(plan.weeks.last!.isRaceWeek)
            XCTAssertGreaterThan(plan.weeks.last!.workouts.count, 1)
        }
    }

    // MARK: GuardrailRepair and the adaptation engine across the jump

    /// A synthetic session placed `day` days after Tehran week `week` (week 0 is Monday 2021-03-08).
    private func tehranSession(_ base: PlannedWorkout, week: Int, day: Int, hour: Int = 7) -> PlannedWorkout {
        let monday = tehranMondays[week]
        let c = cal(tehran)
        let d = c.startOfDay(for: c.date(byAdding: .day, value: day, to: monday)!)
        return PlannedWorkout(id: base.id, date: d.addingTimeInterval(Double(hour) * 3600), kind: base.kind,
                              durationSeconds: base.durationSeconds, prescription: base.prescription)
    }

    private func tehranContext() -> AdaptationContext {
        AdaptationContext(zones: F.zones, timeZone: tehran, tracksPain: false, limits: .default)
    }

    private func easyT(_ id: String, week: Int, day: Int, minutes: Double, hour: Int = 7) -> PlannedWorkout {
        tehranSession(F.easy(id, week: 0, day: 0, minutes: minutes), week: week, day: day, hour: hour)
    }

    private func longT(_ id: String, week: Int, day: Int, minutes: Double) -> PlannedWorkout {
        tehranSession(F.long(id, week: 0, day: 0, minutes: minutes), week: week, day: day)
    }

    /// Weeks 0 to 2 (03-08, 03-15 and the jump week 03-22) of four 50-minute runs.
    private func buildWeeksHistory(done: Double) -> [PlannedWorkout] {
        (0..<3).flatMap { wk in (0..<4).map { easyT("h\(wk)-\($0)", week: wk, day: $0 * 2, minutes: 50) } }
            + [easyT("d1", week: 3, day: 0, minutes: done / 2), easyT("d2", week: 3, day: 1, minutes: done / 2)]
    }

    func testWeekVolumeFindsEveryWeekAfterTheJump() {
        let ctx = tehranContext()
        let history = buildWeeksHistory(done: 150)
        let mondays = tehranMondays
        XCTAssertEqual(GuardrailRepair.weekVolume(mondays[2], history, ctx), 200 * 60)
        XCTAssertEqual(GuardrailRepair.weekVolume(mondays[3], history, ctx), 150 * 60)
        // The helper's steps land on the same keys.
        XCTAssertEqual(GuardrailRepair.weekVolume(PlanCalendar.weekStart(weeks: 1, after: mondays[2], timeZone: tehran), history, ctx), 150 * 60)
        XCTAssertEqual(GuardrailRepair.weekVolume(PlanCalendar.weekStart(weeks: -1, after: mondays[3], timeZone: tehran), history, ctx), 200 * 60)
        XCTAssertEqual(GuardrailRepair.weekVolume(PlanCalendar.weekStart(weeks: -2, after: mondays[3], timeZone: tehran), history, ctx), 200 * 60)
    }

    /// The recovery-cadence repair of `GuardrailRepairRecoveryFloorTests`, with
    /// the build weeks straddling the jump: week 3 (03-29) follows the jump
    /// week, and stepping back from the 01:00 jump Monday used to miss week 1.
    func testRecoveryWeekRepairSeesItsCandidateAfterTheJump() throws {
        let ctx = tehranContext()
        let history = buildWeeksHistory(done: 150)
        let plan = [longT("l1", week: 3, day: 5, minutes: 20)]
        let asOf = tehranSession(F.easy("x", week: 0, day: 0, minutes: 1), week: 3, day: 3, hour: 6).date
        let before = GuardrailChecker.check(history: history, planned: plan, timeZone: tehran, limits: ctx.guardrails,
                                            freezes: [], units: ctx.units)
        XCTAssertEqual(before.violations.map(\.rule), [.recoveryWeek])
        let r = GuardrailRepair.repair(plan: plan, history: history, asOf: asOf, freezes: [], context: ctx)
        XCTAssertTrue(r.report.passed, "\(r.report.violations.map(\.explanation))")
        XCTAssertTrue(r.plan.isEmpty)
        let drop = try XCTUnwrap(r.changes.first)
        XCTAssertEqual(drop.kind, .sessionDropped)
        XCTAssertEqual(drop.workoutIDs, ["l1"])
    }

    /// A volume hold started in the jump week keeps the level of the week
    /// before it (week 1, 03-15). The jump week's own start is 01:00, and
    /// stepping back from it by a plain 7 days gave 03-15 01:00, a week that
    /// holds no sessions, so the level fell to the jump week's lower volume.
    func testVolumeHoldInTheJumpWeekUsesThePreviousWeekLevel() {
        let ctx = tehranContext()
        func week(_ w: Int, easy: (Double, Double), long: Double) -> [PlannedWorkout] {
            [tehranSession(F.threshold("t\(w)", week: 0, day: 0), week: w, day: 1),
             easyT("e\(w)a", week: w, day: 3, minutes: easy.0),
             longT("l\(w)", week: w, day: 5, minutes: long),
             easyT("e\(w)b", week: w, day: 6, minutes: easy.1)]
        }
        // Week 1 (03-15): 214 min. Week 2 (jump, 03-22): 214 - 40 = 174 min. Week 3 (03-29): 214 min.
        let plan = week(1, easy: (55, 45), long: 60) + week(2, easy: (40, 30), long: 50) + week(3, easy: (62, 50), long: 60)
        var d = F.Driver(plan: plan, context: ctx)
        let behind: [String: F.RunSpec] = ["t1": F.RunSpec(pace: 1.04), "t2": F.RunSpec(hr: .high)]
        d.follow(until: tehranSession(F.easy("x", week: 0, day: 0, minutes: 1), week: 2, day: 2, hour: 23).date) {
            behind[$0.id] ?? F.RunSpec()
        }
        XCTAssertEqual(d.changes.filter { $0.kind == .volumeHeld }.count, 1)
        let hold = d.state.holds.first
        XCTAssertEqual(hold?.level, 214 * 60, "the higher of the jump week and the week before it")
        // The held week after the jump is cut back to the level, and still found by its week start.
        let w3 = GuardrailRepair.weekVolume(tehranMondays[3], d.history + d.plan, ctx) ?? 0
        XCTAssertLessThanOrEqual(w3, 214 * 60 + 1e-6)
        XCTAssertGreaterThan(w3, 0)
    }
}
