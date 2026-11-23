import Foundation

/// One recorded activity in the runner's history, independent of where it came
/// from (SPEC.md section 2, F1). Importers build these from HealthKit or Strava;
/// CoachCore never fills a missing value with a guess.
public struct Activity: Equatable, Sendable {
    /// Where the activity was imported from.
    public enum Source: Hashable, Sendable {
        case healthKit
        case strava
        /// Any other source, named by the importer (for example a plan app's export).
        case other(String)
    }

    /// What kind of activity it was.
    public enum Sport: Hashable, Sendable {
        case run
        case walk
        /// Any other sport, named by the importer.
        case other(String)
    }

    /// Importer-assigned identifier, unique within the history.
    public var id: String
    public var source: Source
    public var sport: Sport
    /// Wall-clock start of the activity.
    public var start: Date
    /// Elapsed duration in seconds, pauses included.
    public var durationSeconds: Double
    /// Total distance in meters; nil when not recorded.
    public var distanceMeters: Double?
    /// The source explicitly marked this as a treadmill run (for example Strava's
    /// trainer flag or a treadmill activity type). nil when the source says nothing.
    public var sourceSaysTreadmill: Bool?
    /// The source's indoor flag (for example HealthKit's indoor-workout metadata).
    /// nil when the source says nothing.
    public var isIndoor: Bool?
    /// Whether the activity has a GPS route. nil when unknown.
    public var hasRoute: Bool?
    /// Summary averages as reported by the source; nil when not reported.
    public var averageHeartRate: Double?
    public var averageCadence: Double?
    public var averagePower: Double?
    /// Recorded stream points, in time order.
    public var samples: [StreamSample]

    public init(id: String,
                source: Source,
                sport: Sport = .run,
                start: Date,
                durationSeconds: Double,
                distanceMeters: Double? = nil,
                sourceSaysTreadmill: Bool? = nil,
                isIndoor: Bool? = nil,
                hasRoute: Bool? = nil,
                averageHeartRate: Double? = nil,
                averageCadence: Double? = nil,
                averagePower: Double? = nil,
                samples: [StreamSample] = []) {
        self.id = id
        self.source = source
        self.sport = sport
        self.start = start
        self.durationSeconds = durationSeconds
        self.distanceMeters = distanceMeters
        self.sourceSaysTreadmill = sourceSaysTreadmill
        self.isIndoor = isIndoor
        self.hasRoute = hasRoute
        self.averageHeartRate = averageHeartRate
        self.averageCadence = averageCadence
        self.averagePower = averagePower
        self.samples = samples
    }

    /// The streams that hold at least one finite value in `samples`.
    public var presentStreams: Set<StreamKind> {
        Set(StreamKind.allCases.filter { kind in samples.contains { kind.value(in: $0) != nil } })
    }

    /// True when cadence was recorded, either as a stream or as a finite summary average.
    public var hasCadence: Bool {
        presentStreams.contains(.cadence) || (averageCadence?.isFinite ?? false)
    }
}

/// The optional streams of a `StreamSample`.
public enum StreamKind: String, CaseIterable, Hashable, Sendable {
    case heartRate, speed, power, cadence, distance, altitude

    /// The sample's value for this stream, or nil when it is missing or not finite.
    public func value(in sample: StreamSample) -> Double? {
        let raw: Double?
        switch self {
        case .heartRate: raw = sample.heartRate
        case .speed: raw = sample.speed
        case .power: raw = sample.power
        case .cadence: raw = sample.cadence
        case .distance: raw = sample.distance
        case .altitude: raw = sample.altitude
        }
        guard let value = raw, value.isFinite else { return nil }
        return value
    }
}
