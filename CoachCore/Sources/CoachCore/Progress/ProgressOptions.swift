// TimeZone is Sendable on Apple SDKs but not yet in swift-corelibs-foundation
// (Linux, Swift 5.10); @preconcurrency keeps ProgressOptions' Sendable conformance warning-free there.
@preconcurrency import Foundation

/// Noise thresholds per metric (SPEC.md F13). All are heuristics: a change
/// at or below the threshold reads as "no change", so day-to-day scatter in
/// GPS pace, wrist heart rate and watch HRV isn't shown as progress.
public struct ProgressNoise: Equatable, Sendable {
    /// Heuristic: 2% of the earlier pace (about 6 s/km at 5:00/km).
    public var easyPace: NoiseThreshold
    /// Heuristic: 1 percentage point of decoupling.
    public var longRunDecoupling: NoiseThreshold
    /// Heuristic: 1% of the earlier predicted time.
    public var predictedTime: NoiseThreshold
    /// Heuristic: 1% of the earlier time.
    public var bestEffort: NoiseThreshold
    /// Heuristic: 1 bpm on the 7-day average.
    public var restingHeartRate: NoiseThreshold
    /// Heuristic: 10% of the earlier 7-day average, because Apple Watch SDNN
    /// is a noisy measure (SPEC.md 3.4).
    public var hrv: NoiseThreshold
    /// Heuristic: 10% of the earlier weekly time (the size of the 3.5 weekly step).
    public var weeklyLoad: NoiseThreshold
    /// Heuristic: 0.05 of the actual-to-planned ratio.
    public var loadVersusPlan: NoiseThreshold
    /// Heuristic: 2 percentage points (0.02) of easy share.
    public var easyShare: NoiseThreshold
    /// Heuristic: 1 step per minute.
    public var cadence: NoiseThreshold

    public init(easyPace: NoiseThreshold = .init(relative: 0.02),
                longRunDecoupling: NoiseThreshold = .init(absolute: 1),
                predictedTime: NoiseThreshold = .init(relative: 0.01),
                bestEffort: NoiseThreshold = .init(relative: 0.01),
                restingHeartRate: NoiseThreshold = .init(absolute: 1),
                hrv: NoiseThreshold = .init(relative: 0.10),
                weeklyLoad: NoiseThreshold = .init(relative: 0.10),
                loadVersusPlan: NoiseThreshold = .init(absolute: 0.05),
                easyShare: NoiseThreshold = .init(absolute: 0.02),
                cadence: NoiseThreshold = .init(absolute: 1)) {
        self.easyPace = easyPace
        self.longRunDecoupling = longRunDecoupling
        self.predictedTime = predictedTime
        self.bestEffort = bestEffort
        self.restingHeartRate = restingHeartRate
        self.hrv = hrv
        self.weeklyLoad = weeklyLoad
        self.loadVersusPlan = loadVersusPlan
        self.easyShare = easyShare
        self.cadence = cadence
    }

    public static let `default` = ProgressNoise()

    var all: [NoiseThreshold] {
        [easyPace, longRunDecoupling, predictedTime, bestEffort, restingHeartRate, hrv,
         weeklyLoad, loadVersusPlan, easyShare, cadence]
    }
}

/// Options for `ProgressBuilder` (SPEC.md F13). `baseline.asOf` and
/// `baseline.timeZone` come from the caller; the rest are heuristics, labeled
/// as such, and none stands for a particular runner.
public struct ProgressOptions: Equatable, Sendable {
    /// The options each weekly snapshot is built with. Its `asOf` is the end of
    /// the dashboard (the current value); each snapshot moves it back a week at a time.
    /// Its `recentDays` is the trailing window for easy pace, decoupling, best
    /// efforts and easy share at each snapshot (the initializers set it to
    /// `trailingWindowDays`, 28 by default). Its `bestEffortLookbackDays` is
    /// the predictor's window for predicted race times.
    public var baseline: BaselineOptions
    /// Weeks of trend line before the current point. Heuristic: 12, so the
    /// 12-week change is on the line.
    public var seriesWeeks: Int
    /// The change spans reported for each metric (SPEC.md F13: 4 and 12 weeks).
    public var changeWeeks: [Int]
    /// Distances for predicted race times, in meters. A marathon uses the
    /// Vickers-Vertosick correction and needs complete weekly distance (SPEC.md 3.9).
    public var predictionTargets: [Double]
    /// Distances for best efforts, in meters (SPEC.md F13: mile, 5K, 10K, 10 mile, half).
    public var bestEffortDistances: [Double]
    /// Easy-share range treated as on target (SPEC.md 3.1: 75 to 85% of running time).
    public var easyShareTarget: ClosedRange<Double>
    /// Actual-to-planned ratio treated as on plan. Heuristic: 0.9 to 1.1.
    public var loadVersusPlanTarget: ClosedRange<Double>
    /// Which way counts as better for cadence. SPEC.md F13 lists the cadence
    /// trend but doesn't say a higher cadence is an improvement, so it is
    /// informational by default.
    public var cadencePolarity: ProgressPolarity
    public var noise: ProgressNoise

    /// - Warning: this overwrites `baseline.recentDays` with `trailingWindowDays`,
    ///   whatever the passed baseline options say. To keep the baseline's own
    ///   window, pass it: `trailingWindowDays: baseline.recentDays`.
    /// - Parameter trailingWindowDays: replaces `baseline.recentDays`. Heuristic:
    ///   28 days is the 4-week change span, so a 4-week change compares two
    ///   windows that share no run. A longer window (the baseline's own 42, say)
    ///   makes 4-week windows overlap and smooths the change.
    public init(baseline: BaselineOptions,
                trailingWindowDays: Int = 28,
                seriesWeeks: Int = 12,
                changeWeeks: [Int] = [4, 12],
                predictionTargets: [Double] = [Distance.fiveK, Distance.tenK, Distance.halfMarathon, Distance.marathon],
                bestEffortDistances: [Double] = [Distance.mile, Distance.fiveK, Distance.tenK,
                                                 Distance.tenMiles, Distance.halfMarathon],
                easyShareTarget: ClosedRange<Double> = 0.75...0.85,
                loadVersusPlanTarget: ClosedRange<Double> = 0.9...1.1,
                cadencePolarity: ProgressPolarity = .informational,
                noise: ProgressNoise = .default) {
        self.baseline = baseline
        self.baseline.recentDays = trailingWindowDays
        self.seriesWeeks = seriesWeeks
        self.changeWeeks = changeWeeks
        self.predictionTargets = predictionTargets
        self.bestEffortDistances = bestEffortDistances
        self.easyShareTarget = easyShareTarget
        self.loadVersusPlanTarget = loadVersusPlanTarget
        self.cadencePolarity = cadencePolarity
        self.noise = noise
    }

    /// Progress options with the baseline's defaults and a 28-day trailing window.
    public init(asOf: Date, timeZone: TimeZone) {
        self.init(baseline: BaselineOptions(asOf: asOf, timeZone: timeZone))
    }

    /// Longest series accepted (10 years of weeks), matching the baseline's load window limit.
    public static let maximumSeriesWeeks = BaselineOptions.maximumLoadWindowWeeks

    /// Snapshots before the current one: enough for the series and every change span.
    var snapshotWeeks: Int { ([seriesWeeks] + changeWeeks).max() ?? seriesWeeks }

    /// True when the baseline options are valid and every progress option is in range.
    public var isValid: Bool {
        func validRange(_ r: ClosedRange<Double>) -> Bool { r.lowerBound.isFinite && r.upperBound.isFinite }
        let polarityValid: Bool
        switch cadencePolarity {
        case .towardRange(let r): polarityValid = validRange(r)
        case .lowerIsBetterWithFloor(let f): polarityValid = f.isFinite
        case .lowerIsBetter, .higherIsBetter, .informational: polarityValid = true
        }
        return baseline.isValid
            && seriesWeeks >= 1 && snapshotWeeks <= Self.maximumSeriesWeeks
            && changeWeeks.allSatisfy { $0 >= 1 }
            && predictionTargets.allSatisfy { $0.isFinite && $0 > 0 }
            && bestEffortDistances.allSatisfy { $0.isFinite && $0 > 0 }
            && validRange(easyShareTarget) && validRange(loadVersusPlanTarget) && polarityValid
            && noise.all.allSatisfy(\.isValid)
    }
}
