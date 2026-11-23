import Foundation
import XCTest
@testable import CoachCore

// #147: whole-number limits with no upper bound, after #142 (`LimitGuardTests`).
//
// On main, `Int.max` for `GuardrailLimits.preBreakWeeks`, `maxShortBreakWeeks`
// or `spikeWindowDays` crashed the checker and the adaptation engine with an
// integer overflow (or ran a loop of `Int.max` steps), and other whole-number
// limits used in date or week arithmetic did the same (see `sweep`). Each
// such limit now has an input-sanity upper bound, and a value above it is
// stored as its default, the way #145 stores a negative one. Defaults and
// every value up to the bound are unchanged. The bounds are not training
// rules. Synthetic plans, runs and check-ins only; every limit is a heuristic
// (SPEC 3.5, F4, F9, section 8).
//
// A crash can't be caught inside the test process, so every run that crashed
// on main runs in a child process of this test binary (Linux, where CI runs),
// with a time limit: a crash or a hang then fails one test instead of
// killing the whole run.
final class IntLimitBoundTests: XCTestCase {
    typealias F = AdaptFixture
    typealias P = PlanFixture

    // MARK: The fields

    /// One whole-number limit: where it lives, how to set it on a context,
    /// and its bound (nil for a limit that needs none, which is then only
    /// checked to run at `Int.max`).
    struct Field {
        let name: String
        let bound: Int?
        let set: (inout AdaptationContext, Int) -> Void
        let get: (AdaptationContext) -> Int

        /// The scenarios of `exercise` that read the field's struct (all of
        /// them for the guardrails).
        var scenarios: Set<String>? {
            switch String(name.prefix(while: { $0 != "." })) {
            case "painLimits": return ["checkInRule", "painStop", "checkIns"]
            case "limits": return ["painStop", "missedWeek", "checkIns", "thinWeek", "heldGate", "behind"]
            case "painRecoveryLimits", "painStopLimits": return ["painStop", "checkIns", "nextMorning", "flag"]
            default: return nil
            }
        }
    }

    private static func g(_ name: String, _ path: WritableKeyPath<GuardrailLimits, Int>) -> Field {
        Field(name: "guardrails.\(name)", bound: GuardrailLimits.upperBound(path),
              set: { $0.guardrails[keyPath: path] = $1 }, get: { $0.guardrails[keyPath: path] })
    }

    private static func p(_ name: String, _ path: WritableKeyPath<PainRuleLimits, Int>) -> Field {
        Field(name: "painLimits.\(name)", bound: PainRuleLimits.upperBound(path),
              set: { $0.painLimits[keyPath: path] = $1 }, get: { $0.painLimits[keyPath: path] })
    }

    private static func a(_ name: String, _ path: WritableKeyPath<AdaptationLimits, Int>) -> Field {
        Field(name: "limits.\(name)", bound: AdaptationLimits.upperBound(path),
              set: { $0.limits[keyPath: path] = $1 }, get: { $0.limits[keyPath: path] })
    }

    private static func r(_ name: String, _ path: WritableKeyPath<PainRecoveryLimits, Int>) -> Field {
        Field(name: "painRecoveryLimits.\(name)", bound: PainRecoveryLimits.upperBound(path),
              set: { $0.painRecoveryLimits[keyPath: path] = $1 }, get: { $0.painRecoveryLimits[keyPath: path] })
    }

    private static func s(_ name: String, _ path: WritableKeyPath<PainStopLimits, Int>) -> Field {
        Field(name: "painStopLimits.\(name)", bound: PainStopLimits.upperBound(path),
              set: { $0.painStopLimits[keyPath: path] = $1 }, get: { $0.painStopLimits[keyPath: path] })
    }

    /// Every whole-number limit of the five structs, and each end of
    /// `rampDaysOff` (#157), whose bound is the top of `rampDaysOffBounds`.
    static let fields: [Field] = [
        g("maxConsecutiveBuildWeeks", \.maxConsecutiveBuildWeeks), g("maxQualitySessionsPerWeek", \.maxQualitySessionsPerWeek),
        g("spikeWindowDays", \.spikeWindowDays), g("preBreakWeeks", \.preBreakWeeks),
        g("maxShortBreakWeeks", \.maxShortBreakWeeks),
        Field(name: "guardrails.breakReturnMaxQualitySessions", bound: nil,
              set: { $0.guardrails.breakReturnMaxQualitySessions = [$1, $1] },
              get: { $0.guardrails.breakReturnMaxQualitySessions.first ?? -1 }),
        p("highScore", \.highScore), p("minimumRise", \.minimumRise), p("freezeDays", \.freezeDays),
        p("persistentCount", \.persistentCount),
        a("signalWindow", \.signalWindow), a("signalsToMove", \.signalsToMove), a("easyRunsForCapCheck", \.easyRunsForCapCheck),
        a("strainRPEMargin", \.strainRPEMargin), a("overreachedRPEMargin", \.overreachedRPEMargin),
        a("longRunQualifyingCount", \.longRunQualifyingCount), a("longRunReferenceRuns", \.longRunReferenceRuns),
        a("holdVolumeDays", \.holdVolumeDays), a("powerHistoryRuns", \.powerHistoryRuns),
        a("powerHistoryDays", \.powerHistoryDays), a("powerHistoryMinimumRuns", \.powerHistoryMinimumRuns),
        a("regrowthSnapshotWeeks", \.regrowthSnapshotWeeks),
        r("usualWindow", \.usualWindow), r("usualMinimumCheckIns", \.usualMinimumCheckIns),
        r("nextMorningRise", \.nextMorningRise), r("nextMorningHigh", \.nextMorningHigh), r("risingWeeks", \.risingWeeks),
        r("freezeDays", \.freezeDays), r("morningsToEnd", \.morningsToEnd), r("walkingMax", \.walkingMax),
        r("testAllowance", \.testAllowance), r("testMaxScore", \.testMaxScore), r("cannotEndUsual", \.cannotEndUsual),
        r("walkingStuck", \.walkingStuck), r("stuckDays", \.stuckDays), r("regrowthWeeks", \.regrowthWeeks),
        r("flagReportsToClear", \.flagReportsToClear), r("flagAskDays", \.flagAskDays),
        r("flagCloseDays", \.flagCloseDays), r("flagReopenDays", \.flagReopenDays),
        Field(name: "painRecoveryLimits.rampDaysOff.upperBound", bound: PainRecoveryLimits.rampDaysOffBounds.upperBound,
              set: { $0.painRecoveryLimits.rampDaysOff = min(6, $1)...$1 },
              get: { $0.painRecoveryLimits.rampDaysOff.upperBound }),
        Field(name: "painRecoveryLimits.rampDaysOff.lowerBound", bound: PainRecoveryLimits.rampDaysOffBounds.upperBound,
              set: { $0.painRecoveryLimits.rampDaysOff = $1...max($1, 14) },
              get: { $0.painRecoveryLimits.rampDaysOff.lowerBound }),
        s("clinicianDays", \.clinicianDays), s("restTriggerCount", \.restTriggerCount),
    ]

    // MARK: Scenarios

    /// Everything a limit can reach (or the scenarios in `only`), run with
    /// `apply` on each scenario's context: the checker in time and distance, the plan builder, the pain
    /// check-in rule, and the adaptation engine through a pain stop and its
    /// return, a missed week and its regrowth, check-ins, a thin week, a held
    /// long-run gate, sessions that point behind, next-morning pain and a
    /// clinician flag left without reports.
    struct Exercise: Equatable {
        var reports: [GuardrailReport] = []
        var built: PlanBuildResult?
        var checkIn: PainCheckInOutcome?
        var engine: [[AdaptationOutcome]] = []
    }

    static func exercise(_ only: Set<String>? = nil, _ apply: (inout AdaptationContext) -> Void) -> Exercise {
        var out = Exercise()
        func wants(_ scenario: String) -> Bool { only?.contains(scenario) ?? true }
        func ctx(tracksPain: Bool, seed: Int? = nil) -> AdaptationContext {
            var c = AdaptationContext(zones: F.zones, timeZone: F.tz, tracksPain: tracksPain, usualPainSeed: seed)
            apply(&c)
            return c
        }
        let base = ctx(tracksPain: true, seed: 2)

        // GuardrailChecker: six weeks of history with a dip, four weeks of plan
        // with four quality sessions and a long run each.
        if wants("checker") {
            let history = (0..<6).flatMap { w in
                [P.workout("h\(w)a", week: w, day: 1, .easy, minutes: 100, km: 16),
                 P.workout("h\(w)l", week: w, day: 5, .long, minutes: w == 4 ? 10 : 80, km: w == 4 ? 1.6 : 13)]
        }
        let plan = (6..<10).flatMap { w in
            [P.workout("p\(w)a", week: w, day: 1, .quality(.threshold), minutes: 120, km: 22),
             P.workout("p\(w)b", week: w, day: 3, .quality(.intervals), minutes: 60, km: 11),
             P.workout("p\(w)c", week: w, day: 4, .quality(.tempo), minutes: 60, km: 11),
             P.workout("p\(w)l", week: w, day: 5, .long, minutes: 200, km: 32)]
        }
        out.reports = [VolumeMeasure.time, .distance].map { m in
            var l = base.guardrails
            l.measure = m
            return GuardrailChecker.check(history: history, planned: plan, timeZone: P.utc, limits: l)
        }
        }

        // PlanBuilder: a half marathon in 16 weeks after four weeks at 150 min.
        if wants("builder") {
            let days: Set<PlanWeekday> = [.tuesday, .thursday, .saturday, .sunday]
            let built = (0..<4).flatMap { w in
                days.map { d in
                    PlannedWorkout(id: "b\(w)-\(d.rawValue)", date: P.date(week: w, day: d.rawValue, hour: 7),
                                   kind: d == .sunday ? .long : .easy, durationSeconds: (d == .sunday ? 45 : 35) * 60)
                }
        }
        let input = PlanInput(raceDistanceMeters: Distance.halfMarathon, raceDate: P.date(week: 20, day: 6, hour: 8),
                              startDate: P.date(week: 4, day: 0, hour: 0), trainingDays: days, longRunDay: .sunday,
                              maxSessionSeconds: nil, recentWeeklySeconds: 150 * 60, recentLongRunSeconds: 45 * 60,
                              heartRateZones: HRZones(lthr: 165), easyPace: EasyPaceSample(secondsPerKm: 340, heartRate: 125),
                              fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: 23 * 60))
        var builderLimits = base.guardrails
        builderLimits.measure = .time
        out.built = PlanBuilder.build(input, history: built, timeZone: P.utc, limits: builderLimits)
        }

        // PainCheckInRule: 5, 7 and 6 on consecutive mornings, a quality session ahead.
        if wants("checkInRule") {
            let start = P.date(week: 0, day: 0, hour: 9)
            let checkIns = [5, 7, 6].enumerated().map {
                PainCheckIn(date: start.addingTimeInterval(Double($0.offset) * 86_400), score: $0.element)
        }
        out.checkIn = PainCheckInRule.evaluate(tracksPain: true, checkIns: checkIns,
                                               plan: [P.workout("q", week: 0, day: 5, .quality(.tempo), minutes: 50)],
                                               asOf: start.addingTimeInterval(2 * 86_400 + 3600), lastAppliedCheckIn: nil,
                                               timeZone: P.utc, limits: base.painLimits)
        }

        // The engine.
        var runs: [F.Driver] = []
        // A pain stop that ends with a test run, and its return (3.5 rule 7).
        if wants("painStop") {
            var d = F.Driver(plan: F.weeks(0..<5), context: base)
            d.follow(until: F.date(week: 0, day: 6, hour: 23)) { _ in F.RunSpec() }
            d.afterRun(week: 0, day: 6, 6, worsened: true, hour: 10)
            for day in 0..<7 { d.morning(week: 1, day: day, day < 3 ? 1 : 2, walking: 0) }
            if d.testSession != nil { d.runTest(2) }
            for day in 0..<7 { d.morning(week: 2, day: day, 2) }
            d.follow(until: F.date(week: 4, day: 6, hour: 23)) { _ in F.RunSpec() }
            runs.append(d)
        }
        // A missed week and its regrowth (3.5 rule 6).
        if wants("missedWeek") {
            var d = F.Driver(plan: F.weeks(0..<5), context: ctx(tracksPain: false))
            d.follow(until: F.date(week: 3, day: 6, hour: 23)) { w in
                ["t1", "e1a", "e1b", "l1"].contains(w.id) ? nil : F.RunSpec()
        }
        runs.append(d)
        }
        // Three high check-ins after long runs (3.5).
        if wants("checkIns") {
            var d = F.Driver(plan: F.weeks(0..<3), context: base)
            d.follow(until: F.date(week: 0, day: 5, hour: 23)) { _ in F.RunSpec() }
            d.checkIn(6, at: F.date(week: 0, day: 5, hour: 12))
            d.checkIn(7, at: F.date(week: 0, day: 6, hour: 12))
            d.checkIn(7, at: F.date(week: 1, day: 0, hour: 12))
            d.follow(until: F.date(week: 1, day: 6, hour: 23)) { _ in F.RunSpec() }
            runs.append(d)
        }
        // A thin week: the long run swapped for an easy run.
        if wants("thinWeek") {
            let thinHistory = (0..<4).map { F.easy("h\($0)", week: 0, day: $0 * 2, minutes: 50.0) }
            var d = F.Driver(plan: [F.easy("e1", week: 1, day: 2, minutes: 20), F.long("l1", week: 1, day: 6, minutes: 50)],
                         history: thinHistory, context: ctx(tracksPain: false))
            d.day(F.date(week: 1, day: 0, hour: 6))
            runs.append(d)
        }
        // A held long-run gate (3.3).
        if wants("heldGate") {
            var d = F.Driver(plan: F.weeks(0..<2), context: ctx(tracksPain: false))
            d.state.longRuns = [-2, -1].map { w in
                LongRunRecord(activityID: "old-l\(-w)", date: F.date(week: w, day: 5), plannedSeconds: 40 * 60,
                              movingSeconds: 40 * 60, decouplingPercent: 8)
        }
        d.day(F.date(week: 0, day: 0, hour: 5))
        runs.append(d)
        }
        // Two quality sessions behind: paces slow and volume is held.
        if wants("behind") {
            var d = F.Driver(plan: F.weeks(0..<4), context: ctx(tracksPain: false))
            let specs: [String: F.RunSpec] = ["t0": F.RunSpec(pace: 1.04, rpe: 9), "t1": F.RunSpec(hr: .high)]
            d.follow(until: F.date(week: 2, day: 6, hour: 23)) { specs[$0.id] ?? F.RunSpec() }
            runs.append(d)
        }
        // Next-morning pain at usual + 1 (a freeze), then rising weeks.
        if wants("nextMorning") {
            var d = F.Driver(plan: F.weeks(0..<5), context: base)
            d.follow(until: F.date(week: 0, day: 1, hour: 8)) { _ in F.RunSpec() }
            d.morning(week: 0, day: 2, 3)
            for week in 1..<4 { d.morning(week: week, day: 2, min(2 + week, 3)) }
            d.day(F.date(week: 4, day: 0, hour: 6))
            runs.append(d)
        }
        // A red flag, then 15 days without a report: asked, then closed.
        if wants("flag") {
            var d = F.Driver(plan: F.weeks(0..<4), context: base)
            d.follow(until: F.date(week: 0, day: 1, hour: 8)) { _ in F.RunSpec() }
            d.morning(week: 0, day: 2, 2, flags: [.numbnessOrTingling])
            for k in 1...15 { d.day(F.date(week: 0, day: 2, hour: 7).addingTimeInterval(Double(k) * 86_400)) }
            runs.append(d)
        }
        out.engine = runs.map(\.outcomes)
        return out
    }

    // MARK: Formatting

    /// Each formatter a huge finite value can reach, by name, for a child to run.
    static let formatCases: [String: (Double, UnitPreference) -> String] = {
        func debrief(_ name: DebriefValue.Name, _ unit: DebriefValue.Unit, extra: Int = 0) -> (Double, UnitPreference) -> String {
            { DebriefFormat.string(DebriefValue(name: name, value: $0, unit: unit), timeZone: P.utc, extraDecimals: extra, units: $1) }
        }
        return [
            "format.distance": { UnitFormatting.distance($0, $1) },
            "format.paceClock": { UnitFormatting.paceClock($0, $1) },
            "format.pace": { UnitFormatting.pace($0, $1) },
            "format.paceRange": { UnitFormatting.paceRange(PaceTarget(fastestSecondsPerKm: $0, slowestSecondsPerKm: $0), $1) },
            "format.climb": { UnitFormatting.climb($0, $1) },
            "format.debrief.clock": debrief(.movingTime, .seconds),
            "format.debrief.volume": debrief(.allowedTime, .seconds),
            "format.debrief.distance": debrief(.distance, .meters),
            "format.debrief.pace": debrief(.pace, .secondsPerKm),
            "format.debrief.climb": debrief(.climb, .metersPerKm),
            "format.debrief.climbExtra": debrief(.climb, .metersPerKm, extra: 2),
            "format.debrief.heartRate": debrief(.heartRate, .bpm),
            "format.debrief.cadence": debrief(.cadence, .stepsPerMinute),
            "format.debrief.zone": debrief(.zone, .zone),
            "format.debrief.count": debrief(.signalCount, .count),
            "format.debrief.painScore": debrief(.painScore, .painScore),
            "format.debrief.percent": debrief(.decoupling, .percent),
            "format.debrief.fraction": debrief(.paceTolerance, .fraction),
            "format.debrief.date": debrief(.holdEnd, .date),
            "format.plan.volume": { v, u in PlanFormatting.volume(v, .time, units: u) },
            "format.plan.percent": { v, _ in PlanFormatting.percent(v) },
            "format.goal.clock": { v, _ in GoalPlanner.clock(v) },
            "format.goal.limit": { v, _ in GoalPlanner.limit(.seconds(v)) },
        ]
    }()

    /// Formatters that print a huge finite value in full (a long number, no
    /// crash), left as they are (#147); every other one shows "-". A volume
    /// in time (`PlanFormatting.volume`, #142) shows "-" only past `Int`'s
    /// range and prints below it, in full since #157, and so does a session
    /// limit, which reads as a volume.
    static let printedInFull: Set<String> = ["format.distance", "format.debrief.distance", "format.debrief.climbExtra",
                                             "format.debrief.date", "format.debrief.volume", "format.plan.volume",
                                             "format.goal.limit"]

    // MARK: Running a case in a child process

    private static let caseKey = "COACHCORE_INT_LIMIT_CASE"
    private static let valueKey = "COACHCORE_INT_LIMIT_VALUE"

    /// A context with every limit at its default.
    static func defaultContext() -> AdaptationContext {
        AdaptationContext(zones: F.zones, timeZone: F.tz, tracksPain: true)
    }

    /// The child's side: runs the case its parent named, and does nothing in
    /// an ordinary run. A limit runs everything it can reach; one that fell
    /// back must be stored exactly as the default. A formatter must show "-"
    /// for a value it can't count, or print it in full where it can.
    func testChildCase() throws {
        let env = ProcessInfo.processInfo.environment
        guard let name = env[Self.caseKey], let raw = env[Self.valueKey] else { return }
        try runCase(name, raw)
    }

    private func runCase(_ name: String, _ raw: String) throws {
        if let format = Self.formatCases[name] {
            let value = try XCTUnwrap(Double(raw), raw)
            for units in [UnitPreference.metric, .imperial] {
                let text = format(value, units)
                if Self.printedInFull.contains(name) {
                    XCTAssertFalse(text.isEmpty, "\(name) \(raw) \(units)")
                } else {
                    XCTAssertEqual(text, name == "format.paceRange" ? "- to -" : "-", "\(name) \(raw) \(units)")
                }
            }
            return
        }
        let field = try XCTUnwrap(Self.fields.first { $0.name == name }, name)
        let value = try XCTUnwrap(Int(raw), raw)
        _ = Self.exercise(field.scenarios) { field.set(&$0, value) }
        var stored = Self.defaultContext()
        field.set(&stored, value)
        if field.get(stored) != value {
            XCTAssertEqual(stored, Self.defaultContext(), "\(name) \(value) is stored as the default")
        }
    }

    /// Runs each case in a child process of this test binary, a few at a
    /// time, and fails, with the child's output, for each one that doesn't
    /// exit cleanly within `seconds`. Off Linux the cases run in this process
    /// (on macOS, where the app's tests run): a crash there ends the whole
    /// test run, not one test, and there is no time limit.
    func runIsolated(_ cases: [(name: String, value: String)], seconds: Double = 180,
                             file: StaticString = #filePath, line: UInt = #line) {
        #if os(Linux)
        let failures = Outcome<[String]>()
        failures.value = []
        let lock = NSLock()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount))
        for c in cases {
            queue.addOperation {
                if let failure = Self.child(c.name, c.value, seconds: seconds) {
                    lock.lock()
                    failures.value?.append(failure)
                    lock.unlock()
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        for failure in failures.value ?? [] { XCTFail(failure, file: file, line: line) }
        #else
        for c in cases { XCTAssertNoThrow(try runCase(c.name, c.value), file: file, line: line) }
        #endif
    }

    #if os(Linux)
    /// One child: nil when it exited cleanly in time, else what went wrong.
    private static func child(_ name: String, _ value: String, seconds: Double) -> String? {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["CoachCoreTests.IntLimitBoundTests/testChildCase"]
        var env = ProcessInfo.processInfo.environment
        env[caseKey] = name
        env[valueKey] = value
        child.environment = env
        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = pipe
        let output = Outcome<Data>()
        let read = DispatchSemaphore(value: 0)
        Thread {
            output.value = pipe.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }.start()
        do { try child.run() } catch {
            // Close the write end so the reader thread sees end of file and
            // finishes, instead of staying blocked on the pipe.
            try? pipe.fileHandleForWriting.close()
            _ = read.wait(timeout: .now() + 10)
            return "\(name) \(value): couldn't start the child: \(error)"
        }
        let deadline = Date().addingTimeInterval(seconds)
        while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if child.isRunning {
            // SIGKILL: the child inherits a blocked SIGTERM from Foundation's
            // spawn, so `terminate()` would leave a hung child running.
            kill(child.processIdentifier, SIGKILL)
            child.waitUntilExit()
            return "\(name) \(value): still running after \(Int(seconds)) s"
        }
        _ = read.wait(timeout: .now() + 10)
        guard child.terminationReason != .exit || child.terminationStatus != 0 else { return nil }
        let text = String(decoding: output.value ?? Data(), as: UTF8.self)
        let tail = text.split(separator: "\n").filter { !$0.contains("Test Case") && !$0.contains("Test Suite") }.suffix(12)
        let how = child.terminationReason == .exit ? "failed" : "crashed (signal \(child.terminationStatus))"
        return "\(name) \(value) \(how):\n" + tail.joined(separator: "\n")
    }
    #endif

    // MARK: The crash, reproduced and fixed

    static let named = ["guardrails.preBreakWeeks", "guardrails.maxShortBreakWeeks", "guardrails.spikeWindowDays"]

    /// The issue's three fields at `Int.max`: an overflow in the checker or
    /// the engine (`preBreakWeeks`, `spikeWindowDays`) or a loop of `Int.max`
    /// weeks (`maxShortBreakWeeks`) on main.
    func testIntMaxNoLongerCrashesTheCheckerOrTheEngine() {
        runIsolated(Self.named.map { ($0, String(Int.max)) })
    }

    /// Every other whole-number limit at `Int.max` (on main
    /// `regrowthSnapshotWeeks`, `nextMorningRise`, `testAllowance`,
    /// `risingWeeks` and `regrowthWeeks` overflowed) runs to the end.
    func testEveryWholeNumberLimitRunsAtIntMax() {
        runIsolated(Self.fields.filter { !Self.named.contains($0.name) }.map { ($0.name, String(Int.max)) })
    }

    /// Every bounded limit at its bound runs to the end. Behind
    /// `COACHCORE_SLOW_TESTS` (#158): the bounds are small enough that each
    /// case costs about what the default does, but there are 17 of them in
    /// child processes. `COACHCORE_SLOW_TESTS=1 swift test`.
    func testEveryBoundedLimitRunsAtItsBound() throws {
        try requireSlowTests()
        runIsolated(Self.fields.compactMap { f in f.bound.map { (f.name, String($0)) } })
    }

    /// Skips the test unless `COACHCORE_SLOW_TESTS=1`.
    func requireSlowTests() throws {
        guard ProcessInfo.processInfo.environment["COACHCORE_SLOW_TESTS"] == "1" else {
            throw XCTSkip("set COACHCORE_SLOW_TESTS=1 to run the long sweep")
        }
    }

    /// On main a huge finite pace, clock, climb, heart rate, cadence, zone,
    /// count, pain score or percent trapped converting to `Int`.
    func testHugeFiniteValuesNoLongerCrashTheFormatters() {
        let values = [1e300, -1e300, Double.greatestFiniteMagnitude, 1e19].map { String($0) }
        runIsolated(Self.formatCases.keys.sorted().flatMap { name in values.map { (name, $0) } })
    }

    // MARK: Where the limits are stored

    /// The bounds as the PR lists them.
    func testTheBoundsAreTheDocumentedOnes() {
        let bounds = Dictionary(uniqueKeysWithValues: Self.fields.compactMap { f in f.bound.map { (f.name, $0) } })
        XCTAssertEqual(bounds, [
            "guardrails.spikeWindowDays": 730, "guardrails.preBreakWeeks": 104, "guardrails.maxShortBreakWeeks": 104,
            "painLimits.freezeDays": 730,
            "painStopLimits.clinicianDays": 730, "painStopLimits.restTriggerCount": 100,
            "limits.holdVolumeDays": 730, "limits.powerHistoryDays": 730, "limits.regrowthSnapshotWeeks": 104,
            "painRecoveryLimits.freezeDays": 730, "painRecoveryLimits.flagCloseDays": 730,
            "painRecoveryLimits.risingWeeks": 104, "painRecoveryLimits.regrowthWeeks": 104,
            "painRecoveryLimits.nextMorningRise": 100, "painRecoveryLimits.testAllowance": 100,
            "painRecoveryLimits.rampDaysOff.upperBound": 730, "painRecoveryLimits.rampDaysOff.lowerBound": 730,
        ])
        for f in Self.fields {
            XCTAssertLessThanOrEqual(f.get(Self.defaultContext()), f.bound ?? .max, "\(f.name): the default is within its bound")
        }
    }

    func testAValueAboveItsBoundIsStoredAsTheDefault() {
        for f in Self.fields {
            guard let bound = f.bound else { continue }
            for v in [bound + 1, bound * 10, Int.max] {
                var c = Self.defaultContext()
                f.set(&c, v)
                XCTAssertEqual(f.get(c), f.get(Self.defaultContext()), "\(f.name) \(v)")
                XCTAssertEqual(c, Self.defaultContext(), "\(f.name) \(v): only that limit was bad")
            }
        }
        // The same when the values are handed to the initializers.
        let m = Int.max
        XCTAssertEqual(GuardrailLimits(spikeWindowDays: m, preBreakWeeks: m, maxShortBreakWeeks: m), .default)
        XCTAssertEqual(GuardrailLimits(spikeWindowDays: 731, preBreakWeeks: 105, maxShortBreakWeeks: 105), .default)
        XCTAssertEqual(PainRuleLimits(freezeDays: m), .default)
        XCTAssertEqual(PainRuleLimits(freezeDays: 731), .default)
        XCTAssertEqual(AdaptationLimits(holdVolumeDays: m, powerHistoryDays: m, regrowthSnapshotWeeks: m), .default)
        XCTAssertEqual(PainRecoveryLimits(nextMorningRise: m, risingWeeks: m, freezeDays: m, testAllowance: m,
                                          regrowthWeeks: m, flagCloseDays: m), .default)
        XCTAssertEqual(PainRecoveryLimits(nextMorningRise: 101, risingWeeks: 105, freezeDays: 731, testAllowance: 101,
                                          regrowthWeeks: 105, flagCloseDays: 731), .default)
        XCTAssertEqual(PainStopLimits(clinicianDays: m, restTriggerCount: m), .default)
        XCTAssertEqual(PainStopLimits(clinicianDays: 731, restTriggerCount: 101), .default)
        XCTAssertEqual(PainStopLimits(clinicianDays: 10_000, restTriggerCount: 10_000), .default)
    }

    func testValuesUpToTheBoundAreKept() {
        for f in Self.fields {
            let values = [0, 1, 5, 42, 100] + (f.bound.map { [$0 - 1, $0] } ?? [1_000_000, Int.max])
            for v in values {
                var c = Self.defaultContext()
                f.set(&c, v)
                XCTAssertEqual(f.get(c), v, "\(f.name) \(v) is kept")
            }
        }
        // Below 0 falls back everywhere: the guardrail and pain check-in
        // limits since #142, the engine's, the return's and the pain stop's
        // since #157 (`IntLimitBoundTests+Negative`).
        var c = Self.defaultContext()
        c.guardrails.preBreakWeeks = -1
        c.painLimits.freezeDays = -1
        c.limits.holdVolumeDays = -1
        c.painRecoveryLimits.risingWeeks = -1
        c.painStopLimits.clinicianDays = -1
        XCTAssertEqual(c, Self.defaultContext())
        // The initializers keep a value at the bound.
        XCTAssertEqual(GuardrailLimits(spikeWindowDays: 730, preBreakWeeks: 104, maxShortBreakWeeks: 104).spikeWindowDays, 730)
        XCTAssertEqual(PainRuleLimits(freezeDays: 730).freezeDays, 730)
        XCTAssertEqual(AdaptationLimits(regrowthSnapshotWeeks: 104).regrowthSnapshotWeeks, 104)
        XCTAssertEqual(PainRecoveryLimits(testAllowance: 100).testAllowance, 100)
        XCTAssertEqual(PainStopLimits(clinicianDays: 730, restTriggerCount: 100).clinicianDays, 730)
        XCTAssertEqual(PainStopLimits(clinicianDays: 730, restTriggerCount: 100).restTriggerCount, 100)
    }

    func testTheDefaultsAreUnchanged() {
        let g = GuardrailLimits.default, p = PainRuleLimits.default, a = AdaptationLimits.default, r = PainRecoveryLimits.default
        XCTAssertEqual([g.maxConsecutiveBuildWeeks, g.maxQualitySessionsPerWeek, g.spikeWindowDays, g.preBreakWeeks,
                        g.maxShortBreakWeeks], [3, 2, 30, 4, 2])
        XCTAssertEqual(g.breakReturnMaxQualitySessions, [0, 1])
        XCTAssertEqual([p.highScore, p.minimumRise, p.freezeDays, p.persistentCount], [4, 2, 7, 3])
        XCTAssertEqual([a.signalWindow, a.signalsToMove, a.easyRunsForCapCheck, a.strainRPEMargin, a.overreachedRPEMargin,
                        a.longRunQualifyingCount, a.longRunReferenceRuns, a.holdVolumeDays, a.powerHistoryRuns,
                        a.powerHistoryDays, a.powerHistoryMinimumRuns, a.regrowthSnapshotWeeks],
                       [3, 2, 3, 2, 3, 2, 4, 7, 5, 42, 3, 10])
        XCTAssertEqual([r.usualWindow, r.usualMinimumCheckIns, r.nextMorningRise, r.nextMorningHigh, r.risingWeeks, r.freezeDays,
                        r.morningsToEnd, r.walkingMax, r.testAllowance, r.testMaxScore, r.cannotEndUsual, r.walkingStuck,
                        r.stuckDays, r.regrowthWeeks, r.flagReportsToClear, r.flagAskDays, r.flagCloseDays, r.flagReopenDays],
                       [5, 3, 2, 4, 3, 7, 2, 2, 1, 3, 4, 3, 7, 2, 3, 7, 14, 42])
        XCTAssertEqual(r.rampDaysOff, 6...14)
        XCTAssertEqual([PainStopLimits.default.clinicianDays, PainStopLimits.default.restTriggerCount], [7, 2])
    }

    func testABoundedLimitStillChangesWhatTheRulesDo() {
        // A 10-day pain freeze, well inside the bound, still lasts 10 days.
        let start = P.date(week: 0, day: 0, hour: 9)
        let outcome = PainCheckInRule.evaluate(tracksPain: true, checkIns: [PainCheckIn(date: start, score: 6)], plan: [],
                                               asOf: start.addingTimeInterval(3600), lastAppliedCheckIn: nil,
                                               timeZone: P.utc, limits: PainRuleLimits(freezeDays: 10))
        guard case .act(let r) = outcome else { return XCTFail("expected an action, got \(outcome)") }
        XCTAssertEqual(r.freezeEnd.timeIntervalSince(r.freezeStart), 10 * 86_400, accuracy: 1)
        // A spike window of 1 day finds no reference where 30 days does.
        let runs = [P.workout("a", week: 0, day: 0, .long, minutes: 60)]
        XCTAssertNotNil(GuardrailChecker.spikeReference(before: P.date(week: 0, day: 5), measure: .time, sessions: runs,
                                                        timeZone: P.utc))
        XCTAssertNil(GuardrailChecker.spikeReference(before: P.date(week: 0, day: 5), measure: .time, sessions: runs,
                                                     timeZone: P.utc, limits: GuardrailLimits(spikeWindowDays: 1)))
    }

    /// #173: past its bound a pain stop limit reads as the default, so the
    /// rule still fires; before, `Int.max` silently switched it off.
    func testAPainStopLimitPastItsBoundStillLetsTheRuleFire() {
        let start = Date(timeIntervalSince1970: 1_767_225_600)   // 00:00 UTC
        let reports = (0...8).map {
            PainReport(date: start.addingTimeInterval(Double($0) * 86_400 + 8 * 3600), timing: .nextMorning,
                       hasPain: true, score: 3)
        }
        let asOf = start.addingTimeInterval(9 * 86_400)
        func lasting(_ days: Int) -> LastingPain? {
            PainStopRule.lastingPain(reports: reports, checkIns: [], asOf: asOf, timeZone: P.utc,
                                     limits: PainStopLimits(clinicianDays: days))
        }
        XCTAssertNotNil(lasting(7), "the default")
        XCTAssertNotNil(lasting(Int.max), "stored as the default")
        XCTAssertNotNil(lasting(731))
        XCTAssertNil(lasting(730), "kept at the bound: 730 days have not passed")
        let two: [PainStopTrigger] = [.worsenedDuringRun, .stillThereNextMorning]
        XCTAssertEqual(PainStopRule.mode(for: two, limits: PainStopLimits(restTriggerCount: Int.max)), .rest)
        XCTAssertEqual(PainStopRule.mode(for: two, limits: PainStopLimits(restTriggerCount: 101)), .rest)
        XCTAssertEqual(PainStopRule.mode(for: two, limits: PainStopLimits(restTriggerCount: 100)), .easyOnly,
                       "kept at the bound: two triggers are fewer than 100")
    }

    // MARK: Formatting ordinary values

    func testFormattersReadAsBeforeForOrdinaryValues() {
        XCTAssertEqual(UnitFormatting.paceClock(331, .metric), "5:31")
        XCTAssertEqual(UnitFormatting.pace(331, .imperial), "8:53/mi")
        XCTAssertEqual(UnitFormatting.paceClock(0, .metric), "-")
        XCTAssertEqual(UnitFormatting.climb(12, .metric), "12 m per km")
        XCTAssertEqual(UnitFormatting.climb(12, .imperial), "63 ft per mi")
        XCTAssertEqual(UnitFormatting.distance(8_200, .metric), "8.2 km")
        // A huge distance prints in full: long, but it doesn't crash (#147).
        let huge = UnitFormatting.distance(1e300, .metric)
        XCTAssertTrue(huge.count > 290 && huge.hasSuffix(".0 km"), huge)
        func s(_ name: DebriefValue.Name, _ value: Double, _ unit: DebriefValue.Unit, extra: Int = 0) -> String {
            DebriefFormat.string(DebriefValue(name: name, value: value, unit: unit), timeZone: P.utc, extraDecimals: extra)
        }
        XCTAssertEqual(s(.movingTime, 2_710, .seconds), "45:10")
        XCTAssertEqual(s(.movingTime, 3_920, .seconds), "1:05:20")
        XCTAssertEqual(s(.pace, 331, .secondsPerKm), "5:31")
        XCTAssertEqual(s(.climb, 12.4, .metersPerKm), "12")
        XCTAssertEqual(s(.climb, 12.4, .metersPerKm, extra: 1), "12.4")
        XCTAssertEqual(s(.heartRate, 148.2, .bpm), "148")
        XCTAssertEqual(s(.cadence, 171.6, .stepsPerMinute), "172")
        XCTAssertEqual(s(.zone, 2, .zone), "2")
        XCTAssertEqual(s(.zone, 5, .zone), "5a")
        XCTAssertEqual(s(.zone, 7, .zone), "5c")
        XCTAssertEqual(s(.signalCount, 3, .count), "3")
        XCTAssertEqual(s(.painScore, 4, .painScore), "4")
        XCTAssertEqual(s(.decoupling, 3.24, .percent), "3.2")
        XCTAssertEqual(s(.decoupling, 5, .percent), "5")
        XCTAssertEqual(s(.decoupling, -0.01, .percent), "0")
        // Large but countable values print in full, not cut to 32 bits.
        XCTAssertEqual(s(.movingTime, 1e13, .seconds), "2777777777:46:40")
        XCTAssertEqual(UnitFormatting.paceClock(1e13, .metric), "166666666666:40")
    }
}

/// Where a background run leaves its result.
private final class Outcome<T>: @unchecked Sendable {
    var value: T?
}
