import XCTest
@testable import CoachCore

// F1 acceptance on a synthetic history (BaselineFixture): planted duplicates,
// a cadence gap and a treadmill run; every baseline value lists its evidence.

final class BaselineFixtureTests: XCTestCase {
    private static let fixture = BaselineFixture.make()
    private static let report = BaselineBuilder.build(activities: fixture.activities,
                                                      efforts: fixture.marks,
                                                      dailyHealth: fixture.health,
                                                      options: BaselineFixture.options())
    private var fixture: BaselineFixture.Fixture { Self.fixture }
    private var report: BaselineReport { Self.report }
    private var keptIDs: Set<String> { Set(report.history.activities.map(\.id)) }

    // MARK: F1 "Accept when"

    func testNoDuplicatePairsRemain() {
        let kept = report.history.activities
        for (i, a) in kept.enumerated() {
            for b in kept[(i + 1)...] {
                XCTAssertFalse(ActivityDeduplicator.isDuplicate(a, b), "\(a.id) and \(b.id) still duplicate")
            }
        }
        let dropped = Dictionary(uniqueKeysWithValues: report.history.dropped.map { ($0.dropped.id, $0.keptID) })
        XCTAssertEqual(dropped, [fixture.duplicateID: fixture.duplicateOfID, "race-b-planapp": "race-b"])
    }

    func testCadenceGapIsFlagged() {
        let gaps = report.history.cadence.gaps
        XCTAssertEqual(gaps.map(\.activityIDs), [fixture.cadenceGapIDs])
        XCTAssertTrue(gaps[0].followsRecordedCadence)
        XCTAssertFalse(gaps[0].isOngoing)
        let trend = try! XCTUnwrap(report.cadence.value)
        XCTAssertEqual(trend.gaps, gaps)
        XCTAssertEqual(trend.runsWithoutCadence, fixture.cadenceGapIDs)
        XCTAssertTrue(Set(trend.evidenceActivityIDs).isDisjoint(with: fixture.cadenceGapIDs))
    }

    func testLTHREstimateListsEvidenceRuns() throws {
        let lthr = try XCTUnwrap(report.lthr.value)
        XCTAssertEqual(lthr.estimate.bpm, BaselineFixture.raceAHR, accuracy: 0.05)
        XCTAssertTrue(lthr.estimate.isCorroborated)
        XCTAssertEqual(lthr.evidenceActivityIDs, ["race-a", "race-b"])
        XCTAssertEqual(lthr.estimate.evidence.map(\.kind), [.race, .race])
        XCTAssertEqual(lthr.zones.lthr, lthr.estimate.bpm)
        XCTAssertEqual(lthr.excluded, [ExcludedRun(activityID: "missing-run", reason: .notInHistory)])
        // The plan app's mark on its dropped copy shows on the kept run's entry.
        XCTAssertEqual(report.runs.first { $0.activityID == "race-b" }?.markedEffort, .race)
        XCTAssertEqual(report.runs.filter { $0.markedEffort != nil }.map(\.activityID), ["race-b", "race-a"])
        XCTAssertEqual(report.runs.map(\.activityID), report.history.activities.map(\.id))
        XCTAssertEqual(report.runs.first { $0.activityID == fixture.treadmillID }?.isTreadmill, true)
    }

    func testEveryAvailableValueCitesKeptRuns() {
        let sections: [(String, BaselineEvidence?)] = [
            ("weeklyLoad", report.weeklyLoad.value), ("longRuns", report.longRuns.value),
            ("bestEfforts", report.bestEfforts.value), ("lthr", report.lthr.value),
            ("peakHeartRate", report.peakHeartRate.value), ("easyPace", report.easyPace.value),
            ("decoupling", report.decoupling.value), ("cadence", report.cadence.value),
        ]
        for (name, section) in sections {
            guard let section else { XCTFail("\(name) unavailable"); continue }
            XCTAssertFalse(section.evidenceActivityIDs.isEmpty, name)
            XCTAssertTrue(Set(section.evidenceActivityIDs).isSubset(of: keptIDs), name)
        }
    }

    // MARK: Values worked out from the generator

    func testWeeklyLoadAveragesTheLastFourCompleteWeeks() throws {
        let load = try XCTUnwrap(report.weeklyLoad.value)
        XCTAssertEqual(load.weeks.count, 12)
        XCTAssertEqual(load.weeks.filter { !$0.isComplete }.count, 1)
        XCTAssertFalse(load.weeks.last!.isComplete)
        XCTAssertEqual(load.basisWeekStarts.count, 4)
        XCTAssertEqual(load.basisWeekStarts.first, BaselineFixture.date(day: 12 * 7, hour: 0))

        let basisRuns = report.history.activities.filter {
            $0.start >= BaselineFixture.date(day: 12 * 7, hour: 0) && $0.start < BaselineFixture.date(day: 16 * 7, hour: 0)
        }
        XCTAssertEqual(Set(load.evidenceActivityIDs), Set(basisRuns.map(\.id)))
        XCTAssertEqual(load.currentWeeklyMovingSeconds, basisRuns.reduce(0) { $0 + $1.durationSeconds } / 4, accuracy: 1e-6)
        XCTAssertEqual(load.currentWeeklyDistanceMeters, basisRuns.reduce(0) { $0 + $1.distanceMeters! } / 4, accuracy: 1e-6)
        XCTAssertTrue(load.distanceIsComplete)
    }

    func testLongRunsAreTheSundayRuns() throws {
        let long = try XCTUnwrap(report.longRuns.value)
        // Race B (about 98 min) outlasts the 80-minute long run of its week.
        let expected = (5..<16).map { $0 == 10 ? "race-b" : "w\($0)-sun" }
        XCTAssertEqual(long.weekly.map(\.activityID), expected)
        XCTAssertEqual(long.longest.activityID, "race-b")
        XCTAssertEqual(long.typicalMovingSeconds!, 80 * 60, accuracy: 1e-6)
    }

    func testBestEffortsComeFromTheRaces() throws {
        let best = try XCTUnwrap(report.bestEfforts.value)
        let pr = Dictionary(uniqueKeysWithValues: best.personalRecords.map { ($0.distanceMeters, $0) })
        XCTAssertEqual(pr[Distance.fiveK]?.activityID, "race-a")
        XCTAssertEqual(pr[Distance.fiveK]!.seconds, Distance.fiveK / BaselineFixture.raceASpeed, accuracy: 1e-6)
        XCTAssertEqual(pr[Distance.tenK]!.seconds, Distance.tenK / BaselineFixture.raceASpeed, accuracy: 1e-6)
        XCTAssertEqual(pr[Distance.halfMarathon]?.activityID, "race-b")
        XCTAssertNil(pr[Distance.marathon], "no run covered a marathon")
        XCTAssertFalse(best.evidenceActivityIDs.contains(fixture.treadmillID))
        XCTAssertEqual(best.recent, best.personalRecords)
    }

    func testPeakHeartRateIsHeldNotSpiked() throws {
        let peak = try XCTUnwrap(report.peakHeartRate.value)
        XCTAssertEqual(peak.activityID, "race-a")
        XCTAssertEqual(peak.bpm, BaselineFixture.raceAHR - 0.5, accuracy: 1e-9)
    }

    func testEasyPaceAtZoneTwoMidpoint() throws {
        let easy = try XCTUnwrap(report.easyPace.value)
        XCTAssertEqual(easy.heartRate, 0.875 * report.lthr.value!.estimate.bpm, accuracy: 1e-9)
        XCTAssertEqual(easy.metersPerSecond, BaselineFixture.easySpeed, accuracy: 1e-9)
        XCTAssertTrue(easy.evidenceActivityIDs.allSatisfy { $0.hasSuffix("-tue") || $0.hasSuffix("-thu") || $0.hasSuffix("-sat") })
        XCTAssertTrue(easy.excluded.contains(ExcludedRun(activityID: fixture.treadmillID, reason: .treadmill)))
    }

    func testTypicalDecouplingFromSteadyLongRuns() throws {
        let dec = try XCTUnwrap(report.decoupling.value)
        XCTAssertEqual(dec.evidenceActivityIDs, (10..<16).map { "w\($0)-sun" })
        XCTAssertEqual(dec.classification, .good)
        XCTAssertGreaterThan(dec.typicalPercent, 0)
        XCTAssertLessThan(dec.typicalPercent, 5)
        XCTAssertEqual(Set(dec.excluded.map(\.activityID)), ["race-a", "race-b"])
        XCTAssertTrue(dec.excluded.allSatisfy { $0.reason == .markedEffort })
    }

    func testCadenceTrendRecoversTheSlope() throws {
        let trend = try XCTUnwrap(report.cadence.value)
        XCTAssertEqual(trend.slopePerWeek.value!, BaselineFixture.cadenceSlopePerWeek, accuracy: 1e-6)
        XCTAssertGreaterThan(trend.recentStepsPerMinute, 168 + 12 * BaselineFixture.cadenceSlopePerWeek)
    }

    func testRestingHRAndHRVBaselines() throws {
        let window = (0..<60).filter { $0 % 9 != 4 }
        for (value, formula) in [(report.restingHeartRate, BaselineFixture.restingHR),
                                 (report.hrv, BaselineFixture.sdnn)] {
            let baseline = try XCTUnwrap(value.value)
            let expected = window.map(formula)
            let mean = expected.reduce(0, +) / Double(expected.count)
            XCTAssertEqual(baseline.days.count, window.count)
            XCTAssertEqual(baseline.mean, mean, accuracy: 1e-9)
            XCTAssertLessThan(baseline.normalRange.lowerBound, mean)
            XCTAssertGreaterThan(baseline.normalRange.upperBound, mean)
            let last7 = (0..<7).filter { $0 % 9 != 4 }.map(formula)
            XCTAssertEqual(baseline.sevenDayAverage.value!, last7.reduce(0, +) / Double(last7.count), accuracy: 1e-9)
        }
    }

    func testNoHRVReadingsMeansNoHRVBaseline() {
        let restingOnly = fixture.health.filter { $0.kind == .restingHeartRate }
        let r = BaselineBuilder.build(activities: fixture.activities, efforts: fixture.marks,
                                      dailyHealth: restingOnly, options: BaselineFixture.options())
        XCTAssertEqual(r.hrv, .insufficient(InsufficientData(.noReadings)))
        XCTAssertNotNil(r.restingHeartRate.value)
    }

    func testWithoutMarkedRacesThereIsNoLTHRAndNoZoneDerivedEasyPace() throws {
        let r = BaselineBuilder.build(activities: fixture.activities, dailyHealth: fixture.health,
                                      options: BaselineFixture.options())
        XCTAssertEqual(r.lthr, .insufficient(InsufficientData(.noMarkedEfforts)))
        XCTAssertEqual(r.easyPace, .insufficient(InsufficientData(.needsLTHR)))

        var opts = BaselineFixture.options()
        opts.easyHeartRate = .bpm(147)
        let withBPM = BaselineBuilder.build(activities: fixture.activities, options: opts)
        XCTAssertEqual(try XCTUnwrap(withBPM.easyPace.value).metersPerSecond, BaselineFixture.easySpeed, accuracy: 1e-9)
    }
}
