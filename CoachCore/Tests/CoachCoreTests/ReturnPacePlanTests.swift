import XCTest
@testable import CoachCore

// Paces after a break in built (F3) and adapted (F4) plans (SPEC 3.5 rule 4,
// #28). Synthetic runners only. Day n is n days after `PlanFixture.firstMonday`
// (a Monday). The runner trains Monday, Wednesday, Friday and Sunday: three
// 55-minute easy runs and a 75-minute Sunday long run, 240 minutes a week.

final class ReturnPacePlanTests: XCTestCase {
    private let tz = PlanFixture.utc
    private let zones = HRZones(lthr: 165)!
    private let anchor25 = RaceEquivalent(distanceMeters: Distance.fiveK, seconds: 1500)
    private let anchor24 = RaceEquivalent(distanceMeters: Distance.fiveK, seconds: 1440)

    private func day(_ n: Int, hour: Int = 7) -> Date { PlanFixture.firstMonday.addingTimeInterval(Double(n) * 86_400 + Double(hour) * 3600) }

    /// Week `w` of the runner at `scale` of the usual 240 minutes (runs 55, 55, 55, 75 minutes).
    private func week(_ w: Int, scale: Double = 1) -> [PlannedWorkout] {
        let sessions: [(Int, Double, PlannedWorkout.Kind)] = [(0, 55, .easy), (2, 55, .easy), (4, 55, .easy), (6, 75, .long)]
        return sessions.map { d, m, k in
            PlannedWorkout(id: "h\(w)-\(d)", date: day(w * 7 + d), kind: k, durationSeconds: m * 60 * scale)
        }
    }

    private func history(weeks: [Int]) -> [PlannedWorkout] { weeks.flatMap { week($0) } }

    private func input(planMonday: Int, recentMinutes: Double, longMinutes: Double = 75, efforts: [AnchorEffort] = [],
                       anchor: RaceEquivalent? = nil, distance: Double = Distance.tenK) -> PlanInput {
        let race = day(planMonday + 15 * 7 + 6, hour: 8)
        let a = anchor ?? anchor25
        let predicted = RacePredictor.riegel(knownMeters: a.distanceMeters, knownSeconds: a.seconds, targetMeters: distance)
        return PlanInput(raceDistanceMeters: distance, raceDate: race, startDate: day(planMonday, hour: 0),
                         trainingDays: [.monday, .wednesday, .friday, .sunday], longRunDay: .sunday,
                         recentWeeklySeconds: recentMinutes * 60, recentLongRunSeconds: longMinutes * 60,
                         heartRateZones: zones, easyPace: EasyPaceSample(secondsPerKm: 360, heartRate: 138),
                         fitnessAnchor: a, predictedRaceSeconds: predicted, anchorEfforts: efforts)
    }

    private func model(_ anchor: RaceEquivalent, category: RaceCategory = .tenK) -> TargetModel {
        TargetModel(zones: zones, category: category, easyPace: 360,
                    thresholdPace: TargetModel.riegelPace(anchor: anchor, seconds: 3600),
                    vo2maxPace: TargetModel.riegelPace(anchor: anchor, seconds: 720), racePace: nil)
    }

    private func build(_ i: PlanInput, _ h: [PlannedWorkout], file: StaticString = #filePath, line: UInt = #line) throws -> TrainingPlan {
        let r = PlanBuilder.build(i, history: h, timeZone: tz)
        return try XCTUnwrap(r.plan, "\(r.issues)", file: file, line: line)
    }

    /// Every pace target of the week's segments, by intensity.
    private func paces(_ w: TrainingPlanWeek) -> [WorkoutIntensity: [PaceTarget]] {
        var out: [WorkoutIntensity: [PaceTarget]] = [:]
        for s in w.workouts.flatMap({ $0.prescription?.segments ?? [] }) {
            if let p = s.target.pace { out[s.intensity, default: []].append(p) }
        }
        return out
    }

    /// Checks every segment of `w`: easy and recovery paces from the 6:00 easy
    /// sample, steady, threshold and VO2max paces from `anchor`'s threshold and
    /// VO2max paces, all divided by `f`. Returns the intensities seen.
    @discardableResult
    private func assertPaces(_ w: TrainingPlanWeek, _ f: Double, anchor: RaceEquivalent, label: String,
                             file: StaticString = #filePath, line: UInt = #line) -> Set<WorkoutIntensity> {
        let thr = TargetModel.riegelPace(anchor: anchor, seconds: 3600)! / f
        let vo2 = TargetModel.riegelPace(anchor: anchor, seconds: 720)! / f
        let easy = 360 / f
        let table: [WorkoutIntensity: (Double, Double, Double)] = [
            .easy: (easy, 1.00, 1.12), .recovery: (easy, 1.05, 1.20),
            .steady: (thr, 1.06, 1.12), .threshold: (thr, 0.99, 1.02), .vo2max: (vo2, 0.98, 1.01),
        ]
        var seen: Set<WorkoutIntensity> = []
        for (intensity, list) in paces(w) {
            // Race pace is from the goal and the prediction, not the anchor: never changed.
            if intensity == .racePace || intensity == .race { continue }
            guard let (base, fast, slow) = table[intensity] else {
                XCTFail("\(label): unexpected pace on \(intensity)", file: file, line: line); continue
            }
            seen.insert(intensity)
            for p in list {
                XCTAssertEqual(p.fastestSecondsPerKm, base * fast, accuracy: 1e-6, "\(label) \(intensity)", file: file, line: line)
                XCTAssertEqual(p.slowestSecondsPerKm, base * slow, accuracy: 1e-6, "\(label) \(intensity)", file: file, line: line)
            }
        }
        return seen
    }

    private let quality: Set<WorkoutIntensity> = [.steady, .threshold, .vo2max]

    // MARK: A short break

    /// Weeks 0 to 3 as usual, nothing in weeks 4 and 5 (14 days off, two break weeks), and the plan
    /// starting on day 42: its first week is week 1 back.
    private func shortBreakPlan() throws -> (TrainingPlan, [PlannedWorkout], PlanInput) {
        let h = history(weeks: [0, 1, 2, 3])
        let i = input(planMonday: 42, recentMinutes: 120)
        return (try build(i, h), h, i)
    }

    func testAShortBreakSlowsWeekOneLiftsInWeekTwoAndEndsInWeekThree() throws {
        let (plan, h, i) = try shortBreakPlan()
        // 14 days off, the 14-day row: 0.973. Week 2: halfway to 1.0, (0.973 + 1) / 2 = 0.9865.
        XCTAssertEqual(BreakPaceFactor.factor(daysOff: 14), 0.973)
        let seen = [0.973, 0.9865, 1, 1, 1].enumerated().map { k, f in
            assertPaces(plan.weeks[k], f, anchor: anchor25, label: "week \(k + 1) back")
        }
        XCTAssertTrue(seen[0].contains(.easy), "week 1 back is all easy running")
        XCTAssertTrue(seen[0].isDisjoint(with: quality), "no quality in week 1 back")
        let weekTwoAndThree = seen[1].union(seen[2])
        XCTAssertFalse(weekTwoAndThree.isDisjoint(with: quality), "a quality session is slowed in week 2 or 3 back")
        XCTAssertFalse(seen[1].isDisjoint(with: quality), "week 2 back holds a quality session")
        // Hand check of the first week's easy range: 360 / 0.973 to 1.12 x that.
        let easy = try XCTUnwrap(paces(plan.weeks[0])[.easy]?.first)
        XCTAssertEqual(easy.fastestSecondsPerKm, 369.9897225077081, accuracy: 1e-9)
        XCTAssertEqual(easy.slowestSecondsPerKm, 414.38848920863313, accuracy: 1e-9)
        XCTAssertTrue(plan.notes.contains { $0.contains("14 days without running") }, "\(plan.notes)")
        XCTAssertEqual(h.count, 16)
        XCTAssertEqual(i.anchorEfforts, [])
    }

    func testHeartRateTargetsTheRaceGoalAndThePredictionAreTheSameWithAndWithoutTheBreak() throws {
        let (withBreak, _, brokenInput) = try shortBreakPlan()
        // The same runner with no break: eight steady weeks.
        let steadyInput = input(planMonday: 42, recentMinutes: 240)
        let steady = try build(steadyInput, history(weeks: Array(0..<6)))
        XCTAssertEqual(withBreak.raceSeconds, steady.raceSeconds)
        // The race itself, as planned.
        let raceA = try XCTUnwrap(withBreak.workouts.first { $0.kind == .race })
        let raceB = try XCTUnwrap(steady.workouts.first { $0.kind == .race })
        XCTAssertEqual(raceA, raceB)
        XCTAssertEqual(brokenInput.goalSeconds, steadyInput.goalSeconds)
        XCTAssertEqual(brokenInput.predictedRaceSeconds, steadyInput.predictedRaceSeconds)
        // Every segment's heart-rate target, and every race-pace segment, is the plain model's.
        let plain = TargetModel(zones: zones, category: .tenK, easyPace: 360,
                                thresholdPace: TargetModel.riegelPace(anchor: anchor25, seconds: 3600),
                                vo2maxPace: TargetModel.riegelPace(anchor: anchor25, seconds: 720),
                                racePace: nil)
        for w in withBreak.weeks {
            for s in w.workouts.flatMap({ $0.prescription?.segments ?? [] }) {
                XCTAssertEqual(s.target.heartRate, plain.heartRate(s.intensity), "week \(w.index) \(s.intensity)")
            }
        }
        // Race-pace work keeps the same pace in both plans.
        func racePaces(_ p: TrainingPlan) -> Set<PaceTarget> {
            var out: Set<PaceTarget> = []
            for w in p.workouts {
                for seg in w.prescription?.segments ?? [] where seg.intensity == .racePace || seg.intensity == .race {
                    if let pace = seg.target.pace { out.insert(pace) }
                }
            }
            return out
        }
        XCTAssertFalse(racePaces(steady).isEmpty)
        XCTAssertTrue(racePaces(withBreak).isSubset(of: racePaces(steady)), "\(racePaces(withBreak)) vs \(racePaces(steady))")
    }

    func testAPlanWithNoBreakIsUnchanged() throws {
        // Three common races from steady history: no break, no slow-down, and dated efforts change nothing.
        for distance in [Distance.fiveK, Distance.tenK, Distance.halfMarathon] {
            let h = history(weeks: Array(0..<6))
            let plain = input(planMonday: 42, recentMinutes: 240, distance: distance)
            XCTAssertNil(ReturnPaceSchedule.latest(history: h, efforts: [], raceDistanceMeters: distance,
                                                   startDate: plain.startDate, firstMonday: day(42, hour: 0), timeZone: tz,
                                                   limits: .default), "\(distance)")
            let base = try build(plain, h)
            let withEfforts = input(planMonday: 42, recentMinutes: 240,
                                    efforts: [AnchorEffort(anchor: anchor25, date: day(10), isMarkedRace: true),
                                              AnchorEffort(anchor: anchor24, date: day(30), isMarkedRace: true)],
                                    distance: distance)
            XCTAssertEqual(try build(withEfforts, h), base, "\(distance)")
            XCTAssertFalse(base.notes.contains { $0.contains("without running") })
            // The paces are the anchor's and the easy sample's, undivided.
            for w in base.weeks { assertPaces(w, 1, anchor: anchor25, label: "\(distance) week \(w.index)") }
            // Hand check: easy runs are 6:00 to 6:43.2 per km.
            let easy = try XCTUnwrap(paces(base.weeks[0])[.easy]?.first)
            XCTAssertEqual(easy.fastestSecondsPerKm, 360, accuracy: 1e-9)
            XCTAssertEqual(easy.slowestSecondsPerKm, 403.2, accuracy: 1e-9)
        }
    }

    func testASixDayGapWithNoBreakWeekSlowsThePlanByItsFactor() throws {
        // Runs every day but days 38 to 43, then every day to the plan's start on day 56.
        let h = (0..<56).filter { !(38...43).contains($0) }.map {
            PlannedWorkout(id: "d\($0)", date: day($0), kind: .easy, durationSeconds: 35 * 60)
        }
        let i = input(planMonday: 56, recentMinutes: 245, longMinutes: 35)
        let r = PlanBuilder.build(i, history: h, timeZone: tz)
        // Whether the plan builds is not the point (daily 35-minute runs are far off the schedule): the schedule is.
        let s = try XCTUnwrap(ReturnPaceSchedule.latest(history: h, efforts: [], raceDistanceMeters: Distance.tenK,
                                                       startDate: i.startDate, firstMonday: day(56, hour: 0), timeZone: tz,
                                                       limits: .default))
        XCTAssertEqual(s.daysOff, 6)
        XCTAssertEqual(s.factor, 0.997)
        if let plan = r.plan {
            // Plan week 0 is week 3 back: the factor is 1.
            assertPaces(plan.weeks[0], 1, anchor: anchor25, label: "week 3 back")
        }
    }

    // MARK: Races after a break

    func testNoTrainingPaceIsFasterThanBeforeTheBreakThroughWeekThreeEvenWithAFasterRace() throws {
        // Weeks 0 to 3 as usual, a 14-day break (weeks 4 and 5), week 6 back at 70%.
        // A 25:00 5K race before the break, a faster 24:00 one on day 44, in week 6.
        let h = history(weeks: [0, 1, 2, 3]) + [0, 2, 4].map {
            PlannedWorkout(id: "b\($0)", date: day(42 + $0), kind: .easy, durationSeconds: 56 * 60)
        }
        let efforts = [AnchorEffort(anchor: anchor25, date: day(20), isMarkedRace: true),
                       AnchorEffort(anchor: anchor24, date: day(44), isMarkedRace: true)]
        let i = input(planMonday: 49, recentMinutes: 102, longMinutes: 56, efforts: efforts, anchor: anchor24)
        let plan = try build(i, h)
        // Plan weeks 0 and 1 are weeks 2 and 3 back; week 2 is week 4. The race ended the factor,
        // so easy running is at 6:00 and the paces from the anchor are the pre-break (25:00) ones.
        var sawQuality = false
        for k in 0...1 {
            let seen = assertPaces(plan.weeks[k], 1, anchor: anchor25, label: "week \(k + 2) back")
            sawQuality = sawQuality || !seen.isDisjoint(with: quality)
        }
        XCTAssertTrue(sawQuality)
        // From week 4 back the faster race's paces stand.
        let seenLater = assertPaces(plan.weeks[2], 1, anchor: anchor24, label: "week 4 back")
        XCTAssertFalse(seenLater.isDisjoint(with: quality))
        // And they are faster than the pre-break ones.
        XCTAssertLessThan(try XCTUnwrap(TargetModel.riegelPace(anchor: anchor24, seconds: 3600)),
                          try XCTUnwrap(TargetModel.riegelPace(anchor: anchor25, seconds: 3600)))
    }

    // MARK: A longer break

    /// Weeks 0 to 3, nothing in weeks 4 to 6 (21 days off, three break weeks), weeks 7 to 14 as usual;
    /// the plan starts on day 105, in week 9 back.
    private func longerBreak(efforts: [AnchorEffort] = []) throws -> TrainingPlan {
        let h = history(weeks: [0, 1, 2, 3] + Array(7...14))
        return try build(input(planMonday: 105, recentMinutes: 240, efforts: efforts), h)
    }

    func testALongerBreakHoldsTheFactorPastWeekThree() throws {
        let plan = try longerBreak()
        XCTAssertEqual(BreakPaceFactor.factor(daysOff: 21), 0.952)
        var sawQuality = false
        for w in plan.weeks where !w.isRaceWeek {
            let seen = assertPaces(w, 0.952, anchor: anchor25, label: "week \(w.index)")
            sawQuality = sawQuality || !seen.isDisjoint(with: quality)
        }
        XCTAssertTrue(sawQuality)
        XCTAssertTrue(plan.notes.contains { $0.contains("21 days without running") && $0.contains("held") }, "\(plan.notes)")
    }

    func testATrainingBestEffortAfterALongerBreakDoesNotEndTheFactor() throws {
        let best = AnchorEffort(anchor: anchor25, date: day(84), isMarkedRace: false)
        let plan = try longerBreak(efforts: [best])
        for w in plan.weeks where !w.isRaceWeek {
            assertPaces(w, 0.952, anchor: anchor25, label: "week \(w.index)")
        }
    }

    func testAMarkedRaceAfterALongerBreakEndsTheFactor() throws {
        let race = AnchorEffort(anchor: anchor25, date: day(84), isMarkedRace: true)
        let plan = try longerBreak(efforts: [race])
        var sawQuality = false
        for w in plan.weeks where !w.isRaceWeek {
            let seen = assertPaces(w, 1, anchor: anchor25, label: "week \(w.index)")
            sawQuality = sawQuality || !seen.isDisjoint(with: quality)
        }
        XCTAssertTrue(sawQuality)
        XCTAssertFalse(plan.notes.contains { $0.contains("without running") })
    }

    // MARK: F4

    func testAnAdaptedPlanKeepsTheBuiltPlansPaces() throws {
        let (plan, h, _) = try shortBreakPlan()
        let outcome = AdaptationEngine.processDay(asOf: day(42, hour: 0), state: AdaptationState(), plan: plan.workouts,
                                                  history: h, context: AdaptFixture.context())
        let built = Dictionary(uniqueKeysWithValues: plan.workouts.map { ($0.id, $0) })
        var compared = 0
        for s in outcome.plan {
            guard let b = built[s.id], let bp = b.prescription, let sp = s.prescription else { continue }
            XCTAssertEqual(sp.segments.map(\.target.pace), bp.segments.map(\.target.pace), s.id)
            compared += 1
        }
        XCTAssertGreaterThan(compared, 20)
    }

    func testAnAdaptedPaceStepScalesTheSlowedPace() throws {
        // F4 moves a built target by its own step from where the plan has it: after a break that is the slowed pace.
        let (plan, _, _) = try shortBreakPlan()
        let first = try XCTUnwrap(plan.weeks[0].workouts.first { $0.prescription?.segments.contains { $0.intensity == .easy && $0.target.pace != nil } == true })
        let moved = try XCTUnwrap(first.scalingPaces(of: [.easy], by: 1.02))
        let before = try XCTUnwrap(first.prescription?.segments.first { $0.intensity == .easy }?.target.pace)
        let after = try XCTUnwrap(moved.prescription?.segments.first { $0.intensity == .easy }?.target.pace)
        XCTAssertEqual(after.fastestSecondsPerKm, before.fastestSecondsPerKm * 1.02, accuracy: 1e-9)
        XCTAssertEqual(before.fastestSecondsPerKm, 360 / 0.973, accuracy: 1e-9)
    }

    // MARK: Inputs

    func testAnInvalidDatedEffortIsRefused() {
        let h = history(weeks: Array(0..<6))
        for bad in [RaceEquivalent(distanceMeters: 1000, seconds: 200), RaceEquivalent(distanceMeters: .nan, seconds: 1500),
                    RaceEquivalent(distanceMeters: Distance.fiveK, seconds: -1), RaceEquivalent(distanceMeters: Distance.fiveK, seconds: .infinity),
                    RaceEquivalent(distanceMeters: Distance.fiveK, seconds: 10)] {
            let i = input(planMonday: 42, recentMinutes: 240, efforts: [AnchorEffort(anchor: bad, date: day(10), isMarkedRace: true)])
            XCTAssertEqual(PlanBuilder.build(i, history: h, timeZone: tz).issues, [.invalidValue(.anchorEfforts)], "\(bad)")
        }
        let nan = AnchorEffort(anchor: anchor25, date: Date(timeIntervalSinceReferenceDate: .nan), isMarkedRace: false)
        XCTAssertEqual(PlanBuilder.build(input(planMonday: 42, recentMinutes: 240, efforts: [nan]), history: h, timeZone: tz).issues,
                       [.invalidValue(.anchorEfforts)])
    }

    func testPlanInputDefaultsToNoDatedEfforts() {
        XCTAssertEqual(input(planMonday: 42, recentMinutes: 240).anchorEfforts, [])
    }
}
