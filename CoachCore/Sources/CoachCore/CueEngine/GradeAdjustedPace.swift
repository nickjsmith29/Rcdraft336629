import Foundation

/// A grade-to-pace-factor curve (SPEC.md 3.6). On a grade `g` (rise over run,
/// 0.05 = 5%) the target running pace is the flat target pace times
/// `factor(grade:)`: above 1 is slower, below 1 is faster.
///
/// This protocol is the seam for the personal curve that 3.6's rule asks for
/// once there is enough steady hilly data. Only `DefaultGradePaceCurve` exists
/// today; personalization is not built.
public protocol GradePaceCurve: Sendable {
    /// The pace factor on `grade`. Implementations must return a finite value
    /// above 0 for any input (treat a non-finite grade as flat, 1.0).
    func factor(grade: Double) -> Double
}

/// The default grade-adjusted pace curve of SPEC.md 3.6 ("Default curve").
///
/// - Grades are clamped to -0.45 ... +0.45, the range Minetti et al. measured [33].
/// - Uphill (g above 0): `f = max(1, Cr(g - 0.02) / Cr(0))` with Minetti's
///   polynomial `Cr(i) = 155.4 i^5 - 30.4 i^4 - 43.3 i^3 + 46.3 i^2 + 19.5 i + 3.6`.
///   The 0.02 shift is the spec's reading of Strava's "shifted to the right by
///   about 2%" [34]; the floor at 1 is a heuristic.
/// - Downhill (g below 0): straight lines through (0, 1.0), (-0.09, 0.88) and
///   (-0.18, 1.0), then 1.0 on steeper descents (heuristics between and past
///   Strava's two published points [34]).
///
/// It is a reasonable default, not a validated model (3.6).
public struct DefaultGradePaceCurve: GradePaceCurve, Equatable {
    /// Largest grade magnitude the curve uses (3.6).
    public static let gradeLimit = 0.45

    public init() {}

    /// Minetti et al.'s energy cost of running, J/kg/m, at grade `i` (a fraction).
    static func energyCost(_ i: Double) -> Double {
        ((((155.4 * i - 30.4) * i - 43.3) * i + 46.3) * i + 19.5) * i + 3.6
    }

    public func factor(grade: Double) -> Double {
        guard grade.isFinite else { return 1 }
        let g = min(max(grade, -Self.gradeLimit), Self.gradeLimit)
        if g > 0 {
            return max(1, Self.energyCost(g - 0.02) / Self.energyCost(0))
        }
        if g < 0 {
            let d = -g
            if d <= 0.09 { return 1 - 0.12 * (d / 0.09) }
            if d <= 0.18 { return 0.88 + 0.12 * ((d - 0.09) / 0.09) }
        }
        return 1
    }
}

public extension GradePaceCurve where Self == DefaultGradePaceCurve {
    /// The SPEC 3.6 default curve.
    static var standard: DefaultGradePaceCurve { DefaultGradePaceCurve() }
}
