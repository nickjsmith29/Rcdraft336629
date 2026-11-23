import XCTest
@testable import CoachCore

// SPEC F4 / section 8: metrics(run) and classify(m, e), on synthetic runs only.
final class RunClassifierTests: XCTestCase {
    typealias F = AdaptFixture
    private let thr = AdaptFixture.threshold("t", week: 0, day: 1)

    private func assess(_ w: PlannedWorkout, _ spec: F.RunSpec = F.RunSpec()) -> RunAssessment {
        RunClassifier.assess(F.run(for: w, spec), planned: w, zones: F.zones)
    }

    private func metric(_ a: RunAssessment, _ m: TriggerMetric.Metric) -> TriggerMetric? {
        a.triggers.first { $0.metric == m }
    }

    func testOnTargetQualityIsOnTrackAndCitesPaceAndHeartRate() {
        let a = assess(thr)
        XCTAssertEqual(a.signal, .onTrack)
        XCTAssertNil(a.unclassifiedReason)
        let pace = metric(a, .pace)!
        XCTAssertEqual(pace.value, 271.35, accuracy: 0.5)
        XCTAssertEqual(pace.expectedLow!, 267.3, accuracy: 1e-6)
        XCTAssertEqual(pace.expectedHigh!, 275.4, accuracy: 1e-6)
        let hr = metric(a, .heartRate)!
        XCTAssertEqual(hr.expectedLow!, 0.95 * 165, accuracy: 1e-6)
        XCTAssertEqual(hr.expectedHigh!, 1.03 * 165, accuracy: 1e-6)
        XCTAssertTrue(pace.detail.contains("/km"))
    }

    func testKeyWindowsCoverWorkRepsOnlyAfterHeartRateLag() {
        let windows = RunMetrics.keyWindows(thr)!
        XCTAssertEqual(windows.count, 3)
        // Rep 1 starts after the 10 min warm-up; 60 s of HR lag is skipped.
        XCTAssertEqual(windows[0].lowerBound, 660, accuracy: 1e-9)
        XCTAssertEqual(windows[0].upperBound, 1200, accuracy: 1e-9)
        XCTAssertEqual(windows[1].lowerBound, 1380, accuracy: 1e-9)
        // Easy run: 5 min skipped (or a quarter of a short run).
        XCTAssertEqual(RunMetrics.keyWindows(F.easy("e", week: 0, day: 0, minutes: 40))![0].lowerBound, 300)
        XCTAssertEqual(RunMetrics.keyWindows(F.easy("e", week: 0, day: 0, minutes: 12))![0].lowerBound, 180)
        XCTAssertNil(RunMetrics.keyWindows(PlannedWorkout(id: "x", date: Date(), kind: .easy, durationSeconds: 1800)))
    }

    func testBeatingPaceAtNormalHeartRateIsAhead() {
        XCTAssertEqual(assess(thr, F.RunSpec(pace: 0.97)).signal, .ahead)
    }

    func testOnPaceAtLowHeartRateIsAhead() {
        // F4: beating (or holding) pace at a low HR means fitness is ahead of the plan.
        XCTAssertEqual(assess(thr, F.RunSpec(hr: .low)).signal, .ahead)
    }

    func testOnPaceAtHighHeartRateIsBehind() {
        // F4: hitting pace at a high HR means it is not.
        XCTAssertEqual(assess(thr, F.RunSpec(hr: .high)).signal, .behind)
    }

    func testSlowPaceIsBehind() {
        XCTAssertEqual(assess(thr, F.RunSpec(pace: 1.04)).signal, .behind)
    }

    func testPaceWithinToleranceIsOnTrack() {
        // 0.5% slower than the slow end of the range: inside the 1% tolerance.
        let slowEnd = 275.4 * 1.005 / 271.35
        XCTAssertEqual(assess(thr, F.RunSpec(pace: slowEnd)).signal, .onTrack)
    }

    func testSlowPaceAtLowHeartRateIsNotJudged() {
        let a = assess(thr, F.RunSpec(pace: 1.06, hr: .low))
        XCTAssertNil(a.signal)
        XCTAssertTrue(a.unclassifiedReason!.contains("easier than planned"))
    }

    func testRPEMarginsAndInvalidRPE() {
        // Threshold expects RPE 6 to 8: 10 is 2 over, a strain marker only; 0 and 11 are invalid and ignored.
        let strain = assess(thr, F.RunSpec(rpe: 10))
        XCTAssertEqual(strain.signal, .onTrack)
        XCTAssertNotNil(metric(strain, .rpe))
        XCTAssertNil(assess(thr, F.RunSpec(rpe: 11)).metrics.rpe)
        XCTAssertNil(assess(thr, F.RunSpec(rpe: 0)).metrics.rpe)
        let easy = F.easy("e", week: 0, day: 0, minutes: 45)
        XCTAssertEqual(assess(easy, F.RunSpec(rpe: 7)).signal, .overreached)  // easy expects 2 to 4
    }

    func testHighHeartRateWithStrainMarkerIsOverreached() {
        XCTAssertEqual(assess(thr, F.RunSpec(hr: .high, rpe: 10)).signal, .overreached)
    }

    func testDriftAndCadenceFadeOnLongRunAreStrainMarkers() {
        let long = F.long("l", week: 0, day: 5, minutes: 90)
        let a = assess(long, F.RunSpec(drift: 0.3, cadenceFade: 0.08))
        XCTAssertNotNil(a.metrics.decoupling)
        XCTAssertGreaterThan(a.metrics.decoupling!.percent, 10)
        XCTAssertGreaterThan(a.metrics.cadenceFadePercent!, 3)
        XCTAssertEqual(a.signal, .overreached)
        XCTAssertNotNil(metric(a, .decoupling))
        XCTAssertNotNil(metric(a, .cadenceFade))
    }

    func testCadenceFadeValue() {
        // Linear fall of 6% over the run: first third mean 1 - 0.01, last third 1 - 0.05.
        let easy = F.easy("e", week: 0, day: 0, minutes: 45)
        let m = assess(easy, F.RunSpec(cadenceFade: 0.06)).metrics
        XCTAssertEqual(m.cadenceFadePercent!, (0.04 / 0.99) * 100, accuracy: 0.1)
        XCTAssertEqual(assess(easy).metrics.cadenceFadePercent!, 0, accuracy: 1e-9)
    }

    func testCadenceFadeIsNotAStrainMarkerOnIntervals() {
        let a = assess(thr, F.RunSpec(cadenceFade: 0.1))
        XCTAssertNil(metric(a, .cadenceFade))
        XCTAssertEqual(a.signal, .onTrack)
    }

    func testMissingHeartRateIsNotClassified() {
        let a = assess(thr, F.RunSpec(heartRate: false))
        XCTAssertNil(a.signal)
        XCTAssertTrue(a.unclassifiedReason!.contains("heart rate"))
    }

    func testMissingSpeedIsNotClassified() {
        let a = assess(thr, F.RunSpec(speed: false))
        XCTAssertNil(a.signal)
        XCTAssertNil(a.metrics.paceSecondsPerKm)
    }

    func testTreadmillAndHillyPaceAreNotCompared() {
        let tm = assess(thr, F.RunSpec(pace: 0.95, isTreadmill: true))
        XCTAssertNil(tm.signal)
        XCTAssertTrue(tm.unclassifiedReason!.contains("treadmill"))
        let hilly = assess(thr, F.RunSpec(pace: 0.95, climbPerKm: 30))
        XCTAssertNil(hilly.signal)
        XCTAssertGreaterThan(hilly.metrics.climbMetersPerKm!, 15)
        XCTAssertTrue(hilly.unclassifiedReason!.contains("grade-adjusted"))
        XCTAssertLessThan(assess(thr).metrics.climbMetersPerKm!, 1)
    }

    func testRunMuchShorterThanPlannedIsNotClassified() {
        let a = assess(thr, F.RunSpec(durationScale: 0.4))
        XCTAssertNil(a.signal)
        XCTAssertTrue(a.unclassifiedReason!.contains("too little"))
    }

    func testUnplannedRunAndSessionWithoutTargetsAreNotClassified() {
        let run = F.run(for: thr)
        XCTAssertNil(RunClassifier.assess(run, planned: nil, zones: F.zones).signal)
        let bare = PlannedWorkout(id: "q", date: thr.date, kind: .quality(.intervals), durationSeconds: 3240)
        XCTAssertEqual(RunClassifier.assess(run, planned: bare, zones: F.zones).unclassifiedReason,
                       "the planned session has no target to compare with")
        // An easy session made elsewhere is judged by heart rate only: no pace target.
        let easyBare = PlannedWorkout(id: "e", date: thr.date, kind: .easy, durationSeconds: 3240)
        let a = RunClassifier.assess(run, planned: easyBare, zones: F.zones)
        XCTAssertNil(a.signal)
        XCTAssertEqual(a.triggers.first { $0.metric == .heartRate }?.expectedHigh, F.zones.easyCeiling)
    }

    func testBrokenStreamsAreIgnoredNotGuessed() {
        var run = F.run(for: thr)
        run.activity.samples = run.activity.samples.enumerated().map { i, s in
            var s = s
            if i % 7 == 0 { s.heartRate = .nan }
            if i % 11 == 0 { s.speed = .infinity }
            if i % 13 == 0 { s.heartRate = 400 }
            return s
        }
        let a = RunClassifier.assess(run, planned: thr, zones: F.zones)
        XCTAssertEqual(a.signal, .onTrack)
        XCTAssertTrue(a.metrics.key!.heartRate!.isFinite)

        var empty = run
        empty.activity.samples = []
        empty.activity.durationSeconds = .nan
        let e = RunClassifier.assess(empty, planned: thr, zones: F.zones)
        XCTAssertNil(e.signal)
        XCTAssertEqual(e.metrics.movingSeconds, 0)
        XCTAssertNil(e.metrics.key)
        XCTAssertNil(e.metrics.cadenceFadePercent)
    }

    func testExpectedRPEIsOrderedByIntensity() {
        let order: [WorkoutIntensity] = [.recovery, .easy, .steady, .threshold, .vo2max, .race]
        let uppers = order.map { RunClassifier.expectedRPE($0).upperBound }
        XCTAssertEqual(uppers, uppers.sorted())
    }
}
