import Foundation

/// Replays a `SyntheticRun` through a `CueEngine` and scores the cues against
/// the truth (SPEC.md section 7 replay harness; F11's "no more than one false
/// speed-up per hilly mile").
public struct CueReplay: Sendable {
    /// One reading's decision next to the truth.
    public struct Step: Equatable, Sendable {
        public var decision: CueDecision
        public var truth: SyntheticTruth
    }

    public let steps: [Step]
    /// The cues actually spoken (decisions whose action is not `.none`).
    public var cues: [Step] { steps.filter { $0.decision.action != .none } }
    /// True distance covered by the run, in miles.
    public let miles: Double
    private let target: PaceTarget?
    private let curve: any GradePaceCurve

    /// Replay `run` through a new engine that holds `segment`. `heartRate`
    /// gives each reading's heart rate from its time (nil: the reading's own).
    public init(run: SyntheticRun, segment: WorkoutSegment, config: CueEngineConfig = CueEngineConfig(),
                curve: any GradePaceCurve = DefaultGradePaceCurve(), heartRate: ((Double) -> Double?)? = nil) {
        var engine = CueEngine(segment: segment, startTime: 0, config: config, curve: curve)
        var steps: [Step] = []
        for (reading, truth) in zip(run.readings, run.truth) {
            var r = reading
            if let hr = heartRate { r.heartRate = hr(r.time) }
            steps.append(Step(decision: engine.ingest(r), truth: truth))
        }
        self.steps = steps
        self.miles = (run.truth.last?.distance ?? 0) / UnitFormatting.metersPerMile
        self.target = segment.target.pace
        self.curve = curve
    }

    /// True when the runner's true pace at `truth` is inside the grade-adjusted
    /// band (the segment's pace target times the factor for the true grade).
    /// False when the segment has no pace target or the runner is stopped.
    public func trulyInBand(_ truth: SyntheticTruth) -> Bool {
        guard let t = target, truth.speed > 0 else { return false }
        let f = curve.factor(grade: truth.grade)
        let pace = 1000 / truth.speed
        let eps = 1e-6
        return pace >= t.fastestSecondsPerKm * f * (1 - eps) && pace <= t.slowestSecondsPerKm * f * (1 + eps)
    }

    /// Cues of `action` given while the true grade-adjusted pace was inside the band.
    public func falseCues(_ action: CueAction) -> Int {
        steps.filter { $0.decision.action == action && trulyInBand($0.truth) }.count
    }

    /// False cues of `action` per true mile run; 0 for a run with no distance.
    public func falseCuesPerMile(_ action: CueAction) -> Double {
        miles > 0 ? Double(falseCues(action)) / miles : 0
    }
}
