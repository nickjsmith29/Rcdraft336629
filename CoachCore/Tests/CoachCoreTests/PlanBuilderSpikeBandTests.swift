import XCTest
@testable import CoachCore

// #105, SPEC 3.1 (hard share) against 3.5 rule 1 (single-run spike rule) and
// F2 (max session length): when a session cap holds a week's quality
// sessions down, the week must not be cut to a fraction of its volume to
// reach the 16 to 24% hard-share band. The quality sessions' warm-up and
// cool-down shrink to their shortest (`PlanHeuristics.shortWarmUpSeconds`) so
// the hard time fits under the cap, and a week whose sessions are held short
// counts the run days the cap forces when it sets its quality sessions.
// #113: the shorter warm-up is decided per session, only where the session
// cap holds that session's main set, so no week loses time to it for nothing.
// Synthetic runners and weeks only; no real runner's training is here.
final class PlanBuilderSpikeBandTests: XCTestCase {
    private let utc = PlanFixture.utc
    private typealias F = PlanFixture
    private let floor = PlanHeuristics.minimumEasyRunSeconds
    private let ruleOff = GuardrailLimits(maxSingleRunIncrease: .infinity)

    /// Share of a week's volume the builder must keep (heuristic, chosen for
    /// this test): a training week holds at least this share of what it asked
    /// for after the weekly caps, or of what its days hold under the session
    /// cap when that is less, unless its sessions can't hold the band's hard
    /// time at that volume at all (`WeekVolumeDiagnostic.bandReachable`, the
    /// known gap below).
    private let keptShare = 0.8

    /// Plan start: Monday of fixture week 8, at midnight.
    private var planMonday: Date { F.date(week: 8, day: 0, hour: 0) }

    private func raceDate(weeks: Int) -> Date {
        planMonday.addingTimeInterval(Double((weeks - 1) * 7 + 6) * 86_400 + 8 * 3600)
    }

    /// `weeks` weeks of `minutes` a week before the plan over `days`: equal
    /// easy runs, or with `longShare` a long run on the last day taking that share.
    private func history(minutes: Double, weeks: Int, days: [PlanWeekday], longShare: Double?) -> [PlannedWorkout] {
        var out: [PlannedWorkout] = []
        for k in 0..<weeks {
            for d in days {
                let isLong = longShare != nil && d == days.last!
                let m = longShare.map { isLong ? minutes * $0 : minutes * (1 - $0) / Double(days.count - 1) }
                    ?? minutes / Double(days.count)
                out.append(F.workout("h\(k)-\(d.rawValue)", week: 8 - weeks + k, day: d.rawValue,
                                     isLong ? .long : .easy, minutes: m))
            }
        }
        return out
    }

    private func input(days: [PlanWeekday], weekly: Double, distance: Double, weeks: Int = 12,
                       recentLong: Double?, maxSession: Double? = nil) -> PlanInput {
        PlanInput(raceDistanceMeters: distance, raceDate: raceDate(weeks: weeks), startDate: planMonday,
                  trainingDays: Set(days), longRunDay: days.last!, maxSessionSeconds: maxSession.map { $0 * 60 },
                  recentWeeklySeconds: weekly * 60, recentLongRunSeconds: recentLong.map { $0 * 60 },
                  heartRateZones: HRZones(lthr: 168), easyPace: EasyPaceSample(secondsPerKm: 360, heartRate: 140),
                  fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: 25 * 60))
    }

    private static let all: [PlanWeekday] = [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]

    /// The volume the week could hold: what it asked for, or what its
    /// sessions hold under the session caps (F2, 3.5 rule 1) and the long
    /// run's limits (3.5 rule 5, F3) when that is less.
    private func ceiling(_ d: PlanBuilder.WeekVolumeDiagnostic) -> Double {
        min(d.desired, d.capacity, Double(d.dayCount) * d.sessionCap)
    }

    private func minutes(_ w: TrainingPlanWeek) -> Double { w.trainingSeconds / 60 }

    private func shape(_ w: TrainingPlanWeek) -> String {
        w.workouts.map { x -> String in
            let tag = x.kind == .long ? "L" : x.kind == .easy ? "e" : x.kind == .race ? "R" : "q"
            return "\(tag)\(Int(x.durationSeconds / 60))"
        }.joined(separator: " ")
    }

    private func hardShare(_ w: TrainingPlanWeek) -> Double {
        1 - (w.easyShare ?? 1)
    }

    // MARK: The issue's cases (the #98 review's traces)

    /// Seven days, four weeks of equal 34-min runs, marathon in 12 weeks.
    /// Every session is held to about 37 to 67 minutes by the spike rule. On
    /// main the recovery week 0 (179 min asked) came out at 60, and week 4
    /// (188 asked) at 133: a 25-min warm-up and cool-down left a 12-min main
    /// set under the cap. Week 4 now keeps its volume; week 0 is the known gap.
    func testTheSevenDayMarathonKeepsItsSpikeCappedWeeks() throws {
        let days = Self.all
        let h = history(minutes: 240, weeks: 4, days: days, longShare: nil)
        let i = input(days: days, weekly: 240, distance: Distance.marathon, recentLong: 240 / 7)
        let (r, diag) = PlanBuilder.buildDiagnosed(i, history: h, timeZone: utc)
        let p = try XCTUnwrap(r.plan, "\(r.issues)")
        assertHolds(p, diag, input: i, history: h, label: "7 days, 240")
        XCTAssertTrue(diag[0].spikeBound && diag[4].spikeBound)
        XCTAssertEqual(diag[0].desired / 60, 179, accuracy: 1)
        // Week 0: up from 60 to over 130 (still short of 179, the known gap).
        XCTAssertGreaterThanOrEqual(minutes(p.weeks[0]), 130, shape(p.weeks[0]))
        // Week 4: its whole volume, not 133.
        XCTAssertGreaterThanOrEqual(diag[4].realized, 0.98 * diag[4].desired, shape(p.weeks[4]))
        XCTAssertGreaterThanOrEqual(minutes(p.weeks[4]), 185, shape(p.weeks[4]))
        // The quality sessions of the capped weeks use a shorter warm-up, no
        // shorter than 10 min, and only as short as their main sets need (#113).
        let q = try XCTUnwrap(p.weeks[4].workouts.first { $0.kind.isQuality })
        let warm = try XCTUnwrap(q.prescription?.segments.first { $0.role == .warmUp }?.durationSeconds)
        XCTAssertLessThan(warm, 15 * 60)
        XCTAssertGreaterThanOrEqual(warm, PlanHeuristics.shortWarmUpSeconds)
        XCTAssertGreaterThan(p.weeks.reduce(0) { $0 + $1.trainingSeconds } / 60, 2900)
    }

    /// Six days, four weeks of equal 30-min runs, a 45-min max session, 5K
    /// in 12 weeks. On main weeks 1 to 4 came out at 143, 60, 78 and 60 min
    /// (155 and 150 asked for weeks 2 and 3), and the build grew from there
    /// in 10% steps: 1019 min in all. Now weeks 1 to 3 keep their volume.
    func testTheSixDayFiveKKeepsItsSpikeCappedWeeks() throws {
        let days = Array(Self.all.prefix(6))
        let h = history(minutes: 180, weeks: 4, days: days, longShare: nil)
        let i = input(days: days, weekly: 180, distance: Distance.fiveK, recentLong: 30, maxSession: 45)
        let (r, diag) = PlanBuilder.buildDiagnosed(i, history: h, timeZone: utc)
        let p = try XCTUnwrap(r.plan, "\(r.issues)")
        assertHolds(p, diag, input: i, history: h, label: "6 days, 180")
        for k in 1...3 {
            XCTAssertTrue(diag[k].spikeBound, "week \(k)")
            XCTAssertGreaterThanOrEqual(diag[k].realized, 0.98 * diag[k].desired, "week \(k): \(shape(p.weeks[k]))")
            XCTAssertGreaterThanOrEqual(minutes(p.weeks[k]), 175, "week \(k): \(shape(p.weeks[k]))")
        }
        // A spike-capped build week holds two quality sessions under the cap.
        XCTAssertEqual(p.weeks[1].workouts.filter { $0.kind.isQuality }.count, 2, shape(p.weeks[1]))
        XCTAssertGreaterThan(p.weeks.reduce(0) { $0 + $1.trainingSeconds } / 60, 2000)
    }

    /// Five days at 120 min, equal 24-min runs: week 1 (120 asked, sessions
    /// held to about 28 min) used to be estimated as a 3-day week with one
    /// quality session and cut to 78 min. Held short, it runs on 5 days and
    /// takes two quality sessions.
    func testACappedWeekCountsTheRunDaysTheCapForces() throws {
        let days: [PlanWeekday] = [.monday, .tuesday, .thursday, .friday, .sunday]
        let h = history(minutes: 120, weeks: 4, days: days, longShare: nil)
        let i = input(days: days, weekly: 120, distance: Distance.fiveK, recentLong: 24)
        let (r, diag) = PlanBuilder.buildDiagnosed(i, history: h, timeZone: utc)
        let p = try XCTUnwrap(r.plan, "\(r.issues)")
        assertHolds(p, diag, input: i, history: h, label: "5 days, 120")
        XCTAssertTrue(diag[1].spikeBound)
        XCTAssertGreaterThanOrEqual(minutes(p.weeks[1]), 115, shape(p.weeks[1]))
        XCTAssertEqual(p.weeks[1].workouts.filter { $0.kind.isQuality }.count, 2, shape(p.weeks[1]))
    }

    /// With no cap binding, a large week keeps the usual 15-min warm-up and
    /// 10-min cool-down: the short ones are used only where they let the
    /// hard time fit.
    func testAnUncappedWeekKeepsTheUsualWarmUp() throws {
        let days: [PlanWeekday] = [.monday, .tuesday, .thursday, .friday, .sunday]
        let h = history(minutes: 300, weeks: 4, days: days, longShare: 0.3)
        let i = input(days: days, weekly: 300, distance: Distance.halfMarathon, recentLong: nil)
        let (r, diag) = PlanBuilder.buildDiagnosed(i, history: h, timeZone: utc, limits: ruleOff)
        let p = try XCTUnwrap(r.plan, "\(r.issues)")
        assertHolds(p, diag, input: i, history: h, label: "5 days, 300, rule off", limits: ruleOff)
        let warmUps = p.workouts.filter { $0.kind.isQuality && $0.durationSeconds >= 60 * 60 }
            .compactMap { $0.prescription?.segments.first { $0.role == .warmUp }?.durationSeconds }
        XCTAssertFalse(warmUps.isEmpty)
        XCTAssertTrue(warmUps.allSatisfy { $0 == 15 * 60 }, "\(warmUps)")
    }

    // MARK: Per-session warm-ups (#113)

    /// The #110 review's trace: seven days, four weeks of equal runs at 480
    /// min, a 60-min max session, 5K in 12 weeks. Before #105 week 5 was e60
    /// e60 q53 e60 q59 e60 L60 (412 min); #110 gave both quality sessions the
    /// 10 and 5 min warm-up and cool-down, q43 and q58 (401), though the
    /// race-pace session's main set is held by its own 28-min cap. Now only
    /// the threshold session, which the 60-min cap holds, gives up warm-up
    /// time, and only as much as its main set uses: it stays at 60 minutes.
    func testOnlyTheSessionTheCapHoldsGetsTheShortWarmUp() throws {
        let days = Self.all
        let h = history(minutes: 480, weeks: 4, days: days, longShare: nil)
        let i = input(days: days, weekly: 480, distance: Distance.fiveK, recentLong: 480 / 7, maxSession: 60)
        let (r, diag) = PlanBuilder.buildDiagnosed(i, history: h, timeZone: utc)
        let p = try XCTUnwrap(r.plan, "\(r.issues)")
        assertHolds(p, diag, input: i, history: h, label: "7 days, 480, max 60")
        let (old, _) = PlanBuilder.buildDiagnosed(i, history: h, timeZone: utc, shortenWarmUps: false)
        let o = try XCTUnwrap(old.plan)
        let w = p.weeks[5]
        // Easy time the 60-min cap holds back from the easy runs goes to the
        // quality sessions' easy cool-down (F3), so both fill to the cap.
        XCTAssertEqual(shape(o.weeks[5]), "e60 e60 q60 e60 q60 e60 L60")
        XCTAssertEqual(shape(w), "e60 e60 q60 e60 q60 e60 L60")
        XCTAssertGreaterThanOrEqual(minutes(w), 412, shape(w))
        // It gains hard time too (a longer threshold set), not only volume.
        XCTAssertGreaterThan(hardShare(w) * w.trainingSeconds, hardShare(o.weeks[5]) * o.weeks[5].trainingSeconds)
        func overhead(_ x: PlannedWorkout) -> (Double, Double) {
            let seg = x.prescription?.segments ?? []
            return ((seg.first { $0.role == .warmUp }?.durationSeconds ?? 0) / 60,
                    (seg.first { $0.role == .coolDown }?.durationSeconds ?? 0) / 60)
        }
        let q = w.workouts.filter { $0.kind.isQuality }
        XCTAssertEqual(q.count, 2)
        // Intervals: the usual 15 min warm-up; only the cool-down takes the
        // easy time the cap holds back from the easy runs (and says so).
        let intervals = try XCTUnwrap(q.first { $0.kind == .quality(.intervals) })
        XCTAssertEqual(overhead(intervals).0, 15)
        XCTAssertGreaterThanOrEqual(overhead(intervals).1, 10)
        XCTAssertTrue((intervals.prescription?.purpose ?? "").contains("easy running"), intervals.prescription?.purpose ?? "")
        // Threshold, held by the session cap: shortened only as far as its main set reaches.
        let threshold = try XCTUnwrap(q.first { $0.kind == .quality(.threshold) })
        XCTAssertEqual(threshold.durationSeconds, 60 * 60)
        let (warm, cool) = overhead(threshold)
        XCTAssertLessThan(warm, 15)
        XCTAssertLessThan(warm + cool, 25)
        XCTAssertGreaterThanOrEqual(warm, PlanHeuristics.shortWarmUpSeconds / 60)
        XCTAssertGreaterThanOrEqual(cool, PlanHeuristics.shortCoolDownSeconds / 60)
        // The whole plan is no shorter than with 15 and 10 everywhere.
        XCTAssertGreaterThanOrEqual(p.weeks.reduce(0) { $0 + $1.trainingSeconds },
                                    o.weeks.reduce(0) { $0 + $1.trainingSeconds })
    }

    /// The shorter warm-ups never cost a plan time it gains nothing for:
    /// against the same build with 15 and 10 min everywhere, no plan keeps
    /// more than `totalSlack` less of its asked volume (each training week
    /// counted up to what it asked for), and no week asked for the same
    /// volume keeps more than `weekSlack` less (whole-minute reps can move a
    /// minute or two). With #110's all-or-nothing switch, a 7-day 480-min
    /// plan under a 60-min cap lost 33 min. Weeks are counted only up to
    /// their ask because a recovery week whose first draft falls short may
    /// take up to the recovery limit instead (#87): the 15/10 build does that
    /// more often, so its raw total can be higher without the ask being
    /// served better. A spike-capped recovery week the builder can't bring
    /// to the band (the known gap below, #112) is left to that test and to
    /// `assertHolds`' independent bound: under a tight spike cap its first
    /// draft can now hold the band at its volume but fail the spike rule,
    /// where the 15/10 draft was shortened enough to pass it, as on #110.
    func testShortWarmUpsNeverCostVolume() {
        compareSweep(volumes: [120, 240, 330, 480], distances: [Distance.fiveK, Distance.halfMarathon, Distance.marathon],
                     histories: ["even"], minimumBuilt: 250)
    }

    /// The full comparison: `COACHCORE_SLOW_TESTS=1 swift test`.
    func testShortWarmUpsNeverCostVolumeFull() throws {
        guard ProcessInfo.processInfo.environment["COACHCORE_SLOW_TESTS"] == "1" else {
            throw XCTSkip("set COACHCORE_SLOW_TESTS=1 to run the full comparison")
        }
        compareSweep(volumes: Array(stride(from: 90.0, through: 480, by: 15)),
                     distances: [Distance.fiveK, Distance.tenK, Distance.halfMarathon, Distance.marathon],
                     histories: ["even", "long"], minimumBuilt: 2500)
    }

    private let totalSlack: Double = 5 * 60
    private let weekSlack: Double = 3 * 60

    private func compareSweep(volumes: [Double], distances: [Double], histories: [String], minimumBuilt: Int) {
        var built = 0, differs = 0
        for days in Self.daySets {
            for weekly in volumes {
                for distance in distances {
                    for name in histories {
                        let longShare: Double? = name == "long" ? 0.3 : nil
                        let recentLong: Double? = name == "long" ? nil : weekly / Double(days.count)
                        for maxSession in [nil, 45.0, 60.0] as [Double?] {
                            for limits in [GuardrailLimits.default, ruleOff] {
                                let h = history(minutes: weekly, weeks: 4, days: days, longShare: longShare)
                                let i = input(days: days, weekly: weekly, distance: distance, weeks: 10,
                                              recentLong: recentLong, maxSession: maxSession)
                                let label = "\(days.count) days, \(Int(weekly)) min, \(Int(distance)) m, \(name), "
                                    + "max \(maxSession ?? 0), rule \(limits.maxSingleRunIncrease.isFinite ? "on" : "off")"
                                let (r, diag) = PlanBuilder.buildDiagnosed(i, history: h, timeZone: utc, limits: limits)
                                let (o, oldDiag) = PlanBuilder.buildDiagnosed(i, history: h, timeZone: utc, limits: limits,
                                                                              shortenWarmUps: false)
                                guard let p = r.plan, let q = o.plan else { continue }
                                built += 1
                                func kept(_ ds: [PlanBuilder.WeekVolumeDiagnostic]) -> Double {
                                    ds.reduce(0) { $0 + min($1.realized, $1.desired) }
                                }
                                if p != q { differs += 1 }
                                XCTAssertGreaterThanOrEqual(kept(diag), kept(oldDiag) - totalSlack,
                                                            "\(label): \(Int(kept(diag) / 60)) vs \(Int(kept(oldDiag) / 60))")
                                for (d, e) in zip(diag, oldDiag) where abs(d.desired - e.desired) < 1
                                    && !(d.recovery && !d.bandReachable) {
                                    XCTAssertGreaterThanOrEqual(d.realized, min(e.realized, d.desired) - weekSlack,
                                                                "\(label): week \(d.index) \(shape(p.weeks[d.index])) vs "
                                                                    + shape(q.weeks[d.index]))
                                }
                            }
                        }
                    }
                }
            }
        }
        // Not vacuous: plans build, and the short warm-ups change many of them.
        XCTAssertGreaterThan(built, minimumBuilt)
        XCTAssertGreaterThan(differs, 20)
    }

    // MARK: Diagnostics stay out of production (#113)

    /// `build` drafts no diagnostics, and gives the same plan as
    /// `buildDiagnosed`, whose extra drafts change nothing.
    func testBuildAndBuildDiagnosedGiveTheSamePlan() {
        let cases: [([PlanWeekday], Double, Double, Double?)] = [
            (Self.all, 240, Distance.marathon, nil), (Array(Self.all.prefix(6)), 180, Distance.fiveK, 45),
            (Self.all, 480, Distance.fiveK, 60), ([.tuesday, .thursday, .saturday], 330, Distance.halfMarathon, nil)
        ]
        for (days, weekly, distance, maxSession) in cases {
            let h = history(minutes: weekly, weeks: 4, days: days, longShare: nil)
            let i = input(days: days, weekly: weekly, distance: distance, recentLong: weekly / Double(days.count),
                          maxSession: maxSession)
            let built = PlanBuilder.build(i, history: h, timeZone: utc)
            let (diagnosed, diag) = PlanBuilder.buildDiagnosed(i, history: h, timeZone: utc)
            let (quiet, none) = PlanBuilder.buildDiagnosed(i, history: h, timeZone: utc, diagnose: false)
            XCTAssertNotNil(built.plan, "\(days.count) days, \(weekly)")
            XCTAssertEqual(built, diagnosed, "\(days.count) days, \(weekly)")
            XCTAssertEqual(built, quiet, "\(days.count) days, \(weekly)")
            XCTAssertFalse(diag.isEmpty)
            XCTAssertTrue(none.isEmpty)
        }
    }

    // MARK: Known gap (owner question on #105)

    /// KNOWN GAP, not a target. A recovery week holds one quality session
    /// (and its long run, at 80% of the last, is too short for a steady
    /// finish). When the spike rule holds that session to about 30 to 40
    /// minutes, even a 10-min warm-up and 5-min cool-down leave too little
    /// hard time for 16% of the week, so the week is still shortened to
    /// about hard / 0.165: 179 → 132 min (7 days, 240, marathon) and 135 →
    /// 77 (6 days, 180, 5K, #23). Keeping the volume as easy running would put the
    /// week under SPEC 3.1's band; adding hard time would change the
    /// recovery week. Which to do is the owner's call (SPEC 3.1 against 3.5
    /// rule 1), so the shortened weeks are pinned here until it is decided.
    /// Since #23 no easy run is longer than the week's long run, so the 5K
    /// case's 31-minute easy run beside a 24-minute long run is cut to 24: 77.
    func testKnownGapSpikeCappedRecoveryWeeksStillShrinkToTheBand() throws {
        let cases: [(Int, Double, Double, Double?, Double)] = [(7, 240, Distance.marathon, nil, 132),
                                                               (6, 180, Distance.fiveK, 45, 77)]
        for (count, weekly, distance, maxSession, expected) in cases {
            let days = Array(Self.all.prefix(count))
            let h = history(minutes: weekly, weeks: 4, days: days, longShare: nil)
            let i = input(days: days, weekly: weekly, distance: distance, recentLong: weekly / Double(count),
                          maxSession: maxSession)
            let (r, diag) = PlanBuilder.buildDiagnosed(i, history: h, timeZone: utc)
            let p = try XCTUnwrap(r.plan, "\(r.issues)")
            let d = diag[0]
            XCTAssertTrue(d.recovery && d.spikeBound, "\(count) days")
            XCTAssertEqual(d.maxQuality, 1, "\(count) days")
            XCTAssertFalse(d.bandReachable, "\(count) days")
            XCTAssertLessThan(d.realized, keptShare * d.desired, "\(count) days")
            XCTAssertEqual(minutes(p.weeks[0]), expected, accuracy: 3, shape(p.weeks[0]))
            // It is shortened to the band, never kept below it.
            XCTAssertTrue(PlanHeuristics.hardShareBand.contains(hardShare(p.weeks[0])), shape(p.weeks[0]))
        }
    }

    // MARK: Sweep

    /// Low to high volumes × day counts × distances × histories, the spike
    /// rule on and off, with and without a 45-min max session.
    func testSweepKeepsWeeksNearTheirVolume() {
        sweep(volumes: [120, 180, 240, 330], distances: [Distance.fiveK, Distance.halfMarathon, Distance.marathon],
              histories: ["even", "long"], minimumBuilt: 300)
    }

    /// The full sweep: `COACHCORE_SLOW_TESTS=1 swift test`.
    func testSweepKeepsWeeksNearTheirVolumeFull() throws {
        guard ProcessInfo.processInfo.environment["COACHCORE_SLOW_TESTS"] == "1" else {
            throw XCTSkip("set COACHCORE_SLOW_TESTS=1 to run the full sweep")
        }
        sweep(volumes: Array(stride(from: 90.0, through: 420, by: 15)),
              distances: [Distance.fiveK, Distance.tenK, Distance.halfMarathon, Distance.marathon],
              histories: ["even", "long", "two", "none"], minimumBuilt: 3000)
    }

    private static let daySets: [[PlanWeekday]] = [
        [.tuesday, .thursday, .saturday],
        [.monday, .wednesday, .friday, .sunday],
        [.monday, .tuesday, .thursday, .friday, .sunday],
        [.tuesday, .wednesday, .thursday, .friday, .saturday, .sunday],
        [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]
    ]

    private func sweep(volumes: [Double], distances: [Double], histories: [String], minimumBuilt: Int) {
        var built = 0, spikeBoundWeeks = 0, knownGap = 0, recoveryGraded = 0
        for days in Self.daySets {
            for weekly in volumes {
                for distance in distances {
                    for name in histories {
                        let (weeks, longShare, recentLong): (Int, Double?, Double?) = {
                            switch name {
                            case "even": return (4, nil, weekly / Double(days.count))
                            case "long": return (4, 0.3, nil)
                            case "two": return (2, nil, weekly / Double(days.count))
                            default: return (0, nil, nil)
                            }
                        }()
                        for maxSession in [nil, 45.0] as [Double?] {
                            for limits in [GuardrailLimits.default, ruleOff] {
                                let h = history(minutes: weekly, weeks: weeks, days: days, longShare: longShare)
                                let i = input(days: days, weekly: weekly, distance: distance, weeks: 10,
                                              recentLong: recentLong, maxSession: maxSession)
                                let label = "\(days.count) days, \(Int(weekly)) min, \(Int(distance)) m, \(name), "
                                    + "max \(maxSession ?? 0), rule \(limits.maxSingleRunIncrease.isFinite ? "on" : "off")"
                                let (r, diag) = PlanBuilder.buildDiagnosed(i, history: h, timeZone: utc, limits: limits)
                                guard let p = r.plan else { continue }
                                built += 1
                                assertHolds(p, diag, input: i, history: h, label: label, limits: limits)
                                spikeBoundWeeks += diag.filter(\.spikeBound).count
                                knownGap += diag.filter { !$0.bandReachable && $0.realized < keptShare * ceiling($0) }.count
                                recoveryGraded += diag.filter {
                                    $0.recovery && !$0.bandReachable && $0.realized < keptShare * ceiling($0)
                                        && $0.sessionCap.isFinite
                                }.count
                            }
                        }
                    }
                }
            }
        }
        // Not vacuous: plans build, the spike rule binds in many weeks, and
        // the known gap still shows (see the known-gap test), graded by the
        // independent recovery-week bound in `assertHolds`.
        XCTAssertGreaterThan(built, minimumBuilt)
        XCTAssertGreaterThan(spikeBoundWeeks, 100)
        XCTAssertGreaterThan(knownGap, 0)
        XCTAssertGreaterThan(recoveryGraded, 0)
    }

    /// The guardrails, the floor and the kept share a built plan holds.
    private func assertHolds(_ p: TrainingPlan, _ diag: [PlanBuilder.WeekVolumeDiagnostic], input i: PlanInput,
                             history h: [PlannedWorkout], label: String, limits: GuardrailLimits = .default,
                             file: StaticString = #filePath, line: UInt = #line) {
        // 3.5: the checker passes, run independently.
        let report = GuardrailChecker.check(history: h, planned: p.workouts, timeZone: utc, limits: limits)
        XCTAssertTrue(report.passed, "\(label): \(report.violations.map(\.explanation))", file: file, line: line)
        // #79: no training run under the floor; F2: none over the max session.
        for w in p.workouts where w.kind != .race {
            XCTAssertGreaterThanOrEqual(w.durationSeconds, floor - 1e-6, "\(label): \(w.id)", file: file, line: line)
            if let m = i.maxSessionSeconds {
                XCTAssertLessThanOrEqual(w.durationSeconds, m + 1e-6, "\(label): \(w.id)", file: file, line: line)
            }
        }
        for w in p.weeks where !w.isRaceWeek {
            // 3.1 band, except an all-easy week 1 back (3.5 rule 4).
            if let share = w.easyShare, !(share == 1 && !w.workouts.contains { $0.kind.isQuality }) {
                XCTAssertTrue((0.75...0.85).contains(share), "\(label): week \(w.index) \(shape(w))", file: file, line: line)
            }
            XCTAssertLessThanOrEqual(w.workouts.filter(\.kind.isQuality).count, limits.maxQualitySessionsPerWeek,
                                     label, file: file, line: line)
        }
        // F3: the long run grows at most 10 minutes over the longest so far.
        if let start = i.recentLongRunSeconds {
            var longest = start
            for w in p.workouts where w.kind == .long {
                XCTAssertLessThanOrEqual(w.durationSeconds, longest + PlanHeuristics.longRunStepSeconds + 1e-6,
                                         "\(label): \(w.id)", file: file, line: line)
                longest = max(longest, w.durationSeconds)
            }
        }
        // #105: every week whose sessions can hold the band keeps at least
        // `keptShare` of its volume (or of what its days hold under the cap).
        XCTAssertEqual(diag.count, p.weeks.count - 1, label, file: file, line: line)
        for d in diag where d.bandReachable {
            XCTAssertGreaterThanOrEqual(d.realized, keptShare * ceiling(d) - 1e-6,
                                        "\(label): week \(d.index) asked \(Int(d.desired / 60)), "
                                            + "\(shape(p.weeks[d.index]))", file: file, line: line)
        }
        // The known gap, checked independently of the builder's own probe.
        // A recovery week (one quality session, a long run at 80% of the
        // last) is the case the known-gap test pins. Any other week under a
        // session cap may fall short only when even its quality sessions at
        // the cap with the shortest warm-up and cool-down, plus a steady
        // finish on a long run at the cap, hold less than the band's hard
        // time (with 15% slack for whole-minute reps and main-set caps).
        // Without a cap, only a week that may hold one quality session (a
        // 3-day schedule), whose main set and finish have caps of their own.
        let shortest = PlanHeuristics.shortWarmUpSeconds + PlanHeuristics.shortCoolDownSeconds
        for d in diag where !d.recovery && !d.bandReachable && d.realized < keptShare * ceiling(d) {
            let what = "\(label): week \(d.index) asked \(Int(d.desired / 60)), \(shape(p.weeks[d.index]))"
            if d.sessionCap.isFinite {
                let finish = d.sessionCap >= 40 * 60 ? PlanHeuristics.longRunFinishShare * d.sessionCap : 0
                let most = Double(d.maxQuality) * max(0, d.sessionCap - shortest) + finish
                XCTAssertLessThan(0.85 * most, PlanHeuristics.hardShareBand.lowerBound * ceiling(d), what,
                                  file: file, line: line)
            } else {
                XCTAssertLessThanOrEqual(d.maxQuality, 1, what, file: file, line: line)
            }
        }
        // #113: a recovery week the probe marks unreachable is graded
        // independently too, loosely. It holds one quality session (a
        // fartlek), so it may fall short only when that session at the cap
        // with the shortest warm-up and cool-down, plus a steady finish on
        // the week's own long run (none under 40 min; a recovery week's long
        // run is held short), holds less than the band's hard time (15%
        // slack). And it is shortened no further than the band needs for
        // what that session holds at the least: its main set at the cap less
        // the shortest warm-up and cool-down, less 3 min for whole-minute
        // reps, at the top of the band (24%).
        for d in diag where d.recovery && !d.bandReachable && d.realized < keptShare * ceiling(d) {
            let what = "\(label): recovery week \(d.index) asked \(Int(d.desired / 60)), \(shape(p.weeks[d.index]))"
            XCTAssertLessThanOrEqual(d.maxQuality, 1, what, file: file, line: line)
            guard d.sessionCap.isFinite else { continue }
            let room = max(0, d.sessionCap - shortest)
            let long = p.weeks[d.index].workouts.first { $0.kind == .long }?.durationSeconds ?? 0
            let finish = long >= 40 * 60 ? PlanHeuristics.longRunFinishShare * long : 0
            let most = Double(d.maxQuality) * room + finish
            XCTAssertLessThan(0.85 * most, PlanHeuristics.hardShareBand.lowerBound * ceiling(d), what,
                              file: file, line: line)
            let least = Double(d.maxQuality) * max(0, room - 3 * 60) / PlanHeuristics.hardShareBand.upperBound
            XCTAssertGreaterThanOrEqual(d.realized, min(keptShare * ceiling(d), least) - 1e-6, what,
                                        file: file, line: line)
        }
    }
}
