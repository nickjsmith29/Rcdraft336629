import Foundation
@testable import CoachCore

// Synthetic runners for the F2 goal-interview tests, built on BaselineFixture's
// invented heart-rate model. No real runner's data is represented here.
enum GoalFixture {
    static let timeZone = BaselineFixture.timeZone

    /// A run of `minutes` on `day` of week `week` (day 0 of week 0 is a Monday).
    static func run(_ id: String, week: Int, day: PlanWeekday, minutes: Double,
                    speed: Double = BaselineFixture.easySpeed, outdoor: Bool = true, hour: Int = 7) -> Activity {
        BaselineFixture.run(id, start: BaselineFixture.date(day: week * 7 + day.rawValue, hour: hour),
                            seconds: minutes * 60, speed: speed,
                            hr: { _ in BaselineFixture.hr(atSpeed: speed) }, cadence: 170, outdoor: outdoor)
    }

    /// `weeks` weeks of runs on `days` (minutes per weekday), then `asOf` on
    /// the following Wednesday at noon. `extra` adds runs by hand.
    static func report(weeks: Int, days: [PlanWeekday: Double], extra: [Activity] = [],
                       marks: [EffortMark] = []) -> BaselineReport {
        var acts: [Activity] = []
        for w in 0..<weeks {
            for (day, minutes) in days.sorted(by: { $0.key < $1.key }) {
                acts.append(run("w\(w)-\(day.rawValue)", week: w, day: day, minutes: minutes))
            }
        }
        acts += extra
        let asOf = BaselineFixture.date(day: weeks * 7 + 2, hour: 12)
        return BaselineBuilder.build(activities: acts, efforts: marks,
                                     options: BaselineOptions(asOf: asOf, timeZone: timeZone))
    }

    /// The full F1 fixture runner (Tue, Thu, Sat easy; Sun long; two races; a treadmill run).
    static func fixtureReport(marks: Bool = true, asOf: Date? = nil,
                              change: (inout [Activity]) -> Void = { _ in }) -> BaselineReport {
        let f = BaselineFixture.make()
        var acts = f.activities
        change(&acts)
        return BaselineBuilder.build(activities: acts, efforts: marks ? f.marks : [],
                                     dailyHealth: f.health,
                                     options: BaselineOptions(asOf: asOf ?? BaselineFixture.asOf, timeZone: timeZone))
    }

    static var today: Date { BaselineFixture.asOf }

    /// A Sunday race `weeks` weeks after the week of `today`, at 08:00 local.
    static func raceDay(weeksAhead weeks: Int) -> Date {
        // asOf is a Wednesday (day weeks*7 + 2); the Sunday of its week is day +4.
        BaselineFixture.date(day: BaselineFixture.weeks * 7 + 6 + weeks * 7, hour: 8)
    }

    static let fixtureDays: Set<PlanWeekday> = [.tuesday, .thursday, .saturday, .sunday]

    static func settings(distance: Double = Distance.halfMarathon, weeksAhead: Int = 14,
                         time: GoalTime = .bestPossible, name: String = "Synthetic Half",
                         days: Set<PlanWeekday> = fixtureDays, longRunDay: PlanWeekday = .sunday,
                         maxSession: SessionLimit = .noLimit, treadmill: Bool = true,
                         pain: PainHistory = PainHistory.none) -> GoalSettings {
        GoalSettings(race: GoalRace(name: name, date: raceDay(weeksAhead: weeksAhead), distanceMeters: distance, time: time),
                     schedule: TrainingSchedule(trainingDays: days, longRunDay: longRunDay, maxSession: maxSession),
                     hasTreadmillAccess: treadmill, painHistory: pain)
    }
}
