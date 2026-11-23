import XCTest
@testable import CoachCore

// Issue #48: a plan that starts after the start's week has begun leaves that
// week open, and the runner may log more runs in it after the plan is built.
// The history plus those runs plus the plan must still pass SPEC 3.5.
//
// Synthetic runners only: every volume, pace and heart rate here is made up
// and stands for no real person.
final class PlanBuilderPartialWeekTests: XCTestCase {
    private let utc = PlanFixture.utc
    private var cal: Calendar { PlanCalendar.calendar(timeZone: utc) }
    /// Monday 2026-03-02 00:00 UTC: the start's week.
    private var startWeek: Date { PlanFixture.date(week: 8, day: 0, hour: 0) }
    private var nextMonday: Date { startWeek.addingTimeInterval(7 * 86_400) }

    private struct Runner {
        let name: String
        let weeklyMinutes: Double
        let longMinutes: Double
        let days: [PlanWeekday]
        let longDay: PlanWeekday
        let lthr: Double
        let fiveKMinutes: Double
        let easyPace: Double
        let easyHR: Double
    }

    private let runners: [Runner] = [
        Runner(name: "low-3day", weeklyMinutes: 150, longMinutes: 55, days: [.tuesday, .thursday, .saturday],
               longDay: .saturday, lthr: 171, fiveKMinutes: 30, easyPace: 420, easyHR: 139),
        Runner(name: "mid-4day-mon", weeklyMinutes: 240, longMinutes: 80, days: [.monday, .wednesday, .friday, .sunday],
               longDay: .sunday, lthr: 164, fiveKMinutes: 24, easyPace: 360, easyHR: 137),
        Runner(name: "mid-5day", weeklyMinutes: 300, longMinutes: 95, days: [.tuesday, .wednesday, .thursday, .saturday, .sunday],
               longDay: .sunday, lthr: 158, fiveKMinutes: 22, easyPace: 345, easyHR: 132),
        Runner(name: "high-6day-mon", weeklyMinutes: 420, longMinutes: 120,
               days: [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday],
               longDay: .saturday, lthr: 176, fiveKMinutes: 19, easyPace: 305, easyHR: 146)
    ]

    /// Week shapes before the start's week (multipliers of the runner's week).
    private let shapes: [(String, [Double])] = [
        // Two build weeks after a recovery week: a finished start week is the
        // third, so the plan's first week must be a recovery week (the #48 case).
        ("streak-at-limit", [1, 1, 1, 0.75, 1, 1]),
        ("after-recovery", [1, 1, 1, 1, 1, 0.75]),
        ("steady", [1, 1, 1, 1, 1, 1, 1, 1]),
        ("rising", [0.85, 0.9, 0.95, 0.7, 0.9, 0.95, 1.0])
    ]

    // MARK: Fixtures

    /// The runner's usual sessions in the week starting `weekStart`, at 07:00.
    private func usualWeek(_ r: Runner, weekStart: Date, scale: Double, id: String) -> [PlannedWorkout] {
        let total = r.weeklyMinutes * scale
        guard total > 0 else { return [] }
        let long = min(r.longMinutes * scale, total * 0.33)
        let others = Double(r.days.count - 1)
        return r.days.map { d in
            let minutes = d == r.longDay ? long : (total - long) / others
            let day = cal.date(byAdding: .day, value: d.rawValue, to: weekStart)!
            return PlannedWorkout(id: "\(id)-\(d.rawValue)", date: cal.date(bySettingHour: 7, minute: 0, second: 0, of: day)!,
                                  kind: d == r.longDay ? .long : .easy, durationSeconds: minutes * 60)
        }
    }

    private func history(_ r: Runner, shape: [Double]) -> [PlannedWorkout] {
        shape.enumerated().flatMap { k, m in
            usualWeek(r, weekStart: startWeek.addingTimeInterval(Double(k - shape.count) * 7 * 86_400), scale: m, id: "h\(k)")
        }
    }

    private func input(_ r: Runner, shape: [Double], distance: Double, start: Date, weeks: Int) -> PlanInput {
        let raceDay = cal.date(byAdding: .day, value: (weeks - 1) * 7 + 6, to: nextMonday)!
        let recent = shape.suffix(4).reduce(0, +) / Double(min(4, shape.count))
        let five = r.fiveKMinutes * 60
        return PlanInput(raceDistanceMeters: distance, raceDate: cal.date(bySettingHour: 8, minute: 0, second: 0, of: raceDay)!,
                         goalSeconds: nil, startDate: start, trainingDays: Set(r.days), longRunDay: r.longDay,
                         maxSessionSeconds: nil, recentWeeklySeconds: r.weeklyMinutes * 60 * recent,
                         recentLongRunSeconds: r.longMinutes * 60, heartRateZones: HRZones(lthr: r.lthr)!,
                         easyPace: EasyPaceSample(secondsPerKm: r.easyPace, heartRate: r.easyHR),
                         fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: five),
                         predictedRaceSeconds: RacePredictor.riegel(knownMeters: Distance.fiveK, knownSeconds: five,
                                                                    targetMeters: distance))
    }

    /// Easy runs adding `minutes` to the start's week after `start`: one at
    /// 22:00 on each remaining day of the week, the start's day included.
    private func extraRuns(minutes: Double, after start: Date, id: String) -> [PlannedWorkout] {
        guard minutes > 0 else { return [] }
        let startDay = PlanWeekday(of: start, timeZone: utc).rawValue
        let dates = (startDay...6).map { d -> Date in
            let day = cal.date(byAdding: .day, value: d, to: startWeek)!
            return cal.date(bySettingHour: 22, minute: 0, second: 0, of: day)!
        }.filter { $0 > start }
        return dates.enumerated().map { k, date in
            PlannedWorkout(id: "\(id)-\(k)", date: date, kind: .easy, durationSeconds: minutes * 60 / Double(dates.count))
        }
    }

    private func minutes(_ ws: [PlannedWorkout]) -> Double { ws.reduce(0) { $0 + $1.durationSeconds } / 60 }

    /// The biggest start week SPEC 3.5's weekly and rolling 4-week rules allow
    /// after the weeks before it, found with the checker itself (not the
    /// builder's ledger), or nil when they set no limit.
    private func biggestAllowedWeek(before: [PlannedWorkout], soFar: [PlannedWorkout], start: Date) -> Double? {
        func passes(_ total: Double) -> Bool {
            let week = soFar + extraRuns(minutes: total - minutes(soFar), after: start, id: "probe")
            let report = GuardrailChecker.check(history: before, planned: week, timeZone: utc)
            return !report.violations.contains { $0.rule == .weeklyIncrease || $0.rule == .fourWeekIncrease }
        }
        var lo = minutes(soFar), hi = 10_000.0
        guard !passes(hi) else { return nil }
        guard passes(lo) else { return lo }
        for _ in 0..<50 { let mid = (lo + hi) / 2; if passes(mid) { lo = mid } else { hi = mid } }
        return lo
    }

    /// The rest-of-week cases: no more runs, the runner's usual pattern, the
    /// biggest week 3.5 allows (or the baseline plus 10% where it sets no
    /// limit), the finished week just over and just at the recovery line
    /// (the week before × 0.8), and a sweep in between.
    private func restOfWeek(_ r: Runner, history h: [PlannedWorkout], input i: PlanInput) -> [(String, [PlannedWorkout])] {
        let start = i.startDate
        let soFar = h.filter { $0.date >= startWeek }
        let before = h.filter { $0.date < startWeek }
        let low = minutes(soFar)
        let usual = usualWeek(r, weekStart: startWeek, scale: 1, id: "u").filter { $0.date >= start }
        let big = biggestAllowedWeek(before: before, soFar: soFar, start: start)
            ?? (i.recentWeeklySeconds! / 60 * 1.1)
        let weekBefore = minutes(before.filter { $0.date >= startWeek.addingTimeInterval(-7 * 86_400) })
        var cases: [(String, [PlannedWorkout])] = [("none", []), ("usual", usual)]
        var totals: [(String, Double)] = [("big", big), ("over-line", 0.8 * weekBefore + 0.5), ("at-line", 0.8 * weekBefore)]
        for k in 1...6 { totals.append(("sweep\(k)", low + (big - low) * Double(k) / 7)) }
        for (name, total) in totals where total > low && total <= big + 1e-6 {
            cases.append((name, extraRuns(minutes: total - low, after: start, id: name)))
        }
        return cases
    }

    /// Starts after the start's week has begun, so the plan begins next Monday.
    private func starts(_ r: Runner) -> [(String, Date, [PlannedWorkout])] {
        let monday0700 = startWeek.addingTimeInterval(7 * 3600)
        // Monday morning after a run logged that morning: the runner's usual
        // Monday run, or a 40-minute extra one on a runner who rests Mondays.
        let mondayRun = r.days.contains(.monday) ? []
            : [PlannedWorkout(id: "mon-run", date: monday0700, kind: .easy, durationSeconds: 40 * 60)]
        return [
            ("mon-09:00-after-run", startWeek.addingTimeInterval(9 * 3600), mondayRun),
            ("mon-13:00", startWeek.addingTimeInterval(13 * 3600), []),
            ("wed-09:00", startWeek.addingTimeInterval((2 * 24 + 9) * 3600), []),
            ("thu-18:00", startWeek.addingTimeInterval((3 * 24 + 18) * 3600), []),
            ("sat-20:00", startWeek.addingTimeInterval((5 * 24 + 20) * 3600), [])
        ]
    }

    // MARK: The property

    /// SPEC 3.5 holds for history + the rest of the start's week + the plan,
    /// for a Monday-morning and mid-week plans, across rest-of-week cases.
    /// Each plan is provisional; rebuilt on its first Monday it is final,
    /// passes 3.5 again and, after the usual rest of the week, gets back to
    /// at least the runner's recent load.
    func testThreePointFiveHoldsWhateverTheRestOfTheStartWeekBrings() {
        var built = 0, combos = 0, rebuiltPeaks = 0, refused: [String] = []
        for r in runners {
            for (shapeName, shape) in shapes {
                for (startName, start, extra) in starts(r) {
                    let usualSoFar = usualWeek(r, weekStart: startWeek, scale: 1, id: "s").filter { $0.date < start }
                    let h = history(r, shape: shape) + usualSoFar + extra
                    for d in [Distance.tenK, Distance.halfMarathon] {
                        combos += 1
                        let i = input(r, shape: shape, distance: d, start: start, weeks: 14)
                        let label = "\(r.name) \(shapeName) \(startName) \(Int(d))m"
                        let result = PlanBuilder.build(i, history: h, timeZone: utc)
                        guard let plan = result.plan else {
                            // Only explicit refusals; never a plan that fails the checker.
                            for issue in result.issues {
                                switch issue {
                                case .noWorkableWeek, .historyVolumeUnknown, .volumeTooLowForRace,
                                     .startWeekWithoutReference: break
                                default: XCTFail("\(label): \(issue)")
                                }
                            }
                            refused.append("\(label): \(result.issues)")
                            continue
                        }
                        built += 1
                        XCTAssertEqual(plan.weeks.first?.weekStart, nextMonday, label)
                        XCTAssertEqual(plan.rebuildDate, nextMonday, label)
                        XCTAssertEqual(result.rebuildDate, nextMonday, label)
                        XCTAssertTrue(plan.notes.contains { $0.contains("provisional") }, label)
                        let cases = restOfWeek(r, history: h, input: i)
                        for (restName, rest) in cases {
                            XCTAssertTrue(rest.allSatisfy { $0.date >= start && $0.date < nextMonday }, label)
                            let report = GuardrailChecker.check(history: h + rest, planned: plan.workouts, timeZone: utc)
                            XCTAssertTrue(report.passed, "\(label) rest \(restName) (+\(Int(minutes(rest))) min): "
                                          + "\(report.violations.map(\.explanation))")
                        }
                        // The rebuild on that Monday, after the usual rest of the week and after no more runs.
                        for (restName, rest) in cases where restName == "usual" || restName == "none" {
                            let finished = h + rest
                            let weekMinutes = minutes(finished.filter { $0.date >= startWeek })
                            let rebuiltInput = input(r, shape: shape + [weekMinutes / r.weeklyMinutes], distance: d,
                                                     start: nextMonday, weeks: 14)
                            let rebuilt = PlanBuilder.build(rebuiltInput, history: finished, timeZone: utc)
                            guard let q = rebuilt.plan else {
                                // After no more runs a short week may leave the 4-week rule no room; never a failed check.
                                XCTAssertEqual(restName, "none", "\(label) rebuild: \(rebuilt.issues)")
                                XCTAssertFalse(rebuilt.issues.contains { if case .failsGuardrails = $0 { return true }; return false })
                                continue
                            }
                            XCTAssertNil(q.rebuildDate, label)
                            XCTAssertEqual(q.weeks.first?.weekStart, nextMonday, label)
                            let report = GuardrailChecker.check(history: finished, planned: q.workouts, timeZone: utc)
                            XCTAssertTrue(report.passed, "\(label) rebuild after \(restName): \(report.violations.map(\.explanation))")
                            if restName == "usual" {
                                // Size: the final plan gets back to at least the recent load.
                                // A plan that says it plans weeks shorter so no easy run is
                                // longer than the long run (F3, #23) may peak under it.
                                let peak = q.weeks.map(\.trainingSeconds).max() ?? 0
                                let keptSmaller = q.notes.contains { $0.contains(PlanBuilder.easyRunLimitMarker) }
                                XCTAssertGreaterThanOrEqual(peak, (keptSmaller ? 0.9 : 1.0) * rebuiltInput.recentWeeklySeconds!,
                                                            "\(label) rebuilt peak \(Int(peak / 60)) min")
                                rebuiltPeaks += 1
                            }
                        }
                    }
                }
            }
        }
        // Safety must not cost the plan: nearly every case still builds, and
        // every build was rebuilt and sized after the usual rest of the week.
        XCTAssertGreaterThanOrEqual(built, combos * 9 / 10, "\(refused)")
        XCTAssertEqual(rebuiltPeaks, built)
    }

    /// The issue's case, spelled out: two build weeks after a recovery week,
    /// then a mid-week start whose week so far reads as a recovery week. The
    /// runner's usual Saturday and Sunday then makes it the third build week,
    /// so the plan's first week has to be a recovery week.
    func testPartialWeekThatReadsAsRecoveryDoesNotLetFourBuildWeeksRunInARow() throws {
        let r = runners[2]
        let shape: [Double] = [1, 1, 1, 0.75, 1, 1]
        let start = startWeek.addingTimeInterval((3 * 24 + 9) * 3600) // Thursday 09:00
        let all = usualWeek(r, weekStart: startWeek, scale: 1, id: "s")
        let h = history(r, shape: shape) + all.filter { $0.date < start }
        let i = input(r, shape: shape, distance: Distance.halfMarathon, start: start, weeks: 14)
        // So far the week holds Tuesday to Thursday mornings only: a recovery week as given.
        XCTAssertLessThan(minutes(h.filter { $0.date >= startWeek }), 0.8 * r.weeklyMinutes)
        let p = try XCTUnwrap(PlanBuilder.build(i, history: h, timeZone: utc).plan)
        let rest = all.filter { $0.date >= start }
        let report = GuardrailChecker.check(history: h + rest, planned: p.workouts, timeZone: utc)
        XCTAssertTrue(report.passed, "\(report.violations.map(\.explanation))")
        // The first plan week is a recovery week against the finished week.
        XCTAssertLessThanOrEqual(p.weeks[0].trainingSeconds, 0.8 * minutes(all) * 60)
    }

    /// The week so far reads as a recovery week, and runs that lift it just
    /// over the line make it its own 10% reference: the first plan week is
    /// held to 10% over that, not over the full week before.
    func testFirstWeekIsHeldToTheSmallestReferenceTheStartWeekCanGive() throws {
        let r = runners[1]
        let shape: [Double] = [1, 1, 1, 1, 1, 0.75, 1]
        let start = startWeek.addingTimeInterval(13 * 3600) // Monday 13:00, the Monday run logged
        let h = history(r, shape: shape) + usualWeek(r, weekStart: startWeek, scale: 1, id: "s").filter { $0.date < start }
        let i = input(r, shape: shape, distance: Distance.tenK, start: start, weeks: 12)
        let p = try XCTUnwrap(PlanBuilder.build(i, history: h, timeZone: utc).plan)
        let weekBefore = r.weeklyMinutes * 60
        XCTAssertLessThanOrEqual(p.weeks[0].trainingSeconds, 0.8 * weekBefore * 1.1)
        let lift = 0.8 * weekBefore / 60 + 0.5 - minutes(h.filter { $0.date >= startWeek })
        let report = GuardrailChecker.check(history: h + extraRuns(minutes: lift, after: start, id: "x"),
                                            planned: p.workouts, timeZone: utc)
        XCTAssertTrue(report.passed, "\(report.violations.map(\.explanation))")
    }

    /// A Monday start before noon with nothing logged keeps the start's week
    /// as the plan's first week: there is no open history week to bound.
    func testOpenMondayHasNoPartialWeek() throws {
        let r = runners[0]
        let shape: [Double] = [1, 1, 1, 0.75, 1, 1]
        let start = startWeek.addingTimeInterval(8 * 3600)
        let h = history(r, shape: shape)
        let p = try XCTUnwrap(PlanBuilder.build(input(r, shape: shape, distance: Distance.tenK, start: start, weeks: 12),
                                                history: h, timeZone: utc).plan)
        XCTAssertEqual(p.weeks[0].weekStart, startWeek)
        XCTAssertNil(p.rebuildDate)
        XCTAssertFalse(p.isProvisional)
        XCTAssertFalse(p.notes.contains { $0.contains("provisional") })
        XCTAssertTrue(GuardrailChecker.check(history: h, planned: p.workouts, timeZone: utc).passed)
    }

    /// After a long break (3 empty weeks or more, which keep the plain rules
    /// of 3.5 rule 4), a mid-week start with nothing logged yet has no safe
    /// first week: any short run still to come would be the reference.
    func testNothingLoggedAfterALongBreakIsAnExplicitRefusal() {
        let r = runners[2]
        let shape: [Double] = [1, 1, 1, 1, 1, 0, 0, 0]
        let start = startWeek.addingTimeInterval((2 * 24 + 6) * 3600) // Wednesday 06:00, nothing this week yet
        let h = history(r, shape: shape)
        var i = input(r, shape: shape, distance: Distance.tenK, start: start, weeks: 12)
        i.recentWeeklySeconds = r.weeklyMinutes * 60 * 0.32
        XCTAssertEqual(PlanBuilder.build(i, history: h, timeZone: utc).issues,
                       [.startWeekWithoutReference(rebuildOn: nextMonday)])
    }

    /// After one empty week, a short break (3.5 rule 4, #62), a mid-week
    /// start with nothing logged yet builds: the return ramp, not the empty
    /// week, sets the first plan week. Whatever the rest of the start's week
    /// brings, around the break line too, history plus plan pass 3.5.
    func testNothingLoggedAfterAnEmptyWeekReturnsOnTheRamp() throws {
        let r = runners[2]
        let shape: [Double] = [1, 1, 1, 1, 1, 1, 0]
        let start = startWeek.addingTimeInterval((2 * 24 + 6) * 3600) // Wednesday 06:00, nothing this week yet
        let h = history(r, shape: shape)
        var i = input(r, shape: shape, distance: Distance.tenK, start: start, weeks: 12)
        i.recentWeeklySeconds = r.weeklyMinutes * 60 * 0.75
        let result = PlanBuilder.build(i, history: h, timeZone: utc)
        let p = try XCTUnwrap(result.plan, "\(result.issues)")
        XCTAssertEqual(p.weeks[0].weekStart, nextMonday)
        XCTAssertEqual(p.rebuildDate, nextMonday)
        // The start's week may end just over the break line (25% of the
        // pre-break week): the plan's first week is then week 2 back and may
        // hold at most 0.9 / 0.7 of it.
        let line = 0.25 * r.weeklyMinutes
        XCTAssertLessThanOrEqual(p.weeks[0].trainingSeconds, line * 60 * 0.9 / 0.7 + 1e-6)
        var cases = restOfWeek(r, history: h, input: i)
        for total in [line - 0.5, line, line + 0.5, 1.5 * line, 0.7 * r.weeklyMinutes] {
            cases.append(("total \(total)", extraRuns(minutes: total, after: start, id: "t\(Int(total * 10))")))
        }
        for (name, rest) in cases {
            let report = GuardrailChecker.check(history: h + rest, planned: p.workouts, timeZone: utc)
            XCTAssertTrue(report.passed, "rest \(name) (+\(Int(minutes(rest))) min): \(report.violations.map(\.explanation))")
        }
    }

    /// With no history at all, a mid-week start is still an open week: an
    /// explicit refusal with nothing logged, a bounded plan once a run is.
    func testNoHistoryMidWeekStartIsBoundedOrRefused() throws {
        let r = runners[1]
        let start = startWeek.addingTimeInterval((2 * 24 + 9) * 3600) // Wednesday 09:00
        let i = input(r, shape: [1], distance: Distance.tenK, start: start, weeks: 12)
        XCTAssertEqual(PlanBuilder.build(i, history: [], timeZone: utc).issues,
                       [.startWeekWithoutReference(rebuildOn: nextMonday)])
        // Monday's usual run logged: the week so far is the lower bound.
        let monday = usualWeek(r, weekStart: startWeek, scale: 1, id: "s").filter { $0.date < start }
        XCTAssertFalse(monday.isEmpty)
        let result = PlanBuilder.build(i, history: monday, timeZone: utc)
        let p = try XCTUnwrap(result.plan, "\(result.issues)")
        XCTAssertEqual(p.rebuildDate, nextMonday)
        XCTAssertLessThanOrEqual(p.weeks[0].trainingSeconds, minutes(monday) * 60 * 1.1)
        for extra in [0.0, 30, 120, 400] {
            let rest = extraRuns(minutes: extra, after: start, id: "x")
            let report = GuardrailChecker.check(history: monday + rest, planned: p.workouts, timeZone: utc)
            XCTAssertTrue(report.passed, "+\(Int(extra)) min: \(report.violations.map(\.explanation))")
        }
    }

    // MARK: The ledger scenarios

    func testLedgerScenariosBoundTheOpenWeek() {
        let limits = GuardrailLimits.default
        // 300, 300, then 100 so far: as given, just over the line (240, a
        // build week), and the most 3.5 allows (330).
        let set = PlanBuilder.ledgers(volumes: [300, 300, 100], lastWeekOpen: true, recentWeekly: 300, limits: limits)
        XCTAssertEqual(set.scenarios.map { $0.volumes.last! }, [100, 240, 330])
        XCTAssertEqual(set.scenarios[1].buildWeek, 2)
        XCTAssertFalse(set.scenarios[1].isRecovery(2))
        XCTAssertTrue(set.exact.isRecovery(2))
        XCTAssertEqual(set.nextCap, 240 * 1.1, accuracy: 1e-9)
        XCTAssertEqual(set.streak, 3)
        XCTAssertEqual(set.recoveryBase, 240)
        // A closed week, or one of unknown volume, is taken as given.
        XCTAssertEqual(PlanBuilder.ledgers(volumes: [300, 300, 100], lastWeekOpen: false, recentWeekly: 300,
                                           limits: limits).scenarios.count, 1)
        XCTAssertEqual(PlanBuilder.ledgers(volumes: [300, nil], lastWeekOpen: true, recentWeekly: 300,
                                           limits: limits).scenarios.count, 1)
        // Nothing yet after an empty week: a short break (3.5 rule 4, #62).
        // The open week may end just over the break line (25% of 300), so
        // the next week is then week 2 back: at most 0.9 / 0.7 of it.
        let empty = PlanBuilder.ledgers(volumes: [300, 0, 0], lastWeekOpen: true, recentWeekly: 300, limits: limits)
        XCTAssertEqual(empty.nextCap, 300 * 0.25 * 0.9 / 0.7, accuracy: 1e-9)
        XCTAssertFalse(empty.openWithoutReference)
        XCTAssertEqual(empty.recoveryBase, 0)
        // With the ramp off (the plain rules), no reference is safe, so nothing is allowed.
        let plain = PlanBuilder.ledgers(volumes: [300, 0, 0], lastWeekOpen: true, recentWeekly: 300,
                                        limits: GuardrailLimits(maxShortBreakWeeks: 0))
        XCTAssertEqual(plain.nextCap, 0)
        XCTAssertTrue(plain.openWithoutReference)
        // An open week already above the line is its own lower bound.
        let over = PlanBuilder.ledgers(volumes: [300, 280], lastWeekOpen: true, recentWeekly: 300, limits: limits)
        XCTAssertEqual(over.scenarios.map { $0.volumes.last! }, [280, 280, 330])
        XCTAssertEqual(over.nextCap, 280 * 1.1, accuracy: 1e-9)
        // With no week before, the baseline plus 10% bounds it.
        let first = PlanBuilder.ledgers(volumes: [50], lastWeekOpen: true, recentWeekly: 200, limits: limits)
        XCTAssertEqual(first.scenarios.last!.volumes.last!!, 220, accuracy: 1e-9)
        // Appending a plan week appends it everywhere.
        var grow = set
        grow.append(200)
        XCTAssertTrue(grow.scenarios.allSatisfy { $0.volumes.count == 4 && $0.volumes.last! == 200 })
        XCTAssertEqual(grow.recoveryBase, 200)
    }

    // MARK: Through GoalPlanner (F2), which always plans from today

    /// The F2 fixture plans on a Wednesday with nothing logged yet that week.
    /// Once the runner's usual Thursday-to-Sunday runs land, history plus plan
    /// still pass 3.5, for every distance.
    func testGoalPlannerMidWeekPlanSurvivesTheUsualRestOfWeek() throws {
        let report = GoalFixture.fixtureReport()
        let today = GoalFixture.today
        let tz = report.timeZone
        let thisWeek = PlanCalendar.weekStart(containing: today, timeZone: tz)
        let next = PlanCalendar.nextWeekStart(after: thisWeek, timeZone: tz)
        for (meters, weeks) in [(Distance.fiveK, 8), (Distance.tenK, 12), (Distance.halfMarathon, 16), (Distance.marathon, 20)] {
            let result = GoalPlanner.plan(settings: GoalFixture.settings(distance: meters, weeksAhead: weeks),
                                          baseline: report, today: today)
            let p = try XCTUnwrap(result.plan, "\(meters): \(result.issues)")
            // The usual rest of the week: last week's sessions from today's weekday on, a week later.
            let lastWeek = p.history.filter { $0.date >= thisWeek.addingTimeInterval(-7 * 86_400) && $0.date < thisWeek }
            let rest = lastWeek.map {
                PlannedWorkout(id: "rest-\($0.id)", date: $0.date.addingTimeInterval(7 * 86_400), kind: $0.kind,
                               durationSeconds: $0.durationSeconds)
            }.filter { $0.date > today && $0.date < next }
            XCTAssertFalse(rest.isEmpty)
            for added in [[], rest] {
                let report = GuardrailChecker.check(history: p.history + added, planned: p.plan.workouts, timeZone: tz)
                XCTAssertTrue(report.passed, "\(meters) +\(added.count) runs: \(report.violations.map(\.explanation))")
            }
            // Provisional: re-plan at the start of the plan's first Monday.
            XCTAssertEqual(p.rebuildDate, next, "\(meters)")
        }
    }

    /// The F2 runner's usual Thursday, Saturday and Sunday after the Wednesday
    /// plan (`GoalFixture` runs 35, 35 and 80 minutes on those days).
    private static func f2RestOfWeek() -> [Activity] {
        let w = BaselineFixture.weeks
        return [GoalFixture.run("rest-thu", week: w, day: .thursday, minutes: 35),
                GoalFixture.run("rest-sat", week: w, day: .saturday, minutes: 35),
                GoalFixture.run("rest-sun", week: w, day: .sunday, minutes: 80, hour: 8)]
    }

    /// The re-plan on the provisional plan's rebuild date, with a baseline as
    /// of that moment, is final, passes 3.5 after the usual rest of the week
    /// and after no more runs, and after the usual week gets the build back
    /// above the runner's recent load.
    func testGoalPlannerRebuildOnTheFirstMondayIsFinal() throws {
        let report = GoalFixture.fixtureReport()
        let tz = report.timeZone
        for (meters, weeks) in [(Distance.fiveK, 8), (Distance.tenK, 12), (Distance.halfMarathon, 14),
                                (Distance.halfMarathon, 16), (Distance.marathon, 20)] {
            let settings = GoalFixture.settings(distance: meters, weeksAhead: weeks)
            let first = try XCTUnwrap(GoalPlanner.plan(settings: settings, baseline: report, today: GoalFixture.today).plan)
            let monday = try XCTUnwrap(first.rebuildDate)
            XCTAssertEqual(monday, PlanCalendar.weekStart(containing: monday, timeZone: tz), "start of a Monday")
            for (name, rest) in [("usual", Self.f2RestOfWeek()), ("none", [])] {
                let label = "\(Int(meters)) m \(weeks) w after \(name)"
                let fresh = GoalFixture.fixtureReport(asOf: monday) { $0 += rest }
                let result = GoalPlanner.plan(settings: settings, baseline: fresh, today: monday)
                guard let q = result.plan else {
                    // After a week off the 4-week rule may leave too little; never a failed check.
                    XCTAssertEqual(name, "none", "\(label): \(result.issues)")
                    XCTAssertFalse(result.issues.contains { if case .failsGuardrails = $0 { return true }; return false }, label)
                    continue
                }
                XCTAssertNil(q.rebuildDate, label)
                XCTAssertEqual(q.plan.weeks.first?.weekStart, monday, label)
                let check = GuardrailChecker.check(history: q.history, planned: q.plan.workouts, timeZone: tz)
                XCTAssertTrue(check.passed, "\(label): \(check.violations.map(\.explanation))")
                if name == "usual" {
                    let recent = try XCTUnwrap(q.input.recentWeeklySeconds)
                    let peak = try XCTUnwrap(q.plan.weeks.map(\.trainingSeconds).max())
                    XCTAssertGreaterThan(peak, recent, label)
                    if meters == Distance.halfMarathon && weeks == 14 {
                        // As on a plan made from a closed week (about 1.25).
                        XCTAssertGreaterThan(peak / recent, 1.2, label)
                    }
                }
            }
        }
    }
}
