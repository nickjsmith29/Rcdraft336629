import Foundation

// Persistence for the adaptation engine's state (SPEC.md F4, section 7: the
// engine is stateless, so the app stores `AdaptationState` between launches).
//
// `AdaptationState` is `Codable`. The records it holds that live in this
// folder (`VolumeFreeze`, `VolumeHold`, `SignalRecord`, `TriggerMetric`,
// `PlanChange` and so on) are `Codable` themselves. The types it holds from
// elsewhere in CoachCore (`RunAssessment`'s metrics and kind, `PainCheckIn`,
// `PainResponse` and the planned sessions in its swap) are written through the
// private mirrors below, so no public conformance is added to those types.
//
// The encoding is keyed and versioned (`formatVersion`). Fields added later
// decode to their defaults when missing, so older stored states still load;
// a state written by a newer format version is refused rather than misread.
//
// Versions: 1, the first; 2 adds `painReports` and `painStop` (SPEC 3.5
// rule 7). A version 1 state decodes with no reports and no stop. The
// version went up so a build that knows only version 1 refuses a state that
// may hold a pain stop rather than load it and silently drop the stop.
// 3 adds `painRecovery` (usual pain, the stop's end path, the return and the
// clinician flag, SPEC 3.5 rule 7) and the pain report's walking score and
// red flags; a version 1 or 2 state decodes with an empty `PainRecovery`.
// 4 adds `planSnapshot` (the plan as the app handed it in, for the regrowth
// of SPEC 3.5 rule 6, #64); an older state decodes with an empty snapshot,
// and the engine then takes the plan handed in with the next event as the
// original plan (it may already be cut, so regrowth can only reach that).
// Doubles are stored as they are, so a non-finite value (which the engine
// never stores) needs a `JSONEncoder.nonConformingFloatEncodingStrategy`.

extension AdaptationState: Codable {
    /// Version of the stored format. Decoding a higher version throws.
    public static let formatVersion = 4

    enum CodingKeys: String, CodingKey {
        case formatVersion, assessments, qualitySignals, easyHeartRates, longRuns, painCheckIns, appliedPainResponse,
             lastAppliedCheckIn, freezes, holds, qualityPaceFactor, easyPaceFactor, reportedHoldShortfalls,
             painReports, painStop, painRecovery, planSnapshot
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        guard version <= Self.formatVersion else {
            throw DecodingError.dataCorruptedError(forKey: .formatVersion, in: c,
                                                   debugDescription: "AdaptationState format \(version) is newer than \(Self.formatVersion)")
        }
        self.init(
            assessments: try (c.decodeIfPresent([AssessmentCoding].self, forKey: .assessments) ?? []).map { try $0.value() },
            qualitySignals: try c.decodeIfPresent([SignalRecord].self, forKey: .qualitySignals) ?? [],
            easyHeartRates: try c.decodeIfPresent([EasyHeartRateRecord].self, forKey: .easyHeartRates) ?? [],
            longRuns: try c.decodeIfPresent([LongRunRecord].self, forKey: .longRuns) ?? [],
            painCheckIns: (try c.decodeIfPresent([CheckInCoding].self, forKey: .painCheckIns) ?? []).map(\.value),
            appliedPainResponse: try c.decodeIfPresent(PainResponseCoding.self, forKey: .appliedPainResponse)?.value(),
            lastAppliedCheckIn: try c.decodeIfPresent(Date.self, forKey: .lastAppliedCheckIn),
            freezes: try c.decodeIfPresent([VolumeFreeze].self, forKey: .freezes) ?? [],
            holds: try c.decodeIfPresent([VolumeHold].self, forKey: .holds) ?? [],
            qualityPaceFactor: try c.decodeIfPresent(Double.self, forKey: .qualityPaceFactor) ?? 1,
            easyPaceFactor: try c.decodeIfPresent(Double.self, forKey: .easyPaceFactor) ?? 1,
            reportedHoldShortfalls: try c.decodeIfPresent([PlanChange].self, forKey: .reportedHoldShortfalls) ?? [],
            painReports: try c.decodeIfPresent([PainReport].self, forKey: .painReports) ?? [],
            painStop: try c.decodeIfPresent(PainStop.self, forKey: .painStop),
            painRecovery: try c.decodeIfPresent(PainRecovery.self, forKey: .painRecovery) ?? PainRecovery(),
            planSnapshot: try c.decodeIfPresent(PlanSnapshotCoding.self, forKey: .planSnapshot)?.value() ?? PlanSnapshot())
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatVersion, forKey: .formatVersion)
        try c.encode(assessments.map(AssessmentCoding.init), forKey: .assessments)
        try c.encode(qualitySignals, forKey: .qualitySignals)
        try c.encode(easyHeartRates, forKey: .easyHeartRates)
        try c.encode(longRuns, forKey: .longRuns)
        try c.encode(painCheckIns.map(CheckInCoding.init), forKey: .painCheckIns)
        try c.encodeIfPresent(appliedPainResponse.map(PainResponseCoding.init), forKey: .appliedPainResponse)
        try c.encodeIfPresent(lastAppliedCheckIn, forKey: .lastAppliedCheckIn)
        try c.encode(freezes, forKey: .freezes)
        try c.encode(holds, forKey: .holds)
        try c.encode(qualityPaceFactor, forKey: .qualityPaceFactor)
        try c.encode(easyPaceFactor, forKey: .easyPaceFactor)
        try c.encode(reportedHoldShortfalls, forKey: .reportedHoldShortfalls)
        try c.encode(painReports, forKey: .painReports)
        try c.encodeIfPresent(painStop, forKey: .painStop)
        try c.encode(painRecovery, forKey: .painRecovery)
        try c.encode(PlanSnapshotCoding(planSnapshot), forKey: .planSnapshot)
    }
}

// MARK: - Mirrors of types defined outside Adaptation/

/// The error for a stored value no case matches (an enum raw value or kind name).
private func corrupt(_ description: String) -> DecodingError {
    .dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: description))
}

private func decodeRaw<T: RawRepresentable>(_ raw: T.RawValue, as: T.Type) throws -> T {
    guard let v = T(rawValue: raw) else { throw corrupt("unknown \(T.self) value \(raw)") }
    return v
}

/// `PlannedWorkout.Kind` as one string: "easy", "long", "recovery", "race", "rest" or "quality.<QualityKind>".
enum KindCoding {
    static func encode(_ k: PlannedWorkout.Kind) -> String {
        switch k {
        case .easy: return "easy"
        case .long: return "long"
        case .recovery: return "recovery"
        case .race: return "race"
        case .rest: return "rest"
        case .quality(let q): return "quality.\(q.rawValue)"
        }
    }

    static func decode(_ s: String) throws -> PlannedWorkout.Kind {
        switch s {
        case "easy": return .easy
        case "long": return .long
        case "recovery": return .recovery
        case "race": return .race
        case "rest": return .rest
        default:
            let prefix = "quality."
            guard s.hasPrefix(prefix) else { throw corrupt("unknown session kind \(s)") }
            return .quality(try decodeRaw(String(s.dropFirst(prefix.count)), as: PlannedWorkout.QualityKind.self))
        }
    }
}

struct DecouplingCoding: Codable {
    var basis: String
    var percent: Double
    var classification: String
    var firstHalfEF: Double
    var secondHalfEF: Double
    var movingSeconds: Double
    var analyzedSeconds: Double
    var firstHalfHRCoverage: Double
    var secondHalfHRCoverage: Double
    var speedCoefficientOfVariation: Double?
    var isSteady: Bool?

    init(_ d: DecouplingResult) {
        basis = d.basis == .pace ? "pace" : "power"
        switch d.classification {
        case .good: classification = "good"
        case .moderate: classification = "moderate"
        case .aboveAerobicThreshold: classification = "aboveAerobicThreshold"
        }
        percent = d.percent
        firstHalfEF = d.firstHalfEF
        secondHalfEF = d.secondHalfEF
        movingSeconds = d.movingSeconds
        analyzedSeconds = d.analyzedSeconds
        firstHalfHRCoverage = d.firstHalfHRCoverage
        secondHalfHRCoverage = d.secondHalfHRCoverage
        speedCoefficientOfVariation = d.speedCoefficientOfVariation
        isSteady = d.isSteady
    }

    func value() throws -> DecouplingResult {
        let b: DecouplingBasis
        switch basis {
        case "pace": b = .pace
        case "power": b = .power
        default: throw corrupt("unknown decoupling basis \(basis)")
        }
        let k: DecouplingClass
        switch classification {
        case "good": k = .good
        case "moderate": k = .moderate
        case "aboveAerobicThreshold": k = .aboveAerobicThreshold
        default: throw corrupt("unknown decoupling class \(classification)")
        }
        return DecouplingResult(basis: b, percent: percent, classification: k, firstHalfEF: firstHalfEF,
                                secondHalfEF: secondHalfEF, movingSeconds: movingSeconds, analyzedSeconds: analyzedSeconds,
                                firstHalfHRCoverage: firstHalfHRCoverage, secondHalfHRCoverage: secondHalfHRCoverage,
                                speedCoefficientOfVariation: speedCoefficientOfVariation, isSteady: isSteady)
    }
}

struct MetricsCoding: Codable {
    var activityID: String
    var movingSeconds: Double
    var plannedSeconds: Double?
    var key: StreamMeans?
    var plannedKeySeconds: Double?
    var paceSecondsPerKm: Double?
    var paceNotComparableReason: String?
    var climbMetersPerKm: Double?
    /// Added after format version 4 without a bump: absent in older states (decodes to nil).
    var gradeAdjusted: RecordedGAP?
    var decoupling: DecouplingCoding?
    var powerDecoupling: DecouplingCoding?
    var cadenceFadePercent: Double?
    var rpe: Int?

    init(_ m: RunMetrics) {
        activityID = m.activityID
        movingSeconds = m.movingSeconds
        plannedSeconds = m.plannedSeconds
        key = m.key
        plannedKeySeconds = m.plannedKeySeconds
        paceSecondsPerKm = m.paceSecondsPerKm
        paceNotComparableReason = m.paceNotComparableReason
        climbMetersPerKm = m.climbMetersPerKm
        gradeAdjusted = m.gradeAdjusted
        decoupling = m.decoupling.map(DecouplingCoding.init)
        powerDecoupling = m.powerDecoupling.map(DecouplingCoding.init)
        cadenceFadePercent = m.cadenceFadePercent
        rpe = m.rpe
    }

    func value() throws -> RunMetrics {
        RunMetrics(activityID: activityID, movingSeconds: movingSeconds, plannedSeconds: plannedSeconds, key: key,
                   plannedKeySeconds: plannedKeySeconds, paceSecondsPerKm: paceSecondsPerKm,
                   paceNotComparableReason: paceNotComparableReason, climbMetersPerKm: climbMetersPerKm,
                   gradeAdjusted: gradeAdjusted,
                   decoupling: try decoupling?.value(), powerDecoupling: try powerDecoupling?.value(),
                   cadenceFadePercent: cadenceFadePercent, rpe: rpe)
    }
}

struct AssessmentCoding: Codable {
    var activityID: String
    var plannedWorkoutID: String?
    var kind: String
    var date: Date
    var metrics: MetricsCoding
    var signal: RunSignal?
    var unclassifiedReason: String?
    var triggers: [TriggerMetric]

    init(_ a: RunAssessment) {
        activityID = a.activityID
        plannedWorkoutID = a.plannedWorkoutID
        kind = KindCoding.encode(a.kind)
        date = a.date
        metrics = MetricsCoding(a.metrics)
        signal = a.signal
        unclassifiedReason = a.unclassifiedReason
        triggers = a.triggers
    }

    func value() throws -> RunAssessment {
        RunAssessment(activityID: activityID, plannedWorkoutID: plannedWorkoutID, kind: try KindCoding.decode(kind),
                      date: date, metrics: try metrics.value(), signal: signal, unclassifiedReason: unclassifiedReason,
                      triggers: triggers)
    }
}

struct CheckInCoding: Codable {
    var date: Date
    var score: Int
    init(_ c: PainCheckIn) { date = c.date; score = c.score }
    var value: PainCheckIn { PainCheckIn(date: date, score: score) }
}

struct PainTriggerCoding: Codable {
    /// "scoreAtOrAbove" (with `threshold`) or "rise" (with `previous` and `rise`).
    var type: String
    var threshold: Int?
    var previous: Int?
    var rise: Int?

    init(_ t: PainTrigger) {
        switch t {
        case .scoreAtOrAbove(let threshold): type = "scoreAtOrAbove"; self.threshold = threshold
        case .rise(let previous, let rise): type = "rise"; self.previous = previous; self.rise = rise
        }
    }

    func value() throws -> PainTrigger {
        switch type {
        case "scoreAtOrAbove":
            guard let threshold else { break }
            return .scoreAtOrAbove(threshold: threshold)
        case "rise":
            guard let previous, let rise else { break }
            return .rise(previous: previous, rise: rise)
        default: break
        }
        throw corrupt("invalid pain trigger \(type)")
    }
}

struct PaceTargetCoding: Codable {
    var fastestSecondsPerKm: Double
    var slowestSecondsPerKm: Double
}

struct HeartRateTargetCoding: Codable {
    /// `HRZone` raw values of the range's ends.
    var lowestZone: Int
    var highestZone: Int
    var floorBPM: Double?
    var ceilingBPM: Double?
}

struct TargetCoding: Codable {
    var heartRate: HeartRateTargetCoding
    var pace: PaceTargetCoding?
    var primary: String

    init(_ t: WorkoutTarget) {
        heartRate = HeartRateTargetCoding(lowestZone: t.heartRate.zones.lowerBound.rawValue,
                                          highestZone: t.heartRate.zones.upperBound.rawValue,
                                          floorBPM: t.heartRate.floorBPM, ceilingBPM: t.heartRate.ceilingBPM)
        pace = t.pace.map { PaceTargetCoding(fastestSecondsPerKm: $0.fastestSecondsPerKm, slowestSecondsPerKm: $0.slowestSecondsPerKm) }
        primary = t.primary.rawValue
    }

    func value() throws -> WorkoutTarget {
        let low = try decodeRaw(heartRate.lowestZone, as: HRZone.self)
        let high = try decodeRaw(heartRate.highestZone, as: HRZone.self)
        guard low <= high else { throw corrupt("heart-rate zone range \(low) above \(high)") }
        return WorkoutTarget(heartRate: HeartRateTarget(zones: low...high, floorBPM: heartRate.floorBPM, ceilingBPM: heartRate.ceilingBPM),
                             pace: pace.map { PaceTarget(fastestSecondsPerKm: $0.fastestSecondsPerKm, slowestSecondsPerKm: $0.slowestSecondsPerKm) },
                             primary: try decodeRaw(primary, as: WorkoutTarget.Primary.self))
    }
}

struct SegmentCoding: Codable {
    var role: String
    var intensity: String
    var durationSeconds: Double
    var target: TargetCoding

    init(_ s: WorkoutSegment) {
        role = s.role.rawValue
        intensity = s.intensity.rawValue
        durationSeconds = s.durationSeconds
        target = TargetCoding(s.target)
    }

    func value() throws -> WorkoutSegment {
        WorkoutSegment(role: try decodeRaw(role, as: WorkoutSegment.Role.self),
                       intensity: try decodeRaw(intensity, as: WorkoutIntensity.self),
                       durationSeconds: durationSeconds, target: try target.value())
    }
}

struct PrescriptionCoding: Codable {
    var purpose: String
    var phase: String
    var segments: [SegmentCoding]
    var rules: [String]
    /// Race day only (#89); absent in states stored before it, which decode as nil.
    var raceDistanceMeters: Double?
    /// The return factor applied to the paces (#28); absent in states stored before it.
    var returnPaceFactor: Double?

    init(_ p: WorkoutPrescription) {
        returnPaceFactor = p.returnPaceFactor
        purpose = p.purpose
        phase = p.phase.rawValue
        segments = p.segments.map(SegmentCoding.init)
        rules = p.rules.map(\.rawValue)
        raceDistanceMeters = p.raceDistanceMeters
    }

    func value() throws -> WorkoutPrescription {
        WorkoutPrescription(purpose: purpose, phase: try decodeRaw(phase, as: PlanPhase.self),
                            segments: try segments.map { try $0.value() },
                            rules: try rules.map { try decodeRaw($0, as: PlanRule.self) },
                            raceDistanceMeters: raceDistanceMeters, returnPaceFactor: returnPaceFactor)
    }
}

/// A planned session, through `PlannedWorkout`'s public initializer.
struct WorkoutCoding: Codable {
    var id: String
    var date: Date
    var kind: String
    var durationSeconds: Double
    var distanceMeters: Double?
    var prescription: PrescriptionCoding?

    init(_ w: PlannedWorkout) {
        id = w.id
        date = w.date
        kind = KindCoding.encode(w.kind)
        durationSeconds = w.durationSeconds
        distanceMeters = w.distanceMeters
        prescription = w.prescription.map(PrescriptionCoding.init)
    }

    func value() throws -> PlannedWorkout {
        PlannedWorkout(id: id, date: date, kind: try KindCoding.decode(kind), durationSeconds: durationSeconds,
                       distanceMeters: distanceMeters, prescription: try prescription?.value())
    }
}

/// `PlanSnapshot`, its sessions through `WorkoutCoding`.
struct PlanSnapshotCoding: Codable {
    struct Returned: Codable {
        var id: String
        var date: Date
        var digest: String
    }

    var sessions: [WorkoutCoding]
    var earlier: [PlanWeekVolume]?
    var returned: [Returned]?
    var planned: [PlanWeekVolume]?
    var cut: [PlanWeekVolume]?

    init(_ s: PlanSnapshot) {
        sessions = s.sessions.map(WorkoutCoding.init)
        earlier = s.earlier
        returned = s.returned?.map { Returned(id: $0.id, date: $0.date, digest: $0.digest) }
        planned = s.planned.isEmpty ? nil : s.planned
        cut = s.cut.isEmpty ? nil : s.cut
    }

    func value() throws -> PlanSnapshot {
        PlanSnapshot(sessions: try sessions.map { try $0.value() }, earlier: earlier ?? [],
                     returned: returned?.map { PlanSnapshot.ReturnedSession(id: $0.id, date: $0.date, digest: $0.digest) },
                     planned: planned ?? [], cut: cut ?? [])
    }
}

struct PainResponseCoding: Codable {
    var checkIn: CheckInCoding
    var triggers: [PainTriggerCoding]
    var freezeStart: Date
    var freezeEnd: Date
    var swapOriginal: WorkoutCoding?
    var swapReplacement: WorkoutCoding?
    var suggestClinician: Bool
    var explanation: String

    init(_ r: PainResponse) {
        checkIn = CheckInCoding(r.checkIn)
        triggers = r.triggers.map(PainTriggerCoding.init)
        freezeStart = r.freezeStart
        freezeEnd = r.freezeEnd
        swapOriginal = r.swap.map { WorkoutCoding($0.original) }
        swapReplacement = r.swap.map { WorkoutCoding($0.replacement) }
        suggestClinician = r.suggestClinician
        explanation = r.explanation
    }

    func value() throws -> PainResponse {
        var swap: QualitySwap?
        switch (swapOriginal, swapReplacement) {
        case (nil, nil): swap = nil
        case let (o?, r?): swap = QualitySwap(original: try o.value(), replacement: try r.value())
        default: throw corrupt("a pain swap needs both sessions")
        }
        return PainResponse(checkIn: checkIn.value, triggers: try triggers.map { try $0.value() }, freezeStart: freezeStart,
                            freezeEnd: freezeEnd, swap: swap, suggestClinician: suggestClinician, explanation: explanation)
    }
}
