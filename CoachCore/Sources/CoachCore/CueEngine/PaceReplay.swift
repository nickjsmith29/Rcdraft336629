import Foundation

/// Runs a `PaceEstimator` over a `SyntheticRun` and compares it with the
/// truth (SPEC.md section 7 replay harness; F11's "tracks lap-average pace
/// within 5 sec/mile").
public struct PaceReplay: Sendable {
    /// One reading's estimate next to the truth.
    public struct Sample: Equatable, Sendable {
        public var time: Double
        public var estimate: PaceEstimate?
        public var trueSpeed: Double
    }

    public let samples: [Sample]
    /// The run's true lap paces (seconds per mile) for every full mile.
    public let trueLapPaces: [Double]
    /// The estimator's lap pace (seconds per mile) over the same true laps:
    /// the time-weighted mean of its speed over the lap, as a pace. Each
    /// estimate holds until the next reading. nil when the estimator gave no
    /// estimate during the lap.
    public let estimatedLapPaces: [Double?]

    /// Replay `run` through a new estimator built with `config`.
    public init(run: SyntheticRun, config: PaceEstimatorConfig = PaceEstimatorConfig()) {
        var estimator = PaceEstimator(config: config)
        var samples: [Sample] = []
        for (reading, truth) in zip(run.readings, run.truth) {
            samples.append(Sample(time: reading.time, estimate: estimator.ingest(reading), trueSpeed: truth.speed))
        }
        self.samples = samples
        self.trueLapPaces = run.lapPaces

        var laps: [Double?] = []
        var start = 0.0
        for end in run.mileEndTimes {
            laps.append(PaceReplay.meanPace(samples, from: start, to: end))
            start = end
        }
        self.estimatedLapPaces = laps
    }

    private static func meanPace(_ samples: [Sample], from a: Double, to b: Double) -> Double? {
        var weighted = 0.0
        var covered = 0.0
        for (i, s) in samples.enumerated() {
            guard let e = s.estimate else { continue }
            let holdEnd = i + 1 < samples.count ? samples[i + 1].time : b
            let lo = max(s.time, a), hi = min(holdEnd, b)
            guard hi > lo else { continue }
            weighted += e.speed * (hi - lo)
            covered += hi - lo
        }
        guard covered > 0, weighted > 0 else { return nil }
        return UnitFormatting.metersPerMile / (weighted / covered)
    }

    /// Absolute lap pace errors in seconds per mile, one per lap that has an
    /// estimate (laps with none count as `.infinity`).
    public var lapErrors: [Double] {
        zip(trueLapPaces, estimatedLapPaces).map { t, e in e.map { abs($0 - t) } ?? .infinity }
    }

    /// Absolute instantaneous pace errors in seconds per mile at every reading
    /// where the runner is truly moving faster than `minSpeed` m/s and an
    /// estimate exists.
    public func instantaneousErrors(minSpeed: Double = 1.0) -> [Double] {
        samples.compactMap { s in
            guard s.trueSpeed >= minSpeed, let e = s.estimate else { return nil }
            let truePace = UnitFormatting.metersPerMile / s.trueSpeed
            let estSpeed = max(e.speed, 0.01)
            return abs(UnitFormatting.metersPerMile / estSpeed - truePace)
        }
    }

    /// The `p`-quantile (0...1) of values by nearest rank; nil when empty.
    public static func percentile(_ values: [Double], _ p: Double) -> Double? {
        let v = values.filter { !$0.isNaN }.sorted()
        guard !v.isEmpty else { return nil }
        let rank = Int((p.clamped(to: 0...1) * Double(v.count)).rounded(.up))
        return v[min(max(rank - 1, 0), v.count - 1)]
    }
}

private extension Double {
    func clamped(to r: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, r.lowerBound), r.upperBound) }
}
