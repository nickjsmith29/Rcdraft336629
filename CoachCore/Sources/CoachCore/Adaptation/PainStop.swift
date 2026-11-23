// TimeZone is not Sendable in swift-corelibs-foundation (Linux, Swift 5.10).
@preconcurrency import Foundation

// The pain stop rule (SPEC.md 3.5 rule 7, section 8). Any runner, with or
// without a pain history, can report pain after any run or the next morning.
// Pain that got worse during the run, changed how the runner moved, the
// next-morning trigger (pain in that spot 2 or more above usual, 4/10 or
// more, or still above usual 48 hours after the run), a red flag, or pain
// above usual on most days for about 7 days stops progression and drops the
// plan to easy-only or rest. How a stop ends, the return after it and the
// clinician flag live in `PainRecovery.swift`. CoachCore never diagnoses: it
// only changes load, and the advice wording is the app's.
//
// Every trigger and figure is a **heuristic**: SPEC 3.5 rule 7 says no study
// in the evidence check tests them. Mild, stable pain alone does not stop
// running (SPEC 3.5 evidence, [15]).

/// One pain report from the runner, after any run or the next morning
/// (SPEC.md 3.5 rule 7). Unlike `PainCheckIn`, any runner can give one, and
/// it is about how the pain behaves rather than only how bad it is.
///
/// The app asks after every run whether anything hurt and, if so, the two
/// after-run questions. It asks the next-morning question on the morning
/// after a run with reported pain, and each morning during a stop and the
/// return after it (with pain on daily walking, `walkingScore`), so a stop
/// can end without the runner volunteering reports (SPEC 3.5 rule 7).
///
/// The question asks about one spot, so general muscle soreness doesn't
/// count. CoachCore tracks one spot: the report carries no area (#92), so
/// every report is read as about the runner's pain spot. Until the owner
/// decides, an app with several interview spots passes the lowest seed.
public struct PainReport: Equatable, Sendable, Codable {
    /// When the report was given.
    public enum Timing: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        /// Straight after a run.
        case afterRun
        /// A morning report: the morning after a run, or any morning during
        /// a stop and the return. `hasPain` true means pain in that spot now.
        case nextMorning
    }

    public var date: Date
    public var timing: Timing
    /// Any pain now. A report that says the pain got worse or changed how
    /// the runner moved, or has a score above 0, counts as pain whatever this says.
    public var hasPain: Bool
    /// The pain got worse during the run (a stop trigger).
    public var worsenedDuringRun: Bool
    /// The pain changed how the runner moved, for example a limp or a
    /// shortened stride (a stop trigger).
    public var changedMovement: Bool
    /// A 0 to 10 score when the report doubles as the pain check-in (3.5
    /// rule 7, `PainCheckInRule`); scores outside 0...10 are ignored. The
    /// check-in rule acts on it only for runners who track pain.
    public var score: Int?
    /// The run the report is about, when there is one.
    public var activityID: String?
    /// Pain on daily walking, 0 to 10, asked each morning during a stop and
    /// the return (SPEC 3.5 rule 7: a stop ends only with walking pain at
    /// 2/10 or less). Scores outside 0...10 are ignored.
    public var walkingScore: Int?
    /// Red flags the runner reported (SPEC 3.5 rule 7, clinician flag): any
    /// one stops running at once and turns the clinician flag on.
    public var redFlags: [PainRedFlag]

    public init(date: Date, timing: Timing, hasPain: Bool, worsenedDuringRun: Bool = false,
                changedMovement: Bool = false, score: Int? = nil, activityID: String? = nil,
                walkingScore: Int? = nil, redFlags: [PainRedFlag] = []) {
        self.date = date
        self.timing = timing
        self.hasPain = hasPain
        self.worsenedDuringRun = worsenedDuringRun
        self.changedMovement = changedMovement
        self.score = score
        self.activityID = activityID
        self.walkingScore = walkingScore
        self.redFlags = redFlags
    }

    /// The score when it is in `PainCheckIn.validScores`, nil otherwise.
    public var validScore: Int? { score.flatMap { PainCheckIn.validScores.contains($0) ? $0 : nil } }

    /// The walking score when it is in `PainCheckIn.validScores`, nil otherwise.
    public var validWalkingScore: Int? { walkingScore.flatMap { PainCheckIn.validScores.contains($0) ? $0 : nil } }

    /// True when the report says there is pain (see `hasPain`).
    public var isPain: Bool {
        hasPain || worsenedDuringRun || changedMovement || !redFlags.isEmpty || (validScore ?? 0) > 0
    }

    /// The pain level to compare with usual pain: the valid score, 0 for a
    /// report of no pain at all, nil for pain of unknown size (pain with no
    /// valid score). Every rule here reads nil as above usual, the stricter
    /// reading (heuristic, SPEC 3.5 rule 7).
    public var painLevel: Int? {
        if let s = validScore { return s }
        return isPain ? nil : 0
    }

    /// True when the pain is above `usual`, or of unknown size (see `painLevel`).
    public func isAbove(usual: Int) -> Bool { painLevel.map { $0 > usual } ?? true }

    /// The stop triggers this report fires for a runner whose usual pain is
    /// 0 with no known run time, in `PainStopTrigger.allCases` order. The
    /// engine uses `stopTriggers(usual:hoursSinceRun:)` with the runner's own
    /// usual pain.
    public var stopTriggers: [PainStopTrigger] { stopTriggers(usual: 0, hoursSinceRun: nil) }

    /// The stop triggers this report fires (SPEC 3.5 rule 7), in
    /// `PainStopTrigger.allCases` order: pain that got worse during the run, a
    /// change in how the runner moved, the next-morning trigger
    /// (`NextMorningRule`) and any red flag. `hoursSinceRun` is the time from
    /// the end of the run the pain followed to this report, nil when unknown.
    public func stopTriggers(usual: Int, hoursSinceRun: Double?,
                             limits: PainRecoveryLimits = .default) -> [PainStopTrigger] {
        var out: [PainStopTrigger] = []
        if worsenedDuringRun { out.append(.worsenedDuringRun) }
        if changedMovement { out.append(.changedMovement) }
        if timing == .nextMorning,
           NextMorningRule.verdict(self, usual: usual, hoursSinceRun: hoursSinceRun, limits: limits) == .stop {
            out.append(.stillThereNextMorning)
        }
        if !redFlags.isEmpty { out.append(.redFlag) }
        return out
    }

    /// False for a report whose date is not a finite time; the engine ignores it.
    public var isValid: Bool { date.timeIntervalSinceReferenceDate.isFinite }
}

extension PainReport {
    enum CodingKeys: String, CodingKey {
        case date, timing, hasPain, worsenedDuringRun, changedMovement, score, activityID, walkingScore, redFlags
    }

    /// Reports stored before `walkingScore` and `redFlags` existed decode
    /// with none.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(date: try c.decode(Date.self, forKey: .date),
                  timing: try c.decode(Timing.self, forKey: .timing),
                  hasPain: try c.decode(Bool.self, forKey: .hasPain),
                  worsenedDuringRun: try c.decodeIfPresent(Bool.self, forKey: .worsenedDuringRun) ?? false,
                  changedMovement: try c.decodeIfPresent(Bool.self, forKey: .changedMovement) ?? false,
                  score: try c.decodeIfPresent(Int.self, forKey: .score),
                  activityID: try c.decodeIfPresent(String.self, forKey: .activityID),
                  walkingScore: try c.decodeIfPresent(Int.self, forKey: .walkingScore),
                  redFlags: try c.decodeIfPresent([PainRedFlag].self, forKey: .redFlags) ?? [])
    }
}

/// A red flag the runner reports (SPEC.md 3.5 rule 7, clinician flag): the
/// app advises seeing a clinician at once, and running stops. Swelling,
/// can't bear weight and numbness or tingling follow [23]; sharp pain and a
/// lasting change in how the runner moves are product heuristics, not from
/// [23]. The app never diagnoses: these only change load and raise the advice.
public enum PainRedFlag: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
    case swelling
    case cannotBearWeight
    case numbnessOrTingling
    case sharpPain
    case lastingMovementChange

    var words: String {
        switch self {
        case .swelling: return "swelling"
        case .cannotBearWeight: return "not being able to bear weight"
        case .numbnessOrTingling: return "numbness or tingling"
        case .sharpPain: return "sharp pain"
        case .lastingMovementChange: return "a lasting change in how you move"
        }
    }
}

/// What made the pain stop rule fire (SPEC.md 3.5 rule 7). Each is a
/// **heuristic** trigger, not a clinical sign.
public enum PainStopTrigger: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
    case worsenedDuringRun
    case changedMovement
    /// The next-morning trigger (`NextMorningRule`): 2 or more above usual,
    /// 4/10 or more, or still above usual 48 hours after the run.
    case stillThereNextMorning
    /// A red flag (`PainRedFlag`).
    case redFlag
    /// Pain above usual on most days for about 7 days (`PainStopRule.lastingPain`).
    case lastingAboveUsual
    /// Symptoms came back twice at the same step of the return.
    case recurredInReturn

    var words: String {
        switch self {
        case .worsenedDuringRun: return "got worse during the run"
        case .changedMovement: return "changed how you moved"
        case .stillThereNextMorning: return "was still above your usual level the next morning"
        case .redFlag: return "came with a red flag"
        case .lastingAboveUsual: return "has been above your usual level on most days for about a week"
        case .recurredInReturn: return "came back twice at the same step of your return"
        }
    }
}

/// What a pain stop leaves of the plan.
public enum PainStopMode: String, CaseIterable, Comparable, Equatable, Hashable, Sendable, Codable {
    /// Every quality session to come becomes an easy run of the same length.
    case easyOnly
    /// Every run to come becomes a rest day.
    case rest

    public static func < (a: PainStopMode, b: PainStopMode) -> Bool { a == .easyOnly && b == .rest }
}

/// Progression stopped by the pain stop rule (SPEC.md 3.5 rule 7), stored
/// in `AdaptationState.painStop`. While it stands, on every event (the
/// engine's no-op events included):
/// - no week from the stop's week on may plan more than `level`, a fixed
///   ceiling at the pre-stop weekly volume, so each week is at most
///   min(its planned volume, `level`). The ceiling never moves down: a
///   recovery week below it does not lower the weeks after it. The engine
///   enforces it like a volume hold (cutting easy runs; see `VolumeHold`),
///   so `AdaptationOutcome.holdsSatisfied` covers it too;
/// - with `.easyOnly`, every quality session in the plan is an easy run of
///   the same length, and a long run longer than the long-run share cap
///   (`GuardrailLimits.maxLongRunShare`) of `level` is shortened to it once,
///   so the held weeks keep their long runs rather than losing a little
///   each week; with `.rest`, every run in the plan is a rest day.
/// Races are left as the runner set them (F2).
///
/// **The hook for ending a stop and the return (#73; rule 6's regrowth,
/// #64; rule 4's ramp, #62).** The engine never ends a stop by itself: the
/// rule says how a stop starts, not when it ends, and #73 owns that. Code
/// that ends it clears `AdaptationState.painStop` and regrows the plan from
/// `since`; the days off since then (no running in the history) decide
/// whether rule 4's ramp applies. A rest-mode stop keeps no copy of the
/// sessions it rested; the engine keeps the plan as the app handed it in
/// (`AdaptationState.planSnapshot`), and the return grows back to it
/// (`PlanRegrowth.swift`), or to a plan the app hands in again.
public struct PainStop: Equatable, Sendable, Codable {
    /// Progression stopped since this date: the first report that fired the rule.
    public let since: Date
    public var mode: PainStopMode
    /// Every trigger seen while the stop stands, in the order first seen.
    public var triggers: [PainStopTrigger]
    /// The latest report that fired a trigger.
    public var lastTriggered: Date
    /// The weekly ceiling while the stop stands, in the guardrail measure
    /// (seconds for time, meters for distance): the higher of the stop
    /// week's volume and the week before's when the stop began. Nil while
    /// neither is known; the engine fills it in on a later event once the
    /// stop week's volume is known.
    public var level: Double?

    public init(since: Date, mode: PainStopMode, triggers: [PainStopTrigger], lastTriggered: Date, level: Double? = nil) {
        self.since = since
        self.mode = mode
        self.triggers = triggers
        self.lastTriggered = lastTriggered
        self.level = level
    }
}

/// Pain reported on most days for about a week (SPEC.md 3.5 rule 7): the app
/// uses it to advise seeing a clinician, in its own words. It names no cause.
public struct LastingPain: Equatable, Sendable {
    /// The first report of pain since the last pain-free report.
    public let since: Date
    /// The latest report of pain.
    public let latest: Date
    /// Calendar days from `since` to `latest` in the runner's time zone.
    public let days: Int
    /// Distinct calendar days with a report of pain in that span (both ends included).
    public let reportDays: Int
}

/// Thresholds for the pain stop rule. **Heuristics** from SPEC.md 3.5 rule 7
/// ("the three stop triggers and the one-week figure are conservative
/// heuristics"), not clinical cut-offs. A whole-number limit below 0, or above
/// its input-sanity bound (`LimitBounds`, #173), is stored as its default
/// instead (see `valid`, #157).
public struct PainStopLimits: Equatable, Sendable {
    /// The clinician flag is raised once pain has been reported on a day at
    /// least this many calendar days after the first report of it ("past about
    /// a week"). Default 7: pain on day 0 and on day 7 has lasted a full week.
    public var clinicianDays: Int { didSet { clinicianDays = Self.valid(clinicianDays, \.clinicianDays) } }
    /// ...and only when more than this share of the calendar days in that
    /// span (both ends included) have a report of pain ("most days"), so a few
    /// scattered reports are not read as lasting pain. Default 0.5. NaN, a
    /// negative value and +/-inf are stored as the default (#163, as #142 does
    /// for `AdaptationLimits`): NaN used to make every comparison false, so
    /// lasting pain was never raised. A finite share of 1 or more is kept: at
    /// most every day can have a report, so it reads as "never" (a share of 1
    /// already cannot be exceeded), as before; 0 means any report-day counts.
    public var clinicianMostDaysShare: Double { didSet { clinicianMostDaysShare = Self.valid(clinicianMostDaysShare, \.clinicianMostDaysShare) } }
    /// A stop drops to rest, not easy-only, once this many different triggers
    /// have been seen while it stands. Pain that changed how the runner moves
    /// always means rest. Default 2.
    public var restTriggerCount: Int { didSet { restTriggerCount = Self.valid(restTriggerCount, \.restTriggerCount) } }

    public init(clinicianDays: Int = 7, clinicianMostDaysShare: Double = 0.5, restTriggerCount: Int = 2) {
        self.clinicianDays = Self.valid(clinicianDays, \.clinicianDays)
        self.clinicianMostDaysShare = Self.valid(clinicianMostDaysShare, \.clinicianMostDaysShare)
        self.restTriggerCount = Self.valid(restTriggerCount, \.restTriggerCount)
    }

    public static let `default` = PainStopLimits()

    /// `value` for the whole-number limit at `field`, as it is stored (#157,
    /// as #142 does for `PainRuleLimits`): below 0, or above its `upperBound`
    /// (#173, as #147 does for the other limits), falls back to the default,
    /// when the limits are built and whenever one is set. Before, a negative
    /// `clinicianDays` read as 1 and raised the clinician flag after two days
    /// of pain, and a negative `restTriggerCount` made every stop a rest stop.
    /// 0 and every value up to the bound are kept: both are read through
    /// `max(1, ...)`, so 0 acts as 1. Neither overflowed at `Int.max` (each is
    /// only compared, and `days + 1` stays small), but a value past the bound
    /// can never fire, so it is more likely a mistyped or corrupted tunable
    /// than a choice; the bound makes it read as the default instead of
    /// silently switching the rule off. The fallback reads `default` only for
    /// a bad value, and both defaults are valid.
    static func valid(_ value: Int, _ field: KeyPath<PainStopLimits, Int>) -> Int {
        value >= 0 && value <= (upperBound(field) ?? .max) ? value : Self.default[keyPath: field]
    }

    /// The input-sanity upper bound of a whole-number limit (#173,
    /// `LimitBounds`; not a training rule): `clinicianDays` 730 days, and
    /// `restTriggerCount` 100, far above the six pain triggers.
    static func upperBound(_ field: KeyPath<PainStopLimits, Int>) -> Int? {
        switch field {
        case \PainStopLimits.clinicianDays: return LimitBounds.days
        case \PainStopLimits.restTriggerCount: return LimitBounds.counts
        default: return nil
        }
    }

    /// `value` for the `Double` limit at `field` (#163): NaN, a negative value
    /// and +/-inf fall back to the default, as `AdaptationLimits` does (#142).
    static func valid(_ value: Double, _ field: KeyPath<PainStopLimits, Double>) -> Double {
        value.isFinite && value >= 0 ? value : Self.default[keyPath: field]
    }
}

/// The pure parts of the pain stop rule (SPEC.md 3.5 rule 7); the
/// adaptation engine (`AdaptationEngine.processPainReport`) applies them.
public enum PainStopRule {
    /// The stop mode for a set of triggers (heuristic): rest when the pain
    /// changed how the runner moves, came with a red flag, or
    /// `restTriggerCount` different triggers fired, easy-only otherwise. Nil
    /// for no triggers.
    public static func mode(for triggers: [PainStopTrigger], limits: PainStopLimits = .default) -> PainStopMode? {
        guard !triggers.isEmpty else { return nil }
        let distinct = Set(triggers)
        return distinct.contains(.changedMovement) || distinct.contains(.redFlag)
            || distinct.count >= max(1, limits.restTriggerCount) ? .rest : .easyOnly
    }

    /// The stop after `report`, given the stop already standing (nil if none),
    /// for a runner whose usual pain is 0 (see `PainReport.stopTriggers`).
    /// A stop only ever starts or gets stricter here: a report without a
    /// trigger leaves it as it is, and nothing here ends it (see `PainStop`).
    public static func stop(after report: PainReport, current: PainStop?, limits: PainStopLimits = .default) -> PainStop? {
        guard report.isValid else { return current }
        return stop(fired: report.stopTriggers, at: report.date, current: current, limits: limits)
    }

    /// The stop after triggers `fired` at `date`, given the stop already
    /// standing (nil if none). It only ever starts a stop or makes one stricter.
    public static func stop(fired: [PainStopTrigger], at date: Date, current: PainStop?,
                            limits: PainStopLimits = .default) -> PainStop? {
        guard date.timeIntervalSinceReferenceDate.isFinite, !fired.isEmpty else { return current }
        guard var s = current else {
            return PainStop(since: date, mode: mode(for: fired, limits: limits) ?? .easyOnly,
                            triggers: fired, lastTriggered: date)
        }
        for t in fired where !s.triggers.contains(t) { s.triggers.append(t) }
        s.mode = max(s.mode, mode(for: s.triggers, limits: limits) ?? .easyOnly)
        s.lastTriggered = max(s.lastTriggered, date)
        if date < s.since {
            s = PainStop(since: date, mode: s.mode, triggers: s.triggers, lastTriggered: s.lastTriggered, level: s.level)
        }
        return s
    }

    /// Pain above usual on most days for about a week, or nil (SPEC 3.5
    /// rule 7: it starts a stop and turns the clinician flag on). Reads every
    /// pain report and pain check-in after `after` (all when nil) up to
    /// `asOf`: a report or check-in above `usual` (or of pain with no valid
    /// score) is pain, one at or below `usual` is pain-free. The latest
    /// pain-free one ends any earlier stretch of pain (one at the same instant
    /// as a report of pain is ignored). Then it is lasting pain when the first
    /// and latest reports of pain since are at least `clinicianDays` calendar
    /// days apart and more than `clinicianMostDaysShare` of the days in
    /// between (both ends) have one. A stretch stays open until a pain-free
    /// report comes, however long ago its latest report was; the clinician
    /// flag's 14-day close (`ClinicianFlag`) is what ends a silent one.
    public static func lastingPain(reports: [PainReport], checkIns: [PainCheckIn], asOf: Date, timeZone: TimeZone,
                                   usual: Int = 0, after: Date? = nil,
                                   limits: PainStopLimits = .default) -> LastingPain? {
        let fromReports = reports.filter(\.isValid).map { (date: $0.date, pain: $0.isAbove(usual: usual)) }
        let fromCheckIns = checkIns.filter { PainCheckIn.validScores.contains($0.score) && $0.date.timeIntervalSinceReferenceDate.isFinite }
            .map { (date: $0.date, pain: $0.score > usual) }
        let upTo = (fromReports + fromCheckIns).filter { e in e.date <= asOf && (after.map { e.date > $0 } ?? true) }
        // At one instant, pain outranks pain-free: the pain-free one is dropped.
        let painInstants = Set(upTo.filter(\.pain).map(\.date))
        let all = upTo.filter { $0.pain || !painInstants.contains($0.date) }.sorted { $0.date < $1.date }
        let start = (all.lastIndex { !$0.pain }).map { $0 + 1 } ?? 0
        let stretch = all[start...]
        guard let first = stretch.first?.date, let latest = stretch.last?.date else { return nil }
        let cal = PlanCalendar.calendar(timeZone: timeZone)
        let firstDay = cal.startOfDay(for: first)
        let days = cal.dateComponents([.day], from: firstDay, to: cal.startOfDay(for: latest)).day ?? 0
        let reportDays = Set(stretch.map { cal.startOfDay(for: $0.date) }).count
        guard days >= max(1, limits.clinicianDays),
              Double(reportDays) / Double(days + 1) > limits.clinicianMostDaysShare else { return nil }
        return LastingPain(since: first, latest: latest, days: days, reportDays: reportDays)
    }
}
