import Foundation

/// Whether an activity is a treadmill run, and the evidence for it (SPEC.md 3.8, F1).
public struct TreadmillTag: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// The source explicitly marked it as a treadmill activity.
        case sourceTreadmillFlag
        /// The source explicitly said it is not a treadmill activity.
        case sourceSaysNotTreadmill
        /// Indoor flag set, no GPS route and no altitude stream.
        case indoorWithoutLocation
        /// Indoor flag set but a route or altitude was recorded (for example an
        /// indoor track); not tagged, because the evidence conflicts.
        case indoorWithLocation
        /// No treadmill or indoor flag from the source.
        case noIndoorFlag
    }

    public let isTreadmill: Bool
    public let reason: Reason
}

/// Tags treadmill runs so they get their own handling (SPEC.md 3.8, section 2).
///
/// Heuristic, in order:
/// 1. The source's own treadmill flag (`sourceSaysTreadmill`) decides when present,
///    in either direction, and wins over any route, altitude or indoor evidence: a
///    run the source calls a treadmill run is tagged even with a GPS route or an
///    altitude stream, and one it says is not a treadmill run is never tagged.
/// 2. Otherwise an activity is a treadmill run when the source flags it indoor
///    (`isIndoor == true`), it has no GPS route (`hasRoute != true`) and no altitude
///    stream. Indoor with a route or altitude is left untagged as conflicting.
/// 3. Without any indoor flag the activity is not tagged. Missing GPS alone is not
///    enough: an outdoor run on a device without GPS, or with GPS off, looks the same.
///
/// Known limitation: a watch with a barometric altimeter can record an altitude
/// stream indoors. A treadmill run that carries only the indoor flag (no treadmill
/// flag) and such an altitude stream is then left untagged as `indoorWithLocation`.
/// Missing a treadmill tag is preferred to tagging an indoor-track or outdoor run.
public enum TreadmillTagger {
    public static func tag(_ activity: Activity) -> TreadmillTag {
        if let flag = activity.sourceSaysTreadmill {
            return TreadmillTag(isTreadmill: flag, reason: flag ? .sourceTreadmillFlag : .sourceSaysNotTreadmill)
        }
        guard activity.isIndoor == true else {
            return TreadmillTag(isTreadmill: false, reason: .noIndoorFlag)
        }
        let hasLocation = activity.hasRoute == true || activity.presentStreams.contains(.altitude)
        return hasLocation
            ? TreadmillTag(isTreadmill: false, reason: .indoorWithLocation)
            : TreadmillTag(isTreadmill: true, reason: .indoorWithoutLocation)
    }
}
