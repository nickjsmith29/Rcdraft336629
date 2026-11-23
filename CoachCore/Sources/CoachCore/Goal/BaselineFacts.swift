import Foundation

/// The goal interview's tunable numbers (SPEC.md F2). **Every value here is a
/// heuristic**, chosen to be conservative: when the history doesn't show a
/// clear pattern, the interview asks instead of guessing. None stands for a
/// particular runner.
public enum GoalHeuristics {
    /// How many of the most recent complete weeks the schedule is read from.
    public static let patternWeeks = 4
    /// A weekday is a usual training day when the runner ran on it in at least
    /// this share of the pattern weeks (3 of 4).
    public static let trainingDayMinimumShare = 0.75
    /// The usual days must hold at least this share of the pattern weeks' runs;
    /// below it the runner's days vary too much to call.
    public static let patternMinimumCoverage = 0.9
    /// A weekday is the usual long-run day when the week's long run fell on it
    /// in at least this share of the pattern weeks.
    public static let longRunDayMinimumShare = 0.75
    /// A week's longest run counts as a distinct long run only when it is at
    /// least this many times the mean of the week's other runs.
    public static let longRunMinimumRatio = 1.25
    /// Treadmill runs within this many days before the baseline show the
    /// runner has treadmill access (SPEC 3.8).
    public static let treadmillLookbackDays = 90
    /// Marked races within this many days before the baseline can anchor
    /// training paces (the best-effort window of SPEC 3.9).
    public static let anchorLookbackDays = BlendedPredictor.defaultLookbackDays
    /// A plan is built only from a baseline made at most this long before
    /// `today` (and on the same day). A run synced in between would be missing
    /// from the history, and the plan could then break SPEC 3.5 against the
    /// runner's real history. Ten minutes covers finishing the interview right
    /// after the app built the baseline.
    public static let maximumBaselineAgeSeconds: Double = 10 * 60
}

/// A value the baseline shows, with the runs that show it (F1 evidence).
public struct ObservedFact<Value: Equatable & Sendable>: Equatable, Sendable {
    public let value: Value
    public let evidenceActivityIDs: [String]

    public init(value: Value, evidenceActivityIDs: [String]) {
        self.value = value
        self.evidenceActivityIDs = evidenceActivityIDs
    }
}

/// What the F1 baseline already answers for the goal interview (F2), so the
/// interview never asks it. Each fact is nil when the history doesn't show it
/// clearly; the interview then asks. The race, its date, distance and time
/// goal, the session limit and pain history never come from the data: only
/// the runner sets those.
public struct BaselineFacts: Equatable, Sendable {
    /// The weekdays the runner usually trains on (SPEC 2: typical training days).
    public let trainingDays: ObservedFact<Set<PlanWeekday>>?
    /// The weekday of the runner's usual long run.
    public let longRunDay: ObservedFact<PlanWeekday>?
    /// True when recent history has a treadmill run. No treadmill run does not
    /// show the runner has no access, so that case is nil and asked. Not used
    /// by the plan builder until F8 (SPEC 3.8).
    public let treadmillAccess: ObservedFact<Bool>?

    public init(trainingDays: ObservedFact<Set<PlanWeekday>>? = nil,
                longRunDay: ObservedFact<PlanWeekday>? = nil,
                treadmillAccess: ObservedFact<Bool>? = nil) {
        self.trainingDays = trainingDays
        self.longRunDay = longRunDay
        self.treadmillAccess = treadmillAccess
    }

    /// Nothing known (a runner with no usable history).
    public static let none = BaselineFacts()

    /// Reads the facts from a baseline report.
    ///
    /// Heuristics (`GoalHeuristics`):
    /// - **Training days:** from the last `patternWeeks` complete weeks of the
    ///   weekly load. A weekday counts when it had a run in at least 75% of
    ///   them, the counted days hold at least 90% of the runs, and there are at
    ///   least `PlanHeuristics.minimumTrainingDays` of them. Fewer complete
    ///   weeks, or a scattered pattern, leaves it unknown.
    /// - **Long-run day:** the weekday of each of those weeks' longest run, when
    ///   that run is at least 1.25 times the mean of the week's other runs; one
    ///   weekday must hold at least 75% of the weeks.
    /// - **Treadmill access:** any treadmill run (SPEC 3.8 tagging) in the last
    ///   90 days.
    public static func from(_ report: BaselineReport) -> BaselineFacts {
        let tz = report.timeZone
        let runsByID = Dictionary(report.runs.map { ($0.activityID, $0) }, uniquingKeysWith: { a, _ in a })

        var days: ObservedFact<Set<PlanWeekday>>?
        var longDay: ObservedFact<PlanWeekday>?
        if let load = report.weeklyLoad.value {
            let weeks = Array(load.weeks.filter(\.isComplete).suffix(GoalHeuristics.patternWeeks))
            if weeks.count == GoalHeuristics.patternWeeks {
                days = trainingDays(weeks: weeks, runs: runsByID, timeZone: tz)
                longDay = longRunDay(weeks: weeks, runs: runsByID, timeZone: tz)
            }
        }

        let since = report.asOf.addingTimeInterval(-Double(GoalHeuristics.treadmillLookbackDays) * 86_400)
        let treadmillIDs = report.runs.filter { $0.isTreadmill && $0.start >= since && $0.start <= report.asOf }
            .map(\.activityID)
        let treadmill = treadmillIDs.isEmpty ? nil : ObservedFact(value: true, evidenceActivityIDs: treadmillIDs)
        return BaselineFacts(trainingDays: days, longRunDay: longDay, treadmillAccess: treadmill)
    }

    static func trainingDays(weeks: [WeekLoad], runs: [String: BaselineRun],
                             timeZone: TimeZone) -> ObservedFact<Set<PlanWeekday>>? {
        var weeksWithDay: [PlanWeekday: Int] = [:]
        var runDays: [(id: String, day: PlanWeekday)] = []
        for week in weeks {
            var seen = Set<PlanWeekday>()
            for id in week.activityIDs {
                guard let run = runs[id] else { continue }
                let day = PlanWeekday(of: run.start, timeZone: timeZone)
                runDays.append((id, day))
                seen.insert(day)
            }
            for d in seen { weeksWithDay[d, default: 0] += 1 }
        }
        guard !runDays.isEmpty else { return nil }
        let needed = GoalHeuristics.trainingDayMinimumShare * Double(weeks.count)
        let usual = Set(weeksWithDay.filter { Double($0.value) >= needed - 1e-9 }.keys)
        guard usual.count >= PlanHeuristics.minimumTrainingDays else { return nil }
        let covered = runDays.filter { usual.contains($0.day) }.count
        guard Double(covered) / Double(runDays.count) >= GoalHeuristics.patternMinimumCoverage - 1e-9 else { return nil }
        return ObservedFact(value: usual, evidenceActivityIDs: runDays.map(\.id))
    }

    static func longRunDay(weeks: [WeekLoad], runs: [String: BaselineRun],
                           timeZone: TimeZone) -> ObservedFact<PlanWeekday>? {
        var byDay: [PlanWeekday: [String]] = [:]
        for week in weeks {
            let weekRuns = week.activityIDs.compactMap { runs[$0] }
                .filter { $0.movingSeconds.isFinite && $0.movingSeconds > 0 }
            guard weekRuns.count >= 2,
                  let longest = weekRuns.max(by: { ($0.movingSeconds, $1.activityID) < ($1.movingSeconds, $0.activityID) })
            else { continue }
            let others = weekRuns.filter { $0.activityID != longest.activityID }
            let mean = others.reduce(0) { $0 + $1.movingSeconds } / Double(others.count)
            guard longest.movingSeconds >= GoalHeuristics.longRunMinimumRatio * mean - 1e-6 else { continue }
            byDay[PlanWeekday(of: longest.start, timeZone: timeZone), default: []].append(longest.activityID)
        }
        let needed = GoalHeuristics.longRunDayMinimumShare * Double(weeks.count)
        guard let best = byDay.max(by: { ($0.value.count, $1.key) < ($1.value.count, $0.key) }),
              Double(best.value.count) >= needed - 1e-9 else { return nil }
        return ObservedFact(value: best.key, evidenceActivityIDs: best.value)
    }
}
