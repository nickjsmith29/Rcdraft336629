import Foundation

/// Tuning for `SessionRunner`. **Every number is a heuristic** (SPEC.md F11
/// gives no values for countdowns, splits or summaries); none stands for a
/// particular runner.
public struct SessionRunnerConfig: Equatable, Sendable {
    /// Seconds of segment time left at which a `work` or `jog` segment is
    /// counted down. Heuristic: 30 s lets a runner finish the rep's
    /// last stretch on purpose, 10 s is "start the kick or get ready".
    public var countdownSeconds: [Double] = [30, 10]
    /// A countdown point is used only if at least this many seconds of the
    /// segment have passed when it is due. Heuristic: leaves time to hear the
    /// segment's start announcement ("rep 3 of 6, target ...") before a countdown
    /// follows it, so a 35 s rep gets only the 10 s point and a 15 s one gets none.
    public var minimumElapsedBeforeCountdownSeconds: Double = 10
    /// A countdown is dropped, not spoken, if it would come this many seconds
    /// after its point (it would say "10 seconds" with 6 left). Heuristic: about
    /// two readings at the usual rate.
    public var countdownLateSeconds: Double = 3
    /// Minimum seconds between two spoken announcements (a segment start or the
    /// workout's end ignores it). Heuristic: long enough for a short phrase
    /// ("30 seconds to go") to be said and heard before the next one.
    public var minimumGapSeconds: Double = 5
    /// A pace or heart-rate cue held back by the gap or by a higher-priority
    /// announcement is dropped after this many seconds. Heuristic: the deviation
    /// it reports lasted at least 25 s, so a few more seconds do not make it
    /// false, but a cue 10 s old may.
    public var cueMaxDeferSeconds: Double = 10
    /// A `main` or `finish` segment gets a summary at its end only if the
    /// runner spent at least this many moving seconds in it. Heuristic: 10 min
    /// is long enough to have a pace and a heart-rate trend worth saying.
    public var minimumSummarySegmentSeconds: Double = 600
    /// A rep counts as done when it ran at least this share of its planned
    /// time (a runner who skips with a few seconds left did the rep). Heuristic.
    public var completeFraction: Double = 0.9
    /// A rep's grade-adjusted pace may be this far (as a fraction) outside the
    /// pace band and still count as in it. Heuristic: the estimator's lap
    /// accuracy criterion is 5 s/mile (F11), about 1% of an 8:50 mile.
    public var inBandToleranceFraction: Double = 0.01
    /// A split's pace, distance, grade-adjusted pace and heart rate are nil
    /// unless at least this share of the (post-lag, for heart rate) time had
    /// the needed data. Heuristic.
    public var minimumCoverageFraction: Double = 0.5
    /// Largest reading gap, seconds, whose time still counts as covered by the
    /// estimate it follows (the same cap `CueEngine` uses to integrate distance).
    public var maxCreditedGapSeconds: Double = 5
    /// While the pace estimate says the runner is stopped (twice in a row), segment
    /// time stops, as if paused. Heuristic: a red light inside a rep should not
    /// shorten it. A watch that reports its own auto-pause should call
    /// `SessionRunner.pause(at:)` instead; the estimate lags a stop by a few seconds.
    public var autoPauseWhenStopped: Bool = true

    public init() {}
}
