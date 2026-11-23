import XCTest
@testable import CoachCore

// #163: PainStopLimits.clinicianMostDaysShare validation, and a run with no RPE
// is never overreached on RPE (SPEC 3.5 rule 7, F4). Synthetic data only.
final class PainAndRPEGuardGapTests: XCTestCase {
    typealias F = AdaptFixture

    private let utc = TimeZone(identifier: "UTC")!
    private let start = Date(timeIntervalSince1970: 1_767_225_600)

    /// Daily pain reports on days 0...8: lasting pain at the default share.
    private func lasting(_ limits: PainStopLimits) -> LastingPain? {
        let reports = (0...8).map {
            PainReport(date: start.addingTimeInterval(Double($0) * 86_400 + 8 * 3600), timing: .nextMorning, hasPain: true, score: 3)
        }
        return PainStopRule.lastingPain(reports: reports, checkIns: [], asOf: start.addingTimeInterval(9 * 86_400),
                                        timeZone: utc, limits: limits)
    }

    func testABadShareFallsBackToTheDefault() {
        let d = PainStopLimits.default.clinicianMostDaysShare
        for bad in [Double.nan, -0.1, -.infinity, .infinity, -.greatestFiniteMagnitude] {
            XCTAssertEqual(PainStopLimits(clinicianMostDaysShare: bad).clinicianMostDaysShare, d, "\(bad)")
            XCTAssertEqual(PainStopLimits(clinicianMostDaysShare: bad), .default, "\(bad)")
            var l = PainStopLimits(clinicianMostDaysShare: 0.2)
            l.clinicianMostDaysShare = bad
            XCTAssertEqual(l.clinicianMostDaysShare, d, "set \(bad)")
        }
    }

    func testNaNNoLongerStopsLastingPainBeingRaised() {
        XCTAssertNotNil(lasting(PainStopLimits(clinicianMostDaysShare: .nan)))
        var l = PainStopLimits()
        l.clinicianMostDaysShare = .nan
        XCTAssertNotNil(lasting(l))
        XCTAssertNotNil(lasting(PainStopLimits(clinicianMostDaysShare: -1)), "negative falls back, not 'every report counts' or never")
        XCTAssertNotNil(lasting(PainStopLimits(clinicianMostDaysShare: .infinity)), "inf no longer means never")
    }

    func testAFiniteShareIsKeptIncludingOneAndAboveAsNever() {
        XCTAssertEqual(PainStopLimits(clinicianMostDaysShare: 0).clinicianMostDaysShare, 0)
        XCTAssertEqual(PainStopLimits(clinicianMostDaysShare: 0.9).clinicianMostDaysShare, 0.9)
        XCTAssertNotNil(lasting(PainStopLimits(clinicianMostDaysShare: 0.99)))
        // Every day reported is a share of exactly 1, which is not "more than" 1: never raised, as before.
        XCTAssertNil(lasting(PainStopLimits(clinicianMostDaysShare: 1)))
        XCTAssertNil(lasting(PainStopLimits(clinicianMostDaysShare: 2)))
        XCTAssertEqual(PainStopLimits(clinicianMostDaysShare: 2).clinicianMostDaysShare, 2)
    }

    // MARK: RPE-less runs

    private let easy = AdaptFixture.easy("e", week: 0, day: 0, minutes: 45)

    private func assess(_ spec: F.RunSpec, margin: Int?) -> RunAssessment {
        var limits = AdaptationLimits.default
        if let margin { limits.overreachedRPEMargin = margin }
        return RunClassifier.assess(F.run(for: easy, spec), planned: easy, zones: F.zones, limits: limits)
    }

    func testARunWithoutRPEIsNeverOverreachedOnRPE() {
        for margin in [0, 1, 3, 100, nil] {
            let a = assess(F.RunSpec(), margin: margin)
            XCTAssertNotEqual(a.signal, .overreached, "margin \(String(describing: margin))")
            XCTAssertNil(a.metrics.rpe)
            XCTAssertNil(a.triggers.first { $0.metric == .rpe })
        }
    }

    func testAMarginOfZeroStillCountsAnRPEAtTheTopOfTheRange() {
        // Easy expects RPE 2 to 4: 4 is 0 over, which a margin of 0 counts; 3 is below it.
        XCTAssertEqual(assess(F.RunSpec(rpe: 4), margin: 0).signal, .overreached)
        XCTAssertNotEqual(assess(F.RunSpec(rpe: 3), margin: 0).signal, .overreached)
        XCTAssertEqual(assess(F.RunSpec(rpe: 7), margin: nil).signal, .overreached)
        XCTAssertNotEqual(assess(F.RunSpec(rpe: 4), margin: nil).signal, .overreached)
    }
}
