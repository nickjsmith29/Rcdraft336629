import Foundation

/// The Daniels return factor for paces after a break (SPEC 3.5 rule 4, #28;
/// notes and the source's gaps in `docs/research/break-pace-factor.md`).
///
/// The table is the one in [8], VDOT O2's "VDOT adjustments for time off from
/// running", the no-cross-training column (the app never asks about cross
/// training and doesn't read it from the runner's data). It is a coaching
/// table, not a study. Everything around it is a heuristic: how days off are
/// counted (`ReturnPaceSchedule`), taking the longer row between rows, applying
/// the factor to speed rather than to VDOT, and the halfway step.
public enum BreakPaceFactor {
    /// [8]'s rows: days off and the factor at that count. 72 days or more is
    /// the last row.
    static let rows: [(days: Int, factor: Double)] = [
        (5, 1.000), (6, 0.997), (7, 0.994), (10, 0.985), (14, 0.973), (21, 0.952), (28, 0.931),
        (35, 0.910), (42, 0.889), (49, 0.868), (56, 0.847), (63, 0.826), (70, 0.805), (72, 0.800),
    ]

    /// The factor for `daysOff` consecutive days without running.
    ///
    /// 1.000 up to 5 days. A count between two rows takes the **longer** row's
    /// value (heuristic: [8] gives only the rows, and the longer row is the
    /// larger slow-down), so 8 and 9 days use 0.985 and 11 to 13 use 0.973.
    /// 72 days or more, and any count past the last row, is 0.800. A negative
    /// count is 1.000 (no break).
    public static func factor(daysOff: Int) -> Double {
        rows.first { daysOff <= $0.days }?.factor ?? rows[rows.count - 1].factor
    }

    /// The factor in force `weeksBack` weeks into the return (1 for the first
    /// week back), given the break's own `factor` (SPEC 3.5 rule 4, "When it
    /// ends"). After a **short** break it is lifted over the return ramp's
    /// three weeks: week 1 at `factor`, week 2 halfway between `factor` and
    /// 1.0 (heuristic), week 3 on at 1.0, never earlier. After a longer break
    /// it holds at `factor` (the caller ends it, by a race, with `ended`).
    /// `ended` (a marked race after the break became the anchor) is 1.0 from
    /// then on. Weeks before the break ends (0 or less) are 1.0.
    static func effectiveFactor(_ factor: Double, shortBreak: Bool, weeksBack: Int, ended: Bool = false) -> Double {
        guard factor.isFinite, factor > 0, factor < 1, !ended, weeksBack >= 1 else { return 1 }
        guard shortBreak else { return factor }
        switch weeksBack {
        case 1: return factor
        case 2: return (factor + 1) / 2
        default: return 1
        }
    }

    /// Weeks after a break that no training pace may be faster than it was
    /// before the break (SPEC 3.5 rule 4): the return ramp's three weeks.
    static let returnWeeks = 3

    /// A pace in seconds per km under `factor`: the factor scales speed, so
    /// the pace is divided by it.
    static func pace(_ secondsPerKm: Double, factor: Double) -> Double { secondsPerKm / factor }
}

/// A recent effort that can anchor training paces (SPEC 3.9), with the date it
/// was run and whether the runner marked it as a race. `PlanInput.fitnessAnchor`
/// has no date, so the plan builder reads these to tell an anchor from before
/// a break from one after it (SPEC 3.5 rule 4). A time trial is not one:
/// `BaselinePlanMapping.anchorCandidates` takes marked races and training best
/// efforts only.
public struct AnchorEffort: Equatable, Hashable, Sendable {
    public let anchor: RaceEquivalent
    public let date: Date
    /// True for a run the runner marked as a race (not a best stretch of a training run).
    public let isMarkedRace: Bool

    public init(anchor: RaceEquivalent, date: Date, isMarkedRace: Bool) {
        self.anchor = anchor
        self.date = date
        self.isMarkedRace = isMarkedRace
    }

    /// True when the effort is usable as an anchor (the same test as
    /// `PlanInput.fitnessAnchor`: a distance from 3 km to the half marathon,
    /// a positive time at a plausible speed).
    var isValid: Bool {
        let a = anchor
        return a.distanceMeters.isFinite && BlendedPredictor.riegelEffortMeters.contains(a.distanceMeters)
            && a.seconds.isFinite && a.seconds > 0
            && BlendedPredictor.plausibleSpeed.contains(a.distanceMeters / a.seconds)
            && date.timeIntervalSinceReferenceDate.isFinite
    }

    /// The effort to anchor on (SPEC 3.9, heuristic): marked races beat best
    /// efforts of training runs, which are rarely all-out; among those, the
    /// one closest to `raceDistanceMeters` in log distance (Riegel's error
    /// grows with the ratio), and a tie goes to the most recent.
    static func pick(_ efforts: [AnchorEffort], raceDistanceMeters: Double) -> AnchorEffort? {
        guard raceDistanceMeters.isFinite, raceDistanceMeters > 0 else { return nil }
        let races = efforts.filter(\.isMarkedRace)
        let pool = races.isEmpty ? efforts : races
        let target = log(raceDistanceMeters)
        return pool.min { a, b in
            let da = abs(log(a.anchor.distanceMeters) - target), db = abs(log(b.anchor.distanceMeters) - target)
            if abs(da - db) > 1e-12 { return da < db }
            return a.date > b.date
        }
    }
}
