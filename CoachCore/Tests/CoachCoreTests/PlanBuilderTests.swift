import XCTest
@testable import CoachCore

// Synthetic runners only: every heart rate, pace and volume below is made up
// to cover a range of profiles, and stands for no real person.
private struct SyntheticRunner {
    let name: String
    let weeklyMinutes: Double
    let longMinutes: Double
    let days: Set<PlanWeekday>
    let longDay: PlanWeekday
    let maxSessionMinutes: Double?
    let lthr: Double
    /// 5K time in minutes, the fitness anchor.
    let fiveKMinutes: Double
    let easyPaceSecondsPerKm: Double
    let easyHR: Double

    static let all: [SyntheticRunner] = [
        SyntheticRunner(name: "low-3day", weeklyMinutes: 150, longMinutes: 55, days: [.tuesday, .thursday, .saturday],
                        longDay: .saturday, maxSessionMinutes: 90, lthr: 172, fiveKMinutes: 30,
                        easyPaceSecondsPerKm: 420, easyHR: 140),
        SyntheticRunner(name: "mid-4day", weeklyMinutes: 240, longMinutes: 80, days: [.monday, .wednesday, .friday, .sunday],
                        longDay: .sunday, maxSessionMinutes: nil, lthr: 165, fiveKMinutes: 24,
                        easyPaceSecondsPerKm: 360, easyHR: 138),
        SyntheticRunner(name: "mid-5day", weeklyMinutes: 300, longMinutes: 95,
                        days: [.tuesday, .wednesday, .thursday, .saturday, .sunday],
                        longDay: .sunday, maxSessionMinutes: 120, lthr: 158, fiveKMinutes: 22,
                        easyPaceSecondsPerKm: 345, easyHR: 132),
        SyntheticRunner(name: "high-6day", weeklyMinutes: 450, longMinutes: 130,
                        days: [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday],
                        longDay: .saturday, maxSessionMinutes: nil, lthr: 176, fiveKMinutes: 18.5,
                        easyPaceSecondsPerKm: 300, easyHR: 145),
        SyntheticRunner(name: "high-3day", weeklyMinutes: 330, longMinutes: 115, days: [.monday, .wednesday, .saturday],
                        longDay: .saturday, maxSessionMinutes: 150, lthr: 168, fiveKMinutes: 21,
                        easyPaceSecondsPerKm: 330, easyHR: 136),
        SyntheticRunner(name: "low-6day", weeklyMinutes: 180, longMinutes: 50,
                        days: [.monday, .tuesday, .wednesday, .thursday, .friday, .sunday],
                        longDay: .sunday, maxSessionMinutes: 60, lthr: 162, fiveKMinutes: 27,
                        easyPaceSecondsPerKm: 400, easyHR: 135),
        // Long runs away from the weekend.
        SyntheticRunner(name: "mid-4day-wed-long", weeklyMinutes: 260, longMinutes: 85,
                        days: [.monday, .wednesday, .friday, .saturday],
                        longDay: .wednesday, maxSessionMinutes: 110, lthr: 170, fiveKMinutes: 23,
                        easyPaceSecondsPerKm: 350, easyHR: 140),
        SyntheticRunner(name: "mid-5day-thu-long", weeklyMinutes: 320, longMinutes: 100,
                        days: [.monday, .tuesday, .thursday, .friday, .sunday],
                        longDay: .thursday, maxSessionMinutes: nil, lthr: 160, fiveKMinutes: 21.5,
                        easyPaceSecondsPerKm: 340, easyHR: 133)
    ]

    var zones: HRZones { HRZones(lthr: lthr)! }
}

final class PlanBuilderTests: XCTestCase {
    private let utc = PlanFixture.utc
    private let distances: [Double] = [Distance.fiveK, Distance.tenK, Distance.halfMarathon, Distance.marathon]

    /// Monday 2026-03-02 00:00 UTC, eight weeks after `PlanFixture.firstMonday`.
    private var planMonday: Date { PlanFixture.date(week: 8, day: 0, hour: 0) }

    private func cal(_ tz: TimeZone) -> Calendar { PlanCalendar.calendar(timeZone: tz) }

    /// Race in plan week `weeks - 1` on `weekday` (Sunday by default), 08:00.
    private func raceDate(weeks: Int, from monday: Date, tz: TimeZone, weekday: PlanWeekday = .sunday) -> Date {
        let day = cal(tz).date(byAdding: .day, value: (weeks - 1) * 7 + weekday.rawValue, to: monday)!
        return cal(tz).date(bySettingHour: 8, minute: 0, second: 0, of: day)!
    }

    /// History: `multipliers.count` weeks before `monday`, the last entry being
    /// the week just before the plan.
    private func history(_ r: SyntheticRunner, before monday: Date, multipliers: [Double], tz: TimeZone) -> [PlannedWorkout] {
        var out: [PlannedWorkout] = []
        let days = r.days.sorted()
        for (k, m) in multipliers.enumerated() {
            let weekOffset = k - multipliers.count
            let total = r.weeklyMinutes * m
            guard total > 0 else { continue }
            let long = min(r.longMinutes * m, total * 0.33)
            let others = days.filter { $0 != r.longDay }
            for d in days {
                let minutes = d == r.longDay ? long : (total - long) / Double(others.count)
                let day = cal(tz).date(byAdding: .day, value: weekOffset * 7 + d.rawValue, to: monday)!
                let date = cal(tz).date(bySettingHour: 7, minute: 0, second: 0, of: day)!
                out.append(PlannedWorkout(id: "h\(k)-\(d.rawValue)", date: date, kind: d == r.longDay ? .long : .easy,
                                          durationSeconds: minutes * 60))
            }
        }
        return out
    }

    /// Mean of the last 4 history weeks, as the baseline would report it (1 with no history).
    private static func recentScale(_ shape: [Double]) -> Double {
        shape.isEmpty ? 1 : shape.suffix(4).reduce(0, +) / Double(min(4, shape.count))
    }

    private func input(_ r: SyntheticRunner, distance: Double, start: Date, race: Date,
                       goal: Double? = nil, anchor: Bool = true, recentScale: Double = 1) -> PlanInput {
        let five = r.fiveKMinutes * 60
        var predicted: Double?
        if anchor {
            if distance > Distance.halfMarathon * 1.01 {
                predicted = VickersVertosick.marathonSeconds(raceMeters: Distance.fiveK, raceSeconds: five,
                                                             weeklyMiles: r.weeklyMinutes / (r.easyPaceSecondsPerKm / 60) / 1.609)
            } else {
                predicted = RacePredictor.riegel(knownMeters: Distance.fiveK, knownSeconds: five, targetMeters: distance)
            }
        }
        return PlanInput(raceDistanceMeters: distance, raceDate: race, goalSeconds: goal, startDate: start,
                         trainingDays: r.days, longRunDay: r.longDay, maxSessionSeconds: r.maxSessionMinutes.map { $0 * 60 },
                         recentWeeklySeconds: r.weeklyMinutes * 60 * recentScale, recentLongRunSeconds: r.longMinutes * 60,
                         heartRateZones: r.zones,
                         easyPace: EasyPaceSample(secondsPerKm: r.easyPaceSecondsPerKm, heartRate: r.easyHR),
                         fitnessAnchor: anchor ? RaceEquivalent(distanceMeters: Distance.fiveK, seconds: five) : nil,
                         predictedRaceSeconds: predicted)
    }

    // MARK: Invariants every plan must meet

    private func assertValid(_ plan: TrainingPlan, input: PlanInput, history: [PlannedWorkout], tz: TimeZone,
                             limits: GuardrailLimits = .default, label: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let workouts = plan.workouts
        // F3 acceptance 1: the guardrail checker passes (run independently here).
        let report = GuardrailChecker.check(history: history, planned: workouts, timeZone: tz, limits: limits)
        XCTAssertTrue(report.passed, "\(label): \(report.violations.map(\.explanation))", file: file, line: line)

        // F3 acceptance 2: easy share 75 to 85% of training time in every
        // training week (race week is left out: see TrainingPlanWeek.easyShare).
        // The one exception is week 1 back after a short break, which is all
        // easy (3.5 rule 4, #62): the plan's first week, or, in a provisional
        // plan, any week the open start week could leave as week 1 back.
        for w in plan.weeks where !w.isRaceWeek {
            guard let share = w.easyShare else {
                XCTFail("\(label): week \(w.index) has no training", file: file, line: line); continue
            }
            if (w.index == 0 || plan.isProvisional) && share == 1 && !w.workouts.contains(where: { $0.kind.isQuality }) { continue }
            XCTAssertTrue((0.75...0.85).contains(share), "\(label): week \(w.index) easy share \(share)", file: file, line: line)
        }

        // Phases in order, ending with the race.
        let order: [PlanPhase] = [.base, .build, .peak, .taper]
        let ranks = plan.weeks.map { order.firstIndex(of: $0.phase)! }
        XCTAssertEqual(ranks, ranks.sorted(), "\(label): phases out of order", file: file, line: line)
        XCTAssertEqual(plan.weeks.last?.phase, .taper, label, file: file, line: line)
        XCTAssertTrue(plan.weeks.contains { $0.phase == .peak }, label, file: file, line: line)
        XCTAssertEqual(workouts.last?.kind, .race, label, file: file, line: line)
        XCTAssertEqual(workouts.filter { $0.kind == .race }.count, 1, label, file: file, line: line)
        XCTAssertEqual(workouts.last?.date, input.raceDate, label, file: file, line: line)
        XCTAssertTrue(workouts.allSatisfy { $0.date >= input.startDate }, label, file: file, line: line)

        // F3 heuristic: the long run grows at most 10 minutes over the longest so far.
        var longest = input.recentLongRunSeconds ?? 0
        for w in workouts where w.kind == .long {
            XCTAssertLessThanOrEqual(w.durationSeconds, longest + PlanHeuristics.longRunStepSeconds + 1e-6,
                                     "\(label): \(w.id)", file: file, line: line)
            longest = max(longest, w.durationSeconds)
        }

        let c = cal(tz)
        var lastHardDay: Date? = history.filter { $0.date < input.startDate && ($0.kind.isQuality || $0.kind == .race) }
            .map { c.startOfDay(for: $0.date) }.max()
        for w in workouts {
            // F3: purpose, targets, duration and the rule behind it.
            guard let p = w.prescription else { XCTFail("\(label): \(w.id) has no prescription", file: file, line: line); continue }
            XCTAssertFalse(p.purpose.isEmpty, label, file: file, line: line)
            XCTAssertFalse(p.rules.isEmpty, label, file: file, line: line)
            XCTAssertFalse(p.segments.isEmpty, label, file: file, line: line)
            XCTAssertEqual(p.durationSeconds, w.durationSeconds, accuracy: 1e-6, label, file: file, line: line)
            XCTAssertTrue(p.segments.allSatisfy { $0.durationSeconds > 0 }, "\(label): \(w.id)", file: file, line: line)
            for s in p.segments {
                let hr = s.target.heartRate
                XCTAssertTrue(hr.floorBPM != nil || hr.ceilingBPM != nil, label, file: file, line: line)
                if let lo = hr.floorBPM, let hi = hr.ceilingBPM { XCTAssertLessThan(lo, hi, label, file: file, line: line) }
                if s.intensity.isBelowAerobicThreshold {
                    XCTAssertLessThanOrEqual(hr.ceilingBPM!, input.heartRateZones!.easyCeiling, label, file: file, line: line)
                }
            }
            if w.kind != .race {
                XCTAssertTrue(input.trainingDays.contains(PlanWeekday(of: w.date, timeZone: tz)), "\(label): \(w.id) off-day",
                              file: file, line: line)
                if let m = input.maxSessionSeconds {
                    XCTAssertLessThanOrEqual(w.durationSeconds, m, "\(label): \(w.id)", file: file, line: line)
                }
            }
            if w.kind == .long {
                let toRace = c.dateComponents([.day], from: c.startOfDay(for: w.date), to: c.startOfDay(for: input.raceDate)).day ?? 0
                if toRace >= 7 {
                    XCTAssertEqual(PlanWeekday(of: w.date, timeZone: tz), input.longRunDay, label, file: file, line: line)
                } else {
                    XCTAssertGreaterThanOrEqual(toRace, 3, "\(label): long run \(toRace) days before the race", file: file, line: line)
                }
            }
            // F4: never two hard days in a row (races and quality), across weeks too.
            if w.kind.isQuality || w.kind == .race {
                let day = c.startOfDay(for: w.date)
                if let prev = lastHardDay {
                    let gap = c.dateComponents([.day], from: prev, to: day).day ?? 0
                    XCTAssertGreaterThanOrEqual(gap, 2, "\(label): hard days \(prev) and \(day)", file: file, line: line)
                }
                lastHardDay = day
            }
        }
    }

    // MARK: The grid: 4 distances × 8 runners × lead times × history shapes × race weekdays

    private static let shapes: [(String, [Double])] = [
        ("steady", [1, 1, 1, 1, 1, 1, 1, 1]),
        ("recent-recovery", [1, 1, 1, 1, 1, 1, 0.72, 1]),
        ("rising", [0.85, 0.9, 0.95, 0.7, 0.9, 0.95, 1.0, 1.0]),
        ("none", []),
        ("zero-week", [1, 1, 1, 1, 1, 1, 1, 0]),
        ("short-week", [1, 1, 1, 1, 1, 1, 1, 0.3]),
        ("break-then-return", [1, 1, 1, 1, 0, 0, 1, 1])
    ]

    func testEveryGeneratedPlanPassesGuardrailsAndEasyShare() {
        var built = 0
        var countsByDistance: [Double: Int] = [:]
        var combo = 0
        for d in distances {
            let category = RaceCategory(meters: d)!
            let leadTimes = [PlanHeuristics.minimumWeeks(category), 12, 18, 30]
            for r in SyntheticRunner.all {
                for weeks in leadTimes {
                    for (shapeName, shape) in Self.shapes {
                        combo += 1
                        // Race weekdays rotate through the week, Monday to Sunday.
                        let weekday = PlanWeekday(rawValue: combo % 7)!
                        let h = history(r, before: planMonday, multipliers: shape, tz: utc)
                        let i = input(r, distance: d, start: planMonday,
                                      race: raceDate(weeks: weeks, from: planMonday, tz: utc, weekday: weekday),
                                      recentScale: Self.recentScale(shape))
                        let label = "\(r.name) \(Int(d))m \(weeks)w \(shapeName) race \(weekday)"
                        switch PlanBuilder.build(i, history: h, timeZone: utc) {
                        case .plan(let plan):
                            built += 1
                            countsByDistance[d, default: 0] += 1
                            XCTAssertEqual(plan.weeks.count, weeks, label)
                            assertValid(plan, input: i, history: h, tz: utc, label: label)
                        case .cannotBuild(let issues):
                            XCTAssertEqual(issues.count, 1, label)
                            switch issues.first {
                            case .volumeTooLowForRace?:
                                // A race too long for the volume the guardrails let the plan reach:
                                // a marathon, or a short-lead half right after an empty or short week.
                                XCTAssertTrue(d == Distance.marathon || (d == Distance.halfMarathon && shapeName != "steady"
                                                                         && shapeName != "rising" && shapeName != "none"),
                                              "\(label): \(issues)")
                            case .recentVolumeTooLow?:
                                // Two weeks off halve the 4-week mean of the lowest runner.
                                XCTAssertEqual(shapeName, "break-then-return", "\(label): \(issues)")
                                XCTAssertEqual(r.name, "low-3day", label)
                            case .noWorkableWeek?:
                                // Right after a break the rolling 4-week rule leaves too little room.
                                XCTAssertEqual(shapeName, "break-then-return", "\(label): \(issues)")
                            default:
                                XCTFail("\(label): \(issues)")
                            }
                        }
                    }
                }
            }
        }
        // Every 5K, 10K and half plan is built except some right after a break; most marathons too.
        let perDistance = SyntheticRunner.all.count * 4 * Self.shapes.count
        let breakCases = SyntheticRunner.all.count * 4
        for d in [Distance.fiveK, Distance.tenK] {
            XCTAssertGreaterThanOrEqual(countsByDistance[d] ?? 0, perDistance - breakCases, "\(d)")
        }
        for d in [Distance.halfMarathon] {
            XCTAssertGreaterThanOrEqual(countsByDistance[d] ?? 0, perDistance - breakCases, "\(d)")
        }
        XCTAssertGreaterThan(countsByDistance[Distance.marathon] ?? 0, perDistance / 2)
        XCTAssertGreaterThan(built, 3 * (perDistance - breakCases))
    }

    func testMidWeekStartsAndOtherTimeZones() throws {
        let ny = TimeZone(identifier: "America/New_York")!
        // Monday 2026-02-23 in New York; the plan crosses the March DST change.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 2; comps.day = 23
        let monday = cal(ny).date(from: comps)!
        let wednesday = cal(ny).date(byAdding: .day, value: 2, to: monday)!.addingTimeInterval(9 * 3600)
        let nextMonday = PlanCalendar.nextWeekStart(after: monday, timeZone: ny)
        for d in distances {
            for r in SyntheticRunner.all {
                let h = history(r, before: nextMonday, multipliers: [1, 1, 0.75, 1, 1, 1], tz: ny)
                    .filter { $0.date < wednesday }
                let i = input(r, distance: d, start: wednesday, race: raceDate(weeks: 16, from: nextMonday, tz: ny))
                let label = "ny \(r.name) \(Int(d))"
                let result = PlanBuilder.build(i, history: h, timeZone: ny)
                guard let plan = result.plan else {
                    // Only a marathon may be refused, and only for being too long for the volume.
                    XCTAssertEqual(d, Distance.marathon, "\(label): \(result.issues)")
                    XCTAssertTrue(Self.isVolumeTooLow(result.issues), "\(label): \(result.issues)")
                    continue
                }
                XCTAssertEqual(plan.weeks.first?.weekStart, nextMonday, label)
                XCTAssertEqual(plan.weeks.count, 16, label)
                XCTAssertTrue(plan.notes.contains { $0.contains("starts on Monday") }, label)
                assertValid(plan, input: i, history: h, tz: ny, label: label)
            }
        }
    }

    func testStricterLimitsAreHonoured() {
        let limits = GuardrailLimits(maxWeeklyIncrease: 0.05, maxFourWeekIncrease: 0.15, maxLongRunShare: 0.32,
                                     maxConsecutiveBuildWeeks: 2, maxQualitySessionsPerWeek: 2)
        var refused = 0
        defer { XCTAssertLessThanOrEqual(refused, 1) }
        for d in [Distance.fiveK, Distance.halfMarathon] {
            for r in SyntheticRunner.all {
                let h = history(r, before: planMonday, multipliers: [1, 1, 1, 1, 1, 1, 1, 1], tz: utc)
                let i = input(r, distance: d, start: planMonday, race: raceDate(weeks: 14, from: planMonday, tz: utc))
                let result = PlanBuilder.build(i, history: h, timeZone: utc, limits: limits)
                guard let plan = result.plan else {
                    // Slower growth can leave a low-volume runner short of the race; that is the explicit answer.
                    XCTAssertTrue(Self.isVolumeTooLow(result.issues), "\(r.name): \(result.issues)")
                    refused += 1
                    continue
                }
                assertValid(plan, input: i, history: h, tz: utc, limits: limits, label: "strict \(r.name) \(Int(d))")
            }
        }
    }

    private static func isVolumeTooLow(_ issues: [PlanBuildIssue]) -> Bool {
        guard issues.count == 1, case .volumeTooLowForRace = issues[0] else { return false }
        return true
    }

    // MARK: Structure

    private var mid: SyntheticRunner { SyntheticRunner.all[1] }

    private func plan(_ r: SyntheticRunner, _ d: Double, weeks: Int, shape: [Double] = [1, 1, 1, 1, 1, 1, 1, 1],
                      goal: Double? = nil, anchor: Bool = true) throws -> (TrainingPlan, PlanInput, [PlannedWorkout]) {
        let h = history(r, before: planMonday, multipliers: shape, tz: utc)
        let i = input(r, distance: d, start: planMonday, race: raceDate(weeks: weeks, from: planMonday, tz: utc),
                      goal: goal, anchor: anchor)
        let result = PlanBuilder.build(i, history: h, timeZone: utc)
        return (try XCTUnwrap(result.plan, "\(result.issues)"), i, h)
    }

    func testPhaseLengthsFollowTheHeuristics() throws {
        let (p, _, _) = try plan(mid, Distance.marathon, weeks: 20)
        let count = { (phase: PlanPhase) in p.weeks.filter { $0.phase == phase }.count }
        XCTAssertEqual(count(.taper), PlanHeuristics.taperWeeks(.marathon))
        XCTAssertEqual(count(.peak), 3)
        XCTAssertEqual(count(.build), 7)
        XCTAssertEqual(count(.base), 8)

        let (short, _, _) = try plan(mid, Distance.fiveK, weeks: 4)
        XCTAssertEqual(short.weeks.map(\.phase), [.base, .build, .peak, .taper])
    }

    func testSteadyHistoryForcesAnEarlyRecoveryWeek() throws {
        // Eight build weeks in a row before the plan: 3.5 needs a recovery week now.
        let (p, _, _) = try plan(mid, Distance.halfMarathon, weeks: 16)
        XCTAssertTrue(p.weeks[0].isRecoveryWeek)
        // No history: the plan starts at the recent level instead.
        let i = input(mid, distance: Distance.halfMarathon, start: planMonday, race: raceDate(weeks: 16, from: planMonday, tz: utc))
        let fresh = try XCTUnwrap(PlanBuilder.build(i, timeZone: utc).plan)
        XCTAssertFalse(fresh.weeks[0].isRecoveryWeek)
        XCTAssertLessThanOrEqual(fresh.weeks[0].trainingSeconds, mid.weeklyMinutes * 60)
    }

    func testVolumeGrowsToAPeakAndTapers() throws {
        let (p, _, _) = try plan(mid, Distance.marathon, weeks: 18)
        let peak = p.weeks.filter { $0.phase == .peak }.map(\.trainingSeconds).max()!
        XCTAssertGreaterThan(peak, mid.weeklyMinutes * 60 * 1.15)
        let taper = p.weeks.first { $0.phase == .taper }!
        XCTAssertTrue(taper.isRecoveryWeek)
        XCTAssertLessThan(taper.trainingSeconds, peak)
        XCTAssertTrue(p.weeks.filter(\.isRecoveryWeek).count >= 18 / 4)
    }

    func testWeeksHaveAtMostTwoQualitySessionsAndOneLongRun() throws {
        let (p, _, _) = try plan(SyntheticRunner.all[3], Distance.tenK, weeks: 14)
        for w in p.weeks {
            XCTAssertLessThanOrEqual(w.workouts.filter { $0.kind.isQuality || $0.kind == .race }.count, 2)
            XCTAssertLessThanOrEqual(w.workouts.filter { $0.kind == .long }.count, 1)
        }
        let build = p.weeks.first { $0.phase == .build && !$0.isRecoveryWeek }!
        XCTAssertEqual(build.workouts.filter { $0.kind.isQuality }.count, 2)
    }

    func testTargetsComeFromTheRunnersData() throws {
        let r = mid
        let (p, _, _) = try plan(r, Distance.tenK, weeks: 12)
        let zones = r.zones
        let easy = try XCTUnwrap(p.workouts.first { $0.kind == .easy }?.prescription?.segments.first)
        XCTAssertEqual(easy.target.primary, .heartRate)
        XCTAssertEqual(easy.target.heartRate.ceilingBPM!, zones.easyCeiling, accuracy: 1e-9)
        XCTAssertEqual(easy.target.pace?.fastestSecondsPerKm ?? 0, r.easyPaceSecondsPerKm, accuracy: 1e-9)

        // Threshold pace: the Riegel pace for one hour from the 5K anchor (3.9).
        let threshold = try XCTUnwrap(p.workouts.compactMap(\.prescription).flatMap(\.segments)
            .first { $0.intensity == .threshold })
        // Hard-coded: a 24:00 5K by Riegel (k = 1.07) gives 305.79 s/km for one
        // hour and 275.23 s/km for 12 minutes.
        XCTAssertEqual(r.fiveKMinutes, 24)
        let hourPace = 305.79
        let vo2 = try XCTUnwrap(p.workouts.compactMap(\.prescription).flatMap(\.segments).first { $0.intensity == .vo2max })
        XCTAssertEqual(vo2.target.pace!.fastestSecondsPerKm, 275.23 * 0.98, accuracy: 0.02)
        XCTAssertEqual(threshold.target.primary, .pace)
        XCTAssertEqual(threshold.target.pace!.fastestSecondsPerKm, hourPace * 0.99, accuracy: 0.02)
        XCTAssertEqual(threshold.target.heartRate.floorBPM!, zones.lowerBound(.z4), accuracy: 1e-9)
        // One-hour pace is slower than 5K pace.
        XCTAssertGreaterThan(hourPace, r.fiveKMinutes * 60 / 5)

        let race = try XCTUnwrap(p.workouts.last)
        let predicted = RacePredictor.riegel(knownMeters: 5000, knownSeconds: r.fiveKMinutes * 60, targetMeters: 10_000)!
        XCTAssertEqual(race.durationSeconds, predicted, accuracy: 1e-6)
        XCTAssertEqual(race.distanceMeters, 10_000)
        XCTAssertEqual(race.prescription?.rules.first, .goalRace)
    }

    func testEverySessionNamesItsRule() throws {
        let (p, _, _) = try plan(mid, Distance.halfMarathon, weeks: 14)
        for w in p.workouts {
            let rules = try XCTUnwrap(w.prescription?.rules)
            switch w.kind {
            case .easy: XCTAssertEqual(rules.first, .easyByHeartRate)
            case .long: XCTAssertEqual(rules.first, .longRunShare)
            case .quality: XCTAssertTrue(rules.contains(.intensityDistribution) && rules.contains(.qualityLimit))
            case .race: XCTAssertEqual(rules, [.goalRace])
            default: XCTFail("unexpected kind \(w.kind)")
            }
            XCTAssertTrue(rules.allSatisfy { $0.summary.contains("SPEC") || $0.summary.contains("F") })
        }
    }

    func testNoAnchorMeansHeartRateOnlyQuality() throws {
        let (p, _, _) = try plan(mid, Distance.tenK, weeks: 12, goal: 50 * 60, anchor: false)
        let thresholds = p.workouts.compactMap(\.prescription).flatMap(\.segments).filter { $0.intensity == .threshold || $0.intensity == .vo2max }
        XCTAssertFalse(thresholds.isEmpty)
        XCTAssertTrue(thresholds.allSatisfy { $0.target.pace == nil && $0.target.primary == .heartRate })
        XCTAssertTrue(p.notes.contains { $0.contains("heart-rate targets") })
        // Race pace still comes from the goal.
        let racePace = try XCTUnwrap(p.workouts.compactMap(\.prescription).flatMap(\.segments).first { $0.intensity == .racePace })
        XCTAssertEqual(racePace.target.pace!.fastestSecondsPerKm, 300 * 0.99, accuracy: 1e-6)
        XCTAssertEqual(p.raceSeconds, 50 * 60)
    }

    func testAmbitiousGoalPaceIsCappedAtThreePercentOverFitness() throws {
        let predicted = RacePredictor.riegel(knownMeters: 5000, knownSeconds: mid.fiveKMinutes * 60, targetMeters: 10_000)!
        let (p, _, _) = try plan(mid, Distance.tenK, weeks: 12, goal: predicted * 0.85)
        let rp = try XCTUnwrap(p.workouts.compactMap(\.prescription).flatMap(\.segments).first { $0.intensity == .racePace })
        let capped = predicted / 10 * 0.97
        XCTAssertEqual(rp.target.pace!.fastestSecondsPerKm, capped * 0.99, accuracy: 1e-6)
        XCTAssertTrue(p.notes.contains { $0.contains("3% faster") })
        // The race is planned at the slower of goal and prediction.
        XCTAssertEqual(p.raceSeconds, predicted, accuracy: 1e-6)
    }

    func testEasyPaceRunAboveZoneTwoIsNotUsed() throws {
        let r = mid
        var i = input(r, distance: Distance.tenK, start: planMonday, race: raceDate(weeks: 12, from: planMonday, tz: utc))
        i.easyPace = EasyPaceSample(secondsPerKm: 330, heartRate: r.zones.easyCeiling + 2)
        let p = try XCTUnwrap(PlanBuilder.build(i, timeZone: utc).plan)
        let easy = p.workouts.filter { $0.kind == .easy }.compactMap(\.prescription).flatMap(\.segments)
        XCTAssertTrue(easy.allSatisfy { $0.target.pace == nil })
        XCTAssertTrue(p.notes.contains { $0.contains("above zone 2") })
    }

    func testRaceDurationFallsBackToEasyPaceBound() throws {
        var i = input(mid, distance: Distance.halfMarathon, start: planMonday,
                      race: raceDate(weeks: 14, from: planMonday, tz: utc), anchor: false)
        i.goalSeconds = nil
        let p = try XCTUnwrap(PlanBuilder.build(i, timeZone: utc).plan)
        XCTAssertEqual(p.raceSeconds, mid.easyPaceSecondsPerKm * Distance.halfMarathon / 1000, accuracy: 1e-6)
    }

    func testBuilderIsDeterministic() {
        let i = input(mid, distance: Distance.halfMarathon, start: planMonday, race: raceDate(weeks: 15, from: planMonday, tz: utc))
        let h = history(mid, before: planMonday, multipliers: [1, 1, 0.75, 1, 1], tz: utc)
        XCTAssertEqual(PlanBuilder.build(i, history: h, timeZone: utc), PlanBuilder.build(i, history: h, timeZone: utc))
    }

    func testHistoryAfterPlanStartIsIgnored() throws {
        let i = input(mid, distance: Distance.tenK, start: planMonday, race: raceDate(weeks: 10, from: planMonday, tz: utc))
        let h = history(mid, before: planMonday, multipliers: [1, 1, 1], tz: utc)
        let late = PlannedWorkout(id: "late", date: planMonday.addingTimeInterval(86_400), kind: .easy, durationSeconds: 9000)
        XCTAssertEqual(PlanBuilder.build(i, history: h, timeZone: utc), PlanBuilder.build(i, history: h + [late], timeZone: utc))
    }

    func testPrescriptionDefaultsToNilForExistingCallers() {
        let w = PlannedWorkout(id: "x", date: planMonday, kind: .easy, durationSeconds: 1800)
        XCTAssertNil(w.prescription)
        XCTAssertNil(w.swappedToEasy().prescription)
    }

    // MARK: Helpers

    func testQualityDaysAreNeverConsecutive() {
        let all = Array(0..<7)
        for long in all {
            let picked = PlanBuilder.pickQualityDays(all.filter { $0 != long }, count: 3, anchors: [long])
            XCTAssertEqual(picked.count, 3, "long \(long)")  // e.g. long Monday: Tuesday, Thursday, Saturday
            for a in picked { for b in picked where a != b { XCTAssertGreaterThanOrEqual(PlanBuilder.circularDistance(a, b), 2) } }
            XCTAssertFalse(picked.contains(long))
        }
        // Sunday and Monday are consecutive across the week boundary.
        XCTAssertEqual(PlanBuilder.circularDistance(0, 6), 1)
        XCTAssertEqual(PlanBuilder.pickQualityDays([0, 6], count: 2, anchors: []).count, 1)
        XCTAssertTrue(PlanBuilder.pickQualityDays([], count: 2, anchors: [3]).isEmpty)
    }

    func testLedgerCapsMatchTheChecker() {
        // Volumes in minutes; a ninth week planned exactly at the ledger's cap
        // passes the checker, and 1% more fails it.
        let sequences: [[Double]] = [
            [300, 300, 300, 300, 300, 300, 300, 300],
            [300, 320, 340, 250, 360, 380, 400, 300],
            [200, 200, 150, 0, 200, 210, 220, 230],
            [300]
        ]
        for seq in sequences {
            let ledger = PlanBuilder.LoadLedger(volumes: seq.map { $0 * 60 }, limits: .default)
            let cap = ledger.nextCap
            XCTAssertTrue(cap.isFinite)
            let h = PlanFixture.easyWeeks(seq, prefix: "h")
            let ok = GuardrailChecker.check(history: h, planned: PlanFixture.easyWeek(seq.count, minutes: cap / 60, prefix: "p"),
                                            timeZone: utc)
            XCTAssertTrue(ok.violations.filter { $0.rule == .weeklyIncrease || $0.rule == .fourWeekIncrease }.isEmpty, "\(seq)")
            let over = GuardrailChecker.check(history: h, planned: PlanFixture.easyWeek(seq.count, minutes: cap / 60 * 1.01, prefix: "p"),
                                              timeZone: utc)
            XCTAssertFalse(over.violations.filter { $0.rule == .weeklyIncrease || $0.rule == .fourWeekIncrease }.isEmpty, "\(seq)")
        }
        XCTAssertEqual(PlanBuilder.LoadLedger(volumes: [], limits: .default).nextCap, .infinity)
        XCTAssertEqual(PlanBuilder.LoadLedger(volumes: [100, 100, 100, 70], limits: .default).streak, 0)
        // An unknown week counts as a build week (#40).
        XCTAssertEqual(PlanBuilder.LoadLedger(volumes: [100, 100, nil, 100], limits: .default).streak, 4)
    }

    // MARK: Explicit refusals

    private func issues(_ i: PlanInput, history: [PlannedWorkout] = [], limits: GuardrailLimits = .default) -> [PlanBuildIssue] {
        PlanBuilder.build(i, history: history, timeZone: utc, limits: limits).issues
    }

    private var base: PlanInput {
        input(mid, distance: Distance.halfMarathon, start: planMonday, race: raceDate(weeks: 14, from: planMonday, tz: utc))
    }

    func testLeadTimeTooShort() {
        for d in distances {
            let c = RaceCategory(meters: d)!
            let min = PlanHeuristics.minimumWeeks(c)
            let i = input(mid, distance: d, start: planMonday, race: raceDate(weeks: min - 1, from: planMonday, tz: utc))
            XCTAssertEqual(issues(i), [.leadTimeTooShort(weeksAvailable: min - 1, minimumWeeks: min)], "\(d)")
            let ok = input(mid, distance: d, start: planMonday, race: raceDate(weeks: min, from: planMonday, tz: utc))
            XCTAssertFalse(issues(ok).contains { if case .leadTimeTooShort = $0 { return true }; return false }, "\(d)")
        }
    }

    func testLeadTimeTooLongAndRaceBeforeStart() {
        var i = base
        i.raceDate = planMonday.addingTimeInterval(400 * 86_400)
        XCTAssertEqual(issues(i), [.leadTimeTooLong(weeksAvailable: 53, maximumWeeks: 52)])
        i.raceDate = planMonday.addingTimeInterval(-86_400)
        XCTAssertEqual(issues(i), [.raceNotAfterStart])
        i.raceDate = planMonday
        XCTAssertEqual(issues(i), [.raceNotAfterStart])
    }

    func testTooLittleDataIsReportedNotGuessed() {
        var i = base
        i.recentWeeklySeconds = nil
        i.heartRateZones = nil
        XCTAssertEqual(issues(i), [.missingRecentVolume, .missingHeartRateZones])
        i = base
        i.recentWeeklySeconds = 60 * 60
        XCTAssertEqual(issues(i), [.recentVolumeTooLow(seconds: 3600, minimumSeconds: PlanHeuristics.minimumRecentWeeklySeconds)])
        i.recentWeeklySeconds = 0
        XCTAssertEqual(issues(i), [.recentVolumeTooLow(seconds: 0, minimumSeconds: PlanHeuristics.minimumRecentWeeklySeconds)])
    }

    func testRaceDurationUnknownWithNoGoalPredictionOrPace() {
        var i = base
        i.goalSeconds = nil
        i.predictedRaceSeconds = nil
        i.fitnessAnchor = nil
        i.easyPace = nil
        XCTAssertEqual(issues(i), [.raceDurationUnknown])
    }

    func testScheduleProblems() {
        var i = base
        i.trainingDays = [.tuesday, .sunday]
        i.longRunDay = .saturday
        XCTAssertEqual(issues(i), [.tooFewTrainingDays(available: 2, minimum: 3), .longRunDayNotATrainingDay])
        i = base
        i.maxSessionSeconds = 30 * 60
        XCTAssertEqual(issues(i), [.maxSessionTooShort(seconds: 1800, minimumSeconds: PlanHeuristics.minimumSessionSeconds)])
    }

    func testInvalidValues() {
        let bad: [(PlanInput.Field, (inout PlanInput) -> Void)] = [
            (.goalSeconds, { $0.goalSeconds = .nan }),
            (.goalSeconds, { $0.goalSeconds = -1 }),
            (.predictedRaceSeconds, { $0.predictedRaceSeconds = .infinity }),
            (.recentLongRunSeconds, { $0.recentLongRunSeconds = 0 }),
            (.maxSessionSeconds, { $0.maxSessionSeconds = .nan }),
            (.recentWeeklySeconds, { $0.recentWeeklySeconds = .nan }),
            (.easyPace, { $0.easyPace = EasyPaceSample(secondsPerKm: .nan, heartRate: 140) }),
            (.easyPace, { $0.easyPace = EasyPaceSample(secondsPerKm: 360, heartRate: 0) }),
            (.fitnessAnchor, { $0.fitnessAnchor = RaceEquivalent(distanceMeters: 1500, seconds: 300) }),
            (.fitnessAnchor, { $0.fitnessAnchor = RaceEquivalent(distanceMeters: Distance.marathon, seconds: 12_000) }),
            (.fitnessAnchor, { $0.fitnessAnchor = RaceEquivalent(distanceMeters: 5000, seconds: 0) }),
            (.raceDistanceMeters, { $0.raceDistanceMeters = .nan })
        ]
        for (field, mutate) in bad {
            var i = base
            mutate(&i)
            XCTAssertTrue(issues(i).contains(.invalidValue(field)), "\(field): \(issues(i))")
        }
    }

    func testUnsupportedDistancesAndLimits() {
        var i = base
        i.raceDistanceMeters = 3000
        XCTAssertEqual(issues(i), [.unsupportedRaceDistance(meters: 3000)])
        i.raceDistanceMeters = 50_000
        XCTAssertEqual(issues(i), [.unsupportedRaceDistance(meters: 50_000)])
        XCTAssertEqual(RaceCategory(meters: Distance.tenMiles), .half)
        XCTAssertEqual(RaceCategory(meters: 4960), .fiveK)

        XCTAssertEqual(issues(base, limits: GuardrailLimits(measure: .distance)).count, 1)
        XCTAssertEqual(issues(base, limits: GuardrailLimits(maxQualitySessionsPerWeek: 0)).count, 1)
    }

    func testLowVolumeMarathonOnTheShortestLeadTimeBuilds() throws {
        // A low-volume runner, a slow marathon and the shortest lead time.
        // The race itself is left out of the week-over-week check (SPEC 3.5
        // rule 3, the owner's decision in #38), so the race week no longer
        // refuses the plan (it did before #62).
        let r = SyntheticRunner.all[0]
        let i = input(r, distance: Distance.marathon, start: planMonday, race: raceDate(weeks: 8, from: planMonday, tz: utc))
        let h = history(r, before: planMonday, multipliers: [1, 1, 1, 1, 1, 1, 1, 1], tz: utc)
        let result = PlanBuilder.build(i, history: h, timeZone: utc)
        let p = try XCTUnwrap(result.plan, "\(result.issues)")
        assertValid(p, input: i, history: h, tz: utc, label: "low marathon")
        let race = try XCTUnwrap(p.weeks.last)
        XCTAssertTrue(race.isRaceWeek)
        XCTAssertGreaterThan(race.workouts.first { $0.kind == .race }?.durationSeconds ?? 0,
                             1.1 * p.weeks[p.weeks.count - 2].trainingSeconds, "the race alone is over the 10% cap")
        XCTAssertLessThanOrEqual(race.trainingSeconds, 1.1 * p.weeks[p.weeks.count - 2].trainingSeconds + 1e-6)
    }

    func testLowVolumeMarathonLongRunsMayExceedTheUsualShare() throws {
        // 3.5 rule 5 (#62): in a marathon plan the long run may take up to
        // 45% of the week, a warning above 35%; other distances keep 35%.
        let r = SyntheticRunner.all[0]
        let h = history(r, before: planMonday, multipliers: [1, 1, 1, 1, 1, 1, 1, 1], tz: utc)
        func shares(_ p: TrainingPlan) -> [Double] {
            p.weeks.compactMap { w -> Double? in
                guard let l = w.workouts.first(where: { $0.kind == .long }) else { return nil }
                return l.durationSeconds / w.workouts.reduce(0) { $0 + $1.durationSeconds }
            }
        }
        let mi = input(r, distance: Distance.marathon, start: planMonday, race: raceDate(weeks: 16, from: planMonday, tz: utc))
        let m = try XCTUnwrap(PlanBuilder.build(mi, history: h, timeZone: utc).plan)
        assertValid(m, input: mi, history: h, tz: utc, label: "marathon")
        XCTAssertTrue(shares(m).contains { $0 > 0.35 + 1e-9 }, "\(shares(m))")
        XCTAssertTrue(shares(m).allSatisfy { $0 <= 0.45 + 1e-9 }, "\(shares(m))")
        let flags = m.guardrailReport.informationFlags.filter { $0.rule == .longRunShare }
        XCTAssertEqual(flags.count, shares(m).filter { $0 > 0.35 + 1e-9 }.count)
        XCTAssertTrue(flags.allSatisfy { $0.workoutID != nil && $0.explanation.contains("warning") })
        // Every long run of the plan still at most 150 min when above the usual share.
        for w in m.weeks {
            guard let l = w.workouts.first(where: { $0.kind == .long }) else { continue }
            let share = l.durationSeconds / w.workouts.reduce(0) { $0 + $1.durationSeconds }
            if share > 0.35 + 1e-9 { XCTAssertLessThanOrEqual(l.durationSeconds, PlanHeuristics.marathonLongRunTargetSeconds) }
        }
        for d in [Distance.tenK, Distance.halfMarathon] {
            let hi = input(r, distance: d, start: planMonday, race: raceDate(weeks: 16, from: planMonday, tz: utc))
            let p = try XCTUnwrap(PlanBuilder.build(hi, history: h, timeZone: utc).plan)
            assertValid(p, input: hi, history: h, tz: utc, label: "\(Int(d))")
            XCTAssertTrue(shares(p).allSatisfy { $0 <= 0.35 + 1e-9 }, "\(Int(d)): \(shares(p))")
            XCTAssertFalse(p.guardrailReport.informationFlags.contains { $0.rule == .longRunShare })
        }
    }

    // MARK: Review repros (PR #39)

    private func runs(_ minutes: [Double], before monday: Date) -> [PlannedWorkout] {
        // One easy run on the Wednesday of each week; the last entry is the week before `monday`.
        minutes.enumerated().compactMap { k, m in
            guard m > 0 else { return nil }
            let date = monday.addingTimeInterval(Double((k - minutes.count) * 7 + 2) * 86_400 + 7 * 3600)
            return PlannedWorkout(id: "r\(k)", date: date, kind: .easy, durationSeconds: m * 60)
        }
    }

    func testRecentVolumeAboveHistoryIsRefused() {
        // One 30-minute run the week before, but a baseline of 150 minutes a week.
        var i = input(mid, distance: Distance.halfMarathon, start: planMonday,
                      race: raceDate(weeks: 16, from: planMonday, tz: utc))
        i.recentWeeklySeconds = 150 * 60
        XCTAssertEqual(issues(i, history: runs([30], before: planMonday)),
                       [.recentVolumeDisagreesWithHistory(recentWeeklySeconds: 9000, historyWeeklySeconds: 1800)])
        // Agreeing values build.
        i.recentWeeklySeconds = 240 * 60
        XCTAssertNotNil(PlanBuilder.build(i, history: runs([240, 240, 240, 240], before: planMonday), timeZone: utc).plan)
    }

    func testBreakThenReturnRampsBackWithoutEmptyWeeks() throws {
        let h = runs([240, 240, 240, 240, 0, 0, 240, 240], before: planMonday)
        for d in distances {
            let i = input(mid, distance: d, start: planMonday, race: raceDate(weeks: 16, from: planMonday, tz: utc),
                          recentScale: 0.5)
            let result = PlanBuilder.build(i, history: h, timeZone: utc)
            guard let p = result.plan else {
                XCTAssertEqual(d, Distance.marathon, "\(result.issues)")
                XCTAssertTrue(Self.isVolumeTooLow(result.issues), "\(result.issues)")
                continue
            }
            assertValid(p, input: i, history: h, tz: utc, label: "break \(Int(d))")
            XCTAssertTrue(p.weeks.filter { !$0.isRaceWeek }.allSatisfy {
                $0.trainingSeconds >= ($0.isRecoveryWeek ? PlanHeuristics.minimumRecoveryWeekSeconds : PlanHeuristics.minimumWeekSeconds)
            })
            // The plan's first week is week 3 of the return ramp (3.5 rule 4,
            // #62): at most the pre-break week, and volume keeps coming back.
            XCTAssertLessThanOrEqual(p.weeks[0].trainingSeconds, 240 * 60 + 1e-6)
            XCTAssertGreaterThan(p.weeks.map(\.trainingSeconds).max()!, p.weeks[0].trainingSeconds)
        }
    }

    func testThreeWeeksBackAfterAShortBreakBuild() throws {
        // The owner's example in #38: two weeks off, then three weeks back at
        // the pre-break 240 min. Before #62 the rolling 4-week rule compared
        // weeks -3..-1 (720 min) with 1.3 x 480 and allowed nothing in week 0.
        // Now the break weeks count at the pre-break level (960, so 1248 for
        // the 4 weeks to week 0) and the plan builds.
        let h = runs([240, 240, 240, 0, 0, 240, 240, 240], before: planMonday)
        let i = input(mid, distance: Distance.halfMarathon, start: planMonday,
                      race: raceDate(weeks: 14, from: planMonday, tz: utc), recentScale: 0.75)
        let result = PlanBuilder.build(i, history: h, timeZone: utc)
        let p = try XCTUnwrap(result.plan, "\(result.issues)")
        assertValid(p, input: i, history: h, tz: utc, label: "back after break")
        XCTAssertGreaterThanOrEqual(p.weeks[0].trainingSeconds, PlanHeuristics.minimumWeekSeconds)
        // With the ramp switched off (the plain rules) it is still an explicit issue.
        let plain = GuardrailLimits(maxShortBreakWeeks: 0)
        let old = issues(i, history: h, limits: plain)
        guard case .noWorkableWeek(let week, let allowed)? = old.first, old.count == 1 else { return XCTFail("\(old)") }
        XCTAssertEqual(week, planMonday)
        XCTAssertLessThan(allowed, PlanHeuristics.minimumWeekSeconds)
    }

    func testNoRoomAfterALongBreakIsAnExplicitIssue() throws {
        // Back from three weeks off, a longer break: under the plain rules the rolling 4-week rule
        // leaves under an hour for the plan's second week (1.3 x 240 for the 4 weeks to it, 480 already
        // run), an explicit issue. Under 0.8's steps (3.5 rule 4, #32) the break's weeks count at the
        // pre-break level (240) in that check, so the plan builds.
        let h = runs([240, 240, 240, 240, 0, 0, 0, 240, 240], before: planMonday)
        let i = input(mid, distance: Distance.tenK, start: planMonday, race: raceDate(weeks: 12, from: planMonday, tz: utc),
                      recentScale: 0.5)
        let result = issues(i, history: h, limits: GuardrailLimits(longerBreakReturnSteps: []))
        guard case .noWorkableWeek(_, let allowed)? = result.first, result.count == 1 else { return XCTFail("\(result)") }
        XCTAssertLessThan(allowed, PlanHeuristics.minimumWeekSeconds)
        let built = PlanBuilder.build(i, history: h, timeZone: utc)
        let p = try XCTUnwrap(built.plan, "\(built.issues)")
        assertValid(p, input: i, history: h, tz: utc, label: "longer break, steps")
        // A low-volume runner back from two weeks off, a short break: this
        // was an explicit issue before #62 and now builds.
        let r = SyntheticRunner.all[0]
        let h2 = runs([150, 150, 150, 150, 0, 0, 150, 150], before: planMonday)
        let j = input(r, distance: Distance.tenK, start: planMonday, race: raceDate(weeks: 12, from: planMonday, tz: utc),
                      recentScale: 0.65)
        let r2 = PlanBuilder.build(j, history: h2, timeZone: utc)
        guard let p = r2.plan else { return XCTFail("\(r2.issues)") }
        assertValid(p, input: j, history: h2, tz: utc, label: "short break")
    }

    func testHardDaysStayApartAroundAMondayRace() throws {
        let r = SyntheticRunner(name: "fri-long", weeklyMinutes: 300, longMinutes: 95,
                                days: [.tuesday, .wednesday, .friday, .saturday, .sunday], longDay: .friday,
                                maxSessionMinutes: nil, lthr: 166, fiveKMinutes: 22, easyPaceSecondsPerKm: 345, easyHR: 135)
        for weekday in PlanWeekday.allCases {
            for d in distances {
                let i = input(r, distance: d, start: planMonday,
                              race: raceDate(weeks: 12, from: planMonday, tz: utc, weekday: weekday))
                let h = history(r, before: planMonday, multipliers: [1, 1, 1, 0.75, 1, 1], tz: utc)
                let result = PlanBuilder.build(i, history: h, timeZone: utc)
                guard let p = result.plan else { XCTFail("\(weekday) \(d): \(result.issues)"); continue }
                assertValid(p, input: i, history: h, tz: utc, label: "race \(weekday) \(Int(d))")
            }
        }
    }

    func testHardDaysStayApartFromHistory() throws {
        // A Sunday quality session just before a plan whose pattern wants Monday.
        let r = SyntheticRunner(name: "mon", weeklyMinutes: 280, longMinutes: 90,
                                days: [.monday, .wednesday, .thursday, .saturday], longDay: .thursday,
                                maxSessionMinutes: nil, lthr: 166, fiveKMinutes: 22, easyPaceSecondsPerKm: 345, easyHR: 135)
        var h = history(r, before: planMonday, multipliers: [1, 1, 0.75, 1], tz: utc)
        h.append(PlannedWorkout(id: "sun-q", date: planMonday.addingTimeInterval(-17 * 3600), kind: .quality(.threshold),
                                durationSeconds: 3000))
        let i = input(r, distance: Distance.tenK, start: planMonday, race: raceDate(weeks: 10, from: planMonday, tz: utc),
                      recentScale: 1.05)
        let p = try XCTUnwrap(PlanBuilder.build(i, history: h, timeZone: utc).plan)
        assertValid(p, input: i, history: h, tz: utc, label: "history hard day")
    }

    func testShortSessionCapKeepsTheEasyBand() throws {
        let r = SyntheticRunner(name: "capped", weeklyMinutes: 360, longMinutes: 55,
                                days: [.tuesday, .friday, .saturday], longDay: .saturday,
                                maxSessionMinutes: 55, lthr: 166, fiveKMinutes: 22, easyPaceSecondsPerKm: 345, easyHR: 135)
        let i = input(r, distance: Distance.fiveK, start: planMonday, race: raceDate(weeks: 10, from: planMonday, tz: utc))
        let result = PlanBuilder.build(i, timeZone: utc)
        if let p = result.plan {
            assertValid(p, input: i, history: [], tz: utc, label: "capped")
        } else {
            guard case .intensityDistributionNotMet? = result.issues.first else { return XCTFail("\(result.issues)") }
        }
    }

    func testUnknownHistoryWeekBeforeAForcedRecovery() {
        var h = runs([240, 240, 240], before: planMonday.addingTimeInterval(-7 * 86_400))
        h.append(PlannedWorkout(id: "broken", date: planMonday.addingTimeInterval(-3 * 86_400), kind: .easy,
                                durationSeconds: .nan))
        let i = input(mid, distance: Distance.halfMarathon, start: planMonday, race: raceDate(weeks: 14, from: planMonday, tz: utc))
        XCTAssertEqual(issues(i, history: h),
                       [.historyVolumeUnknown(rebuildOn: planMonday.addingTimeInterval(7 * 86_400))])
        // With room left in the streak, the unknown week only means no recovery
        // week first. It counts as a build week (#40), so one known week before it
        // leaves room: 240, unknown, then plan week 0 makes 3.
        let shorter = Array(h.suffix(2))
        let p = PlanBuilder.build(i, history: shorter, timeZone: utc).plan
        XCTAssertNotNil(p)
        if let p { XCTAssertFalse(p.weeks[0].isRecoveryWeek) }
    }

    private var nextMonday: Date { planMonday.addingTimeInterval(7 * 86_400) }

    func testMondayStartAfterNoonBeginsTheNextMonday() throws {
        // (a) Every 3-day schedule with Monday, at a Monday 15:00 start.
        let start = planMonday.addingTimeInterval(15 * 3600)
        let others: [PlanWeekday] = [.tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]
        for (k, a) in others.enumerated() {
            for b in others[(k + 1)...] {
                let days: Set<PlanWeekday> = [.monday, a, b]
                for long in days.sorted() {
                    let r = SyntheticRunner(name: "3day", weeklyMinutes: 200, longMinutes: 65, days: days, longDay: long,
                                            maxSessionMinutes: nil, lthr: 168, fiveKMinutes: 25,
                                            easyPaceSecondsPerKm: 370, easyHR: 138)
                    let h = history(r, before: planMonday, multipliers: [1, 1, 0.75, 1, 1, 1], tz: utc)
                    for d in [Distance.fiveK, Distance.tenK, Distance.halfMarathon] {
                        let i = input(r, distance: d, start: start, race: raceDate(weeks: 12, from: planMonday, tz: utc))
                        let label = "\(days.map(\.rawValue).sorted()) long \(long) \(Int(d))"
                        let result = PlanBuilder.build(i, history: h, timeZone: utc)
                        guard let p = result.plan else { XCTFail("\(label): \(result.issues)"); continue }
                        XCTAssertEqual(p.weeks[0].weekStart, nextMonday, label)
                        assertValid(p, input: i, history: h, tz: utc, label: label)
                    }
                }
            }
        }
        // A Monday start before noon with nothing logged keeps Monday.
        let r = SyntheticRunner.all[3]
        let h = history(r, before: planMonday, multipliers: [1, 1, 0.75, 1, 1, 1], tz: utc)
        let early = input(r, distance: Distance.tenK, start: planMonday.addingTimeInterval(6 * 3600),
                          race: raceDate(weeks: 10, from: planMonday, tz: utc))
        let q = try XCTUnwrap(PlanBuilder.build(early, history: h, timeZone: utc).plan)
        XCTAssertEqual(q.weeks[0].weekStart, planMonday)
        XCTAssertTrue(q.weeks[0].workouts.contains { PlanWeekday(of: $0.date, timeZone: utc) == .monday })
    }

    func testLongRunLoggedOnTheStartMondayStaysInHistory() throws {
        // (b) A long run done that Monday morning, then a start that afternoon or still in the morning.
        let r = SyntheticRunner.all[1] // 240 min a week
        let base = history(r, before: planMonday, multipliers: [1, 1, 0.75, 1, 1, 1], tz: utc)
        for minutes in [60.0, 90, 120] {
            let done = PlannedWorkout(id: "done", date: planMonday.addingTimeInterval(7 * 3600), kind: .long,
                                      durationSeconds: minutes * 60)
            for startHour in [9.0, 15] {
                let start = planMonday.addingTimeInterval(startHour * 3600)
                let i = input(r, distance: Distance.halfMarathon, start: start,
                              race: raceDate(weeks: 14, from: planMonday, tz: utc))
                let label = "long \(Int(minutes)) start \(Int(startHour))h"
                let result = PlanBuilder.build(i, history: base + [done], timeZone: utc)
                guard let p = result.plan else { XCTFail("\(label): \(result.issues)"); continue }
                XCTAssertEqual(p.weeks[0].weekStart, nextMonday, label)
                XCTAssertTrue(p.workouts.allSatisfy { $0.date >= nextMonday }, label)
                assertValid(p, input: i, history: base + [done], tz: utc, label: label)
            }
        }
    }

    func testRunLoggedOnTheStartMondayBeforeARequiredRecoveryWeek() throws {
        // (c) Three build weeks of 118 minutes (the streak limit), then 64 minutes on the start Monday.
        let r = SyntheticRunner.all[0]
        let h = runs([110, 114, 118, 118], before: planMonday)
            + [PlannedWorkout(id: "done", date: planMonday.addingTimeInterval(7 * 3600), kind: .easy, durationSeconds: 64 * 60)]
        let i = input(r, distance: Distance.tenK, start: planMonday.addingTimeInterval(15 * 3600),
                      race: raceDate(weeks: 12, from: planMonday, tz: utc), recentScale: 115.0 / 150)
        let result = PlanBuilder.build(i, history: h, timeZone: utc)
        let p = try XCTUnwrap(result.plan, "\(result.issues)")
        // The 64-minute start week is history and reads as a recovery week so
        // far, but it is still open (#48): runs later that week can make it a
        // fourth build week, so the plan's first week is a recovery week
        // against the least such a week can be (80% of 118 minutes).
        XCTAssertEqual(p.weeks[0].weekStart, nextMonday)
        XCTAssertFalse(p.weeks[0].isRecoveryWeek, "as labelled against the 64 minutes so far")
        XCTAssertLessThanOrEqual(p.weeks[0].trainingSeconds, 0.8 * 0.8 * 118 * 60)
        assertValid(p, input: i, history: h, tz: utc, label: "done before recovery")
        // The usual week finished after all: 3.5 still holds.
        let rest = [PlannedWorkout(id: "later", date: planMonday.addingTimeInterval(3 * 86_400 + 7 * 3600), kind: .easy,
                                   durationSeconds: 54 * 60)]
        XCTAssertTrue(GuardrailChecker.check(history: h + rest, planned: p.workouts, timeZone: utc).passed)
    }

    func testRequiredRecoveryWeekAfterASmallWeekUsesTheLowerFloor() throws {
        // Back from a break with seven small weeks, more build weeks in a row
        // than 3.5 allows: the required recovery week is 75 to 80% of 70
        // minutes, under an hour but allowed.
        let h = runs([240, 240, 240, 240, 0, 0, 60, 60, 62, 64, 66, 68, 70], before: planMonday)
        let i = input(mid, distance: Distance.tenK, start: planMonday, race: raceDate(weeks: 14, from: planMonday, tz: utc),
                      recentScale: 90.0 / 240)
        let result = PlanBuilder.build(i, history: h, timeZone: utc)
        let p = try XCTUnwrap(result.plan, "\(result.issues)")
        XCTAssertTrue(p.weeks[0].isRecoveryWeek)
        XCTAssertLessThan(p.weeks[0].trainingSeconds, PlanHeuristics.minimumWeekSeconds)
        XCTAssertGreaterThanOrEqual(p.weeks[0].trainingSeconds, PlanHeuristics.minimumRecoveryWeekSeconds)
        assertValid(p, input: i, history: h, tz: utc, label: "small recovery")
        // Below the recovery floor it is still an explicit issue.
        let tiny = runs([240, 240, 240, 240, 0, 0, 40, 40, 42, 44, 46, 48, 48], before: planMonday)
        var j = i
        j.recentWeeklySeconds = 90 * 60
        guard case .noWorkableWeek(let week, let allowed)? = issues(j, history: tiny).first else {
            return XCTFail("\(issues(j, history: tiny))")
        }
        XCTAssertEqual(week, planMonday)
        XCTAssertLessThan(allowed, PlanHeuristics.minimumRecoveryWeekSeconds)
    }

    func testMarathonPredictionIsDerivedForTheCap() throws {
        var i = input(mid, distance: Distance.marathon, start: planMonday, race: raceDate(weeks: 18, from: planMonday, tz: utc),
                      goal: 2.5 * 3600)
        i.predictedRaceSeconds = nil
        let miles = mid.weeklyMinutes * 60 / mid.easyPaceSecondsPerKm / 1.609344
        let vv = try XCTUnwrap(VickersVertosick.marathonSeconds(raceMeters: 5000, raceSeconds: 24 * 60, weeklyMiles: miles))
        let p = try XCTUnwrap(PlanBuilder.build(i, timeZone: utc).plan)
        let rp = try XCTUnwrap(p.workouts.compactMap(\.prescription).flatMap(\.segments).first { $0.intensity == .racePace })
        XCTAssertEqual(rp.target.pace!.fastestSecondsPerKm, vv / 42.195 * 0.97 * 0.99, accuracy: 1e-6)
        XCTAssertEqual(p.raceSeconds, vv, accuracy: 1e-6)
        // Without an easy pace there is no prediction, but the goal is still held back.
        i.easyPace = nil
        let q = try XCTUnwrap(PlanBuilder.build(i, timeZone: utc).plan)
        let rq = try XCTUnwrap(q.workouts.compactMap(\.prescription).flatMap(\.segments).first { $0.intensity == .racePace })
        XCTAssertGreaterThan(rq.target.pace!.fastestSecondsPerKm, 2.5 * 3600 / 42.195 * 0.99 + 1)
        XCTAssertTrue(q.notes.contains { $0.contains("No marathon prediction") })
    }

    func testImplausibleGoalsAreRejected() {
        var i = base
        i.goalSeconds = 10
        XCTAssertEqual(issues(i), [.invalidValue(.goalSeconds)])
        i.goalSeconds = 30 * 3600
        XCTAssertEqual(issues(i), [.invalidValue(.goalSeconds)])
        i.goalSeconds = nil
        i.predictedRaceSeconds = 60
        XCTAssertEqual(issues(i), [.invalidValue(.predictedRaceSeconds)])
    }

    // MARK: Fuzz

    /// SplitMix64, so the cases are the same on every run and platform.
    private struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
        mutating func double(_ range: ClosedRange<Double>) -> Double {
            range.lowerBound + Double(next() % 1_000_000) / 1_000_000 * (range.upperBound - range.lowerBound)
        }
        mutating func pick<T>(_ xs: [T]) -> T { xs[int(0...(xs.count - 1))] }
    }

    func testFuzzedInputsGiveAValidPlanOrAnExplicitRefusal() {
        var rng = Rng(state: 0xC0AC_C02E)
        let zones = ["UTC", "America/New_York", "Europe/London", "Asia/Tokyo", "Asia/Kathmandu", "Australia/Sydney",
                     "America/Los_Angeles"].map { TimeZone(identifier: $0)! }
        let distanceChoices = [Distance.fiveK, Distance.tenK, Distance.tenMiles, Distance.halfMarathon, Distance.marathon]
        let multipliers: [Double] = [1, 1, 1, 0.9, 1.1, 0.75, 0, 0.3, 1.2]
        var built = 0, refused: [String: Int] = [:]
        for n in 0..<400 {
            let tz = rng.pick(zones)
            let c = cal(tz)
            var comps = DateComponents()
            comps.year = 2026; comps.month = 2; comps.day = 23 + rng.int(0...20)
            let anyDay = c.date(from: comps)!
            let monday = PlanCalendar.weekStart(containing: anyDay, timeZone: tz)
            let start = c.date(byAdding: .day, value: rng.int(0...6), to: monday)!.addingTimeInterval(Double(rng.int(0...23)) * 3600)

            var days = Set<PlanWeekday>()
            let dayCount = rng.int(3...7)
            while days.count < dayCount { days.insert(PlanWeekday(rawValue: rng.int(0...6))!) }
            let longDay = rng.pick(days.sorted())
            let weekly = rng.double(100...500)
            let lthr = rng.double(150...185)
            let five = rng.double(17...34) * 60
            let r = SyntheticRunner(name: "fuzz\(n)", weeklyMinutes: weekly, longMinutes: weekly * rng.double(0.22...0.36),
                                    days: days, longDay: longDay,
                                    maxSessionMinutes: rng.int(0...2) == 0 ? nil : rng.double(45...180),
                                    lthr: lthr, fiveKMinutes: five / 60, easyPaceSecondsPerKm: five / 5 * rng.double(1.25...1.45),
                                    easyHR: lthr * rng.double(0.75...0.86))

            let d = rng.pick(distanceChoices)
            let minWeeks = PlanHeuristics.minimumWeeks(RaceCategory(meters: d)!)
            let weeks = rng.int(minWeeks...30)
            // The plan keeps the start's week only on a Monday no later than noon (the history ends before it).
            let mondayNoon = c.date(bySettingHour: 12, minute: 0, second: 0, of: monday)!
            let firstMonday = c.startOfDay(for: start) == monday && start <= mondayNoon
                ? monday : PlanCalendar.nextWeekStart(after: monday, timeZone: tz)
            let raceDay = c.date(byAdding: .day, value: (weeks - 1) * 7 + rng.int(0...6), to: firstMonday)!
            let race = c.date(bySettingHour: rng.int(6...10), minute: 0, second: 0, of: raceDay)!

            // History: whole weeks before the start's week, some empty or short, maybe a quality day.
            let shape = (0..<rng.int(0...10)).map { _ in rng.pick(multipliers) }
            var h = history(r, before: monday, multipliers: shape, tz: tz)
            if !h.isEmpty && rng.int(0...2) == 0, let last = h.max(by: { $0.date < $1.date }) {
                h.append(PlannedWorkout(id: "hq", date: last.date.addingTimeInterval(-3600), kind: .quality(.threshold),
                                        durationSeconds: 40 * 60))
            }
            let complete = shape.suffix(4)
            let mean = complete.isEmpty ? 1 : complete.reduce(0, +) / Double(complete.count)
            var i = input(r, distance: d, start: start, race: race, goal: nil, anchor: rng.int(0...3) != 0,
                          recentScale: max(mean, 0.4) * rng.double(0.85...1.15))
            if rng.int(0...3) == 0, let p = i.predictedRaceSeconds ?? i.fitnessAnchor.map({ $0.seconds * pow(d / 5000, 1.07) }) {
                i.goalSeconds = p * rng.double(0.85...1.1)
            }
            let limits = rng.int(0...4) == 0
                ? GuardrailLimits(maxWeeklyIncrease: 0.07, maxFourWeekIncrease: 0.2, maxConsecutiveBuildWeeks: 2)
                : .default
            let label = "fuzz \(n) \(tz.identifier) \(Int(d))m \(weeks)w days \(days.map(\.rawValue).sorted()) long \(longDay)"
            switch PlanBuilder.build(i, history: h, timeZone: tz, limits: limits) {
            case .plan(let p):
                built += 1
                assertValid(p, input: i, history: h, tz: tz, limits: limits, label: label)
            case .cannotBuild(let issues):
                XCTAssertFalse(issues.isEmpty, label)
                for issue in issues {
                    switch issue {
                    case .volumeTooLowForRace, .noWorkableWeek, .recentVolumeTooLow, .intensityDistributionNotMet,
                         .recentVolumeDisagreesWithHistory, .historyVolumeUnknown, .startWeekWithoutReference:
                        break
                    case .failsGuardrails(let report):
                        XCTFail("\(label): \(report.violations.map(\.explanation))")
                    default:
                        XCTFail("\(label): unexpected refusal \(issue)")
                    }
                    refused[String(describing: issue).components(separatedBy: "(").first!, default: 0] += 1
                }
            }
        }
        XCTAssertGreaterThan(built, 200, "\(refused)")
    }
}
