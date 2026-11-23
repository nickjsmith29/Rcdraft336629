import Foundation

/// One daily health reading from the phone or watch (SPEC.md section 2, 3.4, F1).
///
/// The app builds these from HealthKit's daily resting heart rate and heart-rate
/// variability samples. CoachCore never supplies a value of its own: a runner
/// with no readings gets no resting-HR or HRV baseline.
public struct DailyHealthSample: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Hashable, Sendable {
        /// Resting heart rate in beats per minute.
        case restingHeartRate
        /// Heart-rate variability as SDNN in milliseconds (what Apple Watch
        /// records). Readings in another HRV measure (for example RMSSD) must not
        /// be mixed in, since the two are on different scales.
        case hrvSDNN
    }

    /// When the reading was taken (or the day it describes). It is grouped into
    /// calendar days in the time zone passed to the baseline builder.
    public var date: Date
    public var kind: Kind
    /// bpm for `.restingHeartRate`, milliseconds for `.hrvSDNN`.
    public var value: Double

    public init(date: Date, kind: Kind, value: Double) {
        self.date = date
        self.kind = kind
        self.value = value
    }
}

/// A run the source or the runner marked as a race or a 30-minute time trial,
/// so its heart rate can feed the LTHR estimate (SPEC.md 3.2, F1).
///
/// `Activity` carries no race flag of its own, so the importer passes these
/// alongside the history (for example from Strava's race workout type, or the
/// runner tagging a run in the app).
public struct EffortMark: Equatable, Sendable {
    public var activityID: String
    /// `.race`: the whole activity is the race. `.timeTrialLast20Min`: the
    /// activity is the trial itself (no warm-up or cool-down), and the average
    /// heart rate over its last 20 minutes of moving time is used.
    public var kind: HREffort.Kind

    public init(activityID: String, kind: HREffort.Kind) {
        self.activityID = activityID
        self.kind = kind
    }
}
