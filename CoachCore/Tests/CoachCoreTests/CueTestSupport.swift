import XCTest
@testable import CoachCore

/// Shared builders for the cue engine tests. Synthetic values only: the paces
/// and heart rates here are test numbers, not anyone's.
enum CueTestSupport {
    static let mile = UnitFormatting.metersPerMile

    /// A pace-primary segment, like the plan's threshold work (a 3% band).
    static func paceSegment(role: WorkoutSegment.Role = .work, intensity: WorkoutIntensity = .threshold,
                            fastest: Double = 327, slowest: Double = 337, ceiling: Double? = nil,
                            duration: Double = 3600) -> WorkoutSegment {
        WorkoutSegment(role: role, intensity: intensity, durationSeconds: duration,
                       target: WorkoutTarget(heartRate: HeartRateTarget(zones: .z4 ... .z5a, floorBPM: nil, ceilingBPM: ceiling),
                                             pace: PaceTarget(fastestSecondsPerKm: fastest, slowestSecondsPerKm: slowest),
                                             primary: .pace))
    }

    /// An easy segment: heart-rate primary with a pace band and an HR ceiling.
    static func easySegment(fastest: Double = 360, slowest: Double = 403, ceiling: Double? = 150,
                            intensity: WorkoutIntensity = .easy, duration: Double = 3600) -> WorkoutSegment {
        WorkoutSegment(role: .main, intensity: intensity, durationSeconds: duration,
                       target: WorkoutTarget(heartRate: HeartRateTarget(zones: .z1 ... .z2, floorBPM: nil, ceilingBPM: ceiling),
                                             pace: PaceTarget(fastestSecondsPerKm: fastest, slowestSecondsPerKm: slowest),
                                             primary: .heartRate))
    }

    /// A smoothed pace estimate at `pace` seconds per km, as of `time`.
    static func estimate(pace: Double, time: Double, sigma: Double = 0.05) -> PaceEstimate {
        PaceEstimate(time: time, speed: 1000 / pace, speedSigma: sigma, stoppedSpeed: 0.5)
    }

    static func grade(_ g: Double, time: Double) -> GradeEstimate {
        GradeEstimate(time: time, grade: g, spanMeters: 90)
    }

    /// Feed a constant pace, grade and heart rate every `step` seconds from `from` to `to`
    /// (inclusive) and return every decision. With `heartRateEvery` of n, the heart rate is given
    /// only on every n-th reading (a watch reports it sparsely); the others get nil.
    @discardableResult
    static func drive(_ engine: inout CueEngine, from: Double, to: Double, pace: Double?, grade: Double? = 0,
                      heartRate: Double? = nil, step: Double = 1, heartRateEvery: Int = 1) -> [CueDecision] {
        var out: [CueDecision] = []
        var t = from
        var i = 0
        while t <= to {
            let hr = i % heartRateEvery == 0 ? heartRate : nil
            out.append(engine.evaluate(time: t, pace: pace.map { estimate(pace: $0, time: t) },
                                       grade: grade.map { self.grade($0, time: t) }, heartRate: hr))
            t += step
            i += 1
        }
        return out
    }
}
