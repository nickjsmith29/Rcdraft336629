import XCTest
@testable import CoachCore

/// Edge cases of `SessionRunner`: short segments, pauses, skips, ending early,
/// sessions with no reps, and missing heart rate or altitude.
final class SessionRunnerEdgeTests: XCTestCase {
    typealias S = SessionTestSupport

    /// Feed `run`'s readings, collecting what is said, with hooks at given reading times.
    private func feed(_ runner: inout SessionRunner, _ run: SyntheticRun, from: Double = -1, to: Double = .infinity,
                      heartRate: ((Double) -> Double?)? = S.heartRate) -> [Announcement] {
        var out: [Announcement] = []
        for r in run.readings where r.time > from && r.time <= to {
            var x = r
            if let hr = heartRate { x.heartRate = hr(x.time) }
            out += runner.ingest(x)
        }
        return out
    }

    private func flat(_ p: WorkoutPrescription, seed: UInt64 = 1, pace: Double = S.repPace) -> SyntheticRun {
        SyntheticRun(segments: [SyntheticSegment(duration: p.durationSeconds + 3, paceSecondsPerKm: pace)], seed: seed, noise: .clean)
    }

    // MARK: Short segments

    /// A countdown point must leave 10 s of the segment before it: a 25 s rep gets only the 10 s point,
    /// a 12 s rep none, a 40 s jog (before a rep) both.
    func testCountdownPointsThatDoNotFitAShortSegmentAreSkipped() {
        let p = S.prescription([S.segment(.warmUp, 20), S.segment(.work, 25), S.segment(.jog, 40),
                                S.segment(.work, 12), S.segment(.coolDown, 20)])
        var runner = SessionRunner(prescription: p)
        let said = feed(&runner, flat(p), heartRate: nil)
        let cds = S.countdowns(said).map { ($0.countdown.segmentIndex, $0.countdown.secondsLeft) }
        XCTAssertEqual(cds.map(\.0), [1, 2, 2])
        XCTAssertEqual(cds.map(\.1), [10, 30, 10])
        // A 15 s rep has no point at all and still starts, splits and ends normally.
        let q = S.prescription([S.segment(.work, 15), S.segment(.jog, 15), S.segment(.work, 15)])
        var r2 = SessionRunner(prescription: q)
        let said2 = feed(&r2, flat(q), heartRate: nil)
        XCTAssertTrue(S.countdowns(said2).isEmpty)
        XCTAssertEqual(S.starts(said2).count, 3)
        XCTAssertEqual(S.splits(said2).count, 2)
        // Both reps are in one block: one summary after the second.
        XCTAssertEqual(S.summaries(said2).count, 1)
    }

    /// A jog is counted down only when a rep follows it.
    func testNoJogCountdownBeforeANonRep() {
        let p = S.prescription([S.segment(.work, 60), S.segment(.jog, 60), S.segment(.coolDown, 60)])
        var runner = SessionRunner(prescription: p)
        let said = feed(&runner, flat(p), heartRate: nil)
        XCTAssertEqual(S.countdowns(said).map(\.countdown.role), [.work, .work])
    }

    // MARK: Pauses

    private var pauseSession: (WorkoutPrescription, SyntheticRun) {
        let p = S.prescription([S.segment(.warmUp, 60), S.segment(.work, 120), S.segment(.jog, 60), S.segment(.coolDown, 60)])
        let run = SyntheticRun(segments: [
            SyntheticSegment(duration: 60, paceSecondsPerKm: S.easyPace),
            SyntheticSegment(duration: 40, paceSecondsPerKm: S.repPace),
            .stopped(duration: 30),
            SyntheticSegment(duration: 80, paceSecondsPerKm: S.repPace),
            SyntheticSegment(duration: 63 + 60, paceSecondsPerKm: S.jogPace),
        ], seed: 3, noise: .clean)
        return (p, run)
    }

    /// The watch pauses the workout for 30 s inside a rep: rep time stops, so the rep still gets 120
    /// moving seconds and the jog starts 30 s later than it would have.
    func testExplicitPauseInsideARepStopsSegmentTime() {
        let (p, run) = pauseSession
        var runner = SessionRunner(prescription: p)
        var said = feed(&runner, run, to: 100)
        XCTAssertFalse(runner.isPaused)
        said += runner.pause(at: 100)
        XCTAssertTrue(runner.isPaused)
        // Readings during the pause are ignored.
        XCTAssertTrue(feed(&runner, run, from: 100, to: 130).isEmpty)
        runner.resume(at: 130)
        said += feed(&runner, run, from: 130)
        let jog = S.starts(said).first { $0.role == .jog }!
        let jogAt = said.first { if case .segmentStart(let s) = $0.content { return s.segmentIndex == jog.segmentIndex } else { return false } }!.time
        let t0 = run.readings[0].time
        XCTAssertEqual(jogAt - t0, 60 + 120 + 30, accuracy: 1.5)
        let split = S.splits(said)[0]
        XCTAssertEqual(split.durationSeconds, 120, accuracy: 1e-6)
        XCTAssertEqual(split.distanceMeters!, 120 / S.repPace * 1000, accuracy: 25)
        XCTAssertEqual(split.paceSecondsPerKm!, S.repPace, accuracy: 6)
        XCTAssertEqual(split.verdict, .inBand)
        XCTAssertEqual(runner.movingSeconds, 60 + 120 + 60 + 60, accuracy: 3)
    }

    /// No pause call, but the pace estimate says the runner stopped (a red light): segment time
    /// stops once the estimate has said stopped twice in a row, so the stop does not eat the rep.
    func testAutoPauseWhileTheEstimateSaysStopped() {
        let (p, run) = pauseSession
        var runner = SessionRunner(prescription: p)
        let said = feed(&runner, run)
        let t0 = run.readings[0].time
        let jogAt = said.first { if case .segmentStart(let s) = $0.content { return s.role == .jog } else { return false } }!.time - t0
        // Not at 180 (no pause credit), not at 210 (the estimate lags the stop by a few seconds each way).
        XCTAssertGreaterThan(jogAt, 180 + 12)
        XCTAssertLessThanOrEqual(jogAt, 210 + 1.5)
        let split = S.splits(said)[0]
        XCTAssertEqual(split.durationSeconds, 120, accuracy: 1e-6)
        XCTAssertEqual(split.paceSecondsPerKm!, S.repPace, accuracy: 8)
        // The same run with auto-pause off: the stop counts as rep time, the jog starts at 180.
        var cfg = SessionRunnerConfig()
        cfg.autoPauseWhenStopped = false
        var off = SessionRunner(prescription: p, config: cfg)
        let saidOff = feed(&off, run)
        let jogOff = saidOff.first { if case .segmentStart(let s) = $0.content { return s.role == .jog } else { return false } }!.time - t0
        XCTAssertEqual(jogOff, 180, accuracy: 1.5)
    }

    /// A pause inside a rep's startup window does not shorten the engine's 60 s no-cue window.
    func testPauseDoesNotEatTheStartupWindow() {
        let p = S.prescription([S.segment(.work, 200)])
        let run = SyntheticRun(segments: [SyntheticSegment(duration: 300, paceSecondsPerKm: 262)], seed: 4, noise: .clean)
        var runner = SessionRunner(prescription: p)
        var said = feed(&runner, run, to: 30)
        said += runner.pause(at: 30)
        runner.resume(at: 100)  // 70 s later on the wall clock
        said += feed(&runner, run, from: 100)
        let cue = S.cues(said).first!
        let t0 = run.readings[0].time
        // The engine's clock excludes the pause: no cue before 60 moving seconds, i.e. wall time 130.
        XCTAssertGreaterThanOrEqual(cue.time - t0, 130 - 1e-6)
    }

    // MARK: Skip and end

    /// Skipping a jog starts the next rep at once: no split for the jog, rep 2 flagged as skipped into.
    func testSkippingAJogStartsTheNextRep() {
        let p = S.prescription([S.segment(.warmUp, 60), S.segment(.work, 60), S.segment(.jog, 120),
                                S.segment(.work, 60), S.segment(.coolDown, 60)])
        let run = flat(p)
        var runner = SessionRunner(prescription: p)
        var said = feed(&runner, run, to: 150)
        let at = 150.0 + run.readings[0].time
        let skipped = runner.skipToNextSegment(at: at)
        said += skipped
        XCTAssertEqual(skipped.map(\.kind), [.segmentStart])
        let start = S.starts(skipped)[0]
        XCTAssertEqual(start.role, .work)
        XCTAssertEqual(start.repNumber, 2)
        XCTAssertEqual(start.repCount, 2)
        XCTAssertTrue(start.startedBySkip)
        XCTAssertEqual(runner.activeSegmentIndex, 3)
        said += feed(&runner, run, from: at)
        XCTAssertEqual(S.splits(said).map(\.repNumber), [1, 2])
        XCTAssertTrue(S.splits(said).allSatisfy(\.isComplete))
        XCTAssertEqual(S.summaries(said).map(\.repsDone), [2])
        // The skipped jog's countdowns never came (it ended before them).
        XCTAssertTrue(S.countdowns(said).allSatisfy { $0.countdown.role == .work })
        XCTAssertEqual(S.ends(said).map(\.reason), [.completed])
    }

    /// Skipping a rep short gives a partial split (not done), and the block's summary counts it apart.
    func testSkippingARepGivesAPartialSplit() {
        let p = S.repSession(reps: 3, rep: 60, jog: 40, warmUp: 30, coolDown: 30)
        let run = flat(p)
        var runner = SessionRunner(prescription: p)
        let t0 = run.readings[0].time
        var said = feed(&runner, run, to: 30 + 100 + 30)  // rep 2 is 30 s in
        said += runner.skipToNextSegment(at: t0 + 160)
        said += feed(&runner, run, from: 160)
        let splits = S.splits(said)
        XCTAssertEqual(splits.map(\.repNumber), [1, 2, 3])
        XCTAssertEqual(splits.map(\.isComplete), [true, false, true])
        XCTAssertEqual(splits[1].durationSeconds, 30, accuracy: 1.5)
        XCTAssertEqual(splits[1].plannedSeconds, 60)
        XCTAssertEqual(splits[1].paceSecondsPerKm!, S.repPace, accuracy: 10)
        let sum = S.summaries(said)
        XCTAssertEqual(sum.count, 1)
        XCTAssertEqual(sum[0].repsDone, 2)
        XCTAssertEqual(sum[0].repsPartial, 1)
        XCTAssertEqual(sum[0].repsPlanned, 3)
        XCTAssertFalse(sum[0].endedEarly)
        XCTAssertTrue(Announcement(time: 0, content: .repSplit(splits[1])).phrase().hasPrefix("Rep 2 stopped early: 3:"))
    }

    /// Ending in rep 4 of 6: a partial split, a summary of the 3 reps done, the end, then silence.
    func testEndingEarlyInARepSummarizesTheRepsDone() {
        let p = S.repSession()
        let run = S.run(for: p, seed: 8, noise: .clean)
        var runner = SessionRunner(prescription: p)
        let t0 = run.readings[0].time
        let endTime = 300 + 3 * 270 + 100.0  // 100 s into rep 4
        var said = feed(&runner, run, to: endTime)
        let ended = runner.end(at: t0 + endTime)
        XCTAssertEqual(ended.map(\.kind), [.sessionEnd, .repSplit, .intervalSummary])
        XCTAssertEqual(S.ends(ended)[0].reason, .endedEarly)
        let split = S.splits(ended)[0]
        XCTAssertEqual(split.repNumber, 4)
        XCTAssertFalse(split.isComplete)
        XCTAssertEqual(split.durationSeconds, 100, accuracy: 1.5)
        let sum = S.summaries(ended)[0]
        XCTAssertEqual(sum.repsDone, 3)
        XCTAssertEqual(sum.repsPartial, 1)
        XCTAssertEqual(sum.repsPlanned, 6)
        XCTAssertTrue(sum.endedEarly)
        XCTAssertEqual(sum.repsInBand, 3)
        XCTAssertTrue(Announcement(time: 0, content: .intervalSummary(sum)).phrase().hasPrefix("Ended after 3 of 6 reps, average"))
        XCTAssertEqual(runner.phase, .finished(.endedEarly))
        // After the end: nothing, however many readings come, and a second end is a no-op.
        said = feed(&runner, run, from: endTime)
        XCTAssertTrue(said.isEmpty)
        XCTAssertTrue(runner.end(at: t0 + endTime + 5).isEmpty)
        XCTAssertTrue(runner.skipToNextSegment(at: t0 + endTime + 5).isEmpty)
    }

    /// Ending in a jog (between reps 3 and 4): a summary of 3 complete reps, no partial split.
    func testEndingEarlyInAJogSummarizesTheRepsDone() {
        let p = S.repSession()
        let run = S.run(for: p, seed: 9, noise: .clean)
        var runner = SessionRunner(prescription: p)
        let endTime = 300 + 2 * 270 + 180 + 40.0  // 40 s into the jog after rep 3
        _ = feed(&runner, run, to: endTime)
        let ended = runner.end(at: run.readings[0].time + endTime)
        XCTAssertEqual(ended.map(\.kind), [.sessionEnd, .intervalSummary])
        let sum = S.summaries(ended)[0]
        XCTAssertEqual(sum.repsDone, 3)
        XCTAssertEqual(sum.repsPartial, 0)
        XCTAssertTrue(sum.endedEarly)
    }

    /// Ending before any rep, or after the block's summary: no second or empty summary.
    func testEndingEarlyOutsideTheBlockAddsNoSummary() {
        let p = S.repSession(reps: 2)
        let run = S.run(for: p, seed: 10, noise: .clean)
        var warm = SessionRunner(prescription: p)
        _ = feed(&warm, run, to: 100)
        XCTAssertEqual(warm.end(at: run.readings[0].time + 100).map(\.kind), [.sessionEnd])
        var cool = SessionRunner(prescription: p)
        let all = feed(&cool, run, to: 300 + 2 * 180 + 90 + 50)
        XCTAssertEqual(S.summaries(all).count, 1)
        XCTAssertEqual(cool.end(at: run.readings[0].time + 300 + 2 * 180 + 90 + 50).map(\.kind), [.sessionEnd])
        // Before the first reading: just the end.
        var fresh = SessionRunner(prescription: p)
        XCTAssertEqual(fresh.end(at: 5).map(\.kind), [.sessionEnd])
        XCTAssertEqual(fresh.phase, .finished(.endedEarly))
        XCTAssertTrue(fresh.ingest(LiveReading(time: 6, gpsSpeed: 4)).isEmpty)
    }

    /// Skipping the last segment ends the workout, like pressing end.
    func testSkippingTheLastSegmentEndsTheWorkout() {
        let p = S.prescription([S.segment(.warmUp, 30), S.segment(.coolDown, 60)])
        let run = flat(p)
        var runner = SessionRunner(prescription: p)
        _ = feed(&runner, run, to: 50)
        let said = runner.skipToNextSegment(at: run.readings[0].time + 50)
        XCTAssertEqual(S.ends(said).map(\.reason), [.endedEarly])
        XCTAssertEqual(runner.phase, .finished(.endedEarly))
    }

    // MARK: No reps

    /// An easy run has no countdowns and no rep splits, and a summary at the end of `main` only when
    /// it is long enough. The summary's heart-rate drift is second half minus first half.
    func testEasyRunHasASummaryOnlyIfMainIsLongEnough() {
        let long = S.prescription([S.segment(.main, 900, ceiling: 160)])
        var runner = SessionRunner(prescription: long)
        let said = feed(&runner, flat(long, pace: S.easyPace))
        XCTAssertTrue(S.countdowns(said).isEmpty)
        XCTAssertTrue(S.splits(said).isEmpty)
        // The end of the last segment: the workout ends first, then the segment's summary.
        XCTAssertEqual(said.map(\.kind), [.segmentStart, .sessionEnd, .intervalSummary])
        let sum = S.summaries(said)[0]
        XCTAssertEqual(sum.role, .main)
        XCTAssertEqual(sum.repsDone, 1)
        XCTAssertEqual(sum.repsPlanned, 1)
        XCTAssertFalse(sum.endedEarly)
        XCTAssertEqual(sum.repsInBand, 1)
        // Heart rate rises 0.02 bpm/s; the first half skips its lag (225 s): centres 337.5 and 675 s.
        XCTAssertEqual(sum.heartRateDriftBPM!, 0.02 * (675 - 337.5), accuracy: 0.3)
        XCTAssertEqual(sum.averagePaceSecondsPerKm!, S.easyPace, accuracy: 6)
        XCTAssertNil(sum.gradeAdjustedSpreadSecondsPerKm, "one rep has no spread")
        XCTAssertTrue(Announcement(time: 0, content: .intervalSummary(sum)).phrase(units: .metric).hasPrefix("Main run done, average"))

        let short = S.prescription([S.segment(.main, 480, ceiling: 160)])
        var r2 = SessionRunner(prescription: short)
        let said2 = feed(&r2, flat(short, pace: S.easyPace))
        XCTAssertTrue(S.summaries(said2).isEmpty)
        XCTAssertEqual(S.ends(said2).count, 1)
    }

    /// Heart rate over the ceiling reads as "faster" (more effort than planned) for a heart-rate-primary segment.
    func testHeartRatePrimarySegmentIsJudgedByHeartRate() {
        let p = S.prescription([S.segment(.main, 700, ceiling: 148, floor: 100)])
        var runner = SessionRunner(prescription: p)
        let said = feed(&runner, flat(p, pace: S.easyPace))
        let sum = S.summaries(said)[0]
        XCTAssertEqual(sum.repsFaster, 1)
        XCTAssertEqual(sum.repsInBand, 0)
        let low = S.prescription([S.segment(.main, 700, ceiling: 190, floor: 170)])
        var r2 = SessionRunner(prescription: low)
        XCTAssertEqual(S.summaries(feed(&r2, flat(low, pace: S.easyPace)))[0].repsSlower, 1)
    }

    /// A long run's `main` and `finish` each get a summary when at least 10 minutes long.
    func testFinishGetsASummaryToo() {
        let p = S.prescription([S.segment(.main, 700, ceiling: 170), S.segment(.finish, 640), S.segment(.finish, 500)])
        var runner = SessionRunner(prescription: p)
        let said = feed(&runner, flat(p, pace: S.easyPace))
        XCTAssertEqual(S.summaries(said).map(\.role), [.main, .finish])
        XCTAssertTrue(S.countdowns(said).isEmpty)
    }

    // MARK: Missing data

    /// No heart rate and no altitude: those fields are nil (never zero), pace is still reported, and
    /// the verdict falls back to raw pace, as the engine falls back to a flat target.
    func testMissingHeartRateAndAltitudeLeaveNilNotZero() {
        let p = S.repSession(reps: 3)
        let run = S.run(for: p, seed: 11, noise: .forCueTests)
        let replay = SessionReplay(run: run, prescription: p, dropAltitude: true)
        let splits = S.splits(replay.announcements)
        XCTAssertEqual(splits.count, 3)
        for s in splits {
            XCTAssertNil(s.averageHeartRate)
            XCTAssertNil(s.gradeAdjustedPaceSecondsPerKm)
            XCTAssertEqual(s.gradeCoverage, 0)
            XCTAssertEqual(s.verdictBasis, .flatPace)
            XCTAssertEqual(s.paceSecondsPerKm!, S.repPace, accuracy: 6)
            XCTAssertEqual(s.verdict, .inBand)
        }
        let sum = S.summaries(replay.announcements)[0]
        XCTAssertNil(sum.heartRateDriftBPM)
        XCTAssertNil(sum.averageGradeAdjustedPaceSecondsPerKm)
        XCTAssertNil(sum.gradeAdjustedSpreadSecondsPerKm)
        XCTAssertEqual(sum.repsWithGradeAdjustedPace, 0)
        XCTAssertEqual(sum.averagePaceSecondsPerKm!, S.repPace, accuracy: 5)
        XCTAssertEqual(sum.repsInBand, 3)
        XCTAssertTrue(Announcement(time: 0, content: .intervalSummary(sum)).phrase().hasPrefix("3 of 3 reps, average 3:4"))
    }

    /// Heart rate present but altitude missing leaves only the altitude fields nil, and sparse heart
    /// rate (every 4th reading) still averages, carried for up to 10 s.
    func testSparseHeartRateStillAveragesAndMissingHeartRateAloneIsNil() {
        let p = S.repSession(reps: 2)
        let run = S.run(for: p, seed: 12, noise: .clean)
        var n = 0
        let replay = SessionReplay(run: run, prescription: p, heartRate: { t in
            n += 1
            return n % 4 == 0 ? S.heartRate(t) : nil
        })
        for s in S.splits(replay.announcements) {
            XCTAssertNotNil(s.averageHeartRate)
            XCTAssertNotNil(s.gradeAdjustedPaceSecondsPerKm)
        }
        // Heart rate that is NaN, zero or negative is missing, not a value.
        var k = 0
        let bad = SessionReplay(run: run, prescription: p, heartRate: { _ in
            k += 1
            return [Double.nan, 0, -5][k % 3]
        })
        XCTAssertTrue(S.splits(bad.announcements).allSatisfy { $0.averageHeartRate == nil })
        XCTAssertNil(S.summaries(bad.announcements)[0].heartRateDriftBPM)
    }

    /// A rep with the pace estimate missing for most of it has no pace, distance or verdict (never zero).
    func testTooLittleDataGivesNilNotZero() {
        let p = S.prescription([S.segment(.work, 100)])
        var runner = SessionRunner(prescription: p)
        var said: [Announcement] = []
        var t = 0.0
        while t <= 103 {
            // A watch with no GPS and no motion data after the first 30 s: the estimate goes stale.
            let alive = t < 30
            said += runner.ingest(LiveReading(time: t, gpsSpeed: alive ? 4.4 : nil, gpsAccuracy: alive ? 5 : nil,
                                              watchSpeed: alive ? 4.4 : nil))
            t += 1
        }
        let split = S.splits(said)[0]
        XCTAssertNil(split.paceSecondsPerKm)
        XCTAssertNil(split.distanceMeters)
        XCTAssertNil(split.gradeAdjustedPaceSecondsPerKm)
        XCTAssertEqual(split.verdict, .unknown)
        XCTAssertEqual(split.verdictBasis, .none)
        XCTAssertLessThan(split.coveredFraction, 0.5)
        XCTAssertEqual(split.durationSeconds, 100, accuracy: 1e-6)
        XCTAssertEqual(S.summaries(said)[0].repsUnjudged, 1)
    }

    // MARK: Hills

    /// On a climb the raw pace is slower than the band but the grade-adjusted pace, from the live grade
    /// and the same curve, is in it.
    func testGradeAdjustedPaceUsesTheLiveGrade() {
        let grade = 0.04
        let f = DefaultGradePaceCurve().factor(grade: grade)
        XCTAssertGreaterThan(f, 1.05)
        let p = S.prescription([S.segment(.warmUp, 120), S.segment(.work, 180), S.segment(.coolDown, 60)])
        let run = SyntheticRun(segments: [
            SyntheticSegment(duration: 120, paceSecondsPerKm: S.easyPace),
            SyntheticSegment(duration: 180, paceSecondsPerKm: S.repPace * f, grade: grade),
            SyntheticSegment(duration: 63, paceSecondsPerKm: S.easyPace),
        ], seed: 13, noise: .forCueTests)
        let replay = SessionReplay(run: run, prescription: p)
        let s = S.splits(replay.announcements)[0]
        XCTAssertEqual(s.paceSecondsPerKm!, S.repPace * f, accuracy: 8)
        XCTAssertGreaterThan(s.paceSecondsPerKm!, S.repBand.slow, "the raw pace is outside the band")
        XCTAssertEqual(s.gradeAdjustedPaceSecondsPerKm!, S.repPace, accuracy: 9)
        XCTAssertEqual(s.verdict, .inBand)
        XCTAssertEqual(s.verdictBasis, .gradeAdjustedPace)
        XCTAssertGreaterThan(s.gradeCoverage, 0.8)
    }

    // MARK: Inputs

    func testBadReadingsAreIgnored() {
        let p = S.repSession(reps: 2)
        var runner = SessionRunner(prescription: p)
        XCTAssertEqual(runner.ingest(LiveReading(time: .nan, gpsSpeed: 4)), [])
        XCTAssertEqual(runner.phase, .notStarted)
        XCTAssertEqual(S.starts(runner.ingest(LiveReading(time: 10, gpsSpeed: 4, gpsAccuracy: 5))).count, 1)
        XCTAssertEqual(runner.ingest(LiveReading(time: 10, gpsSpeed: 4)), [], "same time")
        XCTAssertEqual(runner.ingest(LiveReading(time: 9, gpsSpeed: 4)), [], "earlier")
        XCTAssertEqual(runner.ingest(LiveReading(time: .infinity, gpsSpeed: 4)), [])
        XCTAssertEqual(runner.movingSeconds, 0)
        XCTAssertEqual(runner.activeSegmentIndex, 0)
    }

    func testEmptyAndZeroLengthSegments() {
        var empty = SessionRunner(prescription: S.prescription([]))
        XCTAssertEqual(empty.ingest(LiveReading(time: 0, gpsSpeed: 4)), [])
        XCTAssertEqual(empty.phase, .finished(.completed))
        let p = S.prescription([S.segment(.warmUp, 0), S.segment(.work, .nan), S.segment(.main, 30), S.segment(.coolDown, -5)])
        var runner = SessionRunner(prescription: p)
        let said = feed(&runner, SyntheticRun(segments: [SyntheticSegment(duration: 35, paceSecondsPerKm: S.easyPace)], seed: 1, noise: .clean), heartRate: nil)
        XCTAssertEqual(S.starts(said).map(\.segmentIndex), [2], "the original indices are kept")
        XCTAssertEqual(S.ends(said).count, 1)
    }

    func testPhrasesUseTheRunnersUnits() {
        let p = S.repSession(reps: 2)
        let replay = SessionReplay(run: S.run(for: p, seed: 14, noise: .clean), prescription: p, heartRate: S.heartRate)
        let split = S.splits(replay.announcements)[0]
        let phrase = Announcement(time: 0, content: .repSplit(split)).phrase(units: .metric)
        XCTAssertTrue(phrase.hasPrefix("Rep 1: 3:4") || phrase.hasPrefix("Rep 1: 3:3"), phrase)
        XCTAssertTrue(phrase.contains("adjusted") && phrase.hasSuffix("in range") && phrase.contains("bpm"), phrase)
        XCTAssertTrue(Announcement(time: 0, content: .repSplit(split)).phrase(units: .imperial).contains("/mi adjusted"))
        let sum = S.summaries(replay.announcements)[0]
        let text = Announcement(time: 0, content: .intervalSummary(sum)).phrase()
        XCTAssertTrue(text.hasPrefix("2 of 2 reps, average 3:4"), text)
        XCTAssertTrue(text.contains("2 in range") && text.contains("heart rate up"), text)
        let done = replay.announcements.last!
        XCTAssertEqual(done.phrase(), "Workout complete")
    }
}
