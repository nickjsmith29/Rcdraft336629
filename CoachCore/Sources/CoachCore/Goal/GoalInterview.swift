// TimeZone is Sendable on Apple SDKs but not yet in swift-corelibs-foundation
// (Linux, Swift 5.10); @preconcurrency keeps GoalInterview's Sendable conformance warning-free there.
@preconcurrency import Foundation

/// One question of the goal interview (F2), in the order they are asked.
/// The LLM layer words each question; CoachCore only decides which one comes
/// next and checks the answer.
public enum GoalQuestion: String, CaseIterable, Equatable, Hashable, Sendable {
    case raceName
    case raceDate
    case raceDistance
    /// A finish time, or "best possible".
    case goalTime
    case trainingDays
    case longRunDay
    case maxSessionLength
    case treadmillAccess
    case painHistory
}

/// One answer from the runner.
public enum GoalAnswer: Equatable, Hashable, Sendable {
    case raceName(String)
    case raceDate(Date)
    case raceDistance(meters: Double)
    case goalTime(GoalTime)
    case trainingDays(Set<PlanWeekday>)
    case longRunDay(PlanWeekday)
    case maxSessionLength(SessionLimit)
    case treadmillAccess(Bool)
    case painHistory(PainHistory)

    /// The question this answers.
    public var question: GoalQuestion {
        switch self {
        case .raceName: return .raceName
        case .raceDate: return .raceDate
        case .raceDistance: return .raceDistance
        case .goalTime: return .goalTime
        case .trainingDays: return .trainingDays
        case .longRunDay: return .longRunDay
        case .maxSessionLength: return .maxSessionLength
        case .treadmillAccess: return .treadmillAccess
        case .painHistory: return .painHistory
        }
    }
}

/// The runner's answers so far; nil means not answered.
public struct GoalAnswers: Equatable, Hashable, Sendable {
    public var raceName: String?
    public var raceDate: Date?
    public var raceDistanceMeters: Double?
    public var goalTime: GoalTime?
    public var trainingDays: Set<PlanWeekday>?
    public var longRunDay: PlanWeekday?
    public var maxSession: SessionLimit?
    public var treadmillAccess: Bool?
    public var painHistory: PainHistory?

    public init(raceName: String? = nil, raceDate: Date? = nil, raceDistanceMeters: Double? = nil,
                goalTime: GoalTime? = nil, trainingDays: Set<PlanWeekday>? = nil, longRunDay: PlanWeekday? = nil,
                maxSession: SessionLimit? = nil, treadmillAccess: Bool? = nil, painHistory: PainHistory? = nil) {
        self.raceName = raceName
        self.raceDate = raceDate
        self.raceDistanceMeters = raceDistanceMeters
        self.goalTime = goalTime
        self.trainingDays = trainingDays
        self.longRunDay = longRunDay
        self.maxSession = maxSession
        self.treadmillAccess = treadmillAccess
        self.painHistory = painHistory
    }

    /// Every answer taken from saved settings, for example to resume or edit.
    public init(settings s: GoalSettings) {
        self.init(raceName: s.race.name, raceDate: s.race.date, raceDistanceMeters: s.race.distanceMeters,
                  goalTime: s.race.time, trainingDays: s.schedule.trainingDays, longRunDay: s.schedule.longRunDay,
                  maxSession: s.schedule.maxSession, treadmillAccess: s.hasTreadmillAccess, painHistory: s.painHistory)
    }
}

/// Where a known value came from.
public enum GoalFactSource: Equatable, Hashable, Sendable {
    /// The runner answered it.
    case runner
    /// The baseline shows it (`BaselineFacts`); the app can show it for the
    /// runner to confirm or change, but doesn't ask.
    case baseline
}

public enum GoalAnswerOutcome: Equatable, Sendable {
    /// Saved. `cleared` lists earlier answers this one made invalid; they are
    /// asked again (for example a long-run day that is no longer a training
    /// day, or a race date too close or a goal time implausible for a new distance).
    case accepted(cleared: [GoalQuestion])
    /// Not saved; the question stays open.
    case rejected(GoalProblem)
}

/// Where the interview stands.
public enum GoalInterviewResult: Equatable, Sendable {
    case complete(GoalSettings)
    /// Questions still to ask, in order.
    case incomplete([GoalQuestion])
    /// Every question is answered or known, but some saved values no longer
    /// pass the checks as of today (for example a race date now passed).
    case invalid([GoalProblem])
}

/// The goal interview (SPEC.md F2) as a state machine: it asks only what the
/// runner's data can't answer, one question at a time, and skips anything
/// already known, from the baseline (`BaselineFacts`) or an earlier answer.
///
/// Answers can come in any order (a runner may give the race and its date in
/// one reply); each is checked as it arrives. A runner's answer always wins
/// over what the baseline shows.
public struct GoalInterview: Equatable, Sendable {
    public let facts: BaselineFacts
    /// The runner's time zone, for counting plan weeks to the race.
    public let timeZone: TimeZone
    public private(set) var answers: GoalAnswers

    public init(facts: BaselineFacts, timeZone: TimeZone, answers: GoalAnswers = GoalAnswers()) {
        self.facts = facts
        self.timeZone = timeZone
        self.answers = answers
    }

    public init(baseline: BaselineReport, answers: GoalAnswers = GoalAnswers()) {
        self.init(facts: .from(baseline), timeZone: baseline.timeZone, answers: answers)
    }

    // MARK: Resolved values

    /// The training days: the runner's answer, else what the baseline shows.
    public var trainingDays: Set<PlanWeekday>? { answers.trainingDays ?? facts.trainingDays?.value }

    /// The long-run day: the runner's answer, else the baseline's, as long as
    /// it is one of the training days (when those are known).
    public var longRunDay: PlanWeekday? {
        if let day = answers.longRunDay { return day }
        guard let day = facts.longRunDay?.value else { return nil }
        if let days = trainingDays, !days.contains(day) { return nil }
        return day
    }

    public var hasTreadmillAccess: Bool? { answers.treadmillAccess ?? facts.treadmillAccess?.value }

    /// Where the value for `question` comes from, or nil while it is unknown.
    public func source(of question: GoalQuestion) -> GoalFactSource? {
        switch question {
        case .raceName: return answers.raceName == nil ? nil : .runner
        case .raceDate: return answers.raceDate == nil ? nil : .runner
        case .raceDistance: return answers.raceDistanceMeters == nil ? nil : .runner
        case .goalTime: return answers.goalTime == nil ? nil : .runner
        case .maxSessionLength: return answers.maxSession == nil ? nil : .runner
        case .painHistory: return answers.painHistory == nil ? nil : .runner
        case .trainingDays:
            if answers.trainingDays != nil { return .runner }
            return facts.trainingDays == nil ? nil : .baseline
        case .longRunDay:
            if answers.longRunDay != nil { return .runner }
            return longRunDay == nil ? nil : .baseline
        case .treadmillAccess:
            if answers.treadmillAccess != nil { return .runner }
            return facts.treadmillAccess == nil ? nil : .baseline
        }
    }

    // MARK: Questions

    /// Questions still open, in the order they will be asked.
    public var pendingQuestions: [GoalQuestion] {
        GoalQuestion.allCases.filter { source(of: $0) == nil }
    }

    /// The one question to ask now, or nil when everything is known.
    public var nextQuestion: GoalQuestion? { pendingQuestions.first }

    public var isComplete: Bool { pendingQuestions.isEmpty }

    // MARK: Answering

    /// Checks and saves one answer. `today` is the day the race date must be after.
    @discardableResult
    public mutating func answer(_ answer: GoalAnswer, today: Date) -> GoalAnswerOutcome {
        var cleared: [GoalQuestion] = []
        switch answer {
        case .raceName(let name):
            if let p = GoalValidation.raceName(name) { return .rejected(p) }
            answers.raceName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        case .raceDate(let date):
            if let p = GoalValidation.raceDate(date, today: today, distanceMeters: answers.raceDistanceMeters,
                                               timeZone: timeZone) { return .rejected(p) }
            answers.raceDate = date
        case .raceDistance(let meters):
            if let p = GoalValidation.distance(meters) { return .rejected(p) }
            answers.raceDistanceMeters = meters
            if let d = answers.raceDate,
               GoalValidation.raceDate(d, today: today, distanceMeters: meters, timeZone: timeZone) != nil {
                answers.raceDate = nil
                cleared.append(.raceDate)
            }
            if let t = answers.goalTime, GoalValidation.goalTime(t, distanceMeters: meters) != nil {
                answers.goalTime = nil
                cleared.append(.goalTime)
            }
        case .goalTime(let time):
            if let p = GoalValidation.goalTime(time, distanceMeters: answers.raceDistanceMeters) { return .rejected(p) }
            answers.goalTime = time
        case .trainingDays(let days):
            if let p = GoalValidation.trainingDays(days) { return .rejected(p) }
            answers.trainingDays = days
            if let day = answers.longRunDay, !days.contains(day) {
                answers.longRunDay = nil
                cleared.append(.longRunDay)
            }
        case .longRunDay(let day):
            if let days = trainingDays, !days.contains(day) { return .rejected(.longRunDayNotATrainingDay) }
            answers.longRunDay = day
        case .maxSessionLength(let limit):
            if let p = GoalValidation.sessionLimit(limit) { return .rejected(p) }
            answers.maxSession = limit
        case .treadmillAccess(let access):
            answers.treadmillAccess = access
        case .painHistory(let history):
            if let p = GoalValidation.painHistory(history) { return .rejected(p) }
            if case .recurring(let areas) = history {
                let named = areas.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                answers.painHistory = .recurring(areas: named)
            } else {
                answers.painHistory = history
            }
        }
        return .accepted(cleared: cleared)
    }

    /// The finished settings, the questions still open, or what no longer
    /// passes the checks as of `today`.
    public func result(today: Date) -> GoalInterviewResult {
        let pending = pendingQuestions
        guard pending.isEmpty,
              let name = answers.raceName, let date = answers.raceDate, let meters = answers.raceDistanceMeters,
              let time = answers.goalTime, let days = trainingDays, let longDay = longRunDay,
              let limit = answers.maxSession, let treadmill = hasTreadmillAccess, let pain = answers.painHistory
        else { return .incomplete(pending) }
        let settings = GoalSettings(race: GoalRace(name: name, date: date, distanceMeters: meters, time: time),
                                    schedule: TrainingSchedule(trainingDays: days, longRunDay: longDay, maxSession: limit),
                                    hasTreadmillAccess: treadmill, painHistory: pain)
        let problems = settings.problems(today: today, timeZone: timeZone)
        return problems.isEmpty ? .complete(settings) : .invalid(problems)
    }
}
