import Foundation

/// One session on the training timeline (SPEC.md F3, F4, F9).
///
/// The same type describes a session that is planned and one that was done:
/// the guardrail checker (3.5) reads completed sessions as history and
/// planned sessions as the plan, so the plan builder (F3) and the adaptation
/// engine (F4) can hand it one timeline. Targets (pace, HR, power), purpose
/// and the rule behind a session live in the optional `prescription`, which
/// the plan builder (F3) sets; history sessions have none.
///
/// History converts in through `init?(activity:kind:)`: running only (walks
/// and other sports add no running volume), with `durationSeconds` as
/// **moving** time (pauses excluded) and the recorded distance. The caller
/// classifies the kind (easy, long, quality, race...) from the run itself.
public struct PlannedWorkout: Equatable, Hashable, Sendable {
    /// The kind of hard session a quality day is.
    public enum QualityKind: String, CaseIterable, Equatable, Hashable, Sendable {
        case tempo
        case threshold
        case intervals
        case hills
        case fartlek
        case racePace
    }

    /// What the session is for. Only `.quality` and (by default) `.race`
    /// count toward the weekly limit on hard sessions; only `.long` is
    /// checked against the long-run share.
    public enum Kind: Equatable, Hashable, Sendable {
        case easy
        case long
        case quality(QualityKind)
        case recovery
        case race
        /// A planned rest day. It never adds volume, whatever its duration says.
        case rest

        public var isQuality: Bool {
            if case .quality = self { return true }
            return false
        }
    }

    /// Stable identifier, so the adaptation engine can replace a session in place.
    public var id: String
    /// When the session starts (or started). Its week is the Monday-start
    /// week that contains this instant in the runner's time zone (see `PlanCalendar`).
    public var date: Date
    public var kind: Kind
    /// Planned (or recorded) moving time in seconds.
    public var durationSeconds: Double
    /// Planned (or recorded) distance in meters, when known.
    public var distanceMeters: Double?
    /// Purpose, segments, targets and rules, set by the plan builder (F3).
    /// Nil for history sessions and for sessions made elsewhere.
    public var prescription: WorkoutPrescription?

    public init(id: String, date: Date, kind: Kind, durationSeconds: Double, distanceMeters: Double? = nil,
                prescription: WorkoutPrescription? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.durationSeconds = durationSeconds
        self.distanceMeters = distanceMeters
        self.prescription = prescription
    }

    /// The session's contribution to weekly volume, or nil when the needed
    /// value is missing, negative, NaN or infinite. Never guesses: a nil here
    /// makes the whole week's volume unknown. Rest days contribute 0.
    public func volume(_ measure: VolumeMeasure) -> Double? {
        if kind == .rest { return 0 }
        let value: Double?
        switch measure {
        case .time: value = durationSeconds
        case .distance: value = distanceMeters
        }
        guard let v = value, v.isFinite, v >= 0 else { return nil }
        return v
    }

    /// This session turned into an easy run on the same day, keeping its id,
    /// duration and distance, so weekly volume stays the same (and known) in
    /// either measure and the swap never adds load. The plan builder sets the
    /// easy target within that volume.
    public func swappedToEasy() -> PlannedWorkout {
        PlannedWorkout(id: id, date: date, kind: .easy, durationSeconds: durationSeconds, distanceMeters: distanceMeters)
    }

    /// A completed run from the history (F1) as a session on the timeline.
    /// Nil for walks and other sports, which add no running volume.
    ///
    /// Duration is moving time under the one rule every caller uses,
    /// `MovingTime.knownSeconds(of:maximumHoldSeconds:)`: samples sharing a
    /// timestamp are one point, a stretch ending in a pause counts for at most
    /// `maximumHoldSeconds`, and with fewer than two usable points the elapsed
    /// duration is used. So the guardrails' history volume (3.5) and the
    /// baseline's weekly load (F1) agree run for run. Pass the baseline's
    /// `BaselineOptions.decoupling.maximumHoldSeconds` when it isn't the default.
    ///
    /// A run with no usable time (no usable streams and an elapsed duration
    /// that isn't a finite non-negative number) keeps an unknown duration
    /// (NaN), so `volume(.time)` is nil and its week's time volume is unknown,
    /// known only to be at least the week's other sessions. The checker (3.5)
    /// holds the rules for every volume the week may truly have held (except
    /// the rolling 4-week rule while that week is among the recent 4, and the
    /// 10% rise and freeze for that week itself, which have no upper bound and
    /// are read at its known part, else reported as not evaluated; the
    /// long-run share for that week is always not evaluated): it
    /// counts as a build week, the next week's 10% reference is the least it
    /// can have been, and the week after recovers only at most 80% of the
    /// known part (`GuardrailChecker.reference(before:)`). Counting the run as
    /// 0 instead could let its week pass as a recovery week.
    /// `BaselinePlanMapping.planHistory` does the same.
    public init?(activity: Activity, kind: Kind,
                 maximumHoldSeconds: Double = MovingTime.defaultMaximumHoldSeconds) {
        guard activity.sport == .run else { return nil }
        self.init(id: activity.id, date: activity.start, kind: kind,
                  durationSeconds: MovingTime.knownSeconds(of: activity, maximumHoldSeconds: maximumHoldSeconds) ?? .nan,
                  distanceMeters: activity.distanceMeters)
    }
}

/// How weekly volume is measured (SPEC.md 3.5: "weekly time or distance").
/// Time is the default because every session has a duration, while distance
/// is missing for some (treadmill without calibration, planned time-based runs).
public enum VolumeMeasure: String, Equatable, Hashable, Sendable {
    case time
    case distance
}
