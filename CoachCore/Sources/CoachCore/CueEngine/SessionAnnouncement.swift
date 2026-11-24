import Foundation

/// How a reading's announcement was judged against the segment's target band
/// (SPEC.md F11, "rep splits").
public enum BandVerdict: String, CaseIterable, Equatable, Sendable {
    /// Inside the target band (with the session runner's small tolerance).
    case inBand
    /// Faster than the band. For a heart-rate-primary segment: heart rate at or
    /// above the ceiling (more effort than planned).
    case faster
    /// Slower than the band. For a heart-rate-primary segment: heart rate
    /// below the floor.
    case slower
    /// Not judged: the data the target needs (pace or heart rate) is missing.
    case unknown

    /// "in range", "fast" or "slow"; nil for `.unknown`.
    public var phrase: String? {
        switch self {
        case .inBand: return "in range"
        case .faster: return "fast"
        case .slower: return "slow"
        case .unknown: return nil
        }
    }
}

/// Which measurement a `BandVerdict` was based on.
public enum VerdictBasis: String, Equatable, Sendable {
    /// Grade-adjusted pace against the pace band (3.6).
    case gradeAdjustedPace
    /// Raw pace against the pace band, because no live grade was available
    /// (the same flat fallback the `CueEngine` uses).
    case flatPace
    case heartRate
    /// Nothing to judge by.
    case none
}

/// Which announcement wins when several are due at one reading
/// (`SessionRunner`). Higher raw value is spoken first.
public enum AnnouncementPriority: Int, CaseIterable, Comparable, Equatable, Sendable {
    /// Results (rep split, interval summary): useful, never urgent.
    case info = 1
    /// A "speed up" or "slow down" cue.
    case paceCue = 2
    /// A countdown: only true for a moment, so it beats a pace cue.
    case countdown = 3
    /// "Ease off" (heart rate over the ceiling): the one cue that is about safety.
    case safetyCue = 4
    /// A segment starting or the workout ending: the runner must change what
    /// they are doing, and it bypasses the minimum gap.
    case transition = 5

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// A segment starting (SPEC.md F11: "the start of each rep with its number
/// and the target").
public struct SegmentStart: Equatable, Sendable {
    /// Index in `WorkoutPrescription.segments`.
    public let segmentIndex: Int
    public let role: WorkoutSegment.Role
    public let intensity: WorkoutIntensity
    /// Planned length in seconds.
    public let durationSeconds: Double
    /// For a `work` segment: its number within its block (1-based) and the
    /// block's rep count. Nil for any other role.
    public let repNumber: Int?
    public let repCount: Int?
    public let target: WorkoutTarget
    /// True when the runner pressed skip to start this segment early.
    public let startedBySkip: Bool
}

/// Time left in a `work` or `jog` segment at one of `SessionRunnerConfig.countdownSeconds`.
public struct Countdown: Equatable, Sendable {
    public let segmentIndex: Int
    /// `.work` or `.jog`.
    public let role: WorkoutSegment.Role
    /// The countdown point, seconds of segment time left (for example 30).
    public let secondsLeft: Double
    /// For a `work` segment: the rep that is ending.
    public let repNumber: Int?
    /// For a `jog` before a rep: the rep that is coming next.
    public let nextRepNumber: Int?
    public let repCount: Int?
}

/// One finished (or stopped) rep, computed from the session's own readings
/// and estimates, never from the plan (SPEC.md F11).
public struct RepSplit: Equatable, Sendable {
    public let segmentIndex: Int
    public let role: WorkoutSegment.Role
    /// 1-based number within its block, and the block's rep count.
    public let repNumber: Int
    public let repCount: Int
    /// The plan's length of the segment, seconds.
    public let plannedSeconds: Double
    /// Moving seconds actually spent in the segment (paused time excluded).
    public let durationSeconds: Double
    /// False when the runner skipped or ended the workout before
    /// `SessionRunnerConfig.completeFraction` of the planned time.
    public let isComplete: Bool
    /// Estimated distance over `durationSeconds`, metres; nil when too little
    /// of the segment had a usable pace estimate.
    public let distanceMeters: Double?
    /// Average pace over the covered time, seconds per km; nil when too little
    /// of the segment had a usable pace estimate.
    public let paceSecondsPerKm: Double?
    /// Average grade-adjusted pace (SPEC 3.6: pace divided by the live grade's
    /// factor, flat-equivalent), seconds per km. Nil when pace is nil or too
    /// little of the segment had a live grade (altitude missing).
    public let gradeAdjustedPaceSecondsPerKm: Double?
    /// Average heart rate after the heart-rate lag, bpm; nil when missing.
    public let averageHeartRate: Double?
    public let verdict: BandVerdict
    public let verdictBasis: VerdictBasis
    /// Share of the segment's moving time that had a usable pace estimate (0 to 1).
    public let coveredFraction: Double
    /// Share of that covered time that had a live grade (0 to 1).
    public let gradeCoverage: Double
    /// The target this rep was judged against.
    public let target: WorkoutTarget
}

/// A short structured summary of a block of reps or one long continuous
/// segment (SPEC.md F11). Numbers only; the app words them.
public struct IntervalSummary: Equatable, Sendable {
    /// `.work` for a block of reps; `.main` or `.finish` for a long
    /// continuous segment (counted as one rep).
    public let role: WorkoutSegment.Role
    /// Reps the plan has in the block (1 for a continuous segment).
    public let repsPlanned: Int
    /// Complete reps (`RepSplit.isComplete`).
    public let repsDone: Int
    /// Reps that were started but stopped early (0 or 1).
    public let repsPartial: Int
    /// True when the runner ended the workout before the block or segment was done.
    public let endedEarly: Bool
    /// Mean over the complete reps that have a grade-adjusted pace, seconds
    /// per km; and how many reps that is.
    public let averageGradeAdjustedPaceSecondsPerKm: Double?
    public let repsWithGradeAdjustedPace: Int
    /// Slowest minus fastest of those reps' grade-adjusted paces, seconds per
    /// km; nil with fewer than two such reps.
    public let gradeAdjustedSpreadSecondsPerKm: Double?
    /// The same over raw pace (for runs with no altitude).
    public let averagePaceSecondsPerKm: Double?
    public let paceSpreadSecondsPerKm: Double?
    /// How many complete reps were in band, faster, slower or not judged.
    public let repsInBand: Int
    public let repsFaster: Int
    public let repsSlower: Int
    public let repsUnjudged: Int
    /// Heart-rate drift: the last complete rep's average heart rate minus the
    /// first's (among reps that have one), bpm; for a continuous segment, the
    /// second half's average minus the first half's. Nil when it cannot be
    /// computed (fewer than two reps with heart rate, or heart rate missing).
    public let heartRateDriftBPM: Double?
}

/// The workout ending.
public struct SessionEnd: Equatable, Sendable {
    public enum Reason: String, Equatable, Sendable {
        /// Every segment ran its planned time.
        case completed
        /// The runner ended it (`SessionRunner.end(at:)`), or skipped the last segment.
        case endedEarly
    }
    public let reason: Reason
    /// Total moving seconds of the session.
    public let movingSeconds: Double
}

/// One thing the watch may say. Machine-readable: `content` carries the
/// numbers; `phrase(units:)` is only the short fixed wording (the app may
/// word it better; it never has to).
public struct Announcement: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Equatable, Sendable {
        case cue, segmentStart, countdown, repSplit, intervalSummary, sessionEnd
    }

    public enum Content: Equatable, Sendable {
        /// The `CueEngine`'s pace or heart-rate cue.
        case cue(CueDecision)
        case segmentStart(SegmentStart)
        case countdown(Countdown)
        case repSplit(RepSplit)
        case intervalSummary(IntervalSummary)
        case sessionEnd(SessionEnd)
    }

    /// The reading time (or button-press time) it was spoken at, as the caller gave it.
    public let time: Double
    /// The reading time it first became due; later than `time` is never true,
    /// earlier means it waited behind a higher-priority announcement.
    public let dueTime: Double
    public let content: Content

    public var kind: Kind {
        switch content {
        case .cue: return .cue
        case .segmentStart: return .segmentStart
        case .countdown: return .countdown
        case .repSplit: return .repSplit
        case .intervalSummary: return .intervalSummary
        case .sessionEnd: return .sessionEnd
        }
    }

    public var priority: AnnouncementPriority {
        switch content {
        case .cue(let d): return d.action == .easeOff ? .safetyCue : .paceCue
        case .countdown: return .countdown
        case .segmentStart, .sessionEnd: return .transition
        case .repSplit, .intervalSummary: return .info
        }
    }

    /// Seconds it waited behind others.
    public var waitedSeconds: Double { time - dueTime }

    init(time: Double, dueTime: Double? = nil, content: Content) {
        self.time = time
        self.dueTime = dueTime ?? time
        self.content = content
    }

    func spoken(at time: Double) -> Announcement { Announcement(time: time, dueTime: dueTime, content: content) }

    /// The short fixed phrase, with paces in the runner's units (`UnitFormatting`).
    public func phrase(units: UnitPreference = .metric) -> String {
        switch content {
        case .cue(let d):
            return d.phrase ?? ""
        case .segmentStart(let s):
            return Self.startPhrase(s, units: units)
        case .countdown(let c):
            let n = Int(c.secondsLeft.rounded())
            if c.role == .jog, let next = c.nextRepNumber { return "\(n) seconds, rep \(next) next" }
            return "\(n) seconds to go"
        case .repSplit(let r):
            return Self.splitPhrase(r, units: units)
        case .intervalSummary(let s):
            return Self.summaryPhrase(s, units: units)
        case .sessionEnd(let e):
            return e.reason == .completed ? "Workout complete" : "Workout ended"
        }
    }

    private static func roleWord(_ role: WorkoutSegment.Role) -> String {
        switch role {
        case .warmUp: return "Warm up"
        case .main: return "Main run"
        case .work: return "Rep"
        case .jog: return "Jog"
        case .finish: return "Finish"
        case .coolDown: return "Cool down"
        }
    }

    private static func targetPhrase(_ t: WorkoutTarget, units: UnitPreference) -> String? {
        if t.primary == .pace, let p = t.pace {
            return "target " + UnitFormatting.paceRange(p, units)
        }
        if let c = t.heartRate.ceilingBPM, c.isFinite {
            return "heart rate below \(Int(c.rounded()))"
        }
        return nil
    }

    private static func startPhrase(_ s: SegmentStart, units: UnitPreference) -> String {
        var head = roleWord(s.role)
        if s.role == .work, let n = s.repNumber, let of = s.repCount { head = "Rep \(n) of \(of)" }
        // The jog and warm-up have a target too, but speaking it every time is noise.
        if s.role == .work || s.role == .main || s.role == .finish, let t = targetPhrase(s.target, units: units) {
            return head + ", " + t
        }
        return head
    }

    private static func splitPhrase(_ r: RepSplit, units: UnitPreference) -> String {
        var parts: [String] = []
        if let g = r.gradeAdjustedPaceSecondsPerKm {
            let p = UnitFormatting.pace(g, units)
            if p != "-" { parts.append(p + " adjusted") }
        } else if let p = r.paceSecondsPerKm {
            let s = UnitFormatting.pace(p, units)
            if s != "-" { parts.append(s) }
        }
        if let hr = r.averageHeartRate { parts.append("\(Int(hr.rounded())) bpm") }
        if let v = r.verdict.phrase { parts.append(v) }
        let head = r.isComplete ? "Rep \(r.repNumber)" : "Rep \(r.repNumber) stopped early"
        return parts.isEmpty ? head : head + ": " + parts.joined(separator: ", ")
    }

    private static func summaryPhrase(_ s: IntervalSummary, units: UnitPreference) -> String {
        var parts: [String] = []
        if s.role == .work {
            parts.append(s.endedEarly ? "Ended after \(s.repsDone) of \(s.repsPlanned) reps" : "\(s.repsDone) of \(s.repsPlanned) reps")
        } else {
            parts.append(roleWord(s.role) + (s.endedEarly ? " stopped early" : " done"))
        }
        if let g = s.averageGradeAdjustedPaceSecondsPerKm {
            let p = UnitFormatting.pace(g, units)
            if p != "-" { parts.append("average " + p + " adjusted") }
        } else if let p = s.averagePaceSecondsPerKm {
            let t = UnitFormatting.pace(p, units)
            if t != "-" { parts.append("average " + t) }
        }
        let judged = s.repsInBand + s.repsFaster + s.repsSlower
        if s.role == .work, judged > 0 { parts.append("\(s.repsInBand) in range") }
        if let d = s.heartRateDriftBPM {
            let n = Int(abs(d).rounded())
            parts.append(n == 0 ? "heart rate steady" : "heart rate \(d > 0 ? "up" : "down") \(n) bpm")
        }
        return parts.joined(separator: ", ")
    }
}
