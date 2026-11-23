import Foundation

/// Moving time of a recorded run, pauses left out (SPEC.md 3.5 weekly time, F1, F9).
///
/// One rule for every caller, so the baseline's weekly load and the
/// guardrails' history volume agree. It is the clock `Decoupling` uses:
/// - Samples with a non-finite `t` are dropped. Samples that share a timestamp
///   are merged into one point, paused if any of them is paused.
/// - The time from one point to the next counts when the first point is
///   moving (`StreamSample.isMoving`). The last point adds no time.
/// - Heuristic: when the next point is paused, at most `maximumHoldSeconds`
///   of that stretch counts, because the runner may have stopped any time
///   after the last moving sample (the same limit as
///   `DecouplingOptions.maximumHoldSeconds`). A silent stretch with moving
///   points on both sides counts in full.
/// - With fewer than two points there is no way to tell pauses apart, so the
///   activity's elapsed `durationSeconds` is used (0 when it is not a finite
///   non-negative number).
public enum MovingTime {
    public static let defaultMaximumHoldSeconds: Double = 30

    /// Moving seconds of `activity` under the rule above.
    public static func seconds(of activity: Activity,
                               maximumHoldSeconds: Double = defaultMaximumHoldSeconds) -> Double {
        knownSeconds(of: activity, maximumHoldSeconds: maximumHoldSeconds) ?? 0
    }

    /// Moving seconds of `activity` under the rule above, or nil when the run
    /// has no usable time at all: fewer than two usable points and an elapsed
    /// duration that is not a finite non-negative number. `seconds(of:)`
    /// counts such a run as 0; the guardrail history (3.5) keeps it unknown,
    /// so its week can't pass as a recovery week (#40).
    public static func knownSeconds(of activity: Activity,
                                    maximumHoldSeconds: Double = defaultMaximumHoldSeconds) -> Double? {
        let points = merged(activity.samples, streams: [:])
        guard points.count >= 2 else {
            let elapsed = activity.durationSeconds
            return elapsed.isFinite && elapsed >= 0 ? elapsed : nil
        }
        return held(points, maximumHoldSeconds: maximumHoldSeconds).last?.end ?? 0
    }

    /// Samples with a finite time, in time order (stable for equal times).
    static func ordered(_ samples: [StreamSample]) -> [StreamSample] {
        samples.enumerated()
            .filter { $0.element.t.isFinite }
            .sorted { $0.element.t != $1.element.t ? $0.element.t < $1.element.t : $0.offset < $1.offset }
            .map(\.element)
    }

    // MARK: - Streams carried forward on the moving clock

    /// Decides whether a stream's value is usable (finite values only reach it).
    typealias Usable = (Double) -> Bool

    /// One timestamp after merging samples that share it.
    struct Point {
        let t: Double
        let isMoving: Bool
        /// Mean of the usable values per requested stream at this timestamp.
        let values: [StreamKind: Double]
    }

    /// A stretch of moving time with the stream values held over it.
    struct HeldInterval {
        /// Start and end on the moving clock (seconds of moving time so far).
        let start: Double
        let end: Double
        /// Held value per requested stream; a stream is absent when it has no
        /// usable reading within the hold limit.
        let values: [StreamKind: Double]

        var seconds: Double { end - start }
    }

    /// Merges samples sharing a timestamp: paused if any is paused, each
    /// requested stream the mean of its usable values.
    static func merged(_ samples: [StreamSample], streams: [StreamKind: Usable]) -> [Point] {
        var byTime: [Double: (moving: Bool, values: [StreamKind: [Double]])] = [:]
        for s in samples where s.t.isFinite {
            var e = byTime[s.t] ?? (true, [:])
            e.moving = e.moving && s.isMoving
            for (kind, usable) in streams {
                if let v = kind.value(in: s), usable(v) { e.values[kind, default: []].append(v) }
            }
            byTime[s.t] = e
        }
        return byTime.keys.sorted().map { t in
            let e = byTime[t]!
            return Point(t: t, isMoving: e.moving,
                         values: e.values.mapValues { $0.sorted().reduce(0, +) / Double($0.count) })
        }
    }

    /// Moving intervals with each requested stream carried forward from its own
    /// last usable reading for at most `maximumHoldSeconds` (the rule of
    /// `Decoupling`'s timeline, for any streams). A pause clears every hold, so
    /// a reading never carries across it. Intervals are cut where a hold runs out.
    static func held(_ samples: [StreamSample],
                     streams: [StreamKind: Usable],
                     maximumHoldSeconds: Double) -> [HeldInterval] {
        held(merged(samples, streams: streams), maximumHoldSeconds: maximumHoldSeconds)
    }

    static func held(_ points: [Point], maximumHoldSeconds: Double) -> [HeldInterval] {
        guard points.count >= 2 else { return [] }
        let hold = maximumHoldSeconds.isFinite ? max(0, maximumHoldSeconds) : defaultMaximumHoldSeconds
        var clock = 0.0
        var last: [StreamKind: (t: Double, v: Double)] = [:]
        var out: [HeldInterval] = []
        for i in 0..<(points.count - 1) {
            let p = points[i], next = points[i + 1]
            guard p.isMoving else { last = [:]; continue }
            for (kind, v) in p.values { last[kind] = (p.t, v) }
            let dt = next.t - p.t
            let duration = next.isMoving ? dt : min(dt, hold)
            guard duration > 0 else { continue }
            let end = p.t + duration
            var cuts = [p.t, end]
            for (_, r) in last where r.t + hold > p.t && r.t + hold < end { cuts.append(r.t + hold) }
            cuts.sort()
            for j in 0..<(cuts.count - 1) where cuts[j + 1] > cuts[j] {
                let a = cuts[j], b = cuts[j + 1]
                var values: [StreamKind: Double] = [:]
                for (kind, r) in last where a < r.t + hold { values[kind] = r.v }
                out.append(HeldInterval(start: clock + (a - p.t), end: clock + (b - p.t), values: values))
            }
            clock += duration
        }
        return out
    }
}
