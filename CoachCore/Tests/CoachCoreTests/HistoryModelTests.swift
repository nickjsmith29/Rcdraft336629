import XCTest
@testable import CoachCore

// All activities below are synthetic; nothing here is any real runner's data.

private let base = Date(timeIntervalSince1970: 1_790_000_000)

private func day(_ d: Double, plus seconds: Double = 0) -> Date {
    base.addingTimeInterval(d * 86_400 + seconds)
}

/// `count` samples one second apart; each listed stream gets a synthetic value.
private func samples(_ count: Int, streams: Set<StreamKind>) -> [StreamSample] {
    (0..<count).map { i in
        StreamSample(t: Double(i),
                     heartRate: streams.contains(.heartRate) ? 140 : nil,
                     speed: streams.contains(.speed) ? 3 : nil,
                     power: streams.contains(.power) ? 250 : nil,
                     cadence: streams.contains(.cadence) ? 170 : nil,
                     distance: streams.contains(.distance) ? Double(i) * 3 : nil,
                     altitude: streams.contains(.altitude) ? 20 : nil)
    }
}

private func makeRun(_ id: String,
                 source: Activity.Source = .healthKit,
                 sport: Activity.Sport = .run,
                 start: Date,
                 duration: Double = 3_000,
                 streams: Set<StreamKind> = [.heartRate, .speed, .cadence, .distance],
                 sampleCount: Int = 50,
                 averageCadence: Double? = nil,
                 sourceSaysTreadmill: Bool? = nil,
                 isIndoor: Bool? = nil,
                 hasRoute: Bool? = nil) -> Activity {
    Activity(id: id, source: source, sport: sport, start: start, durationSeconds: duration,
             sourceSaysTreadmill: sourceSaysTreadmill, isIndoor: isIndoor, hasRoute: hasRoute,
             averageCadence: averageCadence,
             samples: samples(sampleCount, streams: streams))
}

final class ActivityModelTests: XCTestCase {
    func testPresentStreamsIgnoresNilAndNonFinite() {
        let a = Activity(id: "a", source: .other("plan app"), start: base, durationSeconds: 60, samples: [
            StreamSample(t: 0, heartRate: .nan, speed: 3, cadence: .infinity),
            StreamSample(t: 1, heartRate: nil, speed: 3.1),
        ])
        XCTAssertEqual(a.presentStreams, [.speed])
        XCTAssertFalse(a.hasCadence)
    }

    func testSummaryCadenceCountsAsCadence() {
        let a = makeRun("a", start: base, streams: [.heartRate], averageCadence: 168)
        XCTAssertTrue(a.hasCadence)
        XCTAssertFalse(makeRun("b", start: base, streams: [], averageCadence: .nan).hasCadence)
    }

    func testEmptySamples() {
        let a = makeRun("a", start: base, streams: [], sampleCount: 0)
        XCTAssertTrue(a.presentStreams.isEmpty)
        XCTAssertFalse(a.hasCadence)
    }
}

final class ActivityDeduplicatorTests: XCTestCase {
    func testOverlappingDuplicateKeepsRicherStreams() throws {
        // A plan app logs the run with HR and speed; the watch logs it with five streams.
        let plan = makeRun("plan-1", source: .other("plan app"), start: day(0), duration: 3_010,
                       streams: [.heartRate, .speed], sampleCount: 300)
        let watch = makeRun("watch-1", source: .healthKit, start: day(0, plus: 40), duration: 3_000,
                        streams: [.heartRate, .speed, .cadence, .distance, .altitude], sampleCount: 50)
        let result = ActivityDeduplicator.deduplicate([plan, watch])
        XCTAssertEqual(result.activities.map(\.id), ["watch-1"])
        let drop = try XCTUnwrap(result.dropped.first)
        XCTAssertEqual(drop.dropped.id, "plan-1")
        XCTAssertEqual(drop.keptID, "watch-1")
        XCTAssertEqual(drop.reason, .fewerStreams(kept: 5, dropped: 2))
        XCTAssertEqual(drop.startOffsetSeconds, 40)
        XCTAssertEqual(drop.durationDifferenceSeconds, -10)
        XCTAssertTrue(drop.explanation.contains("plan-1"))
        XCTAssertTrue(drop.explanation.contains("watch-1"))
        XCTAssertTrue(drop.explanation.contains("40 s apart"))
    }

    func testSameStreamsMoreSamplesWins() throws {
        let a = makeRun("a", source: .strava, start: day(0), sampleCount: 100)
        let b = makeRun("b", source: .healthKit, start: day(0), sampleCount: 3_000)
        let result = ActivityDeduplicator.deduplicate([a, b])
        XCTAssertEqual(result.activities.map(\.id), ["b"])
        XCTAssertEqual(result.dropped.first?.reason, .fewerSamples(kept: 3_000, dropped: 100))
    }

    func testEqualRichnessKeepsFirstInInput() {
        let a = makeRun("a", source: .strava, start: day(0))
        let b = makeRun("b", source: .healthKit, start: day(0))
        XCTAssertEqual(ActivityDeduplicator.deduplicate([a, b]).activities.map(\.id), ["a"])
        XCTAssertEqual(ActivityDeduplicator.deduplicate([b, a]).activities.map(\.id), ["b"])
        XCTAssertEqual(ActivityDeduplicator.deduplicate([a, b]).dropped.first?.reason, .equallyRichKeptEarlierInput)
    }

    func testThreeCopiesKeepOne() {
        let copies = [
            makeRun("x", source: .strava, start: day(0, plus: 10), streams: [.heartRate]),
            makeRun("y", source: .healthKit, start: day(0), streams: [.heartRate, .speed, .cadence]),
            makeRun("z", source: .other("plan app"), start: day(0, plus: -30), streams: [.speed]),
        ]
        let result = ActivityDeduplicator.deduplicate(copies)
        XCTAssertEqual(result.activities.map(\.id), ["y"])
        XCTAssertEqual(result.dropped.map(\.dropped.id), ["z", "x"])
    }

    func testStartToleranceBoundaryIsInclusive() {
        let a = makeRun("a", start: day(0))
        XCTAssertTrue(ActivityDeduplicator.isDuplicate(a, makeRun("b", start: day(0, plus: 120))))
        XCTAssertFalse(ActivityDeduplicator.isDuplicate(a, makeRun("c", start: day(0, plus: 121))))
    }

    // MARK: Near-duplicates that are not duplicates

    func testDoubleDayRunsAreNotDuplicates() {
        // Morning and evening runs on the same day.
        let am = makeRun("am", start: day(0))
        let pm = makeRun("pm", start: day(0, plus: 9 * 3_600))
        XCTAssertEqual(ActivityDeduplicator.deduplicate([am, pm]).activities.count, 2)
    }

    func testCloseStartButVeryDifferentDurationIsNotDuplicate() {
        // A warm-up logged separately, starting a minute before the main run.
        let warmup = makeRun("warmup", start: day(0), duration: 600)
        let main = makeRun("main", start: day(0, plus: 60), duration: 3_600)
        let result = ActivityDeduplicator.deduplicate([warmup, main])
        XCTAssertEqual(result.activities.map(\.id), ["warmup", "main"])
        XCTAssertTrue(result.dropped.isEmpty)
    }

    func testDifferentSportsAreNotMerged() {
        let r = makeRun("run", start: day(0))
        let w = makeRun("walk", sport: .walk, start: day(0))
        XCTAssertEqual(ActivityDeduplicator.deduplicate([r, w]).activities.count, 2)
    }

    func testDurationToleranceUsesRelativeShareForLongRuns() {
        // 10% of a two-hour run is 720 s, which beats the 120 s floor.
        let a = makeRun("a", start: day(0), duration: 7_200)
        XCTAssertTrue(ActivityDeduplicator.isDuplicate(a, makeRun("b", start: day(0), duration: 6_500)))
        XCTAssertFalse(ActivityDeduplicator.isDuplicate(a, makeRun("c", start: day(0), duration: 6_400)))
    }

    func testDurationFloorBoundaryOnShortRunIsInclusive() {
        // 10% of 1,000 s is 100 s, so the 120 s floor applies.
        let a = makeRun("a", start: day(0), duration: 1_000)
        XCTAssertTrue(ActivityDeduplicator.isDuplicate(a, makeRun("b", start: day(0), duration: 880)))
        XCTAssertTrue(ActivityDeduplicator.isDuplicate(a, makeRun("b2", start: day(0), duration: 1_120)))
        XCTAssertFalse(ActivityDeduplicator.isDuplicate(a, makeRun("c", start: day(0), duration: 879)))
        XCTAssertFalse(ActivityDeduplicator.isDuplicate(a, makeRun("c2", start: day(0), duration: 1_121)))
    }

    func testDurationFractionBoundaryOnLongRunIsInclusive() {
        // Exactly 10% of the longer duration (7,200 s) is 720 s.
        let a = makeRun("a", start: day(0), duration: 7_200)
        XCTAssertTrue(ActivityDeduplicator.isDuplicate(a, makeRun("b", start: day(0), duration: 6_480)))
        XCTAssertFalse(ActivityDeduplicator.isDuplicate(a, makeRun("c", start: day(0), duration: 6_479)))
        // The fraction is of the longer one: 8,000 vs 7,200 differ by exactly 10% of 8,000.
        XCTAssertTrue(ActivityDeduplicator.isDuplicate(a, makeRun("d", start: day(0), duration: 8_000)))
        XCTAssertFalse(ActivityDeduplicator.isDuplicate(a, makeRun("e", start: day(0), duration: 8_001)))
    }

    func testChainCollapsesToRichestMiddleMember() {
        // a~b and b~c but not a~c. When b is the richest, both ends are dropped as
        // its duplicates; no kept pair is a duplicate and each drop is within
        // tolerance of its keeper.
        let a = makeRun("a", start: day(0), duration: 1_000, streams: [.heartRate])
        let b = makeRun("b", start: day(0, plus: 100), duration: 1_100, streams: [.heartRate, .speed, .cadence])
        let c = makeRun("c", start: day(0, plus: 200), duration: 1_220, streams: [.speed])
        XCTAssertFalse(ActivityDeduplicator.isDuplicate(a, c))
        let result = ActivityDeduplicator.deduplicate([a, b, c])
        XCTAssertEqual(result.activities.map(\.id), ["b"])
        XCTAssertEqual(result.dropped.map(\.dropped.id), ["a", "c"])
        XCTAssertEqual(result.dropped.map(\.keptID), ["b", "b"])
        for drop in result.dropped {
            XCTAssertTrue(ActivityDeduplicator.isDuplicate(b, drop.dropped))
        }
    }

    func testChainDoesNotDropDistinctActivity() {
        // b overlaps both a and c, but a and c are clearly different runs.
        let a = makeRun("a", start: day(0), duration: 1_000, streams: [.heartRate, .speed, .cadence])
        let b = makeRun("b", start: day(0, plus: 100), duration: 1_100, streams: [.heartRate])
        let c = makeRun("c", start: day(0, plus: 200), duration: 1_220, streams: [.heartRate, .speed, .cadence], sampleCount: 40)
        XCTAssertFalse(ActivityDeduplicator.isDuplicate(a, c))
        let result = ActivityDeduplicator.deduplicate([a, b, c])
        XCTAssertEqual(result.activities.map(\.id), ["a", "c"])
        XCTAssertEqual(result.dropped.map(\.dropped.id), ["b"])
    }

    func testNonFiniteOrNegativeDurationIsNeverADuplicate() {
        let good = makeRun("good", start: day(0))
        let nanDur = makeRun("nan", start: day(0), duration: .nan)
        let negative = makeRun("neg", start: day(0), duration: -5)
        let inf = makeRun("inf", start: day(0), duration: .infinity)
        let result = ActivityDeduplicator.deduplicate([good, nanDur, negative, inf])
        XCTAssertEqual(result.activities.count, 4)
        XCTAssertTrue(result.dropped.isEmpty)
    }

    func testEmptyInput() {
        let result = ActivityDeduplicator.deduplicate([])
        XCTAssertTrue(result.activities.isEmpty)
        XCTAssertTrue(result.dropped.isEmpty)
    }

    func testOutputIsInStartOrder() {
        let later = makeRun("later", start: day(2))
        let earlier = makeRun("earlier", start: day(1))
        XCTAssertEqual(ActivityDeduplicator.deduplicate([later, earlier]).activities.map(\.id), ["earlier", "later"])
    }
}

final class TreadmillTaggerTests: XCTestCase {
    func testSourceTreadmillFlagWins() {
        let a = makeRun("a", start: base, streams: [.altitude], sourceSaysTreadmill: true, hasRoute: true)
        XCTAssertEqual(TreadmillTagger.tag(a), TreadmillTag(isTreadmill: true, reason: .sourceTreadmillFlag))
        let b = makeRun("b", start: base, sourceSaysTreadmill: false, isIndoor: true)
        XCTAssertEqual(TreadmillTagger.tag(b), TreadmillTag(isTreadmill: false, reason: .sourceSaysNotTreadmill))
    }

    func testIndoorWithoutRouteOrAltitudeIsTreadmill() {
        let a = makeRun("a", start: base, streams: [.heartRate, .cadence], isIndoor: true, hasRoute: false)
        XCTAssertEqual(TreadmillTagger.tag(a), TreadmillTag(isTreadmill: true, reason: .indoorWithoutLocation))
        // Unknown route counts as no route.
        let b = makeRun("b", start: base, streams: [.heartRate], isIndoor: true, hasRoute: nil)
        XCTAssertTrue(TreadmillTagger.tag(b).isTreadmill)
    }

    func testIndoorWithRouteOrAltitudeIsNotTagged() {
        let route = makeRun("r", start: base, streams: [.heartRate], isIndoor: true, hasRoute: true)
        XCTAssertEqual(TreadmillTagger.tag(route), TreadmillTag(isTreadmill: false, reason: .indoorWithLocation))
        let altitude = makeRun("alt", start: base, streams: [.heartRate, .altitude], isIndoor: true, hasRoute: false)
        XCTAssertEqual(TreadmillTagger.tag(altitude).reason, .indoorWithLocation)
    }

    func testIndoorBarometricAltitudeWithoutTreadmillFlagIsLeftUntagged() {
        // Known limitation: a barometric altimeter records altitude indoors, so an
        // indoor-only flag plus altitude reads as conflicting evidence.
        let indoorOnly = makeRun("i", start: base, streams: [.heartRate, .cadence, .altitude],
                                 isIndoor: true, hasRoute: false)
        XCTAssertEqual(TreadmillTagger.tag(indoorOnly), TreadmillTag(isTreadmill: false, reason: .indoorWithLocation))
        // The same run with the source's treadmill flag is tagged.
        let flagged = makeRun("f", start: base, streams: [.heartRate, .cadence, .altitude],
                              sourceSaysTreadmill: true, isIndoor: true, hasRoute: false)
        XCTAssertEqual(TreadmillTagger.tag(flagged), TreadmillTag(isTreadmill: true, reason: .sourceTreadmillFlag))
    }

    func testSourceNotTreadmillFlagWinsOverIndoorWithoutLocation() {
        let a = makeRun("a", start: base, streams: [.heartRate], sourceSaysTreadmill: false,
                        isIndoor: true, hasRoute: false)
        XCTAssertEqual(TreadmillTagger.tag(a), TreadmillTag(isTreadmill: false, reason: .sourceSaysNotTreadmill))
    }

    func testNoGPSAloneIsNotTreadmill() {
        let a = makeRun("a", start: base, streams: [.heartRate], isIndoor: nil, hasRoute: false)
        XCTAssertEqual(TreadmillTagger.tag(a), TreadmillTag(isTreadmill: false, reason: .noIndoorFlag))
        let b = makeRun("b", start: base, isIndoor: false, hasRoute: false)
        XCTAssertFalse(TreadmillTagger.tag(b).isTreadmill)
    }
}

final class CadenceGapTests: XCTestCase {
    private let withCadence: Set<StreamKind> = [.heartRate, .speed, .cadence]
    private let noCadence: Set<StreamKind> = [.heartRate, .speed]

    func testCadenceStopsAfterDeviceChangeIsFlaggedOngoing() throws {
        let history = [
            makeRun("r1", start: day(0), streams: withCadence),
            makeRun("r2", start: day(2), streams: withCadence),
            makeRun("r3", start: day(4), streams: noCadence),
            makeRun("r4", start: day(6), streams: noCadence),
        ]
        let report = CadenceGapDetector.historyReport(history)
        XCTAssertEqual(report.runCount, 4)
        XCTAssertEqual(report.runsWithCadence, 2)
        let gap = try XCTUnwrap(report.gaps.first)
        XCTAssertEqual(report.gaps.count, 1)
        XCTAssertEqual(gap.activityIDs, ["r3", "r4"])
        XCTAssertEqual(gap.from, day(4))
        XCTAssertEqual(gap.through, day(6))
        XCTAssertTrue(gap.followsRecordedCadence)
        XCTAssertTrue(gap.isOngoing)
    }

    func testInteriorAndLeadingGaps() {
        let history = [
            makeRun("old", start: day(0), streams: noCadence),
            makeRun("a", start: day(1), streams: withCadence),
            makeRun("b", start: day(2), streams: noCadence),
            makeRun("c", start: day(3), streams: withCadence),
        ]
        let gaps = CadenceGapDetector.historyReport(history).gaps
        XCTAssertEqual(gaps.map(\.activityIDs), [["old"], ["b"]])
        XCTAssertEqual(gaps.map(\.followsRecordedCadence), [false, true])
        XCTAssertEqual(gaps.map(\.isOngoing), [false, false])
    }

    func testMinimumRunsFiltersShortStretches() {
        let history = [
            makeRun("a", start: day(1), streams: withCadence),
            makeRun("b", start: day(2), streams: noCadence),
            makeRun("c", start: day(3), streams: withCadence),
        ]
        XCTAssertTrue(CadenceGapDetector.historyReport(history, minimumRuns: 2).gaps.isEmpty)
    }

    func testNeverRecordedCadenceHasNoGapsButSaysSo() {
        let report = CadenceGapDetector.historyReport([makeRun("a", start: day(0), streams: noCadence)])
        XCTAssertTrue(report.gaps.isEmpty)
        XCTAssertTrue(report.neverRecorded)
        XCTAssertFalse(CadenceGapDetector.historyReport([]).neverRecorded)
    }

    func testWalksAreIgnoredAndInputOrderDoesNotMatter() {
        let history = [
            makeRun("r2", start: day(2), streams: withCadence),
            makeRun("walk", sport: .walk, start: day(1), streams: noCadence),
            makeRun("r1", start: day(0), streams: withCadence),
        ]
        let report = CadenceGapDetector.historyReport(history)
        XCTAssertEqual(report.runCount, 2)
        XCTAssertTrue(report.gaps.isEmpty)
    }

    func testWithinRunGapIsFlaggedAndNotFilled() throws {
        var pts = samples(200, streams: withCadence)
        for i in 60..<120 { pts[i].cadence = nil }   // 60 s of missing cadence
        for i in 150..<160 { pts[i].cadence = nil }  // 10 s: below the 30 s minimum
        let activity = Activity(id: "a", source: .healthKit, start: base, durationSeconds: 200, samples: pts)
        let gaps = CadenceGapDetector.gaps(in: activity)
        let gap = try XCTUnwrap(gaps.first)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gap.startT, 60)
        XCTAssertEqual(gap.endT, 120)
        XCTAssertEqual(gap.durationSeconds, 60)
        XCTAssertEqual(gap.missingSampleCount, 60)
        // Detection never touches the data.
        XCTAssertEqual(activity.samples, pts)
        XCTAssertTrue(activity.samples[60..<120].allSatisfy { $0.cadence == nil })
    }

    func testPausedSamplesAreNotGapsAndTrailingGapRunsToLastSample() {
        var pts = samples(100, streams: withCadence)
        for i in 20..<60 { pts[i].cadence = nil; pts[i].isMoving = false }  // a stop at a crossing
        for i in 60..<100 { pts[i].cadence = .nan }                          // watch stops reporting
        let activity = Activity(id: "a", source: .healthKit, start: base, durationSeconds: 100, samples: pts)
        let gaps = CadenceGapDetector.gaps(in: activity)
        // The trailing gap covers the last sample's own interval, so 40 one-second
        // samples read as 40 s, ending at t=100.
        XCTAssertEqual(gaps, [RunCadenceGap(startT: 60, endT: 100, missingSampleCount: 40, durationSeconds: 40)])
    }

    /// One sample per second up to `count`, cadence everywhere; then the given edits.
    private func run(_ count: Int, _ edit: (inout [StreamSample]) -> Void) -> Activity {
        var pts = samples(count, streams: withCadence)
        edit(&pts)
        return Activity(id: "a", source: .healthKit, start: base, durationSeconds: Double(count), samples: pts)
    }

    private static func pause(_ pts: inout [StreamSample], _ range: Range<Int>) {
        for i in range { pts[i].cadence = nil; pts[i].isMoving = false }
    }

    func testMissingCadenceJustBeforeLongStopIsNotAGap() {
        // Five moving samples lose cadence, then the runner stops until t=690 and
        // resumes with cadence. Only 5 s of moving time lacks cadence.
        let activity = run(800) { pts in
            for i in 90..<95 { pts[i].cadence = nil }
            Self.pause(&pts, 95..<690)
        }
        XCTAssertTrue(CadenceGapDetector.gaps(in: activity).isEmpty)
    }

    func testPauseInsideGapIsNotCounted() {
        // 20 s missing, a long stop, then 25 s more missing before cadence returns.
        let activity = run(800) { pts in
            for i in 90..<110 { pts[i].cadence = nil }
            Self.pause(&pts, 110..<690)
            for i in 690..<715 { pts[i].cadence = nil }
        }
        XCTAssertEqual(CadenceGapDetector.gaps(in: activity),
                       [RunCadenceGap(startT: 90, endT: 715, missingSampleCount: 45, durationSeconds: 45)])
        // Below the minimum on moving time even though the span is over 600 s.
        XCTAssertTrue(CadenceGapDetector.gaps(in: activity, minimumSeconds: 46).isEmpty)
    }

    func testMovingTimeBoundaryIsInclusive() {
        let thirty = run(200) { pts in for i in 50..<80 { pts[i].cadence = nil } }
        XCTAssertEqual(CadenceGapDetector.gaps(in: thirty).map(\.durationSeconds), [30])
        let twentyNine = run(200) { pts in for i in 50..<79 { pts[i].cadence = nil } }
        XCTAssertTrue(CadenceGapDetector.gaps(in: twentyNine).isEmpty)
    }

    func testTrailingGapEndingInPauseEndsAtThePause() {
        let activity = run(100) { pts in
            for i in 40..<80 { pts[i].cadence = nil }
            Self.pause(&pts, 80..<100)
        }
        XCTAssertEqual(CadenceGapDetector.gaps(in: activity),
                       [RunCadenceGap(startT: 40, endT: 80, missingSampleCount: 40, durationSeconds: 40)])
    }

    func testTrailingGapUsesMedianSampleInterval() {
        // Samples every 5 s; cadence stops for the last 8 samples (t=60...95).
        let pts = (0..<20).map { i in
            StreamSample(t: Double(i * 5), heartRate: 140, cadence: i < 12 ? 170 : nil)
        }
        let activity = Activity(id: "a", source: .healthKit, start: base, durationSeconds: 100, samples: pts)
        XCTAssertEqual(CadenceGapDetector.gaps(in: activity),
                       [RunCadenceGap(startT: 60, endT: 100, missingSampleCount: 8, durationSeconds: 40)])
    }

    func testUnsortedSamplesAndNonFiniteTimes() {
        var pts = samples(100, streams: withCadence)
        for i in 20..<60 { pts[i].cadence = nil }
        pts.append(StreamSample(t: .nan, heartRate: 140))
        pts.append(StreamSample(t: .infinity, heartRate: 140))
        let activity = Activity(id: "a", source: .healthKit, start: base, durationSeconds: 100,
                                samples: Array(pts.reversed()))
        XCTAssertEqual(CadenceGapDetector.gaps(in: activity),
                       [RunCadenceGap(startT: 20, endT: 60, missingSampleCount: 40, durationSeconds: 40)])
    }

    func testSingleSampleRunHasNoGap() {
        let one = Activity(id: "a", source: .healthKit, start: base, durationSeconds: 1,
                           samples: [StreamSample(t: 0, cadence: 170)])
        XCTAssertTrue(CadenceGapDetector.gaps(in: one).isEmpty)
    }

    func testRunWithoutAnyCadenceHasNoWithinRunGaps() {
        let activity = makeRun("a", start: base, streams: noCadence)
        XCTAssertTrue(CadenceGapDetector.gaps(in: activity).isEmpty)
        XCTAssertTrue(CadenceGapDetector.gaps(in: makeRun("e", start: base, streams: [], sampleCount: 0)).isEmpty)
    }
}

final class HistoryCleanupTests: XCTestCase {
    func testFixtureWithPlantedDuplicatesAndCadenceGap() throws {
        // F1 acceptance shape: planted duplicates and a cadence gap.
        let full: Set<StreamKind> = [.heartRate, .speed, .cadence, .distance, .altitude]
        let history = [
            makeRun("w1", start: day(0), streams: full),
            makeRun("p1", source: .other("plan app"), start: day(0, plus: 20), streams: [.heartRate]),
            makeRun("w2", start: day(2), streams: full),
            makeRun("tm", start: day(3), streams: [.heartRate, .cadence], isIndoor: true, hasRoute: false),
            makeRun("w3", start: day(5), streams: [.heartRate, .speed, .distance]),
            makeRun("p3", source: .strava, start: day(5, plus: -15), streams: [.heartRate]),
            makeRun("w4", start: day(7), streams: [.heartRate, .speed, .distance]),
        ]
        let cleaned = HistoryCleanup.clean(history)
        XCTAssertEqual(cleaned.activities.map(\.id), ["w1", "w2", "tm", "w3", "w4"])
        XCTAssertEqual(Set(cleaned.dropped.map(\.dropped.id)), ["p1", "p3"])
        // No duplicate pairs remain.
        for (i, a) in cleaned.activities.enumerated() {
            for b in cleaned.activities[(i + 1)...] {
                XCTAssertFalse(ActivityDeduplicator.isDuplicate(a, b), "\(a.id) and \(b.id)")
            }
        }
        XCTAssertEqual(cleaned.treadmill["tm"]?.isTreadmill, true)
        XCTAssertEqual(cleaned.treadmill["w1"]?.isTreadmill, false)
        let gap = try XCTUnwrap(cleaned.cadence.gaps.first)
        XCTAssertEqual(cleaned.cadence.gaps.count, 1)
        XCTAssertEqual(gap.activityIDs, ["w3", "w4"])
        XCTAssertTrue(gap.isOngoing)
    }

    func testDuplicateWithoutCadenceDoesNotCreateGap() {
        // A cadence-less copy of a run that has cadence must not look like a gap.
        let history = [
            makeRun("w1", start: day(0)),
            makeRun("p1", source: .other("plan app"), start: day(0, plus: 5), streams: [.heartRate]),
            makeRun("w2", start: day(1)),
        ]
        XCTAssertTrue(HistoryCleanup.clean(history).cadence.gaps.isEmpty)
    }
}
