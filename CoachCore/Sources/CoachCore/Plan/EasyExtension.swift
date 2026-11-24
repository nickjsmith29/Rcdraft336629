import Foundation

/// A quality session's easy extension: the easy running the plan builder
/// moves to the end of the session's cool-down when an easy run would
/// otherwise be longer than the week's long run (SPEC.md F3, "Keep long
/// workout days", #70). The builder states it in the session's purpose, and
/// this type is the one place that writes and reads that sentence, so the
/// adaptation engine can tell the extension from the planned cool-down
/// (SPEC 3.5 rule 5, #54: only the extension is ever cut, never the warm-up,
/// the hard part or the planned cool-down).
enum EasyExtension {
    private static let opening = " The last "
    private static let closing = " min of the cool-down is easy running, moved here from the easy runs so that none is longer than the long run."

    /// The sentence the plan builder appends to the purpose of a session
    /// with `minutes` of extension.
    static func sentence(minutes: Int) -> String { "\(opening)\(minutes)\(closing)" }

    /// The whole minutes of extension a purpose states, or nil when it
    /// states none.
    static func minutes(inPurpose purpose: String) -> Int? {
        guard let range = purpose.range(of: opening) else { return nil }
        let rest = purpose[range.upperBound...]
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix(closing), let n = Int(digits), n > 0 else { return nil }
        return n
    }

    /// `purpose` with the extension sentence set to `minutes`, or taken out
    /// when `minutes` is 0 or less. A purpose with no such sentence is
    /// returned as it is.
    static func purpose(_ purpose: String, settingMinutes minutes: Int) -> String {
        guard let n = Self.minutes(inPurpose: purpose) else { return purpose }
        return purpose.replacingOccurrences(of: sentence(minutes: n), with: minutes > 0 ? sentence(minutes: minutes) : "")
    }
}

extension PlannedWorkout {
    /// The seconds of easy extension at the end of this quality session's
    /// cool-down (SPEC F3), or 0 when it has none. Read from the purpose the
    /// plan builder wrote, and never more than the session's last cool-down
    /// segment, so a purpose that claims more than the segments hold can't
    /// reach into the hard part.
    var easyExtensionSeconds: Double {
        guard kind.isQuality, let p = prescription, let minutes = EasyExtension.minutes(inPurpose: p.purpose),
              let cool = p.segments.last(where: { $0.role == .coolDown }), cool.durationSeconds.isFinite else { return 0 }
        return max(0, min(Double(minutes) * 60, cool.durationSeconds))
    }

    /// This quality session with its easy extension cut to `seconds` (whole
    /// minutes, at least 0), the cut taken from the end of the last
    /// cool-down segment only, the distance scaled with the duration and the
    /// purpose's sentence set to match (taken out at 0). Unchanged when the
    /// extension is already `seconds` or less.
    func cuttingEasyExtension(toSeconds seconds: Double) -> PlannedWorkout {
        let extra = easyExtensionSeconds
        let target = max(0, PlanBuilder.floorMinute(seconds))
        guard extra > 0, target < extra - 1e-6, let p = prescription,
              let c = p.segments.lastIndex(where: { $0.role == .coolDown }) else { return self }
        let cut = extra - target
        var segments = p.segments
        let cool = segments[c]
        segments[c] = WorkoutSegment(role: cool.role, intensity: cool.intensity,
                                     durationSeconds: cool.durationSeconds - cut, target: cool.target)
        var copy = self
        let old = durationSeconds
        copy.durationSeconds = old - cut
        if let d = distanceMeters, old > 0 { copy.distanceMeters = d * copy.durationSeconds / old }
        copy.prescription = WorkoutPrescription(
            purpose: EasyExtension.purpose(p.purpose, settingMinutes: Int(target / 60)), phase: p.phase, segments: segments,
            rules: p.rules, raceDistanceMeters: p.raceDistanceMeters, returnPaceFactor: p.returnPaceFactor)
        return copy
    }
}
