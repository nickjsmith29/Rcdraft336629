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
            XCTAssertLessThanOrEqual(c.down.max() ?? 0, 1, "\(type.name): worst run's false slow-downs per mile")
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
}
