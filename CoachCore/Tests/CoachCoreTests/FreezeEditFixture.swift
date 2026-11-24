import Foundation
@testable import CoachCore

// Synthetic plans held under a pain freeze, for the goal-edit-in-a-freeze tests
// (SPEC 3.5 rule 7, #72), on the F2 goal fixture's runner. Week 0 is the week of
// `GoalFixture.today` (Monday 2026-09-21; today is that Wednesday at noon).
enum FreezeFixture {
    static let tz = BaselineFixture.timeZone
    static var today: Date { GoalFixture.today }

    /// A session at noon on `day` of week `week`.
    static func at(week: Int, day: PlanWeekday) -> Date {
        BaselineFixture.date(day: BaselineFixture.weeks * 7 + week * 7 + day.rawValue, hour: 12)
    }

    static func monday(week: Int) -> Date { PlanCalendar.weekStart(containing: at(week: week, day: .monday), timeZone: tz) }

    static let easyTarget = WorkoutTarget(
        heartRate: HeartRateTarget(zones: .z1 ... .z2, floorBPM: nil, ceilingBPM: 150), pace: nil, primary: .heartRate)
    static let hardTarget = WorkoutTarget(
        heartRate: HeartRateTarget(zones: .z4 ... .z5a, floorBPM: 160, ceilingBPM: 175), pace: nil, primary: .heartRate)

    static func segments(_ kind: PlannedWorkout.Kind, minutes: Double) -> [WorkoutSegment] {
        let s = minutes * 60
        func seg(_ role: WorkoutSegment.Role, _ intensity: WorkoutIntensity, _ seconds: Double) -> WorkoutSegment {
            WorkoutSegment(role: role, intensity: intensity, durationSeconds: seconds,
                           target: intensity.isBelowAerobicThreshold ? easyTarget : hardTarget)
        }
        if kind.isQuality {
            return [seg(.warmUp, .easy, 0.3 * s), seg(.main, .threshold, 0.4 * s), seg(.coolDown, .easy, 0.3 * s)]
        }
        return [seg(.main, .easy, s)]
    }

    static func session(_ id: String, week: Int, _ day: PlanWeekday, _ kind: PlannedWorkout.Kind, minutes: Double,
                        phase: PlanPhase = .build) -> PlannedWorkout {
        let p = WorkoutPrescription(purpose: "Held session \(id).", phase: phase,
                                    segments: segments(kind, minutes: minutes), rules: [.weeklyProgression])
        return PlannedWorkout(id: id, date: at(week: week, day: day), kind: kind, durationSeconds: minutes * 60,
                              prescription: p)
    }

    /// The rest of the current week as the old plan keeps it: 125 minutes (Thu, Sat, Sun).
    static var currentWeekRest: [PlannedWorkout] {
        [session("old-w0-thu", week: 0, .thursday, .easy, minutes: 35),
         session("old-w0-sat", week: 0, .saturday, .easy, minutes: 35),
         session("old-w0-sun", week: 0, .sunday, .long, minutes: 55)]
    }

    /// The frozen week after it as the engine holds it: 120 minutes (77% of the
    /// 155 the week before ends at, so a recovery week too), its
    /// Thursday quality session swapped for easy running by the check-in.
    static var frozenWeek: [PlannedWorkout] {
        let swapped = session("old-w1-thu", week: 1, .thursday, .quality(.threshold), minutes: 30)
            .swappedToEasyKeepingTarget(reason: "pain 5/10 (SPEC 3.5).")
        return [session("old-w1-tue", week: 1, .tuesday, .easy, minutes: 25), swapped,
                session("old-w1-sat", week: 1, .saturday, .easy, minutes: 25),
                session("old-w1-sun", week: 1, .sunday, .long, minutes: 40)]
    }

    /// The freeze from yesterday's check-in: seven days, to next Tuesday noon.
    static var freeze: DateInterval {
        DateInterval(start: at(week: 0, day: .tuesday), end: at(week: 1, day: .tuesday))
    }

    /// A baseline with a Monday run of 30 minutes, so the week the plan starts after has a known volume.
    static func report() -> BaselineReport {
        GoalFixture.fixtureReport(change: { acts in
            acts.append(GoalFixture.run("mon-run", week: BaselineFixture.weeks, day: .monday, minutes: 30))
        })
    }

    static func hold(pendingSwap: QualitySwap? = nil, extra: [PlannedWorkout] = []) -> FreezeHold {
        FreezeHold(freezes: [freeze], sessions: currentWeekRest + frozenWeek + extra, pendingSwap: pendingSwap)
    }

    static let painful = GoalFixture.settings(weeksAhead: 14, pain: .recurring(areas: ["shin"]))
}
