import Foundation

/// One computed number behind a debrief fact (SPEC.md F6).
public struct DebriefValue: Equatable, Sendable {
    public enum Name: String, CaseIterable, Equatable, Hashable, Sendable {
        /// Moving time of the run, pauses left out.
        case movingTime
        /// Elapsed time, used only when the run has too few samples to tell pauses apart.
        case elapsedTime
        case distance
        /// Pace over the scope the fact names.
        case pace
        /// The fast and slow ends of the planned pace target.
        case targetFastest, targetSlowest
        /// The pace tolerance the classifier allows around the target (fraction).
        case paceTolerance
        /// Metres climbed per km.
        case climb
        case heartRate
        /// The Friel zone number the heart rate falls in (3.2).
        case zone
        /// The planned heart-rate floor (inclusive) and ceiling (exclusive).
        case bandFloor, bandCeiling
        /// Aerobic decoupling (3.3).
        case decoupling
        /// The 3.3 class boundaries: under `goodLimit` is good, over `highLimit` is above the aerobic threshold.
        case goodLimit, highLimit
        case cadence
        /// Percent drop of cadence in the final third against the first third.
        case cadenceFade
        /// The fade at or above which the engine counts a strain marker.
        case fadeLimit
        /// The shortest moving time the debrief reads trends from.
        case minimumTime
        /// One pace step (fraction).
        case paceStep
        /// Sessions a change touched.
        case sessions
        /// Sessions agreeing in the "two of the last three" rule.
        case signalCount
        /// The held weekly volume, in the guardrail measure.
        case heldLevel
        /// When a volume hold ends.
        case holdEnd
        /// Mean heart rate of recent easy runs, and the cap it was checked against.
        case easyMeanHeartRate, easyCap
        /// Long-run length allowed, and the length it was planned at.
        case allowedTime, plannedTime
        case painScore
        /// The top of the pain scale (`PainCheckIn.validScores`).
        case painScaleMax
        /// Volume still above a held level after the engine cut what it may.
        case overHeldLevel
        /// Weeks a hold shortfall leaves over the held level.
        case weeks
        /// Weeks a hold can't be checked in because their volume is unknown.
        case uncheckedWeeks
        /// When progression was stopped by the pain stop rule (3.5 rule 7).
        case stopSince
        /// Changes the debrief did not spell out.
        case count
    }

    public enum Unit: String, Equatable, Hashable, Sendable {
        case seconds, meters, secondsPerKm, metersPerKm, bpm, zone, percent, fraction, stepsPerMinute, count
        /// Seconds since 1970, shown as a day in the runner's time zone.
        case date
        /// 0 to 10.
        case painScore
    }

    public let name: Name
    public let value: Double
    public let unit: Unit

    public init(name: Name, value: Double, unit: Unit) {
        self.name = name
        self.value = value
        self.unit = unit
    }
}

/// How a computed value sits against what the plan or a rule expected.
public enum DebriefComparison: String, Equatable, Hashable, Sendable {
    /// Below the range (for pace: faster than the target).
    case below
    /// Inside the range.
    case within
    /// Outside the range but within the classifier's tolerance (pace only).
    case withinTolerance
    /// Above the range (for pace: slower than the target).
    case above
}

/// Which part of the run a pace or heart-rate fact covers.
public enum DebriefScope: String, Equatable, Hashable, Sendable {
    /// The planned session's main part, heart-rate lag skipped (`RunMetrics.key`).
    case mainPart
    /// The planned session's work reps, heart-rate lag skipped.
    case reps
    /// An unplanned run: everything after the warm-up.
    case afterWarmUp
}

/// A stream the debrief could not read.
public enum DebriefStream: String, CaseIterable, Equatable, Hashable, Sendable {
    case heartRate, pace, cadence
}

/// Why pace is not compared with the target.
public enum DebriefPaceSkip: Equatable, Hashable, Sendable {
    /// Treadmill pace waits for the treadmill offset (3.8, F8).
    case treadmill
    /// Raw pace on a hilly route waits for grade-adjusted pace (3.6, F7).
    case hilly
}

/// One fact the debrief may state. Each carries its computed values with
/// units and names the metric it came from, so wording (template or LLM) can
/// only restate it (SPEC.md F6: "every claim maps to a computed metric").
public struct DebriefFact: Equatable, Sendable {
    public enum Kind: Equatable, Hashable, Sendable {
        /// Moving (or elapsed) time and distance, and the planned session's kind if any.
        case run(planned: PlannedWorkout.Kind?)
        /// Pace over a scope, with the target when the plan set one.
        case pace(DebriefScope)
        /// Pace measured but not compared with the target.
        case paceNotCompared(DebriefPaceSkip)
        /// Mean heart rate over a scope, its zone and the planned band.
        case heartRate(DebriefScope)
        /// Steady-run decoupling and its 3.3 class.
        case decoupling(DecouplingBasis, DecouplingClass)
        /// Mean cadence over a scope, and the fade when the session was one continuous effort.
        case cadence(DebriefScope)
        /// Streams that were not recorded at all.
        case missing([DebriefStream])
        /// Streams recorded, but with too little usable data over the scope to read.
        case patchy([DebriefStream])
        /// The run is shorter than the debrief reads trends from.
        case tooShort
        /// The adaptation engine's reading of the run (F4).
        case assessment(RunSignal)
        /// One kind of plan change from the adaptation outcome (F4), aggregated.
        case change(PlanChange.Kind)
        /// Further changes the debrief does not spell out.
        case moreChanges
        /// The adaptation outcome changed nothing.
        case noChange
    }

    /// Stable within one debrief, e.g. "pace" or "change.volumeHeld".
    public let id: String
    public let kind: Kind
    public let values: [DebriefValue]
    public let comparison: DebriefComparison?
    /// The computed metric the values came from, e.g. "RunMetrics.paceSecondsPerKm".
    public let source: String

    public init(id: String, kind: Kind, values: [DebriefValue], comparison: DebriefComparison? = nil, source: String) {
        self.id = id
        self.kind = kind
        self.values = values
        self.comparison = comparison
        self.source = source
    }

    /// The value with `name`, if the fact has one.
    public func value(_ name: DebriefValue.Name) -> Double? { values.first { $0.name == name }?.value }
}

/// Thresholds for the debrief. Every value is a **heuristic** (SPEC.md F6),
/// not a validated cut-off, and none stands for a particular runner.
public struct DebriefHeuristics: Equatable, Sendable {
    /// Under this much moving time the debrief states time, distance and pace
    /// only: heart rate, drift and cadence over a few minutes say little.
    /// Default 10 min.
    public var minimumMovingSeconds: Double
    /// Most lines the template writes (F6: three to five). Default 5.
    public var maximumLines: Int
    /// Most change kinds spelled out; the rest are counted. Default 3.
    public var maximumChangeClauses: Int
    /// A mean cadence outside this range (steps per minute, both feet) is a
    /// sensor or unit error and is not stated. Default 60 to 260.
    public var plausibleCadence: ClosedRange<Double>

    public init(minimumMovingSeconds: Double = 10 * 60,
                maximumLines: Int = 5,
                maximumChangeClauses: Int = 3,
                plausibleCadence: ClosedRange<Double> = 60...260) {
        self.minimumMovingSeconds = minimumMovingSeconds
        self.maximumLines = maximumLines
        self.maximumChangeClauses = maximumChangeClauses
        self.plausibleCadence = plausibleCadence
    }

    public static let `default` = DebriefHeuristics()
}
