import Foundation

/// Replays a `SyntheticRun` through a `SessionRunner` and keeps what it said
/// next to the truth (SPEC.md section 7 replay harness; F11).
public struct SessionReplay: Sendable {
    public struct Step: Equatable, Sendable {
        public var reading: LiveReading
        public var truth: SyntheticTruth
        public var announcements: [Announcement]
    }

    public let steps: [Step]
    /// The runner after the last reading.
    public let runner: SessionRunner
    /// Everything spoken, in order.
    public var announcements: [Announcement] { steps.flatMap(\.announcements) }

    /// Replay `run`. `heartRate` gives each reading's heart rate from its
    /// time (nil: the reading's own); `dropAltitude` removes every altitude
    /// (a watch with no barometer).
    public init(run: SyntheticRun, prescription: WorkoutPrescription, config: SessionRunnerConfig = SessionRunnerConfig(),
                engineConfig: CueEngineConfig = CueEngineConfig(), curve: any GradePaceCurve = DefaultGradePaceCurve(),
                heartRate: ((Double) -> Double?)? = nil, dropAltitude: Bool = false) {
        var runner = SessionRunner(prescription: prescription, config: config, engineConfig: engineConfig, curve: curve)
        var steps: [Step] = []
        for (reading, truth) in zip(run.readings, run.truth) {
            var r = reading
            if let hr = heartRate { r.heartRate = hr(r.time) }
            if dropAltitude { r.altitude = nil }
            steps.append(Step(reading: r, truth: truth, announcements: runner.ingest(r)))
        }
        self.steps = steps
        self.runner = runner
    }
}
