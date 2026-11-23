import Foundation
@testable import CoachCore

// Synthetic plan fixtures only; no real runner's training is represented here.
enum PlanFixture {
    static let utc = TimeZone(identifier: "UTC")!

    /// Monday 2026-01-05 00:00 UTC.
    static let firstMonday: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 1; c.day = 5
        return PlanCalendar.calendar(timeZone: utc).date(from: c)!
    }()

    /// Week `week` (0-based from `firstMonday`), day 0 = Monday, at 07:00 UTC.
    static func date(week: Int, day: Int, hour: Int = 7) -> Date {
        firstMonday.addingTimeInterval(Double(week * 7 + day) * 86_400 + Double(hour) * 3600)
    }

    static func workout(_ id: String, week: Int, day: Int, _ kind: PlannedWorkout.Kind,
                        minutes: Double, km: Double? = nil) -> PlannedWorkout {
        PlannedWorkout(id: id, date: date(week: week, day: day), kind: kind,
                       durationSeconds: minutes * 60, distanceMeters: km.map { $0 * 1000 })
    }

    /// A week of four easy runs of equal length totalling `minutes` (no long run,
    /// no quality), so only the volume rules can fire.
    static func easyWeek(_ week: Int, minutes: Double, prefix: String = "w") -> [PlannedWorkout] {
        (0..<4).map { workout("\(prefix)\(week)-\($0)", week: week, day: $0 * 2 % 7, .easy, minutes: minutes / 4) }
    }

    /// Easy weeks with the given totals, starting at week `start`.
    static func easyWeeks(_ totals: [Double], start: Int = 0, prefix: String = "w") -> [PlannedWorkout] {
        totals.enumerated().flatMap { easyWeek(start + $0.offset, minutes: $0.element, prefix: prefix) }
    }
}
