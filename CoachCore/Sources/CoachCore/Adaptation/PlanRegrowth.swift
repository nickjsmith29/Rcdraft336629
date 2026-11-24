import Foundation

// SPEC.md 3.5 rule 6 inside the F4 engine (#64; owner decision Nov 21, #107):
// after a cut week, hard sessions become easy runs of the same length before
// runs are trimmed (`GuardrailRepair`), and the plan grows back toward the
// original plan as fast as the regrowth limits allow, never above it
// (`GuardrailRegrowth`). The spike rule (rule 1) still applies to every run,
// so the first long run back has to pass it. Every number here is a heuristic.
//
// The original plan is the plan as the app handed it in (`PlanSnapshot`): the
// engine keeps it in its state, because a rest-mode pain stop drops each
// session's kind and length and the app hands the cut plan back.
//
// How a week is read (SPEC 3.5 rules 4, 6 and 7, owner decision Nov 21, #107):
// - A week is **cut**, and starts a regrowth, only when going straight back
//   to the original plan the week after would break the spike rule (a run
//   more than 10% longer than the longest run of the 30 days before it) or
//   rise more than `GuardrailLimits.regrowthMaxWeeklyRise` (20%) over what
//   was run in the week (plus what the plan still holds for its days to
//   come, for the current week). Where the original plan itself rises more
//   than that into the week after (after a planned recovery week), the rise
//   test allows the plan's own rise, so a week run at plan is never cut
//   (a reading of the owner's rule, heuristic).
// - Each week of the regrowth may hold the higher of 20% more than the week
//   before and its return step (`GuardrailLimits.regrowthReturnSteps`: 65%,
//   then 82.5%, then 100% of the original plan's week, counted from the first
//   week after the cut week; or the plan's own rise there after a week at
//   plan, if more). Every run passes the spike rule, and nothing goes above
//   the original plan. A week also in rule 4's return ramp after a short
//   break takes the lower of the two (in the checker). A regrowth week run
//   at or above 1 / (1 + 20%), about 83%, of its own planned volume goes on
//   to the next step; one run under it is a new cut week, and the steps
//   start again from the week actually run (#109's clarification).
// - The regrowth goes on, measured against the original plan, until a week
//   is back at plan (`AdaptationLimits.regrowthAtPlanShare` of it, a margin
//   for GPS and moving-time noise), also after a rule 4 ramp that ends below
//   plan; the plain 10% check takes over only then. Ahead, a regrowth stays
//   on to the end of the plan (a week planned at plan has the plan as its
//   bound), and a week a pain freeze holds starts one or keeps it going.
// - Not after more than 14 days without running outside a pain stop
//   (`PainRecoveryLimits.rampDaysOff`): rule 4 says "longer than 14 days:
//   normal progression under rules 1 and 2".
// - During the return after a pain stop (rule 7) every week of the return is
//   in the regrowth, and the return's own ceilings and guards apply on top.
//   After a stop of 14 days or fewer, each week is bounded as above, so a
//   return week run short starts the steps again. After a stop
//   of more than 14 days, the weeks back are bounded by the return's own
//   ceilings (65%, 82.5%, 100% of the pre-stop level) and the spike rule,
//   not by a weekly rise measured from the stop weeks (owner decision Nov
//   21, #107). During a pain stop there is no regrowth.
//
// Growing back: after the guardrails are repaired, the sessions still to come
// that the engine shortened, rested or dropped are put back at their original
// length (as easy runs: regrowth restores volume, never intensity; quality
// comes back when the app hands in a plan again, F2/F3), and the same rules
// run over that plan again (the pain swap, the return's guards, the long-run
// gate, the holds and guardrail repair). The weeks where that holds more, and
// keeps every quality session the plan had, are taken. A long-run day comes
// back as the long run, not as an easy run of its length, so the long-run
// share (rule 5) still bounds it (#122): an easy run on that day is never
// longer than the floor or what the share leaves for the day (repair's
// swap), so no restored day dodges the share by its kind.

/// The plan as the app last handed it in, before the engine cut it (SPEC 3.5
/// rule 6, #64): what regrowth grows back to and never above. Stored in
/// `AdaptationState.planSnapshot` and kept by the engine.
///
/// **The app hands back `AdaptationOutcome.plan` unchanged** with the next
/// event, apart from dropping sessions dated before the event's day. A plan
/// handed in that differs from the plan the engine returned last
/// (`returned`) in any session from the event's day on, or in any session it
/// still holds, is a new plan from the app (F2, F3) and becomes the snapshot,
/// so a re-plan resets what regrowth grows back to.
public struct PlanSnapshot: Equatable, Sendable {
    /// One session of the plan the engine returned last: its id, date and a
    /// digest of everything stored about it (`PlanSnapshot.digest(of:)`).
    public struct ReturnedSession: Equatable, Sendable {
        public var id: String
        public var date: Date
        public var digest: String

        public init(id: String, date: Date, digest: String) {
            self.id = id
            self.date = date
            self.digest = digest
        }
    }

    /// The sessions of the plan as handed in, in date order. Pace moves the
    /// engine makes later (section 8) are applied here too.
    public var sessions: [PlannedWorkout]
    /// Weekly volumes outside races (guardrail measure) of sessions of an
    /// earlier snapshot dated before the plan that replaced it: they still
    /// say how much an earlier week was planned to hold.
    public var earlier: [PlanWeekVolume]
    /// The plan the engine returned last, session by session, or nil before
    /// the first event.
    public var returned: [ReturnedSession]?
    /// Each week's volume outside races (guardrail measure) as the engine
    /// first returned it once the week had begun (what was run in it so far
    /// plus what the plan returned held for it): a regrowth week's own
    /// planned volume, which says whether the week was run as planned or is
    /// a new cut week (3.5 rule 6, #107, #109). Taken at the week's first
    /// event, after the engine re-reads the week before, and never lowered
    /// later by the runs the week then misses.
    public var planned: [PlanWeekVolume]
    /// The finished weeks read as cut weeks (or regrowth weeks run below
    /// plan), with their original-plan volume: the rolling 4-week check keeps
    /// counting them at the original plan in the windows that still hold
    /// them, after the regrowth or the return that read them has ended (3.5
    /// rules 2, 6 and 7).
    public var cut: [PlanWeekVolume]

    public init(sessions: [PlannedWorkout] = [], earlier: [PlanWeekVolume] = [], returned: [ReturnedSession]? = nil,
                planned: [PlanWeekVolume] = [], cut: [PlanWeekVolume] = []) {
        self.sessions = sessions
        self.earlier = earlier
        self.returned = returned
        self.planned = planned
        self.cut = cut
    }

    /// `plan` as `returned` stores it.
    public static func returned(_ plan: [PlannedWorkout]) -> [ReturnedSession] {
        plan.sorted { $0.date != $1.date ? $0.date < $1.date : $0.id < $1.id }
            .map { ReturnedSession(id: $0.id, date: $0.date, digest: digest(of: $0)) }
    }

    /// True when `plan` is the plan the engine returned last (`returned`),
    /// handed back: every session it holds is one the engine returned,
    /// unchanged, and every session the engine returned dated on or after
    /// `from` is still there. Sessions dated before `from` may be dropped.
    public func isReturnedPlan(_ plan: [PlannedWorkout], from: Date) -> Bool {
        guard let returned else { return false }
        var left: [String: [String]] = [:]
        for r in returned { left[r.id, default: []].append(r.digest) }
        for s in plan {
            let d = Self.digest(of: s)
            guard let i = left[s.id]?.firstIndex(of: d) else { return false }
            left[s.id]!.remove(at: i)
        }
        var still: [String: Int] = [:]
        for r in returned where r.date >= from { still[r.id, default: 0] += 1 }
        var held: [String: Int] = [:]
        for s in plan { held[s.id, default: 0] += 1 }
        return still.allSatisfy { held[$0.key, default: 0] >= $0.value }
    }

    /// A digest of one session: FNV-1a over its stored form.
    public static func digest(of session: PlannedWorkout) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        guard let data = try? encoder.encode(WorkoutCoding(session)) else { return "" }
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in data {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return String(h, radix: 16)
    }
}

extension AdaptationEngine.Work {
    static let regrowthRule = "SPEC 3.5 rule 6 (heuristic, owner decision Nov 21, #107), F4, F9"

    // MARK: The snapshot

    /// Takes the plan handed in as the original plan, unless it is the plan
    /// the engine returned last handed back (`PlanSnapshot.isReturnedPlan`,
    /// sessions before the day of `asOf` may be dropped; with no `asOf`, none
    /// may). Sessions of the old snapshot dated before the new plan are kept
    /// as weekly volumes (`PlanSnapshot.earlier`).
    mutating func takeSnapshot(asOf: Date?) {
        let old = state.planSnapshot
        let from = asOf.flatMap { $0.timeIntervalSinceReferenceDate.isFinite ? calendar.startOfDay(for: $0) : nil } ?? .distantPast
        if old.isReturnedPlan(plan, from: from), !old.sessions.isEmpty || !old.earlier.isEmpty { return }
        let cutoff = plan.map(\.date).min() ?? history.map(\.date).max() ?? .distantPast
        // A new plan replaces the adapted one: a week it covers is no longer the
        // week that was capped, so its pre-cap time is not carried over. Weeks
        // before it are history and keep theirs (3.5 rule 5, #54).
        let firstWeek = min(weekOf(cutoff), asOf.map { weekOf($0) } ?? weekOf(cutoff))
        state.preCap.weeks.removeAll { $0.weekStart >= firstWeek }
        let ids = Set(plan.map(\.id))
        var earlier: [Date: Double] = [:]
        for e in old.earlier where e.week < weekOf(cutoff) || plan.isEmpty { earlier[e.week, default: 0] += e.volume }
        let measure = context.guardrails.measure
        for s in old.sessions where s.date < cutoff && !ids.contains(s.id) && s.kind != .race {
            let v = s.volume(measure) ?? 0
            if v.isFinite { earlier[weekOf(s.date), default: 0] += v }
        }
        state.planSnapshot = PlanSnapshot(
            sessions: plan.sorted { $0.date != $1.date ? $0.date < $1.date : $0.id < $1.id },
            earlier: earlier.keys.sorted().map { PlanWeekVolume(week: $0, volume: earlier[$0]!) },
            returned: old.returned, planned: old.planned, cut: old.cut)
    }

    /// Prunes the snapshot to the weeks regrowth may read and records the
    /// plan returned, session by session, so the same plan handed back keeps
    /// the snapshot, the current week's planned volume at its first event
    /// (`PlanSnapshot.planned`) and the finished weeks `regrowth` reads as
    /// cut (`PlanSnapshot.cut`).
    mutating func noteReturned(asOf: Date, regrowth: GuardrailRegrowth = .none) {
        let keep = shift(weekOf(asOf), weeks: -max(1, limits.regrowthSnapshotWeeks))
        let tz = tz
        var snap = state.planSnapshot
        snap.sessions.removeAll { PlanCalendar.weekStart(containing: $0.date, timeZone: tz) < keep }
        snap.earlier.removeAll { $0.week < keep }
        snap.returned = PlanSnapshot.returned(plan)
        let measure = context.guardrails.measure
        var weeks: [Date: Double] = [:]
        for s in plan where s.kind != .race {
            weeks[weekOf(s.date), default: 0] += s.volume(measure) ?? .nan
        }
        for s in history where weekOf(s.date) == weekOf(asOf) && s.kind != .race {
            weeks[weekOf(s.date), default: 0] += s.volume(measure) ?? .nan
        }
        var planned = Dictionary(snap.planned.filter { $0.week >= keep }.map { ($0.week, $0.volume) }, uniquingKeysWith: { a, _ in a })
        let current = weekOf(asOf)
        if planned[current] == nil, let v = weeks[current], v.isFinite { planned[current] = v }
        snap.planned = planned.keys.sorted().map { PlanWeekVolume(week: $0, volume: planned[$0]!) }
        var cut = Dictionary(snap.cut.filter { $0.week >= keep }.map { ($0.week, $0.volume) }, uniquingKeysWith: { a, _ in a })
        for c in regrowth.cutWeeks where c.weekStart < current && c.original.isFinite { cut[c.weekStart] = c.original }
        snap.cut = cut.keys.sorted().map { PlanWeekVolume(week: $0, volume: cut[$0]!) }
        state.planSnapshot = snap
    }

    /// Week `w`'s own planned volume (`PlanSnapshot.planned`), if recorded.
    func plannedVolume(_ w: Date) -> Double? {
        state.planSnapshot.planned.first { $0.week == w }?.volume
    }

    /// The original plan's volume outside races in `week` (guardrail
    /// measure), or nil when the snapshot has nothing that week or a session
    /// of unknown volume.
    func originalVolume(_ week: Date) -> Double? {
        let snap = state.planSnapshot
        let measure = context.guardrails.measure
        var total = snap.earlier.filter { $0.week == week }.reduce(0) { $0 + $1.volume }
        var any = snap.earlier.contains { $0.week == week }
        for s in snap.sessions where weekOf(s.date) == week {
            any = true
            guard s.kind != .race else { continue }
            guard let v = s.volume(measure) else { return nil }
            total += v
        }
        return any && total.isFinite ? total : nil
    }

    // MARK: The regrowth weeks

    /// The weeks of the regrowth (3.5 rule 6, owner decision Nov 21, #107)
    /// and the cut weeks it follows, for the checker (see the file comment).
    /// Empty during a pain stop and without a snapshot.
    func regrowth(asOf: Date) -> GuardrailRegrowth {
        var out = growthWeeks(asOf: asOf)
        out.preCap = state.preCap   // the weeks capped at a cut long run (3.5 rule 5, #54)
        return out
    }

    private func growthWeeks(asOf: Date) -> GuardrailRegrowth {
        guard state.painStop == nil, !state.planSnapshot.sessions.isEmpty || !state.planSnapshot.earlier.isEmpty else { return .none }
        let g = context.guardrails
        let rise = g.regrowthMaxWeeklyRise.isFinite && g.regrowthMaxWeeklyRise >= 0 ? g.regrowthMaxWeeklyRise : PlanHeuristics.regrowthMaxWeeklyRise
        let atPlan = limits.regrowthAtPlanShare.isFinite ? min(1, max(0, limits.regrowthAtPlanShare)) : 0.98
        let steps = g.regrowthReturnSteps
        let current = weekOf(asOf)
        let today = calendar.startOfDay(for: asOf)
        let lastWeek = weekOf(([asOf] + plan.map(\.date)).max() ?? asOf)
        let maxOff = recoveryLimits.rampDaysOff.upperBound
        let freezes = state.freezeIntervals(at: asOf)
        func frozen(_ w: Date) -> Bool { freezes.contains { $0.start < shift(w, weeks: 1) && $0.end > w } }

        // The return after a pain stop: every week from its first full week
        // is in the regrowth; the weeks before count as cut weeks.
        var forced: Date?
        var weekRise: Double? = rise
        // After a stop of more than 14 days: the weeks from the stop's week
        // through the end of the return count at the pre-stop level in the
        // rolling check (3.5 rule 7, 0.8, #93): the level and the last week.
        var atLevel: (level: Double, from: Date, through: Date)?
        var out = GuardrailRegrowth()
        if let r = state.painRecovery.painReturn {
            guard let off = r.daysOff, off >= 0 else { return .none }
            // Nothing run since for more than 14 days: a longer break (rule 4).
            let lastRun = history.filter { $0.kind != .rest && ($0.volume(.time) ?? 1) > 0 }.map(\.date).max()
            guard let lastRun, days(from: calendar.startOfDay(for: lastRun), to: today) - 1 <= maxOff else { return .none }
            let startWeek = weekOf(r.start)
            let first = calendar.startOfDay(for: r.start) == startWeek ? startWeek : shift(startWeek, weeks: 1)
            let stopWeek = min(r.planWeeks.map(\.week).min() ?? startWeek, startWeek)
            var w = stopWeek
            while w < first {
                if let o = originalVolume(w), o > 0 { out.cutWeeks.append(.init(weekStart: w, original: o)) }
                w = shift(w, weeks: 1)
            }
            forced = first
            // After more than 14 days off, the return's own ceilings and the
            // spike rule bound the weeks back, not a weekly rise (#107).
            if off > maxOff {
                weekRise = nil
                if let level = r.level, level > 0, level.isFinite {
                    atLevel = (level, stopWeek, max(first, r.planVolumeWeek(timeZone: tz, limits: recoveryLimits)))
                }
            }
        }

        let firstWeek = min(forced ?? .distantFuture,
                            ([state.planSnapshot.sessions.map { weekOf($0.date) }.min(), state.planSnapshot.earlier.map(\.week).min()]
                                .compactMap { $0 }.min()) ?? current)
        let long = longBreakWeeks(from: firstWeek, before: current)
        var chain = false   // the week being read is in the regrowth
        var step = 0
        var lastDone: (week: Date, ran: Double)?   // the last week read as run
        // After a longer break (rule 4), rules 1 and 2 as written until a
        // week is back at plan: no cut week starts a regrowth (#111 is open).
        var afterLongBreak = false
        var w = firstWeek
        while w <= lastWeek {
            defer { w = shift(w, weeks: 1) }
            if let f = forced, w < f { chain = false; continue }
            if let f = forced, w == f { chain = true; step = 0; afterLongBreak = false }
            if forced == nil, long.contains(w) { chain = false; afterLongBreak = true; continue }
            guard let o = originalVolume(w), o > 0 else { chain = false; continue }
            if chain {
                step += 1
                out.weeks.append(GuardrailRegrowth.Week(weekStart: w, step: step, original: o,
                                                        previousOriginal: originalVolume(shift(w, weeks: -1)), maxRise: weekRise,
                                                        atPlanShare: atPlan, returnSteps: steps))
            }
            if w <= current {
                // A week run (the current one with what the plan still holds):
                // a regrowth goes on until a week is back at plan; outside one,
                // a cut week starts one.
                guard let d = done(w, current: current, today: today) else { chain = forced != nil && chain; continue }
                let below = d < atPlan * o - 1e-6
                if chain {
                    // The current week is not over: only what has been run
                    // can put it back at plan (what the plan still holds for
                    // its days to come is a plan, not a week run).
                    let ran = w == current ? (done(w, current: shift(current, weeks: 1), today: today) ?? d) : d
                    chain = ran < atPlan * o - 1e-6
                    if chain, forced == nil, d <= 0, longBreak([w], asOf: asOf, maxDaysOff: maxOff) { chain = false; afterLongBreak = true }
                    // A finished regrowth week run under 1 / (1 + rise) of its
                    // own planned volume (about 83% at 20%) is a new cut week:
                    // the steps start again from the week actually run, so a
                    // week run short late in a regrowth doesn't jump back to
                    // plan. At or above it, the steps go on (owner decision
                    // Nov 21, #107, #109). Its planned volume is what the
                    // engine returned for it at its first event
                    // (`PlanSnapshot.planned`), else the regrowth's bound
                    // over the week before as run.
                    if chain, w < current, let g = out.week(w) {
                        let before = lastDone.flatMap { $0.week == shift(w, weeks: -1) ? $0.ran : nil }
                        let planned = plannedVolume(w) ?? min(g.allowed(previous: before) ?? o, o)
                        if d < planned / (1 + rise) - 1e-6 { step = 0 }
                    }
                } else {
                    step = 0
                    if forced == nil, longBreak([w], asOf: asOf, maxDaysOff: maxOff) { afterLongBreak = true }
                    if !below { afterLongBreak = false }
                    chain = !afterLongBreak && cut(w, ran: d, original: o, rise: rise, atPlan: atPlan, current: current, today: today)
                }
                if chain, below { out.cutWeeks.append(.init(weekStart: w, original: o)) }
                lastDone = (w, d)
            } else if frozen(w) {
                // A week a pain freeze holds starts a regrowth or keeps it going.
                if !chain { out.cutWeeks.append(.init(weekStart: w, original: o)); step = 0 }
                chain = true
            }
            // Ahead, a regrowth stays on to the end of the plan: a week at plan
            // has the plan as its bound, and the plain 10% check never takes
            // over below plan.
        }
        // The stop's weeks and the return's, up to the week at plan volume,
        // count at the pre-stop level, not the original plan (3.5 rule 7).
        // The snapshot keeps them for the windows that still hold them.
        if let a = atLevel {
            var w = a.from
            while w <= a.through {
                out.cutWeeks.removeAll { $0.weekStart == w }
                out.cutWeeks.append(.init(weekStart: w, original: a.level))
                w = shift(w, weeks: 1)
            }
        }
        // Cut weeks read before, still in the snapshot's window: the rolling
        // check keeps counting them at the original plan.
        for c in state.planSnapshot.cut where c.week < current && out.cutOriginal(c.week) == nil {
            out.cutWeeks.append(.init(weekStart: c.week, original: c.volume))
        }
        return out
    }

    /// What was run in week `w` (outside races, guardrail measure), plus what
    /// the plan still holds for its days to come in the current week; nil for
    /// a week to come, or when a session's volume is unknown.
    func done(_ w: Date, current: Date, today: Date) -> Double? {
        guard w <= current else { return nil }
        let measure = context.guardrails.measure
        var total = 0.0
        for h in history where weekOf(h.date) == w && h.kind != .race {
            guard let v = h.volume(measure), v.isFinite else { return nil }
            total += v
        }
        if w == current {
            for s in plan where weekOf(s.date) == w && s.date >= today && s.kind != .race {
                guard let v = s.volume(measure), v.isFinite else { return nil }
                total += v
            }
        }
        return total
    }

    /// The finished weeks from `from` up to `before` that rule 4's weekly
    /// reading puts in a longer break (`GuardrailChecker.breaks`: more than
    /// `maxShortBreakWeeks` break weeks in a row, each at most
    /// `breakWeekMaxRatio` of the pre-break level). A longer break is not a
    /// cut week: rules 1 and 2 as written hold there (SPEC 3.5 rules 4 and 6).
    func longBreakWeeks(from: Date, before: Date) -> Set<Date> {
        let g = context.guardrails
        let start = shift(from, weeks: -(max(0, g.preBreakWeeks) + max(0, g.maxShortBreakWeeks) + 1))
        var weeks: [Date] = []
        var w = start
        while w < before { weeks.append(w); w = shift(w, weeks: 1) }
        guard !weeks.isEmpty else { return [] }
        let index = Dictionary(uniqueKeysWithValues: weeks.enumerated().map { ($0.element, $0.offset) })
        let measure = g.measure
        var volumes: [Double?] = Array(repeating: 0, count: weeks.count)
        var races: Set<Int> = []
        for h in history {
            guard let i = index[weekOf(h.date)] else { continue }
            if h.kind == .race { races.insert(i); continue }
            guard h.kind != .rest else { continue }
            if let v = h.volume(measure), v.isFinite, let old = volumes[i] { volumes[i] = old + v } else { volumes[i] = nil }
        }
        let lows = volumes.map { $0 ?? 0 }
        let breaks = GuardrailChecker.breaks(volumes: volumes, lows: lows, raceWeeks: races, limits: g)
        return Set(breaks.filter { !$0.isShort(g) }.flatMap { b in (b.first..<b.end).map { weeks[$0] } })
    }

    /// True when week `w`, run at `ran`, is a cut week (3.5 rule 6, owner
    /// decision Nov 21, #107): going straight back to the original plan the
    /// week after would rise more than `rise` over `ran` (or, when `w` was
    /// run at plan, more than the original plan itself rises there), or
    /// break the spike rule (3.5 rule 1) against the runs up to then.
    func cut(_ w: Date, ran: Double, original: Double, rise: Double, atPlan: Double, current: Date, today: Date) -> Bool {
        let next = shift(w, weeks: 1)
        guard let o = originalVolume(next), o > 0 else { return false }
        let straight = GuardrailRegrowth.Week(weekStart: next, step: 1, original: o, previousOriginal: original, maxRise: rise,
                                              atPlanShare: atPlan, returnSteps: [])
        if let allowed = straight.allowed(previous: ran), o > allowed + 1e-6 { return true }
        // The spike rule over the original week after, as if run.
        let sessions = state.planSnapshot.sessions.filter { weekOf($0.date) == next && $0.kind != .race && $0.kind != .rest }
        guard !sessions.isEmpty else { return false }
        var runs = history.filter { $0.date < next }
        if w == current { runs += plan.filter { weekOf($0.date) == w && $0.date >= today } }
        let spikes = GuardrailChecker.checkSingleRunSpikes(history: runs, planned: sessions, checked: next..<shift(next, weeks: 1),
                                                          timeZone: tz, limits: context.guardrails, units: context.units)
        return !spikes.violations.isEmpty
    }

    /// True when the cut weeks `span` held more than `maxDaysOff` days in a
    /// row without running (from the last run before them, or their first
    /// day, to the first run after them, or today): rule 4's longer break.
    func longBreak(_ span: [Date], asOf: Date, maxDaysOff: Int) -> Bool {
        guard let first = span.min(), let last = span.max() else { return false }
        let today = calendar.startOfDay(for: asOf)
        let runs = Set(history.filter { $0.kind != .rest && ($0.volume(.time) ?? 1) > 0 }.map { calendar.startOfDay(for: $0.date) })
            .sorted()
        let end = shift(last, weeks: 1)
        var prev = runs.last { $0 < first } ?? addDays(-1, to: first)
        var longest = 0
        for r in runs where r >= first && r < end {
            longest = max(longest, days(from: prev, to: r) - 1)
            prev = r
        }
        let after = runs.first { $0 >= end } ?? today
        longest = max(longest, days(from: prev, to: min(after, max(today, prev))) - 1)
        return longest > maxDaysOff
    }

    // MARK: Growing back

    /// The plan grown back toward the snapshot where the rules now allow
    /// more (see the file comment), with one `sessionRegrown` change per week
    /// grown, or nil when nothing grows. `base` is the repaired plan's report.
    func growBack(asOf: Date, regrowth: GuardrailRegrowth, base: GuardrailReport)
        -> (plan: [PlannedWorkout], changes: [PlanChange], report: GuardrailReport)? {
        guard state.painStop == nil, !regrowth.weeks.isEmpty, !state.planSnapshot.sessions.isEmpty else { return nil }
        let measure = context.guardrails.measure
        let step = measure == .time ? 60.0 : 100.0
        // The weeks worth a trial: below the most the regrowth and every hold
        // in force (the return's ceilings included) let them hold, by more
        // than a minute (100 m), and outside any freeze. A week already there
        // can't grow, so the rules are not run again for it.
        let freezes = state.freezeIntervals(at: asOf)
        let holds = state.holds + returnHolds()
        // A week's bound depends on the week before, which may grow too, so
        // the week before is read at the most it may reach.
        func volumeNow(_ w: Date) -> Double {
            (history + plan).filter { weekOf($0.date) == w && $0.kind != .race }.reduce(0) { $0 + ($1.volume(measure) ?? .infinity) }
        }
        var candidates: Set<Date> = []
        var reach: [Date: Double] = [:]
        for g in regrowth.weeks.sorted(by: { $0.weekStart < $1.weekStart }) where shift(g.weekStart, weeks: 1) > asOf {
            let end = shift(g.weekStart, weeks: 1)
            let now = volumeNow(g.weekStart)
            let prevWeek = shift(g.weekStart, weeks: -1)
            let previous = max(volumeNow(prevWeek), reach[prevWeek] ?? 0)
            var cap = g.allowed(previous: previous.isFinite ? previous : nil) ?? g.original
            for h in holds where h.interval.start < end && h.interval.end > g.weekStart { cap = min(cap, h.level) }
            guard !freezes.contains(where: { $0.start < end && $0.end > g.weekStart }) else { continue }
            if now.isFinite, now < cap - step {
                candidates.insert(g.weekStart)
                reach[g.weekStart] = cap
            }
        }
        guard !candidates.isEmpty else { return nil }
        func growing(_ d: Date) -> Bool { d >= asOf && candidates.contains(weekOf(d)) }
        let testID = state.painRecovery.test?.workoutID
        var original: [String: PlannedWorkout] = [:]
        for s in state.planSnapshot.sessions { original[s.id] = s }
        let done = Set(state.assessments.compactMap(\.plannedWorkoutID))
        func asEasy(_ o: PlannedWorkout, date: Date) -> PlannedWorkout {
            var s = o.kind.isQuality
                ? o.swappedToEasyKeepingTarget(reason: "growing back toward the plan after a cut week, volume before intensity (SPEC 3.5 rule 6).")
                : o
            s.date = date
            return s
        }

        var trial = self
        trial.changes = []
        var touched = false
        for i in trial.plan.indices where growing(trial.plan[i].date) && trial.plan[i].id != testID {
            let w = trial.plan[i]
            guard let o = original[w.id], o.kind != .race, o.kind != .rest, let ov = o.volume(measure), ov.isFinite,
                  o.durationSeconds.isFinite, o.durationSeconds > 0 else { continue }
            switch w.kind {
            case .rest:
                trial.plan[i] = asEasy(o, date: w.date)
            case .easy, .recovery, .long:
                guard let v = w.volume(measure), v < ov - 1e-6 else { continue }
                // A long-run day the engine made an easy run comes back as
                // the long run, so the long-run share (3.5 rule 5) reads it:
                // repair then cuts it to the share, or makes it an easy run
                // no longer than the floor or what the share leaves (#122).
                trial.plan[i] = w.kind == o.kind || o.kind == .long ? asEasy(o, date: w.date) : w.resized(toSeconds: o.durationSeconds)
            default:
                continue
            }
            touched = true
        }
        let inPlan = Set(trial.plan.map(\.id))
        var busy = Set((history + trial.plan).filter { $0.kind != .rest }.map { calendar.startOfDay(for: $0.date) })
        for o in state.planSnapshot.sessions where growing(o.date) && !inPlan.contains(o.id) && !done.contains(o.id)
            && o.kind != .race && o.kind != .rest && (o.volume(measure) ?? 0) > 0 {
            let d = calendar.startOfDay(for: o.date)
            guard !busy.contains(d) else { continue }
            busy.insert(d)
            trial.plan.append(asEasy(o, date: o.date))
            touched = true
        }
        guard touched else { return nil }
        trial.plan.sort { $0.date < $1.date }

        // The same rules over the grown plan; their changes are not posted.
        trial.reEnforcePain(asOf: asOf)
        trial.enforceReturn(asOf: asOf)
        trial.longRunGate(asOf: asOf)
        _ = trial.enforceHolds(asOf: asOf)
        let repaired = trial.repairKeepingTestRun(asOf: asOf, regrowth: regrowth)
        let grownPlan = repaired.plan.sorted { $0.date < $1.date }

        // Take the weeks that hold more and keep every quality session.
        func inWeek(_ sessions: [PlannedWorkout], _ w: Date) -> [PlannedWorkout] { sessions.filter { weekOf($0.date) == w } }
        func volume(_ sessions: [PlannedWorkout]) -> Double? {
            var t = 0.0
            for s in sessions where s.kind != .race {
                guard let v = s.volume(measure) else { return nil }
                t += v
            }
            return t
        }
        let weeks = Set((plan + grownPlan).filter { growing($0.date) }.map { weekOf($0.date) }).sorted()
        var grown: [Date] = []
        for w in weeks {
            let b = inWeek(plan, w), g = inWeek(grownPlan, w)
            guard let bv = volume(b), let gv = volume(g), gv >= bv + step else { continue }
            let lostQuality = b.contains { s in s.kind.isQuality && !g.contains { $0.id == s.id && $0.kind == s.kind } }
            guard !lostQuality else { continue }
            grown.append(w)
        }
        guard !grown.isEmpty else { return nil }
        let grownSet = Set(grown)
        let mixed = (plan.filter { !grownSet.contains(weekOf($0.date)) } + grownPlan.filter { grownSet.contains(weekOf($0.date)) })
            .sorted { $0.date < $1.date }

        // The mixed plan must break nothing the repaired plan kept.
        let report = GuardrailChecker.check(history: history, planned: mixed, timeZone: tz, limits: context.guardrails,
                                            freezes: state.freezeIntervals(at: asOf), units: context.units, regrowth: regrowth)
        let before = Set(base.violations.map(GuardrailRepair.key))
        guard report.violations.count <= base.violations.count,
              report.violations.allSatisfy({ before.contains(GuardrailRepair.key($0)) }) else { return nil }
        var check = self
        check.plan = plan
        check.changes = []
        let baseHeld = check.enforceHolds(asOf: asOf, cutting: false)
        check.plan = mixed
        check.changes = []
        if baseHeld, !check.enforceHolds(asOf: asOf, cutting: false) { return nil }
        check.changes = []
        check.reEnforcePain(asOf: asOf)
        check.enforceReturn(asOf: asOf)
        check.longRunGate(asOf: asOf)
        guard check.changes.isEmpty else { return nil }

        var changes: [PlanChange] = []
        for w in grown {
            let b = inWeek(plan, w), g = inWeek(mixed, w)
            let ids = g.filter { s in
                guard s.kind != .rest, s.kind != .race else { return false }
                guard let old = b.first(where: { $0.id == s.id }) else { return true }
                return old.kind == .rest || (s.volume(measure) ?? 0) > (old.volume(measure) ?? 0) + 1e-6
            }.map(\.id)
            guard let bv = volume(b), let gv = volume(g) else { continue }
            let o = originalVolume(w)
            let fmt = { (v: Double) in PlanFormatting.volume(v, measure, units: context.units) }
            let g6 = regrowth.week(w)
            let riseText = g6.flatMap { g in
                g.maxRise.map { " Each week of growing back holds the higher of \(PlanFormatting.percent($0)) more than the week before and its return step, this week \(PlanFormatting.percent(g.stepShare)) of the original plan." }
            } ?? ""
            let stepText = g6.map { " This is week \($0.step) of growing back after a cut week.\(riseText)" } ?? ""
            let planText = o.map { " toward the \(fmt($0)) planned" } ?? ""
            changes.append(PlanChange(
                kind: .sessionRegrown, workoutIDs: ids,
                triggers: [TriggerMetric(metric: .weeklyVolume, value: gv, expectedLow: bv, expectedHigh: o,
                                         unit: measure == .time ? .seconds : .meters,
                                         detail: "the week of \(day(w)) grows from \(fmt(bv)) to \(fmt(gv))\(planText)")],
                rule: Self.regrowthRule,
                explanation: "The week of \(day(w)) grows back from \(fmt(bv)) to \(fmt(gv))\(planText), never above the plan.\(stepText) Sessions come back as easy running, and the load guardrails still apply, so a long run is no more than 10% longer than your longest run of the last 30 days. (Heuristic, SPEC 3.5 rule 6, owner decision Nov 21, #107.)"))
        }
        return (mixed, changes, report)
    }
}
