import Foundation

/// A week whose easy runs the adaptation engine capped at a cut long run
/// (SPEC.md 3.5 rule 5, F3, F4; owner's decision, #54), with the time the
/// week held **before** the cap.
///
/// The cap drops the time it cuts (it is not moved to other runs), so the
/// week comes out smaller. A smaller week would make the long run's share
/// of it larger again and trigger a second share repair, so the week keeps
/// its time before the cap, and keeps it once the week is history. The
/// checker reads the week's long-run share (and a marathon plan's 35%
/// warning and 45% ceiling) against it, and the 10% and rolling 4-week
/// checks of the weeks after it read the week at it too (rule 6's bound and the
/// rule 4 and 7 pre-break levels read the week at its own time), so the cut does not
/// spread down the plan (`GuardrailChecker.check(regrowth:)`, which carries
/// it in `GuardrailRegrowth.preCap`). A week with no entry is read at its
/// own time. Heuristic, as the rest of 3.5; no study tests it.
public struct PreCapWeek: Equatable, Sendable, Codable {
    /// Monday 00:00 of the week.
    public let weekStart: Date
    /// The week's time before the cap, in seconds, races included (the share
    /// is read against the whole week, 3.5 rule 5).
    public let secondsBeforeCap: Double
    /// The time the cap cut, in seconds: `secondsBeforeCap` less what the
    /// week held right after it.
    public let secondsCut: Double
    /// The same two readings in meters, for a plan measured in distance.
    /// Nil when some session of the week had no known distance (the week is
    /// then read at its own distance).
    public let metersBeforeCap: Double?
    public let metersCut: Double?

    public init(weekStart: Date, secondsBeforeCap: Double, secondsCut: Double,
                metersBeforeCap: Double? = nil, metersCut: Double? = nil) {
        self.weekStart = weekStart
        self.secondsBeforeCap = secondsBeforeCap
        self.secondsCut = secondsCut
        self.metersBeforeCap = metersBeforeCap
        self.metersCut = metersCut
    }

    /// What the week reads as when it holds `actual` now (in `measure`): its
    /// own volume, plus the cut time that is still cut. If the week's runs
    /// were cut again, or one was dropped or missed, the reading falls with
    /// them (the cut counts in proportion to what the week still holds; this
    /// proportional reading is a heuristic of this implementation, which the
    /// spec does not give), so a later cut is never measured against time the
    /// week no longer holds; and it never reads above the time before the cap, so time regrown into the capped runs is not
    /// counted twice. Never below `actual`. A value that isn't a finite
    /// number reads as `actual`.
    func reading(of actual: Double, _ measure: VolumeMeasure) -> Double {
        let before: Double?, cut: Double?
        switch measure {
        case .time: (before, cut) = (secondsBeforeCap, secondsCut)
        case .distance: (before, cut) = (metersBeforeCap, metersCut)
        }
        guard actual.isFinite, let before, let cut, before.isFinite, cut.isFinite, cut > 0 else { return actual }
        let afterCap = before - cut
        guard afterCap > 0 else { return actual }
        // Less than the capped week held (a run dropped or missed since, or a stop): the cut
        // time falls in proportion, so a week that was wiped out reads as wiped out and a
        // recovery or stop is never hidden behind the time that was cut.
        if actual < afterCap { return actual + cut * max(0, actual) / afterCap }
        return actual + min(cut, max(0, before - actual))
    }
}

/// The weeks the adaptation engine has capped (`PreCapWeek`), kept in
/// `AdaptationState.preCap` and handed to the checker through
/// `GuardrailRegrowth.preCap`.
public struct GuardrailPreCap: Equatable, Sendable, Codable {
    public var weeks: [PreCapWeek]

    public init(weeks: [PreCapWeek] = []) {
        self.weeks = weeks
    }

    /// No capped week: every week is read at its own time.
    public static let none = GuardrailPreCap()

    public var isEmpty: Bool { weeks.isEmpty }

    /// The entry for the week starting `weekStart`, if any.
    public func week(_ weekStart: Date) -> PreCapWeek? { weeks.first { $0.weekStart == weekStart } }

    /// What the week starting `weekStart` reads above `actual` (in `measure`):
    /// 0 for a week with no entry.
    func extra(_ weekStart: Date, actual: Double, _ measure: VolumeMeasure) -> Double {
        guard let w = week(weekStart) else { return 0 }
        return w.reading(of: actual, measure) - actual
    }

    /// The entries with the week starting `weekStart` set to the one capped
    /// from `before` (the week's volume before the cap, as the checker read
    /// it) down to `after`, in seconds and, when both are known, meters. For
    /// a week capped before, the caller passes `before` already read through
    /// the old entry (`reading(of:)`), so the new entry, which replaces the
    /// old one, still holds the week's first time before a cap. Nothing is
    /// recorded for a cut of 0 or less.
    func recording(weekStart: Date, secondsBefore: Double, secondsAfter: Double,
                   metersBefore: Double?, metersAfter: Double?) -> GuardrailPreCap {
        let cut = secondsBefore - secondsAfter
        guard secondsBefore.isFinite, secondsAfter.isFinite, cut > 1e-6 else { return self }
        var meters: (before: Double, cut: Double)?
        if let b = metersBefore, let a = metersAfter, b.isFinite, a.isFinite, b - a > 1e-6 { meters = (b, b - a) }
        let entry = PreCapWeek(weekStart: weekStart, secondsBeforeCap: secondsBefore, secondsCut: cut,
                               metersBeforeCap: meters?.before, metersCut: meters?.cut)
        var out = self
        out.weeks.removeAll { $0.weekStart == weekStart }
        out.weeks.append(entry)
        out.weeks.sort { $0.weekStart < $1.weekStart }
        return out
    }
}
