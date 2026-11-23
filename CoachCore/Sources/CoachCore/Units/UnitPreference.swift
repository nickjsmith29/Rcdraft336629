import Foundation

/// How the app shows distances, paces and climb to the runner (SPEC.md
/// section 4, "Units setting"; F6, F13). CoachCore computes in SI units
/// throughout (seconds, metres, seconds per km); the preference only changes
/// the text a runner reads, never a target, a limit or a decision.
public enum UnitPreference: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    /// Kilometres, min/km and metres of climb.
    case metric
    /// Miles, min/mi and feet of climb.
    case imperial

    /// The default for a runner whose device uses `locale`: imperial where
    /// the locale's measurement system is the US one (`usesMetricSystem` is
    /// false, as for en_US), metric everywhere else. A UK locale reads as
    /// metric, since Foundation counts its measurement system as metric
    /// (heuristic: UK road signs use miles, but the runner can switch).
    public static func `default`(for locale: Locale) -> UnitPreference {
        locale.usesMetricSystem ? .metric : .imperial
    }

    /// The runner's saved choice when there is one, else the locale default.
    /// The app stores `rawValue` and passes it back here.
    public static func resolved(saved: UnitPreference?, locale: Locale) -> UnitPreference {
        saved ?? .default(for: locale)
    }
}
