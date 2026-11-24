import Foundation

/// How one frozen week is held in an edit made during a pain freeze (SPEC 3.5
/// rule 7, #72). The week keeps the sessions it holds under the freeze, with
/// the same ids, days, lengths and intensity. Only three things change it,
/// and each only lowers load:
///
/// - **New days or longest session.** A session on a day the runner no longer
///   trains moves to the nearest free training day; one longer than the new
///   longest session is cut to it (every segment in proportion, so the hard
///   share is the same); when the edit changed the long-run day the long run
///   moves to it. A session that finds no free day takes the day of the
///   shortest easy run (which is then dropped), or is dropped itself when the
///   week holds nothing else to give way. A quality session is never put next
///   to another quality session or the race (F4); one that can't be placed
///   apart becomes an easy run of the same length. The week never gets a new
///   or harder session type, and never more volume than it held.
/// - **A race inside the week.** The race stays on the day set (F2); sessions
///   on or after that day are dropped, and the other runs shrink by the race
///   so the week still adds up to its frozen volume, the race counted in it
///   (3.5 rule 3: the freeze counts the race). The race counts as a quality
///   session when the limits say so, so the latest quality session turns
///   easy while the week holds too many.
/// - **The week before.** A frozen week never holds more than the week before
///   it (the freeze rule of 3.5 rule 7), so when the edit left that week
///   smaller than the frozen volume, the sessions are cut in proportion to fit.
/// - **Long-run share.** A week laid out again keeps the long run within the
///   limits' share of the week (`maxLongRunShare`, also at marathon distance:
///   the conservative reading), cutting the long run, never adding to the rest.
///
/// A week that needs none of this is returned as it is.
enum FreezeLayout {
    struct Context {
        let input: PlanInput
        let limits: GuardrailLimits
        let timeZone: TimeZone
        /// The edit changed the long-run day (`FreezeHold.longRunDayChanged`).
        let moveLongRun: Bool
        /// The race, when the edit places it inside this week.
        let race: PlannedWorkout?
        /// The week before's volume, which a frozen week may not pass (the
        /// checker's freeze rule). Nil when it is unknown or empty. It binds
        /// only when the edit lowered the week before, say by dropping its
        /// sessions on days the runner no longer trains.
        let ceiling: Double?
        /// Day offsets outside the week (-1: the Sunday before, 7: the Monday after) that hold a quality session.
        var hardOutside: Set<Int> = []
    }

    struct Outcome {
        let workouts: [PlannedWorkout]
        /// Laid out again for new days or a new longest session.
        let relaid: Bool
    }

    static func lay(held: [PlannedWorkout], weekStart: Date, _ ctx: Context) -> Outcome {
        let cal = PlanCalendar.calendar(timeZone: ctx.timeZone)
        func idx(_ date: Date) -> Int {
            cal.dateComponents([.day], from: weekStart, to: cal.startOfDay(for: date)).day ?? 0
        }
        func seconds(_ w: PlannedWorkout) -> Double { w.durationSeconds.isFinite ? max(0, w.durationSeconds) : 0 }

        let trainingDays = Set(ctx.input.trainingDays.map(\.rawValue))
        let cap = ctx.input.maxSessionSeconds ?? .infinity
        let longDay = ctx.input.longRunDay.rawValue
        let raceIdx = ctx.race.map { idx($0.date) }
        // The held week without its race (the new race, if any, is placed by the caller).
        let all = held.filter { $0.kind != .race }.sorted { $0.date < $1.date }
        let sessions = all.filter { $0.kind != .rest }
        let frozenVolume = sessions.reduce(0.0) { $0 + seconds($1) }

        let long = sessions.first { $0.kind == .long }
        let longMismatch = ctx.moveLongRun && long.map { idx($0.date) != longDay } == true
        let overCeiling = ctx.ceiling.map { frozenVolume > $0 + 0.5 } ?? false
        let needsLayout = sessions.contains { !trainingDays.contains(idx($0.date)) || seconds($0) > cap + 0.5 }
            || longMismatch || overCeiling
        if !needsLayout && raceIdx == nil { return Outcome(workouts: all, relaid: false) }

        // Free days: the runner's days, and only the days before a race in the week.
        var slots = trainingDays
        if let r = raceIdx { slots = slots.filter { $0 < r } }
        var placed: [Int: PlannedWorkout] = [:]
        var queue: [PlannedWorkout] = []
        for w in sessions {
            let i = idx(w.date)
            if let r = raceIdx, i >= r { continue }
            let staysOnItsDay = slots.contains(i) && placed[i] == nil
                && !(ctx.moveLongRun && w.kind == .long && i != longDay)
            if staysOnItsDay { placed[i] = w } else { queue.append(w) }
        }
        func rank(_ w: PlannedWorkout) -> Int {
            switch w.kind {
            case .long: return 0
            case .quality: return 1
            default: return 2
            }
        }
        queue.sort { rank($0) != rank($1) ? rank($0) < rank($1) : seconds($0) > seconds($1) }

        func nearest(_ days: [Int], to origin: Int) -> Int? {
            days.min { abs($0 - origin) != abs($1 - origin) ? abs($0 - origin) < abs($1 - origin) : $0 < $1 }
        }
        func apart(_ day: Int) -> Bool {
            ![day - 1, day + 1].contains { $0 == raceIdx || placed[$0]?.kind.isQuality == true || ctx.hardOutside.contains($0) }
        }
        func shifted(_ w: PlannedWorkout, to day: Int) -> PlannedWorkout {
            var moved = w
            let by = day - idx(w.date)
            moved.date = by == 0 ? w.date : (cal.date(byAdding: .day, value: by, to: w.date) ?? w.date.addingTimeInterval(Double(by) * 86_400))
            return moved
        }

        var next = 0
        while next < queue.count {
            var w = queue[next]
            next += 1
            let origin = idx(w.date)
            var free = slots.filter { placed[$0] == nil }.sorted()
            var target: Int?
            if ctx.moveLongRun, w.kind == .long, slots.contains(longDay) {
                if let occupant = placed[longDay], occupant.id != w.id {
                    placed[longDay] = nil
                    queue.append(occupant)
                    free.append(longDay)
                }
                target = longDay
            } else if w.kind.isQuality {
                target = nearest(free.filter(apart), to: origin)
                if target == nil, let any = nearest(free, to: origin) {
                    // No free day apart from the other hard days: the same length, easy.
                    w = w.swappedToEasyKeepingTarget(reason: "it can't go on your new days without a hard day next to it, and your pain freeze holds this week (SPEC 3.5 rule 7).")
                    target = any
                }
            } else {
                target = nearest(free, to: origin)
            }
            if target == nil, w.kind == .long || w.kind.isQuality {
                // Give way: the shortest easy run's day (that run is dropped); a quality session only on a day
                // apart from the other hard days (F4), else it turns easy at the same length and gives way.
                func victim(apartOnly: Bool) -> Int? {
                    placed.filter { ($0.value.kind == .easy || $0.value.kind == .recovery) && (!apartOnly || apart($0.key)) }
                        .min { seconds($0.value) != seconds($1.value) ? seconds($0.value) < seconds($1.value) : $0.key < $1.key }?.key
                }
                var day = victim(apartOnly: w.kind.isQuality)
                if day == nil, w.kind.isQuality {
                    w = w.swappedToEasyKeepingTarget(reason: "it can't go on your new days without a hard day next to it, and your pain freeze holds this week (SPEC 3.5 rule 7).")
                    day = victim(apartOnly: false)
                }
                if let d = day { placed[d] = nil; target = d }
            }
            if let t = target { placed[t] = shifted(w, to: t) }
        }

        var list = placed.values.sorted { $0.date < $1.date }

        // A longest session: every segment in proportion, so the hard share is the same.
        list = list.map { seconds($0) > cap + 0.5 ? scaled($0, to: cap, why: "your longest session is now shorter") : $0 }

        // The week's frozen volume holds the race (3.5 rule 3).
        let limit = min(frozenVolume, ctx.ceiling ?? .infinity)
        let budget = ctx.race.map { max(0, limit - seconds($0)) } ?? limit
        list = shrink(list, to: budget)

        // A week laid out again keeps the long run's share (3.5 rule 5), and no easy or recovery run is longer
        // than the week's long run (F3, 3.5 rule 5, #54): the long run is cut to its share, the easy runs cut to
        // the long run, the cut time dropped (never shared out), until both hold. Each pass only shortens.
        let share = ctx.limits.maxLongRunShare
        if let l = list.firstIndex(where: { $0.kind == .long }) {
            for _ in 0..<50 {
                var changed = false
                let total = list.reduce(0.0) { $0 + seconds($1) }
                let rest = total - seconds(list[l])
                if share > 0, share < 1, rest > 0, seconds(list[l]) > share * total * (1 + 1e-9) {
                    list[l] = scaled(list[l], to: share * rest / (1 - share) * (1 - 1e-9), why: "the long run stays within its share of the week")
                    changed = true
                }
                let longSeconds = seconds(list[l])
                for i in list.indices where (list[i].kind == .easy || list[i].kind == .recovery) && seconds(list[i]) > longSeconds {
                    list[i] = scaled(list[i], to: longSeconds, why: "an easy run stays within the long run")
                    changed = true
                }
                if !changed { break }
            }
        }

        // The race counts as a quality session when the limits say so (3.5 rule 3).
        if ctx.race != nil, ctx.limits.racesCountAsQuality {
            while list.filter({ $0.kind.isQuality }).count + 1 > ctx.limits.maxQualitySessionsPerWeek,
                  let last = list.lastIndex(where: { $0.kind.isQuality }) {
                list[last] = list[last].swappedToEasyKeepingTarget(reason: "your race is in this week and your pain freeze holds it (SPEC 3.5 rule 7).")
            }
        }
        return Outcome(workouts: list.sorted { $0.date < $1.date }, relaid: needsLayout)
    }

    /// The sessions cut in proportion until they add up to at most `budget`,
    /// dropping the lowest-value session (the shortest easy run, then the
    /// shortest quality session, then the long run) while the rest would
    /// fall under the easy-run floor (`PlanHeuristics.minimumEasyRunSeconds`).
    static func shrink(_ sessions: [PlannedWorkout], to budget: Double) -> [PlannedWorkout] {
        func seconds(_ w: PlannedWorkout) -> Double { w.durationSeconds.isFinite ? max(0, w.durationSeconds) : 0 }
        func value(_ w: PlannedWorkout) -> Int { w.kind == .long ? 2 : (w.kind.isQuality ? 1 : 0) }
        var list = sessions
        while true {
            let total = list.reduce(0.0) { $0 + seconds($1) }
            if total <= budget + 0.5 { return list }
            if list.isEmpty || budget < PlanHeuristics.minimumEasyRunSeconds { return [] }
            let factor = budget / total
            if list.count > 1, list.contains(where: { seconds($0) * factor < PlanHeuristics.minimumEasyRunSeconds }),
               let drop = list.indices.min(by: { value(list[$0]) != value(list[$1]) ? value(list[$0]) < value(list[$1])
                                                : seconds(list[$0]) < seconds(list[$1]) }) {
                list.remove(at: drop)
                continue
            }
            return list.map { scaled($0, to: seconds($0) * factor, why: "your race is in this week and your pain freeze holds its volume") }
        }
    }

    /// `w` cut to `target` seconds, every segment in proportion (never longer than it was).
    static func scaled(_ w: PlannedWorkout, to target: Double, why: String) -> PlannedWorkout {
        guard w.durationSeconds.isFinite, w.durationSeconds > 0, target.isFinite, target < w.durationSeconds else { return w }
        let factor = target / w.durationSeconds
        var out = w
        out.durationSeconds = target
        out.distanceMeters = w.distanceMeters.map { $0 * factor }
        if let p = w.prescription {
            let segments = p.segments.map {
                WorkoutSegment(role: $0.role, intensity: $0.intensity, durationSeconds: $0.durationSeconds * factor, target: $0.target)
            }
            out.prescription = WorkoutPrescription(
                purpose: p.purpose + " Shortened to hold your pain freeze: \(why) (SPEC 3.5 rule 7).",
                phase: p.phase, segments: segments, rules: p.rules,
                raceDistanceMeters: p.raceDistanceMeters, returnPaceFactor: p.returnPaceFactor)
        }
        return out
    }
}
