import XCTest
@testable import CoachCore

/// Builders for the session runner tests. Synthetic values only: the paces
/// and heart rates are test numbers, not anyone's.
enum SessionTestSupport {
    /// True pace of a rep and its band (seconds per km): a 3.5% band around 225 s/km.
    static let repPace = 225.0
    static let repBand = (fast: 221.0, slow: 229.0)
    static let jogPace = 330.0
    static let easyPace = 380.0

    static func segment(_ role: WorkoutSegment.Role, _ seconds: Double, intensity: WorkoutIntensity? = nil,
                        fast: Double? = nil, slow: Double? = nil, ceiling: Double? = nil, floor: Double? = nil,
                        hrPrimary: Bool = false) -> WorkoutSegment {
        let defaults: (WorkoutIntensity, Double, Double) = {
            switch role {
            case .work: return (.vo2max, repBand.fast, repBand.slow)
            case .jog: return (.repRecovery, 290, 370)
            case .finish: return (.steady, 340, 360)
            case .warmUp, .coolDown, .main: return (.easy, 350, 410)
            }
        }()
        let pace = (fast ?? defaults.1) > 0
            ? PaceTarget(fastestSecondsPerKm: fast ?? defaults.1, slowestSecondsPerKm: slow ?? defaults.2) : nil
        let easy = (intensity ?? defaults.0).isBelowAerobicThreshold
        return WorkoutSegment(
            role: role, intensity: intensity ?? defaults.0, durationSeconds: seconds,
            target: WorkoutTarget(heartRate: HeartRateTarget(zones: .z1 ... .z2, floorBPM: floor, ceilingBPM: ceiling),
                                  pace: pace, primary: hrPrimary || easy ? .heartRate : .pace))
    }

    static func prescription(_ segments: [WorkoutSegment]) -> WorkoutPrescription {
        WorkoutPrescription(purpose: "test", phase: .build, segments: segments, rules: [])
    }

    /// Warm-up, `reps` x (rep, jog), cool-down.
    static func repSession(reps: Int = 6, rep: Double = 180, jog: Double = 90, warmUp: Double = 300,
                           coolDown: Double = 300) -> WorkoutPrescription {
        var s = [segment(.warmUp, warmUp)]
        for i in 0..<reps {
            s.append(segment(.work, rep))
            if i < reps - 1 { s.append(segment(.jog, jog)) }
        }
        s.append(segment(.coolDown, coolDown))
        return prescription(s)
    }

    /// The synthetic run that follows a prescription at the given true paces per role
    /// (seconds per km); `repPaces[n]` overrides the n-th work segment's pace.
    static func run(for p: WorkoutPrescription, seed: UInt64, noise: SyntheticNoise,
                    repPaces: [Int: Double] = [:]) -> SyntheticRun {
        var rep = 0
        let segs: [SyntheticSegment] = p.segments.map { s in
            switch s.role {
            case .work:
                defer { rep += 1 }
                return SyntheticSegment(duration: s.durationSeconds, paceSecondsPerKm: repPaces[rep] ?? repPace)
            case .jog: return SyntheticSegment(duration: s.durationSeconds, paceSecondsPerKm: jogPace)
            default: return SyntheticSegment(duration: s.durationSeconds, paceSecondsPerKm: easyPace)
            }
        }
        // Three extra seconds at the end: jittered readings may stop just short of the planned end.
        var all = segs
        if let last = all.popLast() { all.append(SyntheticSegment(duration: last.duration + 3, paceSecondsPerKm: last.paceSecondsPerKm)) }
        return SyntheticRun(segments: all, seed: seed, noise: noise)
    }

    /// A made-up heart rate that climbs steadily with the run (bpm).
    static func heartRate(_ t: Double) -> Double? { 140 + 0.02 * t }

    static func starts(_ a: [Announcement]) -> [SegmentStart] {
        a.compactMap { if case .segmentStart(let s) = $0.content { return s } else { return nil } }
    }
    static func countdowns(_ a: [Announcement]) -> [(time: Double, countdown: Countdown)] {
        a.compactMap { if case .countdown(let c) = $0.content { return ($0.time, c) } else { return nil } }
    }
    static func cues(_ a: [Announcement]) -> [(time: Double, decision: CueDecision)] {
        a.compactMap { if case .cue(let d) = $0.content { return ($0.time, d) } else { return nil } }
    }
    static func splits(_ a: [Announcement]) -> [RepSplit] {
        a.compactMap { if case .repSplit(let s) = $0.content { return s } else { return nil } }
    }
    static func summaries(_ a: [Announcement]) -> [IntervalSummary] {
        a.compactMap { if case .intervalSummary(let s) = $0.content { return s } else { return nil } }
    }
    static func ends(_ a: [Announcement]) -> [SessionEnd] {
        a.compactMap { if case .sessionEnd(let s) = $0.content { return s } else { return nil } }
    }
}
