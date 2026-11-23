import Foundation

/// Upper bounds for whole-number limits (#147). These are **input-sanity
/// bounds, not training rules**: each is far beyond any value a plan could
/// mean, and is there so a mistyped or corrupted tunable (`Int.max`, say)
/// can't overflow date or week arithmetic, run a loop of that many steps,
/// or (for a count, #173) silently switch a protective rule off by never
/// being reached. A limit above its bound is stored as its default, the way a
/// negative limit is (#142); every default and every value up to the bound
/// is kept as it is. Nothing here comes from SPEC.md 3.5, F4, F9 or section
/// 8, and nothing here stands for a particular runner.
///
/// The day and week bounds were 3,650 and 520 in #147. At those, a hold of
/// 3,650 days or a break lookback of 520 weeks made one engine call cost
/// seconds more than at the default (#158), so they are now about two years:
/// about 17 times the largest day default (the 42-day power history), about
/// 10 times the largest week default (10 weeks), and far beyond any plan.
enum LimitBounds {
    /// A limit counted in days: two years.
    static let days = 730
    /// A limit counted in weeks: two years.
    static let weeks = 104
    /// A margin added to a 0 to 10 pain score: ten times the whole scale, so
    /// any margin above 10 still never fires, and a score plus the margin
    /// can't overflow.
    static let painScoreMargin = 100
    /// A limit counted in distinct events, such as the pain triggers
    /// (#173): 100, a loose sanity ceiling about 16 times the six triggers
    /// that exist (`PainStopTrigger`). It is not the point where a count
    /// becomes unreachable: any count above the number of triggers already
    /// can't be reached, and values up to the bound are kept, as for the
    /// other bounds. Nothing is computed from it; it is a sanity bound, not a
    /// training rule.
    static let counts = 100
}
