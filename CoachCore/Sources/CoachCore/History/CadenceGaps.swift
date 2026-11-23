import Foundation

/// A stretch of consecutive runs in the history with no cadence recorded
/// (SPEC.md section 2 "Missing streams", F1). Flagged only; never filled.
public struct HistoryCadenceGap: Equatable, Sendable {
    /// Start of the first run without cadence.
    public let from: Date
    /// Start of the last run without cadence.
    public let through: Date
    /// The runs without cadence, in start order.
    public let activityIDs: [String]
    /// True when an earlier run had cadence, so the stretch likely follows a
    /// device or app change rather than predating cadence recording.
    public let followsRecordedCadence: Bool
    /// True when the stretch reaches the latest run, so cadence is still missing.
    public let isOngoing: Bool
}

/// The cadence-presence picture across a history.
public struct HistoryCadenceReport: Equatable, Sendable {
    /// Runs considered (sport `.run` with a finite start).
    public let runCount: Int
    public let runsWithCadence: Int
    /// Stretches without cadence. Empty when cadence was never recorded at all,
    /// since there is then no gap to point at; see `neverRecorded`.
    public let gaps: [HistoryCadenceGap]

    /// True when no run in the history has cadence.
    public var neverRecorded: Bool { runCount > 0 && runsWithCadence == 0 }
}

/// A stretch within one run where cadence is missing while the runner is moving.
/// A pause inside the stretch does not end it, but its length is not counted.
public struct RunCadenceGap: Equatable, Sendable {
    /// Seconds since the activity started at the first moving sample without cadence.
    public let startT: Double
    /// Seconds since start where the gap ends: at the next moving sample with
    /// cadence, or, when the gap runs to the end of the recording, one sample
    /// interval after the last missing sample (that sample's own interval, which
    /// for the final sample is the run's median sample interval).
    public let endT: Double
    /// Moving samples without cadence in the stretch.
    public let missingSampleCount: Int
    /// Moving time without cadence, in seconds. Paused time between `startT` and
    /// `endT` is left out, so this can be shorter than `endT - startT`.
    public let durationSeconds: Double
}

/// Finds where cadence is missing, across a history and within a run
/// (SPEC.md section 2, F1). Nothing here fills a gap; callers decide how to
/// treat flagged runs (for example leaving them out of the cadence trend).
///
/// Heuristics, stated so they can be tuned:
/// - Only `.run` activities count; walks and other sports often lack cadence by design.
/// - A run has cadence when its samples hold a finite cadence value or its
///   summary average cadence is finite.
/// - Across the history, every maximal stretch of at least `minimumRuns`
///   consecutive runs without cadence is a gap, provided cadence was recorded on
///   some run in the history.
/// - Within a run, only moving samples can be missing cadence (a pause
///   legitimately has none), and only runs with some cadence are checked. A
///   stretch runs from a moving sample without cadence to the next moving sample
///   with cadence; pauses inside it neither end it nor add to its length.
/// - Each sample stands for the time until the next sample (the final sample for
///   the run's median sample interval). A stretch's duration is the summed time
///   of its moving samples without cadence, and it is flagged when that moving
///   time is at least `minimumSeconds`. So a few missing samples just before a
///   long stop are not reported as a long gap.
public enum CadenceGapDetector {
    public static let defaultMinimumRuns = 1
    public static let defaultMinimumSeconds: Double = 30

    public static func historyReport(_ activities: [Activity],
                                     minimumRuns: Int = defaultMinimumRuns) -> HistoryCadenceReport {
        let runs = activities.enumerated()
            .filter { $0.element.sport == .run && $0.element.start.timeIntervalSinceReferenceDate.isFinite }
            .sorted { lhs, rhs in
                lhs.element.start != rhs.element.start ? lhs.element.start < rhs.element.start : lhs.offset < rhs.offset
            }
            .map(\.element)
        let flags = runs.map(\.hasCadence)
        let withCadence = flags.filter { $0 }.count
        guard withCadence > 0 else {
            return HistoryCadenceReport(runCount: runs.count, runsWithCadence: 0, gaps: [])
        }

        var gaps: [HistoryCadenceGap] = []
        var i = 0
        while i < runs.count {
            guard !flags[i] else { i += 1; continue }
            var j = i
            while j + 1 < runs.count, !flags[j + 1] { j += 1 }
            if j - i + 1 >= max(1, minimumRuns) {
                gaps.append(HistoryCadenceGap(
                    from: runs[i].start,
                    through: runs[j].start,
                    activityIDs: runs[i...j].map(\.id),
                    followsRecordedCadence: flags[..<i].contains(true),
                    isOngoing: j == runs.count - 1))
            }
            i = j + 1
        }
        return HistoryCadenceReport(runCount: runs.count, runsWithCadence: withCadence, gaps: gaps)
    }

    public static func gaps(in activity: Activity,
                            minimumSeconds: Double = defaultMinimumSeconds) -> [RunCadenceGap] {
        let points = activity.samples.enumerated()
            .filter { $0.element.t.isFinite }
            .sorted { $0.element.t != $1.element.t ? $0.element.t < $1.element.t : $0.offset < $1.offset }
            .map(\.element)
        let missing = points.map { $0.isMoving && StreamKind.cadence.value(in: $0) == nil }
        let present = points.map { $0.isMoving && StreamKind.cadence.value(in: $0) != nil }
        guard present.contains(true) else { return [] }

        let finalInterval = medianPositiveInterval(points)
        func interval(_ k: Int) -> Double {
            k + 1 < points.count ? points[k + 1].t - points[k].t : finalInterval
        }

        var result: [RunCadenceGap] = []
        var open: (startT: Double, lastMissing: Int, count: Int, moving: Double)?
        func close(endT: Double) {
            if let gap = open, gap.moving >= minimumSeconds {
                result.append(RunCadenceGap(startT: gap.startT, endT: endT,
                                            missingSampleCount: gap.count, durationSeconds: gap.moving))
            }
            open = nil
        }
        for k in points.indices {
            if missing[k] {
                if let gap = open {
                    open = (gap.startT, k, gap.count + 1, gap.moving + interval(k))
                } else {
                    open = (points[k].t, k, 1, interval(k))
                }
            } else if present[k], open != nil {
                close(endT: points[k].t)
            }
            // A paused sample neither ends an open gap nor adds to its length.
        }
        if let gap = open {
            close(endT: points[gap.lastMissing].t + interval(gap.lastMissing))
        }
        return result
    }

    /// Median of the positive gaps between consecutive sample times; 0 when there are none.
    private static func medianPositiveInterval(_ points: [StreamSample]) -> Double {
        let steps = zip(points.dropFirst(), points).map { $0.t - $1.t }.filter { $0 > 0 }.sorted()
        guard !steps.isEmpty else { return 0 }
        let mid = steps.count / 2
        return steps.count % 2 == 1 ? steps[mid] : (steps[mid - 1] + steps[mid]) / 2
    }
}
