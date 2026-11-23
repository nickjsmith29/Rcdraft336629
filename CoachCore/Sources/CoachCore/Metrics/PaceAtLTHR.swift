import Foundation

/// One steady stretch at LTHR that counted toward the pace (SPEC.md 3.9).
public struct LTHRStretch: Equatable, Sendable {
    public let activityID: String
    /// Wall-clock start of the stretch's used time (after the settling period).
    public let start: Date
    /// In-band moving seconds used (bridged excursions left out).
    public let seconds: Double
    /// Meters covered in those seconds.
    public let meters: Double
    /// Time-weighted mean heart rate over those seconds, in bpm.
    public let averageHeartRate: Double
    /// Mean pace of the stretch, seconds per meter.
    public var secondsPerMeter: Double { seconds / meters }
    /// Change in mean heart rate from the first half to the second, as a
    /// fraction of the first (positive: heart rate rose).
    public let heartRateDrift: Double
    /// Change in mean pace (seconds per meter) from the first half to the
    /// second, as a fraction of the first (positive: the runner slowed).
    public let paceDrift: Double
    /// Steepest grade window, up or down, as a positive fraction.
    public let maximumAbsoluteGrade: Double
}

/// Why a stretch that held LTHR past the settling period didn't count.
public enum LTHRStretchRejection: Error, Equatable, Sendable {
    /// Under `PaceAtLTHROptions.minimumSeconds` of in-band time after settling.
    case tooShort(seconds: Double)
    /// Under `minimumInBandShare` of the used time was in the band.
    case tooMuchTimeOutOfBand(share: Double)
    /// Some in-band time had no altitude reading, so flatness can't be checked.
    case noElevation
    /// A grade window was steeper than `maximumGrade` (the steepest, as a positive fraction).
    case hilly(maximumAbsoluteGrade: Double)
    /// Mean heart rate changed by more than `maximumHeartRateDrift` between halves.
    case heartRateDrift(fraction: Double)
    /// Mean pace changed by more than `maximumPaceDrift` between halves.
    case paceDrift(fraction: Double)
    /// Speed varied more than `maximumSpeedCV`.
    case unsteadyPace(coefficientOfVariation: Double)
}

public struct RejectedLTHRStretch: Equatable, Sendable {
    public let activityID: String
    /// Wall-clock start of the stretch (before the settling period).
    public let start: Date
    public let reason: LTHRStretchRejection
}

/// What the scan looked at, so the app can explain a missing or thin result.
public struct LTHRPaceScan: Equatable, Sendable {
    /// Runs inside the lookback window that were scanned (treadmill runs excluded).
    public let runsScanned: Int
    /// Treadmill runs inside the window, left out because their pace comes
    /// from the treadmill or a footpod rather than ground covered (SPEC.md 3.8).
    public let treadmillActivityIDs: [String]
    /// Stretches that held LTHR past the settling period but didn't count, in
    /// time order. Briefer touches of the band aren't listed.
    public let rejected: [RejectedLTHRStretch]
}

/// The runner's pace at LTHR with the stretches it came from (SPEC.md 3.9).
public struct PaceAtLTHR: Equatable, Sendable {
    /// The LTHR it was measured at, in bpm.
    public let lthr: Double
    /// Total seconds over total meters of every stretch used, so longer
    /// stretches weigh more.
    public let secondsPerMeter: Double
    /// Every stretch used, in time order.
    public let stretches: [LTHRStretch]
    public let scan: LTHRPaceScan

    public var totalSeconds: Double { stretches.reduce(0) { $0 + $1.seconds } }
    public var totalMeters: Double { stretches.reduce(0) { $0 + $1.meters } }
    /// Distinct runs the stretches came from.
    public var activityIDs: [String] {
        var seen = Set<String>()
        return stretches.map(\.activityID).filter { seen.insert($0).inserted }
    }
    /// From the first stretch's start to the last's.
    public var dateRange: ClosedRange<Date> {
        let dates = stretches.map(\.start)
        return dates.min()!...dates.max()!
    }
    /// Fastest to slowest stretch pace, seconds per meter: the spread of the evidence.
    public var paceSpread: ClosedRange<Double> {
        let paces = stretches.map(\.secondsPerMeter)
        return paces.min()!...paces.max()!
    }
    /// True when the stretches come from two or more runs. One run's stretch
    /// may reflect that day's conditions, so the app should say so.
    public var isCorroborated: Bool { activityIDs.count >= 2 }
}

/// Why no pace at LTHR was measured. CoachCore refuses rather than guesses.
public enum PaceAtLTHRRefusal: Error, Equatable, Sendable {
    /// LTHR is not finite or outside `LTHREstimator.plausibleHR`.
    case invalidLTHR
    /// An option is non-finite or out of range (`PaceAtLTHROptions.isValid`).
    case invalidOptions
    /// No stretch qualified; the scan says what was looked at and set aside.
    case noQualifyingStretch(LTHRPaceScan)
}

/// Measures the runner's pace at their own LTHR from steady stretches in
/// recent runs (SPEC.md 3.9 threshold method; LTHR from SPEC.md 3.2).
///
/// Heuristics, stated so they can be tuned (every number is in `PaceAtLTHROptions`):
/// - Only runs (not walks or other sports) from the lookback window count,
///   and never treadmill runs (`TreadmillTagger`, SPEC.md 3.8). The input is a
///   `CleanedHistory`, so duplicates are already gone.
/// - Streams are put on the moving clock with the `MovingTime` hold rule. A
///   pause ends a stretch, so a stop at a crossing never joins two stretches.
/// - A stretch is moving time with heart rate within the band around LTHR and
///   a usable speed, allowing brief excursions out of the band.
/// - The first `settleSeconds` of each stretch are skipped (heart-rate lag).
/// - What's left must be long enough, mostly in the band, flat (every sliding
///   grade window, measured from the altitude stream, within `maximumGrade`, since
///   grade-adjusted pace doesn't exist yet; a stretch shorter than one
///   `gradeWindowMeters` window uses its end-to-end grade instead), and
///   steady: mean heart rate and mean pace may not drift between its halves
///   beyond their limits, and speed must not vary beyond `maximumSpeedCV`. A
///   stretch failing any check is left out whole rather than trimmed.
/// - The pace is the stretches' total time over their total distance. No
///   correction is made for a stretch's mean heart rate sitting a little off
///   LTHR; the band keeps that small.
public enum PaceAtLTHRMeter {
    /// - Parameter history: the runner's history after `HistoryCleanup.clean`,
    ///   so a run imported twice (HealthKit and Strava) counts once.
    public static func measure(
        history: CleanedHistory,
        lthr: Double,
        asOf: Date,
        options: PaceAtLTHROptions = .default
    ) -> Result<PaceAtLTHR, PaceAtLTHRRefusal> {
        guard lthr.isFinite, LTHREstimator.plausibleHR.contains(lthr) else { return .failure(.invalidLTHR) }
        guard options.isValid else { return .failure(.invalidOptions) }
        let earliest = asOf.addingTimeInterval(-Double(options.lookbackDays) * 86_400)
        let window = history.activities
            .filter { $0.sport == .run && $0.start >= earliest && $0.start <= asOf }
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }
        let band = (lthr * (1 - options.heartRateBandFraction))...(lthr * (1 + options.heartRateBandFraction))

        var used: [LTHRStretch] = []
        var rejected: [RejectedLTHRStretch] = []
        var treadmill: [String] = []
        var scanned = 0
        for activity in window {
            if (history.treadmill[activity.id] ?? TreadmillTagger.tag(activity)).isTreadmill { treadmill.append(activity.id); continue }
            scanned += 1
            for candidate in stretches(in: activity, band: band, options: options) {
                switch evaluate(candidate, options: options) {
                case nil: continue
                case .success(let s)?:
                    used.append(LTHRStretch(activityID: activity.id, start: wallClock(activity, candidate, options.settleSeconds),
                                            seconds: s.seconds, meters: s.meters, averageHeartRate: s.heartRate,
                                            heartRateDrift: s.heartRateDrift, paceDrift: s.paceDrift,
                                            maximumAbsoluteGrade: s.maximumGrade))
                case .failure(let reason)?:
                    rejected.append(RejectedLTHRStretch(activityID: activity.id,
                                                        start: wallClock(activity, candidate, 0), reason: reason))
                }
            }
        }
        let scan = LTHRPaceScan(runsScanned: scanned, treadmillActivityIDs: treadmill, rejected: rejected)
        let seconds = used.reduce(0) { $0 + $1.seconds }, meters = used.reduce(0) { $0 + $1.meters }
        let pace = seconds / meters
        guard !used.isEmpty, pace.isFinite, pace > 0 else { return .failure(.noQualifyingStretch(scan)) }
        return .success(PaceAtLTHR(lthr: lthr, secondsPerMeter: pace, stretches: used, scan: scan))
    }

    // MARK: - Stretches

    /// A run of moving intervals around LTHR, with each interval marked as in
    /// the band or a bridged excursion. `chunkStartT` is the wall-clock offset
    /// (seconds since the activity started) of the moving clock's zero.
    struct Candidate {
        let chunkStartT: Double
        let intervals: [(interval: MovingTime.HeldInterval, inBand: Bool)]
        var start: Double { intervals.first!.interval.start }
        var end: Double { intervals.last!.interval.end }
    }

    static func wallClock(_ activity: Activity, _ c: Candidate, _ offset: Double) -> Date {
        activity.start.addingTimeInterval(c.chunkStartT + c.start + offset)
    }

    /// Splits the run at pauses, puts each moving chunk on its own clock, and
    /// collects stretches in the band, bridging excursions up to the limit.
    static func stretches(in activity: Activity, band: ClosedRange<Double>,
                          options: PaceAtLTHROptions) -> [Candidate] {
        let points = MovingTime.merged(activity.samples, streams: [
            .heartRate: { options.plausibleHeartRate.contains($0) },
            .speed: { options.plausibleSpeed.contains($0) },
            .altitude: { _ in true },
        ])
        var chunks: [[MovingTime.Point]] = []
        var current: [MovingTime.Point] = []
        for p in points {
            current.append(p)
            if !p.isMoving { chunks.append(current); current = [] }
        }
        chunks.append(current)

        var out: [Candidate] = []
        for chunk in chunks where chunk.count >= 2 && chunk[0].isMoving {
            let timeline = MovingTime.held(chunk, maximumHoldSeconds: options.maximumHoldSeconds)
            var stretch: [(interval: MovingTime.HeldInterval, inBand: Bool)] = []
            var pending: [(interval: MovingTime.HeldInterval, inBand: Bool)] = []
            var pendingSeconds = 0.0
            func close() {
                if !stretch.isEmpty { out.append(Candidate(chunkStartT: chunk[0].t, intervals: stretch)) }
                stretch = []; pending = []; pendingSeconds = 0
            }
            for iv in timeline {
                let inBand = iv.values[.speed] != nil && (iv.values[.heartRate].map(band.contains) ?? false)
                if inBand {
                    stretch += pending + [(iv, true)]
                    pending = []; pendingSeconds = 0
                } else if !stretch.isEmpty {
                    pending.append((iv, false)); pendingSeconds += iv.seconds
                    if pendingSeconds > options.maximumExcursionSeconds { close() }
                }
            }
            close()
        }
        return out
    }

    struct Measured {
        let seconds: Double
        let meters: Double
        let heartRate: Double
        let heartRateDrift: Double
        let paceDrift: Double
        let maximumGrade: Double
    }

    /// The used part of one interval: its start on the moving clock, length,
    /// whether it was in the band, and its held stream values.
    typealias Part = (start: Double, seconds: Double, inBand: Bool, values: [StreamKind: Double])

    /// nil for a touch of the band no longer than the settling period, which isn't worth listing.
    static func evaluate(_ c: Candidate, options: PaceAtLTHROptions) -> Result<Measured, LTHRStretchRejection>? {
        let from = c.start + options.settleSeconds, to = c.end
        guard to > from else { return nil }
        let parts: [Part] = c.intervals.compactMap { e in
            let lo = max(e.interval.start, from), hi = min(e.interval.end, to)
            return hi > lo ? (lo, hi - lo, e.inBand, e.interval.values) : nil
        }
        let inBand = parts.filter(\.inBand)
        let seconds = inBand.reduce(0) { $0 + $1.seconds }
        guard seconds >= options.minimumSeconds else { return .failure(.tooShort(seconds: seconds)) }
        let share = seconds / (to - from)
        guard share >= options.minimumInBandShare else { return .failure(.tooMuchTimeOutOfBand(share: share)) }
        guard inBand.allSatisfy({ $0.values[.altitude] != nil }),
              let grade = maximumGrade(parts, windowMeters: options.gradeWindowMeters) else {
            return .failure(.noElevation)
        }
        guard grade <= options.maximumGrade else { return .failure(.hilly(maximumAbsoluteGrade: grade)) }

        // Halves by moving time after settling; in-band time only.
        let mid = from + (to - from) / 2
        var halves = [(w: 0.0, hr: 0.0, speed: 0.0), (w: 0.0, hr: 0.0, speed: 0.0)]
        var sumSq = 0.0
        for p in inBand {
            guard let hr = p.values[.heartRate], let v = p.values[.speed] else { continue }
            let lo = p.start, hi = p.start + p.seconds
            let pieces = [(0, min(hi, mid) - lo), (1, hi - max(lo, mid))]
            for (i, w) in pieces where w > 0 {
                halves[i].w += w; halves[i].hr += hr * w; halves[i].speed += v * w
            }
            sumSq += v * v * p.seconds
        }
        guard halves[0].w > 0, halves[1].w > 0 else { return .failure(.tooMuchTimeOutOfBand(share: share)) }
        let hr1 = halves[0].hr / halves[0].w, hr2 = halves[1].hr / halves[1].w
        let v1 = halves[0].speed / halves[0].w, v2 = halves[1].speed / halves[1].w
        let hrDrift = (hr2 - hr1) / hr1
        guard abs(hrDrift) <= options.maximumHeartRateDrift else { return .failure(.heartRateDrift(fraction: hrDrift)) }
        // Pace is 1 / speed, so (pace2 - pace1) / pace1 = v1 / v2 - 1.
        let paceDrift = v1 / v2 - 1
        guard abs(paceDrift) <= options.maximumPaceDrift else { return .failure(.paceDrift(fraction: paceDrift)) }

        let meters = halves[0].speed + halves[1].speed
        let meanSpeed = meters / seconds
        let cv = max(0, sumSq / seconds - meanSpeed * meanSpeed).squareRoot() / meanSpeed
        guard cv <= options.maximumSpeedCV else { return .failure(.unsteadyPace(coefficientOfVariation: cv)) }
        let heartRate = (halves[0].hr + halves[1].hr) / seconds
        return .success(Measured(seconds: seconds, meters: meters, heartRate: heartRate,
                                 heartRateDrift: hrDrift, paceDrift: paceDrift, maximumGrade: grade))
    }

    /// Steepest absolute grade over sliding windows of at least `windowMeters`
    /// along the parts, so a hill is caught wherever it sits in the stretch.
    /// Distance comes from speed x time (a bridged part without speed adds
    /// none). Marks are the starts of parts that have an altitude, plus the end
    /// of the last part. From each mark the window runs to the first later mark
    /// at least `windowMeters` on. When the whole stretch is shorter than one
    /// window, it is measured end to end. nil when there is no distance or no
    /// altitude to measure from.
    ///
    /// Open: altimeter noise. The steepest window wins, so a single altitude
    /// spike can reject an otherwise flat stretch (pinned by
    /// `testOneSampleAltitudeSpikeSetsTheGrade`). Smoothing the altitude first,
    /// or requiring the grade to hold over more than one window, waits until
    /// real watch data shows how noisy the stream is; the rule is unchanged
    /// until then.
    static func maximumGrade(_ parts: [Part], windowMeters: Double) -> Double? {
        var marks: [(position: Double, altitude: Double)] = []
        var position = 0.0
        for p in parts {
            if let a = p.values[.altitude] { marks.append((position, a)) }
            position += (p.values[.speed] ?? 0) * p.seconds
        }
        guard position > 0, let endAltitude = parts.last?.values[.altitude] ?? marks.last?.altitude,
              let first = marks.first else { return nil }
        marks.append((position, endAltitude))
        guard position - first.position >= windowMeters else {
            let run = position - first.position
            return run > 0 ? abs(endAltitude - first.altitude) / run : nil
        }
        var steepest = 0.0
        var j = 0
        for a in marks.indices {
            if j <= a { j = a + 1 }
            // Positions only grow, so the end mark for each start moves forward too.
            while j < marks.count, marks[j].position - marks[a].position < windowMeters { j += 1 }
            guard j < marks.count else { break }
            let run = marks[j].position - marks[a].position
            steepest = max(steepest, abs(marks[j].altitude - marks[a].altitude) / run)
        }
        return steepest
    }
}
