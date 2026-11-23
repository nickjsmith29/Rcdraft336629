import XCTest
@testable import CoachCore

// Synthetic data only: every LTHR, pace, power and cadence below is made up
// and stands for no real runner.
private enum WatchFixture {
    static let utc = TimeZone(identifier: "UTC")!
    static let newYork = TimeZone(identifier: "America/New_York")!
    static let lthr = 160.0
    static var zones: HRZones { HRZones(lthr: lthr)! }

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 7, _ min: Int = 0, tz: TimeZone = utc) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        return PlanCalendar.calendar(timeZone: tz).date(from: c)!
    }

    static func hr(_ lo: HRZone, _ hi: HRZone, floor: HRZone?, ceiling: HRZone?, lthr: Double = lthr) -> HeartRateTarget {
        let z = HRZones(lthr: lthr)!
        return HeartRateTarget(zones: lo...hi, floorBPM: floor.map { z.lowerBound($0) },
                               ceilingBPM: ceiling.map { z.lowerBound($0) })
    }

    static let easyHR = hr(.z1, .z2, floor: nil, ceiling: .z3)
    static let thresholdHR = hr(.z4, .z5a, floor: .z4, ceiling: .z5b)
    static let vo2HR = hr(.z5b, .z5c, floor: .z5b, ceiling: nil)

    static func seg(_ role: WorkoutSegment.Role, _ intensity: WorkoutIntensity, minutes: Double,
                    hr: HeartRateTarget, pace: PaceTarget? = nil, primary: WorkoutTarget.Primary = .heartRate) -> WorkoutSegment {
        WorkoutSegment(role: role, intensity: intensity, durationSeconds: minutes * 60,
                       target: WorkoutTarget(heartRate: hr, pace: pace, primary: primary))
    }

    static let thresholdPace = PaceTarget(fastestSecondsPerKm: 250, slowestSecondsPerKm: 260)

    /// 10 min warm-up, 3 × 8 min threshold with 2 min jogs, 5 min cool-down: 49 minutes.
    static func thresholdSession(id: String = "q1", date: Date, pace: PaceTarget? = thresholdPace,
                                 primary: WorkoutTarget.Primary = .pace) -> PlannedWorkout {
        let work = seg(.work, .threshold, minutes: 8, hr: thresholdHR, pace: pace, primary: primary)
        let jog = seg(.jog, .repRecovery, minutes: 2, hr: easyHR)
        let segments = [seg(.warmUp, .easy, minutes: 10, hr: easyHR), work, jog, work, jog, work,
                        seg(.coolDown, .easy, minutes: 5, hr: easyHR)]
        let p = WorkoutPrescription(purpose: "Threshold.", phase: .build, segments: segments, rules: [.intensityDistribution])
        return PlannedWorkout(id: id, date: date, kind: .quality(.threshold), durationSeconds: p.durationSeconds,
                              prescription: p)
    }

    static func easySession(id: String, date: Date, minutes: Double = 40, pace: PaceTarget? = nil) -> PlannedWorkout {
        let p = WorkoutPrescription(purpose: "Easy run.", phase: .base,
                                    segments: [seg(.main, .easy, minutes: minutes, hr: easyHR, pace: pace)],
                                    rules: [.easyByHeartRate])
        return PlannedWorkout(id: id, date: date, kind: .easy, durationSeconds: minutes * 60, prescription: p)
    }

    static func only(_ m: WatchSyncMapper.Mapped, file: StaticString = #filePath, line: UInt = #line) throws -> WatchWorkout {
        guard case .workout(let w) = m else {
            XCTFail("expected a workout, got \(m)", file: file, line: line)
            throw NotAWorkout()
        }
        return w
    }
}

private struct NotAWorkout: Error {}

private extension WatchStep {
    func reason(_ m: WatchAlertMetric) -> WatchAlertOmissionReason? {
        omittedAlerts.first { $0.metric == m }?.reason
    }
}

final class WatchSyncIDTests: XCTestCase {
    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    func testSHA1KnownVectors() {
        XCTAssertEqual(hex(SHA1.digest([])), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(hex(SHA1.digest(Array("abc".utf8))), "a9993e364706816aba3e25717850c26c9cd0d89d")
        // 56 bytes: the padding spills into a second block.
        XCTAssertEqual(hex(SHA1.digest(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),
                       "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
        XCTAssertEqual(hex(SHA1.digest(Array(repeating: UInt8(ascii: "a"), count: 1000))),
                       "291e9a6c66994949b57ba5e650361e98fc36b1ba")
    }

    func testUUIDv5MatchesRFC4122() {
        let dns = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
        XCTAssertEqual(WatchSyncID.uuidV5(namespace: dns, name: "python.org"),
                       UUID(uuidString: "886313e1-3b8a-5372-9b90-0c9aee199e5d"))
    }

    func testSessionIDsMapToStableUUIDs() {
        // Pinned values: changing them would duplicate every workout already on a watch.
        XCTAssertEqual(WatchSyncID.uuid(forSessionID: "plan-w0-d1-easy"),
                       UUID(uuidString: "d1204eea-e7a0-5ba7-bb47-28824cbc77e2"))
        XCTAssertEqual(WatchSyncID.uuid(forSessionID: "plan-race"), UUID(uuidString: "3508b962-117c-5671-a217-97d1289f4f17"))
        XCTAssertEqual(WatchSyncID.uuid(forSessionID: ""), UUID(uuidString: "ab9b2ce1-9174-5b81-afdb-f1e589be4582"))
        XCTAssertEqual(WatchSyncID.uuid(forSessionID: "séance-☃"), UUID(uuidString: "cc6a61fc-0c82-50c6-95b2-71dd989355b0"))
        XCTAssertNotEqual(WatchSyncID.uuid(forSessionID: "a"), WatchSyncID.uuid(forSessionID: "b"))
    }
}

final class WatchSyncMapperTests: XCTestCase {
    fileprivate typealias F = WatchFixture
    private let zones = WatchSyncZones(heartRate: F.zones)

    // MARK: Window

    func testWindowCoversFourteenCalendarDaysFromTheGivenDay() {
        let now = F.date(2026, 4, 15, 15, 30, tz: F.newYork) // a Wednesday afternoon
        let start = F.date(2026, 4, 15, 0, tz: F.newYork)
        let end = F.date(2026, 4, 29, 0, tz: F.newYork)
        let sessions = [
            F.easySession(id: "before", date: start.addingTimeInterval(-1)),
            F.easySession(id: "first", date: start),
            F.easySession(id: "earlier-today", date: F.date(2026, 4, 15, 6, tz: F.newYork)),
            F.easySession(id: "later-today", date: F.date(2026, 4, 15, 18, tz: F.newYork)),
            F.easySession(id: "last", date: end.addingTimeInterval(-60)),
            F.easySession(id: "after", date: end)
        ]
        let b = WatchSyncMapper.batch(for: sessions, zones: zones, from: now, timeZone: F.newYork)
        XCTAssertEqual(b.windowStart, start)
        XCTAssertEqual(b.windowEnd, end)
        XCTAssertEqual(b.from, now)
        // Today's sessions that have already started are not sent at a past time.
        XCTAssertEqual(b.workouts.map(\.sessionID), ["later-today", "last"])
        XCTAssertEqual(b.skipped, [WatchSyncSkip(sessionID: "first", date: start, reason: .startedBeforeNow),
                                   WatchSyncSkip(sessionID: "earlier-today", date: F.date(2026, 4, 15, 6, tz: F.newYork),
                                                 reason: .startedBeforeNow)])
    }

    func testStartedMeansStartedByThisMinute() {
        let session = F.date(2026, 5, 5, 7, 0)
        let s = F.easySession(id: "e", date: session)
        for (now, sent) in [(session.addingTimeInterval(-61), true), (session.addingTimeInterval(-1), true),
                            (session, false), (session.addingTimeInterval(30), false)] {
            let b = WatchSyncMapper.batch(for: [s], zones: zones, from: now, timeZone: F.utc)
            XCTAssertEqual(b.workouts.count, sent ? 1 : 0, "\(now)")
        }
        // A rest day is skipped as a rest day whenever it is.
        let rest = PlannedWorkout(id: "r", date: session, kind: .rest, durationSeconds: 0)
        XCTAssertEqual(WatchSyncMapper.batch(for: [rest], zones: zones, from: session.addingTimeInterval(60),
                                             timeZone: F.utc).skipped.map(\.reason), [.restDay])
    }

    func testWindowEdgesAreLocalMidnightAcrossDaylightSaving() {
        // US clocks go forward on 2026-03-08, so the window is an hour short of 14 × 24 h.
        let w = WatchSyncMapper.window(from: F.date(2026, 3, 1, 12, tz: F.newYork), timeZone: F.newYork)
        XCTAssertEqual(w.start, F.date(2026, 3, 1, 0, tz: F.newYork))
        XCTAssertEqual(w.end, F.date(2026, 3, 15, 0, tz: F.newYork))
        XCTAssertEqual(w.end.timeIntervalSince(w.start), 14 * 86_400 - 3600)
    }

    func testDaysBelowOneMeanJustTheFirstDay() {
        for days in [0, -3] {
            let w = WatchSyncMapper.window(from: F.date(2026, 5, 4, 9), timeZone: F.utc, days: days)
            XCTAssertEqual(w.end.timeIntervalSince(w.start), 86_400)
        }
        let custom = WatchSyncMapper.window(from: F.date(2026, 5, 4, 9), timeZone: F.utc, days: 7)
        XCTAssertEqual(custom.end, F.date(2026, 5, 11, 0))
    }

    func testScheduleDateIsTheRunnersWallClock() throws {
        // 11:30 UTC on 2026-03-10 is 07:30 in New York (EDT, UTC-4).
        let s = F.easySession(id: "e", date: F.date(2026, 3, 10, 11, 30))
        let w = try F.only(WatchSyncMapper.workout(for: s, zones: zones, timeZone: F.newYork))
        XCTAssertEqual(w.scheduleDate, WatchScheduleDate(year: 2026, month: 3, day: 10, hour: 7, minute: 30))
        XCTAssertEqual(w.id, WatchSyncID.uuid(forSessionID: "e"))
    }

    // MARK: Structure

    func testEasyRunIsOneTimedStepCappedByHeartRate() throws {
        let w = try F.only(WatchSyncMapper.workout(for: F.easySession(id: "e", date: F.date(2026, 5, 5)), zones: zones,
                                                   timeZone: F.utc))
        XCTAssertNil(w.warmup)
        XCTAssertNil(w.cooldown)
        XCTAssertEqual(w.displayName, "Easy run")
        XCTAssertEqual(w.purpose, "Easy run.")
        XCTAssertEqual(w.blocks.count, 1)
        XCTAssertEqual(w.blocks[0].iterations, 1)
        let step = w.blocks[0].steps[0]
        XCTAssertEqual(step.purpose, .work)
        XCTAssertEqual(step.step.goal, .time(seconds: 2400))
        // Ceiling: below zone 3 (0.90 × 160 = 144, exclusive), so 143. Floor: the open floor, 0.5 × LTHR.
        XCTAssertEqual(step.step.alert, WatchAlert(metric: .heartRate, range: 80...143, aggregation: .current))
        XCTAssertEqual(step.step.reason(.speed), .noPaceTarget)
        XCTAssertEqual(step.step.reason(.power), .noPowerData)
        XCTAssertEqual(step.step.reason(.cadence), .noCadenceData)
        XCTAssertNil(step.step.reason(.heartRate))
    }

    func testEasyRunWithAPaceGuideStillAlertsOnHeartRate() throws {
        let pace = PaceTarget(fastestSecondsPerKm: 360, slowestSecondsPerKm: 400)
        let w = try F.only(WatchSyncMapper.workout(for: F.easySession(id: "e", date: F.date(2026, 5, 5), pace: pace),
                                                   zones: zones, timeZone: F.utc))
        let step = w.blocks[0].steps[0].step
        XCTAssertEqual(step.alert?.metric, .heartRate)
        XCTAssertEqual(step.reason(.speed), .oneAlertPerStep(chosen: .heartRate))
    }

    func testIntervalsFoldIntoBlocksWithExactTime() throws {
        let s = F.thresholdSession(date: F.date(2026, 5, 6))
        let w = try F.only(WatchSyncMapper.workout(for: s, zones: zones, timeZone: F.utc))
        XCTAssertEqual(w.displayName, "Threshold")
        XCTAssertEqual(w.warmup?.goal, .time(seconds: 600))
        XCTAssertEqual(w.cooldown?.goal, .time(seconds: 300))
        XCTAssertEqual(w.blocks.map(\.iterations), [2, 1])
        XCTAssertEqual(w.blocks[0].steps.map(\.purpose), [.work, .recovery])
        XCTAssertEqual(w.blocks[1].steps.map(\.purpose), [.work])
        XCTAssertEqual(w.timedSeconds, s.durationSeconds)
        XCTAssertEqual(w.expandedSteps.count, s.prescription!.segments.count)

        // The reps alert on pace (the plan's primary), as a speed range in m/s.
        let rep = w.blocks[0].steps[0].step
        XCTAssertEqual(rep.alert?.metric, .speed)
        XCTAssertEqual(rep.alert?.aggregation, .average)
        XCTAssertEqual(rep.alert!.range.lowerBound, 1000 / 260, accuracy: 1e-9)
        XCTAssertEqual(rep.alert!.range.upperBound, 1000 / 250, accuracy: 1e-9)
        XCTAssertEqual(rep.reason(.heartRate), .oneAlertPerStep(chosen: .speed))
        XCTAssertEqual(w.blocks[1].steps[0].step, rep)

        // Jogs carry no alert: heart rate is still raised from the rep.
        let jog = w.blocks[0].steps[1].step
        XCTAssertNil(jog.alert)
        XCTAssertEqual(jog.omittedAlerts.map(\.reason), Array(repeating: .recoveryStep, count: 4))

        // Warm-up and cool-down keep the easy cap.
        XCTAssertEqual(w.warmup?.alert?.range, 80...143)
    }

    func testPacePrimaryWithoutPaceFallsBackToHeartRate() throws {
        let s = F.thresholdSession(date: F.date(2026, 5, 6), pace: nil, primary: .pace)
        let rep = try F.only(WatchSyncMapper.workout(for: s, zones: zones, timeZone: F.utc)).blocks[0].steps[0].step
        // Zone 4 floor 0.95 × 160 = 152; below zone 5b (1.03 × 160 = 164.8) gives 164.
        XCTAssertEqual(rep.alert, WatchAlert(metric: .heartRate, range: 152...164, aggregation: .current))
        XCTAssertEqual(rep.reason(.speed), .noPaceTarget)
    }

    func testHeartRateFollowsTheRunnersCurrentZonesNotThePlansOldBPM() throws {
        // The plan was built at LTHR 160; the runner's LTHR is now 170.
        let newer = WatchSyncZones(heartRate: HRZones(lthr: 170)!)
        let w = try F.only(WatchSyncMapper.workout(for: F.easySession(id: "e", date: F.date(2026, 5, 5)), zones: newer,
                                                   timeZone: F.utc))
        // 0.90 × 170 = 153 (exclusive) → 152; floor 0.5 × 170 = 85.
        XCTAssertEqual(w.blocks[0].steps[0].step.alert?.range, 85...152)
    }

    func testTargetWithNoCeilingGetsAnOpenTop() throws {
        let rep = F.seg(.work, .vo2max, minutes: 3, hr: F.vo2HR)
        let p = WorkoutPrescription(purpose: "VO2.", phase: .build, segments: [rep], rules: [])
        let s = PlannedWorkout(id: "v", date: F.date(2026, 5, 7), kind: .quality(.intervals), durationSeconds: 180,
                               prescription: p)
        let step = try F.only(WatchSyncMapper.workout(for: s, zones: zones, timeZone: F.utc)).blocks[0].steps[0].step
        // Floor 1.03 × 160 = 164.8 → 165; open top 1.2 × 160 = 192 → 191.
        XCTAssertEqual(step.alert?.range, 165...191)
    }

    func testNoLTHRMeansNoHeartRateAlert() throws {
        let none = WatchSyncZones(heartRate: nil)
        let easy = try F.only(WatchSyncMapper.workout(for: F.easySession(id: "e", date: F.date(2026, 5, 5)), zones: none,
                                                      timeZone: F.utc)).blocks[0].steps[0].step
        XCTAssertNil(easy.alert)
        XCTAssertEqual(easy.reason(.heartRate), .noHeartRateZones)
        XCTAssertEqual(easy.omittedAlerts.count, 4)

        // A rep with a pace target still gets its speed alert.
        let q = try F.only(WatchSyncMapper.workout(for: F.thresholdSession(date: F.date(2026, 5, 6)), zones: none,
                                                   timeZone: F.utc))
        let rep = q.blocks[0].steps[0].step
        XCTAssertEqual(rep.alert?.metric, .speed)
        XCTAssertEqual(rep.reason(.heartRate), .noHeartRateZones)
    }

    // MARK: Power and cadence

    private let power: [HRZone: ClosedRange<Double>] = [.z1: 150...190, .z2: 180...220, .z4: 250...270, .z5a: 265...285]
    private let cadence: [HRZone: ClosedRange<Double>] = [.z1: 160...168, .z2: 164...172]

    func testPowerAndCadenceAreAvailableButOneAlertPerStep() throws {
        let z = WatchSyncZones(heartRate: F.zones, powerWattsByZone: power, cadenceByZone: cadence)
        let step = try F.only(WatchSyncMapper.workout(for: F.easySession(id: "e", date: F.date(2026, 5, 5)), zones: z,
                                                      timeZone: F.utc)).blocks[0].steps[0].step
        XCTAssertEqual(step.alert?.metric, .heartRate)
        XCTAssertEqual(step.reason(.power), .oneAlertPerStep(chosen: .heartRate))
        XCTAssertEqual(step.reason(.cadence), .oneAlertPerStep(chosen: .heartRate))
    }

    func testPreferPowerUsesTheUnionOfTheSpannedZones() throws {
        let z = WatchSyncZones(heartRate: F.zones, powerWattsByZone: power, cadenceByZone: cadence)
        let opts = WatchSyncOptions(alertPreference: .prefer(.power))
        let q = try F.only(WatchSyncMapper.workout(for: F.thresholdSession(date: F.date(2026, 5, 6)), zones: z,
                                                   timeZone: F.utc, options: opts))
        let rep = q.blocks[0].steps[0].step
        XCTAssertEqual(rep.alert, WatchAlert(metric: .power, range: 250...285, aggregation: .current))
        XCTAssertEqual(rep.reason(.speed), .oneAlertPerStep(chosen: .power))
        XCTAssertEqual(rep.reason(.heartRate), .oneAlertPerStep(chosen: .power))
        // Threshold spans z4 to z5a; there's no cadence there.
        XCTAssertEqual(rep.reason(.cadence), .noCadenceData)
        // The warm-up spans z1 to z2: power from both zones.
        XCTAssertEqual(q.warmup?.alert?.range, 150...220)
    }

    func testPreferCadence() throws {
        let z = WatchSyncZones(heartRate: F.zones, cadenceByZone: cadence)
        let opts = WatchSyncOptions(alertPreference: .prefer(.cadence))
        let step = try F.only(WatchSyncMapper.workout(for: F.easySession(id: "e", date: F.date(2026, 5, 5)), zones: z,
                                                      timeZone: F.utc, options: opts)).blocks[0].steps[0].step
        XCTAssertEqual(step.alert, WatchAlert(metric: .cadence, range: 160...172, aggregation: .current))
        XCTAssertEqual(step.reason(.heartRate), .oneAlertPerStep(chosen: .cadence))
    }

    func testPreferredMetricWithoutDataFallsBackToThePlan() throws {
        let opts = WatchSyncOptions(alertPreference: .prefer(.power))
        let step = try F.only(WatchSyncMapper.workout(for: F.easySession(id: "e", date: F.date(2026, 5, 5)), zones: zones,
                                                      timeZone: F.utc, options: opts)).blocks[0].steps[0].step
        XCTAssertEqual(step.alert?.metric, .heartRate)
        XCTAssertEqual(step.reason(.power), .noPowerData)
    }

    func testPartialOrBrokenPowerDataIsLeftOut() throws {
        let opts = WatchSyncOptions(alertPreference: .prefer(.power))
        // Only z1 known, but easy spans z1 to z2.
        let partial = WatchSyncZones(heartRate: F.zones, powerWattsByZone: [.z1: 150...190])
        let a = try F.only(WatchSyncMapper.workout(for: F.easySession(id: "e", date: F.date(2026, 5, 5)), zones: partial,
                                                   timeZone: F.utc, options: opts)).blocks[0].steps[0].step
        XCTAssertEqual(a.reason(.power), .noPowerData)
        for bad in [0...190.0, 150...Double.infinity, -5...10.0] {
            let broken = WatchSyncZones(heartRate: F.zones, powerWattsByZone: [.z1: bad, .z2: 180...220])
            let b = try F.only(WatchSyncMapper.workout(for: F.easySession(id: "e", date: F.date(2026, 5, 5)), zones: broken,
                                                       timeZone: F.utc, options: opts)).blocks[0].steps[0].step
            XCTAssertEqual(b.reason(.power), .invalidRange, "\(bad)")
            XCTAssertEqual(b.alert?.metric, .heartRate)
        }
        // A zero-width band is no range.
        let flat = WatchSyncZones(heartRate: F.zones, powerWattsByZone: [.z1: 200...200, .z2: 200...200])
        let c = try F.only(WatchSyncMapper.workout(for: F.easySession(id: "e", date: F.date(2026, 5, 5)), zones: flat,
                                                   timeZone: F.utc, options: opts)).blocks[0].steps[0].step
        XCTAssertEqual(c.reason(.power), .invalidRange)
    }

    func testBrokenPaceIsLeftOut() throws {
        for pace in [PaceTarget(fastestSecondsPerKm: .nan, slowestSecondsPerKm: 260),
                     PaceTarget(fastestSecondsPerKm: 0, slowestSecondsPerKm: 260),
                     PaceTarget(fastestSecondsPerKm: 250, slowestSecondsPerKm: .infinity),
                     PaceTarget(fastestSecondsPerKm: 250, slowestSecondsPerKm: 250)] {
            let s = F.thresholdSession(date: F.date(2026, 5, 6), pace: pace)
            let rep = try F.only(WatchSyncMapper.workout(for: s, zones: zones, timeZone: F.utc)).blocks[0].steps[0].step
            XCTAssertEqual(rep.reason(.speed), .invalidRange)
            XCTAssertEqual(rep.alert?.metric, .heartRate)
        }
    }

    func testEveryMetricIsEitherTheAlertOrListedOnce() throws {
        let z = WatchSyncZones(heartRate: F.zones, powerWattsByZone: power)
        let w = try F.only(WatchSyncMapper.workout(for: F.thresholdSession(date: F.date(2026, 5, 6)), zones: z,
                                                   timeZone: F.utc))
        for step in w.expandedSteps {
            let metrics = (step.alert.map { [$0.metric] } ?? []) + step.omittedAlerts.map(\.metric)
            XCTAssertEqual(Set(metrics), Set(WatchAlertMetric.allCases))
            XCTAssertEqual(metrics.count, 4)
        }
    }

    // MARK: Sessions without a prescription

    func testSessionWithoutPrescriptionIsOneTimedStep() throws {
        // As the adaptation engine leaves a swap to easy (F4).
        let swapped = F.thresholdSession(date: F.date(2026, 5, 6)).swappedToEasy()
        XCTAssertNil(swapped.prescription)
        let w = try F.only(WatchSyncMapper.workout(for: swapped, zones: zones, timeZone: F.utc))
        XCTAssertNil(w.purpose)
        XCTAssertEqual(w.blocks.count, 1)
        let step = w.blocks[0].steps[0].step
        XCTAssertEqual(step.goal, .time(seconds: swapped.durationSeconds))
        XCTAssertNil(step.intensity)
        XCTAssertEqual(step.alert?.range, 80...143)

        let recovery = PlannedWorkout(id: "r", date: F.date(2026, 5, 7), kind: .recovery, durationSeconds: 1800)
        let r = try F.only(WatchSyncMapper.workout(for: recovery, zones: zones, timeZone: F.utc)).blocks[0].steps[0].step
        // Below zone 2: 0.85 × 160 = 136 → 135.
        XCTAssertEqual(r.alert?.range, 80...135)

        let quality = PlannedWorkout(id: "q", date: F.date(2026, 5, 8), kind: .quality(.fartlek), durationSeconds: 2400)
        let q = try F.only(WatchSyncMapper.workout(for: quality, zones: zones, timeZone: F.utc)).blocks[0].steps[0].step
        XCTAssertNil(q.alert)
        XCTAssertEqual(q.reason(.heartRate), .noHeartRateTarget)
        XCTAssertEqual(q.reason(.speed), .noPaceTarget)
        // Power and cadence bands are looked up by HR zone, and there is none.
        XCTAssertEqual(q.reason(.power), .noHeartRateTarget)
        XCTAssertEqual(q.reason(.cadence), .noHeartRateTarget)
    }

    func testHeartRateRebuildMatchesThePlansZoneEdges() throws {
        // Ties the mapper to PlanHeuristics' convention: with the plan's own
        // zones, the rebuilt range must equal the target's floor and ceiling.
        for category in [RaceCategory.fiveK, .tenK, .half, .marathon] {
            let model = TargetModel(zones: F.zones, category: category, easyPace: nil, thresholdPace: nil,
                                    vo2maxPace: nil, racePace: nil)
            for intensity in WorkoutIntensity.allCases where intensity != .repRecovery {
                let t = model.target(intensity)
                let seg = WorkoutSegment(role: .main, intensity: intensity, durationSeconds: 600, target: t)
                let p = WorkoutPrescription(purpose: "", phase: .build, segments: [seg], rules: [])
                let s = PlannedWorkout(id: "x", date: F.date(2026, 5, 5), kind: .easy, durationSeconds: 600, prescription: p)
                let alert = try F.only(WatchSyncMapper.workout(for: s, zones: zones, timeZone: F.utc))
                    .blocks[0].steps[0].step.alert
                let lo = (t.heartRate.floorBPM ?? WatchSyncHeuristics.openFloorFractionOfLTHR * F.lthr).rounded(.up)
                let hi = (t.heartRate.ceilingBPM ?? WatchSyncHeuristics.openCeilingFractionOfLTHR * F.lthr).rounded(.up) - 1
                XCTAssertEqual(alert, WatchAlert(metric: .heartRate, range: lo...hi, aggregation: .current),
                               "\(category) \(intensity)")
            }
        }
    }

    func testRaceRunsToItsDistance() throws {
        let racePace = PaceTarget(fastestSecondsPerKm: 297, slowestSecondsPerKm: 303)
        let seg = F.seg(.main, .race, minutes: 50, hr: F.hr(.z5a, .z5a, floor: .z5a, ceiling: .z5b), pace: racePace,
                        primary: .pace)
        let p = WorkoutPrescription(purpose: "Race day.", phase: .taper, segments: [seg], rules: [.goalRace])
        let race = PlannedWorkout(id: "plan-race", date: F.date(2026, 5, 10), kind: .race, durationSeconds: 3000,
                                  distanceMeters: 10_000, prescription: p)
        let w = try F.only(WatchSyncMapper.workout(for: race, zones: zones, timeZone: F.utc))
        XCTAssertEqual(w.displayName, "Race")
        XCTAssertEqual(w.blocks[0].steps[0].step.goal, .distance(meters: 10_000))
        XCTAssertEqual(w.blocks[0].steps[0].step.alert?.metric, .speed)

        // Without a valid distance it runs to time; without a prescription, a
        // valid distance is enough even when the duration is broken.
        var noDistance = race
        noDistance.distanceMeters = .nan
        XCTAssertEqual(try F.only(WatchSyncMapper.workout(for: noDistance, zones: zones, timeZone: F.utc))
            .blocks[0].steps[0].step.goal, .time(seconds: 3000))
        let bare = PlannedWorkout(id: "r", date: F.date(2026, 5, 10), kind: .race, durationSeconds: .nan,
                                  distanceMeters: 5000)
        let b = try F.only(WatchSyncMapper.workout(for: bare, zones: zones, timeZone: F.utc)).blocks[0].steps[0].step
        XCTAssertEqual(b.goal, .distance(meters: 5000))
        XCTAssertEqual(b.reason(.heartRate), .noHeartRateTarget)
    }

    func testDistanceOnANonRaceIsNotUsedAsTheGoal() throws {
        var s = F.easySession(id: "e", date: F.date(2026, 5, 5))
        s.distanceMeters = 8000
        XCTAssertEqual(try F.only(WatchSyncMapper.workout(for: s, zones: zones, timeZone: F.utc))
            .blocks[0].steps[0].step.goal, .time(seconds: 2400))
    }

    // MARK: Skips and limits

    func testRestDaysAndBrokenDurationsAreSkippedWithAReason() {
        let day = F.date(2026, 5, 5)
        let rest = PlannedWorkout(id: "rest", date: day, kind: .rest, durationSeconds: 0)
        XCTAssertEqual(WatchSyncMapper.workout(for: rest, zones: zones, timeZone: F.utc), .skipped(.restDay))
        for d in [Double.nan, .infinity, 0, -60] {
            let bad = PlannedWorkout(id: "x", date: day, kind: .easy, durationSeconds: d)
            XCTAssertEqual(WatchSyncMapper.workout(for: bad, zones: zones, timeZone: F.utc), .skipped(.invalidDuration))
            let seg = F.seg(.main, .easy, minutes: 1, hr: F.easyHR)
            let broken = WorkoutSegment(role: .main, intensity: .easy, durationSeconds: d, target: seg.target)
            let p = WorkoutPrescription(purpose: "", phase: .base, segments: [seg, broken], rules: [])
            let withPrescription = PlannedWorkout(id: "y", date: day, kind: .easy, durationSeconds: 60, prescription: p)
            XCTAssertEqual(WatchSyncMapper.workout(for: withPrescription, zones: zones, timeZone: F.utc),
                           .skipped(.invalidDuration))
        }
    }

    func testDuplicateIDsKeepTheFirstAndCapDropsTheLatest() {
        let sessions = (0..<5).map { F.easySession(id: "s\($0)", date: F.date(2026, 5, 4 + $0)) }
            + [F.easySession(id: "s1", date: F.date(2026, 5, 12)),
               PlannedWorkout(id: "rest", date: F.date(2026, 5, 9), kind: .rest, durationSeconds: 0)]
        let b = WatchSyncMapper.batch(for: sessions, zones: zones, from: F.date(2026, 5, 4, 0), timeZone: F.utc,
                                      options: WatchSyncOptions(maxWorkouts: 3))
        XCTAssertEqual(b.workouts.map(\.sessionID), ["s0", "s1", "s2"])
        XCTAssertEqual(b.skipped.map(\.sessionID), ["s3", "s4", "rest", "s1"])
        XCTAssertEqual(b.skipped.map(\.reason), [.overScheduleLimit(limit: 3), .overScheduleLimit(limit: 3), .restDay,
                                                 .duplicateID])

        let none = WatchSyncMapper.batch(for: sessions, zones: zones, from: F.date(2026, 5, 4, 0), timeZone: F.utc,
                                         options: WatchSyncOptions(maxWorkouts: -1))
        XCTAssertTrue(none.workouts.isEmpty)
        XCTAssertEqual(none.skipped.filter { $0.reason == .overScheduleLimit(limit: 0) }.count, 5)
    }

    func testEmptyInputGivesAnEmptyBatch() {
        let b = WatchSyncMapper.batch(for: [], zones: zones, from: F.date(2026, 5, 4), timeZone: F.utc)
        XCTAssertTrue(b.workouts.isEmpty)
        XCTAssertTrue(b.skipped.isEmpty)
    }

    func testSameDayTiesAreOrderedByID() {
        let day = F.date(2026, 5, 5)
        let b = WatchSyncMapper.batch(for: [F.easySession(id: "b", date: day), F.easySession(id: "a", date: day)],
                                      zones: zones, from: F.date(2026, 5, 5, 0), timeZone: F.utc)
        XCTAssertEqual(b.workouts.map(\.sessionID), ["a", "b"])
    }

    // MARK: Folding

    func testFoldFindsRepeats() {
        let a = F.seg(.work, .threshold, minutes: 8, hr: F.thresholdHR)
        let j = F.seg(.jog, .repRecovery, minutes: 2, hr: F.easyHR)
        let x = F.seg(.main, .easy, minutes: 10, hr: F.easyHR)
        func folded(_ s: [WorkoutSegment]) -> [String] {
            WatchSyncMapper.fold(s).map { "\($0.pattern.map { $0 == a ? "a" : $0 == j ? "j" : "x" }.joined())×\($0.iterations)" }
        }
        XCTAssertEqual(folded([]), [])
        XCTAssertEqual(folded([x]), ["x×1"])
        XCTAssertEqual(folded([a, a, a]), ["a×3"])
        XCTAssertEqual(folded([a, j, a, j, a]), ["aj×2", "a×1"])
        XCTAssertEqual(folded([a, j, a, j, a, j]), ["aj×3"])
        XCTAssertEqual(folded([x, a, j, a, j]), ["x×1", "aj×2"])
        XCTAssertEqual(folded([x, a, j]), ["xaj×1"])
        XCTAssertEqual(folded([a, j, x, a, j]), ["ajxaj×1"])
    }

    func testWarmUpAndCoolDownOnlyMapToWorkoutKitsWarmUpAndCoolDown() throws {
        let warm = F.seg(.warmUp, .easy, minutes: 10, hr: F.easyHR)
        let cool = F.seg(.coolDown, .easy, minutes: 5, hr: F.easyHR)
        let p = WorkoutPrescription(purpose: "", phase: .base, segments: [warm, cool], rules: [])
        let s = PlannedWorkout(id: "wc", date: F.date(2026, 5, 5), kind: .easy, durationSeconds: 900, prescription: p)
        let w = try F.only(WatchSyncMapper.workout(for: s, zones: zones, timeZone: F.utc))
        XCTAssertEqual(w.warmup?.goal, .time(seconds: 600))
        XCTAssertEqual(w.cooldown?.goal, .time(seconds: 300))
        XCTAssertTrue(w.blocks.isEmpty)
        XCTAssertEqual(w.timedSeconds, 900)

        // A lone cool-down is the run itself.
        let lone = WorkoutPrescription(purpose: "", phase: .base, segments: [cool], rules: [])
        let l = try F.only(WatchSyncMapper.workout(for: PlannedWorkout(id: "c", date: F.date(2026, 5, 5), kind: .easy,
                                                                       durationSeconds: 300, prescription: lone),
                                                   zones: zones, timeZone: F.utc))
        XCTAssertNil(l.cooldown)
        XCTAssertEqual(l.blocks.count, 1)
    }

    func testLoneWarmUpOrCoolDownIsNotPulledOut() throws {
        let warm = F.seg(.warmUp, .easy, minutes: 10, hr: F.easyHR)
        let p = WorkoutPrescription(purpose: "", phase: .base, segments: [warm], rules: [])
        let s = PlannedWorkout(id: "w", date: F.date(2026, 5, 5), kind: .easy, durationSeconds: 600, prescription: p)
        let w = try F.only(WatchSyncMapper.workout(for: s, zones: zones, timeZone: F.utc))
        XCTAssertNil(w.warmup)
        XCTAssertEqual(w.blocks.count, 1)
        XCTAssertEqual(w.timedSeconds, 600)

        // Long run with a steady finish: one block, both steps, no cool-down.
        let main = F.seg(.main, .easy, minutes: 70, hr: F.easyHR)
        let finish = F.seg(.finish, .steady, minutes: 15, hr: F.hr(.z3, .z3, floor: .z3, ceiling: .z4))
        let lp = WorkoutPrescription(purpose: "Long.", phase: .build, segments: [main, finish], rules: [.longRunShare])
        let long = PlannedWorkout(id: "l", date: F.date(2026, 5, 9), kind: .long, durationSeconds: 85 * 60, prescription: lp)
        let lw = try F.only(WatchSyncMapper.workout(for: long, zones: zones, timeZone: F.utc))
        XCTAssertEqual(lw.blocks.map(\.iterations), [1])
        XCTAssertEqual(lw.blocks[0].steps.count, 2)
        // Steady: zone 3 floor 144, below zone 4 (152) → 151.
        XCTAssertEqual(lw.blocks[0].steps[1].step.alert?.range, 144...151)
    }

    // MARK: A whole plan

    func testRealPlanMapsDeterministicallyWithExactDurations() throws {
        let monday = F.date(2026, 6, 1, 0)
        let race = F.date(2026, 8, 9, 8) // a Sunday, ten weeks on
        let input = PlanInput(raceDistanceMeters: Distance.tenK, raceDate: race, startDate: monday,
                              trainingDays: [.tuesday, .thursday, .saturday, .sunday], longRunDay: .sunday,
                              recentWeeklySeconds: 240 * 60, recentLongRunSeconds: 80 * 60,
                              heartRateZones: HRZones(lthr: 165),
                              easyPace: EasyPaceSample(secondsPerKm: 360, heartRate: 138),
                              fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: 24 * 60))
        let result = PlanBuilder.build(input, timeZone: F.utc)
        let plan = try XCTUnwrap(result.plan, "\(result.issues)")
        let z = WatchSyncZones(heartRate: HRZones(lthr: 165))

        for from in [monday, F.date(2026, 6, 10, 12), F.date(2026, 7, 30, 6)] {
            let b = WatchSyncMapper.batch(for: plan, zones: z, from: from, timeZone: F.utc)
            XCTAssertEqual(b, WatchSyncMapper.batch(for: plan, zones: z, from: from, timeZone: F.utc))
            let expected = plan.workouts.filter {
                $0.date >= b.windowStart && $0.date < b.windowEnd && $0.kind != .rest
                    && !WatchScheduleDate($0.date, timeZone: F.utc).hasStarted(by: from, timeZone: F.utc)
            }
            XCTAssertFalse(expected.isEmpty)
            XCTAssertEqual(b.workouts.map(\.sessionID), expected.map(\.id))
            for (w, s) in zip(b.workouts, expected) {
                XCTAssertEqual(w.id, WatchSyncID.uuid(forSessionID: s.id))
                if s.kind != .race { XCTAssertEqual(w.timedSeconds, s.durationSeconds, accuracy: 1e-6, s.id) }
                for step in w.expandedSteps {
                    XCTAssertEqual(step.omittedAlerts.count + (step.alert == nil ? 0 : 1), 4)
                    if let a = step.alert { XCTAssertLessThan(a.range.lowerBound, a.range.upperBound) }
                }
                // Every non-jog step of a run the plan guides by heart rate has an alert.
                if s.kind == .easy || s.kind == .long {
                    XCTAssertTrue(w.expandedSteps.allSatisfy { $0.alert != nil }, s.id)
                }
            }
        }
        // The race week window includes the race, run to its distance.
        let last = WatchSyncMapper.batch(for: plan, zones: z, from: F.date(2026, 8, 3), timeZone: F.utc)
        let raceWorkout = try XCTUnwrap(last.workouts.first { $0.sessionID == "plan-race" })
        XCTAssertEqual(raceWorkout.expandedSteps.map(\.goal), [.distance(meters: Distance.tenK)])
    }
}

final class WatchSyncReconcilerTests: XCTestCase {
    fileprivate typealias F = WatchFixture
    private let zones = WatchSyncZones(heartRate: F.zones)

    private func batch(_ sessions: [PlannedWorkout], from: Date) -> WatchSyncBatch {
        WatchSyncMapper.batch(for: sessions, zones: zones, from: from, timeZone: F.utc)
    }

    private func scheduled(_ id: String, _ d: Date, done: Bool = false) -> WatchScheduledWorkout {
        WatchScheduledWorkout(id: WatchSyncID.uuid(forSessionID: id), date: WatchScheduleDate(d, timeZone: F.utc),
                              isComplete: done)
    }

    func testResyncReplacesInsteadOfDuplicating() {
        let from = F.date(2026, 5, 4, 6)
        let b = batch([F.easySession(id: "a", date: F.date(2026, 5, 5)), F.easySession(id: "b", date: F.date(2026, 5, 7))],
                      from: from)
        // First sync: nothing on the watch.
        let first = WatchSyncReconciler.changes(existing: [], batch: b, timeZone: F.utc)
        XCTAssertEqual(first.schedule.map(\.sessionID), ["a", "b"])
        XCTAssertTrue(first.remove.isEmpty)

        // Second sync of the same batch: each one is replaced, never added twice.
        let onWatch = [scheduled("a", F.date(2026, 5, 5)), scheduled("b", F.date(2026, 5, 7))]
        let again = WatchSyncReconciler.changes(existing: onWatch, batch: b, timeZone: F.utc)
        XCTAssertEqual(Set(again.remove), Set(onWatch))
        XCTAssertEqual(again.schedule.map(\.sessionID), ["a", "b"])
        XCTAssertTrue(again.keep.isEmpty)
    }

    func testMovedSessionIsRemovedFromItsOldDay() {
        let from = F.date(2026, 5, 4)
        let b = batch([F.easySession(id: "a", date: F.date(2026, 5, 6))], from: from)
        // It sat on yesterday (before the window) and on a later day.
        let old = [scheduled("a", F.date(2026, 5, 3)), scheduled("gone", F.date(2026, 5, 20))]
        let c = WatchSyncReconciler.changes(existing: old, batch: b, timeZone: F.utc)
        XCTAssertEqual(c.remove, old)
        XCTAssertEqual(c.schedule.map(\.sessionID), ["a"])
    }

    func testCompletedWorkoutsStayAndAreNotScheduledAgain() {
        let from = F.date(2026, 5, 4)
        let b = batch([F.easySession(id: "a", date: F.date(2026, 5, 4, 18)), F.easySession(id: "b", date: F.date(2026, 5, 6))],
                      from: from)
        let done = scheduled("a", F.date(2026, 5, 4, 7), done: true)
        let leftover = scheduled("a", F.date(2026, 5, 4, 18)) // an incomplete copy of the same session
        let missed = scheduled("old", F.date(2026, 5, 1))
        let c = WatchSyncReconciler.changes(existing: [missed, leftover, done], batch: b, timeZone: F.utc)
        XCTAssertEqual(c.keep, [done])
        // The missed workout from before the window is stale and goes too.
        XCTAssertEqual(c.remove, [missed, leftover])
        XCTAssertEqual(c.schedule.map(\.sessionID), ["b"])
        XCTAssertEqual(c.skipped, [WatchSyncSkip(sessionID: "a", date: F.date(2026, 5, 4, 18), reason: .alreadyCompleted)])
    }

    func testOnlyTodaysStartedSessionStillInThePlanIsKept() {
        let from = F.date(2026, 5, 4, 9)
        // "x" started at 07:00 and is still in the plan; "dropped" started too but the plan no longer has it.
        let b = batch([F.easySession(id: "x", date: F.date(2026, 5, 4, 7))], from: from)
        XCTAssertEqual(b.startedBeforeNowIDs, [WatchSyncID.uuid(forSessionID: "x")])
        let startedToday = scheduled("x", F.date(2026, 5, 4, 7))
        let dropped = scheduled("dropped", F.date(2026, 5, 4, 6))
        let laterToday = scheduled("z", F.date(2026, 5, 4, 18))
        let past = scheduled("y", F.date(2026, 5, 3, 23, 59))
        let c = WatchSyncReconciler.changes(existing: [startedToday, dropped, laterToday, past], batch: b, timeZone: F.utc)
        XCTAssertEqual(c.keep, [startedToday])
        XCTAssertEqual(c.remove, [past, dropped, laterToday])
        XCTAssertTrue(c.schedule.isEmpty)
        XCTAssertEqual(c.skipped.map(\.reason), [.startedBeforeNow])
    }

    func testSessionDoneEarlierTodayIsReportedAsCompleted() {
        let from = F.date(2026, 5, 4, 9)
        let b = batch([F.easySession(id: "a", date: F.date(2026, 5, 4, 7))], from: from)
        let done = scheduled("a", F.date(2026, 5, 4, 7), done: true)
        let c = WatchSyncReconciler.changes(existing: [done], batch: b, timeZone: F.utc)
        XCTAssertEqual(c.keep, [done])
        XCTAssertEqual(c.skipped, [WatchSyncSkip(sessionID: "a", date: F.date(2026, 5, 4, 7), reason: .alreadyCompleted)])
    }

    func testTodaysStartedWorkoutMovedByThePlanIsReplaced() {
        // The 07:00 session moved to tomorrow: its old copy goes, the new one is sent.
        let from = F.date(2026, 5, 4, 9)
        let b = batch([F.easySession(id: "a", date: F.date(2026, 5, 5))], from: from)
        let old = scheduled("a", F.date(2026, 5, 4, 7))
        let c = WatchSyncReconciler.changes(existing: [old], batch: b, timeZone: F.utc)
        XCTAssertEqual(c.remove, [old])
        XCTAssertEqual(c.schedule.map(\.sessionID), ["a"])
        XCTAssertTrue(c.keep.isEmpty)
    }

    // MARK: Scheduler limit

    private func days(_ n: Int, from day: Int = 5) -> [PlannedWorkout] {
        (0..<n).map { F.easySession(id: "s\($0)", date: F.date(2026, 5, day + $0)) }
    }

    /// Completed workouts from earlier today, which stay and fill slots.
    private func doneToday(_ n: Int) -> [WatchScheduledWorkout] {
        (0..<n).map { scheduled("done\($0)", F.date(2026, 5, 4, 1, $0), done: true) }
    }

    func testRoomIsTheLimitLessWhatStays() {
        XCTAssertEqual(WatchSyncReconciler.room(maxScheduled: 15, kept: 3), 12)
        XCTAssertEqual(WatchSyncReconciler.room(maxScheduled: 15, kept: 15), 0)
        XCTAssertEqual(WatchSyncReconciler.room(maxScheduled: 15, kept: 20), 0)
        XCTAssertEqual(WatchSyncReconciler.room(maxScheduled: -1, kept: 0), 0)
        XCTAssertEqual(WatchSyncReconciler.room(maxScheduled: 5, kept: -2), 5)
    }

    func testOldCompletedAndMissedWorkoutsFreeTheirSlots() {
        let from = F.date(2026, 5, 4, 9)
        let b = batch([F.easySession(id: "today", date: F.date(2026, 5, 4, 7))] + days(9), from: from)
        let oldDone = (0..<20).map { scheduled("old\($0)", F.date(2026, 4, 1 + $0), done: true) }
        let missed = (0..<4).map { scheduled("missed\($0)", F.date(2026, 4, 27 + $0)) }
        let started = scheduled("today", F.date(2026, 5, 4, 7))
        let c = WatchSyncReconciler.changes(existing: oldDone + missed + doneToday(3) + [started], batch: b,
                                            timeZone: F.utc, maxScheduled: 10)
        XCTAssertEqual(Set(c.remove), Set(oldDone + missed))
        XCTAssertEqual(c.keep.count, 4)
        // 10 slots less 3 completed today and today's started workout leaves 6.
        XCTAssertEqual(c.schedule.map(\.sessionID), ["s0", "s1", "s2", "s3", "s4", "s5"])
        XCTAssertEqual(c.skipped.filter { $0.reason == .overScheduleLimit(limit: 6) }.map(\.sessionID), ["s6", "s7", "s8"])
        XCTAssertLessThanOrEqual(c.keep.count + c.schedule.count, 10)
    }

    func testCapExactlyFull() {
        let b = batch(days(7), from: F.date(2026, 5, 4, 9))
        let c = WatchSyncReconciler.changes(existing: doneToday(3), batch: b, timeZone: F.utc, maxScheduled: 10)
        XCTAssertEqual(c.schedule.count, 7)
        XCTAssertEqual(c.keep.count + c.schedule.count, 10)
        XCTAssertTrue(c.skipped.isEmpty)
    }

    func testNoRoomSchedulesNothing() {
        // Workouts kept inside the window fill the limit.
        let b = batch(days(4), from: F.date(2026, 5, 4, 9))
        let c = WatchSyncReconciler.changes(existing: doneToday(2), batch: b, timeZone: F.utc, maxScheduled: 2)
        XCTAssertTrue(c.schedule.isEmpty)
        XCTAssertEqual(c.skipped.map(\.reason), Array(repeating: .overScheduleLimit(limit: 0), count: 4))
        XCTAssertTrue(c.remove.isEmpty)
        // A session the watch shows done is reported as done, not as over the limit.
        let withDone = batch(days(2), from: F.date(2026, 5, 4, 9))
        let c2 = WatchSyncReconciler.changes(existing: doneToday(2) + [scheduled("s0", F.date(2026, 5, 5), done: true)],
                                             batch: withDone, timeZone: F.utc, maxScheduled: 2)
        XCTAssertEqual(c2.skipped.map(\.reason), [.alreadyCompleted, .overScheduleLimit(limit: 0)])
    }

    func testDailySyncsWithEveryRunCompletedNeverFillTheCap() {
        // Six weeks of a run every day at 07:00; the runner does each one.
        let sessions = (0..<42).map { F.easySession(id: "d\($0)", date: F.date(2026, 5, 4 + $0)) }
        let cap = 15
        var watch: [WatchScheduledWorkout] = []
        for day in 0..<28 {
            // Sync before the run and again after it.
            for hour in [6, 12] {
                let b = batch(sessions, from: F.date(2026, 5, 4 + day, hour))
                let c = WatchSyncReconciler.changes(existing: watch, batch: b, timeZone: F.utc, maxScheduled: cap)
                XCTAssertGreaterThan(c.schedule.count, 0, "day \(day) \(hour):00")
                let removed = Set(c.remove)
                watch = watch.filter { !removed.contains($0) }
                    + c.schedule.map { WatchScheduledWorkout(id: $0.id, date: $0.scheduleDate, isComplete: false) }
                XCTAssertLessThanOrEqual(watch.count, cap, "day \(day) \(hour):00")
                XCTAssertEqual(Set(watch.map(\.id)).count, watch.count, "no duplicates")
                if hour == 6 {
                    // The run happens at 07:00 and the watch marks it done.
                    let today = WatchSyncID.uuid(forSessionID: "d\(day)")
                    watch = watch.map { $0.id == today ? WatchScheduledWorkout(id: $0.id, date: $0.date, isComplete: true) : $0 }
                    XCTAssertTrue(watch.contains { $0.id == today && $0.isComplete }, "day \(day)")
                } else {
                    XCTAssertTrue(c.skipped.contains { $0.sessionID == "d\(day)" && $0.reason == .alreadyCompleted })
                }
            }
        }
    }

    func testScheduleDatesCompareChronologically() {
        let a = WatchScheduleDate(year: 2026, month: 12, day: 31, hour: 23, minute: 59)
        let b = WatchScheduleDate(year: 2027, month: 1, day: 1, hour: 0, minute: 0)
        XCTAssertLessThan(a, b)
        XCTAssertLessThan(WatchScheduleDate(year: 2026, month: 5, day: 4, hour: 7, minute: 0),
                          WatchScheduleDate(year: 2026, month: 5, day: 4, hour: 7, minute: 1))
        XCTAssertFalse(a < a)
    }
}
