// TimeZone is Sendable on Apple SDKs but not yet in swift-corelibs-foundation
// (Linux, Swift 5.10); @preconcurrency keeps BaselineReport's Sendable conformance warning-free there.
@preconcurrency import Foundation

// MARK: - Availability

/// A baseline value, or an explicit statement that the history can't support it
/// (F1: every value comes from the data; nothing is guessed or defaulted).
public enum BaselineValue<Value: Equatable & Sendable>: Equatable, Sendable {
    case available(Value)
    case insufficient(InsufficientData)

    /// The value when available, else nil.
    public var value: Value? {
        if case .available(let v) = self { return v }
        return nil
    }

    /// Why the value is missing, or nil when it is available.
    public var insufficiency: InsufficientData? {
        if case .insufficient(let why) = self { return why }
        return nil
    }
}

/// Why a part of the baseline report could not be produced.
public struct InsufficientData: Equatable, Sendable {
    public let reason: InsufficientReason
    /// Runs that were looked at and left out, with the reason for each.
    public let excluded: [ExcludedRun]

    public init(_ reason: InsufficientReason, excluded: [ExcludedRun] = []) {
        self.reason = reason
        self.excluded = excluded
    }
}

public enum InsufficientReason: Equatable, Sendable {
    /// `asOf`, the time zone calendar or an option is invalid (non-finite, negative).
    case invalidInput
    /// No runs in the window this value looks at.
    case noRuns
    /// History doesn't yet cover one complete week before the current one.
    case noCompleteWeek
    /// No run was marked as a race or time trial (`EffortMark`), so there is
    /// nothing to estimate LTHR from. Cold start: schedule a field test (SPEC.md 3.2).
    case noMarkedEfforts
    /// Runs were marked, but none qualified under `LTHREstimator`; see `excluded`.
    case noQualifyingEfforts
    /// The easy heart rate was to come from the runner's zones, but there is no LTHR.
    case needsLTHR
    /// Fewer usable runs than the value needs.
    case tooFewRuns(have: Int, need: Int)
    /// No daily readings of this kind were provided.
    case noReadings
    /// Fewer days with a reading than the value needs.
    case tooFewDays(have: Int, need: Int)
    /// No run in the window has a plausible heart rate held for
    /// `BaselineOptions.peakHoldSeconds` with closely spaced samples.
    case noHeartRateData
    /// No run in the window recorded cadence.
    case noCadence
    /// No run has a distance stream long enough for any best-effort distance.
    case noDistanceStreams
    /// The runs that had cadence don't span enough time for a trend.
    case spanTooShort(days: Double, need: Double)
}

/// A run that was considered for a value and left out.
public struct ExcludedRun: Equatable, Sendable {
    public let activityID: String
    public let reason: ExclusionReason

    public init(activityID: String, reason: ExclusionReason) {
        self.activityID = activityID
        self.reason = reason
    }
}

public enum ExclusionReason: Equatable, Sendable {
    /// Treadmill runs are left out of outdoor pace values (SPEC.md 3.8).
    case treadmill
    /// A marked effort names an activity that isn't in the history.
    case notInHistory
    /// A marked effort names an activity that isn't a run (for example a walk).
    case notARun
    /// Another mark already named the same run (directly or through a dropped
    /// duplicate); the first mark is used.
    case duplicateMark(of: String)
    /// A marked effort lies after `asOf`.
    case afterAsOf
    /// A marked effort has no usable heart rate for the part that counts.
    case noHeartRate
    /// A marked effort's heart-rate stream covers too little of the moving time
    /// that counts (`BaselineOptions.minimumHeartRateCoverage`); `coverage` is 0 to 1.
    case insufficientHeartRateCoverage(coverage: Double)
    /// The run has no speed stream, so pace at a heart rate can't be measured.
    case noSpeed
    /// A marked effort fails `LTHREstimator.qualifies` (duration or HR out of range).
    case effortDidNotQualify(durationSeconds: Double, averageHR: Double)
    /// A marked effort qualifies but is older than the LTHR lookback window.
    case outsideLookback
    /// `Decoupling.compute` refused the run.
    case decouplingRefused(DecouplingRefusal)
    /// The run failed the steady-run check, so its decoupling isn't comparable (SPEC.md 3.3).
    case notSteady
    /// Not enough speed data to tell whether the run was steady.
    case steadinessUnknown
    /// The run was marked as a race or time trial, so its drift reflects a hard
    /// effort rather than steady aerobic running.
    case markedEffort
    /// Too little moving time at the easy heart rate with a usable speed.
    case tooLittleTimeAtHeartRate(seconds: Double)
}

/// Every value in the report can list the runs it came from (F1 acceptance).
public protocol BaselineEvidence {
    /// The activity ids the value was computed from, in a stable order.
    var evidenceActivityIDs: [String] { get }
}

// MARK: - Runs

/// One run the report considered: a kept `.run` activity that started by `asOf`.
/// Enough to build plan-builder or guardrail input from the report.
public struct BaselineRun: Equatable, Sendable {
    public let activityID: String
    public let start: Date
    /// `MovingTime.seconds(of:maximumHoldSeconds:)` with `BaselineOptions.decoupling.maximumHoldSeconds`.
    public let movingSeconds: Double
    /// False when the run has no usable time (`MovingTime.knownSeconds` is
    /// nil): `movingSeconds` is then 0 in the weekly load, and plan history
    /// keeps the run with an unknown duration (`BaselinePlanMapping.planHistory`).
    public let movingTimeIsKnown: Bool
    /// Recorded distance in meters; nil when missing or not a finite non-negative number.
    public let distanceMeters: Double?
    public let isTreadmill: Bool
    /// The kind of the mark that names this run (directly or through a dropped
    /// duplicate), or nil when it wasn't marked.
    public let markedEffort: HREffort.Kind?
}

// MARK: - Weekly load and long runs

/// One ISO week (Monday 00:00 to the next Monday 00:00 in the caller's time zone).
public struct WeekLoad: Equatable, Sendable {
    public let weekStart: Date
    public let weekEnd: Date
    /// False for the week that contains `asOf`, which is still under way.
    public let isComplete: Bool
    /// Runs in the week, by start time.
    public let activityIDs: [String]
    /// Total moving time in seconds (elapsed duration for runs without samples).
    public let movingSeconds: Double
    /// Total of the recorded distances in meters.
    public let distanceMeters: Double
    /// Runs in the week with no recorded distance; `distanceMeters` leaves them out.
    public let runsWithoutDistance: [String]

    public var runCount: Int { activityIDs.count }
}

public struct WeeklyLoadBaseline: Equatable, Sendable, BaselineEvidence {
    /// Weeks from the oldest in the window to the current one, oldest first.
    /// Weeks without runs are listed with zeros: a week off is real load data.
    /// The window never starts before the week of the first run in the history.
    public let weeks: [WeekLoad]
    /// Start of each complete week averaged for the current load, oldest first.
    public let basisWeekStarts: [Date]
    /// Mean weekly moving time over the basis weeks, in seconds.
    public let currentWeeklyMovingSeconds: Double
    /// Mean weekly recorded distance over the basis weeks, in meters.
    public let currentWeeklyDistanceMeters: Double
    /// False when some run in the basis weeks had no distance, so the distance
    /// figure is a lower bound.
    public let distanceIsComplete: Bool
    /// Runs in the basis weeks.
    public let evidenceActivityIDs: [String]
}

/// The longest run (by moving time) of one week.
public struct LongRun: Equatable, Sendable {
    public let weekStart: Date
    public let activityID: String
    public let start: Date
    public let movingSeconds: Double
    public let distanceMeters: Double?
    /// The run's share of the week's moving time, 0 to 1 (SPEC.md 3.5 heuristic
    /// keeps the long run under about 30 to 35% of weekly volume).
    public let shareOfWeek: Double
}

public struct LongRunHistory: Equatable, Sendable, BaselineEvidence {
    /// The longest run of every week in the weekly-load window that had a run, oldest first.
    public let weekly: [LongRun]
    /// The longest of those.
    public let longest: LongRun
    /// Median moving time of the weekly long runs in the basis weeks of the
    /// weekly load; nil when none of those weeks had a run.
    public let typicalMovingSeconds: Double?

    public var evidenceActivityIDs: [String] { weekly.map(\.activityID) }
}

// MARK: - Best efforts

/// The fastest stretch of one run covering a given distance.
public struct RunBestEffort: Equatable, Sendable {
    public let distanceMeters: Double
    public let seconds: Double
    public let activityID: String
    /// When the stretch began.
    public let date: Date
    /// Seconds from the activity start to the start of the stretch.
    public let startOffsetSeconds: Double

    /// The same effort in the form `BlendedPredictor` takes (SPEC.md 3.9).
    public var bestEffort: BestEffort {
        BestEffort(distanceMeters: distanceMeters, seconds: seconds, date: date)
    }
}

public struct BestEffortsBaseline: Equatable, Sendable, BaselineEvidence {
    /// The all-time fastest effort at each distance that any run covered, shortest distance first.
    public let personalRecords: [RunBestEffort]
    /// The fastest effort at each distance within the best-effort lookback, shortest first.
    public let recent: [RunBestEffort]

    public var evidenceActivityIDs: [String] {
        baselineOrderedUnique((personalRecords + recent).map(\.activityID))
    }
}

// MARK: - Heart rate

public struct LTHRBaseline: Equatable, Sendable, BaselineEvidence {
    /// The estimate; its `evidence` efforts carry the activity ids.
    public let estimate: LTHREstimate
    public let zones: HRZones
    /// Marked runs that were left out, with the reason.
    public let excluded: [ExcludedRun]

    public var evidenceActivityIDs: [String] { estimate.evidence.map(\.id) }
}

/// The highest heart rate held for `holdSeconds` in recent runs. It is an
/// observed peak, not a tested maximum, and is never replaced by an age formula
/// (SPEC.md 3.2).
public struct PeakHeartRate: Equatable, Sendable, BaselineEvidence {
    public let bpm: Double
    public let activityID: String
    public let date: Date
    public let holdSeconds: Double

    public var evidenceActivityIDs: [String] { [activityID] }
}

// MARK: - Easy pace, decoupling, cadence

public struct EasyPaceRun: Equatable, Sendable {
    public let activityID: String
    public let start: Date
    /// Moving time spent inside the heart-rate band with a usable speed.
    public let secondsInBand: Double
    /// Time-weighted mean speed over that time, in m/s.
    public let metersPerSecond: Double
}

public struct EasyPaceBaseline: Equatable, Sendable, BaselineEvidence {
    /// The heart rate the pace is measured at.
    public let heartRate: Double
    /// Samples within this band count as "at" the heart rate.
    public let band: ClosedRange<Double>
    /// Median of the per-run speeds, in m/s.
    public let metersPerSecond: Double
    /// Seconds per kilometer at that speed.
    public var secondsPerKilometer: Double { 1000 / metersPerSecond }
    public let runs: [EasyPaceRun]
    public let excluded: [ExcludedRun]

    public var evidenceActivityIDs: [String] { runs.map(\.activityID) }
}

public struct DecouplingRun: Equatable, Sendable {
    public let activityID: String
    public let start: Date
    public let result: DecouplingResult
}

public struct DecouplingBaseline: Equatable, Sendable, BaselineEvidence {
    /// Median decoupling percent across the steady runs.
    public let typicalPercent: Double
    public let classification: DecouplingClass
    public let runs: [DecouplingRun]
    public let excluded: [ExcludedRun]

    public var evidenceActivityIDs: [String] { runs.map(\.activityID) }
}

public struct CadenceRun: Equatable, Sendable {
    public let activityID: String
    public let start: Date
    /// Time-weighted mean moving cadence (steps per minute), or the source's
    /// summary average when the run has no cadence stream.
    public let stepsPerMinute: Double
}

public struct CadenceTrend: Equatable, Sendable, BaselineEvidence {
    /// Runs with cadence in the window, by start time.
    public let runs: [CadenceRun]
    /// Mean cadence of the runs in the most recent basis weeks (the same weeks
    /// as the current weekly load), or of all runs when none fall there.
    public let recentStepsPerMinute: Double
    /// Least-squares slope in steps per minute per week across `runs`.
    public let slopePerWeek: BaselineValue<Double>
    /// Runs in the window without cadence; they are left out, never filled.
    public let runsWithoutCadence: [String]
    /// History-wide stretches without cadence (from `CadenceGapDetector`).
    public let gaps: [HistoryCadenceGap]

    public var evidenceActivityIDs: [String] { runs.map(\.activityID) }
}

// MARK: - Daily health baselines

/// One calendar day's reading (the mean when the day had several).
public struct DailyValue: Equatable, Sendable {
    /// 00:00 of the day in the caller's time zone.
    public let day: Date
    public let value: Double
}

/// A personal normal range for a daily reading (SPEC.md 3.4).
public struct DailyMetricBaseline: Equatable, Sendable {
    public let kind: DailyHealthSample.Kind
    /// Mean of the daily values in the normal-range window.
    public let mean: Double
    /// Sample standard deviation of those daily values.
    public let standardDeviation: Double
    /// mean ± `BaselineOptions.normalRangeSD` standard deviations.
    public let normalRange: ClosedRange<Double>
    /// Mean of the last 7 calendar days, or why there are too few readings.
    public let sevenDayAverage: BaselineValue<Double>
    /// The days the baseline came from (its evidence), oldest first.
    public let days: [DailyValue]
}

// MARK: - The report

/// The F1 baseline report: what the runner's own history says about them.
/// Every value cites the runs (or days) it came from, and anything the data
/// can't support says so explicitly.
public struct BaselineReport: Equatable, Sendable {
    public let asOf: Date
    public let timeZone: TimeZone
    /// The history after de-duplication, treadmill tagging and the cadence-gap check.
    public let history: CleanedHistory
    /// Every run considered, by start time (empty when the options are invalid).
    public let runs: [BaselineRun]
    public let weeklyLoad: BaselineValue<WeeklyLoadBaseline>
    public let longRuns: BaselineValue<LongRunHistory>
    public let bestEfforts: BaselineValue<BestEffortsBaseline>
    public let lthr: BaselineValue<LTHRBaseline>
    public let peakHeartRate: BaselineValue<PeakHeartRate>
    public let easyPace: BaselineValue<EasyPaceBaseline>
    public let decoupling: BaselineValue<DecouplingBaseline>
    public let cadence: BaselineValue<CadenceTrend>
    public let restingHeartRate: BaselineValue<DailyMetricBaseline>
    public let hrv: BaselineValue<DailyMetricBaseline>
}

func baselineOrderedUnique(_ ids: [String]) -> [String] {
    var seen = Set<String>()
    return ids.filter { seen.insert($0).inserted }
}
