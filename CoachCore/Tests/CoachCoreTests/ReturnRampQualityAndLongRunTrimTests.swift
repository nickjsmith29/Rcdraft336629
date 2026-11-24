import XCTest
@testable import CoachCore

// Review round 1 on #62: the marathon long run trimmed after easy time is
// dropped keeps the 150-minute bound above the usual share (SPEC 3.5 rule 5),
// and the return ramp's first week holds no quality session and its second
// at most one (SPEC 3.5 rule 4). Synthetic runners and weeks only.
final class ReturnRampQualityAndLongRunTrimTests: XCTestCase {
    private let utc = PlanFixture.utc
    private typealias F = PlanFixture

    /// Plan start: Monday of fixture week 8, at midnight.
    private var planMonday: Date { F.date(week: 8, day: 0, hour: 0) }

    /// Race on the Sunday of plan week `weeks - 1`, at 08:00.
    private func raceDate(weeks: Int) -> Date {
        planMonday.addingTimeInterval(Double((weeks - 1) * 7 + 6) * 86_400 + 8 * 3600)
    }

    /// History of `totals` minutes a week (the last entry is the week
    /// before the plan), each week split evenly over `days` with the long run
    /// taking `longShare` of it.
    private func history(_ totals: [Double], days: [PlanWeekday], longDay: PlanWeekday,
                         longShare: Double = 0.30) -> [PlannedWorkout] {
        var out: [PlannedWorkout] = []
        let others = days.filter { $0 != longDay }
        for (k, total) in totals.enumerated() where total > 0 {
            let week = 8 + k - totals.count
            for d in days {
                let minutes = d == longDay ? total * longShare : total * (1 - longShare) / Double(others.count)
                out.append(F.workout("h\(k)-\(d.rawValue)", week: week, day: d.rawValue,
                                     d == longDay ? .long : .easy, minutes: minutes))
            }
        }
        return out
    }

    private func input(days: [PlanWeekday], longDay: PlanWeekday, weekly: Double, distance: Double,
                       weeks: Int, recentLong: Double? = nil) -> PlanInput {
        PlanInput(raceDistanceMeters: distance, raceDate: raceDate(weeks: weeks), startDate: planMonday,
                  trainingDays: Set(days), longRunDay: longDay, recentWeeklySeconds: weekly * 60,
                  recentLongRunSeconds: recentLong.map { $0 * 60 }, heartRateZones: HRZones(lthr: 168),
                  easyPace: EasyPaceSample(secondsPerKm: 360, heartRate: 140),
                  fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: 25 * 60))
    }

    private func total(_ w: TrainingPlanWeek) -> Double { w.workouts.reduce(0) { $0 + $1.durationSeconds } }

    /// Long runs above the usual share that are longer than 150 minutes.
    private func longRunsOverTheBound(_ p: TrainingPlan) -> [String] {
        p.weeks.compactMap { w in
            guard let l = w.workouts.first(where: { $0.kind == .long }) else { return nil }
            let share = l.durationSeconds / total(w)
            guard share > GuardrailLimits.default.maxLongRunShare + 1e-9,
                  l.durationSeconds > PlanHeuristics.marathonLongRunTargetSeconds else { return nil }
            return "week \(w.index): L\(Int(l.durationSeconds / 60)) of \(Int(total(w) / 60))"
        }
    }

    // MARK: Marathon long-run trim (3.5 rule 5)

    func testTrimmedMarathonLongRunKeepsTheBoundAboveTheUsualShare() throws {
        // The review's repro: Tue/Thu/Sat, 480 min a week, no recent long run,
        // a marathon in 8 weeks, 4 even weeks with the long run at 30%.
        let days: [PlanWeekday] = [.tuesday, .thursday, .saturday]
        let h = history([480, 480, 480, 480], days: days, longDay: .saturday)
        let i = input(days: days, longDay: .saturday, weekly: 480, distance: Distance.marathon, weeks: 8)
        let r = PlanBuilder.build(i, history: h, timeZone: utc)
        let p = try XCTUnwrap(r.plan, "\(r.issues)")
        XCTAssertEqual(longRunsOverTheBound(p), [])
        XCTAssertTrue(p.guardrailReport.violations.isEmpty, "\(p.guardrailReport.violations.map(\.explanation))")
    }

    func testLongRunFitBoundaries() {
        // Fit at 34% (usual), at 44% (ceiling) up to 150 min, never below the usual fit.
        let limits = GuardrailLimits.default
        func fit(_ d: Double, rest: Double) -> Double {
            PlanBuilder.longRunFit(rest: rest * 60, marathon: d == Distance.marathon, limits: limits) / 60
        }
        // rest 300: usual floor(0.34*300/0.66) = 154, ceiling 235 -> above 150 the usual fit wins.
        XCTAssertEqual(fit(Distance.marathon, rest: 300), 154)
        XCTAssertEqual(fit(Distance.halfMarathon, rest: 300), 154)
        // rest 260: usual 133, ceiling 204 -> held to 150.
        XCTAssertEqual(fit(Distance.marathon, rest: 260), 150)
        XCTAssertEqual(fit(Distance.halfMarathon, rest: 260), 133)
        // rest 150: usual 77, ceiling 117 -> the ceiling fit.
        XCTAssertEqual(fit(Distance.marathon, rest: 150), 117)
        XCTAssertEqual(fit(Distance.halfMarathon, rest: 150), 77)
    }

    func testPropertyMarathonLongRunAboveTheUsualShareIsAtMost150Minutes() {
        let daySets: [([PlanWeekday], PlanWeekday)] = [
            ([.tuesday, .thursday, .saturday], .saturday),
            ([.monday, .wednesday, .saturday], .saturday),
            ([.monday, .wednesday, .friday, .sunday], .sunday),
            ([.tuesday, .wednesday, .thursday, .saturday, .sunday], .sunday),
            ([.monday, .tuesday, .wednesday, .thursday, .friday, .saturday], .saturday),
        ]
        var built = 0
        for (days, longDay) in daySets {
            for weekly in stride(from: 150.0, through: 600, by: 30) {
                for weeks in [8, 12, 18] {
                    for recentLong in [nil, weekly * 0.30] as [Double?] {
                        let h = history([weekly, weekly, weekly, weekly], days: days, longDay: longDay)
                        let i = input(days: days, longDay: longDay, weekly: weekly, distance: Distance.marathon,
                                      weeks: weeks, recentLong: recentLong)
                        guard let p = PlanBuilder.build(i, history: h, timeZone: utc).plan else { continue }
                        built += 1
                        XCTAssertEqual(longRunsOverTheBound(p), [], "\(days.count) days, \(Int(weekly)) min, \(weeks) weeks")
                        XCTAssertFalse(p.guardrailReport.violations.contains { $0.rule == .longRunShare })
                    }
                }
            }
        }
        XCTAssertGreaterThan(built, 100)
    }

    // MARK: Return-ramp quality limits (3.5 rule 4)

    /// Week `w` of `minutes` in all: `quality` threshold sessions of 40 min
    /// on Tuesday and Thursday, the rest as easy runs on four other days.
    private func week(_ w: Int, _ minutes: Double, quality: Int = 0, race: Bool = false) -> [PlannedWorkout] {
        let q = (0..<quality).map { F.workout("q\(w)-\($0)", week: w, day: 1 + 2 * $0, .quality(.threshold), minutes: 40) }
        let r = race ? [F.workout("race\(w)", week: w, day: 5, .race, minutes: 25, km: 5)] : []
        let easy = (minutes - 40 * Double(quality)) / 4
        let e = [0, 2, 4, 6].map { F.workout("e\(w)-\($0)", week: w, day: $0, .easy, minutes: easy) }
        return q + r + e
    }

    private func quality(_ h: [PlannedWorkout], _ p: [PlannedWorkout],
                         limits: GuardrailLimits = .default) -> [GuardrailViolation] {
        GuardrailChecker.check(history: h, planned: p, timeZone: utc, limits: limits).violations
            .filter { $0.rule == .qualitySessions }
    }

    func testRampWeekOneHoldsNoQualitySession() throws {
        let h = (0..<4).flatMap { week($0, 300) }   // week 4 empty: a one-week break
        XCTAssertEqual(quality(h, week(5, 200)), [])
        let v = try XCTUnwrap(quality(h, week(5, 200, quality: 1)).first)
        XCTAssertEqual(v.measured, 1)
        XCTAssertEqual(v.allowed, 0)
        XCTAssertTrue(v.explanation.contains("week 1 back after a week off"), v.explanation)
        XCTAssertTrue(v.explanation.contains("return ramp (SPEC 3.5 rule 4) allows no quality sessions"), v.explanation)
        // After two weeks off, the same.
        let two = (0..<4).flatMap { week($0, 300) }   // weeks 4 and 5 empty
        XCTAssertTrue(try XCTUnwrap(quality(two, week(6, 200, quality: 1)).first).explanation.contains("after 2 weeks off"))
    }

    func testRampWeekTwoHoldsAtMostOneQualitySession() throws {
        let h = (0..<4).flatMap { week($0, 300) }
        let back = week(5, 200)
        XCTAssertEqual(quality(h, back + week(6, 260, quality: 1)), [])
        let v = try XCTUnwrap(quality(h, back + week(6, 260, quality: 2)).first)
        XCTAssertEqual(v.allowed, 1)
        XCTAssertTrue(v.explanation.contains("week 2 back"), v.explanation)
        XCTAssertTrue(v.explanation.contains("at most 1 quality session"), v.explanation)
        // Week 3 back keeps the plain limit of 2.
        XCTAssertEqual(quality(h, back + week(6, 260, quality: 1) + week(7, 290, quality: 2)), [])
        XCTAssertEqual(quality(h, back + week(6, 260, quality: 1) + week(7, 290, quality: 3)).map(\.allowed), [2])
    }

    func testRampQualityCountsRacesAsTheWeeklyLimitDoes() {
        let h = (0..<4).flatMap { week($0, 300) }
        XCTAssertEqual(quality(h, week(5, 200, race: true)).map(\.allowed), [0])
        var limits = GuardrailLimits.default
        limits.racesCountAsQuality = false
        XCTAssertEqual(quality(h, week(5, 200, race: true), limits: limits), [])
    }

    func testRampQualityLimitFollowsTheRampItself() {
        // A longer break (3 weeks off) returns by rule 4's steps (SPEC 0.8): week 1 back has no quality
        // session. With the steps switched off, it keeps the plain rules.
        let h = (0..<4).flatMap { week($0, 300) }
        XCTAssertEqual(quality(h, week(7, 200, quality: 2)).map(\.allowed), [0])
        var noSteps = GuardrailLimits.default
        noSteps.longerBreakReturnSteps = []
        XCTAssertEqual(quality(h, week(7, 200, quality: 2), limits: noSteps), [])
        // The ramp switched off, or its quality limit, keeps the plain limit.
        var off = GuardrailLimits.default
        off.maxShortBreakWeeks = 0
        XCTAssertEqual(quality(h, week(5, 200, quality: 2), limits: off), [])
        var noLimit = GuardrailLimits.default
        noLimit.breakReturnMaxQualitySessions = []
        XCTAssertEqual(quality(h, week(5, 200, quality: 2), limits: noLimit), [])
        // Never above the weekly limit.
        var one = GuardrailLimits.default
        one.maxQualitySessionsPerWeek = 1
        one.breakReturnMaxQualitySessions = [2, 2]
        XCTAssertEqual(quality(h, week(5, 200, quality: 2), limits: one).map(\.allowed), [1])
        // A week that isn't a break (above a quarter of the level) sets no ramp.
        let notBreak = (0..<4).flatMap { week($0, 300) } + week(4, 76)
        XCTAssertEqual(quality(notBreak, week(5, 200, quality: 2)), [])
    }

    func testAnUnknownWeekThatMayHideABreakHoldsTheLeastRampQuality() throws {
        // 300, 300, 300, then 300 known plus a run of unknown time, then an
        // empty week: the ramp isn't certain (#40), but the empty week may be
        // a 1-week break, after which week 5 would be week 1 back.
        let broken = PlannedWorkout(id: "u", date: F.date(week: 3, day: 3), kind: .easy, durationSeconds: .nan)
        let h = (0..<4).flatMap { week($0, 300) } + [broken]
        let report = GuardrailChecker.check(history: h, planned: week(5, 200, quality: 1), timeZone: utc)
        XCTAssertEqual(report.violations.filter { $0.rule == .qualitySessions }, [])
        let skip = try XCTUnwrap(report.notEvaluated.first { $0.rule == .qualitySessions })
        XCTAssertTrue(skip.reason.contains("may hide a short break"), skip.reason)
        XCTAssertTrue(skip.reason.contains("as few as 0 quality sessions"), skip.reason)
        // No quality session: nothing to doubt; over the plain limit: a violation.
        let none = GuardrailChecker.check(history: h, planned: week(5, 200), timeZone: utc)
        XCTAssertFalse(none.notEvaluated.contains { $0.rule == .qualitySessions })
        XCTAssertEqual(quality(h, week(5, 220, quality: 3)).map(\.allowed), [2])
        // The plan builder's ledger keeps under that least limit, and a
        // known history sets the ramp's own.
        let ledger = PlanBuilder.LoadLedger(volumes: [300, 300, 300, nil, 0].map { $0.map { $0 * 60 } }, limits: .default,
                                            lows: [300, 300, 300, 300, 0].map { $0 * 60 })
        XCTAssertEqual(ledger.nextReturnRampMaxQuality, 0)
        var after = ledger
        after.append(200 * 60)
        XCTAssertEqual(after.nextReturnRampMaxQuality, 1)
        let known = PlanBuilder.LoadLedger(volumes: [300, 300, 300, 300, 0].map { $0 * 60 }, limits: .default)
        XCTAssertEqual(known.nextReturnRampMaxQuality, 0)
        let steady = PlanBuilder.LoadLedger(volumes: [300, 300, 300, 300, 300].map { $0 * 60 }, limits: .default)
        XCTAssertNil(steady.nextReturnRampMaxQuality)
    }

    func testPropertyPlansAfterAShortBreakHoldTheRampQualityLimits() {
        let daySets: [([PlanWeekday], PlanWeekday)] = [
            ([.tuesday, .thursday, .saturday], .saturday),
            ([.monday, .wednesday, .friday, .sunday], .sunday),
            ([.tuesday, .wednesday, .thursday, .saturday, .sunday], .sunday),
            ([.monday, .tuesday, .wednesday, .thursday, .friday, .saturday], .saturday),
        ]
        let breaks: [[Double]] = [[0], [0, 0], [0.2], [0.25, 0], [0, 0.1]]
        var rng = SplitMix(seed: 0x62_0001)
        var built = 0, controls = 0
        for (days, longDay) in daySets {
            for d in [Distance.fiveK, Distance.tenK, Distance.halfMarathon, Distance.marathon] {
                for shape in breaks + [[]] {
                    let weekly = 150 + Double(rng.next() % 300)
                    let totals = [weekly, weekly, weekly, weekly] + shape.map { $0 * weekly }
                    let h = history(totals, days: days, longDay: longDay)
                    let weeks = PlanHeuristics.minimumWeeks(RaceCategory(meters: d)!) + Int(rng.next() % 8)
                    let i = input(days: days, longDay: longDay, weekly: weekly * (shape.isEmpty ? 1 : 0.6),
                                  distance: d, weeks: weeks)
                    guard let p = PlanBuilder.build(i, history: h, timeZone: utc).plan else { continue }
                    let label = "\(days.count) days, \(Int(d)) m, \(Int(weekly)) min, shape \(shape)"
                    let report = GuardrailChecker.check(history: h, planned: p.workouts, timeZone: utc)
                    XCTAssertTrue(report.passed, "\(label): \(report.violations.map(\.explanation))")
                    let q = p.weeks.map { $0.workouts.filter { $0.kind.isQuality }.count }
                    if shape.isEmpty {
                        controls += 1
                        continue
                    }
                    built += 1
                    XCTAssertEqual(q[0], 0, label)
                    XCTAssertEqual(p.weeks[0].easyShare, 1, label)
                    XCTAssertLessThanOrEqual(q[1], 1, label)
                    XCTAssertTrue((0.75...0.85).contains(p.weeks[1].easyShare ?? 0), "\(label): \(p.weeks[1].easyShare ?? 0)")
                }
            }
        }
        XCTAssertGreaterThan(built, 40)
        XCTAssertGreaterThan(controls, 10)
    }

    // MARK: Race week forced to recovery (3.5 rule 3)

    func testRaceTooLongForAForcedRecoveryRaceWeekIsAnExplicitRefusal() throws {
        // A 5K plan's race week is its cadence recovery week, which counts the
        // race (3.5 rule 3, #62). With no goal or prediction the race takes
        // its easy-pace time, here 5 km at 16:40 per km (83 min 20 s), more
        // than 75% of a week of about 100 min can hold.
        let days: [PlanWeekday] = [.tuesday, .thursday, .saturday]
        let h = history([95, 95, 95, 95], days: days, longDay: .saturday)
        func fiveK(goal: Double?) -> PlanInput {
            var i = input(days: days, longDay: .saturday, weekly: 95, distance: Distance.fiveK, weeks: 5)
            i.easyPace = EasyPaceSample(secondsPerKm: 1000, heartRate: 140)
            i.fitnessAnchor = nil
            i.goalSeconds = goal
            return i
        }
        let refused = PlanBuilder.build(fiveK(goal: nil), history: h, timeZone: utc)
        XCTAssertNil(refused.plan)
        guard case .cannotBuild(let issues) = refused,
              case .volumeTooLowForRace(let race, let allowed)? = issues.first, issues.count == 1 else {
            return XCTFail("\(refused.issues)")
        }
        XCTAssertEqual(race, 5000, accuracy: 1e-6)
        // The same weeks with a 30-minute race build; the week before the
        // race is the base the recovery race week is measured against.
        let built = try XCTUnwrap(PlanBuilder.build(fiveK(goal: 30 * 60), history: h, timeZone: utc).plan)
        let weeks = built.weeks
        let last = weeks[weeks.count - 2].trainingSeconds
        let ratio = min(PlanHeuristics.recoveryWeekRatio, GuardrailLimits.default.recoveryWeekMaxRatio - 0.05)
        let allowedTotal = ratio * last
        XCTAssertLessThan(allowedTotal, race)
        XCTAssertEqual(allowed, allowedTotal / PlanHeuristics.guardrailMargin, accuracy: 1e-6)
        XCTAssertTrue(weeks.last!.isRecoveryWeek)
    }
}

/// A small seeded generator (SplitMix64) for the property tests.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
