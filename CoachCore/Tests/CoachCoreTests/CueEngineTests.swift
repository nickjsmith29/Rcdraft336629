import XCTest
@testable import CoachCore

/// Rule-by-rule tests of `CueEngine` on hand-made smoothed inputs.
final class CueEngineTests: XCTestCase {
    private typealias S = CueTestSupport

    // Threshold test segment: band 327...337 s/km (about 5:25 to 5:36 per km).
    private let seg = S.paceSegment()

    private func cues(_ ds: [CueDecision]) -> [CueDecision] { ds.filter { $0.action != .none } }

    // MARK: Basic cues and timing

    func testNoCueInFirstSixtySecondsThenSustainedWindow() {
        var e = CueEngine(segment: seg)
        let ds = S.drive(&e, from: 0, to: 200, pace: 380, grade: 0)  // far too slow from the start
        for d in ds.prefix(60) {
            XCTAssertEqual(d.action, .none)
            XCTAssertEqual(d.reason.rule, .startupWindow)
        }
        let fired = cues(ds)
        XCTAssertEqual(fired.first?.time, 85, "the sustained window (25 s) counts from second 60")
        XCTAssertEqual(fired.first?.action, .speedUp)
        XCTAssertEqual(fired.first?.phrase, "Speed up")
        let r = fired.first!.reason
        XCTAssertEqual(r.rule, .sustainedTooSlow)
        XCTAssertEqual(r.paceSecondsPerKm ?? .nan, 380, accuracy: 1e-9)
        XCTAssertEqual(r.bandFastestSecondsPerKm ?? .nan, 327, accuracy: 1e-9)
        XCTAssertEqual(r.bandSlowestSecondsPerKm ?? .nan, 337, accuracy: 1e-9)
        XCTAssertEqual(r.slowTriggerSecondsPerKm ?? .nan, 337 * 1.02, accuracy: 1e-9)
        // On the flat the fast edge still covers f(-0.25%) (the grade uncertainty).
        XCTAssertEqual(r.fastTriggerSecondsPerKm ?? .nan, 327 * (1 - 0.12 / 9 / 4) * 0.98, accuracy: 1e-9)
        XCTAssertEqual(r.gradeUncertainty, 0.0025, accuracy: 1e-12)
        XCTAssertEqual(r.deviationSeconds ?? .nan, 25, accuracy: 1e-9)
        XCTAssertEqual(r.gradeFactor, 1)
        XCTAssertFalse(r.usedFlatFallback)
        XCTAssertEqual(r.segmentSeconds, 85)
        // Between 60 and 85 the decision says why it is quiet.
        XCTAssertEqual(ds[70].reason.rule, .deviationPending)
        XCTAssertEqual(ds[70].reason.deviationSeconds ?? .nan, 10, accuracy: 1e-9)
    }

    func testSlowDownWhenTooFast() {
        var e = CueEngine(segment: seg)
        let fired = cues(S.drive(&e, from: 0, to: 120, pace: 300, grade: 0))
        XCTAssertEqual(fired.first?.action, .slowDown)
        XCTAssertEqual(fired.first?.phrase, "Slow down")
        XCTAssertEqual(fired.first?.reason.rule, .sustainedTooFast)
        XCTAssertEqual(fired.first?.time, 85)
    }

    func testInsideTheBandAndInsideTheLeaveMarginIsQuiet() {
        var e = CueEngine(segment: seg)
        XCTAssertTrue(cues(S.drive(&e, from: 0, to: 300, pace: 332, grade: 0)).isEmpty)
        // Slightly outside the band but inside the 2% leave margin: still quiet.
        var e2 = CueEngine(segment: seg)
        let ds = S.drive(&e2, from: 0, to: 300, pace: 343, grade: 0)
        XCTAssertTrue(cues(ds).isEmpty)
        XCTAssertEqual(ds.last?.reason.rule, .withinTarget)
        // Just past it: cued.
        var e3 = CueEngine(segment: seg)
        XCTAssertEqual(cues(S.drive(&e3, from: 0, to: 300, pace: 346, grade: 0)).first?.action, .speedUp)
    }

    func testBriefDeviationIsIgnored() {
        var e = CueEngine(segment: seg)
        S.drive(&e, from: 0, to: 99, pace: 332)
        let ds = S.drive(&e, from: 100, to: 120, pace: 400)  // 21 s outside
        XCTAssertTrue(cues(ds).isEmpty)
        XCTAssertTrue(cues(S.drive(&e, from: 121, to: 300, pace: 332)).isEmpty)
    }

    func testPausedOrMissingPaceResetsTheTimer() {
        var e = CueEngine(segment: seg)
        S.drive(&e, from: 0, to: 79, pace: 332)
        S.drive(&e, from: 80, to: 100, pace: 400)       // 21 s out
        S.drive(&e, from: 101, to: 103, pace: nil)       // 3 s with no estimate
        let ds = S.drive(&e, from: 104, to: 120, pace: 400)
        XCTAssertTrue(cues(ds).isEmpty, "continuity broke, the 25 s count starts again")
        XCTAssertFalse(cues(S.drive(&e, from: 121, to: 140, pace: 400)).isEmpty)
    }

    // MARK: Grade-adjusted band

    func testClimbIsOnTargetWhenTheBandIsGradeAdjusted() {
        // 5% uphill: f = 1.169; a runner at 1.169 x the middle of the band is on target.
        let f = DefaultGradePaceCurve().factor(grade: 0.05)
        var e = CueEngine(segment: seg)
        let ds = S.drive(&e, from: 0, to: 300, pace: 332 * f, grade: 0.05)
        XCTAssertTrue(cues(ds).isEmpty)
        XCTAssertEqual(ds.last?.reason.gradeFactor ?? .nan, f, accuracy: 1e-12)
        XCTAssertEqual(ds.last?.reason.bandSlowestSecondsPerKm ?? .nan, 337 * f, accuracy: 1e-9)
        XCTAssertEqual(ds.last?.reason.grade, 0.05)
        // The same pace on the flat is "speed up".
        var flat = CueEngine(segment: seg)
        XCTAssertEqual(cues(S.drive(&flat, from: 0, to: 300, pace: 332 * f, grade: 0)).first?.action, .speedUp)
    }

    func testGradeUncertaintyWidensTheBandBothWays() {
        var cfg = CueEngineConfig()
        cfg.leaveMarginFraction = 0
        cfg.gradeUncertainty = 0.01
        var e = CueEngine(segment: seg, config: cfg)
        // 5% uphill: a pace 4% slower than the nominal slow edge is inside f(0.06).
        let f5 = DefaultGradePaceCurve().factor(grade: 0.05), f6 = DefaultGradePaceCurve().factor(grade: 0.06)
        XCTAssertGreaterThan(f6, f5 * 1.04)
        let ds = S.drive(&e, from: 0, to: 200, pace: 337 * f5 * 1.04, grade: 0.05)
        XCTAssertTrue(cues(ds).isEmpty)
        XCTAssertEqual(ds.last?.reason.slowTriggerSecondsPerKm ?? .nan, 337 * f6, accuracy: 1e-9)
        // Nominal band is still what the reason reports.
        XCTAssertEqual(ds.last?.reason.bandSlowestSecondsPerKm ?? .nan, 337 * f5, accuracy: 1e-9)
    }

    func testMissingGradeFallsBackToFlatAndSaysSo() {
        var e = CueEngine(segment: seg)
        let ds = S.drive(&e, from: 0, to: 120, pace: 332 * 1.169, grade: nil)
        XCTAssertTrue(ds.allSatisfy { $0.reason.usedFlatFallback })
        XCTAssertTrue(ds.allSatisfy { $0.reason.grade == nil && $0.reason.gradeFactor == 1 })
        XCTAssertEqual(ds.last?.reason.bandSlowestSecondsPerKm, 337)
        let fired = cues(ds)
        XCTAssertEqual(fired.first?.action, .speedUp, "flat targets: the climbing runner looks slow")
        XCTAssertTrue(fired.first?.reason.usedFlatFallback ?? false)
    }

    func testStaleOrNonFiniteGradeCountsAsMissing() {
        var e = CueEngine(segment: seg)
        let old = S.grade(0.05, time: 0)
        let d = e.evaluate(time: 100, pace: S.estimate(pace: 332, time: 100), grade: old, heartRate: nil)
        XCTAssertTrue(d.reason.usedFlatFallback)
        var e2 = CueEngine(segment: seg)
        let nan = GradeEstimate(time: 100, grade: .nan, spanMeters: 90)
        XCTAssertTrue(e2.evaluate(time: 100, pace: S.estimate(pace: 332, time: 100), grade: nan, heartRate: nil).reason.usedFlatFallback)
    }

    func testCustomCurveSeam() {
        struct Doubling: GradePaceCurve { func factor(grade: Double) -> Double { 2 } }
        var e = CueEngine(segment: seg, curve: Doubling())
        let d = S.drive(&e, from: 0, to: 70, pace: 600, grade: 0.01).last!
        XCTAssertEqual(d.reason.gradeFactor, 2)
        XCTAssertEqual(d.reason.bandSlowestSecondsPerKm ?? .nan, 674, accuracy: 1e-9)
    }

    // MARK: Descents (pending #83)

    func testNoSpeedUpOnADescentButSlowDownIsAllowed() {
        var e = CueEngine(segment: seg)
        let down = S.drive(&e, from: 0, to: 300, pace: 345, grade: -0.05)
        XCTAssertTrue(cues(down).isEmpty)
        XCTAssertEqual(down.last?.reason.rule, .descentNoSpeedUp)
        XCTAssertEqual(down.last?.reason.grade, -0.05)
        // Too fast on the descent band (f(-5%) = 0.933: band 305...314.5) still cues "slow down".
        var e2 = CueEngine(segment: seg)
        let fired = cues(S.drive(&e2, from: 0, to: 300, pace: 280, grade: -0.05))
        XCTAssertEqual(fired.first?.action, .slowDown)
        // A mild downhill above the threshold (-1%) still allows "speed up".
        var e3 = CueEngine(segment: seg)
        XCTAssertEqual(cues(S.drive(&e3, from: 0, to: 300, pace: 345, grade: -0.01)).first?.action, .speedUp)
    }

    func testSpeedUpNeedsAFreshSustainedWindowAfterADescent() {
        var e = CueEngine(segment: seg)
        S.drive(&e, from: 0, to: 199, pace: 360, grade: -0.05)  // slow on the descent, quiet
        let flat = S.drive(&e, from: 200, to: 260, pace: 360, grade: 0)
        // The slow time on the descent does not count: a fresh 25 s window starts when it ends.
        XCTAssertEqual(cues(flat).first?.time, 225)
    }

    // MARK: Heart rate

    func testEaseOffAboveCeilingOnEasyEvenWhenPaceIsOnTarget() {
        let easy = S.easySegment(fastest: 360, slowest: 403, ceiling: 150)
        var e = CueEngine(segment: easy)
        let ds = S.drive(&e, from: 0, to: 200, pace: 380, grade: 0, heartRate: 156)
        let fired = cues(ds)
        XCTAssertEqual(fired.first?.action, .easeOff)
        XCTAssertEqual(fired.first?.phrase, "Ease off")
        XCTAssertEqual(fired.first?.time, 85)
        XCTAssertEqual(fired.first?.reason.rule, .sustainedHeartRateOverCeiling)
        XCTAssertEqual(fired.first?.reason.heartRate, 156)
        XCTAssertEqual(fired.first?.reason.heartRateCeiling, 150)
        // The reminder comes 90 s after the first cue, not before.
        XCTAssertEqual(fired.dropFirst().first?.time, 175)
        XCTAssertEqual(fired.count, 2, "one reminder at most (maxReminders)")
    }

    func testHeartRateBelowCeilingIsQuiet() {
        let easy = S.easySegment(ceiling: 150)
        var e = CueEngine(segment: easy)
        XCTAssertTrue(cues(S.drive(&e, from: 0, to: 300, pace: 380, grade: 0, heartRate: 149)).isEmpty)
        var e2 = CueEngine(segment: easy)
        XCTAssertTrue(cues(S.drive(&e2, from: 0, to: 300, pace: 380, grade: 0, heartRate: 120)).isEmpty)
    }

    /// `HeartRateTarget.ceilingBPM` is exclusive ("stay below", as `HRZones.easyCeiling`: a bpm equal to it is
    /// already the next zone), so HR equal to the ceiling held for the sustained window cues "ease off".
    func testHeartRateEqualToTheCeilingCuesEaseOff() {
        var e = CueEngine(segment: S.easySegment(ceiling: 150))
        let fired = cues(S.drive(&e, from: 0, to: 200, pace: 380, grade: 0, heartRate: 150))
        XCTAssertEqual(fired.first?.action, .easeOff)
        XCTAssertEqual(fired.first?.time, 85)
        // And it counts as back under only below the ceiling less the margin: 147 is still over, 146 is under.
        var e2 = CueEngine(segment: S.easySegment(ceiling: 150))
        S.drive(&e2, from: 0, to: 100, pace: 380, grade: 0, heartRate: 150)
        XCTAssertTrue(cues(S.drive(&e2, from: 101, to: 160, pace: 380, grade: 0, heartRate: 147)).isEmpty)
        let again = cues(S.drive(&e2, from: 161, to: 240, pace: 380, grade: 0, heartRate: 150))
        XCTAssertEqual(again.map(\.time), [175])
    }

    func testRecoveryUsesCeilingEvenWhenPacePrimary() {
        var seg = S.paceSegment(intensity: .recovery, ceiling: 140)
        seg = WorkoutSegment(role: seg.role, intensity: .recovery, durationSeconds: 600, target: seg.target)
        var e = CueEngine(segment: seg)
        let fired = cues(S.drive(&e, from: 0, to: 200, pace: 332, grade: 0, heartRate: 150))
        XCTAssertEqual(fired.first?.action, .easeOff)
    }

    func testPacePrimaryHardSegmentIgnoresTheCeiling() {
        var e = CueEngine(segment: S.paceSegment(ceiling: 150))
        XCTAssertTrue(cues(S.drive(&e, from: 0, to: 300, pace: 332, grade: 0, heartRate: 190)).isEmpty)
    }

    func testNoCeilingNoHeartRateRule() {
        var e = CueEngine(segment: S.easySegment(ceiling: nil))
        XCTAssertTrue(cues(S.drive(&e, from: 0, to: 300, pace: 380, grade: 0, heartRate: 200)).isEmpty)
    }

    func testNoSpeedUpOnHeartRatePrimarySegments() {
        var e = CueEngine(segment: S.easySegment(fastest: 360, slowest: 403, ceiling: 150))
        let ds = S.drive(&e, from: 0, to: 300, pace: 470, grade: 0, heartRate: 120)
        XCTAssertTrue(cues(ds).isEmpty)
        XCTAssertEqual(ds.last?.reason.rule, .heartRatePrimaryNoSpeedUp)
        // Faster than the easy band still cues "slow down".
        var e2 = CueEngine(segment: S.easySegment(fastest: 360, slowest: 403, ceiling: 150))
        XCTAssertEqual(cues(S.drive(&e2, from: 0, to: 300, pace: 330, grade: 0, heartRate: 120)).first?.action, .slowDown)
    }

    func testHeartRateOutranksPaceAndClearsAPendingSlowDown() {
        var e = CueEngine(segment: S.easySegment(fastest: 360, slowest: 403, ceiling: 150))
        let fired = cues(S.drive(&e, from: 0, to: 85, pace: 330, grade: 0, heartRate: 160))
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired.first?.action, .easeOff)
    }

    func testHeartRateHysteresis() {
        var e = CueEngine(segment: S.easySegment(ceiling: 150))
        S.drive(&e, from: 0, to: 100, pace: 380, grade: 0, heartRate: 156)  // cue at 85
        // 148: under the ceiling but inside the 3 bpm margin: still counted as over, no re-entry.
        S.drive(&e, from: 101, to: 150, pace: 380, grade: 0, heartRate: 148)
        let again = cues(S.drive(&e, from: 151, to: 215, pace: 380, grade: 0, heartRate: 156))
        // No new "confirmation", only the one reminder: 148 still counts as over (inside the margin), and the
        // reminder needs HR at the ceiling itself and 90 s since the first cue, so it comes at 175.
        XCTAssertEqual(again.map(\.time), [175])
        // Properly back under (146) for 25 s, then over again: a fresh cue after another 25 s.
        var e2 = CueEngine(segment: S.easySegment(ceiling: 150))
        S.drive(&e2, from: 0, to: 100, pace: 380, grade: 0, heartRate: 156)
        S.drive(&e2, from: 101, to: 130, pace: 380, grade: 0, heartRate: 146)
        let fresh = cues(S.drive(&e2, from: 131, to: 200, pace: 380, grade: 0, heartRate: 156))
        XCTAssertEqual(fresh.first?.time, 156)
    }

    // MARK: Gap, hysteresis, reminders

    func testMinimumGapBetweenCues() {
        var e = CueEngine(segment: S.easySegment(fastest: 360, slowest: 403, ceiling: 150))
        var all: [CueDecision] = []
        for t in 0...200 {
            let time = Double(t)
            // HR goes over from 60 (cue at 85); pace goes too fast from 70 (due at 95, inside the gap).
            let pace: Double = time >= 70 ? 330 : 380
            all.append(e.evaluate(time: time, pace: S.estimate(pace: pace, time: time), grade: S.grade(0, time: time),
                                  heartRate: time >= 60 ? 156 : 120))
        }
        let fired = cues(all)
        XCTAssertEqual(fired.first?.time, 85)
        XCTAssertEqual(fired.first?.action, .easeOff)
        XCTAssertEqual(all[90].reason.rule, .deviationPending)
        XCTAssertEqual(all[100].reason.rule, .minimumGap)
        XCTAssertEqual(all[114].reason.rule, .minimumGap)
        XCTAssertEqual(fired.dropFirst().first?.time, 115)
        XCTAssertEqual(fired.dropFirst().first?.action, .slowDown)
        for (a, b) in zip(fired, fired.dropFirst()) { XCTAssertGreaterThanOrEqual(b.time - a.time, 30) }
    }

    func testOscillatingAcrossTheEdgeEveryTenSecondsGivesNoCue() {
        // Pace alternates 10 s clearly too slow, 10 s in band, for 10 minutes.
        var e = CueEngine(segment: seg)
        var all: [CueDecision] = []
        for t in 0...600 {
            let time = Double(t)
            let pace: Double = (t / 10) % 2 == 0 ? 360 : 332
            all.append(e.evaluate(time: time, pace: S.estimate(pace: pace, time: time), grade: S.grade(0, time: time), heartRate: nil))
        }
        XCTAssertTrue(cues(all).isEmpty)
    }

    func testHoveringAtTheEdgeGivesAtMostOneCuePerReminderInterval() {
        // 30 s just past the leaving edge (343.7), 30 s between the band edge and the leaving edge, repeat.
        var e = CueEngine(segment: seg)
        var all: [CueDecision] = []
        for t in 0...600 {
            let time = Double(t)
            let pace: Double = (t / 30) % 2 == 0 ? 348 : 340
            all.append(e.evaluate(time: time, pace: S.estimate(pace: pace, time: time), grade: S.grade(0, time: time), heartRate: nil))
        }
        let fired = cues(all)
        XCTAssertFalse(fired.isEmpty)
        for (a, b) in zip(fired, fired.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.time - a.time, e.config.repeatSeconds, "a cue at \(a.time) and \(b.time)")
        }
        // Stated window: at most one cue in any 90 s (the reminder interval), and two in all (one reminder).
        for start in stride(from: 0.0, through: 510, by: 1) {
            XCTAssertLessThanOrEqual(fired.filter { $0.time >= start && $0.time < start + 90 }.count, 1)
        }
        XCTAssertLessThanOrEqual(fired.count, 2)
    }

    func testReentryMustBeSustainedAndAReminderFollowsWhileStillOut() {
        var e = CueEngine(segment: seg)
        S.drive(&e, from: 0, to: 90, pace: 385)               // cue at 85
        S.drive(&e, from: 91, to: 110, pace: 332)             // 20 s back inside: not yet "in"
        let again = cues(S.drive(&e, from: 111, to: 200, pace: 385))
        // Still counted as out, so the next cue is the reminder (90 s after 85), not a new confirmation.
        XCTAssertEqual(again.map(\.time), [175])
        // After 25 s sustained inside, a later deviation is a fresh one (needs min gap and 25 s).
        var e2 = CueEngine(segment: seg)
        S.drive(&e2, from: 0, to: 90, pace: 380)
        S.drive(&e2, from: 91, to: 120, pace: 332)
        let fresh = cues(S.drive(&e2, from: 121, to: 200, pace: 380))
        XCTAssertEqual(fresh.map(\.time), [146])  // a new 25 s window from 121
    }

    // MARK: Missing and invalid inputs

    func testNilAndNaNInputsGiveNoCue() {
        var e = CueEngine(segment: seg)
        for t in 0...200 {
            let time = Double(t)
            let d = e.evaluate(time: time, pace: nil, grade: nil, heartRate: nil)
            XCTAssertEqual(d.action, .none)
            if t >= 60 { XCTAssertEqual(d.reason.rule, .insufficientData) }
        }
        var e2 = CueEngine(segment: S.easySegment(ceiling: 150))
        for t in 0...200 {
            let time = Double(t)
            let nanPace = PaceEstimate(time: time, speed: .nan, speedSigma: 0.1, stoppedSpeed: 0.5)
            XCTAssertEqual(e2.evaluate(time: time, pace: nanPace, grade: S.grade(.nan, time: time), heartRate: .nan).action, .none)
        }
        var e3 = CueEngine(segment: S.easySegment(ceiling: 150))
        for t in 0...200 {
            let time = Double(t)
            XCTAssertEqual(e3.evaluate(time: time, pace: S.estimate(pace: 380, time: time), grade: nil,
                                       heartRate: t % 2 == 0 ? .infinity : -5).action, .none)
        }
    }

    func testStoppedOrStalePaceGivesNoCue() {
        var e = CueEngine(segment: seg)
        let stopped = PaceEstimate(time: 100, speed: 0.1, speedSigma: 0.1, stoppedSpeed: 0.5)
        XCTAssertNil(stopped.secondsPerKm)
        for t in 60...200 {
            let time = Double(t)
            let d = e.evaluate(time: time, pace: PaceEstimate(time: time, speed: 0.1, speedSigma: 0.1, stoppedSpeed: 0.5),
                               grade: S.grade(0, time: time), heartRate: nil)
            XCTAssertEqual(d.action, .none)
        }
        var e2 = CueEngine(segment: seg)
        let old = S.estimate(pace: 400, time: 0)  // never refreshed
        for t in 60...200 {
            XCTAssertEqual(e2.evaluate(time: Double(t), pace: old, grade: S.grade(0, time: Double(t)), heartRate: nil).action, .none)
        }
    }

    func testBadTimesAreRejectedWithoutChangingState() {
        var e = CueEngine(segment: seg)
        S.drive(&e, from: 0, to: 70, pace: 380)
        let est = S.estimate(pace: 380, time: 70)
        XCTAssertEqual(e.evaluate(time: 70, pace: est, grade: nil, heartRate: nil).reason.rule, .invalidInput)
        XCTAssertEqual(e.evaluate(time: 10, pace: est, grade: nil, heartRate: nil).reason.rule, .invalidInput)
        let nan = e.evaluate(time: .nan, pace: est, grade: nil, heartRate: nil)
        XCTAssertEqual(nan.reason.rule, .invalidInput)
        XCTAssertEqual(nan.time, 70)
        XCTAssertEqual(cues(S.drive(&e, from: 71, to: 90, pace: 380)).first?.time, 85)
    }

    func testNoTargetAndNoSegment() {
        var none = CueEngine(segment: nil)
        XCTAssertEqual(S.drive(&none, from: 0, to: 100, pace: 380).last?.reason.rule, .noTarget)
        let bare = WorkoutSegment(role: .main, intensity: .threshold, durationSeconds: 600,
                                  target: WorkoutTarget(heartRate: HeartRateTarget(zones: .z4 ... .z4, floorBPM: nil, ceilingBPM: nil),
                                                        pace: nil, primary: .heartRate))
        var e = CueEngine(segment: bare)
        let ds = S.drive(&e, from: 0, to: 200, pace: 500, heartRate: 190)
        XCTAssertTrue(cues(ds).isEmpty)
        XCTAssertEqual(ds.last?.reason.rule, .noTarget)
    }

    func testNonFinitePaceTargetIsIgnored() {
        let weird = WorkoutSegment(role: .main, intensity: .threshold, durationSeconds: 600,
                                   target: WorkoutTarget(heartRate: HeartRateTarget(zones: .z4 ... .z4, floorBPM: nil, ceilingBPM: nil),
                                                         pace: PaceTarget(fastestSecondsPerKm: .nan, slowestSecondsPerKm: .infinity),
                                                         primary: .pace))
        var e = CueEngine(segment: weird)
        XCTAssertTrue(cues(S.drive(&e, from: 0, to: 200, pace: 500)).isEmpty)
    }

    // MARK: Segments, determinism, phrases

    func testStartingASegmentRestartsTheStartupWindowAndKeepsTheGap() {
        var e = CueEngine(segment: seg)
        let first = cues(S.drive(&e, from: 0, to: 100, pace: 380))
        XCTAssertEqual(first.first?.time, 85)
        e.startSegment(S.paceSegment(fastest: 300, slowest: 310), at: 101)
        let ds = S.drive(&e, from: 101, to: 220, pace: 380)
        for d in ds where d.time < 161 { XCTAssertEqual(d.action, .none) }
        XCTAssertEqual(ds[10].reason.rule, .startupWindow)
        XCTAssertEqual(ds[10].reason.segmentSeconds, 10)
        XCTAssertEqual(cues(ds).first?.time, 186)
    }

    func testDeterministic() {
        func decisions() -> [CueDecision] {
            let run = SyntheticRun.holdingTarget(seg.target.pace!, stretches: SyntheticRun.rollingGrades(totalSeconds: 600, seed: 3), seed: 3)
            var e = CueEngine(segment: seg)
            return run.readings.map { e.ingest($0) }
        }
        XCTAssertEqual(decisions(), decisions())
    }

    func testPhrasesAreShortAndFixed() {
        XCTAssertNil(CueAction.none.phrase)
        XCTAssertEqual(CueAction.speedUp.phrase, "Speed up")
        XCTAssertEqual(CueAction.slowDown.phrase, "Slow down")
        XCTAssertEqual(CueAction.easeOff.phrase, "Ease off")
        for a in CueAction.allCases { XCTAssertLessThanOrEqual(a.phrase?.count ?? 0, 10) }
    }

    // MARK: reading interval and sparse heart rate

    /// Held time must be measured correctly whatever the gap between readings: a runner far too slow gets the
    /// "speed up" cue and its one reminder at 1, 3, 4, 5 and 6 s between readings.
    func testPaceCuesFireAtAnyReadingInterval() {
        for step in [1.0, 2, 3, 4, 5, 6] {
            var e = CueEngine(segment: S.paceSegment())
            let fired = cues(S.drive(&e, from: 0, to: 600, pace: 380, grade: 0, step: step))
            XCTAssertEqual(fired.first?.action, .speedUp, "step \(step)")
            XCTAssertLessThanOrEqual(fired.first?.time ?? .infinity, 85 + 2 * step, "step \(step)")
            XCTAssertEqual(fired.count, 2, "one cue and one reminder, step \(step)")
        }
    }

    func testHeartRateCuesFireAtAnyReadingInterval() {
        for step in [1.0, 2, 3, 4, 5, 6] {
            var e = CueEngine(segment: S.easySegment(ceiling: 150))
            let fired = cues(S.drive(&e, from: 0, to: 600, pace: 380, grade: 0, heartRate: 165, step: step))
            XCTAssertEqual(fired.first?.action, .easeOff, "step \(step)")
            XCTAssertLessThanOrEqual(fired.first?.time ?? .infinity, 85 + 2 * step, "step \(step)")
            XCTAssertEqual(fired.count, 2, "one cue and one reminder, step \(step)")
        }
    }

    /// A watch reports heart rate on every 5th or 10th reading. The last finite value is carried forward for
    /// `maxEstimateAgeSeconds`, like pace, so the ceiling cue still fires.
    func testSparseHeartRateStillCues() {
        for every in [5, 10] {
            var e = CueEngine(segment: S.easySegment(ceiling: 150))
            let fired = cues(S.drive(&e, from: 0, to: 600, pace: 380, grade: 0, heartRate: 165, heartRateEvery: every))
            XCTAssertEqual(fired.first?.action, .easeOff, "every \(every)")
            XCTAssertLessThanOrEqual(fired.first?.time ?? .infinity, 95, "every \(every)")
            XCTAssertEqual(fired.count, 2, "every \(every)")
        }
    }

    /// Heart rate older than `maxEstimateAgeSeconds` is not carried: a gap longer than that restarts judging.
    func testHeartRateNotCarriedPastItsMaximumAge() {
        var e = CueEngine(segment: S.easySegment(ceiling: 150))
        S.drive(&e, from: 0, to: 50, pace: 380, grade: 0, heartRate: 165)
        // 40 s with no heart rate at all: nothing carried, nothing cued.
        XCTAssertTrue(cues(S.drive(&e, from: 51, to: 90, pace: 380, grade: 0, heartRate: nil)).isEmpty)
        // And the window restarts: 25 s of heart rate again are needed.
        let again = cues(S.drive(&e, from: 91, to: 160, pace: 380, grade: 0, heartRate: 165))
        XCTAssertEqual(again.first?.time, 116)
    }

    /// While the grade is changing the band is widened by `gradeChangeWidening` times the grade's range over
    /// the last `gradeChangeWindowSeconds`, on top of the fixed `gradeUncertainty`; judging never stops.
    func testBandIsWidenedWhileTheGradeChanges() {
        var e = CueEngine(segment: S.paceSegment())
        let steady = S.drive(&e, from: 0, to: 80, pace: 335, grade: 0.04)
        XCTAssertEqual(steady.last?.reason.gradeUncertainty ?? .nan, 0.0025, accuracy: 1e-12)
        var t = 81.0
        var last: CueDecision?
        for g in stride(from: 0.04, through: 0.0, by: -0.004) {
            last = e.evaluate(time: t, pace: S.estimate(pace: 335, time: t), grade: S.grade(g, time: t), heartRate: nil)
            t += 1
        }
        // The grade fell 4 points within 15 s: 0.0025 + 0.25 * 0.04.
        XCTAssertEqual(last?.reason.gradeUncertainty ?? .nan, 0.0025 + 0.25 * 0.04, accuracy: 1e-9)
    }
}
