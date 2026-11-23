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

    /// Feed a constant pace, grade and heart rate once per second from `from`
    /// to `to` (inclusive) and return every decision.
    @discardableResult
    static func drive(_ engine: inout CueEngine, from: Double, to: Double, pace: Double?, grade: Double? = 0,
                      heartRate: Double? = nil) -> [CueDecision] {
        var out: [CueDecision] = []
        var t = from
        while t <= to {
            out.append(engine.evaluate(time: t, pace: pace.map { estimate(pace: $0, time: t) },
                                       grade: grade.map { self.grade($0, time: t) }, heartRate: heartRate))
            t += 1
        }
        return out
    }
}
