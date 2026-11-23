import Foundation

/// A workout the watch already has scheduled from this app, as WorkoutKit's
/// `ScheduledWorkoutPlan` reports it (plan id, date, completed or not).
public struct WatchScheduledWorkout: Equatable, Hashable, Sendable {
    public let id: UUID
    public let date: WatchScheduleDate
    public let isComplete: Bool

    public init(id: UUID, date: WatchScheduleDate, isComplete: Bool) {
        self.id = id
        self.date = date
        self.isComplete = isComplete
    }
}

/// What a sync changes on the watch.
public struct WatchSyncChanges: Equatable, Sendable {
    /// Scheduled workouts to remove first.
    public let remove: [WatchScheduledWorkout]
    /// Workouts to schedule after the removals, in date order. Never more
    /// than the room the kept workouts leave under the scheduler's limit.
    public let schedule: [WatchWorkout]
    /// Scheduled workouts left as they are: completed ones in the window, and
    /// today's sessions that have already started.
    public let keep: [WatchScheduledWorkout]
    /// Every session of the batch that isn't scheduled, with the reason: the
    /// batch's own skips (a started session the watch shows done becomes
    /// `alreadyCompleted`), sessions done already, and those over the limit.
    public let skipped: [WatchSyncSkip]

    public init(remove: [WatchScheduledWorkout], schedule: [WatchWorkout], keep: [WatchScheduledWorkout],
                skipped: [WatchSyncSkip]) {
        self.remove = remove
        self.schedule = schedule
        self.keep = keep
        self.skipped = skipped
    }
}

/// Decides how a batch replaces what is already on the watch (SPEC.md F10).
///
/// Rules:
/// - A completed workout dated in the window stays, and a session with the
///   same id is not scheduled again (`WatchSyncSkip.Reason.alreadyCompleted`).
///   One from before the window is removed: run history lives in HealthKit,
///   and completed workouts left in place would fill the scheduler's limit.
/// - An incomplete workout whose id is in the batch is removed and scheduled
///   again with the current content and date, so a moved or changed session
///   replaces itself instead of appearing twice. WorkoutKit doesn't report
///   back enough to tell an unchanged workout apart, so replacing is the safe choice.
/// - An incomplete workout from today that has already started by the
///   batch's `from` stays only when the batch skipped that same session as
///   `startedBeforeNow` (it is still in the plan), so the runner can still
///   start it late without it being scheduled at a past time. One the plan
///   dropped is removed.
/// - Every other incomplete workout is removed: one in or after the window
///   is stale (the plan moved or dropped it), and a missed one from before
///   the window is stale too. Run history comes from HealthKit, not from the
///   scheduler, and a missed workout left in place would take one of the
///   scheduler's few slots for good.
/// - The batch is cut to the room the kept workouts leave under
///   `maxScheduled` (WorkoutKit's `maxAllowedScheduledWorkoutCount`), the
///   latest sessions first (`overScheduleLimit`), so scheduling never runs
///   over the limit partway.
public enum WatchSyncReconciler {
    public static func changes(existing: [WatchScheduledWorkout], batch: WatchSyncBatch, timeZone: TimeZone,
                               maxScheduled: Int? = nil) -> WatchSyncChanges {
        let windowStart = WatchScheduleDate(batch.windowStart, timeZone: timeZone)
        let wanted = Set(batch.workouts.map(\.id))
        let started = batch.startedBeforeNowIDs
        let done = Set(existing.filter { $0.isComplete && $0.date >= windowStart }.map(\.id))

        var remove: [WatchScheduledWorkout] = []
        var keep: [WatchScheduledWorkout] = []
        for e in existing {
            let inWindow = e.date >= windowStart
            let startedToday = inWindow && e.date.hasStarted(by: batch.from, timeZone: timeZone)
            if e.isComplete ? inWindow
                : (startedToday && started.contains(e.id) && !wanted.contains(e.id) && !done.contains(e.id)) {
                keep.append(e)
            } else {
                remove.append(e)
            }
        }
        var schedule: [WatchWorkout] = []
        // A session done earlier today is reported as done, not as started.
        var skipped: [WatchSyncSkip] = batch.skipped.map { s in
            s.reason == .startedBeforeNow && done.contains(WatchSyncID.uuid(forSessionID: s.sessionID))
                ? WatchSyncSkip(sessionID: s.sessionID, date: s.date, reason: .alreadyCompleted) : s
        }
        for w in batch.workouts {
            if done.contains(w.id) {
                skipped.append(WatchSyncSkip(sessionID: w.sessionID, date: w.date, reason: .alreadyCompleted))
            } else {
                schedule.append(w)
            }
        }
        if let maxScheduled {
            let limit = room(maxScheduled: maxScheduled, kept: keep.count)
            if schedule.count > limit {
                skipped += schedule[limit...].map {
                    WatchSyncSkip(sessionID: $0.sessionID, date: $0.date, reason: .overScheduleLimit(limit: limit))
                }
                schedule = Array(schedule[..<limit])
            }
        }
        let order: (WatchScheduledWorkout, WatchScheduledWorkout) -> Bool = {
            $0.date != $1.date ? $0.date < $1.date : $0.id.uuidString < $1.id.uuidString
        }
        skipped.sort { $0.date != $1.date ? $0.date < $1.date : $0.sessionID < $1.sessionID }
        return WatchSyncChanges(remove: remove.sorted(by: order), schedule: schedule, keep: keep.sorted(by: order),
                                skipped: skipped)
    }

    /// Workouts that can still be scheduled: the limit less the workouts that
    /// stay on the watch, never below zero.
    public static func room(maxScheduled: Int, kept: Int) -> Int {
        max(0, maxScheduled - max(0, kept))
    }
}
