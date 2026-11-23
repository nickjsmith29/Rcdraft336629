import Foundation

/// A pain freeze (SPEC.md 3.5): from the check-in, weekly volume may not grow
/// for `PainRuleLimits.freezeDays`. Enforced through
/// `GuardrailChecker.check(freezes:)`, which holds a frozen week to the
/// actual volume of the week before it.
public struct VolumeFreeze: Equatable, Sendable, Codable {
    public let interval: DateInterval
    /// The date of the check-in that fired the rule.
    public let checkIn: Date

    public init(interval: DateInterval, checkIn: Date) {
        self.interval = interval
        self.checkIn = checkIn
    }
}

/// A volume hold after quality sessions pointed behind (SPEC.md section 8:
/// "hold volume"). Weeks overlapping `interval` may not plan more than
/// `level`: the higher of the week the hold started in and the week before
/// it, so a hold that starts in a recovery week holds the level before the
/// recovery week rather than pinning the next build week to it. Unlike a pain
/// freeze it is not a guardrail, so it is not passed to the checker; the
/// engine enforces it itself.
///
/// In a race week only the volume outside the race is compared with the
/// level. A hold that starts in race week takes its level from week totals
/// that include the race, so it hardly bites that week. That is harmless:
/// the engine never grows a week past the plan, so the race week can't rise
/// above what was planned either way.
public struct VolumeHold: Equatable, Sendable, Codable {
    public let interval: DateInterval
    /// Weekly volume in the guardrail measure (seconds for time, meters for distance).
    public let level: Double
    /// The shortest a hold may make a long run (the long-run floor), fixed
    /// when the hold starts so repeated events never compound it. Nil: the
    /// hold leaves long runs alone. The floor binds the hold only: once a hold
    /// has dropped the easy runs, the long-run share guardrail (3.5, at most
    /// 35% of the week) may shorten the long run below it, and the guardrail
    /// wins, since it only lowers load.
    public let longRunFloorSeconds: Double?

    public init(interval: DateInterval, level: Double, longRunFloorSeconds: Double? = nil) {
        self.interval = interval
        self.level = level
        self.longRunFloorSeconds = longRunFloorSeconds
    }
}

/// A classified quality session, kept for the "two of the last three" rule.
public struct SignalRecord: Equatable, Sendable, Codable {
    public let activityID: String
    public let date: Date
    public let signal: RunSignal
    public let triggers: [TriggerMetric]

    public init(activityID: String, date: Date, signal: RunSignal, triggers: [TriggerMetric]) {
        self.activityID = activityID
        self.date = date
        self.signal = signal
        self.triggers = triggers
    }
}

/// Mean heart rate of one easy, recovery or long run's main part.
public struct EasyHeartRateRecord: Equatable, Sendable, Codable {
    public let activityID: String
    public let date: Date
    public let heartRate: Double

    public init(activityID: String, date: Date, heartRate: Double) {
        self.activityID = activityID
        self.date = date
        self.heartRate = heartRate
    }
}

/// One completed long run, for the long-run step gate (3.3).
public struct LongRunRecord: Equatable, Sendable, Codable {
    public let activityID: String
    public let date: Date
    /// The planned duration of the session it was run for (its target duration).
    public let plannedSeconds: Double
    public let movingSeconds: Double
    /// Pace-to-HR decoupling, nil when it could not be computed on a steady run.
    public let decouplingPercent: Double?

    public init(activityID: String, date: Date, plannedSeconds: Double, movingSeconds: Double, decouplingPercent: Double?) {
        self.activityID = activityID
        self.date = date
        self.plannedSeconds = plannedSeconds
        self.movingSeconds = movingSeconds
        self.decouplingPercent = decouplingPercent
    }
}

/// Everything the adaptation engine remembers between events. A value type
/// the app persists and hands back with the next event; the engine never
/// keeps state of its own. All fields are public so the app can store and
/// restore them (for example, seed `longRuns` from the baseline's decoupling runs).
///
/// `Codable` (see `AdaptationStateCoding.swift`) so the app can store it
/// between launches; the plan and history are the app's to store alongside it.
public struct AdaptationState: Equatable, Sendable {
    /// Every assessment so far, oldest first (for the debrief, F6, and the dashboard, F13).
    public var assessments: [RunAssessment]
    /// Classified quality sessions since the last pace move (a move consumes them,
    /// so the same sessions never move paces twice).
    public var qualitySignals: [SignalRecord]
    /// Easy-run heart rates since the last easy-pace change.
    public var easyHeartRates: [EasyHeartRateRecord]
    public var longRuns: [LongRunRecord]
    /// Every pain check-in received, ordered by date and, for the same date, by
    /// score (so the higher score of two at the same time counts as the latest).
    public var painCheckIns: [PainCheckIn]
    /// The pain response the engine applied most recently.
    public var appliedPainResponse: PainResponse?
    /// The date of the check-in behind `appliedPainResponse`, passed back to
    /// `PainCheckInRule.evaluate` so one check-in is acted on once.
    public var lastAppliedCheckIn: Date?
    /// Pain freezes still in force; dropped once they end.
    public var freezes: [VolumeFreeze]
    /// Volume holds still in force; dropped once they end.
    public var holds: [VolumeHold]
    /// Cumulative factor applied to quality pace targets (seconds per km); below 1 is faster.
    public var qualityPaceFactor: Double
    /// Cumulative factor applied to easy pace targets; above 1 is slower.
    public var easyPaceFactor: Double
    /// The `holdShortfall` changes the last event found, so an unchanged
    /// shortfall is not posted again on every event while it lasts.
    public var reportedHoldShortfalls: [PlanChange]
    /// Every pain report received (3.5 rule 7), in date order, kept for the
    /// clinician flag (`PainStopRule.lastingPain`).
    public var painReports: [PainReport]
    /// Progression stopped by the pain stop rule (3.5 rule 7), or nil. The
    /// engine starts it and makes it stricter; it ends only by rule 7's end
    /// path (`painRecovery`), which then starts the return.
    public var painStop: PainStop?
    /// The rest of 3.5 rule 7: usual pain, how the stop ends, the return
    /// after it and the clinician flag (`PainRecovery`).
    public var painRecovery: PainRecovery
    /// The plan as the app last handed it in, before the engine cut it, for
    /// the regrowth after a missed, cut or painful week (3.5 rule 6, #64).
    public var planSnapshot: PlanSnapshot

    public init(assessments: [RunAssessment] = [], qualitySignals: [SignalRecord] = [],
                easyHeartRates: [EasyHeartRateRecord] = [], longRuns: [LongRunRecord] = [],
                painCheckIns: [PainCheckIn] = [], appliedPainResponse: PainResponse? = nil,
                lastAppliedCheckIn: Date? = nil, freezes: [VolumeFreeze] = [], holds: [VolumeHold] = [],
                qualityPaceFactor: Double = 1, easyPaceFactor: Double = 1,
                reportedHoldShortfalls: [PlanChange] = [], painReports: [PainReport] = [],
                painStop: PainStop? = nil, painRecovery: PainRecovery = PainRecovery(),
                planSnapshot: PlanSnapshot = PlanSnapshot()) {
        self.assessments = assessments
        self.qualitySignals = qualitySignals
        self.easyHeartRates = easyHeartRates
        self.longRuns = longRuns
        self.painCheckIns = painCheckIns
        self.appliedPainResponse = appliedPainResponse
        self.lastAppliedCheckIn = lastAppliedCheckIn
        self.freezes = freezes
        self.holds = holds
        self.qualityPaceFactor = qualityPaceFactor
        self.easyPaceFactor = easyPaceFactor
        self.reportedHoldShortfalls = reportedHoldShortfalls
        self.painReports = painReports
        self.painStop = painStop
        self.painRecovery = painRecovery
        self.planSnapshot = planSnapshot
    }

    /// Freezes in force at or after `date` (those that have not ended).
    public func activeFreezes(at date: Date) -> [VolumeFreeze] {
        freezes.filter { $0.interval.end > date }
    }

    /// The intervals of `activeFreezes(at:)`, ready for any caller that runs
    /// `GuardrailChecker.check(freezes:)` itself, for example a goal edit that
    /// re-plans (F2) while a pain freeze (3.5) is in force. Pass them so the
    /// new plan respects the freeze; the engine also keeps enforcing freezes,
    /// holds and a pain stop (`painStop`, whose ceiling is not a freeze) on
    /// its next event, whatever plan it is handed.
    public func freezeIntervals(at date: Date) -> [DateInterval] {
        activeFreezes(at: date).map(\.interval)
    }

    /// True while a pain stop stands: progression is stopped (3.5 rule 7).
    public var progressionStopped: Bool { painStop != nil }

    /// Holds in force at or after `date`.
    public func activeHolds(at date: Date) -> [VolumeHold] {
        holds.filter { $0.interval.end > date }
    }
}
