import Foundation

/// Race-time prediction (SPEC.md 3.9).
///
/// Phase 0 ships only the Riegel model so the package has real, tested
/// logic from day one. Critical-speed and threshold-based predictors and
/// the blended prediction come in Phase 1.
public enum RacePredictor {
    /// Default Riegel exponent. SPEC.md 3.9 uses 1.07 (Vickers & Vertosick 2016)
    /// rather than Riegel's original 1.06, which tends to flatter longer races.
    public static let defaultExponent = 1.07

    /// Predicts the time for `targetMeters` from a known effort.
    ///
    /// SPEC.md 3.9: plain Riegel is well calibrated up to the half marathon.
    /// Marathon predictions must apply the Vickers-Vertosick correction
    /// (Phase 1 blended predictor) and must not use this value directly.
    /// - Returns: predicted seconds, or nil when any input is not finite and positive.
    public static func riegel(
        knownMeters: Double,
        knownSeconds: Double,
        targetMeters: Double,
        exponent: Double = defaultExponent
    ) -> Double? {
        let inputs = [knownMeters, knownSeconds, targetMeters, exponent]
        guard inputs.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return nil
        }
        return knownSeconds * pow(targetMeters / knownMeters, exponent)
    }
}

public enum Distance {
    public static let mile = 1609.344
    public static let fiveK = 5000.0
    public static let tenK = 10000.0
    public static let tenMiles = 16093.44
    public static let halfMarathon = 21097.5
    public static let marathon = 42195.0
}
