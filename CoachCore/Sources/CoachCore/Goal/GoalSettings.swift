import Foundation

/// The runner's time goal for the race (SPEC.md F2): a finish time, or
/// "best possible" when they want the plan to aim at what their fitness allows.
public enum GoalTime: Equatable, Hashable, Sendable {
    case seconds(Double)
    case bestPossible

    /// The goal in seconds, or nil for "best possible" (what `PlanInput.goalSeconds` takes).
    public var seconds: Double? {
        if case .seconds(let s) = self { return s }
        return nil
    }
}

/// The goal race, always set by the runner (F2). Nothing here has a default:
/// the app has no race of its own and never picks one for the runner.
public struct GoalRace: Equatable, Hashable, Sendable {
    /// The race's name as the runner gave it.
    public var name: String
    /// When the race starts.
    public var date: Date
    /// Race distance in meters, 5 km to the marathon (`RaceCategory`).
    public var distanceMeters: Double
    public var time: GoalTime

    public init(name: String, date: Date, distanceMeters: Double, time: GoalTime) {
        self.name = name
        self.date = date
        self.distanceMeters = distanceMeters
        self.time = time
    }
}

/// The longest session the runner can fit (F2), or no limit.
public enum SessionLimit: Equatable, Hashable, Sendable {
    case noLimit
    case seconds(Double)

    /// What `PlanInput.maxSessionSeconds` takes: nil for no limit.
    public var seconds: Double? {
        if case .seconds(let s) = self { return s }
        return nil
    }
}

/// When the runner can train (F2).
public struct TrainingSchedule: Equatable, Hashable, Sendable {
    public var trainingDays: Set<PlanWeekday>
    /// Must be one of `trainingDays`.
    public var longRunDay: PlanWeekday
    public var maxSession: SessionLimit

    public init(trainingDays: Set<PlanWeekday>, longRunDay: PlanWeekday, maxSession: SessionLimit) {
        self.trainingDays = trainingDays
        self.longRunDay = longRunDay
        self.maxSession = maxSession
    }
}

/// Whether the runner reports a recurring pain or injury area (F2, SPEC.md 3.5).
/// Only a runner who reports one gets the pain check-in after long runs and
/// quality sessions. The app records the area as the runner names it and does
/// not diagnose.
public enum PainHistory: Equatable, Hashable, Sendable {
    case none
    /// One or more areas in the runner's own words (for example "left knee").
    case recurring(areas: [String])

    /// True when the pain check-in applies (`PainCheckInRule.evaluate(tracksPain:...)`).
    public var tracksPain: Bool {
        if case .recurring = self { return true }
        return false
    }
}

/// Everything the goal interview (F2) settles: the race, the schedule, treadmill
/// access (F8, SPEC 3.8) and pain history (3.5). Editable anytime in Settings;
/// an edit re-plans from today (`GoalPlanner.replan`).
public struct GoalSettings: Equatable, Hashable, Sendable {
    public var race: GoalRace
    public var schedule: TrainingSchedule
    /// Collected now for treadmill targets (F8, SPEC 3.8). `PlanInput` has no
    /// treadmill field yet, so it doesn't change the plan until F8 lands.
    public var hasTreadmillAccess: Bool
    public var painHistory: PainHistory

    public init(race: GoalRace, schedule: TrainingSchedule, hasTreadmillAccess: Bool, painHistory: PainHistory) {
        self.race = race
        self.schedule = schedule
        self.hasTreadmillAccess = hasTreadmillAccess
        self.painHistory = painHistory
    }

    /// Every problem with these settings as of `today`, or an empty list.
    /// The same checks the interview applies to each answer. `timeZone` is the
    /// runner's, for counting plan weeks (`PlanCalendar`).
    public func problems(today: Date, timeZone: TimeZone) -> [GoalProblem] {
        var out: [GoalProblem] = []
        out += GoalValidation.raceName(race.name).map { [$0] } ?? []
        out += GoalValidation.raceDate(race.date, today: today, distanceMeters: race.distanceMeters,
                                       timeZone: timeZone).map { [$0] } ?? []
        out += GoalValidation.distance(race.distanceMeters).map { [$0] } ?? []
        out += GoalValidation.goalTime(race.time, distanceMeters: race.distanceMeters).map { [$0] } ?? []
        out += GoalValidation.trainingDays(schedule.trainingDays).map { [$0] } ?? []
        if !schedule.trainingDays.contains(schedule.longRunDay) { out.append(.longRunDayNotATrainingDay) }
        out += GoalValidation.sessionLimit(schedule.maxSession).map { [$0] } ?? []
        out += GoalValidation.painHistory(painHistory).map { [$0] } ?? []
        return out
    }
}

/// Why an answer or a goal edit was refused. Each one names what the runner
/// needs to change; nothing is silently corrected.
public enum GoalProblem: Equatable, Hashable, Sendable {
    /// The race name is empty after trimming spaces.
    case emptyRaceName
    /// The race date is not a finite date.
    case invalidRaceDate
    /// The race date is not after today.
    case raceDateNotAfterToday
    /// Too few plan weeks (race week included) for the distance
    /// (`PlanHeuristics.minimumWeeks`); without a distance yet, too few for
    /// any distance. Same count as the plan builder: the plan starts on the
    /// Monday after today (or today, on a Monday no later than noon).
    case leadTimeTooShort(weeks: Int, minimumWeeks: Int)
    /// More plan weeks than `PlanHeuristics.maximumWeeks`.
    case leadTimeTooLong(weeks: Int, maximumWeeks: Int)
    /// The distance is not a finite number from 5 km to the marathon (F3).
    case unsupportedDistance(meters: Double)
    /// The goal time is not a finite positive number of seconds.
    case invalidGoalTime
    /// The goal time means an average speed outside
    /// `BlendedPredictor.plausibleSpeed` for the distance.
    case implausibleGoalTime(seconds: Double, distanceMeters: Double)
    case tooFewTrainingDays(count: Int, minimum: Int)
    case longRunDayNotATrainingDay
    /// The session limit is not a finite positive number of seconds.
    case invalidSessionLimit
    /// Shorter than `PlanHeuristics.minimumSessionSeconds`.
    case sessionLimitTooShort(seconds: Double, minimumSeconds: Double)
    /// A recurring pain history with no named area.
    case noPainArea
}

enum GoalValidation {
    static func raceName(_ name: String) -> GoalProblem? {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .emptyRaceName : nil
    }

    /// Checks the date and the lead time. With no supported distance, the
    /// shortest minimum of any distance is used, and the interview checks
    /// again once the distance is known.
    ///
    /// The count follows `PlanBuilder` without history: on a Monday morning
    /// with a run already logged, the builder starts a week later and can still
    /// refuse a race one week short; it says so with its own issue.
    static func raceDate(_ date: Date, today: Date, distanceMeters: Double?, timeZone: TimeZone) -> GoalProblem? {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return .invalidRaceDate }
        guard today.timeIntervalSinceReferenceDate.isFinite, date > today else { return .raceDateNotAfterToday }
        let weeks = planWeeks(today: today, race: date, timeZone: timeZone)
        if weeks > PlanHeuristics.maximumWeeks {
            return .leadTimeTooLong(weeks: weeks, maximumWeeks: PlanHeuristics.maximumWeeks)
        }
        let minimum = distanceMeters.flatMap { RaceCategory(meters: $0) }.map(PlanHeuristics.minimumWeeks)
            ?? RaceCategory.allCases.map(PlanHeuristics.minimumWeeks).min() ?? 1
        return weeks < minimum ? .leadTimeTooShort(weeks: weeks, minimumWeeks: minimum) : nil
    }

    /// Plan weeks from today to the race week, race week included, as
    /// `PlanBuilder` counts them with no run logged today. Stops counting
    /// past `PlanHeuristics.maximumWeeks`.
    static func planWeeks(today: Date, race: Date, timeZone: TimeZone) -> Int {
        let cal = PlanCalendar.calendar(timeZone: timeZone)
        let startWeek = PlanCalendar.weekStart(containing: today, timeZone: timeZone)
        let mondayNoon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: startWeek) ?? startWeek.addingTimeInterval(12 * 3600)
        let mondayOpen = cal.startOfDay(for: today) == startWeek && today <= mondayNoon
        var w = mondayOpen ? startWeek : PlanCalendar.nextWeekStart(after: startWeek, timeZone: timeZone)
        let raceWeek = PlanCalendar.weekStart(containing: race, timeZone: timeZone)
        var count = 0
        while w <= raceWeek && count <= PlanHeuristics.maximumWeeks {
            count += 1
            w = PlanCalendar.nextWeekStart(after: w, timeZone: timeZone)
        }
        return count
    }

    static func distance(_ meters: Double) -> GoalProblem? {
        RaceCategory(meters: meters) == nil ? .unsupportedDistance(meters: meters) : nil
    }

    /// Checks speed only when the distance is a supported one (else only the number itself).
    static func goalTime(_ time: GoalTime, distanceMeters: Double?) -> GoalProblem? {
        guard let s = time.seconds else { return nil }
        guard s.isFinite, s > 0 else { return .invalidGoalTime }
        guard let d = distanceMeters, RaceCategory(meters: d) != nil else { return nil }
        return BlendedPredictor.plausibleSpeed.contains(d / s) ? nil : .implausibleGoalTime(seconds: s, distanceMeters: d)
    }

    static func trainingDays(_ days: Set<PlanWeekday>) -> GoalProblem? {
        days.count < PlanHeuristics.minimumTrainingDays
            ? .tooFewTrainingDays(count: days.count, minimum: PlanHeuristics.minimumTrainingDays) : nil
    }

    static func sessionLimit(_ limit: SessionLimit) -> GoalProblem? {
        guard let s = limit.seconds else { return nil }
        guard s.isFinite, s > 0 else { return .invalidSessionLimit }
        return s < PlanHeuristics.minimumSessionSeconds
            ? .sessionLimitTooShort(seconds: s, minimumSeconds: PlanHeuristics.minimumSessionSeconds) : nil
    }

    static func painHistory(_ history: PainHistory) -> GoalProblem? {
        guard case .recurring(let areas) = history else { return nil }
        let named = areas.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return named ? nil : .noPainArea
    }
}
