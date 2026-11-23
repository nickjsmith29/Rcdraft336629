// TimeZone is Sendable on Apple SDKs but not yet in swift-corelibs-foundation
// (Linux, Swift 5.10); @preconcurrency keeps BaselineOptions' Sendable conformance warning-free there.
@preconcurrency import Foundation

/// The heart rate at which the baseline measures easy pace (SPEC.md section 2, F1).
public enum EasyHeartRate: Equatable, Sendable {
    /// A heart rate the caller chose, in bpm (for example one the runner set).
    case bpm(Double)
    /// The middle of the runner's own zone 2 (`HRZones`, Friel split of
    /// SPEC.md 3.2): halfway between the zone-2 floor and `easyCeiling`.
    /// Needs an LTHR estimate from the same history.
    case zoneTwoMidpoint
}

/// Inputs and tunable thresholds for `BaselineBuilder`. `asOf` and `timeZone`
/// must come from the caller. Every other default is a heuristic, labeled as
/// such, and none stands for a particular runner.
public struct BaselineOptions: Equatable, Sendable {
    /// The report describes the history up to and including this moment; later
    /// activities and readings are ignored.
    public var asOf: Date
    /// Weeks are ISO weeks (Monday 00:00 to Monday 00:00) and days are calendar
    /// days in this time zone.
    public var timeZone: TimeZone

    /// Weeks of weekly load and long runs listed, current week included. Heuristic: 12.
    public var loadWindowWeeks: Int
    /// Complete weeks averaged for the current weekly load. Heuristic: 4, the
    /// usual chronic-load window (SPEC.md 3.5).
    public var currentLoadWeeks: Int
    /// Days of history used for easy pace and typical decoupling, so they
    /// describe current fitness. Heuristic: 42 (6 weeks).
    public var recentDays: Int
    /// Days of marked efforts used for LTHR and for the observed peak heart rate.
    public var lthrLookbackDays: Int
    /// Days counted as "recent" for best efforts, matching the predictor's window.
    public var bestEffortLookbackDays: Int
    /// Distances, in meters, searched for best efforts within each run.
    public var bestEffortDistances: [Double]

    public var easyHeartRate: EasyHeartRate
    /// Samples within ± this many bpm of the easy heart rate count as at it. Heuristic: 3.
    public var easyHeartRateBandBPM: Double
    /// A run needs at least this much moving time in the band to give an easy
    /// pace. Heuristic: 5 minutes.
    public var minimumSecondsInBand: Double
    /// Seconds skipped at the start of a run for easy pace, because heart rate
    /// lags effort at first. Heuristic: 5 minutes.
    public var warmUpSeconds: Double
    /// Runs needed for a typical easy pace or typical decoupling. Heuristic: 3.
    public var minimumRunsForTypical: Int
    /// A marked race or trial needs a usable heart rate for at least this share
    /// of the moving time that counts, or it is left out. Heuristic: the
    /// decoupling default (0.8), so one stray reading can't set LTHR.
    public var minimumHeartRateCoverage: Double
    /// Options passed to `Decoupling.compute`. Its `maximumHoldSeconds` is the
    /// single hold limit for the whole report: moving time, and how long a
    /// reading is carried forward in every time-weighted mean and in heart-rate
    /// coverage, so coverage here always matches `Decoupling`'s.
    public var decoupling: DecouplingOptions

    /// Peak heart rate must be held this long, so one strap spike doesn't count.
    /// Consecutive samples in the hold may be at most half this far apart. Heuristic: 20 s.
    public var peakHoldSeconds: Double

    /// Runs with cadence needed for a cadence slope. Heuristic: 4.
    public var cadenceMinimumRuns: Int
    /// Days those runs must span for a slope. Heuristic: 14.
    public var cadenceMinimumSpanDays: Double

    /// Calendar days in the resting-HR and HRV normal range (SPEC.md 3.4: 60).
    public var healthWindowDays: Int
    /// Days with a reading needed for a normal range. Heuristic: 14.
    public var minimumHealthDays: Int
    /// Days with a reading in the last 7 needed for a 7-day average. Heuristic: 3,
    /// so one reading never stands for the week (SPEC.md 3.4).
    public var minimumSevenDayReadings: Int
    /// Half-width of the normal range in standard deviations. Heuristic: 1.
    public var normalRangeSD: Double

    public init(asOf: Date,
                timeZone: TimeZone,
                loadWindowWeeks: Int = 12,
                currentLoadWeeks: Int = 4,
                recentDays: Int = 42,
                lthrLookbackDays: Int = LTHREstimator.defaultLookbackDays,
                bestEffortLookbackDays: Int = BlendedPredictor.defaultLookbackDays,
                bestEffortDistances: [Double] = BaselineOptions.standardDistances,
                easyHeartRate: EasyHeartRate = .zoneTwoMidpoint,
                easyHeartRateBandBPM: Double = 3,
                minimumSecondsInBand: Double = 5 * 60,
                warmUpSeconds: Double = 5 * 60,
                minimumRunsForTypical: Int = 3,
                minimumHeartRateCoverage: Double = DecouplingOptions.default.minimumCoverage,
                decoupling: DecouplingOptions = .default,
                peakHoldSeconds: Double = 20,
                cadenceMinimumRuns: Int = 4,
                cadenceMinimumSpanDays: Double = 14,
                healthWindowDays: Int = 60,
                minimumHealthDays: Int = 14,
                minimumSevenDayReadings: Int = 3,
                normalRangeSD: Double = 1) {
        self.asOf = asOf
        self.timeZone = timeZone
        self.loadWindowWeeks = loadWindowWeeks
        self.currentLoadWeeks = currentLoadWeeks
        self.recentDays = recentDays
        self.lthrLookbackDays = lthrLookbackDays
        self.bestEffortLookbackDays = bestEffortLookbackDays
        self.bestEffortDistances = bestEffortDistances
        self.easyHeartRate = easyHeartRate
        self.easyHeartRateBandBPM = easyHeartRateBandBPM
        self.minimumSecondsInBand = minimumSecondsInBand
        self.warmUpSeconds = warmUpSeconds
        self.minimumRunsForTypical = minimumRunsForTypical
        self.minimumHeartRateCoverage = minimumHeartRateCoverage
        self.decoupling = decoupling
        self.peakHoldSeconds = peakHoldSeconds
        self.cadenceMinimumRuns = cadenceMinimumRuns
        self.cadenceMinimumSpanDays = cadenceMinimumSpanDays
        self.healthWindowDays = healthWindowDays
        self.minimumHealthDays = minimumHealthDays
        self.minimumSevenDayReadings = minimumSevenDayReadings
        self.normalRangeSD = normalRangeSD
    }

    /// Mile, 5K, 10K, 10 miles, half marathon and marathon.
    public static let standardDistances: [Double] = [
        Distance.mile, Distance.fiveK, Distance.tenK, Distance.tenMiles, Distance.halfMarathon, Distance.marathon,
    ]

    /// Longest weekly-load window accepted (10 years), so date arithmetic can't overflow.
    public static let maximumLoadWindowWeeks = 520
    /// Longest daily-health window accepted (10 years), for the same reason.
    public static let maximumHealthWindowDays = 3660
    /// Longest lookback, in days, for any other window (100 years).
    public static let maximumLookbackDays = 36_600

    /// True when `asOf` is finite and every option is finite and in range.
    /// The easy heart rate is checked separately (an invalid one only blanks easy pace).
    public var isValid: Bool {
        let counts = [loadWindowWeeks, currentLoadWeeks, recentDays, lthrLookbackDays, bestEffortLookbackDays,
                      minimumRunsForTypical, cadenceMinimumRuns, healthWindowDays, minimumHealthDays,
                      minimumSevenDayReadings]
        let reals = [easyHeartRateBandBPM, minimumSecondsInBand, warmUpSeconds,
                     peakHoldSeconds, cadenceMinimumSpanDays, normalRangeSD]
        return asOf.timeIntervalSinceReferenceDate.isFinite
            && counts.allSatisfy { $0 >= 1 }
            && loadWindowWeeks <= Self.maximumLoadWindowWeeks
            && healthWindowDays <= Self.maximumHealthWindowDays
            && [recentDays, lthrLookbackDays, bestEffortLookbackDays].allSatisfy { $0 <= Self.maximumLookbackDays }
            && minimumHeartRateCoverage.isFinite && (0...1).contains(minimumHeartRateCoverage)
            && reals.allSatisfy { $0.isFinite && $0 >= 0 }
            && peakHoldSeconds > 0 && decoupling.maximumHoldSeconds > 0
            && bestEffortDistances.allSatisfy { $0.isFinite && $0 > 0 }
            && decoupling.isValid
    }
}

/// Builds the F1 baseline report from a runner's history (SPEC.md section 2, F1).
///
/// The history is cleaned first (`HistoryCleanup`: duplicates dropped,
/// treadmill runs tagged, cadence gaps flagged); only `.run` activities that
/// started by `asOf` count. Each part of the report lists the runs (or days) it
/// came from, and a part without enough data is `.insufficient` with a reason.
///
/// Heuristics, stated so they can be tuned (see `BaselineOptions` for values):
/// - Moving time: `MovingTime.seconds(of:maximumHoldSeconds:)`. Time-weighted
///   means and heart-rate coverage use the same timeline as `Decoupling`: each
///   stream carries its own last usable reading forward for at most
///   `decoupling.maximumHoldSeconds` of moving time, and a pause clears every hold. So
///   streams recorded at different rates or in separate samples line up.
/// - Weekly load: ISO weeks (`PlanCalendar`) in the caller's time zone, from the week of the
///   first run (weeks before any data are unknown, not zero) or
///   `loadWindowWeeks` back, whichever is later. Current load is the mean of the
///   last `currentLoadWeeks` complete weeks, empty weeks counted as zero.
/// - Long run: the run with the most moving time in each week.
/// - Best efforts: the fastest stretch of each outdoor run's distance stream
///   covering each distance (start interpolated, elapsed time), at a plausible
///   speed (`BlendedPredictor.plausibleSpeed`); jumps and backwards steps in
///   the stream add no distance. Treadmill distance is a
///   footpod or belt estimate, so treadmill runs are left out.
/// - LTHR: `LTHREstimator` on runs marked as races or time trials. A race uses
///   the whole run's moving heart rate (or the source's summary average when
///   it has no heart-rate stream at all); a time trial uses its last 20 minutes
///   of moving time and needs a stream. A stream must cover at least
///   `minimumHeartRateCoverage` of the moving time that counts.
/// - Peak heart rate: the highest value held for `peakHoldSeconds`, i.e. the
///   largest minimum over any such stretch of closely spaced samples.
/// - Easy pace: outdoor runs in the recent window; moving time after the first
///   `warmUpSeconds` of moving time, with heart rate in the band and a
///   plausible speed; the median of the per-run mean speeds. A run without a
///   speed stream is left out (`.noSpeed`); speed is not derived from distance.
/// - Decoupling: runs in the recent window long enough for SPEC.md 3.3, not
///   marked as races or trials, that `Decoupling.compute` accepts and finds
///   steady; the median percent.
/// - Cadence: per-run time-weighted mean moving cadence over the weekly-load window (summary
///   average when there is no stream); slope by least squares over run dates.
/// - Resting HR and HRV: readings averaged per calendar day; the normal range
///   is mean ± `normalRangeSD` sample standard deviations over
///   `healthWindowDays`, and the 7-day average needs `minimumSevenDayReadings`.
public enum BaselineBuilder {
    // Plausible ranges, all heuristics: readings outside them are treated as
    // sensor or unit errors and ignored. Heart rate for efforts and peaks uses
    // `DecouplingOptions.plausibleHeartRate`.
    /// Cadence in steps per minute (both feet).
    static let plausibleCadence: ClosedRange<Double> = 60...260
    /// Daily resting heart rate in bpm.
    static let plausibleRestingHR: ClosedRange<Double> = 25...130
    /// Daily HRV (SDNN) in milliseconds.
    static let plausibleSDNN: ClosedRange<Double> = 1...300
    static let timeTrialHRSeconds: Double = 20 * 60
    /// Heuristic: GPS distance readings are a few metres off each way, so one
    /// reading may rise past the top plausible speed by up to this many metres
    /// and wait for the next reading instead of being dropped as a jump.
    /// Without it, noisy 1 Hz distance from a fast runner loses real steps.
    static let distanceNoiseMeters: Double = 5

    public static func build(activities: [Activity],
                             efforts: [EffortMark] = [],
                             dailyHealth: [DailyHealthSample] = [],
                             options: BaselineOptions) -> BaselineReport {
        let history = HistoryCleanup.clean(activities)
        guard options.isValid else {
            let bad = InsufficientData(.invalidInput)
            return BaselineReport(asOf: options.asOf, timeZone: options.timeZone, history: history, runs: [],
                                  weeklyLoad: .insufficient(bad), longRuns: .insufficient(bad),
                                  bestEfforts: .insufficient(bad), lthr: .insufficient(bad),
                                  peakHeartRate: .insufficient(bad), easyPace: .insufficient(bad),
                                  decoupling: .insufficient(bad), cadence: .insufficient(bad),
                                  restingHeartRate: .insufficient(bad), hrv: .insufficient(bad))
        }
        let ctx = Context(history: history, options: options, marks: efforts)
        let load = ctx.weeklyLoad()
        let lthr = ctx.lthr()
        return BaselineReport(
            asOf: options.asOf,
            timeZone: options.timeZone,
            history: history,
            runs: ctx.runEntries(),
            weeklyLoad: load,
            longRuns: ctx.longRuns(load),
            bestEfforts: ctx.bestEfforts(),
            lthr: lthr,
            peakHeartRate: ctx.peakHeartRate(),
            easyPace: ctx.easyPace(lthr: lthr.value),
            decoupling: ctx.decoupling(),
            cadence: ctx.cadence(load),
            restingHeartRate: ctx.daily(.restingHeartRate, dailyHealth),
            hrv: ctx.daily(.hrvSDNN, dailyHealth))
    }

    /// Marks resolved against the kept runs: each run's kind (first mark wins),
    /// and the marks that couldn't be used, with the reason. A mark on a dropped
    /// duplicate resolves to the run kept in its place.
    static func resolveMarks(_ marks: [EffortMark],
                             runs: [Activity],
                             history: CleanedHistory) -> (kinds: [String: HREffort.Kind], excluded: [ExcludedRun]) {
        let runIDs = Set(runs.map(\.id))
        let keptIDs = Set(history.activities.map(\.id))
        var kinds: [String: HREffort.Kind] = [:]
        var excluded: [ExcludedRun] = []
        for mark in marks {
            let id = keptIDs.contains(mark.activityID)
                ? mark.activityID
                : history.dropped.first { $0.dropped.id == mark.activityID }?.keptID
            guard let id, let activity = history.activities.first(where: { $0.id == id }) else {
                excluded.append(.init(activityID: mark.activityID, reason: .notInHistory)); continue
            }
            guard activity.sport == .run else {
                excluded.append(.init(activityID: id, reason: .notARun)); continue
            }
            guard runIDs.contains(id) else {
                excluded.append(.init(activityID: id, reason: .afterAsOf)); continue
            }
            guard kinds[id] == nil else {
                excluded.append(.init(activityID: mark.activityID, reason: .duplicateMark(of: id))); continue
            }
            kinds[id] = mark.kind
        }
        return (kinds, excluded)
    }

    // MARK: - Calendar

    static func addDays(_ n: Int, to date: Date, _ cal: Calendar) -> Date {
        cal.date(byAdding: .day, value: n, to: date) ?? date.addingTimeInterval(Double(n) * 86_400)
    }

    // MARK: - Stream helpers

    /// Time-weighted mean of the held `kind` stream over the moving-clock range
    /// `lo..<hi`, counting only stretches where `include` accepts the held
    /// values, with the moving seconds it covers; nil when it covers none.
    static func heldMean(_ intervals: [MovingTime.HeldInterval],
                         of kind: StreamKind,
                         from lo: Double = 0,
                         to hi: Double = .infinity,
                         where include: ([StreamKind: Double]) -> Bool = { _ in true }) -> (mean: Double, seconds: Double)? {
        var w = 0.0, sum = 0.0
        for iv in intervals {
            guard let v = iv.values[kind] else { continue }
            let overlap = min(iv.end, hi) - max(iv.start, lo)
            guard overlap > 0, include(iv.values) else { continue }
            w += overlap; sum += v * overlap
        }
        guard w > 0 else { return nil }
        let mean = sum / w
        return mean.isFinite ? (mean, w) : nil
    }

    static func median(_ xs: [Double]) -> Double? {
        let s = xs.filter(\.isFinite).sorted()
        guard !s.isEmpty else { return nil }
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    /// The fastest stretch covering `meters` in a distance stream, as
    /// (seconds, start offset), or nil. Elapsed time; the start is interpolated
    /// between samples; stretches at an implausible speed are skipped.
    ///
    /// The stream is rebuilt so a detectable glitch can only make an effort
    /// slower, never faster, than the distance truly run:
    /// - Readings that share a timestamp but disagree are all dropped.
    /// - Distance is counted from a high-water mark: a reading adds `raw - mark`
    ///   only when it is above the mark, so a dip that recovers is not counted
    ///   twice. Readings below the mark are dropped, so regained distance is
    ///   spread over the time since the mark rather than the last sample interval.
    /// - A rise above the top plausible speed (`BlendedPredictor.plausibleSpeed`)
    ///   times the time since the mark is not counted as it stands:
    ///   - if it is the first such reading and over by at most
    ///     `distanceNoiseMeters`, it may be noise, so it is held back and the
    ///     next reading decides: when the rise from the mark over both
    ///     intervals is plausible (at most the top speed times both intervals,
    ///     15 m over two 1 s intervals), it all counts;
    ///   - otherwise it is a GPS jump or a sustained over-read: it adds nothing,
    ///     the mark moves up to it, and until a plausible step arrives every
    ///     further over-limit step is treated the same way. So an over-read
    ///     faster than the plausible top speed never counts, however long it lasts.
    ///
    /// What noise costs a fast runner: with independent errors on each
    /// reading, a held-back reading loses nothing only while the rise from the
    /// mark across the two intervals stays within the top speed times both
    /// intervals. At true speed `v`, interval `dt` and errors `e0` (the mark)
    /// and `e2` (the reading after the held-back one), that is
    /// `2 * v * dt + (e2 - e0) <= 2 * top * dt`; with errors of up to 2 m at
    /// 1 Hz it always holds up to 5.5 m/s. Above that, the two steps are
    /// re-based without counting and their real distance is dropped. The
    /// stream is then suspect until a step within the top speed arrives: every
    /// over-limit step before that is dropped too, even one over by less than
    /// `distanceNoiseMeters` that would otherwise be held back. So a fast
    /// runner with noisy readings can lose several steps in a row, not just
    /// two. Dropped distance only ever makes an effort slower (or too short to
    /// count), never faster.
    ///
    /// A held-back reading that is the last one in the stream is never
    /// counted, since no later reading can show it was noise. That drops at
    /// most one reading's rise (at most the top speed times its interval plus
    /// `distanceNoiseMeters`) from the very end of the run: an effort that
    /// ends there can only get slower or miss its distance, never faster.
    /// Counting it would trust a reading already over the plausible speed.
    ///
    /// Known limitation: wrong readings that stay within the plausible speed
    /// can't be told apart from real running. A low reading still above the
    /// mark looks like the runner slowing and then speeding up, and a high one
    /// looks like a surge. Counted distance never rises faster than the
    /// plausible top speed between points, and noise that reverses shifts an
    /// effort by at most the errors of the readings at its two ends. A
    /// sustained over-read below the top speed (say a stretch reading 7 m/s on
    /// a 3 m/s run) counts in full and can make a short effort too fast. There
    /// is deliberately no check against the run's own pace: strides,
    /// intervals and races are real running well above a run's typical pace,
    /// and a cap tied to it would drop exactly the efforts this measures.
    static func fastestStretch(_ samples: [StreamSample], meters: Double) -> (seconds: Double, startT: Double)? {
        var byTime: [(t: Double, raws: [Double])] = []
        for s in MovingTime.ordered(samples) {
            guard let raw = StreamKind.distance.value(in: s) else { continue }
            if let last = byTime.last, last.t == s.t {
                byTime[byTime.count - 1].raws.append(raw)
            } else {
                byTime.append((s.t, [raw]))
            }
        }
        // Readings that share a timestamp but disagree can't be told apart, so none is used.
        let readings = byTime.compactMap { e in
            e.raws.allSatisfy { $0 == e.raws[0] } ? (t: e.t, raw: e.raws[0]) : nil
        }
        var pts: [(t: Double, d: Double)] = []
        var mark: (t: Double, raw: Double)?
        var pending = false   // the last reading rose just past the limit: wait for the next
        var suspect = false   // the last step was a jump: no pending until a plausible step
        var total = 0.0
        let top = BlendedPredictor.plausibleSpeed.upperBound
        for r in readings {
            guard let m = mark else {
                mark = r
                pts.append((r.t, total))
                continue
            }
            // A reading below the mark is a dip: it is dropped as a point, so the
            // distance regained later spreads over the time since the mark.
            guard r.raw >= m.raw else { continue }
            let rise = r.raw - m.raw, limit = top * (r.t - m.t)
            if rise <= limit {
                total += rise
                pending = false
                suspect = false
            } else if !pending && !suspect && rise <= limit + distanceNoiseMeters {
                // Maybe noise that the next reading reverses: keep the mark, add no point.
                pending = true
                continue
            } else {
                // A GPS jump, or an over-read that didn't reverse: re-base without counting.
                pending = false
                suspect = true
            }
            mark = r
            pts.append((r.t, total))
        }
        guard let first = pts.first, let last = pts.last, last.d - first.d >= meters else { return nil }
        var best: (Double, Double)?
        var i = 0
        for j in pts.indices {
            let target = pts[j].d - meters
            guard target >= first.d else { continue }
            while i + 1 < j && pts[i + 1].d <= target { i += 1 }
            // Start lies between pts[i] and pts[i + 1].
            let a = pts[i], b = pts[min(i + 1, j)]
            let startT = b.d > a.d ? a.t + (target - a.d) / (b.d - a.d) * (b.t - a.t) : a.t
            let seconds = pts[j].t - startT
            guard seconds > 0, BlendedPredictor.plausibleSpeed.contains(meters / seconds) else { continue }
            if best == nil || seconds < best!.0 { best = (seconds, startT) }
        }
        return best
    }

    /// The highest heart rate held for `hold` seconds (the largest minimum over
    /// any such stretch whose samples are at most `hold / 2` apart).
    static func heldPeak(_ samples: [StreamSample], hold: Double, plausible: ClosedRange<Double>) -> Double? {
        let pts = MovingTime.ordered(samples)
        let maxGap = hold / 2
        func hr(_ k: Int) -> Double? {
            guard let v = StreamKind.heartRate.value(in: pts[k]), plausible.contains(v) else { return nil }
            return v
        }
        var best: Double?
        for i in pts.indices {
            guard var low = hr(i) else { continue }
            var j = i + 1
            var covered = false
            while j < pts.count, pts[j].t - pts[j - 1].t <= maxGap {
                if pts[j].t >= pts[i].t + hold { covered = true; break }
                guard let v = hr(j) else { break }
                low = min(low, v)
                j += 1
            }
            if covered, best.map({ low > $0 }) ?? true { best = low }
        }
        return best
    }
}

// MARK: - Sections

extension BaselineBuilder {
    struct Context {
        let history: CleanedHistory
        let options: BaselineOptions
        let cal: Calendar
        /// Kept `.run` activities that started by `asOf`, by start time.
        let runs: [Activity]
        let moving: [String: Double]
        /// Runs with no usable time (counted as 0 in `moving`).
        let movingUnknown: Set<String>
        /// Resolved mark kind per run id, and marks that couldn't be used.
        let markKinds: [String: HREffort.Kind]
        let markExclusions: [ExcludedRun]

        init(history: CleanedHistory, options: BaselineOptions, marks: [EffortMark]) {
            self.history = history
            self.options = options
            self.cal = PlanCalendar.calendar(timeZone: options.timeZone)
            let runs = history.activities
                .filter { $0.sport == .run && $0.start.timeIntervalSinceReferenceDate.isFinite && $0.start <= options.asOf }
                .sorted { $0.start < $1.start }
            self.runs = runs
            var m: [String: Double] = [:]
            var unknown: Set<String> = []
            for r in runs {
                let known = MovingTime.knownSeconds(of: r, maximumHoldSeconds: options.decoupling.maximumHoldSeconds)
                m[r.id] = known ?? 0
                if known == nil { unknown.insert(r.id) }
            }
            self.moving = m
            self.movingUnknown = unknown
            let resolved = BaselineBuilder.resolveMarks(marks, runs: runs, history: history)
            self.markKinds = resolved.kinds
            self.markExclusions = resolved.excluded
        }

        func weekStart(_ date: Date) -> Date { PlanCalendar.weekStart(containing: date, timeZone: options.timeZone) }

        func runEntries() -> [BaselineRun] {
            runs.map { r in
                BaselineRun(activityID: r.id, start: r.start, movingSeconds: moving[r.id] ?? 0,
                            movingTimeIsKnown: !movingUnknown.contains(r.id),
                            distanceMeters: r.distanceMeters.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                            isTreadmill: isTreadmill(r), markedEffort: markKinds[r.id])
            }
        }

        func isTreadmill(_ a: Activity) -> Bool { history.treadmill[a.id]?.isTreadmill ?? false }

        /// Runs that started within the last `days` days up to `asOf`.
        func runs(withinDays days: Int) -> [Activity] {
            let earliest = options.asOf.addingTimeInterval(-Double(days) * 86_400)
            return runs.filter { $0.start >= earliest }
        }

        // MARK: Weekly load

        func weeklyLoad() -> BaselineValue<WeeklyLoadBaseline> {
            guard let firstRun = runs.first else { return .insufficient(.init(.noRuns)) }
            let current = weekStart(options.asOf)
            let windowStart = PlanCalendar.weekStart(weeks: -(options.loadWindowWeeks - 1), after: current, timeZone: options.timeZone)
            var ws = max(windowStart, weekStart(firstRun.start))
            var weeks: [WeekLoad] = []
            while ws <= current {
                let we = PlanCalendar.nextWeekStart(after: ws, timeZone: options.timeZone)
                let inWeek = runs.filter { $0.start >= ws && $0.start < we }
                let withDistance = inWeek.compactMap { r in r.distanceMeters.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
                weeks.append(WeekLoad(
                    weekStart: ws, weekEnd: we, isComplete: ws < current,
                    activityIDs: inWeek.map(\.id),
                    movingSeconds: inWeek.reduce(0) { $0 + (moving[$1.id] ?? 0) },
                    distanceMeters: withDistance.reduce(0, +),
                    runsWithoutDistance: inWeek.filter { r in !(r.distanceMeters.map { $0.isFinite && $0 >= 0 } ?? false) }.map(\.id)))
                ws = we
            }
            guard weeks.contains(where: { $0.runCount > 0 }) else { return .insufficient(.init(.noRuns)) }
            let basis = Array(weeks.filter(\.isComplete).suffix(options.currentLoadWeeks))
            guard !basis.isEmpty else { return .insufficient(.init(.noCompleteWeek)) }
            let n = Double(basis.count)
            return .available(WeeklyLoadBaseline(
                weeks: weeks,
                basisWeekStarts: basis.map(\.weekStart),
                currentWeeklyMovingSeconds: basis.reduce(0) { $0 + $1.movingSeconds } / n,
                currentWeeklyDistanceMeters: basis.reduce(0) { $0 + $1.distanceMeters } / n,
                distanceIsComplete: basis.allSatisfy { $0.runsWithoutDistance.isEmpty },
                evidenceActivityIDs: basis.flatMap(\.activityIDs)))
        }

        // MARK: Long runs

        func longRuns(_ load: BaselineValue<WeeklyLoadBaseline>) -> BaselineValue<LongRunHistory> {
            guard let load = load.value else {
                return .insufficient(load.insufficiency ?? .init(.noRuns))
            }
            let byID = Dictionary(runs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var weekly: [LongRun] = []
            for week in load.weeks {
                let candidates = week.activityIDs.compactMap { byID[$0] }
                // Most moving time; ties go to the earlier run.
                guard let top = candidates.max(by: { (moving[$0.id] ?? 0) < (moving[$1.id] ?? 0) }) else { continue }
                let secs = moving[top.id] ?? 0
                weekly.append(LongRun(weekStart: week.weekStart, activityID: top.id, start: top.start,
                                      movingSeconds: secs,
                                      distanceMeters: top.distanceMeters.flatMap { $0.isFinite ? $0 : nil },
                                      shareOfWeek: week.movingSeconds > 0 ? secs / week.movingSeconds : 0))
            }
            guard let longest = weekly.max(by: { $0.movingSeconds < $1.movingSeconds }) else {
                return .insufficient(.init(.noRuns))
            }
            let basis = Set(load.basisWeekStarts)
            let typical = BaselineBuilder.median(weekly.filter { basis.contains($0.weekStart) }.map(\.movingSeconds))
            return .available(LongRunHistory(weekly: weekly, longest: longest, typicalMovingSeconds: typical))
        }

        // MARK: Best efforts

        func bestEfforts() -> BaselineValue<BestEffortsBaseline> {
            guard !runs.isEmpty else { return .insufficient(.init(.noRuns)) }
            var excluded: [ExcludedRun] = []
            var all: [RunBestEffort] = []
            let distances = Array(Set(options.bestEffortDistances)).sorted()
            for run in runs {
                if isTreadmill(run) { excluded.append(.init(activityID: run.id, reason: .treadmill)); continue }
                for meters in distances {
                    guard let s = BaselineBuilder.fastestStretch(run.samples, meters: meters) else { continue }
                    all.append(RunBestEffort(distanceMeters: meters, seconds: s.seconds, activityID: run.id,
                                             date: run.start.addingTimeInterval(s.startT),
                                             startOffsetSeconds: s.startT))
                }
            }
            guard !all.isEmpty else { return .insufficient(.init(.noDistanceStreams, excluded: excluded)) }
            func fastest(_ efforts: [RunBestEffort]) -> [RunBestEffort] {
                distances.compactMap { meters in
                    efforts.filter { $0.distanceMeters == meters }
                        .min { $0.seconds != $1.seconds ? $0.seconds < $1.seconds : $0.date < $1.date }
                }
            }
            let earliest = options.asOf.addingTimeInterval(-Double(options.bestEffortLookbackDays) * 86_400)
            return .available(BestEffortsBaseline(personalRecords: fastest(all),
                                                  recent: fastest(all.filter { $0.date >= earliest })))
        }

        // MARK: LTHR and zones

        func lthr() -> BaselineValue<LTHRBaseline> {
            guard !markKinds.isEmpty || !markExclusions.isEmpty else { return .insufficient(.init(.noMarkedEfforts)) }
            var excluded = markExclusions
            var efforts: [HREffort] = []
            let earliest = options.asOf.addingTimeInterval(-Double(options.lthrLookbackDays) * 86_400)
            let plausible = options.decoupling.plausibleHeartRate
            for activity in runs {
                guard let kind = markKinds[activity.id] else { continue }
                let id = activity.id
                let timeline = MovingTime.held(activity.samples, streams: [.heartRate: { plausible.contains($0) }],
                                               maximumHoldSeconds: options.decoupling.maximumHoldSeconds)
                let total = timeline.last?.end ?? 0
                // The moving time that counts: the whole race, or the trial's last 20 minutes of it.
                let from = kind == .race ? 0 : max(0, total - BaselineBuilder.timeTrialHRSeconds)
                let counted = total - from
                let fromStream = BaselineBuilder.heldMean(timeline, of: .heartRate, from: from)
                let hasStream = activity.samples.contains { s in
                    StreamKind.heartRate.value(in: s).map { plausible.contains($0) } ?? false
                }
                let hr: Double
                if let fromStream {
                    let coverage = counted > 0 ? fromStream.seconds / counted : 0
                    guard coverage >= options.minimumHeartRateCoverage else {
                        excluded.append(.init(activityID: id, reason: .insufficientHeartRateCoverage(coverage: coverage)))
                        continue
                    }
                    hr = fromStream.mean
                } else if kind == .race, !hasStream,
                          let summary = activity.averageHeartRate, summary.isFinite {
                    hr = summary
                } else {
                    excluded.append(.init(activityID: id, reason: .noHeartRate)); continue
                }
                let effort = HREffort(id: id, date: activity.start, kind: kind,
                                      durationSeconds: activity.durationSeconds, averageHR: hr)
                guard LTHREstimator.qualifies(effort) else {
                    excluded.append(.init(activityID: id, reason: .effortDidNotQualify(
                        durationSeconds: activity.durationSeconds, averageHR: hr)))
                    continue
                }
                guard activity.start >= earliest else {
                    excluded.append(.init(activityID: id, reason: .outsideLookback)); continue
                }
                efforts.append(effort)
            }
            guard let estimate = LTHREstimator.estimate(from: efforts, asOf: options.asOf,
                                                        lookbackDays: options.lthrLookbackDays),
                  let zones = HRZones(lthr: estimate.bpm) else {
                return .insufficient(.init(.noQualifyingEfforts, excluded: excluded))
            }
            return .available(LTHRBaseline(estimate: estimate, zones: zones, excluded: excluded))
        }

        // MARK: Peak heart rate

        func peakHeartRate() -> BaselineValue<PeakHeartRate> {
            let window = runs(withinDays: options.lthrLookbackDays)
            guard !window.isEmpty else { return .insufficient(.init(.noRuns)) }
            var best: PeakHeartRate?
            for run in window {
                guard let bpm = BaselineBuilder.heldPeak(run.samples, hold: options.peakHoldSeconds,
                                                         plausible: options.decoupling.plausibleHeartRate) else { continue }
                if best.map({ bpm > $0.bpm }) ?? true {
                    best = PeakHeartRate(bpm: bpm, activityID: run.id, date: run.start, holdSeconds: options.peakHoldSeconds)
                }
            }
            guard let peak = best else { return .insufficient(.init(.noHeartRateData)) }
            return .available(peak)
        }

        // MARK: Easy pace at a fixed heart rate

        func easyPace(lthr: LTHRBaseline?) -> BaselineValue<EasyPaceBaseline> {
            let target: Double
            switch options.easyHeartRate {
            case .bpm(let bpm):
                guard bpm.isFinite, options.decoupling.plausibleHeartRate.contains(bpm) else {
                    return .insufficient(.init(.invalidInput))
                }
                target = bpm
            case .zoneTwoMidpoint:
                guard let zones = lthr?.zones else { return .insufficient(.init(.needsLTHR)) }
                target = (zones.lowerBound(.z2) + zones.easyCeiling) / 2
            }
            let window = runs(withinDays: options.recentDays)
            guard !window.isEmpty else { return .insufficient(.init(.noRuns)) }
            let band = (target - options.easyHeartRateBandBPM)...(target + options.easyHeartRateBandBPM)
            var excluded: [ExcludedRun] = []
            var used: [EasyPaceRun] = []
            for run in window {
                if isTreadmill(run) { excluded.append(.init(activityID: run.id, reason: .treadmill)); continue }
                guard run.presentStreams.contains(.speed) else {
                    excluded.append(.init(activityID: run.id, reason: .noSpeed)); continue
                }
                let timeline = MovingTime.held(
                    run.samples,
                    streams: [.heartRate: { options.decoupling.plausibleHeartRate.contains($0) },
                              .speed: { BlendedPredictor.plausibleSpeed.contains($0) }],
                    maximumHoldSeconds: options.decoupling.maximumHoldSeconds)
                let stats = BaselineBuilder.heldMean(timeline, of: .speed, from: options.warmUpSeconds) { values in
                    values[.heartRate].map { band.contains($0) } ?? false
                }
                guard let stats, stats.seconds >= options.minimumSecondsInBand else {
                    excluded.append(.init(activityID: run.id,
                                          reason: .tooLittleTimeAtHeartRate(seconds: stats?.seconds ?? 0)))
                    continue
                }
                used.append(EasyPaceRun(activityID: run.id, start: run.start,
                                        secondsInBand: stats.seconds, metersPerSecond: stats.mean))
            }
            guard used.count >= options.minimumRunsForTypical,
                  let speed = BaselineBuilder.median(used.map(\.metersPerSecond)) else {
                return .insufficient(.init(.tooFewRuns(have: used.count, need: options.minimumRunsForTypical),
                                           excluded: excluded))
            }
            return .available(EasyPaceBaseline(heartRate: target, band: band, metersPerSecond: speed,
                                               runs: used, excluded: excluded))
        }

        // MARK: Typical decoupling

        func decoupling() -> BaselineValue<DecouplingBaseline> {
            // SPEC.md 3.3 applies only to runs over the minimum duration; shorter
            // runs aren't candidates, so they aren't listed as excluded either.
            let window = runs(withinDays: options.recentDays)
            guard !window.isEmpty else { return .insufficient(.init(.noRuns)) }
            let candidates = window.filter { (moving[$0.id] ?? 0) > options.decoupling.minimumMovingSeconds }
            var excluded: [ExcludedRun] = []
            var used: [DecouplingRun] = []
            for run in candidates {
                if markKinds[run.id] != nil { excluded.append(.init(activityID: run.id, reason: .markedEffort)); continue }
                switch Decoupling.compute(run.samples, basis: .pace, options: options.decoupling) {
                case .failure(let refusal):
                    excluded.append(.init(activityID: run.id, reason: .decouplingRefused(refusal)))
                case .success(let result):
                    switch result.isSteady {
                    case true?: used.append(DecouplingRun(activityID: run.id, start: run.start, result: result))
                    case false?: excluded.append(.init(activityID: run.id, reason: .notSteady))
                    case nil: excluded.append(.init(activityID: run.id, reason: .steadinessUnknown))
                    }
                }
            }
            guard used.count >= options.minimumRunsForTypical,
                  let typical = BaselineBuilder.median(used.map(\.result.percent)) else {
                return .insufficient(.init(.tooFewRuns(have: used.count, need: options.minimumRunsForTypical),
                                           excluded: excluded))
            }
            return .available(DecouplingBaseline(typicalPercent: typical,
                                                 classification: DecouplingClass(percent: typical),
                                                 runs: used, excluded: excluded))
        }

        // MARK: Cadence trend

        func cadence(_ load: BaselineValue<WeeklyLoadBaseline>) -> BaselineValue<CadenceTrend> {
            let current = weekStart(options.asOf)
            let windowStart = PlanCalendar.weekStart(weeks: -(options.loadWindowWeeks - 1), after: current, timeZone: options.timeZone)
            let window = runs.filter { $0.start >= windowStart }
            guard !window.isEmpty else { return .insufficient(.init(.noRuns)) }
            var withCadence: [CadenceRun] = []
            var without: [String] = []
            for run in window {
                let timeline = MovingTime.held(run.samples,
                                               streams: [.cadence: { BaselineBuilder.plausibleCadence.contains($0) }],
                                               maximumHoldSeconds: options.decoupling.maximumHoldSeconds)
                let fromStream = BaselineBuilder.heldMean(timeline, of: .cadence)?.mean
                let summary = run.averageCadence.flatMap {
                    $0.isFinite && BaselineBuilder.plausibleCadence.contains($0) ? $0 : nil
                }
                if let spm = fromStream ?? summary {
                    withCadence.append(CadenceRun(activityID: run.id, start: run.start, stepsPerMinute: spm))
                } else {
                    without.append(run.id)
                }
            }
            guard !withCadence.isEmpty else { return .insufficient(.init(.noCadence)) }

            var recentRuns = withCadence
            if let basis = load.value?.basisWeekStarts, let first = basis.first {
                let inBasis = withCadence.filter { $0.start >= first && $0.start < current }
                if !inBasis.isEmpty { recentRuns = inBasis }
            }
            let recent = recentRuns.reduce(0) { $0 + $1.stepsPerMinute } / Double(recentRuns.count)

            let week = 7 * 86_400.0
            let span = (withCadence.last!.start.timeIntervalSince(withCadence.first!.start)) / 86_400
            let slope: BaselineValue<Double>
            if withCadence.count < options.cadenceMinimumRuns {
                slope = .insufficient(.init(.tooFewRuns(have: withCadence.count, need: options.cadenceMinimumRuns)))
            } else if span < options.cadenceMinimumSpanDays {
                slope = .insufficient(.init(.spanTooShort(days: span, need: options.cadenceMinimumSpanDays)))
            } else {
                let x = withCadence.map { $0.start.timeIntervalSince(withCadence[0].start) / week }
                let y = withCadence.map(\.stepsPerMinute)
                let mx = x.reduce(0, +) / Double(x.count), my = y.reduce(0, +) / Double(y.count)
                let sxy = zip(x, y).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
                let sxx = x.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
                slope = sxx > 0 ? .available(sxy / sxx)
                    : .insufficient(.init(.spanTooShort(days: span, need: options.cadenceMinimumSpanDays)))
            }
            return .available(CadenceTrend(runs: withCadence, recentStepsPerMinute: recent, slopePerWeek: slope,
                                           runsWithoutCadence: without, gaps: history.cadence.gaps))
        }

        // MARK: Resting HR and HRV

        func daily(_ kind: DailyHealthSample.Kind, _ samples: [DailyHealthSample]) -> BaselineValue<DailyMetricBaseline> {
            let plausible = kind == .restingHeartRate ? BaselineBuilder.plausibleRestingHR : BaselineBuilder.plausibleSDNN
            let ofKind = samples.filter {
                $0.kind == kind && $0.value.isFinite && plausible.contains($0.value)
                    && $0.date.timeIntervalSinceReferenceDate.isFinite && $0.date <= options.asOf
            }
            guard !ofKind.isEmpty else { return .insufficient(.init(.noReadings)) }
            let today = cal.startOfDay(for: options.asOf)
            let first = BaselineBuilder.addDays(-(options.healthWindowDays - 1), to: today, cal)
            var byDay: [Date: [Double]] = [:]
            for s in ofKind {
                let day = cal.startOfDay(for: s.date)
                if day >= first { byDay[day, default: []].append(s.value) }
            }
            let days = byDay.keys.sorted().map { d in
                DailyValue(day: d, value: byDay[d]!.reduce(0, +) / Double(byDay[d]!.count))
            }
            guard days.count >= max(2, options.minimumHealthDays) else {
                return .insufficient(.init(.tooFewDays(have: days.count, need: max(2, options.minimumHealthDays))))
            }
            let values = days.map(\.value)
            let mean = values.reduce(0, +) / Double(values.count)
            let sd = (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)).squareRoot()
            let k = options.normalRangeSD
            let weekStart = BaselineBuilder.addDays(-6, to: today, cal)
            let lastWeek = days.filter { $0.day >= weekStart }
            let seven: BaselineValue<Double> = lastWeek.count >= options.minimumSevenDayReadings
                ? .available(lastWeek.reduce(0) { $0 + $1.value } / Double(lastWeek.count))
                : .insufficient(.init(.tooFewDays(have: lastWeek.count, need: options.minimumSevenDayReadings)))
            return .available(DailyMetricBaseline(kind: kind, mean: mean, standardDeviation: sd,
                                                  normalRange: (mean - k * sd)...(mean + k * sd),
                                                  sevenDayAverage: seven, days: days))
        }
    }
}
