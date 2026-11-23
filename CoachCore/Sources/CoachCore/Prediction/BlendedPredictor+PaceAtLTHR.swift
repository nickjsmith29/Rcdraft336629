import Foundation

extension BlendedPredictor {
    /// Predicts `targetMeters` with the threshold method fed by a measured
    /// pace at LTHR (SPEC.md 3.9; `PaceAtLTHRMeter`). Otherwise the same as
    /// `predict(targetMeters:efforts:asOf:lookbackDays:secondsPerMeterAtLTHR:typicalWeeklyMeters:)`.
    ///
    /// The pace counts under the same recency rule as the efforts: it is used
    /// only when every stretch it came from, oldest and newest, falls inside
    /// `asOf - lookbackDays ... asOf`. Otherwise (a stretch too old or after
    /// `asOf`, or no pace) the threshold method is skipped with `.missingInput`;
    /// measure the pace again with a lookback no longer than the predictor's.
    /// Its evidence (stretches, total time, dates, spread) lives on
    /// `PaceAtLTHR`; the threshold `MethodEstimate.evidence` stays empty
    /// because it lists best efforts only.
    public static func predict(
        targetMeters: Double,
        efforts: [BestEffort],
        asOf: Date,
        lookbackDays: Int = defaultLookbackDays,
        paceAtLTHR: PaceAtLTHR?,
        typicalWeeklyMeters: Double? = nil
    ) -> BlendedPrediction {
        predict(targetMeters: targetMeters, efforts: efforts, asOf: asOf, lookbackDays: lookbackDays,
                secondsPerMeterAtLTHR: currentPace(paceAtLTHR, asOf: asOf, lookbackDays: lookbackDays),
                typicalWeeklyMeters: typicalWeeklyMeters)
    }

    /// The pace in seconds per meter when all its stretches are inside the recency window.
    static func currentPace(_ pace: PaceAtLTHR?, asOf: Date, lookbackDays: Int) -> Double? {
        let dates = pace?.stretches.map(\.start) ?? []
        guard let pace, lookbackDays > 0, let oldest = dates.min(), let newest = dates.max() else { return nil }
        let earliest = asOf.addingTimeInterval(-Double(lookbackDays) * 86_400)
        return oldest >= earliest && newest <= asOf ? pace.secondsPerMeter : nil
    }
}
