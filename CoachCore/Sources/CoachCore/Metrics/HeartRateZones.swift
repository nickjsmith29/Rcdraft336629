import Foundation

/// A sustained hard effort that can reveal lactate threshold heart rate (SPEC.md 3.2).
public struct HREffort: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A race; `averageHR` is the whole-race average and `durationSeconds`
        /// is the whole race.
        case race
        /// A 30-minute solo time trial (SPEC.md 3.2). `durationSeconds` is the
        /// whole trial, from the start of the hard effort to its end (no
        /// warm-up or cool-down), while `averageHR` is the average of its last
        /// 20 minutes only.
        case timeTrialLast20Min
    }

    public let id: String
    public let date: Date
    public let kind: Kind
    /// Length of the whole effort in seconds (see `Kind` for what it covers).
    public let durationSeconds: Double
    /// Average heart rate in bpm (see `Kind` for which part of the effort).
    public let averageHR: Double

    public init(id: String, date: Date, kind: Kind, durationSeconds: Double, averageHR: Double) {
        self.id = id
        self.date = date
        self.kind = kind
        self.durationSeconds = durationSeconds
        self.averageHR = averageHR
    }
}

/// An LTHR estimate with the efforts it came from, so the app can show its evidence (F1).
public struct LTHREstimate: Equatable, Sendable {
    public let bpm: Double
    /// The effort that set the estimate.
    public let source: HREffort
    /// Every effort that qualified, highest average HR first (ties: newer
    /// first). Includes `setAside` when there is one.
    public let evidence: [HREffort]
    /// The highest qualifying effort when it was set aside as a suspected bad
    /// recording because no other effort came within
    /// `LTHREstimator.agreementToleranceBPM` of it; nil otherwise.
    public let setAside: HREffort?
    /// True when another qualifying effort lies within
    /// `LTHREstimator.agreementToleranceBPM` of `source`. A single effort, or
    /// one that only survived because the top effort was set aside, is not
    /// corroborated, and the app should confirm it with a field test (SPEC.md 3.2).
    public let isCorroborated: Bool
}

/// Estimates lactate threshold heart rate from the athlete's own efforts (SPEC.md 3.2).
///
/// Heuristics, stated so they can be tuned:
/// - A race counts when it lasted 30 to 120 minutes. Shorter races (a 5K)
///   are run above threshold and would overestimate LTHR; longer ones fall
///   well below it.
/// - A time trial counts when the whole trial lasted 30 to 35 minutes, so
///   it matches the 30-minute protocol of SPEC.md 3.2 (with a few minutes'
///   slack for a late press of the stop button) and its last-20-minute
///   average is a sustained effort at threshold. A longer trial is a
///   different, easier effort and doesn't count.
/// - Only efforts from `now - lookbackDays` through `now`, both inclusive, count.
/// - Robustness to one bad recording: a below-par day can hide threshold but
///   can't raise a sustained average above it, so the highest qualifying
///   average normally sets the estimate. A strap glitch or cadence lock can,
///   though. So with two or more qualifying efforts, the highest is used only
///   when the second-highest agrees with it within `agreementToleranceBPM`
///   (inclusive). Otherwise the highest is set aside as a suspected bad
///   recording and the second-highest sets the estimate. With three or more
///   efforts that is the median of the top three; either way it errs low,
///   which keeps easy runs easy. The set-aside effort stays in the evidence list.
/// - With exactly one qualifying effort it sets the estimate, marked as not
///   corroborated.
/// There is deliberately no age-based fallback: with no qualifying effort
/// the result is nil and the app schedules a field test (cold start).
public enum LTHREstimator {
    public static let raceDurationRange: ClosedRange<Double> = (30 * 60)...(120 * 60)
    public static let timeTrialDurationRange: ClosedRange<Double> = (30 * 60)...(35 * 60)
    public static let plausibleHR: ClosedRange<Double> = 100...220
    public static let defaultLookbackDays = 120
    /// How close, in bpm, the top two efforts must be to trust the highest. Heuristic.
    public static let agreementToleranceBPM: Double = 3

    public static func qualifies(_ effort: HREffort) -> Bool {
        guard effort.averageHR.isFinite, effort.durationSeconds.isFinite,
              plausibleHR.contains(effort.averageHR) else { return false }
        switch effort.kind {
        case .race:
            return raceDurationRange.contains(effort.durationSeconds)
        case .timeTrialLast20Min:
            return timeTrialDurationRange.contains(effort.durationSeconds)
        }
    }

    public static func estimate(
        from efforts: [HREffort],
        asOf now: Date,
        lookbackDays: Int = defaultLookbackDays
    ) -> LTHREstimate? {
        let earliest = now.addingTimeInterval(-Double(lookbackDays) * 86_400)
        let qualifying = efforts
            .filter { $0.date >= earliest && $0.date <= now && qualifies($0) }
            .sorted { lhs, rhs in
                lhs.averageHR != rhs.averageHR ? lhs.averageHR > rhs.averageHR : lhs.date > rhs.date
            }
        guard let best = qualifying.first else { return nil }

        func agree(_ a: HREffort, _ b: HREffort) -> Bool {
            abs(a.averageHR - b.averageHR) <= agreementToleranceBPM
        }

        guard qualifying.count >= 2 else {
            return LTHREstimate(bpm: best.averageHR, source: best, evidence: qualifying,
                                setAside: nil, isCorroborated: false)
        }
        let second = qualifying[1]
        if agree(best, second) {
            return LTHREstimate(bpm: best.averageHR, source: best, evidence: qualifying,
                                setAside: nil, isCorroborated: true)
        }
        let corroborated = qualifying.count >= 3 && agree(second, qualifying[2])
        return LTHREstimate(bpm: second.averageHR, source: second, evidence: qualifying,
                            setAside: best, isCorroborated: corroborated)
    }
}

/// Friel's running heart-rate zones as fractions of LTHR (SPEC.md 3.2).
public enum HRZone: Int, CaseIterable, Comparable, Sendable {
    case z1 = 1, z2, z3, z4, z5a, z5b, z5c

    public static func < (lhs: HRZone, rhs: HRZone) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Lower bound of the zone as a fraction of LTHR (z1 has none).
    public var lowerFraction: Double {
        switch self {
        case .z1: return 0
        case .z2: return 0.85
        case .z3: return 0.90
        case .z4: return 0.95
        case .z5a: return 1.00
        case .z5b: return 1.03
        case .z5c: return 1.07
        }
    }

    /// Friel's name for the zone.
    public var name: String {
        switch self {
        case .z1: return "Recovery"
        case .z2: return "Aerobic"
        case .z3: return "Tempo"
        case .z4: return "SubThreshold"
        case .z5a: return "SuperThreshold"
        case .z5b: return "Aerobic capacity"
        case .z5c: return "Anaerobic capacity"
        }
    }
}

public struct HRZones: Equatable, Sendable {
    public let lthr: Double

    /// Returns nil for an implausible LTHR.
    public init?(lthr: Double) {
        guard lthr.isFinite, LTHREstimator.plausibleHR.contains(lthr) else { return nil }
        self.lthr = lthr
    }

    /// Lower bound of a zone in bpm (inclusive: a bpm equal to it is in that zone).
    public func lowerBound(_ zone: HRZone) -> Double { zone.lowerFraction * lthr }

    /// The zone a heart rate falls in. A bpm exactly on a boundary belongs to
    /// the higher zone. Returns nil for a non-finite or non-positive bpm, which
    /// is a missing or broken reading rather than recovery effort.
    public func zone(for bpm: Double) -> HRZone? {
        guard bpm.isFinite, bpm > 0 else { return nil }
        return HRZone.allCases.last { bpm >= lowerBound($0) } ?? .z1
    }

    /// Upper limit for easy running: the lower bound of zone 3, so the top of
    /// zone 2. It is exclusive: a bpm equal to `easyCeiling` is already zone 3,
    /// so a check for running above the zone-2 cap must use `bpm >= easyCeiling`.
    public var easyCeiling: Double { lowerBound(.z3) }
}
