// Provisional plan rebuild (#55, #77): a thin wrapper around CoachCore's
// `ProvisionalRebuild.run`, which runs the steps and is tested on Linux. This
// file only supplies the app's clock, time zone, log and debug assertion.
//
// Not wired yet (#77): the app has no stored plan, no baseline built from
// HealthKit and no pain freezes in force, so nothing calls `run` yet. Once
// those exist, call it on launch and when the scene becomes active, then pass
// the attempt to `ProvisionalRebuild.CurrentPlan.apply` and persist the plan,
// its `retryAt`, `refusalNote` and `token` together. When `apply` returns
// `.replaced`, replace the plan's watch workouts; on `.stale`, do nothing (the
// next launch or foreground runs again). TODO(#50): nothing calls
// `WatchWorkoutSync.sync` yet.

import Foundation
import CoachCore
#if canImport(os)
import os
#endif

enum ProvisionalRebuildCheck {
    static func run(_ current: ProvisionalRebuild.CurrentPlan,
                    freezes: [DateInterval],
                    limits: GuardrailLimits = .default,
                    now: Date = Date(),
                    timeZone: TimeZone = .current,
                    baseline: (BaselineOptions) async -> BaselineReport) async -> ProvisionalRebuild.Attempt? {
        await ProvisionalRebuild.run(current, freezes: freezes, limits: limits, now: now, timeZone: timeZone,
                                     baseline: baseline,
                                     log: { log($0) },
                                     fail: { assertionFailure($0.message) })
    }

    private static func log(_ problem: ProvisionalRebuild.Problem) {
        #if canImport(os)
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "runningcoach", category: "ProvisionalRebuild")
            .fault("\(problem.message, privacy: .public)")
        #endif
    }
}
