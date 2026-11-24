import Foundation

/// One comparison a debrief line states, with the numbers as the line shows
/// them, so a check (a test, or a validator of LLM wording) can confirm the
/// comparison still holds for the rounded numbers a reader sees.
public struct DebriefStatedComparison: Equatable, Sendable {
    public enum Relation: String, Equatable, Hashable, Sendable {
        case lessThan, atMost, atLeast, greaterThan

        public func holds(_ a: Double, _ b: Double) -> Bool {
            switch self {
            case .lessThan: return a < b
            case .atMost: return a <= b
            case .atLeast: return a >= b
            case .greaterThan: return a > b
            }
        }
    }

    public let factID: String
    public let value: DebriefValue.Name
    public let relation: Relation
    public let limit: DebriefValue.Name
    /// The value and the limit as the line writes them.
    public let shownValue: String
    public let shownLimit: String
    /// The numbers those strings show.
    public let shownValueNumber: Double
    public let shownLimitNumber: Double
    /// True when no precision the formatter allows shows the strict
    /// comparison (the shown numbers are equal); the line then says "just".
    public let isBoundary: Bool
}

/// One line of a debrief and the facts it restates.
public struct DebriefLine: Equatable, Sendable {
    public enum Topic: String, CaseIterable, Equatable, Hashable, Sendable {
        case run, heartRate, drift, cadence, dataGap, plan
    }

    public let topic: Topic
    public let text: String
    /// Ids of the `DebriefFact`s the line restates; never empty.
    public let factIDs: [String]
    /// The comparisons of a value with a limit that the line states.
    public let comparisons: [DebriefStatedComparison]

    public init(topic: Topic, text: String, factIDs: [String], comparisons: [DebriefStatedComparison] = []) {
        self.topic = topic
        self.text = text
        self.factIDs = factIDs
        self.comparisons = comparisons
    }
}

/// The deterministic wording of a debrief (SPEC.md F6): three to five plain
/// lines on pace, heart rate, drift and cadence, and what changes in the plan.
///
/// It is the tested fallback and the contract for any LLM wording: every
/// number and comparison in a line comes from one of the facts it cites,
/// formatted by `DebriefFormat`. A value compared with a limit is shown with
/// enough precision for the comparison to hold on the shown numbers (169.7
/// against a 170 ceiling), or, when no precision separates them, with
/// boundary wording ("just under"). A topic without a fact gets no line, so a
/// run with little data gets fewer lines (even fewer than three) rather than
/// invented ones.
public enum DebriefText {
    /// The lines in reading order. When more topics have facts than
    /// `maximumLines` allows, the lowest-priority ones are left out (plan,
    /// run, heart rate, drift, cadence, then data gaps, highest first).
    public static func lines(_ d: DebriefFacts, heuristics: DebriefHeuristics = .default,
                             units u: UnitPreference = .metric) -> [DebriefLine] {
        let all = [runLine(d, units: u), heartRateLine(d, units: u), driftLine(d, units: u), cadenceLine(d, units: u),
                   gapLine(d, units: u), planLine(d, units: u)].compactMap { $0 }
        let limit = max(1, heuristics.maximumLines)
        guard all.count > limit else { return all }
        let priority: [DebriefLine.Topic] = [.plan, .run, .heartRate, .drift, .cadence, .dataGap]
        let keep = Set(priority.filter { t in all.contains { $0.topic == t } }.prefix(limit))
        return all.filter { keep.contains($0.topic) }
    }

    /// The lines joined by newlines.
    public static func text(_ d: DebriefFacts, heuristics: DebriefHeuristics = .default,
                            units u: UnitPreference = .metric) -> String {
        lines(d, heuristics: heuristics, units: u).map(\.text).joined(separator: "\n")
    }

    // MARK: - Stating a comparison

    /// A value and its limits as one line shows them.
    struct Stated {
        let value: String
        let limits: [DebriefValue.Name: String]
        let comparisons: [DebriefStatedComparison]
        var isBoundary: Bool { comparisons.contains { $0.isBoundary } }
        /// "just " when the shown numbers can't show the comparison.
        var just: String { isBoundary ? "just " : "" }
        func limit(_ n: DebriefValue.Name) -> String { limits[n] ?? "" }
    }

    /// Formats `value` and the `relations`' limits at the lowest precision at
    /// which every relation holds on the shown numbers: first more decimals on
    /// the value, then on both. Falls back to the default precision marked as
    /// a boundary. Nil when the fact lacks one of the values.
    static func state(_ f: DebriefFact, _ value: DebriefValue.Name,
                      _ relations: [(DebriefStatedComparison.Relation, DebriefValue.Name)],
                      _ d: DebriefFacts, _ u: UnitPreference = .metric) -> Stated? {
        guard let v = f.values.first(where: { $0.name == value }) else { return nil }
        let limits = relations.compactMap { r in f.values.first { $0.name == r.1 }.map { (r.0, $0) } }
        guard limits.count == relations.count, DebriefFormat.number(v, units: u) != nil,
              limits.allSatisfy({ DebriefFormat.number($0.1, units: u) != nil }) else { return nil }
        let vMax = DebriefFormat.maximumExtraDecimals(v.unit)
        let lMax = limits.map { DebriefFormat.maximumExtraDecimals($0.1.unit) }.max() ?? 0
        let attempts = (0...vMax).map { ($0, 0) } + (lMax > 0 ? (1...lMax).map { (min($0, vMax), $0) } : [])

        func make(_ ve: Int, _ le: Int, boundary: Bool) -> Stated {
            let vn = DebriefFormat.number(v, extraDecimals: ve, units: u)!
            let vs = DebriefFormat.string(v, timeZone: d.timeZone, extraDecimals: ve, units: u)
            var shown: [DebriefValue.Name: String] = [:]
            let cmps = limits.map { rel, l -> DebriefStatedComparison in
                let ln = DebriefFormat.number(l, extraDecimals: le, units: u)!
                let ls = DebriefFormat.string(l, timeZone: d.timeZone, extraDecimals: le, units: u)
                shown[l.name] = ls
                return DebriefStatedComparison(factID: f.id, value: v.name, relation: rel, limit: l.name,
                                               shownValue: vs, shownLimit: ls, shownValueNumber: vn, shownLimitNumber: ln,
                                               isBoundary: boundary && !rel.holds(vn, ln))
            }
            return Stated(value: vs, limits: shown, comparisons: cmps)
        }
        for (ve, le) in attempts {
            let s = make(ve, le, boundary: false)
            if s.comparisons.allSatisfy({ $0.relation.holds($0.shownValueNumber, $0.shownLimitNumber) }) { return s }
        }
        return make(0, 0, boundary: true)
    }

    // MARK: - Lines

    static func runLine(_ d: DebriefFacts, units u: UnitPreference = .metric) -> DebriefLine? {
        var parts: [String] = [], ids: [String] = [], cmps: [DebriefStatedComparison] = []
        if let f = d.fact("run"), case .run(let planned) = f.kind,
           let t = f.values.first(where: { $0.name == .movingTime || $0.name == .elapsedTime }) {
            let clock = "\(fmt(t, d, u)) \(t.name == .movingTime ? "moving" : "elapsed")"
            var s = f.values.first { $0.name == .distance }.map { "\(fmt($0, d, u)) in \(clock)" } ?? clock
            s += planned.map { ", for the planned \(AdaptationEngine.describe($0))." } ?? ", not matched to a planned session."
            parts.append(s)
            ids.append(f.id)
        }
        if let f = d.fact("pace") {
            switch f.kind {
            case .pace(let scope), .paceGradeAdjusted(let scope):
                guard let pace = f.values.first(where: { $0.name == .pace }) else { break }
                let per = UnitFormatting.paceSuffix(u)
                var adjusted = false
                if case .paceGradeAdjusted = f.kind { adjusted = true }
                var s = "\(adjusted ? "Grade-adjusted pace" : "Pace") was \(fmt(pace, d, u))\(per) \(words(scope))"
                if let c = f.comparison, let fast = f.values.first(where: { $0.name == .targetFastest }),
                   let slow = f.values.first(where: { $0.name == .targetSlowest }) {
                    let stated: Stated?
                    switch c {
                    case .within: stated = state(f, .pace, [(.atLeast, .targetFastest), (.atMost, .targetSlowest)], d, u)
                    case .below: stated = state(f, .pace, [(.lessThan, .targetFastest)], d, u)
                    case .above: stated = state(f, .pace, [(.greaterThan, .targetSlowest)], d, u)
                    case .withinTolerance:
                        // Outside the range by no more than the classifier's tolerance:
                        // state the end it passed, and that it is close enough to count as on pace
                        // (a statement about pace only, not the coach's overall reading of the run).
                        stated = pace.value > slow.value ? state(f, .pace, [(.greaterThan, .targetSlowest)], d, u)
                            : state(f, .pace, [(.lessThan, .targetFastest)], d, u)
                    }
                    let a = stated?.limits[.targetFastest] ?? fmt(fast, d, u), b = stated?.limits[.targetSlowest] ?? fmt(slow, d, u)
                    let target = "the \(a) to \(b)\(per) target"
                    let j = stated?.just ?? ""
                    if let stated { s = "\(adjusted ? "Grade-adjusted pace" : "Pace") was \(stated.value)\(per) \(words(scope))"; cmps += stated.comparisons }
                    switch c {
                    case .within: s += ", \(j)inside \(target)"
                    case .withinTolerance:
                        let side = pace.value > slow.value ? "slower" : "faster"
                        s += ", \(j)\(side) than \(target), but close enough to count as on pace"
                    case .below: s += ", \(j)faster than \(target)"
                    case .above: s += ", \(j)slower than \(target)"
                    }
                }
                if adjusted {
                    s += f.values.first { $0.name == .climb }
                        .map { ", on a route that climbed \(fmt($0, d, u)) \(UnitFormatting.climbUnit(u))" } ?? ", on a hilly route"
                }
                parts.append(s + ".")
                ids.append(f.id)
            case .paceNotCompared(.treadmill):
                parts.append("Treadmill pace is not compared with the target until the treadmill offset is learned.")
                ids.append(f.id)
            case .paceNotCompared(.hilly):
                guard let pace = f.values.first(where: { $0.name == .pace }) else { break }
                let climb = f.values.first { $0.name == .climb }.map { " on a route that climbed \(fmt($0, d, u)) \(UnitFormatting.climbUnit(u))" } ?? " on a hilly route"
                parts.append("Pace was \(fmt(pace, d, u))\(UnitFormatting.paceSuffix(u))\(climb); raw pace is not compared with the target until grade-adjusted pace exists.")
                ids.append(f.id)
            default: break
            }
        }
        guard !ids.isEmpty else { return nil }
        return DebriefLine(topic: .run, text: parts.joined(separator: " "), factIDs: ids, comparisons: cmps)
    }

    static func heartRateLine(_ d: DebriefFacts, units u: UnitPreference = .metric) -> DebriefLine? {
        guard let f = d.fact("heartRate"), case .heartRate(let scope) = f.kind,
              let hr = f.values.first(where: { $0.name == .heartRate }) else { return nil }
        let hasFloor = f.value(.bandFloor) != nil, hasCeiling = f.value(.bandCeiling) != nil
        var tail = "", shownHR = fmt(hr, d, u)
        var cmps: [DebriefStatedComparison] = []
        if let c = f.comparison, hasFloor || hasCeiling {
            let relations: [(DebriefStatedComparison.Relation, DebriefValue.Name)]
            switch (c, hasFloor, hasCeiling) {
            case (.above, _, true): relations = [(.atLeast, .bandCeiling)]
            case (.below, true, _): relations = [(.lessThan, .bandFloor)]
            case (_, true, true): relations = [(.atLeast, .bandFloor), (.lessThan, .bandCeiling)]
            case (_, false, true): relations = [(.lessThan, .bandCeiling)]
            default: relations = [(.atLeast, .bandFloor)]
            }
            if let s = state(f, .heartRate, relations, d, u) {
                shownHR = s.value
                cmps = s.comparisons
                let fl = s.limits[.bandFloor] ?? f.values.first { $0.name == .bandFloor }.map { fmt($0, d, u) } ?? ""
                let ce = s.limits[.bandCeiling] ?? f.values.first { $0.name == .bandCeiling }.map { fmt($0, d, u) } ?? ""
                switch (hasFloor, hasCeiling) {
                case (true, true):
                    let band = "the \(fl) to \(ce) bpm target band"
                    // The ceiling is exclusive: reaching it is already above the band.
                    tail = c == .above ? ", at or above the top of \(band)" : c == .below ? ", \(s.just)below \(band)" : ", \(s.just)inside \(band)"
                case (false, true):
                    tail = c == .above ? ", at or above the \(ce) bpm ceiling" : ", \(s.just)under the \(ce) bpm ceiling"
                default:
                    tail = c == .below ? ", \(s.just)below the \(fl) bpm floor" : ", at or above the \(fl) bpm floor"
                }
            }
        }
        var s = "Heart rate averaged \(shownHR) bpm \(words(scope))"
        if let z = f.values.first(where: { $0.name == .zone }) { s += " (zone \(fmt(z, d, u)))" }
        return DebriefLine(topic: .heartRate, text: s + tail + ".", factIDs: [f.id], comparisons: cmps)
    }

    static func driftLine(_ d: DebriefFacts, units u: UnitPreference = .metric) -> DebriefLine? {
        guard let f = d.fact("drift"), case .decoupling(let basis, let cls) = f.kind else { return nil }
        let relations: [(DebriefStatedComparison.Relation, DebriefValue.Name)]
        switch cls {
        case .good: relations = [(.lessThan, .goodLimit)]
        case .moderate: relations = [(.atLeast, .goodLimit), (.atMost, .highLimit)]
        case .aboveAerobicThreshold: relations = [(.greaterThan, .highLimit)]
        }
        guard let st = state(f, .decoupling, relations, d, u) else { return nil }
        let name = basis == .pace ? "pace-to-HR" : "power-to-HR"
        var s = "Heart-rate drift (\(name) decoupling) was \(st.value)%"
        switch cls {
        case .good: s += ": \(st.just)under \(st.limit(.goodLimit))%, good aerobic endurance at this effort"
        case .moderate: s += ": between \(st.limit(.goodLimit))% and \(st.limit(.highLimit))%, moderate aerobic endurance at this effort"
        case .aboveAerobicThreshold: s += ": \(st.just)over \(st.limit(.highLimit))%, a sign the effort was above the aerobic threshold"
        }
        // Only when the number shown is itself negative.
        if let shown = st.comparisons.first?.shownValueNumber, shown < 0 { s += " (efficiency rose in the second half)" }
        return DebriefLine(topic: .drift, text: s + ".", factIDs: [f.id], comparisons: st.comparisons)
    }

    static func cadenceLine(_ d: DebriefFacts, units u: UnitPreference = .metric) -> DebriefLine? {
        guard let f = d.fact("cadence"), case .cadence(let scope) = f.kind,
              let c = f.values.first(where: { $0.name == .cadence }) else { return nil }
        var s = "Cadence averaged \(fmt(c, d, u)) spm \(words(scope))"
        var cmps: [DebriefStatedComparison] = []
        if let fade = f.values.first(where: { $0.name == .cadenceFade }), let cmp = f.comparison {
            let size = DebriefValue(name: fade.name, value: abs(fade.value), unit: fade.unit)
            let thirds = "from the first third to the final third"
            if cmp == .within, DebriefFormat.number(size, units: u) == 0 {
                s += " and held steady \(thirds)"
            } else if fade.value < 0 {
                s += " and rose \(fmt(size, d, u))% \(thirds)"
            } else if let st = state(f, .cadenceFade, [(cmp == .above ? .atLeast : .lessThan, .fadeLimit)], d, u) {
                cmps = st.comparisons
                let side = cmp == .above ? "at or above" : "\(st.just)under"
                s += " and fell \(st.value)% \(thirds), \(side) the \(st.limit(.fadeLimit))% fade the coach counts as strain"
            }
        }
        return DebriefLine(topic: .cadence, text: s + ".", factIDs: [f.id], comparisons: cmps)
    }

    static func gapLine(_ d: DebriefFacts, units u: UnitPreference = .metric) -> DebriefLine? {
        var parts: [String] = [], ids: [String] = [], cmps: [DebriefStatedComparison] = []
        if let f = d.fact("tooShort"), let st = state(f, .movingTime, [(.lessThan, .minimumTime)], d, u) {
            parts.append("At \(st.value) moving, the run is \(st.just)under \(st.limit(.minimumTime)), too short to read heart rate, drift or cadence from.")
            ids.append(f.id)
            cmps += st.comparisons
        }
        if let f = d.fact("missing"), case .missing(let streams) = f.kind, !streams.isEmpty {
            parts.append("No \(list(streams)) was recorded, so \(streams.count == 1 ? "it is" : "they are") left out.")
            ids.append(f.id)
        }
        if let f = d.fact("patchy"), case .patchy(let streams) = f.kind, !streams.isEmpty {
            let names = list(streams)
            parts.append("\(names.prefix(1).uppercased() + names.dropFirst()) dropped out for too much of the run to read, so \(streams.count == 1 ? "it is" : "they are") left out.")
            ids.append(f.id)
        }
        guard !ids.isEmpty else { return nil }
        return DebriefLine(topic: .dataGap, text: parts.joined(separator: " "), factIDs: ids, comparisons: cmps)
    }

    static func planLine(_ d: DebriefFacts, units u: UnitPreference = .metric) -> DebriefLine? {
        var parts: [String] = [], ids: [String] = [], cmps: [DebriefStatedComparison] = []
        if let f = d.fact("assessment"), case .assessment(let s) = f.kind {
            let read: String
            switch s {
            case .ahead: read = "ahead of the plan"
            case .onTrack: read = "on track with the plan"
            case .behind: read = "behind the plan"
            case .overreached: read = "showing strain"
            }
            parts.append("The coach reads this run as \(read).")
            ids.append(f.id)
        }
        if let f = d.fact("noChange") {
            parts.append("No plan changes.")
            ids.append(f.id)
        } else {
            var clauses: [String] = []
            for f in d.facts {
                if case .change(let kind) = f.kind, let c = clause(kind, f, d, u) {
                    clauses.append(c.0)
                    cmps += c.1
                    ids.append(f.id)
                }
            }
            if let f = d.fact("moreChanges"), let n = f.values.first(where: { $0.name == .count }), n.value > 0 {
                clauses.append("and \(fmt(n, d, u)) more \(n.value == 1 ? "change" : "changes") in the plan")
                ids.append(f.id)
            }
            if !clauses.isEmpty { parts.append("Plan changes: \(clauses.joined(separator: "; ")).") }
        }
        guard !ids.isEmpty else { return nil }
        return DebriefLine(topic: .plan, text: parts.joined(separator: " "), factIDs: ids, comparisons: cmps)
    }

    static func clause(_ kind: PlanChange.Kind, _ f: DebriefFact, _ d: DebriefFacts,
                       _ u: UnitPreference = .metric) -> (String, [DebriefStatedComparison])? {
        func v(_ n: DebriefValue.Name) -> DebriefValue? { f.values.first { $0.name == n } }
        func sessions(_ x: DebriefValue) -> String { "\(fmt(x, d, u)) \(x.value == 1 ? "session" : "sessions")" }
        switch kind {
        case .paceTargetsFaster, .paceTargetsSlower:
            let dir = kind == .paceTargetsFaster ? "faster" : "slower"
            guard let step = v(.paceStep), let n = v(.sessions) else { return ("quality pace targets move \(dir)", []) }
            return ("quality pace targets move \(fmt(step, d, u)) \(dir) on \(sessions(n))", [])
        case .volumeHeld:
            guard let level = v(.heldLevel), let end = v(.holdEnd) else { return ("weekly volume is held", []) }
            return ("weekly volume stays at or below \(fmt(level, d, u)) until \(fmt(end, d, u))", [])
        case .easyPaceSlower:
            var s = "easy runs have run hot"
            var cmps: [DebriefStatedComparison] = []
            var cap: String?
            if let st = state(f, .easyMeanHeartRate, [(.atLeast, .easyCap)], d, u) {
                s = "easy runs averaged \(st.value) bpm, at or above the easy cap of \(st.limit(.easyCap)) bpm"
                cmps = st.comparisons
                cap = st.limit(.easyCap)
            }
            if let n = v(.sessions), n.value == 0, cap != nil { return (s + ", so let heart rate, not pace, set easy runs", cmps) }
            if let n = v(.sessions), n.value > 0, let step = v(.paceStep) {
                return (s + ", so easy pace targets move \(fmt(step, d, u)) slower on \(sessions(n))", cmps)
            }
            return (s, cmps)
        case .returnPaces:
            guard let n = v(.sessions), n.value > 0 else { return ("paces after your break are adjusted", []) }
            return ("paces after your break are adjusted on \(sessions(n))", [])
        case .longRunHeld:
            guard let st = state(f, .allowedTime, [(.lessThan, .plannedTime)], d, u) else {
                return ("the next long run is held at its length", [])
            }
            if st.isBoundary {
                return ("the next long run is capped just under its planned \(st.limit(.plannedTime))", st.comparisons)
            }
            return ("the next long run is capped at \(st.value) instead of \(st.limit(.plannedTime))", st.comparisons)
        case .painVolumeFreeze:
            guard let score = v(.painScore), let top = v(.painScaleMax) else { return ("volume growth is frozen after a pain check-in", []) }
            return ("volume growth is frozen after a pain score of \(fmt(score, d, u))/\(fmt(top, d, u))", [])
        case .qualitySwappedToEasy:
            guard let n = v(.sessions), n.value > 0 else { return ("a quality session becomes an easy run", []) }
            return ("\(fmt(n, d, u)) quality \(n.value == 1 ? "session becomes an easy run" : "sessions become easy runs")", [])
        case .painStop:
            guard let since = v(.stopSince) else { return ("progression stops after the pain you reported", []) }
            return ("progression has stopped since \(fmt(since, d, u)) after the pain you reported", [])
        case .painTestRun:
            return ("a short, easy test run is planned to check the pain", [])
        case .painTestRunFailed:
            return ("the test run didn't pass, so the pain stop stays and the count of good mornings starts again", [])
        case .painTestRunWithdrawn:
            return ("the planned test run is withdrawn after more pain, so the count of good mornings starts again", [])
        case .painTestRunRoom:
            return ("other runs this week are dropped to make room for the test run", [])
        case .painReturnRepeated:
            return ("the week at plan volume in the return repeats, with quality sessions still out", [])
        case .painStopEnded:
            return ("the pain stop has ended and a gradual return starts", [])
        case .painReturnStep:
            return ("the return after the pain stop changes step", [])
        case .sessionRested:
            guard let n = v(.sessions), n.value > 0 else { return ("a run becomes a rest day", []) }
            return ("\(fmt(n, d, u)) \(n.value == 1 ? "run becomes a rest day" : "runs become rest days")", [])
        case .sessionMoved:
            guard let n = v(.sessions) else { return nil }
            return ("\(fmt(n, d, u)) missed \(n.value == 1 ? "session moves" : "sessions move") to a later day this week", [])
        case .sessionDropped:
            guard let n = v(.sessions) else { return nil }
            return ("\(fmt(n, d, u)) missed \(n.value == 1 ? "session is" : "sessions are") dropped", [])
        case .sessionShortened:
            guard let n = v(.sessions), n.value > 0 else { return nil }
            return ("\(sessions(n)) \(n.value == 1 ? "is" : "are") shortened to respect the load guardrails", [])
        case .longRunSwappedToEasy:
            return ("a long run becomes an easy run of the same length, since the week has too little other running for a long run", [])
        case .sessionRegrown:
            guard let n = v(.sessions), n.value > 0 else { return ("the plan grows back toward its planned volume", []) }
            return ("\(sessions(n)) \(n.value == 1 ? "grows" : "grow") back toward the plan, never above it", [])
        case .holdShortfall:
            var parts: [String] = []
            if let over = v(.overHeldLevel) {
                if let w = v(.weeks), w.value > 1 {
                    parts.append("the volume hold can't be fully met in \(fmt(w, d, u)) weeks, up to \(fmt(over, d, u)) over the held level")
                } else {
                    parts.append("the volume hold can't be fully met: \(fmt(over, d, u)) stays over the held level")
                }
            }
            if let unchecked = v(.uncheckedWeeks), unchecked.value > 0 {
                let weeks = unchecked.value == 1 ? "a week whose volume is unknown" : "\(fmt(unchecked, d, u)) weeks whose volume is unknown"
                parts.append(parts.isEmpty ? "the volume hold can't be checked in \(weeks)" : "it can't be checked in \(weeks)")
            }
            return parts.isEmpty ? nil : (parts.joined(separator: "; "), [])
        }
    }

    static func words(_ scope: DebriefScope) -> String {
        switch scope {
        case .mainPart: return "over the main part"
        case .reps: return "over the reps"
        case .afterWarmUp: return "after the warm-up"
        }
    }

    static func list(_ streams: [DebriefStream]) -> String {
        let names = streams.map { s -> String in
            switch s {
            case .heartRate: return "heart rate"
            case .pace: return "pace"
            case .cadence: return "cadence"
            }
        }
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) or \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " or " + names.last!
        }
    }

    static func fmt(_ v: DebriefValue, _ d: DebriefFacts, _ u: UnitPreference = .metric) -> String {
        DebriefFormat.string(v, timeZone: d.timeZone, units: u)
    }
}

/// The one formatter every number in a debrief goes through, so a test (or
/// an LLM prompt) can check each number against the facts. Locale-free.
///
/// Facts stay in SI units (seconds, metres, seconds per km, metres per km);
/// `units` picks how distance, pace and climb are shown (`UnitPreference`,
/// metric by default). Each value is converted to the shown unit **before**
/// it is rounded, through `UnitFormatting`, so a comparison near a limit (a
/// 5:00/km target shown as 8:03/mi) is judged on the numbers the runner sees.
public enum DebriefFormat {
    /// Extra decimals `string(_:timeZone:extraDecimals:units:)` may add for a
    /// unit to separate a value from a limit; 0 for units shown as clocks,
    /// paces, volumes, counts and days. The same in both unit systems.
    public static func maximumExtraDecimals(_ unit: DebriefValue.Unit) -> Int {
        switch unit {
        case .bpm, .stepsPerMinute, .metersPerKm, .percent: return 2
        default: return 0
        }
    }

    /// The value as the debrief writes it, without a unit suffix the
    /// sentence adds itself ("5:31" for a pace, "148" for bpm, "3.2" for a
    /// percent). `extraDecimals` (up to `maximumExtraDecimals`) shows more
    /// precision, e.g. "169.7" bpm or "4.96" percent. A distance carries its
    /// unit ("8.2 km" or "5.1 mi"); a pace is per km or per mile and a climb
    /// in metres per km or feet per mile, as `units` says.
    public static func string(_ v: DebriefValue, timeZone: TimeZone, extraDecimals: Int = 0,
                              units: UnitPreference = .metric) -> String {
        let x = v.value
        guard x.isFinite else { return "-" }
        let extra = max(0, min(extraDecimals, maximumExtraDecimals(v.unit)))
        // A finite value too large to count in whole numbers shows "-" too,
        // rather than trapping (#147, as `PlanFormatting` does since #142).
        func whole(_ y: Double) -> String { Int(exactly: y.rounded()).map { "\($0)" } ?? "-" }
        switch v.unit {
        case .seconds:
            switch v.name {
            case .movingTime, .elapsedTime, .minimumTime: return clock(x)
            default: return PlanFormatting.volume(x, .time)
            }
        case .meters:
            return v.name == .distance ? UnitFormatting.distance(x, units) : PlanFormatting.volume(x, .distance, units: units)
        case .secondsPerKm:
            guard let s = Int(exactly: UnitFormatting.paceValue(x, units).rounded()) else { return "-" }
            return String(format: "%ld:%02ld", s / 60, s % 60)
        case .metersPerKm:
            let c = UnitFormatting.climbValue(x, units)
            return extra == 0 ? whole(c) : fixed(c, extra)
        case .bpm, .stepsPerMinute:
            return extra == 0 ? whole(x) : fixed(x, extra)
        case .zone:
            // Friel's labels: zones 1 to 4, then 5a, 5b and 5c (3.2).
            switch Int(exactly: x.rounded()).flatMap(HRZone.init(rawValue:)) {
            case .z5a?: return "5a"
            case .z5b?: return "5b"
            case .z5c?: return "5c"
            default: return whole(x)
            }
        case .count, .painScore:
            return whole(x)
        case .percent:
            return extra == 0 ? decimal(x) : fixed(x, 1 + extra)
        case .fraction:
            return PlanFormatting.percent(x)
        case .date:
            return PlanFormatting.day(Date(timeIntervalSince1970: x), timeZone: timeZone)
        }
    }

    /// The number `string` shows for the value, or nil for a day or a
    /// non-finite value. Times are in seconds, heart rate in bpm and so on,
    /// whatever `units` is. Distance, pace and climb are in the shown system's
    /// unit: metres (metric) or miles (imperial) for a distance or volume,
    /// seconds per km or per mile for a pace, metres per km or feet per mile
    /// for a climb. A value and its limit always share a unit, so a stated
    /// comparison holds on these numbers exactly when it holds as shown.
    public static func number(_ v: DebriefValue, extraDecimals: Int = 0, units: UnitPreference = .metric) -> Double? {
        let x = v.value
        guard x.isFinite else { return nil }
        let extra = max(0, min(extraDecimals, maximumExtraDecimals(v.unit)))
        func round(_ y: Double, _ decimals: Int) -> Double {
            let p = pow(10, Double(decimals))
            return (y * p).rounded() / p
        }
        switch v.unit {
        case .seconds:
            switch v.name {
            case .movingTime, .elapsedTime, .minimumTime: return clockSeconds(x)
            default: return (x / 60).rounded() * 60
            }
        case .meters:
            switch units {
            case .metric: return round(x / 1000, 1) * 1000
            case .imperial: return round(UnitFormatting.distanceValue(x, units), 1)
            }
        case .secondsPerKm: return UnitFormatting.paceValue(x, units).rounded()
        case .zone, .count, .painScore: return x.rounded()
        case .metersPerKm: return round(UnitFormatting.climbValue(x, units), extra)
        case .bpm, .stepsPerMinute: return round(x, extra)
        case .percent: return round(x, 1 + extra)
        case .fraction:
            let p = x * 100
            return (abs(p - p.rounded()) < 0.05 ? p.rounded() : round(p, 1)) / 100
        case .date: return nil
        }
    }

    /// A clock shows whole seconds elapsed, so 599.7 s is "9:59": it never
    /// shows a time the runner had not yet reached.
    static func clockSeconds(_ seconds: Double) -> Double { (seconds + 1e-6).rounded(.down) }

    /// "45:10" or "1:05:20"; "-" for a time too large to count in whole
    /// seconds (#147).
    static func clock(_ seconds: Double) -> String {
        guard let s = Int(exactly: clockSeconds(seconds)) else { return "-" }
        if s >= 3600 { return String(format: "%ld:%02ld:%02ld", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%ld:%02ld", s / 60, s % 60)
    }

    /// A whole number when it is one, else one decimal; never "-0".
    static func decimal(_ x: Double) -> String {
        let r = (x * 10).rounded() / 10
        if r == 0 { return "0" }
        if r == r.rounded() { return Int(exactly: r).map { "\($0)" } ?? "-" }
        return String(format: "%.1f", r)
    }

    /// Exactly `decimals` decimals; never "-0.00".
    static func fixed(_ x: Double, _ decimals: Int) -> String {
        let p = pow(10, Double(decimals))
        let r = (x * p).rounded() / p
        return String(format: "%.\(decimals)f", r == 0 ? 0 : r)
    }
}
