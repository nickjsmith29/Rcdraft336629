import Foundation

/// A day of the training week, Monday first (ISO 8601, like `PlanCalendar`).
public enum PlanWeekday: Int, CaseIterable, Comparable, Hashable, Sendable {
    case monday = 0, tuesday, wednesday, thursday, friday, saturday, sunday

    public static func < (lhs: PlanWeekday, rhs: PlanWeekday) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The weekday of `date` in `timeZone`.
    public init(of date: Date, timeZone: TimeZone) {
        let weekday = PlanCalendar.calendar(timeZone: timeZone).component(.weekday, from: date)
        // Gregorian weekday: 1 = Sunday ... 7 = Saturday.
        self = PlanWeekday(rawValue: (weekday + 5) % 7) ?? .monday
    }
}

/// A race performance, done or predicted, used as the anchor for training
/// paces (SPEC.md 3.9). Riegel is calibrated up to the half marathon, so the
/// builder only uses an anchor between 3 km and the half marathon.
public struct RaceEquivalent: Equatable, Hashable, Sendable {
    public let distanceMeters: Double
    public let seconds: Double

    public init(distanceMeters: Double, seconds: Double) {
        self.distanceMeters = distanceMeters
        self.seconds = seconds
    }
}

/// The runner's easy pace at a given heart rate, from their own easy runs (F1, SPEC 2).
public struct EasyPaceSample: Equatable, Hashable, Sendable {
    /// Flat (or grade-adjusted) pace in seconds per kilometre.
    public let secondsPerKm: Double
    /// The heart rate that pace was run at, in bpm.
    public let heartRate: Double

    public init(secondsPerKm: Double, heartRate: Double) {
        self.secondsPerKm = secondsPerKm
        self.heartRate = heartRate
    }
}

/// Everything the plan builder (F3) needs, and nothing more: the goal and
/// schedule from the goal interview (F2) and a few values from the baseline
/// (F1). The baseline report maps into this type; there are no defaults that
/// stand for a particular runner, and optional values left nil are treated as
/// unknown, never guessed.
public struct PlanInput: Equatable, Sendable {
    /// Names of the input values, for `PlanBuildIssue.invalidValue`.
    public enum Field: String, Equatable, Hashable, Sendable {
        case raceDistanceMeters, goalSeconds, maxSessionSeconds, recentWeeklySeconds,
             recentLongRunSeconds, easyPace, fitnessAnchor, predictedRaceSeconds, anchorEfforts
    }

    // MARK: Goal (F2)

    /// Goal race distance in meters, 5 km to the marathon.
    public var raceDistanceMeters: Double
    /// When the race starts.
    public var raceDate: Date
    /// The athlete's time goal in seconds, or nil for "best possible".
    public var goalSeconds: Double?

    // MARK: Schedule (F2)

    /// The first moment the plan may use (usually now). The plan starts on
    /// the next Monday, so its first week is a whole week, or on this day
    /// when it is a Monday no later than noon with no run logged yet.
    public var startDate: Date
    /// The days the runner can train.
    public var trainingDays: Set<PlanWeekday>
    /// The day for the long run; must be one of `trainingDays`.
    public var longRunDay: PlanWeekday
    /// Longest single session the runner can fit, in seconds, or nil for no limit.
    public var maxSessionSeconds: Double?

    // MARK: Baseline (F1)

    /// Typical recent weekly running time in seconds (moving time): the mean
    /// of the last 4 complete weeks, zero weeks included. The plan starts from
    /// this level. It must agree with the history given to the builder, which
    /// refuses a value well above the history's own mean
    /// (`PlanBuildIssue.recentVolumeDisagreesWithHistory`).
    public var recentWeeklySeconds: Double?
    /// The **typical** recent long run in seconds: the usual length of the
    /// weekly long run over the last 4 weeks or so (the median, say), not a
    /// one-off longest run. Long runs grow from it, at most 10 minutes a week.
    /// When nil, they grow from an average session of the recent week instead.
    public var recentLongRunSeconds: Double?
    /// The runner's heart-rate zones (from their LTHR, SPEC 3.2). Required:
    /// with no LTHR the app schedules a field test first (cold start, SPEC 2).
    public var heartRateZones: HRZones?
    /// Easy pace at an easy heart rate, when known. Gives easy runs a pace guide.
    public var easyPace: EasyPaceSample?
    /// A recent race, or a predicted time at a distance from 3 km to the half
    /// marathon, used for threshold and VO2max paces. When nil, those sessions
    /// have heart-rate targets only.
    public var fitnessAnchor: RaceEquivalent?
    /// Current-fitness prediction for the goal distance in seconds (for example
    /// the central value of `BlendedPrediction`, SPEC 3.9). Used for race pace
    /// and the race's duration. When nil, the builder derives it from the
    /// fitness anchor: Riegel up to the half marathon; for a marathon,
    /// Vickers-Vertosick, which needs an anchor of 5K or more and `easyPace`.
    /// Pass it for a marathon whenever the baseline has one.
    public var predictedRaceSeconds: Double?
    /// The efforts that qualify as an anchor, with their dates and whether
    /// each is a marked race (`BaselinePlanMapping.anchorEfforts`). The
    /// builder reads them only for the paces after a break (SPEC 3.5 rule 4):
    /// the anchor from before the break (no training pace may be faster than
    /// it through the third week back) and a marked race after the break,
    /// which becomes the anchor and ends the return factor. Leaving a marked
    /// race after a longer break out means the factor holds (errs slow). Empty means no
    /// dated efforts are known: `fitnessAnchor` is then treated as an anchor
    /// from before the break, so the factor applies to it in full.
    public var anchorEfforts: [AnchorEffort]

    public init(raceDistanceMeters: Double,
                raceDate: Date,
                goalSeconds: Double? = nil,
                startDate: Date,
                trainingDays: Set<PlanWeekday>,
                longRunDay: PlanWeekday,
                maxSessionSeconds: Double? = nil,
                recentWeeklySeconds: Double?,
                recentLongRunSeconds: Double? = nil,
                heartRateZones: HRZones?,
                easyPace: EasyPaceSample? = nil,
                fitnessAnchor: RaceEquivalent? = nil,
                predictedRaceSeconds: Double? = nil,
                anchorEfforts: [AnchorEffort] = []) {
        self.raceDistanceMeters = raceDistanceMeters
        self.raceDate = raceDate
        self.goalSeconds = goalSeconds
        self.startDate = startDate
        self.trainingDays = trainingDays
        self.longRunDay = longRunDay
        self.maxSessionSeconds = maxSessionSeconds
        self.recentWeeklySeconds = recentWeeklySeconds
        self.recentLongRunSeconds = recentLongRunSeconds
        self.heartRateZones = heartRateZones
        self.easyPace = easyPace
        self.fitnessAnchor = fitnessAnchor
        self.predictedRaceSeconds = predictedRaceSeconds
        self.anchorEfforts = anchorEfforts
    }
}
