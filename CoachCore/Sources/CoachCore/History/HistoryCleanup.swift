import Foundation

/// An imported history after de-duplication, treadmill tagging and the cadence-gap
/// check (F1). The activities are unchanged apart from duplicates being removed.
public struct CleanedHistory: Equatable, Sendable {
    /// Kept activities, ordered by start time.
    public let activities: [Activity]
    /// Duplicates removed, with the reason for each.
    public let dropped: [DroppedDuplicate]
    /// Treadmill tag per kept activity id.
    public let treadmill: [String: TreadmillTag]
    /// Cadence presence across the kept runs.
    public let cadence: HistoryCadenceReport
}

/// Runs the F1 history checks in the order that matters: duplicates go first, so
/// a stream-poor copy of a run can't show up as a cadence gap.
public enum HistoryCleanup {
    public static func clean(_ activities: [Activity]) -> CleanedHistory {
        let dedup = ActivityDeduplicator.deduplicate(activities)
        var tags: [String: TreadmillTag] = [:]
        for activity in dedup.activities { tags[activity.id] = TreadmillTagger.tag(activity) }
        return CleanedHistory(activities: dedup.activities,
                              dropped: dedup.dropped,
                              treadmill: tags,
                              cadence: CadenceGapDetector.historyReport(dedup.activities))
    }
}
