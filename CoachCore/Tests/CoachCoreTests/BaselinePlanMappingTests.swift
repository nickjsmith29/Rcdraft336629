import XCTest
@testable import CoachCore

final class BaselinePlanMappingTests: XCTestCase {
    func testBaselineValuesMapIntoThePlanInput() throws {
        let report = GoalFixture.fixtureReport()
        let s = GoalFixture.settings(time: .seconds(6600), maxSession: .seconds(7200))
        let input = BaselinePlanMapping.planInput(settings: s, baseline: report, startDate: GoalFixture.today)
        let load = try XCTUnwrap(report.weeklyLoad.value)
        XCTAssertEqual(input.recentWeeklySeconds, load.currentWeeklyMovingSeconds)
        XCTAssertEqual(input.recentLongRunSeconds, try XCTUnwrap(report.longRuns.value).typicalMovingSeconds)
        XCTAssertEqual(input.heartRateZones, try XCTUnwrap(report.lthr.value).zones)
        let easy = try XCTUnwrap(report.easyPace.value)
        XCTAssertEqual(input.easyPace, EasyPaceSample(secondsPerKm: easy.secondsPerKilometer, heartRate: easy.heartRate))
        // Goal and schedule come from the settings only.
        XCTAssertEqual(input.raceDistanceMeters, Distance.halfMarathon)
        XCTAssertEqual(input.raceDate, s.race.date)
        XCTAssertEqual(input.goalSeconds, 6600)
        XCTAssertEqual(input.startDate, GoalFixture.today)
        XCTAssertEqual(input.trainingDays, GoalFixture.fixtureDays)
        XCTAssertEqual(input.longRunDay, .sunday)
        XCTAssertEqual(input.maxSessionSeconds, 7200)
        XCTAssertNil(BaselinePlanMapping.planInput(settings: GoalFixture.settings(), baseline: report,
                                                   startDate: GoalFixture.today).goalSeconds,
                     "best possible is no goal time")
    }

    func testMarkedRacesAnchorTheClosestDistance() throws {
        let report = GoalFixture.fixtureReport()
        // The fixture has a 10 km race (race-a) and a half marathon (race-b, marked on its dropped copy).
        let half = try XCTUnwrap(BaselinePlanMapping.fitnessAnchor(from: report, raceDistanceMeters: Distance.halfMarathon))
        let raceB = try XCTUnwrap(report.runs.first { $0.activityID == "race-b" })
        XCTAssertEqual(half, RaceEquivalent(distanceMeters: try XCTUnwrap(raceB.distanceMeters), seconds: raceB.movingSeconds))
        let raceA = try XCTUnwrap(report.runs.first { $0.activityID == "race-a" })
        let tenK = RaceEquivalent(distanceMeters: try XCTUnwrap(raceA.distanceMeters), seconds: raceA.movingSeconds)
        XCTAssertEqual(BaselinePlanMapping.fitnessAnchor(from: report, raceDistanceMeters: Distance.tenK), tenK)
        // For a 5K the 10 km race is closer than the half, and a race beats the 5 km best effort.
        XCTAssertEqual(BaselinePlanMapping.fitnessAnchor(from: report, raceDistanceMeters: Distance.fiveK), tenK)
        XCTAssertEqual(BaselinePlanMapping.fitnessAnchor(from: report, raceDistanceMeters: Distance.marathon), half)
    }

    func testBestEffortsAnchorWhenNoRaceIsMarked() throws {
        let report = GoalFixture.fixtureReport(marks: false)
        let recent = try XCTUnwrap(report.bestEfforts.value).recent
        let anchor = try XCTUnwrap(BaselinePlanMapping.fitnessAnchor(from: report, raceDistanceMeters: Distance.tenK))
        let tenK = try XCTUnwrap(recent.first { $0.distanceMeters == Distance.tenK })
        XCTAssertEqual(anchor, RaceEquivalent(distanceMeters: tenK.distanceMeters, seconds: tenK.seconds))
        // Efforts under 3 km never anchor (Riegel's range, SPEC 3.9).
        for a in [Distance.fiveK, Distance.tenK, Distance.halfMarathon, Distance.marathon] {
            let e = try XCTUnwrap(BaselinePlanMapping.fitnessAnchor(from: report, raceDistanceMeters: a))
            XCTAssertTrue(BlendedPredictor.riegelEffortMeters.contains(e.distanceMeters))
        }
    }

    func testNoEffortsMeansNoAnchorOrPrediction() {
        let report = GoalFixture.report(weeks: 6, days: [.monday: 20, .wednesday: 20, .saturday: 25])
        // 25 minutes at easy speed is under 5 km and no run is marked.
        XCTAssertNil(BaselinePlanMapping.fitnessAnchor(from: report, raceDistanceMeters: Distance.tenK))
        XCTAssertNil(BaselinePlanMapping.fitnessAnchor(from: GoalFixture.fixtureReport(), raceDistanceMeters: .nan))
        XCTAssertNil(BaselinePlanMapping.predictedRaceSeconds(from: GoalFixture.fixtureReport(), raceDistanceMeters: .infinity))
        XCTAssertNil(BaselinePlanMapping.predictedRaceSeconds(from: GoalFixture.fixtureReport(), raceDistanceMeters: 0))
        let empty = BaselineBuilder.build(activities: [], options: BaselineOptions(asOf: GoalFixture.today, timeZone: GoalFixture.timeZone))
        XCTAssertNil(BaselinePlanMapping.predictedRaceSeconds(from: empty, raceDistanceMeters: Distance.tenK))
        let input = BaselinePlanMapping.planInput(settings: GoalFixture.settings(), baseline: empty, startDate: GoalFixture.today)
        XCTAssertNil(input.recentWeeklySeconds)
        XCTAssertNil(input.recentLongRunSeconds)
        XCTAssertNil(input.heartRateZones)
        XCTAssertNil(input.easyPace)
        XCTAssertNil(input.fitnessAnchor)
        XCTAssertNil(input.predictedRaceSeconds)
    }

    func testPredictionComesFromTheBlendedPredictor() throws {
        let report = GoalFixture.fixtureReport()
        for meters in [Distance.fiveK, Distance.tenK, Distance.halfMarathon] {
            let p = try XCTUnwrap(BaselinePlanMapping.predictedRaceSeconds(from: report, raceDistanceMeters: meters))
            XCTAssertTrue(BlendedPredictor.plausibleSpeed.contains(meters / p), "\(meters) m in \(p) s")
        }
        let half = try XCTUnwrap(BaselinePlanMapping.predictedRaceSeconds(from: report, raceDistanceMeters: Distance.halfMarathon))
        let five = try XCTUnwrap(BaselinePlanMapping.predictedRaceSeconds(from: report, raceDistanceMeters: Distance.fiveK))
        XCTAssertGreaterThan(half, five)
        let load = try XCTUnwrap(report.weeklyLoad.value)
        let marathon = BaselinePlanMapping.predictedRaceSeconds(from: report, raceDistanceMeters: Distance.marathon)
        if load.distanceIsComplete {
            let m = try XCTUnwrap(marathon, "Vickers-Vertosick runs with weekly distance and a 5K-to-half effort")
            XCTAssertGreaterThan(m, half)
        }
    }

    func testHistoryUsesTheBaselineMovingTimeAndKinds() throws {
        let report = GoalFixture.fixtureReport()
        let history = BaselinePlanMapping.planHistory(from: report)
        XCTAssertEqual(history.map(\.id), report.runs.map(\.activityID))
        for (w, r) in zip(history, report.runs) {
            XCTAssertEqual(w.durationSeconds, r.movingSeconds)
            XCTAssertEqual(w.distanceMeters, r.distanceMeters)
            XCTAssertEqual(w.date, r.start)
            XCTAssertNil(w.prescription)
        }
        let kinds = Dictionary(uniqueKeysWithValues: history.map { ($0.id, $0.kind) })
        XCTAssertEqual(kinds["race-a"], .race)
        XCTAssertEqual(kinds["race-b"], .race, "marked through its dropped duplicate")
        XCTAssertEqual(kinds["w15-sun"], .long)
        XCTAssertEqual(kinds["w15-tue"], .easy)
        XCTAssertEqual(kinds["treadmill"], .easy)
        XCTAssertNil(kinds["w13-sun-planapp"], "dropped duplicates are not history")

        // Each basis week's history volume equals the baseline's weekly load,
        // so the plan builder's history check agrees with recentWeeklySeconds.
        let load = try XCTUnwrap(report.weeklyLoad.value)
        let weeks = PlanWeek.weeks(from: history, timeZone: report.timeZone)
        for basis in load.basisWeekStarts {
            let week = try XCTUnwrap(weeks.first { $0.weekStart == basis })
            let loadWeek = try XCTUnwrap(load.weeks.first { $0.weekStart == basis })
            XCTAssertEqual(try XCTUnwrap(week.volume(.time)), loadWeek.movingSeconds, accuracy: 1e-6)
        }
    }

    func testTimeTrialIsAThresholdSession() throws {
        let days: [PlanWeekday: Double] = [.monday: 30, .wednesday: 30, .saturday: 70]
        let tt = BaselineFixture.run("tt", start: BaselineFixture.date(day: 4 * 7 + 4), seconds: 30 * 60, speed: 3.9,
                                     hr: { _ in 170 }, cadence: 170)
        let report = GoalFixture.report(weeks: 6, days: days, extra: [tt], marks: [EffortMark(activityID: "tt", kind: .timeTrialLast20Min)])
        let kinds = Dictionary(uniqueKeysWithValues: BaselinePlanMapping.planHistory(from: report).map { ($0.id, $0.kind) })
        XCTAssertEqual(kinds["tt"], .quality(.threshold))
    }
}

extension BaselinePlanMappingTests {
    func testMarkedRaceAnchorsOnElapsedTime() throws {
        // race-a with a two-minute stop: elapsed time is two minutes over its moving time.
        let paused = GoalFixture.fixtureReport { acts in
            let i = acts.firstIndex { $0.id == "race-a" }!
            acts[i].durationSeconds += 120
        }
        let raceA = try XCTUnwrap(paused.runs.first { $0.activityID == "race-a" })
        let anchor = try XCTUnwrap(BaselinePlanMapping.fitnessAnchor(from: paused, raceDistanceMeters: Distance.tenK))
        XCTAssertEqual(anchor.seconds, raceA.movingSeconds + 120, accuracy: 1e-6)

        // An elapsed time shorter than the moving time is unusable: moving time is used.
        let short = GoalFixture.fixtureReport { acts in
            let i = acts.firstIndex { $0.id == "race-a" }!
            acts[i].durationSeconds = 10
        }
        let raceA2 = try XCTUnwrap(short.runs.first { $0.activityID == "race-a" })
        let anchor2 = try XCTUnwrap(BaselinePlanMapping.fitnessAnchor(from: short, raceDistanceMeters: Distance.tenK))
        XCTAssertEqual(anchor2.seconds, raceA2.movingSeconds)
        XCTAssertEqual(BaselinePlanMapping.raceSeconds(raceA2, elapsed: .nan), raceA2.movingSeconds)
        XCTAssertEqual(BaselinePlanMapping.raceSeconds(raceA2, elapsed: nil), raceA2.movingSeconds)
    }
}

extension BaselinePlanMappingTests {
    func testAnchorEffortsCarryTheirDatesAndRaceMarks() throws {
        let report = GoalFixture.fixtureReport()
        let input = BaselinePlanMapping.planInput(settings: GoalFixture.settings(), baseline: report, startDate: GoalFixture.today)
        let efforts = BaselinePlanMapping.anchorEfforts(from: report)
        XCTAssertEqual(input.anchorEfforts, efforts)
        XCTAssertFalse(efforts.isEmpty)
        // The two marked races (race-a, race-b) are the marked ones, with their runs' dates.
        let marked = efforts.filter(\.isMarkedRace)
        XCTAssertEqual(marked.count, 2)
        for id in ["race-a", "race-b"] {
            let run = try XCTUnwrap(report.runs.first { $0.activityID == id })
            XCTAssertTrue(marked.contains { $0.date == run.start }, id)
        }
        XCTAssertTrue(efforts.allSatisfy(\.isValid))
        // The anchor is one of them, chosen as before.
        for meters in [Distance.fiveK, Distance.tenK, Distance.halfMarathon, Distance.marathon] {
            let anchor = try XCTUnwrap(BaselinePlanMapping.fitnessAnchor(from: report, raceDistanceMeters: meters))
            XCTAssertTrue(efforts.contains { $0.anchor == anchor }, "\(meters)")
        }
        // Nothing to anchor on means no dated efforts either.
        let empty = BaselineBuilder.build(activities: [], options: BaselineOptions(asOf: GoalFixture.today, timeZone: GoalFixture.timeZone))
        XCTAssertEqual(BaselinePlanMapping.anchorEfforts(from: empty), [])
    }

    func testAMarkedTimeTrialIsNotADatedAnchorEffort() throws {
        // A time trial is a threshold session in the history but no anchor candidate, so it ends no factor.
        let days: [PlanWeekday: Double] = [.monday: 30, .wednesday: 30, .saturday: 70]
        let tt = BaselineFixture.run("tt", start: BaselineFixture.date(day: 4 * 7 + 4), seconds: 30 * 60, speed: 3.9,
                                     hr: { _ in 170 }, cadence: 170)
        let report = GoalFixture.report(weeks: 6, days: days, extra: [tt], marks: [EffortMark(activityID: "tt", kind: .timeTrialLast20Min)])
        let run = try XCTUnwrap(report.runs.first { $0.activityID == "tt" })
        XCTAssertFalse(BaselinePlanMapping.anchorEfforts(from: report).contains { $0.date == run.start && $0.isMarkedRace })
    }
}
