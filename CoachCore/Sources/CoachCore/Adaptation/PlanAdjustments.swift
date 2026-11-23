import Foundation

// Edits the adaptation engine makes to single sessions (SPEC.md F4). Each one
// keeps the session's id and date so the app can replace it in place.

extension PlannedWorkout {
    /// Value used when a week loses days: the lowest is dropped first (F4,
    /// section 8 "missed day"). Heuristic order: race, long run, quality,
    /// easy, recovery, rest.
    var adaptationValue: Int {
        switch kind {
        case .race: return 5
        case .long: return 4
        case .quality: return 3
        case .easy: return 2
        case .recovery: return 1
        case .rest: return 0
        }
    }

    /// Hard days for the "never stack two quality days" rule.
    var isHardDay: Bool { kind.isQuality || kind == .race }

    /// This session with every pace target on segments of the given
    /// intensities multiplied by `factor` (seconds per km, so below 1 is
    /// faster). Nil when nothing changed.
    func scalingPaces(of intensities: Set<WorkoutIntensity>, by factor: Double) -> PlannedWorkout? {
        guard let p = prescription, factor.isFinite, factor > 0 else { return nil }
        var changed = false
        let segments = p.segments.map { s -> WorkoutSegment in
            guard intensities.contains(s.intensity), let pace = s.target.pace else { return s }
            changed = true
            let scaled = PaceTarget(fastestSecondsPerKm: pace.fastestSecondsPerKm * factor,
                                    slowestSecondsPerKm: pace.slowestSecondsPerKm * factor)
            return WorkoutSegment(role: s.role, intensity: s.intensity, durationSeconds: s.durationSeconds,
                                  target: WorkoutTarget(heartRate: s.target.heartRate, pace: scaled, primary: s.target.primary))
        }
        guard changed else { return nil }
        var copy = self
        copy.prescription = WorkoutPrescription(purpose: p.purpose, phase: p.phase, segments: segments, rules: p.rules,
                                                raceDistanceMeters: p.raceDistanceMeters)
        return copy
    }

    /// This session shortened (or lengthened) to `seconds`, the change taken
    /// from its easy main segments and the distance scaled with it. The
    /// prescription is dropped when its easy main segments can't absorb the change.
    func resized(toSeconds seconds: Double) -> PlannedWorkout {
        var copy = self
        let old = durationSeconds
        copy.durationSeconds = seconds
        if let d = distanceMeters, old > 0 { copy.distanceMeters = d * seconds / old }
        guard let p = prescription else { return copy }
        let delta = seconds - old
        let mains = p.segments.indices.filter { p.segments[$0].role == .main && p.segments[$0].intensity.isBelowAerobicThreshold }
        let mainTotal = mains.reduce(0) { $0 + p.segments[$1].durationSeconds }
        guard mainTotal > 0, mainTotal + delta >= 60 else { copy.prescription = nil; return copy }
        var segments = p.segments
        for i in mains {
            let s = segments[i]
            segments[i] = WorkoutSegment(role: s.role, intensity: s.intensity,
                                         durationSeconds: s.durationSeconds + delta * s.durationSeconds / mainTotal, target: s.target)
        }
        copy.prescription = WorkoutPrescription(purpose: p.purpose, phase: p.phase, segments: segments, rules: p.rules,
                                                raceDistanceMeters: p.raceDistanceMeters)
        return copy
    }

    /// This quality session as an easy run of the same id, date, duration and
    /// distance (see `swappedToEasy()`), with an easy prescription built from
    /// the session's own easy warm-up target so the watch still has a heart-rate cap.
    func swappedToEasyKeepingTarget(reason: String) -> PlannedWorkout {
        var easy = swappedToEasy()
        guard let p = prescription,
              let target = p.segments.first(where: { $0.intensity == .easy })?.target else { return easy }
        easy.prescription = WorkoutPrescription(
            purpose: "Easy run in place of the planned quality session: \(reason)",
            phase: p.phase,
            segments: [WorkoutSegment(role: .main, intensity: .easy, durationSeconds: durationSeconds, target: target)],
            rules: [.easyByHeartRate])
        return easy
    }
}
