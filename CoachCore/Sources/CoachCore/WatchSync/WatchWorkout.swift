import Foundation

// A neutral description of a watch workout (SPEC.md F10). It mirrors
// WorkoutKit's `CustomWorkout` model (warm-up, interval blocks with
// iterations, steps with a goal and at most one alert, cool-down) without
// importing WorkoutKit, so the mapping can be tested on Linux. The app turns
// it into a `CustomWorkout` / `WorkoutPlan` and schedules it.

/// What a step runs until: a time, a distance, or until the runner moves on.
public enum WatchGoal: Equatable, Hashable, Sendable {
    case time(seconds: Double)
    case distance(meters: Double)
    /// No goal: the step lasts until the runner moves on.
    case open
}

/// The metrics a WorkoutKit alert can watch (F10: HR, cadence, power, speed).
public enum WatchAlertMetric: String, CaseIterable, Equatable, Hashable, Sendable {
    /// Heart rate, in beats per minute.
    case heartRate
    /// Running speed, in meters per second (the plan's pace target, inverted).
    case speed
    /// Running power, in watts.
    case power
    /// Cadence, in steps per minute (both feet).
    case cadence
}

/// Whether an alert watches the current value or the step's running average
/// (WorkoutKit's `WorkoutAlertMetric`).
public enum WatchAlertAggregation: String, Equatable, Hashable, Sendable {
    case current
    case average
}

/// A range alert on one metric. The watch alerts when the runner leaves the
/// range. Units: bpm for heart rate, m/s for speed, W for power, steps/min for cadence.
public struct WatchAlert: Equatable, Hashable, Sendable {
    public let metric: WatchAlertMetric
    public let range: ClosedRange<Double>
    public let aggregation: WatchAlertAggregation

    public init(metric: WatchAlertMetric, range: ClosedRange<Double>, aggregation: WatchAlertAggregation) {
        self.metric = metric
        self.range = range
        self.aggregation = aggregation
    }
}

/// Why a step carries no alert on a metric. Every metric a step does not
/// alert on is listed with one of these, so the app can say why.
public enum WatchAlertOmissionReason: Equatable, Hashable, Sendable {
    /// No LTHR, so no heart-rate zones (SPEC 3.2): no heart-rate alert.
    case noHeartRateZones
    /// The session has no heart-rate target (for example a quality session or
    /// race with no prescription, whose effort isn't known). Also given for
    /// power and cadence, whose bands are looked up by the step's heart-rate zones.
    case noHeartRateTarget
    /// The plan sets no pace for this step (no pace data, or an intensity
    /// the plan guides by heart rate only).
    case noPaceTarget
    /// The runner has no power data for this step's heart-rate zones.
    case noPowerData
    /// The runner has no cadence data for this step's heart-rate zones.
    case noCadenceData
    /// The values were NaN, infinite, non-positive or an empty range.
    case invalidRange
    /// A recovery jog between repetitions: heart rate stays raised from the
    /// rep before (SPEC 3.1), so a range alert would only nag. Heuristic.
    case recoveryStep
    /// The metric had a usable range, but WorkoutKit takes one alert per
    /// step and `chosen` was preferred.
    case oneAlertPerStep(chosen: WatchAlertMetric)
}

public struct WatchAlertOmission: Equatable, Hashable, Sendable {
    public let metric: WatchAlertMetric
    public let reason: WatchAlertOmissionReason

    public init(metric: WatchAlertMetric, reason: WatchAlertOmissionReason) {
        self.metric = metric
        self.reason = reason
    }
}

/// One step: a goal and at most one alert (WorkoutKit's `WorkoutStep`).
public struct WatchStep: Equatable, Hashable, Sendable {
    public let goal: WatchGoal
    public let alert: WatchAlert?
    /// Every metric without an alert, in `WatchAlertMetric.allCases` order, with the reason.
    public let omittedAlerts: [WatchAlertOmission]
    /// The plan's intensity for the step, for display; nil when the session had no prescription.
    public let intensity: WorkoutIntensity?

    public init(goal: WatchGoal, alert: WatchAlert?, omittedAlerts: [WatchAlertOmission], intensity: WorkoutIntensity?) {
        self.goal = goal
        self.alert = alert
        self.omittedAlerts = omittedAlerts
        self.intensity = intensity
    }
}

/// A step inside an interval block (WorkoutKit's `IntervalStep`).
public struct WatchIntervalStep: Equatable, Hashable, Sendable {
    public enum Purpose: String, Equatable, Hashable, Sendable {
        case work
        case recovery
    }

    public let purpose: Purpose
    public let step: WatchStep

    public init(purpose: Purpose, step: WatchStep) {
        self.purpose = purpose
        self.step = step
    }
}

/// Steps repeated `iterations` times (WorkoutKit's `IntervalBlock`).
public struct WatchIntervalBlock: Equatable, Hashable, Sendable {
    public let steps: [WatchIntervalStep]
    public let iterations: Int

    public init(steps: [WatchIntervalStep], iterations: Int) {
        self.steps = steps
        self.iterations = iterations
    }
}

/// A calendar date and time in the runner's time zone, the shape WorkoutKit's
/// scheduler takes as `DateComponents`.
public struct WatchScheduleDate: Equatable, Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let hour: Int
    public let minute: Int

    public init(year: Int, month: Int, day: Int, hour: Int, minute: Int) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
    }

    /// `date` as seen on a wall clock in `timeZone` (Gregorian).
    public init(_ date: Date, timeZone: TimeZone) {
        let c = PlanCalendar.calendar(timeZone: timeZone).dateComponents([.year, .month, .day, .hour, .minute], from: date)
        self.init(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0, hour: c.hour ?? 0, minute: c.minute ?? 0)
    }

    /// True when a session at this time has started by `now`, to the minute
    /// (the scheduler's resolution). The mapper and the reconciler both use it,
    /// so they agree on which of today's sessions are already under way.
    public func hasStarted(by now: Date, timeZone: TimeZone) -> Bool {
        self <= WatchScheduleDate(now, timeZone: timeZone)
    }

    public static func < (lhs: WatchScheduleDate, rhs: WatchScheduleDate) -> Bool {
        (lhs.year, lhs.month, lhs.day, lhs.hour, lhs.minute) < (rhs.year, rhs.month, rhs.day, rhs.hour, rhs.minute)
    }
}

/// Where the session is run (WorkoutKit's `HKWorkoutSessionLocationType`).
public enum WatchWorkoutLocation: String, Equatable, Hashable, Sendable {
    case outdoor
    case indoor
}

/// One planned session as a custom running workout for the Workout app (F10).
public struct WatchWorkout: Equatable, Hashable, Sendable {
    /// Stable id derived from the session id (`WatchSyncID`), so a re-sync
    /// replaces the workout instead of adding a second copy.
    public let id: UUID
    /// The `PlannedWorkout.id` it came from.
    public let sessionID: String
    /// When the session starts.
    public let date: Date
    /// `date` on the runner's wall clock, for the scheduler.
    public let scheduleDate: WatchScheduleDate
    /// Short name shown on the watch, from the session kind.
    public let displayName: String
    /// The prescription's purpose, for the app to show, in `WatchSyncOptions.units`
    /// (`PlanFormatting.purpose(of:units:)`); nil without one.
    public let purpose: String?
    public let location: WatchWorkoutLocation
    public let warmup: WatchStep?
    public let blocks: [WatchIntervalBlock]
    public let cooldown: WatchStep?

    public init(id: UUID, sessionID: String, date: Date, scheduleDate: WatchScheduleDate, displayName: String,
                purpose: String?, location: WatchWorkoutLocation, warmup: WatchStep?, blocks: [WatchIntervalBlock],
                cooldown: WatchStep?) {
        self.id = id
        self.sessionID = sessionID
        self.date = date
        self.scheduleDate = scheduleDate
        self.displayName = displayName
        self.purpose = purpose
        self.location = location
        self.warmup = warmup
        self.blocks = blocks
        self.cooldown = cooldown
    }

    /// Every step in the order the watch runs them, blocks expanded by their iterations.
    public var expandedSteps: [WatchStep] {
        var out: [WatchStep] = []
        if let warmup { out.append(warmup) }
        for b in blocks {
            for _ in 0..<max(0, b.iterations) { out += b.steps.map(\.step) }
        }
        if let cooldown { out.append(cooldown) }
        return out
    }

    /// Total of the time goals in seconds (distance and open steps add nothing).
    public var timedSeconds: Double {
        expandedSteps.reduce(0) { total, s in
            if case .time(let t) = s.goal { return total + t }
            return total
        }
    }
}

/// A session in the window that was not sent, and why.
public struct WatchSyncSkip: Equatable, Hashable, Sendable {
    public enum Reason: Equatable, Hashable, Sendable {
        /// A planned rest day: nothing to run.
        case restDay
        /// The duration (or a segment's duration) is NaN, infinite or not positive.
        case invalidDuration
        /// Another session in the window has the same id; the first one is kept.
        case duplicateID
        /// Over the scheduler's limit on scheduled workouts; the latest sessions
        /// go first. `limit` is how many workouts this sync could send.
        case overScheduleLimit(limit: Int)
        /// The watch already has this session as completed (`WatchSyncReconciler`).
        case alreadyCompleted
        /// The session's start time today has already passed. It isn't sent
        /// again at a time in the past; a copy already on the watch stays
        /// (`WatchSyncReconciler`), so the runner can still start it.
        case startedBeforeNow
    }

    public let sessionID: String
    public let date: Date
    public let reason: Reason

    public init(sessionID: String, date: Date, reason: Reason) {
        self.sessionID = sessionID
        self.date = date
        self.reason = reason
    }
}

/// The workouts to put on the watch for one window (F10).
public struct WatchSyncBatch: Equatable, Sendable {
    /// The moment the batch was built for (the sync's "now").
    public let from: Date
    /// Midnight on the first day of the window, in the runner's time zone.
    public let windowStart: Date
    /// Midnight after the last day; the window covers `windowStart ..< windowEnd`.
    public let windowEnd: Date
    /// The workouts in date order.
    public let workouts: [WatchWorkout]
    /// Sessions in the window that were left out, in date order.
    public let skipped: [WatchSyncSkip]

    /// Ids of the sessions skipped as `startedBeforeNow`: the only scheduled
    /// incomplete workouts from today that a re-sync keeps.
    public var startedBeforeNowIDs: Set<UUID> {
        Set(skipped.filter { $0.reason == .startedBeforeNow }.map { WatchSyncID.uuid(forSessionID: $0.sessionID) })
    }

    public init(from: Date, windowStart: Date, windowEnd: Date, workouts: [WatchWorkout], skipped: [WatchSyncSkip]) {
        self.from = from
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.workouts = workouts
        self.skipped = skipped
    }
}
