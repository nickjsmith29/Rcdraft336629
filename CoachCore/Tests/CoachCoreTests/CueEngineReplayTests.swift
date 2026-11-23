import XCTest
@testable import CoachCore

/// True positives, missing altitude and the replay harness, on seeded synthetic runs.
final class CueEngineReplayTests: XCTestCase {
    private let mile = UnitFormatting.metersPerMile
    private let noise = SyntheticNoise.forCueTests

    /// Seconds per km for a pace given in seconds per mile.
    private func perKm(_ secondsPerMile: Double) -> Double { secondsPerMile * 1000 / mile }

    /// A flat run in the band for `driftStart` seconds, then `drift` s/mile
    /// outside the band's slow (or fast) edge for 60 s, then back in.
    private func driftRun(_ seed: UInt64, segment: WorkoutSegment, drift: Double, slower: Bool,
                          driftStart: Double = 120, lengthSeconds: Double = 60) -> SyntheticRun {
        let p = segment.target.pace!
        let inBand = (p.fastestSecondsPerKm + p.slowestSecondsPerKm) / 2
        let out = slower ? p.slowestSecondsPerKm + perKm(drift) : p.fastestSecondsPerKm - perKm(drift)
        return SyntheticRun(segments: [SyntheticSegment(duration: driftStart, paceSecondsPerKm: inBand),
                                       SyntheticSegment(duration: lengthSeconds, paceSecondsPerKm: out),
                                       SyntheticSegment(duration: 120, paceSecondsPerKm: inBand)],
                            seed: seed, noise: noise)
    }

    /// Share of drift runs (both directions) whose first cue after the drift starts is the right one
    /// and comes within `within` seconds of the drift's start; also the median delay.
    private func driftStats(_ drift: Double, within: Double, seeds: ClosedRange<UInt64>) -> (share: Double, median: Double, wrongWay: Int) {
        let seg = CueTestSupport.paceSegment()
        var hits = 0, n = 0, wrong = 0
        var delays: [Double] = []
        for slower in [true, false] {
            for seed in seeds {
                let replay = CueReplay(run: driftRun(seed, segment: seg, drift: drift, slower: slower), segment: seg)
                n += 1
                let right: CueAction = slower ? .speedUp : .slowDown
                if let first = replay.cues.first(where: { $0.truth.time >= 120 }), first.decision.action == right {
                    let delay = first.truth.time - 120
                    delays.append(delay)
                    if delay <= within { hits += 1 }
                }
                if replay.cues.contains(where: { $0.decision.action != right }) { wrong += 1 }
            }
        }
        delays.sort()
        return (Double(hits) / Double(n), delays.isEmpty ? .infinity : delays[delays.count / 2], wrong)
    }

    /// A 60 s drift outside the band is cued within the sustained window plus the pace
    /// estimate's lag, as often as the estimate's own noise allows. The simulated
    /// estimate error is about 2% rms (about 11 s/mile), so a 15 s/mile drift is near
    /// the noise floor: measured over 200 runs, 70% are cued within 40 s and 84% before
    /// the drift ends; 30 s/mile is cued within 40 s in 97%.
    func testDriftsOutsideTheBandAreCuedWithinTheSustainedWindowPlusLag() {
        let fifteen = driftStats(15, within: 40, seeds: 1...60)
        let thirty = driftStats(30, within: 40, seeds: 1...60)
        print(String(format: "CUE true positives, 120 runs each: 15 s/mile cued within 40 s in %.0f%%, median delay %.0f s; "
                     + "30 s/mile in %.0f%%, median %.0f s",
                     fifteen.share * 100, fifteen.median, thirty.share * 100, thirty.median))
        XCTAssertGreaterThanOrEqual(fifteen.share, 0.6)
        XCTAssertLessThanOrEqual(fifteen.median, 30)
        XCTAssertGreaterThanOrEqual(thirty.share, 0.93)
        XCTAssertLessThanOrEqual(thirty.median, 30)
        // Cues of any other kind stay rare: 22 of the 240 five-minute runs in the replay (the estimator's
        // first minute, before it has learned the watch scale, and its lag after the drift ends).
        XCTAssertLessThanOrEqual(fifteen.wrongWay + thirty.wrongWay, 29)
    }

    func testRightCueForBothDirections() {
        let seg = CueTestSupport.paceSegment()
        for (slower, expected) in [(true, CueAction.speedUp), (false, .slowDown)] {
            let replay = CueReplay(run: driftRun(7, segment: seg, drift: 40, slower: slower), segment: seg)
            XCTAssertEqual(replay.cues.first?.decision.action, expected)
            XCTAssertEqual(replay.cues.first?.decision.reason.rule, slower ? .sustainedTooSlow : .sustainedTooFast)
            XCTAssertLessThanOrEqual((replay.cues.first?.truth.time ?? .infinity) - 120, 25 + 10)
        }
    }

    func testHeartRateOverTheCeilingOnAnEasyRunGetsEaseOff() {
        let seg = CueTestSupport.easySegment(fastest: 360, slowest: 403, ceiling: 150)
        for seed in 1...30 as ClosedRange<UInt64> {
            let run = SyntheticRun(segments: [.init(duration: 300, paceSecondsPerKm: 380)], seed: seed, noise: noise)
            // Heart rate 135 bpm (plus a little jitter) until 120 s, then 158 bpm for 60 s, then back.
            let replay = CueReplay(run: run, segment: seg) { t in
                let base = t >= 120 && t < 180 ? 158.0 : 135.0
                return base + 2 * sin(t)
            }
            let first = replay.cues.first
            XCTAssertEqual(first?.decision.action, .easeOff, "seed \(seed)")
            XCTAssertEqual(first?.decision.reason.rule, .sustainedHeartRateOverCeiling)
            XCTAssertGreaterThanOrEqual(first?.truth.time ?? 0, 120 + 25 - 1)
            XCTAssertLessThanOrEqual(first?.truth.time ?? .infinity, 120 + 25 + 3)
            XCTAssertEqual(replay.cues.count, 1, "seed \(seed): one cue, the over-ceiling spell is only 60 s")
        }
    }

    func testNoCueInTheFirstSixtySecondsOfARepEvenWhenWayOff() {
        let seg = CueTestSupport.paceSegment()
        for seed in 1...30 as ClosedRange<UInt64> {
            let run = SyntheticRun(segments: [.init(duration: 200, paceSecondsPerKm: 450)], seed: seed, noise: noise)
            let replay = CueReplay(run: run, segment: seg)
            XCTAssertTrue(replay.cues.allSatisfy { $0.truth.time >= 60 }, "seed \(seed)")
            XCTAssertTrue(replay.steps.filter { $0.truth.time < 60 }.allSatisfy { $0.decision.reason.rule == .startupWindow })
        }
    }

    func testNoSpeedUpOnDescentsAndNoneOnHeartRatePrimaryRuns() {
        // A slow runner on a long descent and an easy-run segment: never "speed up".
        let seg = CueTestSupport.paceSegment()
        for seed in 1...20 as ClosedRange<UInt64> {
            let down = SyntheticRun(segments: [.init(duration: 300, paceSecondsPerKm: 400, grade: -0.05)], seed: seed, noise: noise)
            let r1 = CueReplay(run: down, segment: seg)
            XCTAssertFalse(r1.cues.contains { $0.decision.action == .speedUp }, "descent seed \(seed)")
            XCTAssertTrue(r1.steps.contains { $0.decision.reason.rule == .descentNoSpeedUp }, "descent seed \(seed)")
            let flatSlow = SyntheticRun(segments: [.init(duration: 300, paceSecondsPerKm: 520)], seed: seed, noise: noise)
            let r2 = CueReplay(run: flatSlow, segment: CueTestSupport.easySegment(fastest: 360, slowest: 403, ceiling: 150))
            XCTAssertFalse(r2.cues.contains { $0.decision.action == .speedUp }, "easy seed \(seed)")
            XCTAssertTrue(r2.steps.contains { $0.decision.reason.rule == .heartRatePrimaryNoSpeedUp })
        }
    }

    func testMissingAltitudeFallsBackToFlatTargetsAndSaysSo() {
        let seg = CueTestSupport.paceSegment()
        let run = SyntheticRun.holdingTarget(seg.target.pace!, stretches: [GradeStretch(seconds: 300, grade: 0.06)], seed: 4, noise: noise)
        var stripped = run
        stripped = SyntheticRun(segments: run.segments, seed: 4, noise: noise)
        // Same run with every altitude removed.
        var engine = CueEngine(segment: seg)
        var withAlt = CueEngine(segment: seg)
        var flat: [CueDecision] = [], hilly: [CueDecision] = []
        for r in stripped.readings {
            var noAlt = r
            noAlt.altitude = nil
            flat.append(engine.ingest(noAlt))
            hilly.append(withAlt.ingest(r))
        }
        XCTAssertTrue(flat.allSatisfy { $0.reason.usedFlatFallback && $0.reason.grade == nil && $0.reason.gradeFactor == 1 })
        // On a 6% climb with flat targets the runner looks slow: "speed up", flagged as flat.
        XCTAssertEqual(flat.first { $0.action != .none }?.action, .speedUp)
        XCTAssertEqual(flat.first { $0.action != .none }?.reason.usedFlatFallback, true)
        // With altitude the same run is on target once the grade has settled (a minute in).
        XCTAssertTrue(hilly.suffix(200).allSatisfy { !$0.reason.usedFlatFallback })
        XCTAssertTrue(hilly.filter { $0.action != .none }.isEmpty)
        XCTAssertEqual(hilly.last?.reason.grade ?? .nan, 0.06, accuracy: 0.015)
    }

    func testReplayHarnessScoring() {
        let seg = CueTestSupport.paceSegment()
        let run = SyntheticRun.holdingTarget(seg.target.pace!, bandPosition: 0.5,
                                             stretches: [GradeStretch(seconds: 120, grade: 0.05), GradeStretch(seconds: 120, grade: -0.05)],
                                             seed: 2, noise: .clean)
        let replay = CueReplay(run: run, segment: seg)
        XCTAssertTrue(replay.steps.allSatisfy { replay.trulyInBand($0.truth) })
        XCTAssertGreaterThan(replay.miles, 0.3)
        XCTAssertEqual(replay.falseCues(.speedUp), 0)
        XCTAssertEqual(replay.falseCuesPerMile(.slowDown), 0)
        // Judged against the flat band the same truth is out of it on the climb.
        let flatBand = CueReplay(run: run, segment: seg, curve: FlatCurve())
        XCTAssertTrue(flatBand.steps.contains { !flatBand.trulyInBand($0.truth) })
        XCTAssertFalse(CueReplay(run: SyntheticRun(segments: [], seed: 1), segment: seg).trulyInBand(SyntheticTruth(time: 0, speed: 0, distance: 0, grade: 0)))
        XCTAssertEqual(CueReplay(run: SyntheticRun(segments: [], seed: 1), segment: seg).falseCuesPerMile(.speedUp), 0)
    }

    private struct FlatCurve: GradePaceCurve { func factor(grade: Double) -> Double { 1 } }
}
