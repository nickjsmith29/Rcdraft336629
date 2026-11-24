import Foundation
import XCTest
@testable import CoachCore

// Synthetic runs only (SPEC.md 3.6, F7 part 1): hand-built 1 Hz streams with
// invented paces and grades; they stand for no real runner.
final class RecordedGAPTests: XCTestCase {
    /// One stretch of a built run: seconds, raw pace (s/km) and true grade.
    private typealias Leg = (seconds: Int, pace: Double, grade: Double)

    /// A 1 Hz run through `legs`. Altitude is the true profile plus Gaussian
    /// noise of `altitudeNoise` metres (seeded, so the test is repeatable).
    private func activity(_ legs: [Leg], altitudeNoise: Double = 0, seed: UInt64 = 7,
                          edit: (inout StreamSample, Int) -> Void = { _, _ in }) -> Activity {
        var rng = SplitMix64(seed: seed)
        var samples: [StreamSample] = []
        var t = 0.0, d = 0.0, alt = 100.0
        for leg in legs {
            let v = 1000 / leg.pace
            for _ in 0..<leg.seconds {
                var s = StreamSample(t: t, speed: v, distance: d,
                                     altitude: alt + (altitudeNoise > 0 ? altitudeNoise * rng.gaussian() : 0))
                edit(&s, samples.count)
                samples.append(s)
                t += 1; d += v; alt += v * leg.grade
            }
        }
        return Activity(id: "gap-test", source: .healthKit, start: Date(timeIntervalSince1970: 0), durationSeconds: t,
                        distanceMeters: d, samples: samples)
    }

    /// A rolling run whose true flat-equivalent pace is `gap` throughout: each
    /// leg's raw pace is `gap * f(grade)` by the default curve (3.6).
    private func steadyEffort(gap: Double, noise: Double = 0, seed: UInt64 = 7,
                              edit: (inout StreamSample, Int) -> Void = { _, _ in }) -> Activity {
        let curve = DefaultGradePaceCurve()
        let grades: [Double] = [0, 0.05, -0.05, 0.08, 0, -0.08, 0.03, -0.03, 0.06, 0]
        return activity(grades.map { (240, gap * curve.factor(grade: $0), $0) }, altitudeNoise: noise, seed: seed, edit: edit)
    }

    // MARK: Worked values (computed by hand with python from SPEC 3.6, not by the code under test)

    func testWorkedValuesOnASteadyGrade() throws {
        // GAP pace = raw pace / f(grade): f(+5%) = 1.17374, f(+10%) = 1.50928, f(+3%) = 1.05544,
        // f(-4.5%) = 0.94 (the downhill line), f(-9%) = 0.88.
        let cases: [(pace: Double, grade: Double, expected: Double)] = [
            (360, 0.05, 306.7107),    // 6:00/km at +5%
            (300, 0.10, 198.7700),
            (300, 0.03, 284.2415),
            (330, -0.045, 351.0638),
            (300, -0.09, 340.9091),
        ]
        for c in cases {
            let a = activity([(600, c.pace, c.grade)])
            let gap = try XCTUnwrap(RecordedGAP.measure(a), "\(c)")
            XCTAssertEqual(gap.paceSecondsPerKm, c.expected, accuracy: 0.01, "\(c)")
            XCTAssertEqual(gap.rawPaceSecondsPerKm, c.pace, accuracy: 1e-6, "\(c)")
            XCTAssertEqual(gap.coverage, 1, accuracy: 1e-9)
            XCTAssertEqual(gap.coveredSeconds, 599, accuracy: 1e-9, "the last sample adds no time")
        }
    }

    func testClimbMakesGAPFasterAndDescentSlower() throws {
        let up = try XCTUnwrap(RecordedGAP.measure(activity([(600, 330, 0.06)])))
        let down = try XCTUnwrap(RecordedGAP.measure(activity([(600, 330, -0.06)])))
        XCTAssertLessThan(up.paceSecondsPerKm, up.rawPaceSecondsPerKm)
        XCTAssertGreaterThan(down.paceSecondsPerKm, down.rawPaceSecondsPerKm)
    }

    // MARK: Recovering a known effort

    func testSteadyEffortOnAKnownProfileRecoversTheGAP() throws {
        // The true flat-equivalent pace is 300 s/km on every leg. The grade is fitted over a 90 m
        // window, so a leg's first and last ~30 s blend two grades, and 0.4 m of altitude noise
        // moves a fitted grade by about a point. Heuristic tolerance: 2% (6 s/km). Both are
        // synthetic, so the figure only shows the smoothing error stays small against the
        // 10 to 50% pace swings the grades cause.
        for seed: UInt64 in [1, 2, 3] {
            let a = steadyEffort(gap: 300, noise: 0.4, seed: seed)
            let gap = try XCTUnwrap(RecordedGAP.measure(a), "seed \(seed)")
            XCTAssertEqual(gap.paceSecondsPerKm, 300, accuracy: 6, "seed \(seed)")
            XCTAssertGreaterThan(gap.coverage, 0.95)
            // The raw pace is clearly different, so the test is not passing by accident.
            XCTAssertGreaterThan(abs(gap.rawPaceSecondsPerKm - 300), 3)
        }
        // Noise-free, only the blending at the grade changes is left.
        let clean = try XCTUnwrap(RecordedGAP.measure(steadyEffort(gap: 300)))
        XCTAssertEqual(clean.paceSecondsPerKm, 300, accuracy: 4.5)
    }

    func testFlatRunGivesGAPEqualToRawPace() throws {
        let a = activity([(1200, 330, 0)], altitudeNoise: 0.4)
        let gap = try XCTUnwrap(RecordedGAP.measure(a))
        // Noise tilts the fitted grade a little either way; uphill under +2% costs nothing and
        // a downhill tilt costs under 1% (heuristic tolerance 1%).
        XCTAssertEqual(gap.paceSecondsPerKm, gap.rawPaceSecondsPerKm, accuracy: 3.3)
        XCTAssertEqual(gap.rawPaceSecondsPerKm, 330, accuracy: 1e-6)
        let exact = try XCTUnwrap(RecordedGAP.measure(activity([(600, 330, 0)])))
        XCTAssertEqual(exact.paceSecondsPerKm, 330, accuracy: 1e-9)
    }

    func testKeyWindowsAverageOnlyTheirOwnStretch() throws {
        // 10 min flat at 6:00, then 10 min at +5% at 5:00 raw (a 4:15 GAP).
        let a = activity([(600, 360, 0), (600, 300, 0.05)])
        let flat = try XCTUnwrap(RecordedGAP.measure(a, windows: [30...500]))
        XCTAssertEqual(flat.paceSecondsPerKm, 360, accuracy: 0.5)
        let hill = try XCTUnwrap(RecordedGAP.measure(a, windows: [700...1100]))
        XCTAssertEqual(hill.paceSecondsPerKm, 300 / 1.17374445895, accuracy: 0.3)
        XCTAssertEqual(hill.coveredSeconds, 400, accuracy: 1e-9)
        // A window past the end of the run has nothing to average.
        XCTAssertNil(RecordedGAP.measure(a, windows: [5000...6000]))
    }

    func testRawPaceMatchesRunMetricsTimeWeighting() throws {
        // On a hilly unplanned run RunMetrics withholds raw pace but keeps the key speed; the GAP's
        // raw pace over the same stretches is that speed's pace (the same time weighting).
        let curve = DefaultGradePaceCurve()
        let grades: [Double] = [0.06, -0.06, 0.06, -0.06, 0.06, -0.06, 0.06, -0.06]
        let a = activity(grades.map { (200, 300 * curve.factor(grade: $0), $0) })
        let m = RunMetrics.measure(CompletedRun(activity: a, plannedWorkoutID: nil, rpe: nil, isTreadmill: false), planned: nil)
        XCTAssertNotNil(m.paceNotComparableReason, "hilly")
        XCTAssertNil(m.paceSecondsPerKm)
        let gap = try XCTUnwrap(m.gradeAdjusted)
        let keySpeed = try XCTUnwrap(m.key?.speed)
        XCTAssertEqual(gap.rawPaceSecondsPerKm, 1000 / keySpeed, accuracy: 1e-6)
        XCTAssertEqual(gap.paceSecondsPerKm, 300, accuracy: 9)
    }

    // MARK: Missing and patchy altitude

    func testMissingAltitudeGivesNil() {
        let a = activity([(900, 330, 0.04)]) { s, _ in s.altitude = nil }
        XCTAssertNil(RecordedGAP.measure(a))
        XCTAssertNil(RecordedGAP.measure(Activity(id: "e", source: .healthKit, start: Date(), durationSeconds: 0)))
    }

    func testPatchyAltitudeBelowCoverageGivesNil() throws {
        // Altitude is missing for 150 s of every 300 s: half the run has no grade.
        let patchy = activity([(1800, 330, 0.04)]) { s, _ in if Int(s.t) % 300 >= 150 { s.altitude = nil } }
        XCTAssertNil(RecordedGAP.measure(patchy))
        // Lower the bar and the same run reports, with its true coverage.
        var lenient = RecordedGAPOptions()
        lenient.minimumCoverage = 0.3
        let gap = try XCTUnwrap(RecordedGAP.measure(patchy, options: lenient))
        XCTAssertLessThan(gap.coverage, RecordedGAPOptions().minimumCoverage)
        XCTAssertGreaterThan(gap.coverage, 0.3)
        // Single dropped readings are not a gap: every third altitude missing still covers the run.
        let sporadic = activity([(900, 330, 0.04)]) { s, _ in if Int(s.t) % 3 == 0 { s.altitude = nil } }
        XCTAssertEqual(try XCTUnwrap(RecordedGAP.measure(sporadic)).coverage, 1, accuracy: 0.02)
    }

    func testMissingDistanceIsIntegratedFromSpeed() throws {
        let with = try XCTUnwrap(RecordedGAP.measure(activity([(900, 330, 0.05)])))
        let without = try XCTUnwrap(RecordedGAP.measure(activity([(900, 330, 0.05)]) { s, _ in s.distance = nil }))
        XCTAssertEqual(without.paceSecondsPerKm, with.paceSecondsPerKm, accuracy: with.paceSecondsPerKm * 0.01)
        // No distance and no speed: nothing to adjust.
        XCTAssertNil(RecordedGAP.measure(activity([(900, 330, 0.05)]) { s, _ in s.distance = nil; s.speed = nil }))
    }

    func testPauseIsLeftOut() throws {
        let a = activity([(300, 330, 0.05), (300, 330, 0.05)]) { s, i in
            if (300..<420).contains(i) { s.isMoving = false; s.speed = 0 }
        }
        let gap = try XCTUnwrap(RecordedGAP.measure(a))
        XCTAssertEqual(gap.paceSecondsPerKm, 330 / 1.17374445895, accuracy: 0.3)
        XCTAssertLessThan(gap.coveredSeconds, 480 + 30 + 1, "the pause adds at most the 30 s hold")
    }

    // MARK: Bad values

    func testAltitudeSpikesAreFilteredOut() throws {
        let clean = try XCTUnwrap(RecordedGAP.measure(steadyEffort(gap: 300, noise: 0.4)))
        // A barometer glitch: every 37th altitude jumps 60 m up, every 53rd 80 m down.
        func spiked(_ s: inout StreamSample, _ i: Int) {
            if i % 37 == 5, let a = s.altitude { s.altitude = a + 60 }
            if i % 53 == 9, let a = s.altitude { s.altitude = a - 80 }
        }
        let filtered = try XCTUnwrap(RecordedGAP.measure(steadyEffort(gap: 300, noise: 0.4, edit: spiked)))
        XCTAssertEqual(filtered.paceSecondsPerKm, clean.paceSecondsPerKm, accuracy: 3)
        XCTAssertEqual(filtered.paceSecondsPerKm, 300, accuracy: 6)
        // With the filter switched off (a tolerance no spike exceeds) the spikes wreck the grade.
        var off = RecordedGAPOptions()
        off.spikeToleranceMeters = 1000
        let raw = try XCTUnwrap(RecordedGAP.measure(steadyEffort(gap: 300, noise: 0.4, edit: spiked), options: off))
        XCTAssertGreaterThan(abs(raw.paceSecondsPerKm - clean.paceSecondsPerKm), 3 * abs(filtered.paceSecondsPerKm - clean.paceSecondsPerKm))
    }

    func testNonFiniteAndNegativeValuesAreIgnored() throws {
        let clean = try XCTUnwrap(RecordedGAP.measure(steadyEffort(gap: 300)))
        let bad = steadyEffort(gap: 300) { s, i in
            switch i % 97 {
            case 3: s.speed = .nan
            case 11: s.speed = -4
            case 19: s.altitude = .infinity
            case 23: s.altitude = .nan
            case 29: s.distance = -50
            case 31: s.distance = .infinity
            case 37: s.speed = 0
            default: break
            }
        }
        let gap = try XCTUnwrap(RecordedGAP.measure(bad))
        XCTAssertTrue(gap.paceSecondsPerKm.isFinite && gap.paceSecondsPerKm > 0)
        XCTAssertEqual(gap.paceSecondsPerKm, clean.paceSecondsPerKm, accuracy: 6)
        XCTAssertGreaterThan(gap.coverage, 0.9)
        // A run of nothing usable is nil, never zero.
        let junk = activity([(600, 330, 0.04)]) { s, _ in s.speed = .nan; s.altitude = .nan }
        XCTAssertNil(RecordedGAP.measure(junk))
        XCTAssertNil(RecordedGAP.measure(activity([(600, 330, 0.04)]) { s, _ in s.speed = -3 }))
    }

    func testGradesPastFortyFivePercentAreClamped() throws {
        // A 100% climb (nonsense, as a glitchy track would give): the factor uses 45%, not 100%.
        let gap = try XCTUnwrap(RecordedGAP.measure(activity([(600, 600, 1.0)])))
        XCTAssertEqual(gap.paceSecondsPerKm, 600 / DefaultGradePaceCurve().factor(grade: 0.45), accuracy: 0.6)
        XCTAssertEqual(gap.paceSecondsPerKm, 600 / 5.09678, accuracy: 0.6, "5.0968 is f(0.45), worked by hand")
        // The shared fit clamps too, both ways.
        let cfg = GradeEstimatorConfig()
        let steepUp = (0..<30).map { (d: Double($0) * 3, a: Double($0) * 6) }
        let steepDown = (0..<30).map { (d: Double($0) * 3, a: -Double($0) * 6) }
        XCTAssertEqual(GradeEstimator.fitGrade(steepUp[...], config: cfg)?.grade ?? .nan, 0.45, accuracy: 1e-12)
        XCTAssertEqual(GradeEstimator.fitGrade(steepDown[...], config: cfg)?.grade ?? .nan, -0.45, accuracy: 1e-12)
    }

    // MARK: Shared with the live grade

    func testSharedFitMatchesTheLiveEstimator() throws {
        var live = GradeEstimator()
        var points: [(d: Double, a: Double)] = []
        var last: GradeEstimate?
        for i in 0..<40 {
            let d = Double(i) * 3, a = 0.06 * d + 0.3 * sin(Double(i))
            last = live.ingest(time: Double(i), distance: d, altitude: a)
            points.append((d, a))
        }
        // The estimator's window holds the last 90 m: the shared fit over those points gives its grade.
        let window = points.filter { $0.d >= (points.last!.d - 90) }
        let shared = try XCTUnwrap(GradeEstimator.fitGrade(window[...], config: GradeEstimatorConfig()))
        XCTAssertEqual(shared.grade, try XCTUnwrap(last).grade, accuracy: 1e-12)
        XCTAssertEqual(shared.span, try XCTUnwrap(last).spanMeters, accuracy: 1e-12)
        XCTAssertNil(GradeEstimator.fitGrade(window[0..<5], config: GradeEstimatorConfig()), "too few samples")
    }

    func testResultIsCodable() throws {
        let gap = try XCTUnwrap(RecordedGAP.measure(activity([(600, 330, 0.05)])))
        let back = try JSONDecoder().decode(RecordedGAP.self, from: JSONEncoder().encode(gap))
        XCTAssertEqual(back, gap)
    }
}
