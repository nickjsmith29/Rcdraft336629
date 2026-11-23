import Foundation

/// A tiny deterministic random generator (SplitMix64) so seeded synthetic runs
/// are identical on Linux and macOS. Not for anything but test data.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1) from the top 53 bits (same on every platform).
    public mutating func unit() -> Double {
        Double(next() >> 11) / 9_007_199_254_740_992.0
    }

    /// Uniform in [lo, hi).
    public mutating func uniform(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * unit() }

    /// Standard normal (Box-Muller, one value per call).
    public mutating func gaussian() -> Double {
        let u1 = max(unit(), 1e-12)
        let u2 = unit()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
}

/// One stretch of a synthetic run: how long, how fast (the true pace) and on
/// what grade. The true speed is constant within a segment and changes
/// instantly between segments, the hardest case for a smoother.
public struct SyntheticSegment: Equatable, Sendable {
    /// Length of the stretch in seconds.
    public var duration: Double
    /// True pace in seconds per km; nil means standing still (a pause).
    public var paceSecondsPerKm: Double?
    /// Grade as a fraction (0.05 = 5% uphill). Only changes the altitude
    /// stream; the segment's pace is the true pace on that grade.
    public var grade: Double

    public init(duration: Double, paceSecondsPerKm: Double?, grade: Double = 0) {
        self.duration = duration
        self.paceSecondsPerKm = paceSecondsPerKm
        self.grade = grade
    }

    /// A segment at a pace given in seconds per mile.
    public static func atMilePace(_ secondsPerMile: Double, duration: Double, grade: Double = 0) -> SyntheticSegment {
        SyntheticSegment(duration: duration, paceSecondsPerKm: secondsPerMile * 1000 / UnitFormatting.metersPerMile,
                         grade: grade)
    }

    /// A pause: standing still for `duration` seconds.
    public static func stopped(duration: Double) -> SyntheticSegment {
        SyntheticSegment(duration: duration, paceSecondsPerKm: nil, grade: 0)
    }

    /// True speed in m/s (0 when stopped).
    public var speed: Double {
        guard let p = paceSecondsPerKm, p.isFinite, p > 0 else { return 0 }
        return 1000 / p
    }
}

/// How noisy the simulated sensors are. Everything here is a synthetic-data
/// setting (heuristic), not a model of any real device or runner.
public struct SyntheticNoise: Equatable, Sendable {
    /// Seconds between readings on average (about 1 Hz).
    public var interval: Double = 1.0
    /// Reading times wander by up to this many seconds either way.
    public var timeJitter: Double = 0.15
    /// GPS horizontal accuracy of a good fix, drawn uniformly from this range (m).
    public var goodAccuracy: ClosedRange<Double> = 4...9
    /// GPS speed noise (1 sigma, m/s) = base + perMeter * accuracy.
    public var gpsSigmaBase: Double = 0.08
    public var gpsSigmaPerMeter: Double = 0.02
    /// Chance per reading that a dropout (no GPS at all) starts.
    public var dropoutProbability: Double = 0.01
    /// A dropout lasts a duration drawn from this range, in seconds.
    public var dropoutDuration: ClosedRange<Double> = 5...20
    /// Chance per reading of a bad fix: poor accuracy and a wild speed.
    public var spikeProbability: Double = 0.02
    /// Bad-fix accuracy range (m).
    public var spikeAccuracy: ClosedRange<Double> = 35...90
    /// A bad fix's speed error (1 sigma, m/s).
    public var spikeSpeedSigma: Double = 2.0
    /// The watch's running speed is the truth times a per-run bias drawn
    /// uniformly in 1 +/- this fraction, plus noise.
    public var watchBiasFraction: Double = 0.03
    /// Watch running-speed noise (1 sigma, m/s).
    public var watchSigma: Double = 0.12
    /// Cadence noise (1 sigma, steps per minute).
    public var cadenceSigma: Double = 1.5
    /// Stride (m per step) at true speed v is `strideIntercept + strideSlope * v`
    /// (stride grows with pace, so cadence = 60 v / stride).
    public var strideIntercept: Double = 0.3
    public var strideSlope: Double = 0.25
    /// Altitude noise (1 sigma, metres).
    public var altitudeSigma: Double = 0.4

    public init() {}

    /// No noise, no dropouts, no spikes, no bias: for exact-value tests.
    public static var clean: SyntheticNoise {
        var n = SyntheticNoise()
        n.timeJitter = 0
        n.gpsSigmaBase = 0
        n.gpsSigmaPerMeter = 0
        n.dropoutProbability = 0
        n.spikeProbability = 0
        n.watchBiasFraction = 0
        n.watchSigma = 0
        n.cadenceSigma = 0
        n.altitudeSigma = 0
        return n
    }
}

/// The truth at one reading time of a synthetic run.
public struct SyntheticTruth: Equatable, Sendable {
    public var time: Double
    /// True ground speed, m/s.
    public var speed: Double
    /// True distance covered since the start, metres.
    public var distance: Double
    /// True grade, fraction.
    public var grade: Double
}

/// A synthetic run: noisy live readings plus the truth behind them, for
/// replaying through the CueEngine in CI (SPEC.md section 7, the replay
/// harness). Everything is generated from a seed; there is no real data.
public struct SyntheticRun: Sendable {
    public let seed: UInt64
    public let segments: [SyntheticSegment]
    /// The readings in time order, about 1 Hz.
    public let readings: [LiveReading]
    /// True speed and distance at each reading time (same order and count).
    public let truth: [SyntheticTruth]
    /// True time (s since start) at the end of each full mile, in order.
    public let mileEndTimes: [Double]

    /// True pace of each full mile lap in seconds per mile (the time to cover
    /// that mile), in order.
    public var lapPaces: [Double] {
        var previous = 0.0
        return mileEndTimes.map { end in defer { previous = end }; return end - previous }
    }

    /// Total run time in seconds.
    public var duration: Double { segments.reduce(0) { $0 + max(0, $1.duration) } }

    /// Build a run: sample the segments at about `noise.interval` seconds with
    /// seeded noise. Segments with a non-positive or non-finite duration are
    /// skipped. The same seed, segments and noise always give the same run.
    public init(segments: [SyntheticSegment], seed: UInt64, noise: SyntheticNoise = SyntheticNoise()) {
        self.seed = seed
        let usable = segments.filter { $0.duration.isFinite && $0.duration > 0 }
        self.segments = usable
        var rng = SplitMix64(seed: seed)

        // Segment boundaries with cumulative distance at each start.
        var starts: [(t0: Double, d0: Double, seg: SyntheticSegment)] = []
        var t = 0.0, d = 0.0
        for s in usable {
            starts.append((t, d, s))
            t += s.duration
            d += s.speed * s.duration
        }
        let total = t

        // Mile end times, exact for piecewise constant speed.
        var mileEnds: [Double] = []
        var nextMile = UnitFormatting.metersPerMile
        for (t0, d0, seg) in starts where seg.speed > 0 {
            let dEnd = d0 + seg.speed * seg.duration
            while nextMile <= dEnd + 1e-9 {
                mileEnds.append(t0 + (nextMile - d0) / seg.speed)
                nextMile += UnitFormatting.metersPerMile
            }
        }
        self.mileEndTimes = mileEnds

        func state(at time: Double) -> (speed: Double, distance: Double, grade: Double, altitude: Double) {
            var altitude = 0.0
            for (i, entry) in starts.enumerated() {
                let end = entry.t0 + entry.seg.duration
                if time < end || i == starts.count - 1 {
                    let into = min(max(time - entry.t0, 0), entry.seg.duration)
                    return (entry.seg.speed, entry.d0 + entry.seg.speed * into, entry.seg.grade,
                            altitude + entry.seg.speed * into * entry.seg.grade)
                }
                altitude += entry.seg.speed * entry.seg.duration * entry.seg.grade
            }
            return (0, 0, 0, 0)
        }

        let watchBias = 1 + rng.uniform(-noise.watchBiasFraction, noise.watchBiasFraction)
        var readings: [LiveReading] = []
        var truth: [SyntheticTruth] = []
        var dropoutUntil = -1.0
        var clock = 0.0
        while clock <= total {
            let time = max(clock + rng.uniform(-noise.timeJitter, noise.timeJitter), readings.last.map { $0.time + 0.2 } ?? 0)
            guard time <= total + 1e-9 else { break }
            let st = state(at: time)

            var gpsSpeed: Double?
            var gpsAccuracy: Double?
            if time >= dropoutUntil {
                if rng.unit() < noise.dropoutProbability {
                    dropoutUntil = time + rng.uniform(noise.dropoutDuration.lowerBound, noise.dropoutDuration.upperBound)
                } else if rng.unit() < noise.spikeProbability {
                    gpsAccuracy = rng.uniform(noise.spikeAccuracy.lowerBound, noise.spikeAccuracy.upperBound)
                    gpsSpeed = max(0, st.speed + noise.spikeSpeedSigma * rng.gaussian())
                } else {
                    let acc = rng.uniform(noise.goodAccuracy.lowerBound, noise.goodAccuracy.upperBound)
                    let sigma = noise.gpsSigmaBase + noise.gpsSigmaPerMeter * acc
                    gpsAccuracy = acc
                    gpsSpeed = max(0, st.speed + sigma * rng.gaussian())
                }
            }

            let watch = max(0, st.speed * watchBias + noise.watchSigma * rng.gaussian())
            var cadence: Double?
            if st.speed > 0.5 {
                let stride = noise.strideIntercept + noise.strideSlope * st.speed
                cadence = 60 * st.speed / stride + noise.cadenceSigma * rng.gaussian()
            }
            let altitude = st.altitude + noise.altitudeSigma * rng.gaussian()

            readings.append(LiveReading(time: time, gpsSpeed: gpsSpeed, gpsAccuracy: gpsAccuracy,
                                        watchSpeed: watch, cadence: cadence, heartRate: nil, altitude: altitude))
            truth.append(SyntheticTruth(time: time, speed: st.speed, distance: st.distance, grade: st.grade))
            clock += noise.interval
        }
        self.readings = readings
        self.truth = truth
    }

    // MARK: Ready-made run shapes

    /// An easy steady run at a constant pace.
    public static func steady(secondsPerMile: Double, minutes: Double, seed: UInt64,
                              noise: SyntheticNoise = SyntheticNoise()) -> SyntheticRun {
        SyntheticRun(segments: [.atMilePace(secondsPerMile, duration: minutes * 60)], seed: seed, noise: noise)
    }

    /// A progression run: `steps` equal blocks, each faster than the last by
    /// `stepSeconds` per mile.
    public static func progression(startSecondsPerMile: Double, stepSeconds: Double, steps: Int,
                                   blockMinutes: Double, seed: UInt64,
                                   noise: SyntheticNoise = SyntheticNoise()) -> SyntheticRun {
        let segs = (0..<max(steps, 0)).map {
            SyntheticSegment.atMilePace(startSecondsPerMile - stepSeconds * Double($0), duration: blockMinutes * 60)
        }
        return SyntheticRun(segments: segs, seed: seed, noise: noise)
    }

    /// Mile repeats: warm-up, `reps` hard efforts of `repSeconds` at
    /// `repSecondsPerMile` with jog recoveries, cool-down.
    public static func repeats(warmupMinutes: Double, reps: Int, repSecondsPerMile: Double, repSeconds: Double,
                               jogSecondsPerMile: Double, jogSeconds: Double, easySecondsPerMile: Double,
                               cooldownMinutes: Double, seed: UInt64,
                               noise: SyntheticNoise = SyntheticNoise()) -> SyntheticRun {
        var segs = [SyntheticSegment.atMilePace(easySecondsPerMile, duration: warmupMinutes * 60)]
        for _ in 0..<max(reps, 0) {
            segs.append(.atMilePace(repSecondsPerMile, duration: repSeconds))
            segs.append(.atMilePace(jogSecondsPerMile, duration: jogSeconds))
        }
        segs.append(.atMilePace(easySecondsPerMile, duration: cooldownMinutes * 60))
        return SyntheticRun(segments: segs, seed: seed, noise: noise)
    }

    /// A rolling hilly run: alternating climbs and descents at a constant
    /// effort, whose true pace is slower uphill and faster downhill, with more
    /// GPS dropouts than the default.
    public static func hilly(basePaceSecondsPerMile: Double, hillSeconds: Double, hills: Int,
                             grade: Double, seed: UInt64, noise: SyntheticNoise? = nil) -> SyntheticRun {
        var n = noise ?? SyntheticNoise()
        if noise == nil {
            n.dropoutProbability = 0.025
            n.dropoutDuration = 8...25
        }
        var segs: [SyntheticSegment] = []
        for i in 0..<max(hills, 0) {
            let up = i % 2 == 0
            // Rough heuristic: about 12 s/mile slower per 1% uphill, 8 s faster per 1% downhill.
            let pct = abs(grade) * 100
            let pace = basePaceSecondsPerMile + (up ? 12 : -8) * pct
            segs.append(.atMilePace(pace, duration: hillSeconds, grade: up ? abs(grade) : -abs(grade)))
        }
        return SyntheticRun(segments: segs, seed: seed, noise: n)
    }
}
