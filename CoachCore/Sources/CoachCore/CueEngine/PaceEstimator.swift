import Foundation

/// Tuning for `PaceEstimator`. **Every number here is a heuristic** chosen
/// against synthetic runs (`SyntheticRun`), not a measured constant, and none
/// stands for a particular runner. Units are SI.
public struct PaceEstimatorConfig: Equatable, Sendable {
    /// GPS readings with a horizontal accuracy worse than this (metres) are
    /// ignored. Heuristic.
    public var maxGPSAccuracy: Double = 30
    /// A GPS reading counts as "good" for learning the stride and the watch
    /// speed scale when its accuracy is at most this (metres). Heuristic.
    public var goodGPSAccuracy: Double = 12
    /// Accuracy assumed when a GPS speed arrives without one (metres).
    /// Heuristic, deliberately middling.
    public var assumedGPSAccuracy: Double = 15
    /// GPS speed noise (1 sigma, m/s) at zero accuracy radius. Heuristic.
    public var gpsSigmaBase: Double = 0.10
    /// Extra GPS speed noise (m/s) per metre of horizontal accuracy: a poorer
    /// fix is trusted less. Heuristic.
    public var gpsSigmaPerMeter: Double = 0.02
    /// Watch running-speed noise (1 sigma, m/s) once its scale is calibrated
    /// against GPS. Heuristic.
    public var watchSigma: Double = 0.25
    /// Watch running-speed noise (m/s) before any calibration against GPS has
    /// been learned (its bias is unknown). Heuristic.
    public var watchSigmaUncalibrated: Double = 0.6
    /// Step-speed (cadence x stride) noise (1 sigma, m/s) at the speed the
    /// stride was learned at. Heuristic.
    public var stepSigma: Double = 0.4
    /// Extra step-speed noise (m/s) per m/s between the current estimate and
    /// the speed the stride was learned at, because stride changes with pace.
    /// Heuristic.
    public var stepSigmaPerSpeedGap: Double = 1.5
    /// Random-walk process noise for speed, in (m/s)^2 per second. Higher
    /// follows pace changes faster but passes more noise. Heuristic.
    public var processNoise: Double = 0.003
    /// The process noise is multiplied by the recent normalized innovation
    /// (a sign of a real pace change), clamped to 1...this. Heuristic.
    public var maxProcessNoiseBoost: Double = 40
    /// Smoothing of the normalized innovation per update (0...1). Heuristic.
    public var innovationSmoothing: Double = 0.25
    /// Change detection: a reading whose speed innovation is more than this
    /// many standard deviations off counts as a "surprise" (a real pace
    /// change or an outlier). Heuristic.
    public var changeThreshold: Double = 2.5
    /// This many surprises in a row in the same direction mean the pace really
    /// changed (a rep start, a stop): the variance is opened up to
    /// `changeVariance` so the estimate catches up fast. A single surprise is
    /// treated as an outlier and does not. Heuristic.
    public var changeRunLength: Int = 2
    /// Variance (m/s)^2 set when a pace change is detected. Heuristic.
    public var changeVariance: Double = 0.2
    /// Upper bound on the standard deviation of the first estimate, m/s. Heuristic.
    public var initialSigma: Double = 1.0
    /// The speed variance never grows past this (m/s)^2, so one reading after a
    /// long gap or pause is not taken as the whole truth. Heuristic.
    public var maxVariance: Double = 0.25
    /// A gap this long (seconds) between accepted readings counts as a pause
    /// or dropout and clears the steadiness history. Heuristic.
    public var gapSeconds: Double = 5
    /// Estimates below this speed (m/s) are "stopped": the pace is nil.
    /// Heuristic.
    public var stoppedSpeed: Double = 0.5
    /// Learning (stride, watch scale) needs a speed estimate at least this
    /// (m/s), so walking and standing never teach the stride. Heuristic.
    public var minLearningSpeed: Double = 1.5
    /// "Steady" means the estimate stayed within this band (m/s) over the
    /// steadiness window. Heuristic.
    public var steadyBand: Double = 0.3
    /// Length of the steadiness window, seconds. Heuristic.
    public var steadyWindowSeconds: Double = 8
    /// Time constant of the stride and watch-scale learning, seconds (the
    /// "stride learning rate"). Heuristic.
    public var learningTimeConstant: Double = 60
    /// Seconds of steady, good-accuracy learning before the stride or watch
    /// scale is trusted. Heuristic.
    public var minLearningSeconds: Double = 8
    /// Cadences outside this range (steps per minute) are ignored as sensor
    /// errors. Heuristic.
    public var cadenceRange: ClosedRange<Double> = 60...300
    /// Learned watch scale is clamped to this range. Heuristic.
    public var watchScaleRange: ClosedRange<Double> = 0.7...1.3

    public init() {}
}

/// A speed estimate with its uncertainty.
public struct PaceEstimate: Equatable, Sendable {
    /// Time of the reading this estimate was made at (seconds since start).
    public let time: Double
    /// Estimated ground speed, m/s (never negative).
    public let speed: Double
    /// One standard deviation of the speed estimate, m/s.
    public let speedSigma: Double
    /// Speed below which the runner counts as stopped (pace is nil).
    let stoppedSpeed: Double

    init(time: Double, speed: Double, speedSigma: Double, stoppedSpeed: Double) {
        self.time = time
        self.speed = speed
        self.speedSigma = speedSigma
        self.stoppedSpeed = stoppedSpeed
    }

    /// Pace in seconds per km; nil when stopped.
    public var secondsPerKm: Double? {
        speed >= stoppedSpeed ? 1000 / speed : nil
    }

    /// Pace in seconds per mile, via `UnitFormatting`; nil when stopped.
    public var secondsPerMile: Double? {
        secondsPerKm.map { UnitFormatting.paceValue($0, .imperial) }
    }

    /// Pace in the runner's unit (seconds per km or per mile); nil when stopped.
    public func pace(in units: UnitPreference) -> Double? {
        secondsPerKm.map { UnitFormatting.paceValue($0, units) }
    }

    /// One standard deviation of the pace in seconds per km (delta method from
    /// the speed sigma); nil when stopped.
    public var secondsPerKmSigma: Double? {
        speed >= stoppedSpeed ? 1000 * speedSigma / (speed * speed) : nil
    }
}

/// Smoothed pace estimate for the live voice coach (SPEC.md F11: "a smoothed
/// estimate that blends GPS speed with the watch's running-speed and step
/// data (Kalman filter or similar), not instantaneous GPS").
///
/// **Model.** A one-dimensional Kalman filter on ground speed with a random
/// walk motion model; process noise grows with elapsed time (so uneven
/// intervals and gaps are handled) and is boosted while the innovations say a
/// real pace change is under way (adaptive heuristic).
///
/// **Measurements** (each applied as its own scalar update, each with its own
/// noise):
/// - GPS speed. Noise grows with the horizontal accuracy; readings past
///   `maxGPSAccuracy` or with an invalid value are ignored.
/// - The watch's running speed, multiplied by a scale learned online against
///   GPS (the motion-based speed carries a bias).
/// - Step speed = cadence x stride length. The stride length is learned online
///   from good-accuracy GPS while the runner is steady; it is never a constant
///   or taken from anyone's data. Until a stride is learned, cadence is not
///   used (cadence-only input gives no estimate).
///
/// **Pauses.** With no readings the variance grows (capped) so the first
/// reading after a pause is trusted but not taken as the whole truth; speed
/// readings near 0 pull the estimate to 0 and the pace reads nil ("stopped").
/// The steadiness history is cleared after a gap so nothing is learned across
/// it.
///
/// Non-finite readings are ignored field by field. A reading whose time is not
/// after the last accepted one is dropped (see `LiveReading`).
public struct PaceEstimator: Sendable {
    public let config: PaceEstimatorConfig

    /// The latest estimate; nil until a usable measurement has arrived.
    public private(set) var estimate: PaceEstimate?

    /// Learned stride length in metres per step; nil until learned (a
    /// heuristic mean over steady, good-GPS stretches).
    public var strideLength: Double? {
        strideLearnedSeconds >= config.minLearningSeconds ? strideValue : nil
    }

    /// Learned multiplier applied to the watch's running speed; nil until
    /// learned.
    public var watchSpeedScale: Double? {
        scaleLearnedSeconds >= config.minLearningSeconds ? scaleValue : nil
    }

    private var speed = 0.0
    private var variance = 0.0
    private var lastTime: Double?
    private var innovationLevel = 1.0
    private var surpriseRun = 0
    private var surpriseSign = 0.0
    private var history: [(time: Double, speed: Double)] = []

    private var strideValue = 0.0
    private var strideLearnedSeconds = 0.0
    private var strideReferenceSpeed = 0.0
    private var scaleValue = 1.0
    private var scaleLearnedSeconds = 0.0

    public init(config: PaceEstimatorConfig = PaceEstimatorConfig()) {
        self.config = config
    }

    /// Forget everything, including the learned stride and watch scale.
    public mutating func reset() {
        self = PaceEstimator(config: config)
    }

    /// Feed readings in order and return the final estimate. Readings are put
    /// in order first (`LiveReading.chronological`).
    public static func run(_ readings: [LiveReading], config: PaceEstimatorConfig = PaceEstimatorConfig())
        -> [PaceEstimate?] {
        var estimator = PaceEstimator(config: config)
        return LiveReading.chronological(readings).map { estimator.ingest($0) }
    }

    /// Take one reading and return the estimate after it (the unchanged
    /// previous estimate if the reading was dropped or held nothing usable).
    @discardableResult
    public mutating func ingest(_ r: LiveReading) -> PaceEstimate? {
        guard r.time.isFinite else { return estimate }
        if let last = lastTime, r.time <= last { return estimate }

        let dt = lastTime.map { r.time - $0 } ?? 0
        let gap = dt > config.gapSeconds
        if gap { history.removeAll() }

        // Measurements valid in this reading.
        let gps = validGPS(r)
        let watchRaw = validWatch(r)
        let cadence = validCadence(r)

        // Predict.
        if lastTime != nil {
            let boost = min(max(innovationLevel, 1), config.maxProcessNoiseBoost)
            variance = min(variance + config.processNoise * boost * dt, config.maxVariance)
        }
        lastTime = r.time

        let steady = isSteady()
        var innovations: [(nis: Double, z: Double)] = []

        // GPS.
        if let g = gps, let n = update(g.speed, sigma: g.sigma) { innovations.append(n) }

        // Watch speed.
        if let w = watchRaw {
            let calibrated = watchSpeedScale != nil
            let sigma = calibrated ? config.watchSigma : config.watchSigmaUncalibrated
            let scale = calibrated ? scaleValue : 1.0
            if let n = update(w * scale, sigma: sigma) { innovations.append(n) }
        }

        // Step speed (needs a learned stride).
        if let c = cadence, let stride = strideLength {
            let gapSpeed = abs(speed - strideReferenceSpeed)
            let sigma = config.stepSigma + config.stepSigmaPerSpeedGap * gapSpeed
            if let n = update(c / 60 * stride, sigma: sigma) { innovations.append(n) }
        }

        guard initialized else { return estimate }

        if !innovations.isEmpty {
            let count = Double(innovations.count)
            let meanNIS = innovations.reduce(0) { $0 + $1.nis } / count
            let meanZ = innovations.reduce(0) { $0 + $1.z } / count
            innovationLevel += config.innovationSmoothing * (meanNIS - innovationLevel)
            if abs(meanZ) > config.changeThreshold {
                surpriseRun = (surpriseSign * meanZ > 0) ? surpriseRun + 1 : 1
                surpriseSign = meanZ
                if surpriseRun >= config.changeRunLength {
                    variance = max(variance, config.changeVariance)
                    surpriseRun = 0
                }
            } else {
                surpriseRun = 0
            }
        }

        // Learn stride and watch scale from good GPS while steady.
        if steady, let g = gps, g.accuracy <= config.goodGPSAccuracy,
           speed >= config.minLearningSpeed, abs(g.speed - speed) <= 3 * g.sigma + config.steadyBand {
            let weightTime = min(max(dt, 0), config.gapSeconds)
            if let c = cadence {
                let sample = g.speed * 60 / c
                strideValue = learn(strideValue, sample: sample, seconds: &strideLearnedSeconds, dt: weightTime)
                let w = weightTime / max(strideLearnedSeconds, weightTime, 1e-9)
                let rate = min(1, max(w, 1 - exp(-weightTime / config.learningTimeConstant)))
                strideReferenceSpeed += rate * (speed - strideReferenceSpeed)
            }
            if let w = watchRaw, w >= config.minLearningSpeed * 0.5 {
                let sample = min(max(g.speed / w, config.watchScaleRange.lowerBound), config.watchScaleRange.upperBound)
                scaleValue = learn(scaleValue, sample: sample, seconds: &scaleLearnedSeconds, dt: weightTime)
            }
        }

        history.append((r.time, speed))
        history.removeAll { r.time - $0.time > config.steadyWindowSeconds }

        estimate = PaceEstimate(time: r.time, speed: speed, speedSigma: variance.squareRoot(),
                                stoppedSpeed: config.stoppedSpeed)
        return estimate
    }

    // MARK: Internals

    private var initialized = false

    /// One scalar Kalman update. The first measurement ever starts the filter
    /// (returns nil); later ones return their normalized innovation squared.
    private mutating func update(_ z: Double, sigma: Double) -> (nis: Double, z: Double)? {
        guard initialized else {
            speed = max(0, z)
            variance = min(sigma * sigma, config.initialSigma * config.initialSigma)
            initialized = true
            return nil
        }
        let s = variance + sigma * sigma
        let innovation = z - speed
        let k = variance / s
        speed = max(0, speed + k * innovation)
        variance = max((1 - k) * variance, 1e-5)
        return (innovation * innovation / s, innovation / s.squareRoot())
    }

    /// Running mean over the first seconds, then an exponential average with
    /// `learningTimeConstant` (the stride learning rate).
    private func learn(_ current: Double, sample: Double, seconds: inout Double, dt: Double) -> Double {
        guard sample.isFinite, dt > 0 else { return current }
        let before = seconds
        seconds += dt
        if before <= 0 { return sample }
        let runningMean = dt / seconds
        let exponential = 1 - exp(-dt / config.learningTimeConstant)
        return current + max(runningMean, exponential) * (sample - current)
    }

    private func isSteady() -> Bool {
        guard let first = history.first, let last = history.last,
              last.time - first.time >= config.steadyWindowSeconds * 0.75 else { return false }
        let speeds = history.map(\.speed)
        guard let lo = speeds.min(), let hi = speeds.max() else { return false }
        return hi - lo <= config.steadyBand
    }

    private func validGPS(_ r: LiveReading) -> (speed: Double, accuracy: Double, sigma: Double)? {
        guard let s = r.gpsSpeed, s.isFinite, s >= 0 else { return nil }
        var accuracy = config.assumedGPSAccuracy
        if let a = r.gpsAccuracy {
            guard a.isFinite, a >= 0 else { return nil }
            accuracy = a
        }
        guard accuracy <= config.maxGPSAccuracy else { return nil }
        return (s, accuracy, config.gpsSigmaBase + config.gpsSigmaPerMeter * accuracy)
    }

    private func validWatch(_ r: LiveReading) -> Double? {
        guard let w = r.watchSpeed, w.isFinite, w >= 0 else { return nil }
        return w
    }

    private func validCadence(_ r: LiveReading) -> Double? {
        guard let c = r.cadence, c.isFinite, config.cadenceRange.contains(c) else { return nil }
        return c
    }
}
