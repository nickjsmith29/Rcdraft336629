import Foundation

/// One point of a run's recorded streams (SPEC section 2, F1). Any stream may be
/// missing at any point: nil means "not recorded", never zero. Built from HealthKit
/// or Strava by the importers; CoachCore never fills gaps with guesses.
public struct StreamSample: Equatable, Sendable {
    /// Seconds since the activity started, wall-clock (pauses included).
    public var t: Double
    /// Heart rate in beats per minute.
    public var heartRate: Double?
    /// Speed in meters per second.
    public var speed: Double?
    /// Running power in watts.
    public var power: Double?
    /// Cadence in steps per minute (both feet).
    public var cadence: Double?
    /// Cumulative distance in meters.
    public var distance: Double?
    /// Altitude in meters.
    public var altitude: Double?
    /// False while the runner is paused or stopped.
    public var isMoving: Bool

    public init(t: Double,
                heartRate: Double? = nil,
                speed: Double? = nil,
                power: Double? = nil,
                cadence: Double? = nil,
                distance: Double? = nil,
                altitude: Double? = nil,
                isMoving: Bool = true) {
        self.t = t
        self.heartRate = heartRate
        self.speed = speed
        self.power = power
        self.cadence = cadence
        self.distance = distance
        self.altitude = altitude
        self.isMoving = isMoving
    }
}
