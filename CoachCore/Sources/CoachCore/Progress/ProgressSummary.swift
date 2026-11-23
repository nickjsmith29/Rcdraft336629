import Foundation

/// A metric that improved over the window, for the dashboard to highlight.
public struct ImprovedMetric: Equatable, Sendable {
    public let id: ProgressMetricID
    public let unit: ProgressUnit
    public let change: ProgressChange

    /// One plain sentence, for example "Easy pace at a fixed heart rate improved by 8.0 s/km over 4 weeks."
    /// For a target range it says how much closer the value moved, not how far
    /// it moved: "Easy-intensity share moved from 95.0% to 70.0%, 5.0 points closer to the 75.0-85.0% target, over 4 weeks."
    /// It says when the value crossed the range, and when a value below a
    /// floor was rated as the floor.
    public var plainText: String { plainText(units: .metric) }

    /// `plainText` with paces (and unnamed distances) in `units`; values are
    /// converted from s/km before they are rounded.
    public func plainText(units: UnitPreference) -> String {
        let span = ProgressText.weeks(change.weeks)
        let name = id.name(units: units)
        guard case .measured(let a) = change.outcome else { return "\(name) improved over \(span)." }
        let gain = ProgressText.amount(abs(a.gain), unit, units)
        if let target = a.target {
            let moved = "\(name) moved from \(ProgressText.value(a.earlier, unit, units)) to \(ProgressText.value(a.latest, unit, units)), "
            if a.crossedTarget {
                return moved + "crossing the \(ProgressText.range(target, unit, units)) target \(ProgressText.crossing(a)), "
                    + "\(gain) closer to it, over \(span)."
            }
            return moved + "\(gain) closer to the \(ProgressText.range(target, unit, units)) target, over \(span)."
        }
        if a.belowFloor, let floor = a.floor {
            return "\(name) improved by \(gain) over \(span) (\(ProgressText.thenNow(a, unit, units)); "
                + "\(ProgressText.floorRule(floor, unit, units)))."
        }
        return "\(name) improved by \(gain) over \(span)."
    }
}

/// Why a metric didn't improve over the window.
public enum StillKind: Equatable, Sendable {
    /// Its rated change (`ChangeAssessment.gain`) is within the noise threshold
    /// (heuristic), so it counts as no change.
    case withinNoise(ChangeAssessment)
    /// It got worse by more than the noise threshold.
    case worse(ChangeAssessment)
    /// There isn't enough data at one end of the window.
    case notEnoughData(ChangeGap)
}

/// One reason the window shows no improvement.
public enum StillReason: Equatable, Sendable {
    /// `ProgressOptions.isValid` failed.
    case invalidOptions
    /// No run started in the window.
    case noRunsInWindow
    /// A rated metric didn't improve, and why.
    case metric(ProgressMetricID, ProgressUnit, StillKind)

    /// One plain sentence the app can show as it stands.
    /// Paces (and unnamed distances) are in `units`, metric by default.
    public func plainText(windowWeeks: Int, units: UnitPreference = .metric) -> String {
        let span = ProgressText.weeks(windowWeeks)
        switch self {
        case .invalidOptions:
            return "The dashboard settings are invalid, so nothing could be compared."
        case .noRunsInWindow:
            return "No runs in the last \(span), so there is no training to compare."
        case .metric(let id, let unit, .withinNoise(let a)):
            let noise = "within the \(ProgressText.amount(a.threshold, unit, units)) noise threshold, so it counts as no change."
            let gain = ProgressText.amount(abs(a.gain), unit, units)
            if let target = a.target {
                let range = ProgressText.range(target, unit, units)
                if a.earlierPosition == .within && a.latestPosition == .within {
                    return "\(id.name(units: units)) stayed within the \(range) target over \(span) "
                        + "(\(ProgressText.thenNow(a, unit, units))), so it counts as no change."
                }
                if a.crossedTarget {
                    return "\(id.name(units: units)) crossed the \(range) target \(ProgressText.crossing(a)) over \(span) "
                        + "(\(ProgressText.thenNow(a, unit, units))), but its distance from the target changed by \(gain), " + noise
                }
                return "\(id.name(units: units)) moved from \(ProgressText.value(a.earlier, unit, units)) to \(ProgressText.value(a.latest, unit, units)) "
                    + "over \(span); its distance from the \(range) target changed by \(gain), " + noise
            }
            if a.belowFloor, let floor = a.floor {
                return "\(id.name(units: units)) went from \(ProgressText.value(a.earlier, unit, units)) to \(ProgressText.value(a.latest, unit, units)) "
                    + "over \(span); \(ProgressText.floorRule(floor, unit, units)), so the rated change is \(gain), " + noise
            }
            return "\(id.name(units: units)) changed by \(ProgressText.amount(abs(a.delta), unit, units)) over \(span), " + noise
        case .metric(let id, let unit, .worse(let a)):
            let gain = ProgressText.amount(abs(a.gain), unit, units)
            if let target = a.target {
                let range = ProgressText.range(target, unit, units)
                if a.crossedTarget {
                    return "\(id.name(units: units)) crossed the \(range) target \(ProgressText.crossing(a)) and is \(gain) "
                        + "further from it than \(span) ago (\(ProgressText.thenNow(a, unit, units)))."
                }
                return "\(id.name(units: units)) is \(gain) further from the \(range) target than \(span) ago "
                    + "(\(ProgressText.thenNow(a, unit, units)))."
            }
            if a.belowFloor, let floor = a.floor {
                return "\(id.name(units: units)) is \(gain) worse than \(span) ago (\(ProgressText.thenNow(a, unit, units)); "
                    + "\(ProgressText.floorRule(floor, unit, units)))."
            }
            return "\(id.name(units: units)) is \(gain) worse than \(span) ago."
        case .metric(let id, _, .notEnoughData(let gap)):
            switch gap {
            case .notInSeries: return "\(id.name(units: units)): the dashboard's series doesn't cover \(span)."
            case .latestMissing(let g): return "\(id.name(units: units)): not enough data now (\(ProgressText.gap(g)))."
            case .earlierMissing(let g): return "\(id.name(units: units)): not enough data \(span) ago (\(ProgressText.gap(g)))."
            }
        }
    }
}

/// A change whose two ends were computed partly from the same runs (F13:
/// every value cites its runs). Predicted times are the usual case: each
/// prediction draws on the predictor's lookback (120 days by default, SPEC.md
/// 3.9), so predictions 4 weeks apart share most of their best efforts and the
/// change rests on the few runs that differ. The summary says so instead of
/// shortening the window (see `ProgressBuilder`).
public struct SharedEvidence: Equatable, Sendable {
    public let id: ProgressMetricID
    public let weeks: Int
    /// Runs both ends cite, in the latest point's order.
    public let sharedActivityIDs: [String]
    /// Distinct runs either end cites.
    public let totalActivityCount: Int
    /// The predictor's lookback in days, for predicted times; nil otherwise.
    public let lookbackDays: Int?

    /// One plain sentence, for example "Predicted 5K time: each prediction looks
    /// back 120 days, so the values 4 weeks apart share 3 of the 5 runs they draw on; the change comes from the other 2."
    public var plainText: String { plainText(units: .metric) }

    /// `plainText` with an unnamed distance in `units`.
    public func plainText(units: UnitPreference) -> String {
        let span = ProgressText.weeks(weeks)
        let name = id.name(units: units)
        let why = lookbackDays.map { "each prediction looks back \($0) days, so " } ?? ""
        let shared = sharedActivityIDs.count
        if shared >= totalActivityCount {
            return "\(name): \(why)the values \(span) apart draw on the same "
                + "\(shared == 1 ? "run" : "\(shared) runs")."
        }
        let other = totalActivityCount - shared
        return "\(name): \(why)the values \(span) apart share \(shared) of the \(totalActivityCount) runs "
            + "they draw on; the change comes from the other \(other)."
    }

    /// The runs a measured change's two ends share, or nil when they share none.
    static func of(_ change: ProgressChange, id: ProgressMetricID, lookbackDays: Int) -> SharedEvidence? {
        guard case .measured = change.outcome,
              let latest = change.latest?.evidence.activityIDs, let earlier = change.earlier?.evidence.activityIDs
        else { return nil }
        let before = Set(earlier)
        let shared = baselineOrderedUnique(latest.filter { before.contains($0) })
        guard !shared.isEmpty else { return nil }
        var lookback: Int?
        if case .predictedTime = id { lookback = lookbackDays }
        return SharedEvidence(id: id, weeks: change.weeks, sharedActivityIDs: shared,
                              totalActivityCount: Set(latest).union(before).count, lookbackDays: lookback)
    }
}

public enum ProgressVerdict: Equatable, Sendable {
    /// At least one rated metric improved beyond its noise threshold.
    case improving([ImprovedMetric])
    /// Nothing improved; the reasons say why: run-level reasons first, then one per rated metric.
    case nothingMoved([StillReason])
}

/// The F13 acceptance check for one window: at least one improving metric,
/// or a plain statement that nothing moved and why (SPEC.md F13).
public struct ProgressSummary: Equatable, Sendable {
    public let windowWeeks: Int
    /// `windowEnd` minus `windowWeeks` weeks.
    public let windowStart: Date
    /// The dashboard's `asOf`.
    public let windowEnd: Date
    /// Runs that started in the window (after `windowStart`, up to `windowEnd`), by start time.
    /// They come from `ProgressDashboard.runs`, which holds only runs within
    /// the dashboard's longest lookback, so a window longer than that lookback
    /// lists only its later part.
    public let runsInWindow: [String]
    public let verdict: ProgressVerdict
    /// Rated metrics whose change over the window compares two values computed
    /// partly from the same runs, in dashboard order (usually predicted times).
    public let sharedEvidence: [SharedEvidence]

    /// Plain sentences for the verdict: one per improved metric, or a lead line
    /// and one per reason; then one per `sharedEvidence` entry.
    public var plainText: [String] { plainText(units: .metric) }

    /// `plainText` with paces (and unnamed distances) in `units`.
    public func plainText(units: UnitPreference) -> [String] {
        let verdictText: [String]
        switch verdict {
        case .improving(let metrics): verdictText = metrics.map { $0.plainText(units: units) }
        case .nothingMoved(let reasons):
            verdictText = ["Nothing moved in the last \(ProgressText.weeks(windowWeeks))."]
                + reasons.map { $0.plainText(windowWeeks: windowWeeks, units: units) }
        }
        return verdictText + sharedEvidence.map { $0.plainText(units: units) }
    }
}

extension ProgressDashboard {
    /// The summary for the `windowWeeks` weeks ending at `asOf` (4 by default,
    /// the F13 acceptance window). Informational metrics (weekly time, and
    /// cadence unless the options rate it) never count as improvement and
    /// give no reason. To check another window, build the dashboard with `asOf` at its end.
    public func summary(windowWeeks: Int = 4) -> ProgressSummary {
        guard optionsAreValid else {
            return ProgressSummary(windowWeeks: windowWeeks, windowStart: asOf, windowEnd: asOf,
                                   runsInWindow: [], verdict: .nothingMoved([.invalidOptions]), sharedEvidence: [])
        }
        let cal = PlanCalendar.calendar(timeZone: timeZone)
        let start = (1...ProgressOptions.maximumSeriesWeeks).contains(windowWeeks)
            ? BaselineBuilder.addDays(-7 * windowWeeks, to: asOf, cal) : asOf
        let inWindow = runs.filter { $0.start > start && $0.start <= asOf }.map(\.activityID)
        var improved: [ImprovedMetric] = []
        var reasons: [StillReason] = inWindow.isEmpty ? [.noRunsInWindow] : []
        var shared: [SharedEvidence] = []
        for m in metrics where m.polarity != .informational {
            let change = m.change(overWeeks: windowWeeks)
            if let s = SharedEvidence.of(change, id: m.id, lookbackDays: predictionLookbackDays) { shared.append(s) }
            switch change.outcome {
            case .unavailable(let gap):
                reasons.append(.metric(m.id, m.unit, .notEnoughData(gap)))
            case .measured(let a):
                switch a.direction {
                case .improving: improved.append(ImprovedMetric(id: m.id, unit: m.unit, change: change))
                case .worse: reasons.append(.metric(m.id, m.unit, .worse(a)))
                case .noChange: reasons.append(.metric(m.id, m.unit, .withinNoise(a)))
                case .notRated: break
                }
            }
        }
        return ProgressSummary(windowWeeks: windowWeeks, windowStart: start, windowEnd: asOf, runsInWindow: inWindow,
                               verdict: improved.isEmpty ? .nothingMoved(reasons) : .improving(improved),
                               sharedEvidence: shared)
    }
}

/// Plain-text pieces for summaries. Deterministic, so every sentence maps to a computed value (F13).
enum ProgressText {
    static func weeks(_ n: Int) -> String { n == 1 ? "1 week" : "\(n) weeks" }

    /// A change: a share or ratio changes by percentage points.
    /// A pace (or a change of pace) in s/km is converted to s/mi for
    /// imperial before it is rounded.
    static func amount(_ v: Double, _ unit: ProgressUnit, _ units: UnitPreference = .metric) -> String {
        switch unit {
        case .ratio: return String(format: "%.1f points", v * 100)
        case .percent: return String(format: "%.1f points", v)
        case .seconds: return String(format: "%.0f s", v)
        default: return String(format: "%.1f ", shown(v, unit, units)) + unit.symbol(units: units)
        }
    }

    /// `v` in the shown unit: s/km becomes s/mi for imperial; other units are unit-free.
    static func shown(_ v: Double, _ unit: ProgressUnit, _ units: UnitPreference) -> Double {
        unit == .secondsPerKilometer ? UnitFormatting.paceValue(v, units) : v
    }

    /// A level: a share or ratio as a percentage, a pace as a clock
    /// ("5:20/km" or "8:35/mi", converted before rounding).
    static func value(_ v: Double, _ unit: ProgressUnit, _ units: UnitPreference = .metric) -> String {
        switch unit {
        case .ratio: return String(format: "%.1f%%", v * 100)
        case .percent: return String(format: "%.1f%%", v)
        case .secondsPerKilometer: return UnitFormatting.pace(v, units)
        default: return amount(v, unit, units)
        }
    }

    /// "70.0% then, 90.0% now".
    static func thenNow(_ a: ChangeAssessment, _ unit: ProgressUnit, _ units: UnitPreference = .metric) -> String {
        "\(value(a.earlier, unit, units)) then, \(value(a.latest, unit, units)) now"
    }

    /// "from below to above" or "from above to below", for a change that crossed its target.
    static func crossing(_ a: ChangeAssessment) -> String {
        a.earlierPosition == .below ? "from below to above" : "from above to below"
    }

    /// "values below 0.0% rate as 0.0%".
    static func floorRule(_ floor: Double, _ unit: ProgressUnit, _ units: UnitPreference = .metric) -> String {
        "values below \(value(floor, unit, units)) rate as \(value(floor, unit, units))"
    }

    static func range(_ r: ClosedRange<Double>, _ unit: ProgressUnit, _ units: UnitPreference = .metric) -> String {
        switch unit {
        case .ratio: return String(format: "%.1f-%.1f%%", r.lowerBound * 100, r.upperBound * 100)
        case .percent: return String(format: "%.1f-%.1f%%", r.lowerBound, r.upperBound)
        case .secondsPerKilometer: return "\(UnitFormatting.paceClock(r.lowerBound, units))-\(UnitFormatting.pace(r.upperBound, units))"
        default: return String(format: "%.1f-%.1f ", shown(r.lowerBound, unit, units), shown(r.upperBound, unit, units))
            + unit.symbol(units: units)
        }
    }

    static func gap(_ g: ProgressGap) -> String {
        switch g {
        case .insufficient(let why): return reason(why.reason)
        case .noPlannedSessions: return "no planned sessions in those weeks"
        case .plannedVolumeUnknown: return "a planned session has no valid duration"
        case .noPrediction: return "no recent best efforts the predictor can use"
        case .noEffortAtDistance: return "no run covered that distance"
        }
    }

    static func reason(_ r: InsufficientReason) -> String {
        switch r {
        case .invalidInput: return "invalid input"
        case .noRuns: return "no runs"
        case .noCompleteWeek: return "no complete week yet"
        case .noMarkedEfforts: return "no race or time trial yet to set heart-rate zones"
        case .noQualifyingEfforts: return "no race or time trial that qualifies for heart-rate zones"
        case .needsLTHR: return "heart-rate zones need a race or time trial first"
        case .tooFewRuns(let have, let need): return "\(have) usable runs of the \(need) needed"
        case .noReadings: return "no readings"
        case .tooFewDays(let have, let need): return "\(have) days with a reading of the \(need) needed"
        case .noHeartRateData: return "no heart-rate data"
        case .noCadence: return "no cadence recorded"
        case .noDistanceStreams: return "no runs with a distance stream"
        case .spanTooShort(let days, let need): return String(format: "%.0f days of data of the %.0f needed", days, need)
        }
    }
}
