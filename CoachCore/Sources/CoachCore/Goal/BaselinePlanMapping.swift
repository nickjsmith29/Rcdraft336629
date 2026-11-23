import Foundation

/// Maps the F1 baseline report and the F2 goal settings into the plan
/// builder's input (F3). Every baseline value comes from the runner's own
/// runs; a value the baseline can't support stays nil and the builder treats
/// it as unknown (or refuses, for the ones it needs). Nothing is defaulted.
public enum BaselinePlanMapping {
    /// The merged plan-builder input.
    ///
    /// - `recentWeeklySeconds`: `weeklyLoad.currentWeeklyMovingSeconds`.
    /// - `recentLongRunSeconds`: `longRuns.typicalMovingSeconds` (the median
    ///   weekly long run of the basis weeks).
    /// - `heartRateZones`: the LTHR zones (nil on a cold start: the builder
    ///   then asks for a field test, SPEC 2, 3.2).
    /// - `easyPace`: the easy pace at the easy heart rate.
    /// - `fitnessAnchor`: `fitnessAnchor(from:raceDistanceMeters:)`.
    /// - `predictedRaceSeconds`: `predictedRaceSeconds(from:raceDistanceMeters:)`.
    public static func planInput(settings: GoalSettings, baseline: BaselineReport, startDate: Date) -> PlanInput {
        let meters = settings.race.distanceMeters
        return PlanInput(
            raceDistanceMeters: meters,
            raceDate: settings.race.date,
            goalSeconds: settings.race.time.seconds,
            startDate: startDate,
            trainingDays: settings.schedule.trainingDays,
            longRunDay: settings.schedule.longRunDay,
            maxSessionSeconds: settings.schedule.maxSession.seconds,
            recentWeeklySeconds: baseline.weeklyLoad.value?.currentWeeklyMovingSeconds,
            recentLongRunSeconds: baseline.longRuns.value?.typicalMovingSeconds,
            heartRateZones: baseline.lthr.value?.zones,
            easyPace: baseline.easyPace.value.map {
                EasyPaceSample(secondsPerKm: $0.secondsPerKilometer, heartRate: $0.heartRate)
            },
            fitnessAnchor: fitnessAnchor(from: baseline, raceDistanceMeters: meters),
            predictedRaceSeconds: predictedRaceSeconds(from: baseline, raceDistanceMeters: meters))
    }

    /// The baseline's runs as plan history for the builder and the guardrail
    /// checker, with the same moving time the weekly load uses
    /// (`BaselineRun.movingSeconds`, from `MovingTime`), so the recent volume
    /// and the history agree. Kinds: a run marked as a race is `.race`; a
    /// marked time trial is a threshold session; each week's longest run
    /// (`LongRunHistory`) is `.long`; the rest are `.easy`.
    ///
    /// A week with a single run therefore has that run as `.long`: it is that
    /// week's longest run, and `LongRunHistory` (the source of the label) lists
    /// every week that had a run, however short. This is deliberate and
    /// acceptable. The history's `.long` kind is read in three places:
    /// - the checker's long-run-share and easy-run-length rules, which look
    ///   only at weeks holding planned sessions (the current, partly run week
    ///   on a mid-week start, where the label is the same one a multi-run
    ///   week's longest run gets);
    /// - the pain-stop recovery's pre-stop long run, which takes the longest
    ///   run in the window before the stop, so the label changes nothing there;
    /// - indirectly, the pain-stop recovery's `.easy`-based readers
    ///   (`usualEasySeconds(before:)`, which sets the 3.5 rule 7 test-run
    ///   length, and `usualEasySpeed()`), which only read `.easy` runs. A
    ///   one-run week's run labelled `.long` is therefore left out of those
    ///   easy medians; if every recent week has a single run, no easy run is
    ///   left and the test run falls back to `testDefaultSeconds` (and the
    ///   usual speed to nil). That is acceptable: the fallback is the rule's
    ///   own safe default, a lone run is the runner's long run by the
    ///   week's-longest definition, and it keeps a long run out of a median
    ///   meant to describe easy runs.
    ///
    /// Completed weeks before the plan are not checked for the first two
    /// readers, and no volume or weekly-increase rule reads the kind.
    ///
    /// A run with no usable time (`BaselineRun.movingTimeIsKnown` false, or a
    /// moving time that isn't a finite non-negative number) is kept with an
    /// unknown duration (NaN), exactly as `PlannedWorkout(activity:kind:)`
    /// keeps it, rather than left out or counted as 0: either of those would
    /// let its week read low and pass as a recovery week (3.5, #40).
    public static func planHistory(from baseline: BaselineReport) -> [PlannedWorkout] {
        let longIDs = Set(baseline.longRuns.value?.weekly.map(\.activityID) ?? [])
        return baseline.runs.map { run in
            let known = run.movingTimeIsKnown && run.movingSeconds.isFinite && run.movingSeconds >= 0
            let kind: PlannedWorkout.Kind
            switch run.markedEffort {
            case .race?: kind = .race
            case .timeTrialLast20Min?: kind = .quality(.threshold)
            case nil: kind = longIDs.contains(run.activityID) ? .long : .easy
            }
            return PlannedWorkout(id: run.activityID, date: run.start, kind: kind,
                                  durationSeconds: known ? run.movingSeconds : .nan, distanceMeters: run.distanceMeters)
        }
    }

    /// The effort that anchors threshold and VO2max paces (SPEC 3.9): a recent
    /// marked race when there is one, else a recent best effort, at a distance
    /// from 3 km to the half marathon and a plausible speed.
    ///
    /// Heuristic: races beat best-effort stretches of training runs, which are
    /// rarely all-out; among the candidates, the one closest to the goal
    /// distance (in log distance, since Riegel errors grow with the ratio) is
    /// used, and a tie goes to the most recent. Races count when they are
    /// within `GoalHeuristics.anchorLookbackDays` of the baseline.
    ///
    /// A race's time is its elapsed duration (`Activity.durationSeconds`),
    /// which is how races are timed; moving time drops pauses (a stop at an aid
    /// station, say) and would make the anchor too fast. Heuristic fallback:
    /// when the elapsed duration is missing, not finite or shorter than the
    /// moving time, the moving time is used (`raceSeconds`). A watch left
    /// running after the finish makes the elapsed time, and so the anchor,
    /// slower, which errs on the safe side.
    public static func fitnessAnchor(from baseline: BaselineReport, raceDistanceMeters: Double) -> RaceEquivalent? {
        guard raceDistanceMeters.isFinite, raceDistanceMeters > 0 else { return nil }
        let candidates = anchorCandidates(baseline)
        let races = candidates.filter(\.isRace)
        let pool = races.isEmpty ? candidates : races
        let target = log(raceDistanceMeters)
        let best = pool.min { a, b in
            let da = abs(log(a.effort.distanceMeters) - target), db = abs(log(b.effort.distanceMeters) - target)
            if abs(da - db) > 1e-12 { return da < db }
            return a.effort.date > b.effort.date
        }
        return best.map { RaceEquivalent(distanceMeters: $0.effort.distanceMeters, seconds: $0.effort.seconds) }
    }

    /// The current-fitness prediction for the goal distance: the central value
    /// of `BlendedPredictor.predict` from the recent best efforts and marked
    /// races (SPEC 3.9), with the weekly distance for the marathon model when
    /// every basis-week run had one. Nil when no method can run.
    public static func predictedRaceSeconds(from baseline: BaselineReport, raceDistanceMeters: Double) -> Double? {
        guard raceDistanceMeters.isFinite, raceDistanceMeters > 0 else { return nil }
        var efforts = baseline.bestEfforts.value?.recent.map(\.bestEffort) ?? []
        efforts += markedRaces(baseline).map(\.effort)
        guard !efforts.isEmpty else { return nil }
        var weeklyMeters: Double?
        if let load = baseline.weeklyLoad.value, load.distanceIsComplete, load.currentWeeklyDistanceMeters > 0 {
            weeklyMeters = load.currentWeeklyDistanceMeters
        }
        let prediction = BlendedPredictor.predict(targetMeters: raceDistanceMeters, efforts: efforts,
                                                  asOf: baseline.asOf, typicalWeeklyMeters: weeklyMeters)
        guard let central = prediction.range?.central, central.isFinite, central > 0 else { return nil }
        return central
    }

    struct Candidate {
        let effort: BestEffort
        let isRace: Bool
    }

    static func markedRaces(_ baseline: BaselineReport) -> [Candidate] {
        let since = baseline.asOf.addingTimeInterval(-Double(GoalHeuristics.anchorLookbackDays) * 86_400)
        let elapsed = Dictionary(baseline.history.activities.map { ($0.id, $0.durationSeconds) },
                                 uniquingKeysWith: { a, _ in a })
        return baseline.runs.compactMap { run in
            guard run.markedEffort == .race, !run.isTreadmill, run.start >= since, run.start <= baseline.asOf,
                  let d = run.distanceMeters, let t = raceSeconds(run, elapsed: elapsed[run.activityID]) else { return nil }
            return Candidate(effort: BestEffort(distanceMeters: d, seconds: t, date: run.start), isRace: true)
        }
    }

    /// The race's elapsed time, or its moving time when the elapsed time is
    /// unusable (see `fitnessAnchor`). Nil when neither is a positive number.
    static func raceSeconds(_ run: BaselineRun, elapsed: Double?) -> Double? {
        let moving = run.movingSeconds
        if let e = elapsed, e.isFinite, e > 0, !(moving.isFinite && e < moving) { return e }
        return moving.isFinite && moving > 0 ? moving : nil
    }

    static func anchorCandidates(_ baseline: BaselineReport) -> [Candidate] {
        let recent = (baseline.bestEfforts.value?.recent ?? []).map { Candidate(effort: $0.bestEffort, isRace: false) }
        return (markedRaces(baseline) + recent).filter { c in
            let e = c.effort
            return e.distanceMeters.isFinite && e.seconds.isFinite && e.seconds > 0
                && BlendedPredictor.riegelEffortMeters.contains(e.distanceMeters)
                && BlendedPredictor.plausibleSpeed.contains(e.distanceMeters / e.seconds)
        }
    }
}
