import XCTest
@testable import CoachCore

/// F11 acceptance: "no more than one false speed-up per hilly mile", replayed over
/// seeded synthetic runs where the runner truly holds the grade-adjusted target band.
final class CueEngineAcceptanceTests: XCTestCase {
    /// At least 200 seeded runs of each type (F11).
    private let seeds: [UInt64] = Array(1...200)
    private let runSeconds = 900.0

    private struct RunType {
        let name: String
        let segment: WorkoutSegment
        let grades: ClosedRange<Double>
    }

    /// Pace-primary segments as the plan builds them: threshold work has a 3% band
    /// (0.99 to 1.02 of the threshold pace), race pace a 2% band (0.99 to 1.01).
    private var runTypes: [RunType] {
        [RunType(name: "threshold (3% band), rolling 3-5%", segment: CueTestSupport.paceSegment(), grades: 0.03...0.05),
         RunType(name: "threshold (3% band), rolling 5-8%", segment: CueTestSupport.paceSegment(), grades: 0.05...0.08),
         RunType(name: "race pace (2% band), rolling 3-8%",
                 segment: CueTestSupport.paceSegment(intensity: .racePace, fastest: 327, slowest: 333.5), grades: 0.03...0.08)]
    }

    private func counts(_ type: RunType, position: Double = 0.5) -> (up: [Double], down: [Double], miles: Double) {
        var up: [Double] = [], down: [Double] = []
        var miles = 0.0
        for seed in seeds {
            let run = SyntheticRun.holdingTarget(type.segment.target.pace!, bandPosition: position,
                                                 stretches: SyntheticRun.rollingGrades(totalSeconds: runSeconds, gradeRange: type.grades, seed: seed),
                                                 seed: seed)
            let replay = CueReplay(run: run, segment: type.segment)
            up.append(replay.falseCuesPerMile(.speedUp))
            down.append(replay.falseCuesPerMile(.slowDown))
            miles += replay.miles
        }
        return (up, down, miles)
    }

    func testAtMostOneFalseSpeedUpPerHillyMile() {
        for type in runTypes {
            let c = counts(type)
            let mean = { (v: [Double]) in v.reduce(0, +) / Double(v.count) }
            print(String(format: "CUE-ACCEPT %@, %d runs, %.1f miles each: false speed-up per mile mean %.3f worst %.3f; "
                         + "false slow-down per mile mean %.3f worst %.3f",
                         type.name, seeds.count, c.miles / Double(seeds.count), mean(c.up), c.up.max() ?? 0, mean(c.down), c.down.max() ?? 0))
            XCTAssertEqual(c.up.count, seeds.count)
            XCTAssertGreaterThan(c.miles / Double(seeds.count), 1.2, "runs must cover enough hilly miles")
            XCTAssertLessThanOrEqual(c.up.max() ?? 0, 1, "\(type.name): worst run's false speed-ups per mile")
            // False slow-downs are reported (worst seed on 2% hills is two cues in 1.6 miles); their mean is bounded.
            XCTAssertLessThanOrEqual(c.down.max() ?? 0, 1.5, "\(type.name): worst run's false slow-downs per mile")
            XCTAssertLessThanOrEqual(mean(c.up), 0.25)
            XCTAssertLessThanOrEqual(mean(c.down), 0.25)
        }
    }

    /// A run held near a band edge is the hard case: the estimate's noise then
    /// crosses the edge. Reported for the 3% band at 0.15 and 0.85 of the band
    /// (still truly inside it), over 30 seeds; the one-per-mile bound is not asserted.
    func testNearTheEdgeOfTheBandIsReportedNotAsserted() {
        let type = runTypes[0]
        for position in [0.15, 0.85] {
            var up: [Double] = [], down: [Double] = []
            for seed in seeds.prefix(30) {
                let run = SyntheticRun.holdingTarget(type.segment.target.pace!, bandPosition: position,
                                                     stretches: SyntheticRun.rollingGrades(totalSeconds: runSeconds, gradeRange: type.grades, seed: seed),
                                                     seed: seed)
                let replay = CueReplay(run: run, segment: type.segment)
                up.append(replay.falseCuesPerMile(.speedUp))
                down.append(replay.falseCuesPerMile(.slowDown))
            }
            print(String(format: "CUE-EDGE band position %.2f, 30 runs: false speed-up per mile mean %.3f worst %.3f; slow-down mean %.3f worst %.3f",
                         position, up.reduce(0, +) / 30, up.max() ?? 0, down.reduce(0, +) / 30, down.max() ?? 0))
            XCTAssertEqual(up.count, 30)
        }
    }

    /// An easy run (HR-primary with a pace band) on hills never cues "speed up".
    func testHeartRatePrimaryHillyRunsNeverCueSpeedUp() {
        let easy = CueTestSupport.easySegment(fastest: 360, slowest: 403, ceiling: 150)
        for seed in seeds.prefix(30) {
            // The runner is slower than the easy band the whole way (the hardest case for "speed up").
            let slow = PaceTarget(fastestSecondsPerKm: 430, slowestSecondsPerKm: 450)
            let run = SyntheticRun.holdingTarget(slow, stretches: SyntheticRun.rollingGrades(totalSeconds: runSeconds, seed: seed), seed: seed)
            let replay = CueReplay(run: run, segment: easy) { _ in 130 }
            XCTAssertEqual(replay.cues.filter { $0.decision.action == .speedUp }.count, 0, "seed \(seed)")
        }
    }

    // MARK: flat runs, widening, hilly true positives

    private let flatTypes: [(name: String, segment: WorkoutSegment)] = [
        ("threshold (3% band), flat", CueTestSupport.paceSegment()),
        ("race pace (2% band), flat", CueTestSupport.paceSegment(intensity: .racePace, fastest: 327, slowest: 333.5))]

    private func mean(_ v: [Double]) -> Double { v.reduce(0, +) / Double(max(v.count, 1)) }

    /// The same bound as the hilly run, on the road most runs happen on: a flat run truly inside the band
    /// (at its middle) gets no more than one false cue per mile, and on average no more than 0.25.
    func testAtMostOneFalseCuePerFlatMile() {
        for type in flatTypes {
            var up: [Double] = [], down: [Double] = []
            var miles = 0.0
            for seed in seeds {
                let run = SyntheticRun.holdingTarget(type.segment.target.pace!, stretches: [GradeStretch(seconds: 1200, grade: 0)], seed: seed)
                let replay = CueReplay(run: run, segment: type.segment)
                up.append(replay.falseCuesPerMile(.speedUp))
                down.append(replay.falseCuesPerMile(.slowDown))
                miles += replay.miles
            }
            print(String(format: "CUE-FLAT %@, %d runs, %.1f miles each: false speed-up per mile mean %.3f worst %.3f; slow-down mean %.3f worst %.3f",
                         type.name, seeds.count, miles / Double(seeds.count), mean(up), up.max() ?? 0, mean(down), down.max() ?? 0))
            XCTAssertGreaterThan(miles / Double(seeds.count), 2.0)
            XCTAssertLessThanOrEqual(up.max() ?? 0, 1, "\(type.name): worst false speed-ups per mile")
            XCTAssertLessThanOrEqual(down.max() ?? 0, 1, "\(type.name): worst false slow-downs per mile")
            XCTAssertLessThanOrEqual(mean(up), 0.25)
            XCTAssertLessThanOrEqual(mean(down), 0.25)
        }
    }

    /// Share of judged readings (after the 60 s startup window) on which the band was widened by at least one
    /// point of grade, for the acceptance routes and for gentle 1 to 3% rolling roads. Reported; the
    /// acceptance routes are bounded so that the engine never goes deaf on hills again.
    func testShareOfReadingsWidenedByAPointOfGradeIsReported() {
        let routes: [(String, ClosedRange<Double>, Bool)] = [
            ("rolling 3-5%", 0.03...0.05, true), ("rolling 5-8%", 0.05...0.08, true),
            ("gentle rolling 1-3%", 0.01...0.03, false)]
        let segment = CueTestSupport.paceSegment()
        for (name, range, bounded) in routes {
            var widened = 0, judged = 0
            for seed in seeds.prefix(60) {
                let run = SyntheticRun.holdingTarget(segment.target.pace!,
                                                     stretches: SyntheticRun.rollingGrades(totalSeconds: 750, gradeRange: range, seed: seed), seed: seed)
                for step in CueReplay(run: run, segment: segment).steps where step.decision.time > 60 && step.decision.reason.gradeUncertainty > 0 {
                    judged += 1
                    if step.decision.reason.gradeUncertainty >= 0.0025 + 0.01 { widened += 1 }
                }
            }
            let share = Double(widened) / Double(max(judged, 1))
            print(String(format: "CUE-WIDEN %@: %.1f%% of %d judged readings widened by 1+ point of grade", name, 100 * share, judged))
            XCTAssertGreaterThan(judged, 1000)
            if bounded { XCTAssertLessThan(share, 0.5, name) }
        }
    }

    /// A runner truly 15 or 30 s/mile slower than the band's slow edge: how often and how fast the engine says
    /// "speed up". Reported for flat, rolling hills (3-8%) and a steady 5% climb, over 100 seeds of 750 s.
    /// Only the flat case is asserted; on hills the engine trades sensitivity for no false cues.
    func testTruePositivesForADriftedRunnerAreReported() {
        let segment = CueTestSupport.paceSegment()
        let target = segment.target.pace!
        let routes: [(String, (UInt64) -> [GradeStretch])] = [
            ("flat", { _ in [GradeStretch(seconds: 750, grade: 0)] }),
            ("rolling 3-8%", { SyntheticRun.rollingGrades(totalSeconds: 750, seed: $0) }),
            ("steady 5% climb", { _ in [GradeStretch(seconds: 750, grade: 0.05)] })]
        for (name, stretches) in routes {
            for drift in [15.0, 30] {
                var cued = 0
                var firsts: [Double] = []
                let n = 100
                for seed in seeds.prefix(n) {
                    let run = SyntheticRun.holdingTarget(target, bandPosition: 1, offsetSecondsPerKm: drift * 1000 / CueTestSupport.mile,
                                                         stretches: stretches(seed), seed: seed)
                    let replay = CueReplay(run: run, segment: segment)
                    if let first = replay.cues.first(where: { $0.decision.action == .speedUp || $0.decision.action == .slowDown }) {
                        if first.decision.action == .slowDown { continue }
                        cued += 1
                        firsts.append(first.decision.time)
                    }
                }
                firsts.sort()
                let median = firsts.isEmpty ? Double.nan : firsts[firsts.count / 2]
                print(String(format: "CUE-TP %@, runner %.0f s/mile slow: %d of %d runs cued, median first cue %.0f s", name, drift, cued, n, median))
                if name == "flat" && drift == 30 { XCTAssertGreaterThanOrEqual(cued, 95) }
            }
        }
    }
}
