import Foundation

/// One live reading from the watch during a run (SPEC.md F11, section 7).
///
/// Every field except `time` is optional: `nil` means "not available in this
/// reading", never zero. A runner who is standing still reports a speed of 0,
/// which is a real value; a reading with no GPS fix has `gpsSpeed == nil`.
///
/// Readings from a live workout can arrive out of order or at uneven
/// intervals. `PaceEstimator.ingest(_:)` handles uneven intervals by scaling
/// its prediction step with the real elapsed time, and **drops** a reading
/// whose time is not after the last one it accepted (a streaming filter cannot
/// rewind). For batch use, `LiveReading.chronological(_:)` sorts a collection
/// first.
public struct LiveReading: Equatable, Sendable {
    /// Seconds since the start of the run.
    public var time: Double
    /// GPS ground speed in m/s. Negative values (CoreLocation's "invalid")
    /// and non-finite values are ignored by the estimator.
    public var gpsSpeed: Double?
    /// Horizontal accuracy of the location that produced `gpsSpeed`, in
    /// metres (a radius; smaller is better). Negative means invalid.
    public var gpsAccuracy: Double?
    /// The watch's own running speed in m/s (HealthKit's motion-based running
    /// speed), not GPS.
    public var watchSpeed: Double?
    /// Cadence in steps per minute.
    public var cadence: Double?
    /// Heart rate in beats per minute. Carried for later CueEngine stages
    /// (the HR ceiling); the pace estimator does not use it.
    public var heartRate: Double?
    /// Altitude in metres. Carried for later CueEngine stages (grade-adjusted
    /// targets, SPEC.md 3.6); the pace estimator does not use it.
    public var altitude: Double?

    public init(time: Double,
                gpsSpeed: Double? = nil,
                gpsAccuracy: Double? = nil,
                watchSpeed: Double? = nil,
                cadence: Double? = nil,
                heartRate: Double? = nil,
                altitude: Double? = nil) {
        self.time = time
        self.gpsSpeed = gpsSpeed
        self.gpsAccuracy = gpsAccuracy
        self.watchSpeed = watchSpeed
        self.cadence = cadence
        self.heartRate = heartRate
        self.altitude = altitude
    }

    /// The readings sorted by time, with non-finite times removed and, for
    /// equal times, only the first reading kept (stable order). Use it before
    /// replaying a batch that may be out of order.
    public static func chronological(_ readings: [LiveReading]) -> [LiveReading] {
        let finite = readings.enumerated().filter { $0.element.time.isFinite }
        let sorted = finite.sorted {
            $0.element.time != $1.element.time ? $0.element.time < $1.element.time : $0.offset < $1.offset
        }
        var out: [LiveReading] = []
        for (_, r) in sorted where out.last.map({ r.time > $0.time }) ?? true {
            out.append(r)
        }
        return out
    }
}
