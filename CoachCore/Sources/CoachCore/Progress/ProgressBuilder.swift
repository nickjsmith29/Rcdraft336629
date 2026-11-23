// TimeZone is Sendable on Apple SDKs but not yet in swift-corelibs-foundation
// (Linux, Swift 5.10); @preconcurrency keeps ProgressDashboard's Sendable conformance warning-free there.
@preconcurrency import Foundation

/// The F13 progress dashboard's data: one weekly series per metric, with
/// its 4- and 12-week changes. The charts (Swift Charts) draw from this; no
/// value here is a default for any runner.
public struct ProgressDashboard: Equatable, Sendable {
    /// The end of the dashboard: the date of every metric's latest point.
    public let asOf: Date
    public let timeZone: TimeZone
    /// False when `ProgressOptions.isValid` failed; every point is then invalid input.
    public let optionsAreValid: Bool
    /// The fixed heart rate easy pace is measured at, or nil when the runner
    /// has no LTHR yet and the options asked for their zone 2.
    public let easyHeartRate: Double?
    /// Running below this heart rate counts as easy (the start of zone 3, so the top of zone 2
    /// from the runner's current LTHR), or nil without an LTHR.
    public let easyCeiling: Double?
    /// The predictor's lookback for predicted times (`baseline.bestEffortLookbackDays`).
    /// It is longer than a 4-week change, so the two ends of a predicted-time
    /// change usually share best efforts; `ProgressSummary.sharedEvidence` says so.
    public let predictionLookbackDays: Int
    /// The runs as of `asOf` within the dashboard's longest lookback (from the
    /// baseline, see `ProgressBuilder.relevant`), by start time.
    public let runs: [BaselineRun]
    /// Metrics in dashboard order: the fitness signals that move first (easy
    /// pace, drift, resting HR, HRV, easy share), then load, cadence, best
    /// efforts and predicted race times.
    public let metrics: [ProgressMetric]

    public func metric(_ id: ProgressMetricID) -> ProgressMetric? { metrics.first { $0.id == id } }
}

/// Builds the F13 progress dashboard from the runner's history (SPEC.md F13).
///
/// Each point of a series is a `BaselineBuilder` report as of that date (one
/// a week, going back from `asOf`), so every value is computed exactly as the
/// F1 baseline computes it and cites the same evidence. Heuristics and choices:
/// - Easy pace is measured at one heart rate for the whole series: the
///   caller's, or the middle of zone 2 from the runner's *current* LTHR. Each
///   snapshot then uses `.bpm` of it, so a recomputed LTHR never moves the target.
/// - Easy pace, decoupling, best efforts and easy share use the trailing
///   `baseline.recentDays` at each snapshot (28 days by default, so a 4-week
///   change compares windows that share no run).
/// - Weekly load, load versus plan and cadence use the baseline's basis weeks:
///   the last `currentLoadWeeks` complete ISO weeks before the snapshot.
/// - Decoupling is rated lower-is-better with a floor of 0, so a negative
///   value (usually a data artefact) rates as no drift (SPEC.md 3.3).
/// - Predicted times run `BlendedPredictor` on the snapshot's recent best
///   efforts, recalculated weekly, with the predictor's full lookback
///   (`bestEffortLookbackDays`, as SPEC.md 3.9 predicts), so each point is the
///   prediction the runner would see that week. The lookback is longer than
///   the change spans, so the two ends of a change share most of their
///   evidence; the summary says so (`SharedEvidence`) rather than shortening
///   the window, which would give a series of predictions the app never shows
///   and more gaps. Pace at LTHR isn't measured yet, so the threshold method
///   doesn't contribute.
/// - Resting HR and HRV are the snapshot's 7-day averages, shown with the
///   60-day normal range.
/// - A change is the latest point minus the point that many weeks earlier,
///   rated with the metric's polarity and noise threshold (`ProgressNoise`).
public enum ProgressBuilder {
    /// Builds the dashboard.
    /// - Parameters:
    ///   - activities: the runner's history (raw; it is cleaned like the baseline's).
    ///   - efforts: runs marked as races or time trials, for LTHR and zones.
    ///   - dailyHealth: daily resting HR and HRV readings.
    ///   - plan: planned sessions, for weekly load versus plan. With none, that metric is left out.
    public static func build(activities: [Activity],
                             efforts: [EffortMark] = [],
                             dailyHealth: [DailyHealthSample] = [],
                             plan: [PlannedWorkout] = [],
                             options: ProgressOptions) -> ProgressDashboard {
        let tz = options.baseline.timeZone
        guard options.isValid else {
            return invalid(options: options, hasPlan: !plan.isEmpty)
        }
        let cal = PlanCalendar.calendar(timeZone: tz)
        let latest = BaselineBuilder.build(activities: relevant(activities, for: options.baseline),
                                           efforts: efforts, dailyHealth: dailyHealth, options: options.baseline)
        let fixedHR: Double?
        switch options.baseline.easyHeartRate {
        case .bpm(let bpm): fixedHR = bpm
        case .zoneTwoMidpoint:
            fixedHR = latest.lthr.value.map { ($0.zones.lowerBound(.z2) + $0.zones.easyCeiling) / 2 }
        }
        let ceiling = latest.lthr.value?.zones.easyCeiling

        // Snapshots oldest first; the last is `latest`.
        let n = options.snapshotWeeks
        var reports: [BaselineReport] = []
        for k in stride(from: n, through: 1, by: -1) {
            var o = options.baseline
            o.asOf = BaselineBuilder.addDays(-7 * k, to: options.baseline.asOf, cal)
            if let fixedHR { o.easyHeartRate = .bpm(fixedHR) }
            reports.append(BaselineBuilder.build(activities: relevant(activities, for: o), efforts: efforts,
                                                 dailyHealth: dailyHealth, options: o))
        }
        reports.append(latest)

        let snaps = reports.map { Snapshot(report: $0, options: options, cal: cal) }
        let noise = options.noise
        func metric(_ id: ProgressMetricID, _ unit: ProgressUnit, _ polarity: ProgressPolarity,
                    _ threshold: NoiseThreshold, _ point: (Snapshot) -> ProgressPoint) -> ProgressMetric {
            ProgressMetric(id: id, unit: unit, polarity: polarity, noise: threshold,
                           series: snaps.map(point), changeWeeks: options.changeWeeks)
        }

        var metrics: [ProgressMetric] = [
            metric(.easyPace, .secondsPerKilometer, .lowerIsBetter, noise.easyPace) {
                fixedHR == nil ? $0.missing(.baseline(.needsLTHR)) : $0.easyPace()
            },
            metric(.longRunDecoupling, .percent, .lowerIsBetterWithFloor(0), noise.longRunDecoupling) {
                $0.decoupling()
            },
            metric(.restingHeartRate, .beatsPerMinute, .lowerIsBetter, noise.restingHeartRate) {
                $0.daily($0.report.restingHeartRate)
            },
            metric(.hrv, .milliseconds, .higherIsBetter, noise.hrv) { $0.daily($0.report.hrv) },
            metric(.easyShare, .ratio, .towardRange(options.easyShareTarget), noise.easyShare) {
                $0.easyShare(ceiling: ceiling)
            },
        ]
        if !plan.isEmpty {
            metrics.append(metric(.loadVersusPlan, .ratio, .towardRange(options.loadVersusPlanTarget),
                                  noise.loadVersusPlan) { $0.loadVersusPlan(plan) })
        }
        metrics.append(metric(.weeklyLoad, .seconds, .informational, noise.weeklyLoad) { $0.weeklyLoad() })
        metrics.append(metric(.cadence, .stepsPerMinute, options.cadencePolarity, noise.cadence) { $0.cadence() })
        for meters in orderedUnique(options.bestEffortDistances) {
            metrics.append(metric(.bestEffort(meters: meters), .seconds, .lowerIsBetter, noise.bestEffort) {
                $0.bestEffort(meters: meters)
            })
        }
        for meters in orderedUnique(options.predictionTargets) {
            metrics.append(metric(.predictedTime(meters: meters), .seconds, .lowerIsBetter, noise.predictedTime) {
                $0.prediction(meters: meters)
            })
        }
        return ProgressDashboard(asOf: options.baseline.asOf, timeZone: tz, optionsAreValid: true,
                                 easyHeartRate: fixedHR, easyCeiling: ceiling,
                                 predictionLookbackDays: options.baseline.bestEffortLookbackDays,
                                 runs: latest.runs, metrics: metrics)
    }

    /// The activities one snapshot needs: every activity that started within its
    /// longest lookback (plus a day), and the last run before that. This is
    /// only a speed-up, so a long history isn't re-read in full for every
    /// week: no value the dashboard uses depends on older runs, except that
    /// the weekly-load window starts at the week of the first run, which the
    /// one older run keeps where the whole history would put it. (All-time
    /// personal records and history-wide cadence gaps do depend on older runs;
    /// the dashboard uses neither.)
    ///
    /// Known gaps, both theoretical and outside every window the values use:
    /// a duplicate pair (`ActivityDeduplicator`) split by the cutoff is not
    /// de-duplicated against the dropped copy, which can matter only if the
    /// pair also straddles an ISO-week boundary at the start of the load
    /// window; and the reasons inside a gap can differ from the whole
    /// history's (for example a mark on an older run reads `.notInHistory`
    /// instead of `.outsideLookback`).
    static func relevant(_ activities: [Activity], for o: BaselineOptions) -> [Activity] {
        let days = max(o.recentDays, o.lthrLookbackDays, o.bestEffortLookbackDays, 7 * o.loadWindowWeeks) + 1
        let cutoff = o.asOf.addingTimeInterval(-Double(days) * 86_400)
        var kept = activities.filter { $0.start >= cutoff }
        let older = activities.filter { $0.sport == .run && $0.start.timeIntervalSinceReferenceDate.isFinite && $0.start < cutoff }
        if let last = older.max(by: { $0.start < $1.start }) { kept.append(last) }
        return kept
    }

    static func orderedUnique(_ xs: [Double]) -> [Double] {
        var seen = Set<Double>()
        return xs.filter { seen.insert($0).inserted }
    }

    static func invalid(options: ProgressOptions, hasPlan: Bool) -> ProgressDashboard {
        var ids: [ProgressMetricID] = [.easyPace, .longRunDecoupling, .restingHeartRate, .hrv, .easyShare]
        if hasPlan { ids.append(.loadVersusPlan) }
        ids += [.weeklyLoad, .cadence]
        let point = ProgressPoint(asOf: options.baseline.asOf, reading: .missing(.baseline(.invalidInput)))
        let metrics = ids.map {
            ProgressMetric(id: $0, unit: .ratio, polarity: .informational, noise: .init(), series: [point],
                           changeWeeks: options.changeWeeks)
        }
        return ProgressDashboard(asOf: options.baseline.asOf, timeZone: options.baseline.timeZone,
                                 optionsAreValid: false, easyHeartRate: nil, easyCeiling: nil,
                                 predictionLookbackDays: options.baseline.bestEffortLookbackDays, runs: [],
                                 metrics: metrics)
    }

    // MARK: - One snapshot

    /// The metric values from one baseline report.
    struct Snapshot {
        let report: BaselineReport
        let options: ProgressOptions
        let cal: Calendar

        var asOf: Date { report.asOf }
        var baseline: BaselineOptions { options.baseline }

        func missing(_ gap: ProgressGap) -> ProgressPoint { ProgressPoint(asOf: asOf, reading: .missing(gap)) }

        func point<V>(_ value: BaselineValue<V>, _ make: (V) -> ProgressPoint) -> ProgressPoint {
            switch value {
            case .available(let v): return make(v)
            case .insufficient(let why): return missing(.insufficient(why))
            }
        }

        /// Runs that started in the trailing window (`baseline.recentDays`), as the baseline counts them.
        var windowRuns: [BaselineRun] {
            let earliest = asOf.addingTimeInterval(-Double(baseline.recentDays) * 86_400)
            return report.runs.filter { $0.start >= earliest }
        }

        func activity(_ id: String) -> Activity? { report.history.activities.first { $0.id == id } }

        func easyPace() -> ProgressPoint {
            point(report.easyPace) {
                ProgressPoint(asOf: asOf, reading: .value($0.secondsPerKilometer),
                              evidence: ProgressEvidence(activityIDs: $0.evidenceActivityIDs))
            }
        }

        func decoupling() -> ProgressPoint {
            point(report.decoupling) {
                ProgressPoint(asOf: asOf, reading: .value($0.typicalPercent),
                              evidence: ProgressEvidence(activityIDs: $0.evidenceActivityIDs))
            }
        }

        func daily(_ value: BaselineValue<DailyMetricBaseline>) -> ProgressPoint {
            point(value) { b in
                switch b.sevenDayAverage {
                case .insufficient(let why): return missing(.insufficient(why))
                case .available(let avg):
                    let weekStart = BaselineBuilder.addDays(-6, to: cal.startOfDay(for: asOf), cal)
                    return ProgressPoint(asOf: asOf, reading: .value(avg), band: b.normalRange,
                                         evidence: ProgressEvidence(days: b.days.filter { $0.day >= weekStart }.map(\.day)))
                }
            }
        }

        func weeklyLoad() -> ProgressPoint {
            point(report.weeklyLoad) {
                ProgressPoint(asOf: asOf, reading: .value($0.currentWeeklyMovingSeconds),
                              evidence: ProgressEvidence(activityIDs: $0.evidenceActivityIDs))
            }
        }

        /// Actual over planned moving time across the basis weeks that had planned volume.
        func loadVersusPlan(_ plan: [PlannedWorkout]) -> ProgressPoint {
            point(report.weeklyLoad) { load in
                let basis = Set(load.basisWeekStarts)
                var actual = 0.0, planned = 0.0
                var runIDs: [String] = [], planIDs: [String] = []
                for week in load.weeks where basis.contains(week.weekStart) {
                    let inWeek = plan.filter { $0.date >= week.weekStart && $0.date < week.weekEnd }
                    guard !inWeek.isEmpty else { continue }
                    let planWeek = PlanWeek(weekStart: week.weekStart, weekEnd: week.weekEnd, workouts: inWeek)
                    guard let volume = planWeek.volume(.time) else { return missing(.plannedVolumeUnknown) }
                    guard volume > 0 else { continue }
                    actual += week.movingSeconds
                    planned += volume
                    runIDs += week.activityIDs
                    planIDs += planWeek.workouts.map(\.id)
                }
                guard planned > 0 else { return missing(.noPlannedSessions) }
                return ProgressPoint(asOf: asOf, reading: .value(actual / planned),
                                     evidence: ProgressEvidence(activityIDs: runIDs, plannedWorkoutIDs: planIDs))
            }
        }

        /// Mean cadence of the runs in the basis weeks. Unlike the baseline's
        /// `recentStepsPerMinute`, it never falls back to older runs, so two
        /// snapshots never share their evidence by accident.
        func cadence() -> ProgressPoint {
            guard let load = report.weeklyLoad.value else {
                return missing(.insufficient(report.weeklyLoad.insufficiency ?? .init(.noRuns)))
            }
            return point(report.cadence) { trend in
                let current = PlanCalendar.weekStart(containing: asOf, timeZone: baseline.timeZone)
                guard let first = load.basisWeekStarts.first else { return missing(.baseline(.noCompleteWeek)) }
                let runs = trend.runs.filter { $0.start >= first && $0.start < current }
                guard !runs.isEmpty else {
                    return missing(.insufficient(.init(.noCadence)))
                }
                return ProgressPoint(asOf: asOf,
                                     reading: .value(runs.reduce(0) { $0 + $1.stepsPerMinute } / Double(runs.count)),
                                     evidence: ProgressEvidence(activityIDs: runs.map(\.activityID)))
            }
        }

        /// The fastest outdoor stretch covering `meters` in the trailing window
        /// (`BaselineBuilder.fastestStretch`, the baseline's best-effort rule).
        func bestEffort(meters: Double) -> ProgressPoint {
            let window = windowRuns
            guard !window.isEmpty else { return missing(.baseline(.noRuns)) }
            let treadmill = window.filter(\.isTreadmill).map { ExcludedRun(activityID: $0.activityID, reason: .treadmill) }
            var best: (seconds: Double, id: String, date: Date)?
            var anyDistance = false
            for run in window where !run.isTreadmill {
                guard let a = activity(run.activityID) else { continue }
                if a.presentStreams.contains(.distance) { anyDistance = true }
                guard let s = BaselineBuilder.fastestStretch(a.samples, meters: meters) else { continue }
                let date = a.start.addingTimeInterval(s.startT)
                if best.map({ s.seconds < $0.seconds || (s.seconds == $0.seconds && date < $0.date) }) ?? true {
                    best = (s.seconds, a.id, date)
                }
            }
            guard let best else {
                return missing(anyDistance ? .noEffortAtDistance : .insufficient(.init(.noDistanceStreams, excluded: treadmill)))
            }
            return ProgressPoint(asOf: asOf, reading: .value(best.seconds),
                                 evidence: ProgressEvidence(activityIDs: [best.id]))
        }

        /// The blended prediction's central value, with its range as the band.
        func prediction(meters: Double) -> ProgressPoint {
            point(report.bestEfforts) { efforts in
                let recent = efforts.recent
                let weekly = report.weeklyLoad.value
                let weeklyMeters = weekly.flatMap { $0.distanceIsComplete ? $0.currentWeeklyDistanceMeters : nil }
                let p = BlendedPredictor.predict(targetMeters: meters, efforts: recent.map(\.bestEffort), asOf: asOf,
                                                 lookbackDays: baseline.bestEffortLookbackDays,
                                                 typicalWeeklyMeters: weeklyMeters)
                guard let range = p.range else { return missing(.noPrediction(skipped: p.skipped)) }
                let used = p.estimates.flatMap(\.evidence)
                var ids = recent.filter { e in used.contains(e.bestEffort) }.map(\.activityID)
                if p.estimates.contains(where: { $0.method == .vickersVertosick }), let weekly {
                    ids += weekly.evidenceActivityIDs
                }
                return ProgressPoint(asOf: asOf, reading: .value(range.central), band: range.low...range.high,
                                     evidence: ProgressEvidence(activityIDs: baselineOrderedUnique(ids)))
            }
        }

        /// Share of heart-rate-covered moving time below `ceiling` (exclusive, as
        /// `HRZones.easyCeiling` is the start of zone 3), over
        /// every run in the trailing window (treadmill included, since it is by
        /// heart rate). Runs without a usable heart rate are left out and listed.
        func easyShare(ceiling: Double?) -> ProgressPoint {
            guard let ceiling else { return missing(.baseline(.needsLTHR)) }
            let window = windowRuns
            guard !window.isEmpty else { return missing(.baseline(.noRuns)) }
            let plausible = baseline.decoupling.plausibleHeartRate
            var total = 0.0, easy = 0.0
            var used: [String] = []
            var excluded: [ExcludedRun] = []
            for run in window {
                guard let a = activity(run.activityID) else { continue }
                let timeline = MovingTime.held(a.samples, streams: [.heartRate: { plausible.contains($0) }],
                                               maximumHoldSeconds: baseline.decoupling.maximumHoldSeconds)
                guard let all = BaselineBuilder.heldMean(timeline, of: .heartRate), all.seconds > 0 else {
                    excluded.append(ExcludedRun(activityID: a.id, reason: .noHeartRate)); continue
                }
                let below = BaselineBuilder.heldMean(timeline, of: .heartRate) { ($0[.heartRate] ?? .infinity) < ceiling }
                total += all.seconds
                easy += below?.seconds ?? 0
                used.append(a.id)
            }
            guard total > 0 else { return missing(.insufficient(.init(.noHeartRateData, excluded: excluded))) }
            return ProgressPoint(asOf: asOf, reading: .value(easy / total),
                                 evidence: ProgressEvidence(activityIDs: used))
        }
    }
}
