import Foundation

/// The one formatter for distance, pace and climb in every unit the runner
/// can choose (`UnitPreference`). Values come in SI (metres, seconds per km,
/// metres climbed per km) and are converted **before** rounding, so a shown
/// number is the input rounded once in the shown unit. Locale-free, like
/// `PlanFormatting`.
public enum UnitFormatting {
    /// Metres in a statute mile (exact, international mile of 1959).
    public static let metersPerMile = 1609.344
    /// Metres in a foot (exact).
    public static let metersPerFoot = 0.3048

    // MARK: Conversion (no rounding)

    /// A distance in metres as km or miles.
    public static func distanceValue(_ meters: Double, _ units: UnitPreference) -> Double {
        switch units {
        case .metric: return meters / 1000
        case .imperial: return meters / metersPerMile
        }
    }

    /// A pace in seconds per km as seconds per km or per mile.
    public static func paceValue(_ secondsPerKm: Double, _ units: UnitPreference) -> Double {
        switch units {
        case .metric: return secondsPerKm
        case .imperial: return secondsPerKm * metersPerMile / 1000
        }
    }

    /// Climb in metres per km as metres per km or feet per mile.
    public static func climbValue(_ metersPerKm: Double, _ units: UnitPreference) -> Double {
        switch units {
        case .metric: return metersPerKm
        case .imperial: return metersPerKm / metersPerFoot * metersPerMile / 1000
        }
    }

    // MARK: Unit words

    /// "km" or "mi".
    public static func distanceUnit(_ units: UnitPreference) -> String { units == .metric ? "km" : "mi" }

    /// "/km" or "/mi", the suffix after a pace clock.
    public static func paceSuffix(_ units: UnitPreference) -> String { "/" + distanceUnit(units) }

    /// "m per km" or "ft per mi".
    public static func climbUnit(_ units: UnitPreference) -> String { units == .metric ? "m per km" : "ft per mi" }

    // MARK: Text

    /// "8.2 km" or "5.1 mi": one decimal by default; "-" when not finite. A
    /// huge finite distance prints in full, a long number but no crash (#147).
    public static func distance(_ meters: Double, _ units: UnitPreference, decimals: Int = 1) -> String {
        guard meters.isFinite else { return "-" }
        return String(format: "%.\(max(0, decimals))f ", distanceValue(meters, units)) + distanceUnit(units)
    }

    /// The pace clock without a suffix, "5:31" (per km) or "8:53" (per mile),
    /// rounded to whole seconds after converting; "-" when not finite, not
    /// positive, or too large to count in whole seconds (#147).
    public static func paceClock(_ secondsPerKm: Double, _ units: UnitPreference) -> String {
        guard secondsPerKm.isFinite, secondsPerKm > 0,
              let s = Int(exactly: paceValue(secondsPerKm, units).rounded()) else { return "-" }
        return String(format: "%ld:%02ld", s / 60, s % 60)
    }

    /// "5:31/km" or "8:53/mi".
    public static func pace(_ secondsPerKm: Double, _ units: UnitPreference) -> String {
        let c = paceClock(secondsPerKm, units)
        return c == "-" ? c : c + paceSuffix(units)
    }

    /// A pace range, "4:27 to 4:35/km" or "7:10 to 7:23/mi".
    public static func paceRange(_ target: PaceTarget, _ units: UnitPreference) -> String {
        "\(paceClock(target.fastestSecondsPerKm, units)) to \(pace(target.slowestSecondsPerKm, units))"
    }

    /// "12 m per km" or "63 ft per mi", whole numbers; "-" when not finite or
    /// too large to count in whole numbers (#147).
    public static func climb(_ metersPerKm: Double, _ units: UnitPreference) -> String {
        guard metersPerKm.isFinite, let c = Int(exactly: climbValue(metersPerKm, units).rounded()) else { return "-" }
        return "\(c) \(climbUnit(units))"
    }
}
