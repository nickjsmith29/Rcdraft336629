import Foundation

/// Time-weighted stream means over a stretch of a run's moving time.
public struct StreamMeans: Equatable, Sendable, Codable {
    /// Moving seconds the stretch covers.
    public let seconds: Double
    /// Each mean is nil when under `RunMetrics.minimumCoverage` of the stretch has a usable reading.
    public let heartRate: Double?
    /// Meters per second.
    public let speed: Double?
    public let power: Double?
    public let cadence: Double?
}

/// The numbers the adaptation engine reads from one completed run (SPEC.md F4,
/// section 8 `metrics(run)`). Every value comes from the run's own streams;
/// a value that can't be measured is nil, never guessed.
///
/// Not yet measured: weather (F8). Raw pace on a hilly route (climb of
/// `AdaptationLimits.hillyClimbMetersPerKm` or more) or a treadmill is
/// reported as not comparable with the plan's targets. On a hilly route the
/// grade-adjusted pace (`gradeAdjusted`, F7 part 1) is measured beside it for
/// the debrief; no training or progression rule reads it yet (the plan
/// engine, decoupling and the fitness anchor stay on raw, flat data).
public struct RunMetrics: Equatable, Sendable {
    public let activityID: String
    public let movingSeconds: Double
    /// Planned duration of the matched session, when there is one.
    public let plannedSeconds: Double?
    /// The session's key part: its work or main segments, with the first
    /// minute (quality) or first five minutes (easy) of each skipped because
    /// heart rate lags effort. Nil when the run did not reach that part.
    public let key: StreamMeans?
    /// Moving seconds of the key part that the plan asked for.
    public let plannedKeySeconds: Double?
    /// Pace over the key part in seconds per km, or nil without speed or when
    /// pace is not comparable (see `paceNotComparableReason`).
    public let paceSecondsPerKm: Double?
    /// Why pace is not compared with the target, or nil when it is.
    public let paceNotComparableReason: String?
    /// Metres climbed per km (2 m hysteresis), nil without altitude and distance.
    public let climbMetersPerKm: Double?
    /// Grade-adjusted pace over the key part (same scope and time weighting as
    /// `paceSecondsPerKm`), measured only on a hilly, non-treadmill run, and
    /// nil when altitude is missing or too patchy (`RecordedGAP`).
    public let gradeAdjusted: RecordedGAP?
    /// Pace-to-HR decoupling, kept only for a steady run (3.3).
    public let decoupling: DecouplingResult?
    /// Power-to-HR decoupling, kept only for a steady run (3.3).
    public let powerDecoupling: DecouplingResult?
    /// Percent drop of mean cadence in the final third of moving time against
    /// the first third; negative when cadence rose. Nil without enough cadence.
    public let cadenceFadePercent: Double?
    /// RPE 1 to 10, when given.
    public let rpe: Int?

    /// Heuristic: a mean needs a usable reading over at least this share of its stretch.
    public static let minimumCoverage = 0.8
    /// Heuristic: heart rate in this range is plausible; outside it is a sensor error.
    public static let plausibleHeartRate: ClosedRange<Double> = 30...250

    /// Measures `activity` against `planned` (nil for an unplanned run).
    /// `units` sets only how the climb reads in `paceNotComparableReason`.
    public static func measure(_ run: CompletedRun, planned: PlannedWorkout?,
                               limits: AdaptationLimits = .default, units: UnitPreference = .metric) -> RunMetrics {
        let activity = run.activity
        let timeline = MovingTime.held(activity.samples, streams: [
            .heartRate: { plausibleHeartRate.contains($0) },
            .speed: { $0 > 0 },
            .power: { $0 > 0 },
            .cadence: { $0 > 0 },
        ], maximumHoldSeconds: MovingTime.defaultMaximumHoldSeconds)
        let moving = timeline.last?.end ?? 0

        let windows = keyWindows(planned)
        var key: StreamMeans?
        var plannedKey: Double?
        var keyRanges: [ClosedRange<Double>] = []
        if let windows {
            plannedKey = windows.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
            let clipped = windows.compactMap { w -> ClosedRange<Double>? in
                let hi = min(w.upperBound, moving)
                return hi > w.lowerBound ? w.lowerBound...hi : nil
            }
            key = clipped.isEmpty ? nil : means(timeline, clipped)
            keyRanges = clipped
        } else {
            // No prescription: the whole run after the warm-up.
            let warm = min(DecouplingOptions.default.warmUpSeconds, moving / 4)
            key = moving > warm ? means(timeline, [warm...moving]) : nil
            if moving > warm { keyRanges = [warm...moving] }
        }

        let climb = climbPerKm(activity)
        var reason: String?
        if run.isTreadmill {
            reason = "treadmill run: pace is not compared until the treadmill offset is learned (SPEC 3.8, F8)"
        } else if let c = climb, c >= limits.hillyClimbMetersPerKm {
            let climb = units == .metric ? String(format: "%.0f m climb per km", c) : "\(UnitFormatting.climb(c, units)) of climb"
            reason = "hilly route (\(climb)): raw pace is not compared until grade-adjusted pace exists (SPEC 3.6, F7)"
        }
        let pace = reason == nil ? key?.speed.map { 1000 / $0 } : nil
        // Grade-adjusted pace only where raw pace is withheld for hills.
        let gap = !run.isTreadmill && reason != nil && !keyRanges.isEmpty
            ? RecordedGAP.measure(activity, windows: keyRanges) : nil

        func steady(_ basis: DecouplingBasis) -> DecouplingResult? {
            guard case .success(let r) = Decoupling.compute(activity.samples, basis: basis), r.isSteady == true else { return nil }
            return r
        }

        var fade: Double?
        if moving > 0 {
            let first = means(timeline, [0...(moving / 3)]).cadence
            let last = means(timeline, [(2 * moving / 3)...moving]).cadence
            if let f = first, let l = last, f > 0 { fade = (f - l) / f * 100 }
        }

        return RunMetrics(activityID: activity.id, movingSeconds: moving, plannedSeconds: planned?.durationSeconds,
                          key: key, plannedKeySeconds: plannedKey, paceSecondsPerKm: pace,
                          paceNotComparableReason: key?.speed == nil ? nil : reason, climbMetersPerKm: climb,
                          gradeAdjusted: key?.speed == nil ? nil : gap,
                          decoupling: steady(.pace), powerDecoupling: steady(.power), cadenceFadePercent: fade,
                          rpe: run.rpe.flatMap { CompletedRun.validRPE.contains($0) ? $0 : nil })
    }

    /// The key segments of a planned session on the moving clock, each with
    /// the heart-rate lag skipped. Nil when the session has no prescription.
    static func keyWindows(_ planned: PlannedWorkout?) -> [ClosedRange<Double>]? {
        guard let p = planned?.prescription, let intensity = keyIntensity(p) else { return nil }
        var t = 0.0
        var out: [ClosedRange<Double>] = []
        for s in p.segments {
            defer { t += max(0, s.durationSeconds) }
            guard s.intensity == intensity, isKeyRole(s.role, intensity: intensity), s.durationSeconds > 0 else { continue }
            let lag = intensity.isBelowAerobicThreshold ? min(300, s.durationSeconds / 4) : min(60, s.durationSeconds / 4)
            out.append((t + lag)...(t + s.durationSeconds))
        }
        return out.isEmpty ? nil : out
    }

    /// The intensity a session is judged at: its hardest work or main segment.
    static func keyIntensity(_ p: WorkoutPrescription) -> WorkoutIntensity? {
        let order: [WorkoutIntensity] = [.race, .vo2max, .threshold, .racePace, .steady, .easy, .recovery]
        let present = Set(p.segments.filter { isKeyRole($0.role, intensity: $0.intensity) }.map(\.intensity))
        return order.first { present.contains($0) }
    }

    static func isKeyRole(_ role: WorkoutSegment.Role, intensity: WorkoutIntensity) -> Bool {
        switch role {
        case .main, .work: return true
        case .finish, .warmUp, .coolDown, .jog: return false
        }
    }

    static func means(_ timeline: [MovingTime.HeldInterval], _ windows: [ClosedRange<Double>]) -> StreamMeans {
        let total = windows.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        var sum: [StreamKind: Double] = [:], covered: [StreamKind: Double] = [:]
        for iv in timeline {
            for w in windows {
                let overlap = min(iv.end, w.upperBound) - max(iv.start, w.lowerBound)
                guard overlap > 0 else { continue }
                for (kind, v) in iv.values {
                    sum[kind, default: 0] += v * overlap
                    covered[kind, default: 0] += overlap
                }
            }
        }
        func mean(_ k: StreamKind) -> Double? {
            guard total > 0, let c = covered[k], c >= minimumCoverage * total, let s = sum[k] else { return nil }
            return s / c
        }
        return StreamMeans(seconds: total, heartRate: mean(.heartRate), speed: mean(.speed),
                           power: mean(.power), cadence: mean(.cadence))
    }

    /// Metres climbed per km, counting a rise only once altitude is 2 m above
    /// the last low point (heuristic hysteresis against altimeter noise).
    static func climbPerKm(_ activity: Activity) -> Double? {
        let samples = MovingTime.ordered(activity.samples).filter(\.isMoving)
        let altitudes = samples.compactMap { StreamKind.altitude.value(in: $0) }
        guard altitudes.count >= 2 else { return nil }
        let meters = activity.distanceMeters ?? samples.compactMap { StreamKind.distance.value(in: $0) }.max()
        guard let m = meters, m.isFinite, m >= 100 else { return nil }
        var climb = 0.0
        var anchor = altitudes[0]
        for a in altitudes.dropFirst() {
            if a < anchor { anchor = a } else if a - anchor >= 2 { climb += a - anchor; anchor = a }
        }
        return climb / (m / 1000)
    }
}
