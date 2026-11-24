import XCTest
@testable import CoachCore

/// The 6-rep time-based session replayed through `SessionRunner` (F11), and
/// the one-voice priority rules.
final class SessionRunnerTests: XCTestCase {
    typealias S = SessionTestSupport

    private let noise = SyntheticNoise.forCueTests

    /// Wall time (the reading time) each segment starts at, from the start announcements.
    private func startTimes(_ a: [Announcement]) -> [Int: Double] {
        var out: [Int: Double] = [:]
        for x in a { if case .segmentStart(let s) = x.content { out[s.segmentIndex] = x.time } }
        return out
    }

    // MARK: The 6-rep session

    /// Rep numbers, start announcements and targets, in order, with the plan's band.
    func testSixRepSessionAnnouncesEachRepWithItsNumberAndTarget() {
        let p = S.repSession()
        let replay = SessionReplay(run: S.run(for: p, seed: 1, noise: .clean), prescription: p)
        let starts = S.starts(replay.announcements)
        XCTAssertEqual(starts.map(\.segmentIndex), Array(0..<p.segments.count))
        XCTAssertEqual(starts.map(\.role), p.segments.map(\.role))
        let reps = starts.filter { $0.role == .work }
        XCTAssertEqual(reps.map(\.repNumber), [1, 2, 3, 4, 5, 6])
        XCTAssertTrue(reps.allSatisfy { $0.repCount == 6 })
        XCTAssertTrue(reps.allSatisfy { $0.target.pace?.fastestSecondsPerKm == S.repBand.fast && $0.target.pace?.slowestSecondsPerKm == S.repBand.slow })
        XCTAssertTrue(starts.filter { $0.role != .work }.allSatisfy { $0.repNumber == nil })
        // The fixed phrase names the rep and the target, in the runner's units.
        let first = replay.announcements.first { if case .segmentStart(let s) = $0.content { return s.role == .work } else { return false } }!
        XCTAssertEqual(first.phrase(units: .metric), "Rep 1 of 6, target 3:41 to 3:49/km")
        XCTAssertEqual(first.phrase(units: .imperial), "Rep 1 of 6, target 5:56 to 6:09/mi")
        // Segments start on moving time: warm-up 300 s, then 180 s reps and 90 s jogs.
        let t = startTimes(replay.announcements)
        let t0 = replay.steps[0].reading.time
        var expected = 0.0
        for (i, s) in p.segments.enumerated() {
            XCTAssertEqual(t[i]! - t0, expected, accuracy: 1.5, "segment \(i)")
            expected += s.durationSeconds
        }
        XCTAssertEqual(replay.runner.phase, .finished(.completed))
    }

    /// Countdowns at 30 s and 10 s left of every rep, and of every jog (with the next rep's number).
    func testCountdownsBeforeEveryRepAndJogEnd() {
        let p = S.repSession()
        let replay = SessionReplay(run: S.run(for: p, seed: 2, noise: .clean), prescription: p)
        let all = replay.announcements
        let t = startTimes(all)
        let cds = S.countdowns(all)
        XCTAssertEqual(cds.count, 6 * 2 + 5 * 2)
        for (time, c) in cds {
            let start = t[c.segmentIndex]!
            let length = p.segments[c.segmentIndex].durationSeconds
            XCTAssertEqual(time - start, length - c.secondsLeft, accuracy: 1.5, "segment \(c.segmentIndex) \(c.secondsLeft)")
            XCTAssertTrue([30, 10].contains(c.secondsLeft))
        }
        let repCds = cds.filter { $0.countdown.role == .work }
        XCTAssertEqual(repCds.map(\.countdown.repNumber), [1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6])
        XCTAssertEqual(repCds.map(\.countdown.secondsLeft), [30, 10, 30, 10, 30, 10, 30, 10, 30, 10, 30, 10])
        let jogCds = cds.filter { $0.countdown.role == .jog }
        XCTAssertEqual(jogCds.map(\.countdown.nextRepNumber), [2, 2, 3, 3, 4, 4, 5, 5, 6, 6])
        XCTAssertTrue(jogCds.allSatisfy { $0.countdown.repNumber == nil })
        let sample = all.first { if case .countdown(let c) = $0.content { return c.role == .jog } else { return false } }!
        XCTAssertEqual(sample.phrase(), "30 seconds, rep 2 next")
        XCTAssertEqual(cds.first!.countdown.role, .work)
        XCTAssertEqual(all.first { $0.kind == .countdown }!.phrase(), "30 seconds to go")
    }

    /// One split per rep, matching the harness's truth within the pace estimator's error;
    /// one summary at the end of the block; then the workout ends.
    func testSplitsMatchTruthAndASummaryEndsTheBlock() {
        let p = S.repSession()
        var worstPace = 0.0, worstDistance = 0.0, worstHR = 0.0
        for seed in UInt64(1)...5 {
            let run = S.run(for: p, seed: seed, noise: noise)
            let replay = SessionReplay(run: run, prescription: p, heartRate: S.heartRate)
            let splits = S.splits(replay.announcements)
            XCTAssertEqual(splits.map(\.repNumber), [1, 2, 3, 4, 5, 6], "seed \(seed)")
            XCTAssertEqual(replay.runner.splits, splits)
            var segStart = 300.0
            for s in splits {
                // Truth from the segments the harness ran: constant true pace and heart-rate function.
                let trueDistance = 1000 / S.repPace * 180
                XCTAssertEqual(s.durationSeconds, 180, accuracy: 1e-6)
                XCTAssertTrue(s.isComplete)
                XCTAssertEqual(s.plannedSeconds, 180)
                let pace = try! XCTUnwrap(s.paceSecondsPerKm), gap = try! XCTUnwrap(s.gradeAdjustedPaceSecondsPerKm)
                worstPace = max(worstPace, abs(pace - S.repPace))
                worstDistance = max(worstDistance, abs(try! XCTUnwrap(s.distanceMeters) - trueDistance) / trueDistance)
                // Flat truth: the adjusted pace is the raw pace, up to altitude noise through the curve.
                XCTAssertEqual(gap, pace, accuracy: 2)
                let lag = 45.0  // min(60, 180 / 4)
                let trueHR = 140 + 0.02 * (segStart + lag + segStart + 180) / 2
                worstHR = max(worstHR, abs(try! XCTUnwrap(s.averageHeartRate) - trueHR))
                XCTAssertEqual(s.verdict, .inBand, "seed \(seed) rep \(s.repNumber)")
                XCTAssertEqual(s.verdictBasis, .gradeAdjustedPace)
                XCTAssertGreaterThan(s.coveredFraction, 0.9)
                XCTAssertGreaterThan(s.gradeCoverage, 0.9)
                segStart += 270
            }
            // One summary, right after the last rep, in the same announcement group.
            let sums = S.summaries(replay.announcements)
            XCTAssertEqual(sums.count, 1)
            let sum = sums[0]
            XCTAssertEqual(sum.role, .work)
            XCTAssertEqual(sum.repsDone, 6)
            XCTAssertEqual(sum.repsPlanned, 6)
            XCTAssertEqual(sum.repsInBand, 6)
            XCTAssertEqual(sum.repsFaster + sum.repsSlower + sum.repsUnjudged + sum.repsPartial, 0)
            XCTAssertFalse(sum.endedEarly)
            XCTAssertEqual(sum.averageGradeAdjustedPaceSecondsPerKm!, S.repPace, accuracy: 4)
            XCTAssertLessThan(sum.gradeAdjustedSpreadSecondsPerKm!, 8)
            // The made-up heart rate rises 0.02 bpm per second: last rep minus first is 5 reps x 270 s.
            XCTAssertEqual(sum.heartRateDriftBPM!, 27, accuracy: 0.5)
            XCTAssertEqual(sum.heartRateDriftBPM!, splits.last!.averageHeartRate! - splits.first!.averageHeartRate!, accuracy: 1e-9)
            XCTAssertEqual(replay.runner.summaries, sums)
            XCTAssertEqual(S.ends(replay.announcements).map(\.reason), [.completed])
        }
        print(String(format: "SESSION split errors over 5 seeds x 6 reps: worst pace %.1f s/km, worst distance %.1f%%, worst HR %.2f bpm",
                     worstPace, worstDistance * 100, worstHR))
        // A 3-minute rep after an instant pace change is a harder case than the 1-mile lap of F11's
        // 5 s/mile (3.1 s/km) criterion: allow 6 s/km and 4% (heuristic).
        XCTAssertLessThan(worstPace, 6)
        XCTAssertLessThan(worstDistance, 0.04)
        XCTAssertLessThan(worstHR, 0.5)
    }

    /// At a rep's end the order spoken is: the next segment starts, the split, then the summary.
    func testSegmentChangeGroupIsInPriorityOrder() {
        let p = S.repSession(reps: 3)
        let replay = SessionReplay(run: S.run(for: p, seed: 3, noise: .clean), prescription: p, heartRate: S.heartRate)
        let groups = replay.steps.map(\.announcements).filter { $0.count > 1 }
        XCTAssertEqual(groups.count, 3, "each rep ends with a group of its start, split and summary")
        XCTAssertEqual(groups[0].map(\.kind), [.segmentStart, .repSplit])
        XCTAssertEqual(groups[2].map(\.kind), [.segmentStart, .repSplit, .intervalSummary])
        XCTAssertEqual(groups[2].map(\.priority), [.transition, .info, .info])
        // The cool-down's end is the last group: the workout ends.
        XCTAssertEqual(replay.steps.last(where: { !$0.announcements.isEmpty })!.announcements.map(\.kind), [.sessionEnd])
    }

    /// The cue from part 2 still fires when the runner drifts, inside the rep and after its startup window.
    func testPaceCueStillFiresWhenARepDrifts() {
        let p = S.repSession()
        let run = S.run(for: p, seed: 4, noise: noise, repPaces: [2: 262])  // rep 3 about 14% slow
        let replay = SessionReplay(run: run, prescription: p, heartRate: S.heartRate)
        let t = startTimes(replay.announcements)
        let t0 = replay.steps[0].reading.time
        let rep3 = (start: t[5]!, end: t[5]! + 180)
        XCTAssertEqual(rep3.start - t0, 300 + 2 * 270, accuracy: 1.5)
        let cues = S.cues(replay.announcements)
        let inRep3 = cues.filter { $0.time >= rep3.start && $0.time < rep3.end }
        XCTAssertFalse(inRep3.isEmpty)
        XCTAssertTrue(inRep3.allSatisfy { $0.decision.action == .speedUp }, "a reminder is the engine's own, also speed up")
        XCTAssertGreaterThanOrEqual(inRep3[0].time - rep3.start, 60, "never in the first 60 s of a rep")
        XCTAssertEqual(inRep3[0].decision.reason.rule, .sustainedTooSlow)
        XCTAssertEqual(replay.announcements.first { $0.kind == .cue }!.phrase(), "Speed up")
        // The split of that rep says slow, from the session's own numbers; the others are in band.
        let splits = S.splits(replay.announcements)
        XCTAssertEqual(splits[2].verdict, .slower)
        XCTAssertGreaterThan(splits[2].gradeAdjustedPaceSecondsPerKm!, 250)
        XCTAssertEqual(splits.filter { $0.verdict == .inBand }.count, 5)
        let sum = S.summaries(replay.announcements)[0]
        XCTAssertEqual(sum.repsInBand, 5)
        XCTAssertEqual(sum.repsSlower, 1)
        XCTAssertGreaterThan(sum.gradeAdjustedSpreadSecondsPerKm!, 25)
    }

    // MARK: One voice

    /// A one-segment session whose only segment is `segment`, with the countdown aligned to the
    /// reading where a cue is first due: the cue's reading time (found by a first pass with a long
    /// segment) plus `left`, so the countdown point `left` falls on that same reading.
    private func alignedSession(segment make: (Double) -> WorkoutSegment, run: SyntheticRun,
                                heartRate: Double?, left: Double = 30) -> (WorkoutPrescription, Double) {
        let firstPass = SessionRunner(prescription: S.prescription([make(600)]))
        var runner = firstPass
        var cueClock: Double?
        for r in run.readings {
            var x = r
            x.heartRate = heartRate
            if runner.ingest(x).contains(where: { $0.kind == .cue }) { cueClock = x.time - run.readings[0].time; break }
        }
        let c = try! XCTUnwrap(cueClock, "the first pass should cue")
        return (S.prescription([make(c + left)]), run.readings[0].time + c)
    }

    /// A countdown and a pace cue due at the same reading: the countdown first, the cue after the
    /// minimum gap (not dropped, since it is still fresh).
    func testCountdownBeatsPaceCueAndTheGapIsKept() {
        let run = SyntheticRun(segments: [SyntheticSegment(duration: 400, paceSecondsPerKm: 262)], seed: 5, noise: .clean)
        let (p, cueTime) = alignedSession(segment: { S.segment(.work, $0) }, run: run, heartRate: nil)
        var runner = SessionRunner(prescription: p)
        var spoken: [Announcement] = []
        for r in run.readings { spoken += runner.ingest(r) }
        let kinds = spoken.map(\.kind)
        XCTAssertEqual(kinds.prefix(4), [.segmentStart, .countdown, .cue, .countdown])
        let countdown = spoken[1], cue = spoken[2]
        XCTAssertEqual(countdown.time, cueTime, accuracy: 1e-9, "the countdown took the reading where both were due")
        XCTAssertEqual(cue.dueTime, cueTime, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(cue.time - countdown.time, runner.config.minimumGapSeconds - 1e-9)
        XCTAssertLessThanOrEqual(cue.waitedSeconds, runner.config.cueMaxDeferSeconds)
        XCTAssertEqual(cue.priority, .paceCue)
        XCTAssertLessThan(cue.priority, countdown.priority)
        // The deferred cue is the same decision the engine made.
        XCTAssertEqual(S.cues([cue])[0].decision.action, .speedUp)
        XCTAssertTrue(runner.droppedAnnouncements.isEmpty)
    }

    /// "Ease off" outranks a countdown due at the same reading; the countdown, which is only true for
    /// a moment, then expires behind the gap and is dropped (and logged).
    func testSafetyCueBeatsCountdownAndTheStaleCountdownIsDropped() {
        let run = SyntheticRun(segments: [SyntheticSegment(duration: 400, paceSecondsPerKm: S.repPace)], seed: 6, noise: .clean)
        let make: (Double) -> WorkoutSegment = { S.segment(.work, $0, ceiling: 150, hrPrimary: true) }
        let (p, cueTime) = alignedSession(segment: make, run: run, heartRate: 170)
        var runner = SessionRunner(prescription: p)
        var spoken: [Announcement] = []
        for r in run.readings {
            var x = r
            x.heartRate = 170
            spoken += runner.ingest(x)
        }
        XCTAssertEqual(spoken.prefix(3).map(\.kind), [.segmentStart, .cue, .countdown])
        let cue = spoken[1]
        XCTAssertEqual(cue.time, cueTime, accuracy: 1e-9)
        XCTAssertEqual(cue.priority, .safetyCue)
        XCTAssertEqual(S.cues([cue])[0].decision.action, .easeOff)
        // The 30 s countdown is not spoken late: only the 10 s one is.
        XCTAssertEqual(S.countdowns(spoken).map(\.countdown.secondsLeft), [10])
        XCTAssertEqual(runner.droppedAnnouncements.map(\.kind), [.countdown])
        XCTAssertEqual(S.countdowns(runner.droppedAnnouncements).first?.countdown.secondsLeft, 30)
    }

    func testPrioritiesAreOrdered() {
        XCTAssertLessThan(AnnouncementPriority.info, .paceCue)
        XCTAssertLessThan(AnnouncementPriority.paceCue, .countdown)
        XCTAssertLessThan(AnnouncementPriority.countdown, .safetyCue)
        XCTAssertLessThan(AnnouncementPriority.safetyCue, .transition)
    }

    /// Whatever the noise does, two spoken announcements at different readings are at least the
    /// minimum gap apart, except a segment start or the end, which are heard at once.
    func testMinimumGapHoldsAcrossNoisyReplays() {
        let p = S.repSession()
        for seed in UInt64(10)...13 {
            let run = S.run(for: p, seed: seed, noise: noise, repPaces: [1: 250, 4: 205])
            let replay = SessionReplay(run: run, prescription: p, heartRate: S.heartRate)
            let a = replay.announcements
            for (x, y) in zip(a, a.dropFirst()) where y.time != x.time && y.priority != .transition {
                XCTAssertGreaterThanOrEqual(y.time - x.time, SessionRunnerConfig().minimumGapSeconds - 1e-9,
                                            "seed \(seed): \(x.kind) at \(x.time), \(y.kind) at \(y.time)")
            }
            XCTAssertTrue(a.allSatisfy { $0.time >= $0.dueTime })
            XCTAssertFalse(S.cues(a).isEmpty, "seed \(seed): the drifting reps are cued")
        }
    }

    // MARK: Overrun

    /// A runner who keeps going at rep pace through the jog: the jog still starts on time (a timed rep
    /// does not wait for a press), and after the last segment the workout is over: nothing more is said.
    func testSegmentsStartOnTimeAndNothingIsSaidAfterTheEnd() {
        let p = S.repSession(reps: 2)
        let long = SyntheticRun(segments: [SyntheticSegment(duration: p.durationSeconds + 120, paceSecondsPerKm: S.repPace)],
                                seed: 7, noise: .clean)
        let replay = SessionReplay(run: long, prescription: p)
        let t = startTimes(replay.announcements)
        let t0 = replay.steps[0].reading.time
        XCTAssertEqual(t[2]! - t0, 300 + 180, accuracy: 1.5, "the jog starts when the rep's time is up")
        XCTAssertEqual(S.ends(replay.announcements).count, 1)
        let endIndex = replay.steps.lastIndex { !$0.announcements.isEmpty }!
        XCTAssertEqual(replay.steps[endIndex].announcements.map(\.kind), [.sessionEnd])
        XCTAssertLessThan(endIndex, replay.steps.count - 60, "the extra 120 s of running produced nothing")
        XCTAssertEqual(replay.runner.phase, .finished(.completed))
        XCTAssertNil(replay.runner.activeSegmentIndex)
    }
}
