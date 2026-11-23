import Foundation

// The app's steps for a provisional plan's rebuild (#55, #77), run in order
// so the app only supplies the stored plan, the baseline and its logging.
// Builds on `ProvisionalRebuild.due` and `resolve`; adds no rule of its own.
extension ProvisionalRebuild {
    /// The plan in use, with what a refused rebuild left for it and a token
    /// that names this state. The app stores the four together: `retryAt` and
    /// `refusalNote` belong to `plan` only.
    ///
    /// `CurrentPlan` is not `Codable` because `GoalPlan` is not yet. Until it
    /// is, the app persists `plan` its own way with `retryAt`, `refusalNote`
    /// and `token` (which is `Codable`), and restores them with
    /// `init(restoring:retryAt:refusalNote:token:)`.
    public struct CurrentPlan: Equatable, Sendable {
        /// Names one state of a `CurrentPlan`. A new one is made whenever the
        /// state changes (`init`, `replace`, `apply`), so `apply` can tell an
        /// attempt's base from the plan in use without comparing plans: a
        /// plan's history keeps runs of unknown moving time as NaN (#40), so
        /// two copies of the same plan need not compare equal.
        public struct Token: Hashable, Codable, Sendable {
            public let id: UUID
            init() { id = UUID() }
        }

        public private(set) var plan: GoalPlan
        /// `Outcome.retryAt` after a refused rebuild of this plan; nil
        /// otherwise. Pass it to `due` (`run` does).
        public private(set) var retryAt: Date?
        /// `Outcome.note` after a refused rebuild of this plan: show it in
        /// place of the plan's own provisional note (the last of
        /// `plan.plan.notes` while the plan is provisional), which names a
        /// rebuild day that has passed. Nil otherwise.
        public private(set) var refusalNote: String?
        /// This state's token: persist it with the rest.
        public private(set) var token: Token

        /// A new plan in use (from the goal interview, a goal edit or any new
        /// plan), with no retry and no note.
        public init(_ plan: GoalPlan) {
            self.plan = plan
            token = Token()
        }

        /// A plan in use restored from storage, with the parts and the token
        /// stored with it, so an attempt that started from it still applies.
        public init(restoring plan: GoalPlan, retryAt: Date?, refusalNote: String?, token: Token) {
            self.plan = plan
            self.retryAt = retryAt
            self.refusalNote = refusalNote
            self.token = token
        }

        /// Any new plan (a goal edit (F2), a new plan, or a rebuild through
        /// `apply`) clears the retry and the note: a stale `retryAt` would
        /// push back the new plan's own rebuild.
        public mutating func replace(with plan: GoalPlan) {
            self = CurrentPlan(plan)
        }

        /// What `apply` did.
        public enum Applied: Equatable, Sendable {
            /// The rebuilt plan replaced the plan in use, with no retry and no
            /// note: replace its watch workouts too (F10).
            case replaced
            /// The rebuild was refused: the plan is kept, and its `retryAt`
            /// (nil once the next try would fall in the race week) and
            /// `refusalNote` are stored.
            case refusalStored
            /// Nothing changed: the attempt started from an earlier state.
            case stale
        }

        /// Applies a rebuild attempt from `run`.
        ///
        /// Does nothing and returns `.stale` when the plan in use is no longer
        /// the state `attempt.base` names (its `token`): the plan was replaced
        /// (a goal edit, a new plan) or another attempt was applied while the
        /// baseline was being built, and the attempt would overwrite it. The
        /// next `run` starts again from the plan now in use.
        @discardableResult
        public mutating func apply(_ attempt: Attempt) -> Applied {
            guard attempt.base.token == token else { return .stale }
            let outcome = attempt.outcome
            if outcome.isRebuilt {
                replace(with: outcome.plan)
                return .replaced
            }
            plan = outcome.plan
            retryAt = outcome.retryAt
            refusalNote = outcome.note
            token = Token()
            return .refusalStored
        }
    }

    /// A rebuild attempt and the plan it started from.
    public struct Attempt: Equatable, Sendable {
        /// The `CurrentPlan` passed to `run`, with its token. `CurrentPlan.apply`
        /// ignores the attempt unless the plan in use still has that token.
        public let base: CurrentPlan
        public let outcome: Outcome<GoalPlan>
    }

    /// Something only a bug or corrupt stored data can cause, for the app to
    /// log. Never shown to the runner.
    public enum Problem: Equatable, Sendable {
        /// `Due.invalidDate`: a stored or current date is not finite. The plan
        /// is kept as it is and nothing is tried.
        case invalidDate
        /// `Outcome.isWiringError`: the rebuild was refused because the
        /// baseline was not built as of `today`. The plan is kept and the
        /// weekly retry set, but the same bug would refuse every retry.
        case wiringError(issues: [GoalPlanIssue])

        /// A fixed English line for a log; holds no runner data.
        public var message: String {
            switch self {
            case .invalidDate:
                return "Provisional rebuild: a stored or current date is not finite; the plan is kept."
            case .wiringError:
                return "Provisional rebuild refused by an app wiring bug: the baseline was not built as of the rebuild day."
            }
        }
    }

    /// The steps the app runs on launch and when it comes to the foreground:
    /// `due`; on `.rebuild(today:)`, the baseline **as of `today`** (not
    /// `now`), `GoalPlanner.plan(today:)` and `resolve`. Pass the result to
    /// `CurrentPlan.apply`.
    /// - Parameters:
    ///   - current: the plan in use, with any stored retry.
    ///   - freezes: pain freezes in force (SPEC 3.5), as for any new plan.
    ///   - limits: guardrail limits, as for any new plan.
    ///   - baseline: builds the F1 baseline (`BaselineBuilder.build`) with
    ///     the options given, which `run` sets as of the rebuild's `today` in
    ///     `timeZone`. Called only when a rebuild is due.
    ///   - log: called for every `Problem`.
    ///   - fail: called for a `.wiringError` only, after `log`; the app passes
    ///     an `assertionFailure` so debug builds stop on it.
    /// - Returns: nil when there is nothing to do now (a final plan, not yet
    ///   due, the race week reached, or `.invalidDate`).
    public static func run(_ current: CurrentPlan,
                           freezes: [DateInterval],
                           limits: GuardrailLimits = .default,
                           now: Date,
                           timeZone: TimeZone,
                           baseline: (BaselineOptions) async -> BaselineReport,
                           log: (Problem) -> Void,
                           fail: (Problem) -> Void) async -> Attempt? {
        switch due(plan: current.plan, retryAt: current.retryAt, now: now, timeZone: timeZone) {
        case .notNeeded, .notYet, .raceWeekReached:
            return nil
        case .invalidDate:
            log(.invalidDate)
            return nil
        case .rebuild(let today):
            let report = await baseline(BaselineOptions(asOf: today, timeZone: timeZone))
            let result = GoalPlanner.plan(settings: current.plan.settings, baseline: report, today: today,
                                          limits: limits, freezes: freezes)
            let outcome = resolve(provisional: current.plan, attempt: result, now: now, timeZone: timeZone)
            if outcome.isWiringError {
                let problem = Problem.wiringError(issues: result.issues.filter(isWiringError))
                log(problem)
                fail(problem)
            }
            return Attempt(base: current, outcome: outcome)
        }
    }
}
