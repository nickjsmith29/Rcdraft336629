import Foundation

/// Week convention for plans (SPEC.md F3, F9).
///
/// A training week is an ISO-8601 week: it starts on **Monday at 00:00 in the
/// runner's time zone** and runs to the next Monday at 00:00 (so a session at
/// Sunday 23:30 belongs to the week that started six days earlier). The time
/// zone is always passed in, never assumed, so the same sessions group the
/// same way on any device.
public enum PlanCalendar {
    /// A Gregorian calendar with Monday as the first weekday (ISO 8601) in `timeZone`.
    public static func calendar(timeZone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.firstWeekday = 2
        cal.minimumDaysInFirstWeek = 4
        return cal
    }

    /// Monday 00:00 of the week containing `date`, in `timeZone`.
    public static func weekStart(containing date: Date, timeZone: TimeZone) -> Date {
        let cal = calendar(timeZone: timeZone)
        let day = cal.startOfDay(for: date)
        // Gregorian weekday: 1 = Sunday ... 7 = Saturday. Days since Monday:
        let daysSinceMonday = (cal.component(.weekday, from: day) + 5) % 7
        guard let monday = cal.date(byAdding: .day, value: -daysSinceMonday, to: day) else { return day }
        // Normalize: where a Monday has no midnight (a clock change at 00:00),
        // stepping back lands mid-day; the week start is that day's first instant.
        return cal.startOfDay(for: monday)
    }

    /// The Monday after `weekStart` (handles daylight-saving changes, including
    /// zones whose clocks jump at midnight; see `weekStart(weeks:after:)`).
    public static func nextWeekStart(after weekStart: Date, timeZone: TimeZone) -> Date {
        self.weekStart(weeks: 1, after: weekStart, timeZone: timeZone)
    }

    /// The week start `n` whole weeks after `weekStart` (`n` may be negative or
    /// zero), stepping by calendar date, not by 7 * 86,400 seconds, and
    /// normalizing with `startOfDay(for:)` so the result is always that
    /// Monday's first instant. Where a Monday has no 00:00 (a clock change at
    /// midnight, e.g. Asia/Tehran on 2021-03-22) a plain "add 7 days" lands at
    /// 01:00, and every later addition would carry the drift. Returns the
    /// normalized `weekStart` itself if the calendar cannot step.
    public static func weekStart(weeks n: Int, after weekStart: Date, timeZone: TimeZone) -> Date {
        let cal = calendar(timeZone: timeZone)
        let day = cal.startOfDay(for: weekStart)
        let (days, overflow) = n.multipliedReportingOverflow(by: 7)
        guard n != 0, !overflow, let moved = cal.date(byAdding: .day, value: days, to: day) else { return day }
        return cal.startOfDay(for: moved)
    }
}

/// One Monday-start training week and the sessions in it (see `PlanCalendar`).
public struct PlanWeek: Equatable, Sendable {
    /// Monday 00:00 in the runner's time zone.
    public let weekStart: Date
    /// The next Monday 00:00; the week covers `weekStart ..< weekEnd`.
    public let weekEnd: Date
    /// Sessions in the week, sorted by date.
    public let workouts: [PlannedWorkout]

    public init(weekStart: Date, weekEnd: Date, workouts: [PlannedWorkout]) {
        self.weekStart = weekStart
        self.weekEnd = weekEnd
        self.workouts = workouts.sorted { $0.date < $1.date }
    }

    /// Total weekly volume (seconds for `.time`, meters for `.distance`),
    /// or nil when any session's value is missing or invalid. An empty week is 0.
    public func volume(_ measure: VolumeMeasure) -> Double? {
        var total = 0.0
        for w in workouts {
            guard let v = w.volume(measure) else { return nil }
            total += v
        }
        return total
    }

    /// The part of the week's volume that is known: the sum of the sessions
    /// whose value is valid (`PlannedWorkout.volume`). When `volume` is nil
    /// the true total is at least this much, since a session never has
    /// negative volume (#40). Equal to `volume` when that is known.
    func knownVolume(_ measure: VolumeMeasure) -> Double {
        workouts.reduce(0) { $0 + ($1.volume(measure) ?? 0) }
    }

    /// Groups sessions into consecutive weeks from the first session's week to
    /// the last one's, inserting empty weeks for gaps (a week with no runs is
    /// a real zero, which matters for the rolling checks). Empty input gives [].
    public static func weeks(from workouts: [PlannedWorkout], timeZone: TimeZone) -> [PlanWeek] {
        guard let first = workouts.map(\.date).min(), let last = workouts.map(\.date).max() else { return [] }
        return weeks(from: workouts, firstWeekContaining: first, lastWeekContaining: last, timeZone: timeZone)
    }

    /// Consecutive weeks covering the weeks of `start` through `end` inclusive;
    /// sessions outside that range are left out.
    static func weeks(from workouts: [PlannedWorkout], firstWeekContaining start: Date,
                      lastWeekContaining end: Date, timeZone: TimeZone) -> [PlanWeek] {
        var result: [PlanWeek] = []
        var weekStart = PlanCalendar.weekStart(containing: start, timeZone: timeZone)
        let lastStart = PlanCalendar.weekStart(containing: end, timeZone: timeZone)
        let sorted = workouts.sorted { $0.date < $1.date }
        while weekStart <= lastStart {
            let weekEnd = PlanCalendar.nextWeekStart(after: weekStart, timeZone: timeZone)
            let inWeek = sorted.filter { $0.date >= weekStart && $0.date < weekEnd }
            result.append(PlanWeek(weekStart: weekStart, weekEnd: weekEnd, workouts: inWeek))
            weekStart = weekEnd
        }
        return result
    }
}
