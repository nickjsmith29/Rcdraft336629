import Foundation

/// Plain-English formatting for plan text: guardrail and pain explanations,
/// and the numbers of a planned session as the runner reads them. Locale-free
/// on purpose so explanations read the same in tests and on any device.
/// Distances and paces follow the runner's `UnitPreference` (metric unless
/// a caller passes one); the plan itself stays in SI units.
public enum PlanFormatting {
    /// "2026-03-02" in `timeZone`, printed with `%ld` so no part is cut to
    /// 32 bits (#157).
    public static func day(_ date: Date, timeZone: TimeZone) -> String {
        let c = PlanCalendar.calendar(timeZone: timeZone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "4 h 05 min" or "45 min" for seconds; "12.3 km" (or "7.6 mi") for meters.
    /// "-" (the placeholder `UnitFormatting` and the debrief use) for a value
    /// that isn't a finite number, or a time too large to count in whole
    /// minutes, rather than trapping (#142). A large time that can be counted
    /// prints in full, with `%ld`, not cut to 32 bits (#157).
    public static func volume(_ value: Double, _ measure: VolumeMeasure, units: UnitPreference = .metric) -> String {
        switch measure {
        case .time:
            guard value.isFinite, let minutes = Int(exactly: (value / 60).rounded()) else { return placeholder }
            if minutes < 60 { return "\(minutes) min" }
            return String(format: "%ld h %02ld min", minutes / 60, minutes % 60)
        case .distance:
            return UnitFormatting.distance(value, units)
        }
    }

    /// "35%" (rounded to a whole percent, or one decimal when needed to show a
    /// difference). "-" for a fraction that isn't a finite number, or a
    /// percent too large to count in whole numbers, rather than trapping (#142).
    public static func percent(_ fraction: Double) -> String {
        let p = fraction * 100
        guard p.isFinite, let whole = Int(exactly: p.rounded()) else { return placeholder }
        if abs(p - p.rounded()) < 0.05 { return "\(whole)%" }
        return String(format: "%.1f%%", p)
    }

    /// What `volume` and `percent` show for a value they can't: "-", as
    /// `UnitFormatting` and `DebriefFormat` do.
    static let placeholder = "-"

    /// A segment's pace target, "4:27 to 4:35/km" or "7:10 to 7:23/mi".
    public static func paceTarget(_ target: PaceTarget, units: UnitPreference = .metric) -> String {
        UnitFormatting.paceRange(target, units)
    }

    /// A session's distance, when it has one: "21.1 km" or "13.1 mi".
    public static func distance(of workout: PlannedWorkout, units: UnitPreference = .metric) -> String? {
        guard let m = workout.distanceMeters, m.isFinite, m > 0 else { return nil }
        return UnitFormatting.distance(m, units)
    }

    /// The session's purpose as the runner reads it, in `units`. The plan
    /// builder writes purposes once, in SI (`WorkoutPrescription.purpose`).
    /// Race day is built here, at the edge, from the prescription's
    /// `raceDistanceMeters` (`raceDayPurpose(meters:units:)`), so the race is
    /// named by its own distance and reads in the runner's units. A race-day
    /// prescription without a usable distance (one stored before #89) whose
    /// rules hold `.goalRace` and whose purpose ends in the exact
    /// " (<d> km)." suffix the older builder wrote is rebuilt the same way
    /// from the workout's own `distanceMeters`, so an old 10-mile plan no
    /// longer reads "half marathon". Any other race purpose with that suffix
    /// keeps the older rewrite of the suffix alone. Other purposes state
    /// minutes and bpm only and come back unchanged. Nil without a
    /// prescription.
    public static func purpose(of workout: PlannedWorkout, units: UnitPreference = .metric) -> String? {
        guard let prescription = workout.prescription else { return nil }
        if let race = prescription.raceDistanceMeters, isUsableRaceDistance(race) {
            return raceDayPurpose(meters: race, units: units)
        }
        let p = prescription.purpose
        guard workout.kind == .race, let m = workout.distanceMeters, isUsableRaceDistance(m) else { return p }
        let built = " (\(UnitFormatting.distance(m, .metric)))."
        guard p.hasSuffix(built) else { return p }
        if prescription.rules.contains(.goalRace) { return raceDayPurpose(meters: m, units: units) }
        guard units != .metric else { return p }
        return String(p.dropLast(built.count)) + " (\(UnitFormatting.distance(m, units)))."
    }
}
