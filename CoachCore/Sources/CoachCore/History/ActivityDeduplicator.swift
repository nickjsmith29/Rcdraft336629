import Foundation

/// An activity removed as a duplicate, with the activity kept in its place and why.
public struct DroppedDuplicate: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// The kept activity recorded more streams.
        case fewerStreams(kept: Int, dropped: Int)
        /// Same number of streams; the kept activity had more samples.
        case fewerSamples(kept: Int, dropped: Int)
        /// Equally rich; the one that came first in the input was kept.
        case equallyRichKeptEarlierInput
    }

    public let dropped: Activity
    public let keptID: String
    /// Kept start minus dropped start, in seconds.
    public let startOffsetSeconds: Double
    /// Kept duration minus dropped duration, in seconds.
    public let durationDifferenceSeconds: Double
    public let reason: Reason

    /// A plain sentence the app can show, for example
    /// "Dropped b (Strava) as a duplicate of a: starts 30 s apart, durations differ by 12 s; a has 5 streams, b has 2."
    public var explanation: String {
        let why: String
        switch reason {
        case let .fewerStreams(kept, droppedCount):
            why = "\(keptID) has \(kept) streams, \(dropped.id) has \(droppedCount)"
        case let .fewerSamples(kept, droppedCount):
            why = "same streams, but \(keptID) has \(kept) samples and \(dropped.id) has \(droppedCount)"
        case .equallyRichKeptEarlierInput:
            why = "equally rich, so the one imported first (\(keptID)) was kept"
        }
        return "Dropped \(dropped.id) (\(dropped.source.label)) as a duplicate of \(keptID): "
            + "starts \(Int(abs(startOffsetSeconds).rounded())) s apart, "
            + "durations differ by \(Int(abs(durationDifferenceSeconds).rounded())) s; \(why)."
    }
}

/// The history with duplicates removed, and a record of each removal.
public struct DeduplicationResult: Equatable, Sendable {
    /// Kept activities, ordered by start time.
    public let activities: [Activity]
    /// Removed activities, ordered by start time.
    public let dropped: [DroppedDuplicate]
}

/// Removes the same run recorded twice, for example once by a third-party plan
/// app and once by the watch (SPEC.md section 2 "Duplicates", F1).
///
/// Heuristics, stated so they can be tuned:
/// - Two activities are the same one when they have the same sport, their starts
///   are at most `startTolerance` apart, and their durations differ by at most
///   `max(durationToleranceSeconds, durationToleranceFraction * longer duration)`.
///   Different sports are never merged, because dropping a real activity is worse
///   than keeping a duplicate.
/// - Of a group of duplicates the richest is kept: most streams present (a stream
///   counts when it holds at least one finite value), then most samples, then the
///   one that came first in the input, so the result is deterministic.
/// - Activities are kept richest first, and each one is compared only with
///   activities already kept. The result guarantees two things: no two kept
///   activities are duplicates of each other, and every dropped activity is
///   within tolerance of the kept activity named in its record. It does not
///   guarantee that a chain keeps more than one member: in a chain A~B~C where A
///   and C are not duplicates, if B is the richest it is kept and both A and C are
///   dropped as its duplicates; if A or C is richest, B is dropped and the other
///   end is kept too.
/// - Both tolerances are inclusive: a start offset of exactly `startTolerance`, or
///   a duration difference of exactly the allowed amount, still counts as a duplicate.
/// - An activity with a non-finite or negative start or duration is never treated
///   as a duplicate; it is kept as is.
public enum ActivityDeduplicator {
    public static let defaultStartTolerance: TimeInterval = 120
    public static let defaultDurationToleranceSeconds: Double = 120
    public static let defaultDurationToleranceFraction: Double = 0.10

    public static func isDuplicate(_ a: Activity,
                                   _ b: Activity,
                                   startTolerance: TimeInterval = defaultStartTolerance,
                                   durationToleranceSeconds: Double = defaultDurationToleranceSeconds,
                                   durationToleranceFraction: Double = defaultDurationToleranceFraction) -> Bool {
        guard comparable(a), comparable(b), a.sport == b.sport else { return false }
        let startGap = abs(a.start.timeIntervalSince(b.start))
        guard startGap <= startTolerance else { return false }
        let longer = max(a.durationSeconds, b.durationSeconds)
        let allowed = max(durationToleranceSeconds, durationToleranceFraction * longer)
        return abs(a.durationSeconds - b.durationSeconds) <= allowed
    }

    public static func deduplicate(_ activities: [Activity],
                                   startTolerance: TimeInterval = defaultStartTolerance,
                                   durationToleranceSeconds: Double = defaultDurationToleranceSeconds,
                                   durationToleranceFraction: Double = defaultDurationToleranceFraction) -> DeduplicationResult {
        let ranked = activities.enumerated()
            .map { (index: $0.offset, activity: $0.element, streams: $0.element.presentStreams.count) }
            .sorted { lhs, rhs in
                if lhs.streams != rhs.streams { return lhs.streams > rhs.streams }
                if lhs.activity.samples.count != rhs.activity.samples.count {
                    return lhs.activity.samples.count > rhs.activity.samples.count
                }
                return lhs.index < rhs.index
            }

        var kept: [(index: Int, activity: Activity, streams: Int)] = []
        var dropped: [(index: Int, record: DroppedDuplicate)] = []
        for candidate in ranked {
            let match = kept.first {
                isDuplicate($0.activity, candidate.activity,
                            startTolerance: startTolerance,
                            durationToleranceSeconds: durationToleranceSeconds,
                            durationToleranceFraction: durationToleranceFraction)
            }
            guard let keeper = match else {
                kept.append(candidate)
                continue
            }
            let reason: DroppedDuplicate.Reason
            if keeper.streams != candidate.streams {
                reason = .fewerStreams(kept: keeper.streams, dropped: candidate.streams)
            } else if keeper.activity.samples.count != candidate.activity.samples.count {
                reason = .fewerSamples(kept: keeper.activity.samples.count,
                                       dropped: candidate.activity.samples.count)
            } else {
                reason = .equallyRichKeptEarlierInput
            }
            dropped.append((candidate.index, DroppedDuplicate(
                dropped: candidate.activity,
                keptID: keeper.activity.id,
                startOffsetSeconds: keeper.activity.start.timeIntervalSince(candidate.activity.start),
                durationDifferenceSeconds: keeper.activity.durationSeconds - candidate.activity.durationSeconds,
                reason: reason)))
        }

        return DeduplicationResult(
            activities: kept.sorted { startOrder($0.activity, $0.index, $1.activity, $1.index) }.map(\.activity),
            dropped: dropped.sorted { startOrder($0.record.dropped, $0.index, $1.record.dropped, $1.index) }
                .map(\.record))
    }

    private static func comparable(_ a: Activity) -> Bool {
        a.start.timeIntervalSinceReferenceDate.isFinite && a.durationSeconds.isFinite && a.durationSeconds >= 0
    }

    /// Start time ascending (non-finite starts last), then input order.
    private static func startOrder(_ a: Activity, _ ai: Int, _ b: Activity, _ bi: Int) -> Bool {
        let l = a.start.timeIntervalSinceReferenceDate
        let r = b.start.timeIntervalSinceReferenceDate
        if l.isFinite != r.isFinite { return l.isFinite }
        if l.isFinite, l != r { return l < r }
        return ai < bi
    }
}

extension Activity.Source {
    /// A short label for explanations.
    public var label: String {
        switch self {
        case .healthKit: return "Apple Health"
        case .strava: return "Strava"
        case .other(let name): return name
        }
    }
}
