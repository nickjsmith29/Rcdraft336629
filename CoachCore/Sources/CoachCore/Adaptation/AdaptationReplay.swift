import Foundation

/// The replay harness for the adaptation engine (SPEC.md section 7, F4
/// acceptance): feeds recorded-style runs, pain check-ins, pain reports and quiet days
/// through `AdaptationEngine` in time order, carrying state, plan and
/// history from one event to the next. CI replays synthetic fixtures only; a
/// runner's own exports belong in the git-ignored `Fixtures/local/`.
public enum AdaptationReplay {
    public enum Event: Equatable, Sendable {
        case run(CompletedRun)
        case painCheckIn(PainCheckIn)
        /// A pain report after a run or the next morning (3.5 rule 7).
        case painReport(PainReport)
        /// A day passing with nothing logged (the app's morning call).
        case day(Date)

        /// When the event happens: a run at its start (so a run that crosses
        /// midnight is placed on the day of its planned session, before the
        /// next morning's call), the others at their date.
        public var date: Date {
            switch self {
            case .run(let r): return r.activity.start
            case .painCheckIn(let c): return c.date
            case .painReport(let r): return r.date
            case .day(let d): return d
            }
        }
    }

    /// One replayed event and what the engine made of it.
    public struct Step: Equatable, Sendable {
        public let event: Event
        public let outcome: AdaptationOutcome
    }

    /// Replays `events` in time order (events at the same time keep their
    /// input order). With `mornings` (the default), a `.day` step at local
    /// midnight is inserted for each day from the first event's day to the
    /// last, as the app's morning call would run, so a missed session is
    /// rearranged before the next day's run rather than after it.
    public static func replay(_ events: [Event], plan: [PlannedWorkout], history: [PlannedWorkout] = [],
                              state: AdaptationState = AdaptationState(), mornings: Bool = true,
                              context: AdaptationContext) -> [Step] {
        let ordered = events.enumerated()
            .sorted { $0.element.date != $1.element.date ? $0.element.date < $1.element.date : $0.offset < $1.offset }
            .map(\.element)
        let cal = PlanCalendar.calendar(timeZone: context.timeZone)
        var all: [Event] = []
        var nextMorning: Date?
        for e in ordered {
            if mornings {
                let today = cal.startOfDay(for: e.date)
                var m = nextMorning ?? today
                while m <= today {
                    all.append(.day(m))
                    m = cal.date(byAdding: .day, value: 1, to: m) ?? m.addingTimeInterval(86_400)
                }
                nextMorning = m
            }
            all.append(e)
        }
        var state = state, plan = plan, history = history
        var out: [Step] = []
        for e in all {
            let o: AdaptationOutcome
            switch e {
            case .run(let r):
                o = AdaptationEngine.processRun(r, state: state, plan: plan, history: history, context: context)
            case .painCheckIn(let c):
                o = AdaptationEngine.processCheckIn(c, state: state, plan: plan, history: history, context: context)
            case .painReport(let r):
                o = AdaptationEngine.processPainReport(r, state: state, plan: plan, history: history, context: context)
            case .day(let d):
                o = AdaptationEngine.processDay(asOf: d, state: state, plan: plan, history: history, context: context)
            }
            state = o.state; plan = o.plan; history = o.history
            out.append(Step(event: e, outcome: o))
        }
        return out
    }
}
