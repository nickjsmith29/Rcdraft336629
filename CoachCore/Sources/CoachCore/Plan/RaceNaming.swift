import Foundation

/// How a race is named in plan text (SPEC.md F2, F3). A race is named by its
/// own distance, never by the `RaceCategory` the plan builder trains it as:
/// a 10-mile race is a "10-mile race", not a "half marathon" (#89).
extension PlanFormatting {
    /// How close a distance must be to a named one to take its name, as a
    /// share of the named distance. A heuristic: 0.5% lets "21.1 km" read as a
    /// half marathon and 16,090 m as a 10-mile race, and is the tolerance
    /// `ProgressMetricID` uses for its distance names.
    public static let raceNameTolerance = 0.005

    /// The longest distance taken as a race, in metres. A heuristic sanity
    /// cap, not a training rule: 500 km is well above any race the plan
    /// builder takes (about a marathon at most, `RaceCategory`) and the
    /// longest common ultras (about 250 to 330 km), and
    /// it keeps the whole-km and whole-mile names far inside `Int`, so a
    /// corrupt or absurd stored distance reads as unusable instead of
    /// trapping (#89).
    public static let maxRaceDistanceMeters = 500_000.0

    /// True for a race distance the plan text can use: finite, above zero
    /// and at most `maxRaceDistanceMeters`.
    static func isUsableRaceDistance(_ meters: Double) -> Bool {
        meters.isFinite && meters > 0 && meters <= maxRaceDistanceMeters
    }

    /// The race's name from its distance: "marathon", "half marathon", a whole
    /// number of kilometres as "15K", or a whole number of miles as
    /// "10-mile race", whichever is closest within `raceNameTolerance`. The
    /// name doesn't depend on the runner's units, because race names are
    /// conventions ("10K" in miles too). Nil when no name fits (say 17.3 km),
    /// or for a distance that isn't finite, above zero and at most
    /// `maxRaceDistanceMeters`.
    public static func raceName(meters: Double) -> String? {
        guard isUsableRaceDistance(meters) else { return nil }
        var candidates: [(meters: Double, name: String)] = [
            (Distance.marathon, "marathon"),
            (Distance.halfMarathon, "half marathon"),
        ]
        let km = (meters / 1000).rounded()
        if km >= 1 { candidates.append((km * 1000, "\(Int(km))K")) }
        let miles = (meters / Distance.mile).rounded()
        if miles >= 1 { candidates.append((miles * Distance.mile, "\(Int(miles))-mile race")) }
        // Closest first; on a tie the earlier candidate (marathon, half, K, miles) wins.
        var best: (error: Double, name: String)?
        for c in candidates {
            let error = abs(meters - c.meters) / c.meters
            guard error <= raceNameTolerance else { continue }
            if best == nil || error < best!.error { best = (error, c.name) }
        }
        return best?.name
    }

    /// The race-day purpose, built at the edge from the race's distance:
    /// "Race day: your 10-mile race (16.1 km)." or, in miles, "Race day: your
    /// 10-mile race (10.0 mi)."; "Race day: your race (17.3 km)." when no name
    /// fits, and "Race day." for a distance that isn't finite, above zero and
    /// at most `maxRaceDistanceMeters`.
    public static func raceDayPurpose(meters: Double, units: UnitPreference = .metric) -> String {
        guard isUsableRaceDistance(meters) else { return "Race day." }
        let name = raceName(meters: meters) ?? "race"
        return "Race day: your \(name) (\(UnitFormatting.distance(meters, units)))."
    }
}
