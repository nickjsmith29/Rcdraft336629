import Foundation

/// The phase of a periodized plan (SPEC.md F3).
public enum PlanPhase: String, CaseIterable, Equatable, Hashable, Sendable {
    /// Aerobic volume first, one light quality session.
    case base
    /// Volume keeps growing; two quality sessions (threshold and VO2max work).
    case build
    /// Volume holds at its highest; quality turns race-specific.
    case peak
    /// Volume drops so the runner arrives fresh; the race week is part of it.
    case taper
}

/// How hard a stretch of running is, relative to the runner's own zones (SPEC.md 3.1, 3.2).
public enum WorkoutIntensity: String, CaseIterable, Equatable, Hashable, Sendable {
    /// Zone 1: very easy.
    case recovery
    /// Zones 1 to 2: below the aerobic threshold.
    case easy
    /// Zone 3: steady running just above the aerobic threshold.
    case steady
    /// The jog between repetitions. Heart rate stays raised from the rep before,
    /// so this time is counted as **not easy** in the intensity distribution (3.1).
    case repRecovery
    /// The goal race's pace.
    case racePace
    /// Zones 4 to 5a: around lactate threshold.
    case threshold
    /// Zone 5b and above: VO2max repetitions.
    case vo2max
    /// The race itself.
    case race

    /// True for running below the aerobic threshold, the "easy" share of SPEC 3.1.
    public var isBelowAerobicThreshold: Bool { self == .recovery || self == .easy }
}

/// A heart-rate target in bpm, derived from the runner's LTHR (SPEC.md 3.2).
public struct HeartRateTarget: Equatable, Hashable, Sendable {
    /// The Friel zones the target spans.
    public let zones: ClosedRange<HRZone>
    /// Lowest heart rate to aim for (inclusive), or nil for no floor.
    public let floorBPM: Double?
    /// Heart rate to stay **below** (exclusive, like `HRZones.easyCeiling`),
    /// or nil for no cap.
    public let ceilingBPM: Double?

    public init(zones: ClosedRange<HRZone>, floorBPM: Double?, ceilingBPM: Double?) {
        self.zones = zones
        self.floorBPM = floorBPM
        self.ceilingBPM = ceilingBPM
    }
}

/// A grade-adjusted pace range (SPEC.md 3.6), in seconds per kilometre on the
/// flat. On a hilly route the app converts it with the GAP curve (F7).
public struct PaceTarget: Equatable, Hashable, Sendable {
    /// The fast end of the range (fewer seconds per km).
    public let fastestSecondsPerKm: Double
    /// The slow end of the range.
    public let slowestSecondsPerKm: Double

    public init(fastestSecondsPerKm: Double, slowestSecondsPerKm: Double) {
        self.fastestSecondsPerKm = min(fastestSecondsPerKm, slowestSecondsPerKm)
        self.slowestSecondsPerKm = max(fastestSecondsPerKm, slowestSecondsPerKm)
    }
}

/// What a stretch of running aims for. Heart rate is always set (the plan
/// needs zones, 3.2); pace is set only when the runner's data gives one, and
/// is never guessed. Power has no baseline input yet and is not set.
public struct WorkoutTarget: Equatable, Hashable, Sendable {
    /// Which target the watch should hold the runner to.
    public enum Primary: String, Equatable, Hashable, Sendable {
        case heartRate
        case pace
    }

    public let heartRate: HeartRateTarget
    public let pace: PaceTarget?
    public let primary: Primary

    public init(heartRate: HeartRateTarget, pace: PaceTarget?, primary: Primary) {
        self.heartRate = heartRate
        self.pace = pace
        self.primary = primary
    }
}

/// One contiguous stretch of a session.
public struct WorkoutSegment: Equatable, Hashable, Sendable {
    public enum Role: String, Equatable, Hashable, Sendable {
        case warmUp
        /// The whole of an easy or long run, or the body of a continuous effort.
        case main
        /// One repetition of a repeated effort.
        case work
        /// The jog between two repetitions.
        case jog
        /// A faster finish at the end of a long run.
        case finish
        case coolDown
    }

    public let role: Role
    public let intensity: WorkoutIntensity
    public let durationSeconds: Double
    public let target: WorkoutTarget

    public init(role: Role, intensity: WorkoutIntensity, durationSeconds: Double, target: WorkoutTarget) {
        self.role = role
        self.intensity = intensity
        self.durationSeconds = durationSeconds
        self.target = target
    }
}

/// A rule of SPEC.md that shaped a session, so the app can say why it is there (F3).
public enum PlanRule: String, CaseIterable, Equatable, Hashable, Sendable {
    /// SPEC 3.1 and 3.2: easy running is easy by heart rate, below the top of zone 2.
    case easyByHeartRate
    /// SPEC 3.1: about 75 to 85% of weekly time below the aerobic threshold,
    /// the rest threshold and VO2max work.
    case intensityDistribution
    /// SPEC 3.5 (heuristic): weekly volume rises at most about 10% a week and
    /// 30% over 4 weeks.
    case weeklyProgression
    /// SPEC 3.5 (heuristic): the long run stays within about 30 to 35% of the
    /// week; F3 heuristic: it grows at most 10 minutes a week.
    case longRunShare
    /// SPEC 3.5 rule 1 (heuristic): no run more than about 10% longer than
    /// the longest run of the previous 30 days.
    case singleRunSpike
    /// SPEC 3.5 (heuristic): a recovery week every third or fourth week.
    case recoveryWeek
    /// SPEC 3.5: at most two quality sessions a week, never on consecutive days (F4).
    case qualityLimit
    /// F3: base, build, peak and taper; which session a phase gets is a heuristic.
    case periodization
    /// F3 (heuristic): volume drops before the race so the runner arrives fresh.
    case taper
    /// F2: the race the athlete set.
    case goalRace

    /// One plain-English line naming the rule and its SPEC section.
    public var summary: String {
        switch self {
        case .easyByHeartRate:
            return "Easy running stays below the top of zone 2 by heart rate (SPEC 3.1, 3.2)."
        case .intensityDistribution:
            return "About 75 to 85% of weekly running time is easy; the rest is threshold and VO2max work (SPEC 3.1)."
        case .weeklyProgression:
            return "Weekly volume rises at most about 10% a week and 30% over 4 weeks (heuristic, SPEC 3.5)."
        case .longRunShare:
            return "The long run stays within about 30 to 35% of the week and grows at most 10 minutes a week (heuristic, SPEC 3.5, F3)."
        case .singleRunSpike:
            return "No run is more than about 10% longer than your longest run of the last 30 days (heuristic, SPEC 3.5 rule 1)."
        case .recoveryWeek:
            return "A lighter recovery week every third or fourth week (heuristic, SPEC 3.5)."
        case .qualityLimit:
            return "At most two quality sessions a week, never on consecutive days (SPEC 3.5, F4)."
        case .periodization:
            return "Base, build, peak and taper; the session each phase gets is a heuristic (F3)."
        case .taper:
            return "Volume drops before the race so you arrive fresh (heuristic, F3)."
        case .goalRace:
            return "Your goal race, as you set it (F2)."
        }
    }
}

/// What a planned session is for and how to run it (SPEC.md F3). Attached to
/// a `PlannedWorkout` by the plan builder.
public struct WorkoutPrescription: Equatable, Hashable, Sendable {
    /// Why the session is in the plan, in plain English.
    public let purpose: String
    public let phase: PlanPhase
    /// The session from start to finish; the durations add up to the workout's duration.
    public let segments: [WorkoutSegment]
    /// The rules that produced the session, the main one first.
    public let rules: [PlanRule]
    /// On race day only: the race's distance in metres (F2). The race-day
    /// sentence is built from it at the edge, in the runner's units, by
    /// `PlanFormatting.purpose(of:units:)`; `purpose` holds the metric
    /// sentence. Nil on every other session.
    public let raceDistanceMeters: Double?
    /// The Daniels return factor (SPEC 3.5 rule 4, #28) already applied to the
    /// session's pace targets taken from the fitness anchor or the easy-pace
    /// sample (each divided by it), or nil when none is (the same as 1.0).
    /// Set by the plan builder and the adaptation engine, so that either can
    /// change the factor later without applying it twice.
    public let returnPaceFactor: Double?

    public init(purpose: String, phase: PlanPhase, segments: [WorkoutSegment], rules: [PlanRule],
                raceDistanceMeters: Double? = nil, returnPaceFactor: Double? = nil) {
        self.returnPaceFactor = returnPaceFactor
        self.purpose = purpose
        self.phase = phase
        self.segments = segments
        self.rules = rules
        self.raceDistanceMeters = raceDistanceMeters
    }

    /// Total duration of the segments in seconds.
    public var durationSeconds: Double { segments.reduce(0) { $0 + $1.durationSeconds } }

    /// Seconds below the aerobic threshold (easy and recovery segments).
    public var easySeconds: Double {
        segments.filter { $0.intensity.isBelowAerobicThreshold }.reduce(0) { $0 + $1.durationSeconds }
    }
}
