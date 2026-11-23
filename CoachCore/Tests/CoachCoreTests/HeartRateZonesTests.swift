import XCTest
@testable import CoachCore

final class HeartRateZonesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)
    private func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }
    private func race(_ id: String, minutes: Double, hr: Double, daysAgo d: Double = 10) -> HREffort {
        HREffort(id: id, date: daysAgo(d), kind: .race, durationSeconds: minutes * 60, averageHR: hr)
    }
    private func trial(_ id: String, minutes: Double = 30, hr: Double, daysAgo d: Double = 2) -> HREffort {
        HREffort(id: id, date: daysAgo(d), kind: .timeTrialLast20Min, durationSeconds: minutes * 60, averageHR: hr)
    }

    // MARK: LTHR estimate

    // All efforts below are synthetic; nothing here is any real runner's data.

    func testTenMileRaceSetsLTHR() throws {
        let est = try XCTUnwrap(LTHREstimator.estimate(from: [race("10mi", minutes: 85, hr: 172)], asOf: now))
        XCTAssertEqual(est.bpm, 172)
        XCTAssertEqual(est.source.id, "10mi")
    }

    func testShortRaceIsExcluded() {
        // A 5K in about 24 minutes runs above threshold and must not count.
        XCTAssertNil(LTHREstimator.estimate(from: [race("5k", minutes: 24, hr: 180)], asOf: now))
    }

    func testOverlongRaceIsExcluded() {
        XCTAssertNil(LTHREstimator.estimate(from: [race("hm-slow", minutes: 125, hr: 170)], asOf: now))
    }

    func testDurationBoundsAreInclusive() {
        XCTAssertTrue(LTHREstimator.qualifies(race("a", minutes: 30, hr: 175)))
        XCTAssertTrue(LTHREstimator.qualifies(race("b", minutes: 120, hr: 175)))
        XCTAssertFalse(LTHREstimator.qualifies(race("c", minutes: 29.9, hr: 175)))
    }

    func testHighestQualifyingEffortWinsAndAllAreEvidence() throws {
        let efforts = [
            race("10k", minutes: 48, hr: 174, daysAgo: 40),
            race("10mi", minutes: 85, hr: 172, daysAgo: 6),
            race("5k", minutes: 24, hr: 181, daysAgo: 3)
        ]
        let est = try XCTUnwrap(LTHREstimator.estimate(from: efforts, asOf: now))
        XCTAssertEqual(est.bpm, 174)
        XCTAssertEqual(est.source.id, "10k")
        XCTAssertEqual(est.evidence.map(\.id), ["10k", "10mi"])
    }

    func testTimeTrialCounts() throws {
        let tt = HREffort(id: "tt", date: daysAgo(2), kind: .timeTrialLast20Min, durationSeconds: 30 * 60, averageHR: 181)
        let est = try XCTUnwrap(LTHREstimator.estimate(from: [tt], asOf: now))
        XCTAssertEqual(est.bpm, 181)
    }

    func testShortTimeTrialIsExcluded() {
        let tt = HREffort(id: "tt", date: daysAgo(2), kind: .timeTrialLast20Min, durationSeconds: 20 * 60, averageHR: 181)
        XCTAssertNil(LTHREstimator.estimate(from: [tt], asOf: now))
    }

    func testOldAndFutureEffortsAreExcluded() {
        let old = race("old", minutes: 60, hr: 182, daysAgo: 121)
        let future = race("future", minutes: 60, hr: 182, daysAgo: -1)
        XCTAssertNil(LTHREstimator.estimate(from: [old, future], asOf: now))
        XCTAssertNotNil(LTHREstimator.estimate(from: [old], asOf: now, lookbackDays: 200))
    }

    func testImplausibleHeartRateIsExcluded() {
        XCTAssertNil(LTHREstimator.estimate(from: [race("bad", minutes: 60, hr: 60)], asOf: now))
        XCTAssertNil(LTHREstimator.estimate(from: [race("bad", minutes: 60, hr: 240)], asOf: now))
        XCTAssertNil(LTHREstimator.estimate(from: [race("nan", minutes: 60, hr: .nan)], asOf: now))
    }

    func testNoEffortsGivesNilNotAnAgeGuess() {
        XCTAssertNil(LTHREstimator.estimate(from: [], asOf: now))
    }

    func testEffortExactlyLookbackDaysOldCounts() throws {
        let edge = race("edge", minutes: 60, hr: 175, daysAgo: Double(LTHREstimator.defaultLookbackDays))
        let est = try XCTUnwrap(LTHREstimator.estimate(from: [edge], asOf: now))
        XCTAssertEqual(est.source.id, "edge")
        let custom = race("edge30", minutes: 60, hr: 175, daysAgo: 30)
        XCTAssertNotNil(LTHREstimator.estimate(from: [custom], asOf: now, lookbackDays: 30))
        XCTAssertNil(LTHREstimator.estimate(from: [custom], asOf: now, lookbackDays: 29))
    }

    func testEffortExactlyNowCounts() {
        XCTAssertNotNil(LTHREstimator.estimate(from: [race("today", minutes: 60, hr: 175, daysAgo: 0)], asOf: now))
    }

    func testEqualHeartRateTieGoesToNewerEffort() throws {
        let older = race("older", minutes: 60, hr: 172, daysAgo: 50)
        let newer = race("newer", minutes: 50, hr: 172, daysAgo: 5)
        let est = try XCTUnwrap(LTHREstimator.estimate(from: [older, newer], asOf: now))
        XCTAssertEqual(est.source.id, "newer")
        XCTAssertEqual(est.evidence.map(\.id), ["newer", "older"])
        XCTAssertTrue(est.isCorroborated)
        XCTAssertNil(est.setAside)
    }

    func testHeartRateBoundsOfPlausibleRangeAreInclusive() {
        XCTAssertTrue(LTHREstimator.qualifies(race("lo", minutes: 60, hr: 100)))
        XCTAssertTrue(LTHREstimator.qualifies(race("hi", minutes: 60, hr: 220)))
        XCTAssertFalse(LTHREstimator.qualifies(race("lo-", minutes: 60, hr: 99.9)))
        XCTAssertFalse(LTHREstimator.qualifies(race("hi+", minutes: 60, hr: 220.1)))
        XCTAssertNotNil(HRZones(lthr: 100))
        XCTAssertNotNil(HRZones(lthr: 220))
    }

    func testNonFiniteOrNegativeDurationIsExcluded() {
        XCTAssertFalse(LTHREstimator.qualifies(HREffort(id: "inf", date: now, kind: .race, durationSeconds: .infinity, averageHR: 175)))
        XCTAssertFalse(LTHREstimator.qualifies(trial("inf-tt", minutes: .infinity, hr: 175)))
        XCTAssertFalse(LTHREstimator.qualifies(HREffort(id: "nan", date: now, kind: .race, durationSeconds: .nan, averageHR: 175)))
        XCTAssertFalse(LTHREstimator.qualifies(race("neg", minutes: -60, hr: 175)))
        XCTAssertFalse(LTHREstimator.qualifies(race("inf-hr", minutes: 60, hr: .infinity)))
    }

    func testTimeTrialIsCappedNearThirtyMinutes() {
        // SPEC 3.2: the last 20 minutes of a 30-minute trial; a few minutes' slack only.
        XCTAssertTrue(LTHREstimator.qualifies(trial("30", minutes: 30, hr: 175)))
        XCTAssertTrue(LTHREstimator.qualifies(trial("35", minutes: 35, hr: 175)))
        XCTAssertFalse(LTHREstimator.qualifies(trial("36", minutes: 36, hr: 175)))
        XCTAssertFalse(LTHREstimator.qualifies(trial("60", minutes: 60, hr: 175)))
    }

    // MARK: Robustness to one bad recording

    func testSingleEffortIsUsedButNotCorroborated() throws {
        let est = try XCTUnwrap(LTHREstimator.estimate(from: [race("only", minutes: 60, hr: 170)], asOf: now))
        XCTAssertEqual(est.bpm, 170)
        XCTAssertFalse(est.isCorroborated)
        XCTAssertNil(est.setAside)
    }

    func testTopTwoAgreeingWithinToleranceKeepsHighest() throws {
        // Exactly at the tolerance still agrees.
        let tol = LTHREstimator.agreementToleranceBPM
        let efforts = [race("a", minutes: 60, hr: 170, daysAgo: 20), race("b", minutes: 45, hr: 170 + tol, daysAgo: 10)]
        let est = try XCTUnwrap(LTHREstimator.estimate(from: efforts, asOf: now))
        XCTAssertEqual(est.source.id, "b")
        XCTAssertEqual(est.bpm, 170 + tol)
        XCTAssertTrue(est.isCorroborated)
        XCTAssertNil(est.setAside)
    }

    func testOneGlitchedRecordingCannotSetLTHR() throws {
        // Synthetic: a strap glitch reads 196 on one race; three others sit near 171.
        let efforts = [
            race("glitch", minutes: 50, hr: 196, daysAgo: 8),
            race("r1", minutes: 60, hr: 171, daysAgo: 30),
            race("r2", minutes: 85, hr: 170, daysAgo: 60),
            trial("tt", hr: 172, daysAgo: 15)
        ]
        let est = try XCTUnwrap(LTHREstimator.estimate(from: efforts, asOf: now))
        XCTAssertEqual(est.bpm, 172)
        XCTAssertEqual(est.source.id, "tt")
        XCTAssertEqual(est.setAside?.id, "glitch")
        XCTAssertTrue(est.isCorroborated)
        // The glitch stays in the evidence so the app can show what was set aside.
        XCTAssertEqual(est.evidence.map(\.id), ["glitch", "tt", "r1", "r2"])
        // Zones built from it keep the easy ceiling where the real efforts put it.
        let zones = try XCTUnwrap(HRZones(lthr: est.bpm))
        XCTAssertEqual(zones.easyCeiling, 172 * 0.9, accuracy: 1e-9)
    }

    func testTwoDisagreeingEffortsUseTheLowerOne() throws {
        let tol = LTHREstimator.agreementToleranceBPM
        let efforts = [race("high", minutes: 60, hr: 168 + tol + 0.5), race("low", minutes: 60, hr: 168, daysAgo: 20)]
        let est = try XCTUnwrap(LTHREstimator.estimate(from: efforts, asOf: now))
        XCTAssertEqual(est.bpm, 168)
        XCTAssertEqual(est.source.id, "low")
        XCTAssertEqual(est.setAside?.id, "high")
        XCTAssertFalse(est.isCorroborated)
    }

    func testThreeSpreadEffortsUseTheMedianUncorroborated() throws {
        let efforts = [race("a", minutes: 60, hr: 185), race("b", minutes: 60, hr: 175), race("c", minutes: 60, hr: 165)]
        let est = try XCTUnwrap(LTHREstimator.estimate(from: efforts, asOf: now))
        XCTAssertEqual(est.bpm, 175)
        XCTAssertEqual(est.setAside?.id, "a")
        XCTAssertFalse(est.isCorroborated)
    }

    func testTopTwoAgreeAndThirdFarBelowKeepsHighest() throws {
        let efforts = [race("a", minutes: 60, hr: 175), race("b", minutes: 60, hr: 173), race("c", minutes: 60, hr: 160)]
        let est = try XCTUnwrap(LTHREstimator.estimate(from: efforts, asOf: now))
        XCTAssertEqual(est.bpm, 175)
        XCTAssertEqual(est.source.id, "a")
        XCTAssertNil(est.setAside)
        XCTAssertTrue(est.isCorroborated)
    }

    func testTwoAgreeingBadRecordingsAreNotCaught() throws {
        // Pins the documented limit: the rule guards against one bad recording, not two that agree.
        let efforts = [race("a", minutes: 60, hr: 200), race("b", minutes: 60, hr: 199), race("c", minutes: 60, hr: 171)]
        let est = try XCTUnwrap(LTHREstimator.estimate(from: efforts, asOf: now))
        XCTAssertEqual(est.bpm, 200)
        XCTAssertNil(est.setAside)
        XCTAssertTrue(est.isCorroborated)
    }

    func testNonQualifyingGlitchDoesNotCountTowardAgreement() throws {
        // A too-short race at a high HR is filtered out before the agreement check.
        let efforts = [race("5k", minutes: 22, hr: 190), race("10mi", minutes: 85, hr: 170)]
        let est = try XCTUnwrap(LTHREstimator.estimate(from: efforts, asOf: now))
        XCTAssertEqual(est.bpm, 170)
        XCTAssertNil(est.setAside)
        XCTAssertEqual(est.evidence.map(\.id), ["10mi"])
    }

    // MARK: Zones

    func testZoneBoundsForLTHR180() throws {
        let zones = try XCTUnwrap(HRZones(lthr: 180))
        // Friel run zones: 85, 90, 95, 100, 103, 107 percent of LTHR.
        XCTAssertEqual(zones.lowerBound(.z2), 153, accuracy: 1e-9)
        XCTAssertEqual(zones.lowerBound(.z3), 162, accuracy: 1e-9)
        XCTAssertEqual(zones.lowerBound(.z4), 171, accuracy: 1e-9)
        XCTAssertEqual(zones.lowerBound(.z5a), 180, accuracy: 1e-9)
        XCTAssertEqual(zones.lowerBound(.z5b), 185.4, accuracy: 1e-9)
        XCTAssertEqual(zones.lowerBound(.z5c), 192.6, accuracy: 1e-9)
        XCTAssertEqual(zones.easyCeiling, 162, accuracy: 1e-9)
    }

    func testZoneLookup() throws {
        let zones = try XCTUnwrap(HRZones(lthr: 180))
        XCTAssertEqual(zones.zone(for: 120), .z1)
        XCTAssertEqual(zones.zone(for: 152.9), .z1)
        XCTAssertEqual(zones.zone(for: 153), .z2)   // boundary goes up
        XCTAssertEqual(zones.zone(for: 161.9), .z2)
        XCTAssertEqual(zones.zone(for: 170), .z3)
        XCTAssertEqual(zones.zone(for: 177), .z4)
        XCTAssertEqual(zones.zone(for: 180), .z5a)
        XCTAssertEqual(zones.zone(for: 188), .z5b)
        XCTAssertEqual(zones.zone(for: 200), .z5c)
    }

    func testZoneLookupRejectsBrokenReadings() throws {
        let zones = try XCTUnwrap(HRZones(lthr: 180))
        XCTAssertNil(zones.zone(for: .nan))
        XCTAssertNil(zones.zone(for: .infinity))
        XCTAssertNil(zones.zone(for: -.infinity))
        XCTAssertNil(zones.zone(for: -5))
        XCTAssertNil(zones.zone(for: 0))
        XCTAssertEqual(zones.zone(for: 0.5), .z1)
        XCTAssertEqual(zones.zone(for: 400), .z5c)
    }

    func testEasyCeilingIsExclusive() throws {
        let zones = try XCTUnwrap(HRZones(lthr: 180))
        XCTAssertEqual(zones.zone(for: zones.easyCeiling), .z3)
        XCTAssertEqual(zones.zone(for: zones.easyCeiling.nextDown), .z2)
    }

    func testFrielZoneNames() {
        XCTAssertEqual(HRZone.z4.name, "SubThreshold")
        XCTAssertEqual(HRZone.z5a.name, "SuperThreshold")
        XCTAssertEqual(HRZone.allCases.map(\.name).count, Set(HRZone.allCases.map(\.name)).count)
    }

    func testEasyRunNearThresholdIsNotEasy() throws {
        // SPEC section 2: an "easy" run near threshold HR should be flagged.
        // Synthetic: LTHR 165, easy run averaging 158 bpm (about 96% of LTHR).
        let zones = try XCTUnwrap(HRZones(lthr: 165))
        XCTAssertEqual(zones.easyCeiling, 148.5, accuracy: 1e-9)
        XCTAssertGreaterThan(158, zones.easyCeiling)
        XCTAssertEqual(zones.zone(for: 158), .z4)
    }

    func testImplausibleLTHRIsRejected() {
        XCTAssertNil(HRZones(lthr: 0))
        XCTAssertNil(HRZones(lthr: 250))
        XCTAssertNil(HRZones(lthr: .infinity))
    }
}
