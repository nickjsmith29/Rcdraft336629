import XCTest
@testable import CoachCore

// F3 and SPEC 3.5 (recovery weeks), follow-ups to the plan builder review
// (#13 here, #42 in the earlier repo): a recovery week under an hour keeps
// the layout `PlanHeuristics.minimumRecoveryWeekSeconds` describes (short
// easy running and a short fartlek), with no run under the easy-run floor
// (`PlanHeuristics.minimumEasyRunSeconds`) and no run labelled "long" under
// it. The expected totals below were recorded from main at 29e8fc7, so the
// sweep fails if a week ever grows or takes more hard time. Synthetic
// runners only: every figure is made up.
final class PlanBuilderSmallWeekTests: XCTestCase {
    private typealias F = PlanFixture
    private let utc = PlanFixture.utc
    private let floor = PlanHeuristics.minimumEasyRunSeconds

    private var planMonday: Date { F.date(week: 8, day: 0, hour: 0) }

    private let daySets: [[PlanWeekday]] = [
        [.monday, .wednesday, .sunday],
        [.monday, .wednesday, .friday, .sunday],
        [.monday, .tuesday, .thursday, .friday, .sunday],
        [.tuesday, .wednesday, .thursday, .friday, .saturday, .sunday],
    ]
    private let distances = [Distance.fiveK, Distance.tenK, Distance.halfMarathon, Distance.marathon]

    /// Seven build weeks of `weekly` minutes on three days (a long run on
    /// Sunday), so the plan's first week is a required recovery week
    /// (3.5 rule 2) of 75 to 80% of it. `recentWeeklySeconds` stays at the
    /// builder's minimum, so only the history sets the week's size.
    private func scenario(weekly: Double, days: [PlanWeekday], distance: Double,
                          limits: GuardrailLimits = .default) -> (PlanBuildResult, [PlannedWorkout]) {
        var h: [PlannedWorkout] = []
        for k in 0..<7 {
            for d in [PlanWeekday.monday, .wednesday, .sunday] {
                h.append(F.workout("h\(k)-\(d.rawValue)", week: 1 + k, day: d.rawValue, d == .sunday ? .long : .easy,
                                   minutes: weekly / 3))
            }
        }
        let input = PlanInput(raceDistanceMeters: distance,
                              raceDate: planMonday.addingTimeInterval(Double(11 * 7 + 6) * 86_400 + 8 * 3600),
                              startDate: planMonday, trainingDays: Set(days), longRunDay: days.last!,
                              recentWeeklySeconds: PlanHeuristics.minimumRecentWeeklySeconds,
                              heartRateZones: HRZones(lthr: 168),
                              easyPace: EasyPaceSample(secondsPerKm: 360, heartRate: 140),
                              fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: 25 * 60))
        return (PlanBuilder.build(input, history: h, timeZone: utc, limits: limits), h)
    }

    private func hardSeconds(_ w: TrainingPlanWeek) -> Double {
        w.workouts.flatMap { $0.prescription?.segments ?? [] }.filter { !$0.intensity.isBelowAerobicThreshold }
            .reduce(0) { $0 + $1.durationSeconds }
    }

    private func shape(_ w: TrainingPlanWeek) -> String {
        w.workouts.map { x -> String in
            let tag = x.kind == .long ? "L" : x.kind == .easy ? "e" : x.kind == .race ? "R" : "q"
            return "\(tag)\(Int(x.durationSeconds / 60))"
        }.joined(separator: " ")
    }

    /// Weekly history minutes -> (total, hard) minutes of the sub-hour
    /// recovery week, recorded from main at 29e8fc7. Weeks of 60 to 68
    /// minutes are refused (see the retry test); any other weekly volume
    /// in 60 to 90 has a recovery week of an hour or more.
    private let main: [Double: (total: Double, hard: Double)] = {
        var t: [Double: (Double, Double)] = [:]
        for w in 69...71 { t[Double(w)] = (50, 10) }
        for w in 72...74 { t[Double(w)] = (52, 10) }
        for w in 75...77 { t[Double(w)] = (54, 10) }
        for w in 78...79 { t[Double(w)] = (56, 10) }
        for w in 80...82 { t[Double(w)] = (58, 10) }
        return t
    }()

    /// The same for a marathon plan, recorded from main at 29e8fc7. Its
    /// long run may take up to 45% of the week (3.5 rule 5), so a 20-minute
    /// run at the easy-run floor fits and stays labelled "long" in weeks of
    /// 72 to 87 minutes of history; 69 to 71 minutes has no long run.
    private let marathonMain: [Double: (total: Double, hard: Double)] = {
        var t: [Double: (Double, Double)] = [:]
        for w in 69...71 { t[Double(w)] = (50, 10) }
        for w in 72...74 { t[Double(w)] = (46, 10) }
        for w in 75...77 { t[Double(w)] = (48, 10) }
        for w in 78...79 { t[Double(w)] = (50, 10) }
        for w in 80...82 { t[Double(w)] = (51, 10) }
        for w in 83...85 { t[Double(w)] = (53, 10) }
        t[87] = (55, 13)
        return t
    }()

    // MARK: Sweep over sub-hour recovery weeks

    func testSubHourRecoveryWeeksNeverGrowAndHoldTheFloor() throws {
        var seen = 0
        for days in daySets {
            for distance in distances {
                for w in stride(from: 60.0, through: 90.0, by: 1.0) {
                    let (result, history) = scenario(weekly: w, days: days, distance: distance)
                    let label = "\(days.count) days, \(Int(distance)) m, \(Int(w)) min"
                    let table = distance == Distance.marathon ? marathonMain : main
                    // A recorded week must still build: a new refusal fails here.
                    if table[w] != nil { XCTAssertNotNil(result.plan, "\(label): \(result.issues)") }
                    guard let plan = result.plan else { continue }
                    let small = plan.weeks.filter { $0.isRecoveryWeek && !$0.isRaceWeek && $0.trainingSeconds < 3600 }
                    if table[w] == nil { XCTAssertTrue(small.isEmpty, "\(label): \(small.map(shape))") }
                    for week in small {
                        seen += 1
                        let expected = try XCTUnwrap(table[w], label)
                        // Hard limits: no more time, and no more hard time, than main plans.
                        let why = "\(label): \(shape(week))"
                        XCTAssertLessThanOrEqual(week.trainingSeconds, expected.total * 60 + 1e-6, why)
                        XCTAssertLessThanOrEqual(hardSeconds(week), expected.hard * 60 + 1e-6, why)
                        // No run under the easy-run floor, and so no short "long" run.
                        XCTAssertTrue(week.workouts.allSatisfy { $0.durationSeconds >= floor }, why)
                        XCTAssertTrue(week.workouts.filter { $0.kind == .long }.allSatisfy { $0.durationSeconds >= floor },
                                      why)
                        XCTAssertGreaterThanOrEqual(week.trainingSeconds, PlanHeuristics.minimumRecoveryWeekSeconds, label)
                        XCTAssertTrue(GuardrailChecker.check(history: history, planned: plan.workouts, timeZone: utc).passed,
                                      label)
                    }
                }
            }
        }
        XCTAssertGreaterThan(seen, 100, "the sweep should reach sub-hour recovery weeks")
    }

    // MARK: Layout

    /// A 50-minute recovery week (history 70 min a week) is one easy run and
    /// one short fartlek of equal length, on two of the runner's days: a
    /// second easy run would need another 20 minutes, which the week hasn't
    /// got, so the builder plans fewer runs. It has no long run: for 5K to
    /// half marathon a 20-minute run is over the long run's one-third share
    /// of the week (3.5 rule 5). A marathon plan's ceiling is 45%, so there
    /// the missing long run comes from the other long-run limits, and weeks
    /// of 72 to 87 minutes of history do keep a 20-minute long run (the
    /// sweep above covers them). The fartlek holds 10 minutes of hard
    /// running, 20% of the week, inside 3.1's band.
    func testAFiftyMinuteRecoveryWeekIsOneEasyRunAndAShortFartlek() throws {
        for days in daySets {
            for distance in distances {
                let (result, history) = scenario(weekly: 70, days: days, distance: distance)
                let plan = try XCTUnwrap(result.plan, "\(result.issues)")
                let week = plan.weeks[0]
                XCTAssertTrue(week.isRecoveryWeek)
                XCTAssertEqual(week.trainingSeconds, 50 * 60, accuracy: 1e-6, shape(week))
                XCTAssertEqual(week.workouts.count, 2, shape(week))
                XCTAssertEqual(week.workouts.filter { $0.kind == .easy }.count, 1, shape(week))
                let fartlek = try XCTUnwrap(week.workouts.first { $0.kind == .quality(.fartlek) }, shape(week))
                XCTAssertFalse(week.workouts.contains { $0.kind == .long }, "no long run label: \(shape(week))")
                XCTAssertEqual(hardSeconds(week), 10 * 60, accuracy: 1e-6, shape(week))
                // The fartlek opens and closes with easy running.
                let roles = (fartlek.prescription?.segments ?? []).map(\.role)
                XCTAssertEqual(roles.first, .warmUp)
                XCTAssertEqual(roles.last, .coolDown)
                let share = try XCTUnwrap(week.easyShare)
                XCTAssertTrue((0.75...0.85).contains(share), "\(share)")
                XCTAssertTrue(GuardrailChecker.check(history: history, planned: plan.workouts, timeZone: utc).passed)
            }
        }
    }

    // MARK: The "fewer quality sessions" retry (3.1 band)

    /// `composeWeek` tries fewer quality sessions, down to none, when a week
    /// can't hold the 3.1 band. This test reaches that retry only in the
    /// degenerate case where the one-session draft already has no quality
    /// session (the first recovery week's spike cap is 21 to 24 minutes, too
    /// little for a quality session's warm-up, main set and cool-down), so
    /// the retry to zero repeats the same draft. It pins "the retry runs and
    /// fails", not a real step from more to fewer sessions. With no long run
    /// of 40 minutes, no steady finish can carry hard time, so no draft is in
    /// band. The builder then refuses the plan with `intensityDistributionNotMet`
    /// for that week (all easy running) rather than ship a week outside 3.1.
    /// With the spike rule off the same week fits a fartlek and builds, so
    /// the cap is the cause.
    func testTheFewerQualitySessionsRetryFindsNoBandAndRefusesThePlan() throws {
        let ruleOff = GuardrailLimits(maxSingleRunIncrease: .infinity)
        for days in daySets {
            for distance in distances {
                for w in [60.0, 64.0, 68.0] {
                    let (result, _) = scenario(weekly: w, days: days, distance: distance)
                    XCTAssertNil(result.plan, "\(days.count) days, \(Int(distance)) m, \(Int(w)) min")
                    guard case .intensityDistributionNotMet(let start, let share)? = result.issues.first else {
                        return XCTFail("\(result.issues)")
                    }
                    XCTAssertEqual(start, planMonday)
                    XCTAssertEqual(share, 1.0, accuracy: 1e-9, "all easy")
                    XCTAssertEqual(result.issues.count, 1)
                    let (free, _) = scenario(weekly: w, days: days, distance: distance, limits: ruleOff)
                    let plan = try XCTUnwrap(free.plan, "\(free.issues)")
                    XCTAssertTrue(plan.weeks[0].workouts.contains { $0.kind.isQuality }, shape(plan.weeks[0]))
                }
            }
        }
    }
}
