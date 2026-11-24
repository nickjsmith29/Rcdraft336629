// Watch sync (SPEC.md F10): puts the next two weeks of planned sessions in the
// Apple Watch Workout app as WorkoutKit custom workouts.
//
// All decisions (which sessions, steps, goals, alert ranges, what to replace)
// are made in CoachCore by `WatchSyncMapper` and `WatchSyncReconciler`, which
// are tested on Linux. This file only converts their neutral description into
// WorkoutKit types and calls the scheduler. It builds only with the iOS SDK.

#if canImport(WorkoutKit)
import Foundation
import HealthKit
import WorkoutKit
import CoachCore

/// Main-actor bound so the scheduler is always used from one place.
@MainActor
enum WatchWorkoutSync {
    enum SyncError: Error {
        /// The runner hasn't allowed the app to schedule workouts on the watch.
        case notAuthorized
        /// The earlier copy of this workout couldn't be removed, so it wasn't
        /// scheduled again (that would leave two copies on the watch).
        case earlierCopyNotRemoved
    }

    /// What one sync did, for the app to show.
    struct Outcome {
        /// A scheduler call that failed. The sync carries on past it.
        struct Failure {
            enum Operation { case remove, schedule }
            let operation: Operation
            let workoutID: UUID
            /// The session id, for a workout this sync tried to schedule.
            let sessionID: String?
            let error: Error
        }

        let removed: Int
        let scheduled: [WatchWorkout]
        let skipped: [WatchSyncSkip]
        let failures: [Failure]
    }

    /// Maps the plan's next two weeks and replaces what this app has
    /// scheduled on the watch. Safe to call again at any time: workout ids are
    /// stable, so a re-sync replaces workouts instead of duplicating them.
    /// All removals run first, then all schedules; a failed call is recorded
    /// in `Outcome.failures` and the rest still run.
    static func sync(plan: TrainingPlan, zones: WatchSyncZones, now: Date = Date(),
                     timeZone: TimeZone = .current) async throws -> Outcome {
        let scheduler = WorkoutScheduler.shared
        guard await scheduler.requestAuthorization() == .authorized else { throw SyncError.notAuthorized }

        let existingPlans = await scheduler.scheduledWorkouts
        func ref(_ s: ScheduledWorkoutPlan) -> WatchScheduledWorkout {
            WatchScheduledWorkout(id: s.plan.id, date: scheduleDate(s.date), isComplete: s.complete)
        }
        let batch = WatchSyncMapper.batch(for: plan, zones: zones, from: now, timeZone: timeZone)
        // The reconciler cuts the batch to the room the kept workouts leave.
        let changes = WatchSyncReconciler.changes(existing: existingPlans.map(ref), batch: batch, timeZone: timeZone,
                                                  maxScheduled: WorkoutScheduler.maxAllowedScheduledWorkoutCount)

        var failures: [Outcome.Failure] = []
        let toRemove = Set(changes.remove)
        var removed = 0
        var notRemoved = Set<UUID>()
        for scheduled in existingPlans where toRemove.contains(ref(scheduled)) {
            do {
                try await scheduler.remove(scheduled.plan, at: scheduled.date)
                removed += 1
            } catch {
                notRemoved.insert(scheduled.plan.id)
                failures.append(.init(operation: .remove, workoutID: scheduled.plan.id, sessionID: nil, error: error))
            }
        }
        var scheduledWorkouts: [WatchWorkout] = []
        for workout in changes.schedule {
            guard !notRemoved.contains(workout.id) else {
                failures.append(.init(operation: .schedule, workoutID: workout.id, sessionID: workout.sessionID,
                                      error: SyncError.earlierCopyNotRemoved))
                continue
            }
            do {
                try await scheduler.schedule(workoutPlan(workout), at: dateComponents(workout.scheduleDate))
                scheduledWorkouts.append(workout)
            } catch {
                failures.append(.init(operation: .schedule, workoutID: workout.id, sessionID: workout.sessionID,
                                      error: error))
            }
        }
        return Outcome(removed: removed, scheduled: scheduledWorkouts, skipped: changes.skipped,
                       failures: failures)
    }

    // MARK: Conversion

    static func workoutPlan(_ w: WatchWorkout) -> WorkoutPlan {
        WorkoutPlan(.custom(customWorkout(w)), id: w.id)
    }

    static func customWorkout(_ w: WatchWorkout) -> CustomWorkout {
        let blocks = w.blocks.map { block in
            IntervalBlock(steps: block.steps.map(intervalStep), iterations: block.iterations)
        }
        return CustomWorkout(activity: .running,
                             location: w.location == .indoor ? .indoor : .outdoor,
                             displayName: w.displayName,
                             warmup: w.warmup.map(workoutStep),
                             blocks: blocks,
                             cooldown: w.cooldown.map(workoutStep))
    }

    static func intervalStep(_ s: WatchIntervalStep) -> IntervalStep {
        var step = IntervalStep(s.purpose == .recovery ? .recovery : .work)
        step.step = workoutStep(s.step)
        return step
    }

    static func workoutStep(_ s: WatchStep) -> WorkoutStep {
        var step = WorkoutStep(goal: workoutGoal(s.goal))
        step.alert = s.alert.map(workoutAlert)
        return step
    }

    static func workoutGoal(_ g: WatchGoal) -> WorkoutGoal {
        switch g {
        case .time(let seconds): return .time(seconds, .seconds)
        case .distance(let meters): return .distance(meters, .meters)
        case .open: return .open
        }
    }

    /// Beats or steps per minute as a frequency (1/60 Hz each).
    static let perMinute = UnitFrequency(symbol: "/min", converter: UnitConverterLinear(coefficient: 1.0 / 60.0))

    static func workoutAlert(_ a: WatchAlert) -> any WorkoutAlert {
        let lo = a.range.lowerBound, hi = a.range.upperBound
        let metric: WorkoutAlertMetric = a.aggregation == .average ? .average : .current
        switch a.metric {
        case .heartRate:
            return HeartRateRangeAlert(target: Measurement(value: lo, unit: perMinute)...Measurement(value: hi, unit: perMinute))
        case .cadence:
            return CadenceRangeAlert(target: Measurement(value: lo, unit: perMinute)...Measurement(value: hi, unit: perMinute))
        case .speed:
            let unit = UnitSpeed.metersPerSecond
            return SpeedRangeAlert(target: Measurement(value: lo, unit: unit)...Measurement(value: hi, unit: unit),
                                   metric: metric)
        case .power:
            let unit = UnitPower.watts
            let target = Measurement(value: lo, unit: unit)...Measurement(value: hi, unit: unit)
            // The metric choice needs iOS 17.4; earlier systems get the default (current) metric.
            if #available(iOS 17.4, *) {
                return PowerRangeAlert(target: target, metric: metric)
            }
            return PowerRangeAlert(target: target)
        }
    }

    static func dateComponents(_ d: WatchScheduleDate) -> DateComponents {
        DateComponents(year: d.year, month: d.month, day: d.day, hour: d.hour, minute: d.minute)
    }

    static func scheduleDate(_ c: DateComponents) -> WatchScheduleDate {
        WatchScheduleDate(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0, hour: c.hour ?? 0,
                          minute: c.minute ?? 0)
    }
}
#endif
