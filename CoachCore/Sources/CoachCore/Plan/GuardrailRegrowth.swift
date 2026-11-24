import Foundation

/// The weeks of a regrowth after a cut week (SPEC.md 3.5 rule 6, owner
/// decision Nov 21, #107), as `GuardrailChecker.check(regrowth:)` reads them.
/// The checker can't tell a week that was cut from one that was planned low,
/// so the adaptation engine, which keeps the plan as it was handed in
/// (`PlanSnapshot`), works these out and hands them in (`AdaptationOutcome.regrowth`).
///
/// In a regrowth week, rule 2's 10% check is replaced by the regrowth's bound
/// (`Week.allowed(previous:)`): the higher of `GuardrailLimits.regrowthMaxWeeklyRise`
/// (20%) above the week before it as run or planned and the week's return
/// step (`GuardrailLimits.regrowthReturnSteps`: 65%, then 82.5%, then 100% of
/// the original plan's week, counted from the first week after the cut
/// week), and never above the original plan's week. In a week that is also in rule 4's return ramp after
/// a short break, the lower of the ramp cap and that bound applies, since both
/// bounds apply. In the rolling 4-week check, a cut week among the 4 earlier
/// weeks counts at the higher of its volume and its original-plan volume
/// (`cutWeeks`), as a short break counts at the pre-break level (rule 4). The
/// spike rule (rule 1) and every other check are unchanged, so every run,
/// the first long run back included, still has to pass the spike rule.
/// Every figure is a heuristic.
public struct GuardrailRegrowth: Equatable, Sendable {
    /// One week of a regrowth.
    public struct Week: Equatable, Sendable {
        /// Monday 00:00 of the week.
        public let weekStart: Date
        /// 1 for the first week after the cut week, then 2, 3 and so on until
        /// a week is back at the original plan.
        public let step: Int
        /// The week's volume outside races in the original plan, in the guardrail measure.
        public let original: Double
        /// The original plan's volume outside races in the week before, or
        /// nil when unknown. Where the week before holds at least
        /// `atPlanShare` of it (it is at plan) and the original plan itself
        /// rises more than the regrowth's limit into this week (after a
        /// planned recovery week), the week may rise as much as the plan does
        /// (`allowed(previous:)`), so a planned recovery week doesn't hold
        /// back the week after it.
        public let previousOriginal: Double?
        /// The share of its original-plan volume at which a week counts as
        /// at plan (`AdaptationLimits.regrowthAtPlanShare`). Default 0.98.
        public let atPlanShare: Double
        /// Most the week may rise over the week before it, as a fraction;
        /// nil for no weekly bound but the original plan (the return after a
        /// pain stop of more than 14 days, 3.5 rule 7, whose own ceilings and
        /// the spike rule bound it instead: the checker then applies neither
        /// rule 4's ramp nor rule 2's rolling check to the week).
        public let maxRise: Double?
        /// The return steps, as shares of the original plan's week: step `k`
        /// may hold `returnSteps[k-1]` × `original` (the last share from then
        /// on) when that is more than `maxRise` over the week before.
        public let returnSteps: [Double]

        public init(weekStart: Date, step: Int, original: Double, previousOriginal: Double? = nil,
                    maxRise: Double? = PlanHeuristics.regrowthMaxWeeklyRise, atPlanShare: Double = 0.98,
                    returnSteps: [Double] = PlanHeuristics.regrowthReturnSteps) {
            self.weekStart = weekStart
            self.step = step
            self.original = original
            self.previousOriginal = previousOriginal
            self.maxRise = maxRise
            self.atPlanShare = atPlanShare
            self.returnSteps = returnSteps
        }

        /// The week's return step as a share of the original plan's week,
        /// from 0 to 1 (0 for no steps or a step below 1).
        public var stepShare: Double { GuardrailRegrowth.stepShare(step, steps: returnSteps) }

        /// The most the week may hold outside races when the week before it
        /// holds `previous` (as run, or as planned for a week to come): the
        /// higher of `previous` raised by `maxRise` and the week's return step
        /// (`stepShare` × `original`), and never above the original plan's
        /// week. When the week before is at plan (`atPlanShare` of its
        /// original-plan volume) and the original plan itself rises more than
        /// `maxRise` into this week (after a planned recovery week), the week
        /// may rise as much as the plan does.
        /// Nil when `original` is not a finite volume of 0 or more, or when
        /// `previous` is unknown (nil or not finite) under a weekly bound: the
        /// caller falls back to the plain rules. A week before that ran
        /// nothing (or less than nothing) gives no rise to measure from, so
        /// the return step alone bounds the week. Rule 4's return ramp, which
        /// covers a week of little or no running, still applies in the checker.
        public func allowed(previous: Double?) -> Double? {
            guard original.isFinite, original >= 0 else { return nil }
            guard let rise = maxRise else { return original }
            guard let p = previous, p.isFinite else { return nil }
            let level = stepShare * original
            guard p > 0 else { return min(original, level) }
            let r = rise.isFinite ? max(0, rise) : 0
            let share = atPlanShare.isFinite ? min(1, max(0, atPlanShare)) : 1
            let planned = previousOriginal.flatMap { $0.isFinite && $0 > 0 && p >= share * $0 - 1e-9 ? original / $0 : nil } ?? 0
            return min(original, max(max(1 + r, planned) * p, level))
        }
    }

    /// A cut week the regrowth follows, or a week of the regrowth run below
    /// the original plan, with its volume outside races in the original plan.
    public struct CutWeek: Equatable, Sendable {
        public let weekStart: Date
        public let original: Double

        public init(weekStart: Date, original: Double) {
            self.weekStart = weekStart
            self.original = original
        }
    }

    public var weeks: [Week]
    public var cutWeeks: [CutWeek]
    /// The weeks whose easy runs were capped at a cut long run, with their
    /// time before the cap (SPEC 3.5 rule 5, #54). Not part of the regrowth
    /// itself: it travels with it because the engine hands both to the
    /// checker in the same call, and it is empty unless a cap was made.
    public var preCap: GuardrailPreCap

    public init(weeks: [Week] = [], cutWeeks: [CutWeek] = [], preCap: GuardrailPreCap = .none) {
        self.weeks = weeks
        self.cutWeeks = cutWeeks
        self.preCap = preCap
    }

    /// Step `step`'s share of the original plan's week in `steps` (the last
    /// share past the end), clamped to 0...1; 0 for no steps, a step below 1
    /// or a share that is not finite.
    public static func stepShare(_ step: Int, steps: [Double]) -> Double {
        guard step >= 1, let s = steps.isEmpty ? nil : steps[min(step, steps.count) - 1], s.isFinite else { return 0 }
        return min(1, max(0, s))
    }

    /// No regrowth: the plain rules.
    public static let none = GuardrailRegrowth()

    public var isEmpty: Bool { weeks.isEmpty && cutWeeks.isEmpty && preCap.isEmpty }

    /// The regrowth week starting `weekStart`, if any.
    public func week(_ weekStart: Date) -> Week? { weeks.first { $0.weekStart == weekStart } }

    /// The original-plan volume of the cut week starting `weekStart`, if it is one.
    public func cutOriginal(_ weekStart: Date) -> Double? {
        cutWeeks.first { $0.weekStart == weekStart }.map(\.original)
    }
}
