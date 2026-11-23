import Foundation

/// A best effort or race from the runner's own history (SPEC.md 3.9, F13).
///
/// The app fills these from HealthKit workouts (and Strava best efforts if
/// the runner connects Strava). Nothing here is a default for any runner.
public struct BestEffort: Equatable, Sendable {
    public let distanceMeters: Double
    public let seconds: Double
    public let date: Date

    public init(distanceMeters: Double, seconds: Double, date: Date) {
        self.distanceMeters = distanceMeters
        self.seconds = seconds
        self.date = date
    }

    /// Average speed in meters per second.
    public var speed: Double { distanceMeters / seconds }
}

/// The models that can feed a blended prediction (SPEC.md 3.9).
public enum PredictionMethod: String, CaseIterable, Sendable {
    /// Riegel, k = 1.07, from best efforts of the half marathon or shorter.
    case riegel
    /// Two-parameter critical-speed model fitted to best efforts.
    case criticalSpeed
    /// Pace at LTHR treated as 1-hour race pace, then Riegel.
    case threshold
    /// Vickers and Vertosick (2016) Model 1: the marathon from a shorter race and weekly mileage.
    case vickersVertosick
}

/// The numbers a method used besides its efforts, so each estimate shows its
/// inputs (SPEC.md 3.9, F13). A field is nil when the method doesn't use it.
public struct MethodInputs: Equatable, Sendable {
    /// The runner's pace at LTHR in seconds per meter (threshold method).
    public let secondsPerMeterAtLTHR: Double?
    /// Typical weekly running volume in meters (Vickers-Vertosick).
    public let weeklyMeters: Double?
    /// Fitted critical speed in meters per second (critical-speed method).
    public let criticalSpeedMetersPerSecond: Double?
    /// Fitted D′ in meters (critical-speed method).
    public let dPrimeMeters: Double?
    /// The Riegel exponent applied (Riegel, threshold and Vickers-Vertosick).
    public let riegelExponent: Double?

    public init(secondsPerMeterAtLTHR: Double? = nil, weeklyMeters: Double? = nil,
                criticalSpeedMetersPerSecond: Double? = nil, dPrimeMeters: Double? = nil,
                riegelExponent: Double? = nil) {
        self.secondsPerMeterAtLTHR = secondsPerMeterAtLTHR
        self.weeklyMeters = weeklyMeters
        self.criticalSpeedMetersPerSecond = criticalSpeedMetersPerSecond
        self.dPrimeMeters = dPrimeMeters
        self.riegelExponent = riegelExponent
    }
}

/// One method's estimate, with the efforts and inputs it used so the app can show its evidence.
public struct MethodEstimate: Equatable, Sendable {
    public let method: PredictionMethod
    public let seconds: Double
    /// Efforts the estimate came from (empty for the threshold method, which uses pace at LTHR).
    public let evidence: [BestEffort]
    /// The other numbers the method used (pace at LTHR, weekly meters, fitted CS and D′, exponent).
    public let inputs: MethodInputs
}

/// Why a method did not contribute.
public enum SkipReason: Error, Equatable, Sendable {
    /// No effort in the recency window fits the method.
    case noQualifyingEfforts
    /// Critical speed needs best efforts at two or more distances with enough spread in duration.
    case needsTwoDistances
    /// The critical-speed fit gave a non-positive CS or a negative D′.
    case implausibleFit
    /// The method isn't valid for this target distance.
    case targetOutOfRange
    /// The method needs a caller input that is missing or not finite and positive
    /// (pace at LTHR for `.threshold`, weekly volume for `.vickersVertosick`).
    case missingInput
    /// SPEC.md 3.9: only the Vickers-Vertosick correction may predict a marathon.
    case notUsedForMarathon
}

public struct SkippedMethod: Equatable, Sendable {
    public let method: PredictionMethod
    public let reason: SkipReason
}

/// A predicted range in seconds: `low` is the fastest plausible time, `high` the slowest.
public struct PredictionRange: Equatable, Sendable {
    public let low: Double
    public let central: Double
    public let high: Double
}

/// The blended prediction: a range (nil when no method had enough data),
/// which methods contributed, and why the others were skipped.
public struct BlendedPrediction: Equatable, Sendable {
    public let targetMeters: Double
    public let range: PredictionRange?
    public let estimates: [MethodEstimate]
    public let skipped: [SkippedMethod]
}

/// A linear critical-speed fit: distance = CS x time + D′ (SPEC.md 3.9).
public struct CriticalSpeedFit: Equatable, Sendable {
    /// Critical speed in meters per second.
    public let metersPerSecond: Double
    /// D′ (distance that can be covered above CS) in meters.
    public let dPrimeMeters: Double
    public let evidence: [BestEffort]

    /// Predicted seconds for `meters`: (d - D′) / CS; nil when d isn't beyond D′.
    public func predictedSeconds(meters: Double) -> Double? {
        guard meters.isFinite, meters > dPrimeMeters else { return nil }
        let t = (meters - dPrimeMeters) / metersPerSecond
        return t.isFinite && t > 0 ? t : nil
    }
}

/// Blended race-time prediction (SPEC.md 3.9, F13): Riegel, critical speed and
/// threshold, and the Vickers-Vertosick correction for the marathon. It shows a
/// range, never a single number, and never returns plain Riegel for a marathon.
///
/// Heuristics, stated so they can be tuned (all are constants below):
/// - Efforts count only inside the recency window, with a finite positive
///   distance and time and a plausible running speed. At each distance (within
///   1%) only the fastest effort counts, since a best effort is a maximal one.
/// - Riegel uses efforts from 3 km to the half marathon and predicts targets
///   up to the half marathon, where Vickers and Vertosick found it well
///   calibrated. It uses the effort closest in distance to the target, because
///   Riegel's error grows with the distance ratio.
/// - Critical speed is fitted by least squares over efforts lasting 2 to 30
///   minutes (the range where the two-parameter model holds), needs at least two
///   distances whose durations differ by 1.5x or more, and predicts only targets
///   it would run in 60 minutes or less: beyond about an hour the model's
///   asymptote at CS flatters the runner.
/// - Threshold treats the runner's pace at LTHR as 1-hour race pace, then
///   applies Riegel from that 1-hour equivalent. Targets up to the half marathon.
///   Mapping LTHR to an all-out 1-hour pace is a heuristic: SPEC.md 3.2 defines
///   LTHR but does not say it is the 1-hour race pace.
/// - Targets shorter than `minimumTargetMeters` (1 mile, a heuristic) are not predicted.
/// - The range runs from the fastest to the slowest method estimate around their
///   median, and is at least `minimumSpreadFraction` either side of it.
public enum BlendedPredictor {
    public static let riegelExponent = RacePredictor.defaultExponent
    public static let defaultLookbackDays = 120
    public static let plausibleSpeed: ClosedRange<Double> = 1.0...7.5
    public static let riegelEffortMeters: ClosedRange<Double> = 3000...(Distance.halfMarathon * 1.01)
    public static let criticalSpeedEffortSeconds: ClosedRange<Double> = 120...1800
    public static let criticalSpeedMinimumDurationRatio = 1.5
    public static let criticalSpeedMaximumPredictionSeconds: Double = 3600
    /// Plausible pace at LTHR, in seconds per meter (7.5 m/s to 1 m/s).
    public static let plausibleSecondsPerMeter: ClosedRange<Double> = (1 / 7.5)...1.0
    public static let minimumSpreadFraction = 0.02
    /// A target within 0.5% of 42.195 km counts as a marathon.
    public static let marathonTolerance = 0.005
    /// Shortest target predicted: 1 mile. A heuristic, not from the spec: Riegel and
    /// critical speed from 3 km+ efforts are extrapolated too far for 400 m or 800 m,
    /// where anaerobic capacity, not endurance, sets the time.
    public static let minimumTargetMeters = Distance.mile
    /// Targets up to the half marathon (plus 1% for course measurement) are "short".
    public static let shortTargetLimit = Distance.halfMarathon * 1.01

    /// Predicts `targetMeters` from the runner's own efforts.
    /// - Parameters:
    ///   - efforts: best efforts and races from the runner's history.
    ///   - asOf: efforts dated after this, or before the recency window, are ignored.
    ///   - secondsPerMeterAtLTHR: the runner's pace at LTHR from their own runs, if known.
    ///   - typicalWeeklyMeters: the runner's typical weekly running volume, needed for the marathon.
    public static func predict(
        targetMeters: Double,
        efforts: [BestEffort],
        asOf: Date,
        lookbackDays: Int = defaultLookbackDays,
        secondsPerMeterAtLTHR: Double? = nil,
        typicalWeeklyMeters: Double? = nil
    ) -> BlendedPrediction {
        let recent = bestPerDistance(eligible(efforts, asOf: asOf, lookbackDays: lookbackDays))
        var estimates: [MethodEstimate] = []
        var skipped: [SkippedMethod] = []
        func record(_ method: PredictionMethod, _ result: Result<MethodEstimate, SkipReason>) {
            switch result {
            case .success(let estimate): estimates.append(estimate)
            case .failure(let reason): skipped.append(SkippedMethod(method: method, reason: reason))
            }
        }

        let validTarget = targetMeters.isFinite && targetMeters > 0
        let isMarathon = validTarget
            && abs(targetMeters - Distance.marathon) / Distance.marathon <= marathonTolerance
        let isShort = validTarget && targetMeters >= minimumTargetMeters && targetMeters <= shortTargetLimit

        if isMarathon {
            for method in [PredictionMethod.riegel, .criticalSpeed, .threshold] {
                record(method, .failure(.notUsedForMarathon))
            }
            record(.vickersVertosick, vickersVertosick(efforts: recent, typicalWeeklyMeters: typicalWeeklyMeters))
            let band = VickersVertosick.validationRMSESeconds
            let range = estimates.first.map {
                PredictionRange(low: $0.seconds - band, central: $0.seconds, high: $0.seconds + band)
            }
            return BlendedPrediction(targetMeters: targetMeters, range: range, estimates: estimates, skipped: skipped)
        }

        if isShort {
            record(.riegel, riegel(target: targetMeters, efforts: recent))
            record(.criticalSpeed, criticalSpeed(target: targetMeters, efforts: recent))
            record(.threshold, threshold(target: targetMeters, secondsPerMeter: secondsPerMeterAtLTHR))
        } else {
            for method in [PredictionMethod.riegel, .criticalSpeed, .threshold] {
                record(method, .failure(.targetOutOfRange))
            }
        }
        record(.vickersVertosick, .failure(.targetOutOfRange))

        return BlendedPrediction(
            targetMeters: targetMeters,
            range: blend(estimates.map(\.seconds)),
            estimates: estimates,
            skipped: skipped
        )
    }

    /// Fits distance = CS x time + D′ to efforts lasting 2 to 30 minutes (one per distance).
    /// Returns the reason when no plausible fit exists.
    public static func fitCriticalSpeed(_ efforts: [BestEffort]) -> Result<CriticalSpeedFit, SkipReason> {
        let usable = bestPerDistance(efforts.filter(isPlausible))
            .filter { criticalSpeedEffortSeconds.contains($0.seconds) }
        guard usable.count >= 2,
              let shortest = usable.map(\.seconds).min(),
              let longest = usable.map(\.seconds).max(),
              longest / shortest >= criticalSpeedMinimumDurationRatio else {
            return .failure(usable.isEmpty ? .noQualifyingEfforts : .needsTwoDistances)
        }
        let n = Double(usable.count)
        let meanT = usable.map(\.seconds).reduce(0, +) / n
        let meanD = usable.map(\.distanceMeters).reduce(0, +) / n
        let sxy = usable.reduce(0) { $0 + ($1.seconds - meanT) * ($1.distanceMeters - meanD) }
        let sxx = usable.reduce(0) { $0 + ($1.seconds - meanT) * ($1.seconds - meanT) }
        let cs = sxy / sxx
        let dPrime = meanD - cs * meanT
        guard cs.isFinite, dPrime.isFinite, cs > 0, dPrime >= 0 else { return .failure(.implausibleFit) }
        return .success(CriticalSpeedFit(metersPerSecond: cs, dPrimeMeters: dPrime, evidence: usable))
    }

    // MARK: - Methods

    static func riegel(target: Double, efforts: [BestEffort]) -> Result<MethodEstimate, SkipReason> {
        let usable = efforts.filter { riegelEffortMeters.contains($0.distanceMeters) }
        let closest = usable.min { lhs, rhs in
            let l = abs(log(lhs.distanceMeters / target)), r = abs(log(rhs.distanceMeters / target))
            return l != r ? l < r : lhs.speed > rhs.speed
        }
        guard let effort = closest,
              let t = RacePredictor.riegel(knownMeters: effort.distanceMeters, knownSeconds: effort.seconds,
                                           targetMeters: target, exponent: riegelExponent) else {
            return .failure(.noQualifyingEfforts)
        }
        return .success(MethodEstimate(method: .riegel, seconds: t, evidence: [effort],
                                     inputs: MethodInputs(riegelExponent: riegelExponent)))
    }

    static func criticalSpeed(target: Double, efforts: [BestEffort]) -> Result<MethodEstimate, SkipReason> {
        switch fitCriticalSpeed(efforts) {
        case .failure(let reason):
            return .failure(reason)
        case .success(let fit):
            guard let t = fit.predictedSeconds(meters: target), t <= criticalSpeedMaximumPredictionSeconds else {
                return .failure(.targetOutOfRange)
            }
            return .success(MethodEstimate(method: .criticalSpeed, seconds: t, evidence: fit.evidence,
                                             inputs: MethodInputs(criticalSpeedMetersPerSecond: fit.metersPerSecond,
                                                                  dPrimeMeters: fit.dPrimeMeters)))
        }
    }

    static func threshold(target: Double, secondsPerMeter: Double?) -> Result<MethodEstimate, SkipReason> {
        guard let spm = secondsPerMeter, spm.isFinite, plausibleSecondsPerMeter.contains(spm) else {
            return .failure(.missingInput)
        }
        let oneHourMeters = 3600 / spm
        guard let t = RacePredictor.riegel(knownMeters: oneHourMeters, knownSeconds: 3600,
                                           targetMeters: target, exponent: riegelExponent) else {
            return .failure(.missingInput)
        }
        return .success(MethodEstimate(method: .threshold, seconds: t, evidence: [],
                                     inputs: MethodInputs(secondsPerMeterAtLTHR: spm, riegelExponent: riegelExponent)))
    }

    static func vickersVertosick(efforts: [BestEffort], typicalWeeklyMeters: Double?) -> Result<MethodEstimate, SkipReason> {
        guard let weekly = typicalWeeklyMeters, weekly.isFinite, weekly > 0 else {
            return .failure(.missingInput)
        }
        // Model 1 uses the runner's longest non-marathon race, from 5K to the half marathon.
        let usable = efforts.filter { VickersVertosick.raceMeters.contains($0.distanceMeters) }
        let longest = usable.max { lhs, rhs in
            lhs.distanceMeters != rhs.distanceMeters ? lhs.distanceMeters < rhs.distanceMeters : lhs.speed < rhs.speed
        }
        guard let race = longest,
              let t = VickersVertosick.marathonSeconds(raceMeters: race.distanceMeters, raceSeconds: race.seconds,
                                                       weeklyMiles: weekly / Distance.mile) else {
            return .failure(.noQualifyingEfforts)
        }
        return .success(MethodEstimate(method: .vickersVertosick, seconds: t, evidence: [race],
                                     inputs: MethodInputs(weeklyMeters: weekly, riegelExponent: 1.07)))
    }

    // MARK: - Helpers

    static func isPlausible(_ effort: BestEffort) -> Bool {
        effort.distanceMeters.isFinite && effort.seconds.isFinite
            && effort.distanceMeters > 0 && effort.seconds > 0
            && plausibleSpeed.contains(effort.speed)
    }

    static func eligible(_ efforts: [BestEffort], asOf: Date, lookbackDays: Int) -> [BestEffort] {
        guard lookbackDays > 0 else { return [] }
        let earliest = asOf.addingTimeInterval(-Double(lookbackDays) * 86_400)
        return efforts.filter { $0.date >= earliest && $0.date <= asOf && isPlausible($0) }
    }

    /// Keeps the fastest effort at each distance (distances within 1% are the same distance).
    static func bestPerDistance(_ efforts: [BestEffort]) -> [BestEffort] {
        var kept: [BestEffort] = []
        for effort in efforts.sorted(by: { $0.speed > $1.speed }) {
            let duplicate = kept.contains { abs($0.distanceMeters - effort.distanceMeters) / effort.distanceMeters <= 0.01 }
            if !duplicate { kept.append(effort) }
        }
        return kept.sorted { $0.distanceMeters < $1.distanceMeters }
    }

    /// Median of the estimates, from the fastest to the slowest, widened to at least
    /// `minimumSpreadFraction` either side of the median.
    static func blend(_ seconds: [Double]) -> PredictionRange? {
        let sorted = seconds.filter { $0.isFinite && $0 > 0 }.sorted()
        guard let fastest = sorted.first, let slowest = sorted.last else { return nil }
        let mid = sorted.count / 2
        let central = sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        return PredictionRange(
            low: min(fastest, central * (1 - minimumSpreadFraction)),
            central: central,
            high: max(slowest, central * (1 + minimumSpreadFraction))
        )
    }
}

/// Vickers and Vertosick (2016), "An empirical study of race times in recreational
/// endurance runners", BMC Sports Sci Med Rehabil 8:26, Model 1 (SPEC.md 3.9).
///
/// Marathon speed (m/s) = 0.16018617 + 0.83076202 x Riegel speed + 0.06423826 x (miles per week / 10),
/// where Riegel speed is 42,195 m over the Riegel (k = 1.07) marathon time from the
/// runner's longest race from 5K to the half marathon. This is the "average course"
/// form, with no course-difficulty offset. The coefficients come from the paper's
/// supplementary formulae as reproduced in a systematic review of marathon prediction
/// equations; see the PR for what was and wasn't checked against the original.
///
/// **Unverified constants:** the four coefficients (intercept, Riegel-speed and
/// weekly-mileage terms, and the 1.07 Riegel exponent) and the 227.6 min² validation
/// MSE are all unverified against the paper's Additional file 1. Someone with access
/// should check all five against the original file.
///
/// The predictor feeds this the longest best effort in range, which may be a training
/// split or a hard session rather than a race; the UI should say "longest recent effort".
///
/// For most runners the corrected time is slower than plain Riegel. At high weekly volume
/// for the runner's speed it can come out faster (the regression gives mileage its own
/// term), so for each runner there is one weekly volume where the two coincide. The code
/// never returns the Riegel value itself for a marathon.
public enum VickersVertosick {
    public static let intercept = 0.16018617
    public static let riegelSpeedCoefficient = 0.83076202
    /// Per 10 miles of typical weekly running.
    public static let weeklyMileageCoefficient = 0.06423826
    /// Race distances the model was built on: 5K to the half marathon.
    public static let raceMeters: ClosedRange<Double> = (Distance.fiveK * 0.99)...(Distance.halfMarathon * 1.01)
    /// Model 1's published validation mean squared error was 227.6 min²; its root, in seconds,
    /// sets the half-width of the marathon range.
    public static let validationRMSESeconds = 227.6.squareRoot() * 60

    /// Corrected marathon seconds from a race of 5K to the half marathon and typical weekly miles.
    /// Returns nil for inputs that aren't finite and positive or outside the model's race distances.
    public static func marathonSeconds(raceMeters: Double, raceSeconds: Double, weeklyMiles: Double) -> Double? {
        guard self.raceMeters.contains(raceMeters), weeklyMiles.isFinite, weeklyMiles > 0,
              let riegelSeconds = RacePredictor.riegel(knownMeters: raceMeters, knownSeconds: raceSeconds,
                                                       targetMeters: Distance.marathon, exponent: 1.07) else {
            return nil
        }
        let riegelSpeed = Distance.marathon / riegelSeconds
        let speed = intercept + riegelSpeedCoefficient * riegelSpeed + weeklyMileageCoefficient * (weeklyMiles / 10)
        guard speed.isFinite, speed > 0 else { return nil }
        return Distance.marathon / speed
    }
}
