import Foundation

/// What the voice coach should do at one reading (SPEC.md F11).
public enum CueAction: String, CaseIterable, Equatable, Sendable {
    /// Say nothing.
    case none
    /// Pace is slower than the band: "speed up".
    case speedUp
    /// Pace is faster than the band: "slow down".
    case slowDown
    /// Heart rate is above the ceiling: "ease off".
    case easeOff

    /// The short fixed phrase for the cue; nil for `.none`. The app may word
    /// it more fully; the engine never writes anything longer (F11, 1.2).
    public var phrase: String? {
        switch self {
        case .none: return nil
        case .speedUp: return "Speed up"
        case .slowDown: return "Slow down"
        case .easeOff: return "Ease off"
        }
    }
}

/// Why the engine decided what it did, machine-readable so the app can word
/// it and tests can assert it.
public struct CueReason: Equatable, Sendable {
    /// The rule that decided. The first three groups fire a cue; the rest
    /// explain why the engine said nothing.
    public enum Rule: String, CaseIterable, Equatable, Sendable {
        // Cues.
        /// Pace stayed slower than the band for the sustained window.
        case sustainedTooSlow
        /// Pace stayed faster than the band for the sustained window.
        case sustainedTooFast
        /// Heart rate stayed above the ceiling for the sustained window.
        case sustainedHeartRateOverCeiling

        // Silence.
        /// The reading's time is not finite or not after the previous one.
        case invalidInput
        /// Neither a usable pace nor a usable heart rate (nil, NaN, stale or
        /// stopped), so nothing could be judged.
        case insufficientData
        /// The segment has no pace band and no heart-rate ceiling to hold.
        case noTarget
        /// Inside the first `startupSeconds` of the segment (F11).
        case startupWindow
        /// Inside the band and under the ceiling (or back inside after a cue
        /// and held there).
        case withinTarget
        /// A deviation is under way but has not lasted `sustainSeconds` yet.
        case deviationPending
        /// Already cued for this deviation; waiting for it to end (re-entry
        /// must be sustained too) or for the reminder interval.
        case alreadyCued
        /// A cue is due but the last one was less than `minimumGapSeconds` ago.
        case minimumGap
        /// "Speed up" suppressed because the smoothed grade is below
        /// `descentGradeThreshold`. **Pending owner decision #83.**
        case descentNoSpeedUp
        /// "Speed up" suppressed because the segment's target is heart-rate
        /// primary (F11, F3).
        case heartRatePrimaryNoSpeedUp
    }

    public let rule: Rule
    /// Smoothed pace in seconds per km, when there was one.
    public let paceSecondsPerKm: Double?
    /// The grade-adjusted band, seconds per km (the segment's `PaceTarget`
    /// times `gradeFactor`), when the segment has a pace target.
    public let bandFastestSecondsPerKm: Double?
    public let bandSlowestSecondsPerKm: Double?
    /// The paces a deviation must pass to start counting: the band widened by
    /// the grade uncertainty and by the leave margin (seconds per km). Pace
    /// slower than `slowTrigger...` or faster than `fastTrigger...` is
    /// outside; nil when the segment has no pace target.
    public let fastTriggerSecondsPerKm: Double?
    public let slowTriggerSecondsPerKm: Double?
    /// Smoothed grade used, nil when none was available.
    public let grade: Double?
    /// The pace factor applied (1 when `usedFlatFallback`).
    public let gradeFactor: Double
    /// The grade uncertainty the band was widened by, as a fraction of grade: the
    /// engine's base uncertainty, plus more while the smoothed grade is changing.
    public let gradeUncertainty: Double
    /// True when no grade was available (altitude missing or too little
    /// distance yet) and the targets were taken as flat (f = 1).
    public let usedFlatFallback: Bool
    public let heartRate: Double?
    public let heartRateCeiling: Double?
    /// How long the deviation behind this decision has lasted, seconds
    /// (the pending deviation for `deviationPending`, the one that fired for a
    /// cue); nil when there is none.
    public let deviationSeconds: Double?
    /// Seconds into the active segment.
    public let segmentSeconds: Double

    public init(rule: Rule, paceSecondsPerKm: Double? = nil, bandFastestSecondsPerKm: Double? = nil,
                bandSlowestSecondsPerKm: Double? = nil, fastTriggerSecondsPerKm: Double? = nil,
                slowTriggerSecondsPerKm: Double? = nil, grade: Double? = nil, gradeFactor: Double = 1,
                usedFlatFallback: Bool = false, gradeUncertainty: Double = 0, heartRate: Double? = nil, heartRateCeiling: Double? = nil,
                deviationSeconds: Double? = nil, segmentSeconds: Double = 0) {
        self.rule = rule
        self.paceSecondsPerKm = paceSecondsPerKm
        self.bandFastestSecondsPerKm = bandFastestSecondsPerKm
        self.bandSlowestSecondsPerKm = bandSlowestSecondsPerKm
        self.fastTriggerSecondsPerKm = fastTriggerSecondsPerKm
        self.slowTriggerSecondsPerKm = slowTriggerSecondsPerKm
        self.grade = grade
        self.gradeFactor = gradeFactor
        self.usedFlatFallback = usedFlatFallback
        self.gradeUncertainty = gradeUncertainty
        self.heartRate = heartRate
        self.heartRateCeiling = heartRateCeiling
        self.deviationSeconds = deviationSeconds
        self.segmentSeconds = segmentSeconds
    }
}

/// The engine's decision at one reading.
public struct CueDecision: Equatable, Sendable {
    /// Time of the reading (seconds since the start of the run).
    public let time: Double
    public let action: CueAction
    public let reason: CueReason

    /// The short fixed phrase to speak; nil when the action is `.none`.
    public var phrase: String? { action.phrase }

    public init(time: Double, action: CueAction, reason: CueReason) {
        self.time = time
        self.action = action
        self.reason = reason
    }
}
