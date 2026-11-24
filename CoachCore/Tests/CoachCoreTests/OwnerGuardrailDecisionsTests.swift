import XCTest
@testable import CoachCore

// The owner's guardrail decisions of #38, applied in #62 (SPEC 3.5 rules 2
// to 5): the race is left out of the weekly caps, a short break returns on a
// ramp to the pre-break volume, and a marathon plan's long run may take up to
// 45% of the week. Synthetic weeks only: every volume here is made up and
// stands for no real person.
final class OwnerGuardrailDecisionsTests: XCTestCase {
    private let utc = PlanFixture.utc
    private typealias F = PlanFixture

    // MARK: Fixtures

    /// Week `w`: four equal easy runs totalling `easy` minutes (none when 0),
    /// plus a race on the Saturday when `race` is given.
    private func week(_ w: Int, _ easy: Double, race: Double? = nil, raceKm: Double? = 42.195,
                      prefix: String = "w") -> [PlannedWorkout] {
        var out = easy > 0 ? F.easyWeek(w, minutes: easy, prefix: prefix) : []
        if let race {
            out.append(F.workout("\(prefix)\(w)-race", week: w, day: 5, .race, minutes: race, km: raceKm))
        }
        return out
    }

    /// Weeks from week 0 with easy volumes `easy`, races where `races` says.
    private func weeks(_ easy: [Double], start: Int = 0, races: [Int: Double] = [:], prefix: String) -> [PlannedWorkout] {
        easy.enumerated().flatMap { k, m in week(start + k, m, race: races[start + k], prefix: prefix) }
    }

    private func check(_ history: [PlannedWorkout], _ planned: [PlannedWorkout],
                       limits: GuardrailLimits = .default) -> GuardrailReport {
        GuardrailChecker.check(history: history, planned: planned, timeZone: utc, limits: limits)
    }

    /// Violations of `rules` only (the spike rule and the cadence fire on
    /// some of these synthetic weeks; each test names what it checks).
    private func violations(_ r: GuardrailReport, _ rules: GuardrailRule...) -> [GuardrailViolation] {
        r.violations.filter { rules.contains($0.rule) }
    }

    private func weekly(_ r: GuardrailReport) -> [GuardrailViolation] { violations(r, .weeklyIncrease) }
    private func rolling(_ r: GuardrailReport) -> [GuardrailViolation] { violations(r, .fourWeekIncrease) }

    // MARK: Race week (3.5 rule 3)

    func testRaceIsLeftOutOfTheWeeklyCheckAtItsBoundary() throws {
        // 300, a recovery week, 300; then 330 easy plus a 100 min race.
        let h = weeks([300, 200, 300], prefix: "h")
        XCTAssertTrue(weekly(check(h, week(3, 330, race: 100))).isEmpty)
        let r = check(h, week(3, 331, race: 100))
        let v = try XCTUnwrap(weekly(r).first)
        XCTAssertEqual(v.measured, 331 * 60, accuracy: 1e-6)
        XCTAssertEqual(v.allowed, 330 * 60, accuracy: 1e-6)
        XCTAssertTrue(v.explanation.contains("outside the race"), v.explanation)
        XCTAssertTrue(v.explanation.contains("SPEC 3.5 rule 3"), v.explanation)
        // A race of unknown length leaves the week's outside volume known.
        let unknown = check(h, week(3, 330) + [PlannedWorkout(id: "race", date: F.date(week: 3, day: 5), kind: .race,
                                                              durationSeconds: .nan, distanceMeters: 42_195)])
        XCTAssertTrue(weekly(unknown).isEmpty)
        XCTAssertFalse(unknown.notEvaluated.contains { $0.rule == .weeklyIncrease })
        // Without the race the same week is held to the same cap.
        XCTAssertEqual(weekly(check(h, week(3, 331))).first?.allowed ?? 0, 330 * 60, accuracy: 1e-6)
    }

    func testTheWeekAfterARaceIsMeasuredFromTheTrainingAroundIt() {
        // The race week's 330 min outside the race, not 430, is the next week's reference.
        let h = weeks([300, 200, 300], prefix: "h")
        let ok = check(h, week(3, 330, race: 100) + week(4, 363))
        XCTAssertTrue(weekly(ok).isEmpty, "\(weekly(ok).map(\.explanation))")
        let over = check(h, week(3, 330, race: 100) + week(4, 364))
        XCTAssertEqual(weekly(over).map(\.allowed), [363.0 * 60])
    }

    func testAShortTaperWithAMarathonAtTheEndPasses() {
        // 4 weeks of 200, a build to 220, a recovery week, 220, then a race
        // week of 220 easy plus a 300 min marathon. With the race counted the
        // race week would be 136% over the week before and the 4 weeks to it
        // 9% over 1.3 x 800; left out, every rule passes.
        let h = weeks([200, 200, 200, 200, 220, 170, 220], prefix: "h")
        let r = check(h, week(7, 220, race: 300))
        XCTAssertTrue(r.passed, "\(r.violations.map(\.explanation))")
        XCTAssertTrue(r.informationFlags.allSatisfy { $0.rule == .singleRunSpike })
        // The rolling check's own boundary, outside the race: 1040 allowed
        // for the 4 weeks, 610 of them already run.
        let loose = GuardrailLimits(maxWeeklyIncrease: 10)
        XCTAssertTrue(rolling(check(h, week(7, 430, race: 300), limits: loose)).isEmpty)
        let over = check(h, week(7, 431, race: 300), limits: loose)
        XCTAssertEqual(rolling(over).map(\.allowed), [1040.0 * 60])
        XCTAssertTrue(rolling(over).first?.explanation.contains("Races are left out") ?? false)
    }

    func testTheRaceStillCountsInTheRecoveryCadence() {
        // A recovery week, then three build weeks: the plan week must be a
        // recovery week (at most 80% of 300 = 240 min, race included).
        let h = weeks([300, 200, 300, 300, 300], prefix: "h")
        // 200 easy + a 30 min race = 230: a recovery week.
        XCTAssertTrue(violations(check(h, week(5, 200, race: 30)), .recoveryWeek).isEmpty)
        // 200 easy + a 100 min race = 300: a fourth build week, though 200
        // outside the race would be a recovery week.
        let r = check(h, week(5, 200, race: 100))
        XCTAssertEqual(violations(r, .recoveryWeek).count, 1)
        XCTAssertTrue(weekly(r).isEmpty)
    }

    // MARK: Return from a short break (3.5 rule 4)

    func testReturnRampAfterOneWeekOffAtItsBoundaries() throws {
        // Four weeks of 300, one week off: weeks back may hold 210, 270 and
        // 300, then the plain 10% rule (330).
        let h = weeks([300, 300, 300, 300, 0], prefix: "h")
        let onRamp = check(h, weeks([210, 270, 300, 330], start: 5, prefix: "p"))
        XCTAssertTrue(weekly(onRamp).isEmpty, "\(weekly(onRamp).map(\.explanation))")
        XCTAssertTrue(rolling(onRamp).isEmpty)
        for (k, plan) in [[211.0], [210, 271], [210, 270, 301], [210, 270, 300, 331]].enumerated() {
            let r = check(h, weeks(plan, start: 5, prefix: "p"))
            let v = try XCTUnwrap(weekly(r).first, "step \(k + 1)")
            XCTAssertEqual(weekly(r).count, 1)
            XCTAssertEqual(v.weekStart, F.date(week: 5 + k, day: 0, hour: 0))
            XCTAssertEqual(v.allowed, [210, 270, 300, 330][k] * 60, accuracy: 1e-6)
            if k < 3 {
                XCTAssertTrue(v.explanation.contains("return ramp"), v.explanation)
                XCTAssertTrue(v.explanation.contains("week \(k + 1) back after a week"), v.explanation)
            } else {
                XCTAssertFalse(v.explanation.contains("return ramp"), v.explanation)
            }
        }
    }

    func testReturnRampRisesNoFasterThanItsOwnSteps() throws {
        // Back at only 140 (below the first step): week 2 may rise by 0.9 / 0.7
        // of it (180), not jump to 270.
        let h = weeks([300, 300, 300, 300, 0, 0], prefix: "h")
        XCTAssertTrue(weekly(check(h, weeks([140, 180], start: 6, prefix: "p"))).isEmpty)
        let r = check(h, weeks([140, 181], start: 6, prefix: "p"))
        let v = try XCTUnwrap(weekly(r).first)
        XCTAssertEqual(v.allowed, 180 * 60, accuracy: 1e-6)
        XCTAssertTrue(v.explanation.contains("more than the week before"), v.explanation)
        XCTAssertTrue(v.explanation.contains("after 2 weeks"), v.explanation)
    }

    func testBreakLineIsAQuarterOfThePreBreakWeek() {
        // 75 min after four weeks of 300 is a break week; 76 is not (a
        // recovery week, so the plain rule steps back to 300 and allows 330).
        let atLine = weeks([300, 300, 300, 300, 75], prefix: "h")
        let overLine = weeks([300, 300, 300, 300, 76], prefix: "h")
        XCTAssertEqual(weekly(check(atLine, week(5, 300))).map(\.allowed), [210.0 * 60])
        XCTAssertTrue(weekly(check(overLine, week(5, 300))).isEmpty)
        XCTAssertEqual(weekly(check(overLine, week(5, 331))).map(\.allowed), [330.0 * 60])
        // The pre-break level is the mean of up to 4 weeks before the break.
        let mixed = weeks([200, 400, 300, 300, 0], prefix: "h")
        XCTAssertEqual(weekly(check(mixed, week(5, 300))).map(\.allowed), [0.7 * 300 * 60])
    }

    func testALongerBreakReturnsByTheSteps() {
        // Three weeks off (3.5 rule 4, SPEC 0.8, #32): the zero weeks make the
        // plain 10% check useless, so week 1 back holds at most 65% of the
        // pre-break 300, 195 minutes. With the ramp off, the plain rules: the
        // zero reference leaves the 10% check unevaluated, as before #62.
        let h = weeks([300, 300, 300, 300, 0, 0, 0], prefix: "h")
        let r = check(h, week(7, 400))
        XCTAssertEqual(weekly(r).map(\.allowed), [195.0 * 60])
        XCTAssertTrue(weekly(check(h, week(7, 195))).isEmpty)
        let plain = check(h, week(7, 400), limits: GuardrailLimits(maxShortBreakWeeks: 0))
        XCTAssertTrue(weekly(plain).isEmpty)
        XCTAssertTrue(plain.notEvaluated.contains { $0.rule == .weeklyIncrease && $0.reason.contains("no volume") })
    }

    func testARaceOnlyWeekIsNotABreak() {
        // A week holding only a race has no volume outside races, but is not
        // a break: the plain rule steps back past it as a recovery week.
        let h = weeks([300, 300, 300, 300, 0], races: [4: 40], prefix: "h")
        let r = check(h, week(5, 300))
        XCTAssertTrue(weekly(r).isEmpty, "\(weekly(r).map(\.explanation))")
        // A week of unknown volume is not a break week either.
        let unknown = weeks([300, 300, 300, 300], prefix: "h")
            + [PlannedWorkout(id: "u", date: F.date(week: 4, day: 2), kind: .easy, durationSeconds: .nan)]
        XCTAssertFalse(weekly(check(unknown, week(5, 300))).contains { $0.explanation.contains("return ramp") })
    }

    func testOwnersBreakExampleRollingCheck() throws {
        // #38: history 240, 240, 240, 0, 0, 240, 240, 240. The 4 weeks before
        // the window count at the pre-break level (960, so 1248 allowed) and
        // not at 480 (624, already broken by the 720 run since the break).
        let h = weeks([240, 240, 240, 0, 0, 240, 240, 240], prefix: "h")
        let r = check(h, week(8, 240))
        XCTAssertTrue(rolling(r).isEmpty, "\(rolling(r).map(\.explanation))")
        XCTAssertTrue(weekly(r).isEmpty)
        let plain = check(h, week(8, 240), limits: GuardrailLimits(maxShortBreakWeeks: 0))
        XCTAssertEqual(rolling(plain).map(\.allowed), [624.0 * 60])
        // The rolling check's boundary, with the weekly rule set wide.
        let loose = GuardrailLimits(maxWeeklyIncrease: 10)
        XCTAssertTrue(rolling(check(h, week(8, 528), limits: loose)).isEmpty)
        let over = try XCTUnwrap(rolling(check(h, week(8, 529), limits: loose)).first)
        XCTAssertEqual(over.allowed, 1248 * 60, accuracy: 1e-6)
        XCTAssertTrue(over.explanation.contains("short break"), over.explanation)
    }

    func testAnUnknownWeekNearABreakKeepsThePlainRulesAndTheLeastRampCap() throws {
        // 300, 300, 300, then 300 known plus a run of unknown time, then an
        // empty week. The unknown week could hide a longer break, so the ramp
        // is not used (plain rules: 330 over the unknown week's least, #40),
        // but the empty week may be a 1-week break, after which the ramp
        // would allow 70% of a pre-break mean of at least 300.
        let broken = PlannedWorkout(id: "u", date: F.date(week: 3, day: 3), kind: .easy, durationSeconds: .nan)
        let h = weeks([300, 300, 300, 300, 0], prefix: "h") + [broken]
        let mid = check(h, week(5, 300))
        XCTAssertTrue(weekly(mid).isEmpty, "\(weekly(mid).map(\.explanation))")
        XCTAssertTrue(mid.notEvaluated.contains { $0.rule == .weeklyIncrease && $0.reason.contains("may hide a short break") })
        XCTAssertFalse(mid.notEvaluated.contains { $0.rule == .weeklyIncrease && $0.weekStart == F.date(week: 5, day: 0, hour: 0)
            && !$0.reason.contains("may hide") })
        XCTAssertTrue(check(h, week(5, 210)).notEvaluated.allSatisfy { $0.rule != .weeklyIncrease || $0.weekStart != F.date(week: 5, day: 0, hour: 0) })
        XCTAssertEqual(weekly(check(h, week(5, 331))).map(\.allowed), [330.0 * 60])
        // The plan builder's ledger keeps under that least cap.
        let ledger = PlanBuilder.LoadLedger(volumes: [300, 300, 300, nil, 0].map { $0.map { $0 * 60 } }, limits: .default,
                                            lows: [300, 300, 300, 300, 0].map { $0 * 60 })
        XCTAssertEqual(ledger.nextCap, 210 * 60, accuracy: 1e-6)
        // With every week known the same history is a plain short break.
        let known = weeks([300, 300, 300, 300, 0], prefix: "h")
        XCTAssertEqual(weekly(check(known, week(5, 300))).map(\.allowed), [210.0 * 60])
        XCTAssertTrue(weekly(check(known, week(5, 300))).first?.explanation.contains("return ramp") ?? false)
    }

    func testSwitchingTheRampOffRestoresThePlainRules() {
        let h = weeks([300, 300, 300, 300, 0], prefix: "h")
        let plain = GuardrailLimits(maxShortBreakWeeks: 0)
        XCTAssertTrue(weekly(check(h, week(5, 330), limits: plain)).isEmpty)
        XCTAssertEqual(weekly(check(h, week(5, 331), limits: plain)).map(\.allowed), [330.0 * 60])
        let noSteps = GuardrailLimits(breakReturnSteps: [])
        XCTAssertTrue(weekly(check(h, week(5, 330), limits: noSteps)).isEmpty)
        // Degenerate limits don't trap or invent breaks.
        for limits in [GuardrailLimits(breakWeekMaxRatio: 0), GuardrailLimits(preBreakWeeks: 0)] {
            XCTAssertTrue(weekly(check(h, week(5, 330), limits: limits)).isEmpty)
        }
        // An invalid ratio or step is stored as its default (#142), so the
        // ramp applies as it does by default.
        let ramp = check(h, week(5, 330))
        XCTAssertEqual(weekly(ramp).map(\.allowed), [210.0 * 60])
        for limits in [GuardrailLimits(breakWeekMaxRatio: .nan), GuardrailLimits(breakReturnSteps: [.nan, 1])] {
            XCTAssertEqual(check(h, week(5, 330), limits: limits), ramp)
        }
    }

    // MARK: Marathon long-run share (3.5 rule 5)

    /// Week 1: three easy runs and a long run of `long` minutes in 400; a race in week 2.
    private func shareWeek(long: Double, raceKm: Double?, raceWeek: Int = 2) -> [PlannedWorkout] {
        let easy = (400 - long) / 3
        return (0..<3).map { F.workout("e\($0)", week: 1, day: $0 * 2, .easy, minutes: easy) }
            + [F.workout("long", week: 1, day: 6, .long, minutes: long),
               F.workout("race", week: raceWeek, day: 6, .race, minutes: 200, km: raceKm)]
    }

    private func share(_ r: GuardrailReport) -> (violations: [GuardrailViolation], flags: [GuardrailFlag]) {
        (violations(r, .longRunShare), r.informationFlags.filter { $0.rule == .longRunShare })
    }

    func testMarathonLongRunShareAtItsBoundaries() throws {
        // 35%: nothing. 44% and 45%: a warning flag on the long run. 46%: a violation at 45%.
        let usual = share(check([], shareWeek(long: 140, raceKm: 42.195)))
        XCTAssertTrue(usual.violations.isEmpty && usual.flags.isEmpty)
        for long in [176.0, 180] {
            let s = share(check([], shareWeek(long: long, raceKm: 42.195)))
            XCTAssertTrue(s.violations.isEmpty, "\(long)")
            let f = try XCTUnwrap(s.flags.first)
            XCTAssertEqual(f.workoutID, "long")
            XCTAssertEqual(f.allowed, 0.35)
            XCTAssertTrue(f.explanation.contains("warning"), f.explanation)
        }
        let over = share(check([], shareWeek(long: 184, raceKm: 42.195)))
        XCTAssertEqual(over.violations.map(\.allowed), [0.45])
        XCTAssertTrue(over.violations.first?.explanation.contains("marathon plan") ?? false)
        XCTAssertTrue(over.flags.isEmpty)
        // A custom ceiling below the usual share never lowers it.
        let low = share(check([], shareWeek(long: 140, raceKm: 42.195), limits: GuardrailLimits(marathonMaxLongRunShare: 0.3)))
        XCTAssertTrue(low.violations.isEmpty && low.flags.isEmpty)
    }

    func testOtherDistancesKeepTheUsualShare() {
        for km: Double? in [21.0975, 10, nil] {
            let s = share(check([], shareWeek(long: 176, raceKm: km)))
            XCTAssertEqual(s.violations.map(\.allowed), [0.35], "\(String(describing: km))")
            XCTAssertTrue(s.flags.isEmpty)
        }
        // No race at all.
        let none = share(check([], shareWeek(long: 176, raceKm: 42.195).filter { $0.kind != .race }))
        XCTAssertEqual(none.violations.map(\.allowed), [0.35])
        // A week after the marathon is no longer in the marathon plan.
        let after = share(check([], shareWeek(long: 176, raceKm: 42.195, raceWeek: 0)))
        XCTAssertEqual(after.violations.map(\.allowed), [0.35])
    }

    // MARK: Properties: SPEC 3.5 as amended

    private func easyMinutes(_ ws: [PlannedWorkout], week w: Int) -> Double {
        ws.filter { $0.kind != .race && PlanCalendar.weekStart(containing: $0.date, timeZone: utc) == F.date(week: w, day: 0, hour: 0) }
            .reduce(0) { $0 + $1.durationSeconds } / 60
    }

    private struct Key: Hashable { let rule: GuardrailRule; let week: Date; let measured: Double; let allowed: Double }
    private func keys(_ r: GuardrailReport) -> Set<Key> {
        Set((weekly(r) + rolling(r)).map { Key(rule: $0.rule, week: $0.weekStart, measured: $0.measured, allowed: $0.allowed) })
    }

    func testPropertyRaceVolumeNeverChangesTheWeeklyCaps() {
        // Random weeks of 150 to 400 min (no breaks), races in random weeks.
        // The weekly and rolling findings are the same whatever each race's
        // length, and the same as with the races taken out.
        var rng = SplitMix(seed: 62)
        for n in 0..<150 {
            let count = 6 + Int(rng.next() * 8)
            let easy = (0..<count).map { _ in (150 + rng.next() * 250).rounded() }
            var races: [Int: Double] = [:]
            for w in 0..<count where rng.next() < 0.25 { races[w] = 20 + rng.next() * 250 }
            let split = 1 + Int(rng.next() * Double(count - 1))
            func report(_ r: [Int: Double]) -> GuardrailReport {
                let all = weeks(easy, races: r, prefix: "w")
                let cut = F.date(week: split, day: 0, hour: 0)
                return check(all.filter { $0.date < cut }, all.filter { $0.date >= cut })
            }
            let base = keys(report(races))
            XCTAssertEqual(base, keys(report(races.mapValues { $0 * 3 + 7 })), "#\(n)")
            XCTAssertEqual(base, keys(report([:])), "#\(n) \(easy) \(races)")
        }
    }

    func testPropertyAReturnOnTheRampPasses() {
        // Four pre-break weeks around a level L, one or two weeks at most
        // 25% of it, then the ramp's steps of the pre-break mean and the
        // mean again (all scaled by one factor of 0.9 to 1): no weekly or
        // rolling violation.
        var rng = SplitMix(seed: 38)
        for n in 0..<200 {
            let pre = (0..<4).map { _ in (200 + rng.next() * 300).rounded() }
            let level = pre.reduce(0, +) / 4
            let off = 1 + Int(rng.next() * 2)
            let breakWeeks = (0..<off).map { _ in (rng.next() * 0.25 * level * 0.99).rounded(.down) }
            let jitter = 0.9 + 0.1 * rng.next()
            let back = [0.7, 0.9, 1.0, 1.0].map { $0 * level * jitter }
            let h = weeks(pre + breakWeeks, prefix: "h")
            let p = weeks(back, start: pre.count + off, prefix: "p")
            let r = check(h, p)
            XCTAssertTrue(weekly(r).isEmpty && rolling(r).isEmpty,
                          "#\(n) \(pre) \(breakWeeks) \(back): \((weekly(r) + rolling(r)).map(\.explanation))")
        }
    }

    func testPropertyRampCapsFollowTheirFormulaAndNeverPassThePreBreakLevel() {
        // Short breaks after random weeks, random weeks back: each ramp cap
        // equals step x level, or the ramp's own rise over the week before
        // when lower, and never passes the pre-break level.
        var rng = SplitMix(seed: 45)
        let steps = GuardrailLimits.default.breakReturnSteps
        for n in 0..<200 {
            let pre = (0..<(1 + Int(rng.next() * 4))).map { _ in (200 + rng.next() * 300).rounded() }
            let level = pre.reduce(0, +) / Double(pre.count)
            let off = 1 + Int(rng.next() * 2)
            let back = (0..<3).map { _ in (rng.next() * 1.3 * level).rounded() }
            let volumes: [Double?] = (pre + [Double](repeating: 0, count: off) + back).map { $0 * 60 }
            let lows = volumes.map { $0 ?? 0 }
            let limits = GuardrailLimits.default
            let breaks = GuardrailChecker.breaks(volumes: volumes, lows: lows, raceWeeks: [], limits: limits)
            for k in 1...3 {
                let i = pre.count + off + k - 1
                // A week back under the break line starts a new break.
                if breaks.contains(where: { i >= $0.first && i < $0.end }) { break }
                guard let ramp = GuardrailChecker.returnRamp(i, volumes: volumes, lows: lows, breaks: breaks, limits: limits) else {
                    XCTFail("#\(n) week \(k) back has no ramp: \(volumes) \(breaks)"); break
                }
                XCTAssertEqual(ramp.brk.level, level * 60, accuracy: 1e-6, "#\(n)")
                var expected = steps[k - 1] * level * 60
                if k > 1 { expected = min(expected, volumes[i - 1]! * steps[k - 1] / steps[k - 2]) }
                XCTAssertEqual(ramp.allowed, expected, accuracy: 1e-6, "#\(n) week \(k)")
                XCTAssertLessThanOrEqual(ramp.allowed, ramp.brk.level + 1e-6)
                // The checker holds the week to exactly that cap.
                let h = weeks(pre + [Double](repeating: 0, count: off) + Array(back.prefix(k - 1)), prefix: "h")
                let ok = check(h, week(i, ramp.allowed / 60))
                XCTAssertFalse(weekly(ok).contains { $0.explanation.contains("return ramp") }, "#\(n) week \(k)")
                let over = check(h, week(i, ramp.allowed / 60 + 1))
                XCTAssertTrue(weekly(over).contains { abs($0.allowed - ramp.allowed) < 1e-6 }, "#\(n) week \(k)")
            }
        }
    }

    func testPropertySwitchingTheLongerBreakReturnOffRestoresThePlainRules() {
        // Breaks of 3 or 4 weeks (and weeks back too big to start a new one):
        // with the longer-break return off (SPEC 0.8 made it the default), the
        // report is the same as with the whole ramp switched off.
        var rng = SplitMix(seed: 20)
        let plain = GuardrailLimits(maxShortBreakWeeks: 0)
        let off = GuardrailLimits(longerBreakReturnSteps: [])
        for n in 0..<120 {
            let pre = (0..<(2 + Int(rng.next() * 4))).map { _ in (200 + rng.next() * 200).rounded() }
            let breakWeeks = 3 + Int(rng.next() * 2)
            let back = (0..<(2 + Int(rng.next() * 6))).map { _ in (101 + rng.next() * 300).rounded() }
            let all = pre + [Double](repeating: 0, count: breakWeeks) + back
            let split = pre.count + breakWeeks + Int(rng.next() * Double(back.count))
            let h = weeks(Array(all.prefix(split)), prefix: "h")
            let p = weeks(Array(all.dropFirst(split)), start: split, prefix: "p")
            XCTAssertEqual(check(h, p, limits: off), check(h, p, limits: plain), "#\(n) \(all)")
        }
    }

    func testPropertyMarathonShareCeiling() {
        // Random weeks and long-run shares: above 45% a violation in a
        // marathon plan (35% otherwise); between 35 and 45% a marathon flag.
        var rng = SplitMix(seed: 5)
        for n in 0..<300 {
            let total = 120 + rng.next() * 500
            let s = 0.2 + rng.next() * 0.4
            guard abs(s - 0.35) > 1e-6, abs(s - 0.45) > 1e-6 else { continue }
            let marathon = rng.next() < 0.5
            let long = s * total
            let easy = (total - long) / 3
            let plan = (0..<3).map { F.workout("e\($0)", week: 1, day: $0 * 2, .easy, minutes: easy) }
                + [F.workout("long", week: 1, day: 6, .long, minutes: long),
                   F.workout("race", week: 3, day: 6, .race, minutes: 200, km: marathon ? 42.195 : 21.0975)]
            let r = share(check([], plan))
            let limit = marathon ? 0.45 : 0.35
            XCTAssertEqual(!r.violations.isEmpty, s > limit, "#\(n) share \(s) marathon \(marathon)")
            XCTAssertEqual(!r.flags.isEmpty, marathon && s > 0.35 && s <= 0.45, "#\(n) share \(s)")
        }
    }

    // MARK: The plan builder's ledger reads breaks and races the same way

    func testPropertyLedgerCapMatchesTheCheckerWithBreaksAndRaces() {
        // Random weeks with short and long breaks and races: a next week at
        // the ledger's cap passes the checker's weekly and rolling rules, and
        // 1% plus a minute more breaks one of them.
        var rng = SplitMix(seed: 86)
        var checked = 0
        for n in 0..<250 {
            let count = 4 + Int(rng.next() * 9)
            var easy: [Double] = []
            var races: [Int: Double] = [:]
            var w = 0
            while w < count {
                if w >= 2, rng.next() < 0.15 {
                    let off = 1 + Int(rng.next() * 3)
                    for _ in 0..<off where easy.count < count { easy.append(rng.next() < 0.5 ? 0 : (rng.next() * 40).rounded()) }
                    w = easy.count
                    continue
                }
                easy.append((150 + rng.next() * 250).rounded())
                if rng.next() < 0.15 { races[w] = 30 + rng.next() * 200 }
                w += 1
            }
            let totals: [Double?] = easy.indices.map { (easy[$0] + (races[$0] ?? 0)) * 60 }
            let outside: [Double?] = easy.map { $0 * 60 }
            let ledger = PlanBuilder.LoadLedger(volumes: totals, limits: .default, outside: outside,
                                                raceWeeks: Set(races.keys))
            let cap = ledger.nextCap
            guard cap.isFinite, cap > 60 else { continue }
            checked += 1
            let h = weeks(easy, races: races, prefix: "h")
            let ok = check(h, week(easy.count, cap / 60, prefix: "p"))
            XCTAssertTrue((weekly(ok) + rolling(ok)).isEmpty,
                          "#\(n) \(easy) \(races) cap \(cap / 60): \((weekly(ok) + rolling(ok)).map(\.explanation))")
            let over = check(h, week(easy.count, cap / 60 * 1.01 + 1, prefix: "p"))
            XCTAssertFalse((weekly(over) + rolling(over)).isEmpty, "#\(n) \(easy) \(races) cap \(cap / 60)")
        }
        XCTAssertGreaterThan(checked, 150)
    }
}

/// A small seeded generator so the properties are repeatable.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    /// Uniform in [0, 1).
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
