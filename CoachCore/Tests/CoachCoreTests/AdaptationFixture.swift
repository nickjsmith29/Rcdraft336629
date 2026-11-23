import Foundation
import XCTest
@testable import CoachCore

// Synthetic adaptation fixtures only: the LTHR, paces and runs below are
// invented for the F4 tests and stand for no real runner.
enum AdaptFixture {
    static let tz = PlanFixture.utc
    static let lthr = 165.0
    static let zones = HRZones(lthr: lthr)!
    /// Invented targets: easy 6:00/km, threshold 4:30/km, VO2max 4:10/km, half-marathon pace 4:45/km.
    static let targets = TargetModel(zones: zones, category: .half, easyPace: 360, thresholdPace: 270,
                                     vo2maxPace: 250, racePace: 285)

    static func context(tracksPain: Bool = false, limits: AdaptationLimits = .default) -> AdaptationContext {
        AdaptationContext(zones: zones, timeZone: tz, tracksPain: tracksPain, limits: limits)
    }

    static func date(week: Int, day: Int, hour: Int = 7) -> Date { PlanFixture.date(week: week, day: day, hour: hour) }

    static func segment(_ role: WorkoutSegment.Role, _ intensity: WorkoutIntensity, _ minutes: Double) -> WorkoutSegment {
        WorkoutSegment(role: role, intensity: intensity, durationSeconds: minutes * 60, target: targets.target(intensity))
    }

    static func session(_ id: String, week: Int, day: Int, _ kind: PlannedWorkout.Kind, _ segments: [WorkoutSegment],
                        hour: Int = 7) -> PlannedWorkout {
        let p = WorkoutPrescription(purpose: "synthetic \(id)", phase: .build, segments: segments, rules: [.periodization])
        return PlannedWorkout(id: id, date: date(week: week, day: day, hour: hour), kind: kind,
                              durationSeconds: p.durationSeconds, prescription: p)
    }

    static func easy(_ id: String, week: Int, day: Int, minutes: Double, hour: Int = 7) -> PlannedWorkout {
        session(id, week: week, day: day, .easy, [segment(.main, .easy, minutes)], hour: hour)
    }

    static func long(_ id: String, week: Int, day: Int, minutes: Double) -> PlannedWorkout {
        session(id, week: week, day: day, .long, [segment(.main, .easy, minutes)])
    }

    /// 10 min warm-up, 3 x 10 min threshold with 2 min jogs, 10 min cool-down: 54 min.
    static func threshold(_ id: String, week: Int, day: Int) -> PlannedWorkout {
        session(id, week: week, day: day, .quality(.threshold), [
            segment(.warmUp, .easy, 10),
            segment(.work, .threshold, 10), segment(.jog, .repRecovery, 2),
            segment(.work, .threshold, 10), segment(.jog, .repRecovery, 2),
            segment(.work, .threshold, 10),
            segment(.coolDown, .easy, 10),
        ])
    }

    /// Weeks of Tue threshold (54 min), Thu easy, Sat long, Sun easy.
    static func weeks(_ range: Range<Int>, easyMinutes: (Int) -> (Double, Double) = { _ in (55, 45) },
                      longMinutes: (Int) -> Double = { _ in 60 }) -> [PlannedWorkout] {
        range.flatMap { w -> [PlannedWorkout] in
            let e = easyMinutes(w)
            return [threshold("t\(w)", week: w, day: 1),
                    easy("e\(w)a", week: w, day: 3, minutes: e.0),
                    long("l\(w)", week: w, day: 5, minutes: longMinutes(w)),
                    easy("e\(w)b", week: w, day: 6, minutes: e.1)]
        }
    }

    enum HR { case mid, low, high }

    /// Options for a simulated run of a planned session.
    struct RunSpec {
        var pace = 1.0          // multiplier on the key segments' target pace (below 1 is faster)
        var hr = HR.mid         // where heart rate sits in the key segments' band
        var drift = 0.0         // HR rises by this fraction over the second half
        var cadenceFade = 0.0   // cadence falls linearly by this fraction over the run
        var durationScale = 1.0
        var heartRate = true
        var speed = true
        var climbPerKm = 0.0
        var rpe: Int? = nil
        var isTreadmill = false
        var id: String? = nil
    }

    /// A run that follows `w`'s segments with samples every 5 s.
    static func run(for w: PlannedWorkout, _ spec: RunSpec = RunSpec()) -> CompletedRun {
        let segs = w.prescription?.segments ?? [segment(.main, .easy, w.durationSeconds / 60)]
        let key = w.prescription.flatMap(RunMetrics.keyIntensity) ?? .easy
        let total = segs.reduce(0) { $0 + $1.durationSeconds } * spec.durationScale
        var samples: [StreamSample] = []
        var t = 0.0, dist = 0.0
        var segStart = 0.0
        for s in segs {
            let dur = s.durationSeconds * spec.durationScale
            let isKey = s.intensity == key && RunMetrics.isKeyRole(s.role, intensity: s.intensity)
            let band = s.target.heartRate
            let low = band.floorBPM ?? zones.lowerBound(band.zones.upperBound)
            let high = band.ceilingBPM
            let mid = high.map { (low + $0) / 2 } ?? low + 5
            var hr = mid
            if isKey {
                switch spec.hr {
                case .mid: hr = mid
                case .low: hr = low - 6
                case .high: hr = (high ?? low + 10) + 4
                }
            }
            let speed: Double = s.target.pace.map { p in
                1000 / ((p.fastestSecondsPerKm + p.slowestSecondsPerKm) / 2 * (isKey ? spec.pace : 1))
            } ?? 2.8
            while t < segStart + dur - 1e-9 {
                let half = total / 2
                let driftFactor = 1 + spec.drift * max(0, (t - half) / half)
                let cad = 170 * (1 - spec.cadenceFade * t / total)
                let x = dist / 1000
                let frac = x - x.rounded(.down)
                let alt = 50 + spec.climbPerKm * (frac < 0.5 ? 2 * frac : 2 * (1 - frac))
                samples.append(StreamSample(t: t, heartRate: spec.heartRate ? hr * driftFactor : nil,
                                            speed: spec.speed ? speed : nil, cadence: cad, distance: dist,
                                            altitude: alt))
                t += 5
                dist += speed * 5
            }
            segStart += dur
        }
        samples.append(StreamSample(t: total, heartRate: spec.heartRate ? samples.last?.heartRate : nil,
                                    speed: spec.speed ? samples.last?.speed : nil, cadence: samples.last?.cadence,
                                    distance: dist, altitude: samples.last?.altitude))
        let a = Activity(id: spec.id ?? "run-\(w.id)", source: .healthKit, start: w.date, durationSeconds: total,
                         distanceMeters: dist, samples: samples)
        return CompletedRun(activity: a, plannedWorkoutID: nil, rpe: spec.rpe, isTreadmill: spec.isTreadmill)
    }

    /// Follows the plan in date order through `until`, running each session as
    /// `spec` says (nil skips it, so the engine finds it missed), and calling
    /// `between` before each session for extra events such as check-ins.
    struct Driver {
        var state = AdaptationState()
        var plan: [PlannedWorkout]
        var history: [PlannedWorkout]
        let context: AdaptationContext
        var outcomes: [AdaptationOutcome] = []
        var skipped: Set<String> = []

        init(plan: [PlannedWorkout], history: [PlannedWorkout] = [], context: AdaptationContext) {
            self.plan = plan
            self.history = history
            self.context = context
        }

        /// The next local midnight the morning call has not run for.
        var nextMorning: Date?

        /// The app's morning call for every day up to `date`'s (SPEC section 8 "each morning").
        mutating func mornings(through date: Date) {
            let cal = PlanCalendar.calendar(timeZone: context.timeZone)
            let today = cal.startOfDay(for: date)
            var m = nextMorning ?? today
            while m <= today {
                take(AdaptationEngine.processDay(asOf: m, state: state, plan: plan, history: history, context: context))
                m = cal.date(byAdding: .day, value: 1, to: m)!
            }
            nextMorning = m
        }

        mutating func take(_ o: AdaptationOutcome) {
            state = o.state; plan = o.plan; history = o.history
            outcomes.append(o)
        }

        mutating func follow(until: Date, _ spec: (PlannedWorkout) -> RunSpec?) {
            func key(_ w: PlannedWorkout) -> String { "\(w.id)@\(w.date.timeIntervalSince1970)" }
            while let next = plan.first(where: { $0.date <= until && !skipped.contains(key($0)) && $0.kind != .race }) {
                guard let s = spec(next) else { skipped.insert(key(next)); continue }
                mornings(through: next.date)
                // The morning call may have moved or cut today's session.
                guard let current = plan.first(where: { $0.id == next.id }), current.date == next.date else { continue }
                let run = AdaptFixture.run(for: current, s)
                let seen = history.contains { $0.id == run.activity.id }
                take(AdaptationEngine.processRun(run, state: state, plan: plan, history: history, context: context))
                // The engine keeps a session in the plan after its run only on
                // a rest day: a rest day the runner ran on stays a rest day.
                // Running it again is only a re-sync of a run already seen (a
                // no-op), so after that one re-sync it is skipped and `follow`
                // always ends (#143). Any other session still planned after its
                // run is an engine regression, so it fails the test instead of
                // being skipped quietly (#149).
                if seen {
                    if current.kind != .rest {
                        XCTFail("\(current.id) (\(current.kind)) on \(current.date) is still planned after its run was synced")
                    }
                    skipped.insert(key(current))
                }
            }
        }

        mutating func checkIn(_ score: Int, at date: Date) {
            mornings(through: date)
            take(AdaptationEngine.processCheckIn(PainCheckIn(date: date, score: score), state: state, plan: plan,
                                                 history: history, context: context))
        }

        mutating func day(_ date: Date) {
            mornings(through: date)
            take(AdaptationEngine.processDay(asOf: date, state: state, plan: plan, history: history, context: context))
        }

        var changes: [PlanChange] { outcomes.flatMap(\.changes) }
    }

    static func weekVolume(_ week: Int, _ sessions: [PlannedWorkout]) -> Double {
        let start = PlanCalendar.weekStart(containing: date(week: week, day: 0), timeZone: tz)
        return sessions.filter { PlanCalendar.weekStart(containing: $0.date, timeZone: tz) == start }
            .reduce(0) { $0 + $1.durationSeconds }
    }
}

extension XCTestCase {
    /// Every outcome passes the guardrails (as reported and run independently
    /// with the freezes in force), and every change cites its trigger metrics (F4).
    func assertAdaptationSound(_ outcomes: [AdaptationOutcome], limits: GuardrailLimits = .default,
                               file: StaticString = #filePath, line: UInt = #line) {
        for (i, o) in outcomes.enumerated() {
            XCTAssertTrue(o.guardrailReport.passed, "outcome \(i): \(o.guardrailReport.violations.map(\.explanation))",
                          file: file, line: line)
            let asOf = o.history.map(\.date).max() ?? .distantPast
            let independent = GuardrailChecker.check(history: o.history, planned: o.plan, timeZone: AdaptFixture.tz,
                                                     limits: limits, freezes: o.state.freezeIntervals(at: asOf),
                                                     regrowth: o.regrowth)
            XCTAssertTrue(independent.passed, "outcome \(i)", file: file, line: line)
            // Regrowth never allows more than the original plan (SPEC 3.5 rule 6, #64, #107).
            for g in o.regrowth.weeks {
                XCTAssertLessThanOrEqual(g.allowed(previous: 1e12) ?? 0, g.original + 1e-6, "outcome \(i)", file: file, line: line)
                guard g.weekStart > asOf else { continue }
                let held = (o.history + o.plan).filter {
                    PlanCalendar.weekStart(containing: $0.date, timeZone: AdaptFixture.tz) == g.weekStart && $0.kind != .race
                }.reduce(0) { $0 + ($1.volume(limits.measure) ?? 0) }
                XCTAssertLessThanOrEqual(held, g.original + 1e-6, "outcome \(i): a week to come above the original plan", file: file, line: line)
            }
            for c in o.changes {
                XCTAssertFalse(c.triggers.isEmpty, "\(c.kind) cites no trigger", file: file, line: line)
                XCTAssertTrue(c.triggers.allSatisfy { !$0.detail.isEmpty && $0.value.isFinite }, file: file, line: line)
                XCTAssertFalse(c.explanation.isEmpty, file: file, line: line)
                XCTAssertTrue(c.rule.contains("SPEC"), file: file, line: line)
            }
        }
    }
}
