import XCTest
@testable import CoachCore

/// F11 acceptance: "the cue engine's pace estimate tracks lap-average pace
/// within 5 sec/mile", replayed on seeded synthetic runs (SPEC.md section 7).
final class PaceReplayAcceptanceTests: XCTestCase {
    private let mile = UnitFormatting.metersPerMile
    private let seeds: [UInt64] = Array(1...8)

    private let runTypes: [(name: String, make: (UInt64) -> SyntheticRun)] = [
        ("easy steady", { .steady(secondsPerMile: 560, minutes: 45, seed: $0) }),
        ("progression", { .progression(startSecondsPerMile: 580, stepSeconds: 30, steps: 4, blockMinutes: 10, seed: $0) }),
        ("mile repeats", { .repeats(warmupMinutes: 12, reps: 4, repSecondsPerMile: 400, repSeconds: 400,
                                    jogSecondsPerMile: 600, jogSeconds: 180, easySecondsPerMile: 540,
                                    cooldownMinutes: 8, seed: $0) }),
        ("hilly with dropouts", { .hilly(basePaceSecondsPerMile: 540, hillSeconds: 150, hills: 14, grade: 0.05, seed: $0) }),
    ]

    func testEveryFullMileLapIsWithinFiveSecondsPerMile() {
        for type in runTypes {
            var worst = 0.0
            var instantaneous: [Double] = []
            var laps = 0
            for seed in seeds {
                let replay = PaceReplay(run: type.make(seed))
                XCTAssertFalse(replay.trueLapPaces.isEmpty, "\(type.name) seed \(seed) has no full mile")
                for (i, error) in replay.lapErrors.enumerated() {
                    XCTAssertLessThanOrEqual(error, 5, "\(type.name) seed \(seed) lap \(i + 1)")
                    laps += 1
                }
                worst = max(worst, replay.lapErrors.max() ?? 0)
                instantaneous += replay.instantaneousErrors()
            }
            XCTAssertGreaterThanOrEqual(seeds.count, 5)
            let p95 = PaceReplay.percentile(instantaneous, 0.95) ?? .nan
            print(String(format: "PACE-REPLAY %@: %d laps, worst lap error %.2f s/mile, 95th percentile instantaneous error %.1f s/mile",
                         type.name, laps, worst, p95))
        }
    }

    /// Heuristic (not a spec number): after a step change in true pace, the
    /// estimate gets within 5 s/mile of the new pace within 15 s, as long as
    /// GPS is present. With GPS dropouts the watch speed and cadence carry the
    /// estimate, whose noise and bias are larger, so this is not asserted
    /// there (see the PR notes for the measured trade-off).
    func testStepChangeIsFollowedWithinFifteenSecondsWhenGPSIsPresent() {
        var noise = SyntheticNoise()
        noise.dropoutProbability = 0
        noise.spikeProbability = 0
        for seed in 1...10 as ClosedRange<UInt64> {
            for (from, to) in [(560.0, 400.0), (400.0, 600.0), (540.0, 480.0)] {
                let run = SyntheticRun(segments: [.atMilePace(from, duration: 600), .atMilePace(to, duration: 120)],
                                       seed: seed, noise: noise)
                let replay = PaceReplay(run: run)
                let reached = replay.samples.first { s in
                    guard s.time >= 600, let e = s.estimate else { return false }
                    return abs(mile / e.speed - to) <= 5
                }
                XCTAssertNotNil(reached, "seed \(seed) \(from) to \(to) never got within 5 s/mile")
                XCTAssertLessThanOrEqual((reached?.time ?? .infinity) - 600, 15, "seed \(seed) \(from) to \(to)")
            }
        }
    }

    func testPercentileHelper() {
        XCTAssertNil(PaceReplay.percentile([], 0.95))
        XCTAssertEqual(PaceReplay.percentile([1, 2, 3, 4], 0.5), 2)
        XCTAssertEqual(PaceReplay.percentile([1, 2, 3, 4], 1), 4)
        XCTAssertEqual(PaceReplay.percentile([3, 1, 2], 0), 1)
        XCTAssertEqual(PaceReplay.percentile([5], 0.95), 5)
    }
}
