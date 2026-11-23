import XCTest
@testable import CoachCore

final class BaselineFactsTests: XCTestCase {
    func testFixtureShowsDaysLongRunDayAndTreadmill() throws {
        let facts = BaselineFacts.from(GoalFixture.fixtureReport())
        XCTAssertEqual(facts.trainingDays?.value, GoalFixture.fixtureDays)
        XCTAssertEqual(facts.longRunDay?.value, .sunday)
        XCTAssertEqual(facts.treadmillAccess?.value, true)
        XCTAssertEqual(facts.treadmillAccess?.evidenceActivityIDs, ["treadmill"])
        // Long-run evidence is the last four Sunday long runs.
        XCTAssertEqual(facts.longRunDay?.evidenceActivityIDs, ["w12-sun", "w13-sun", "w14-sun", "w15-sun"])
        XCTAssertFalse(try XCTUnwrap(facts.trainingDays).evidenceActivityIDs.isEmpty)
    }

    func testNoHistoryShowsNothing() {
        let report = BaselineBuilder.build(activities: [], options: BaselineOptions(asOf: GoalFixture.today, timeZone: GoalFixture.timeZone))
        XCTAssertEqual(BaselineFacts.from(report), .none)
    }

    func testFewerThanFourCompleteWeeksIsUnknown() {
        let report = GoalFixture.report(weeks: 3, days: [.monday: 30, .wednesday: 30, .saturday: 70])
        let facts = BaselineFacts.from(report)
        XCTAssertNil(facts.trainingDays)
        XCTAssertNil(facts.longRunDay)
        let four = BaselineFacts.from(GoalFixture.report(weeks: 4, days: [.monday: 30, .wednesday: 30, .saturday: 70]))
        XCTAssertEqual(four.trainingDays?.value, [.monday, .wednesday, .saturday])
        XCTAssertEqual(four.longRunDay?.value, .saturday)
    }

    func testFewerUsualDaysThanThePlanNeedsIsAsked() {
        let facts = BaselineFacts.from(GoalFixture.report(weeks: 6, days: [.tuesday: 40, .sunday: 80]))
        XCTAssertNil(facts.trainingDays, "two days a week is below the plan's minimum, so the runner is asked")
        XCTAssertEqual(facts.longRunDay?.value, .sunday)
    }

    func testScatteredDaysAreAsked() {
        // Each week runs on three different days.
        var extra: [Activity] = []
        let rotations: [[PlanWeekday]] = [[.monday, .wednesday, .friday], [.tuesday, .thursday, .saturday],
                                          [.wednesday, .friday, .sunday], [.monday, .thursday, .saturday]]
        for (w, days) in rotations.enumerated() {
            for d in days { extra.append(GoalFixture.run("s\(w)-\(d.rawValue)", week: w, day: d, minutes: 40)) }
        }
        let facts = BaselineFacts.from(GoalFixture.report(weeks: 4, days: [:], extra: extra))
        XCTAssertNil(facts.trainingDays)
        XCTAssertNil(facts.longRunDay, "equal-length runs have no distinct long run")
    }

    func testDayRunInThreeOfFourWeeksCountsButTwoDoesNot() {
        let base: [PlanWeekday: Double] = [.monday: 30, .wednesday: 30, .saturday: 70]
        // Fridays in weeks 0, 1, 2: three of four weeks.
        let three = (0..<3).map { GoalFixture.run("fri\($0)", week: $0, day: .friday, minutes: 30) }
        XCTAssertEqual(BaselineFacts.from(GoalFixture.report(weeks: 4, days: base, extra: three)).trainingDays?.value,
                       [.monday, .wednesday, .friday, .saturday])
        // Fridays in two weeks only: off-pattern runs are 2 of 14 (86%), under the 90% coverage.
        let two = (0..<2).map { GoalFixture.run("fri\($0)", week: $0, day: .friday, minutes: 30) }
        XCTAssertNil(BaselineFacts.from(GoalFixture.report(weeks: 4, days: base, extra: two)).trainingDays)
        // One off-pattern run in 13 (92%) is still a clear pattern.
        let one = [GoalFixture.run("fri0", week: 0, day: .friday, minutes: 30)]
        XCTAssertEqual(BaselineFacts.from(GoalFixture.report(weeks: 4, days: base, extra: one)).trainingDays?.value,
                       [.monday, .wednesday, .saturday])
    }

    func testOnlyTheLastFourCompleteWeeksCount() {
        // Older weeks ran Tue/Thu/Sun; the last four run Mon/Wed/Sat.
        var extra: [Activity] = []
        for w in 0..<4 {
            for (d, m) in [(PlanWeekday.tuesday, 30.0), (.thursday, 30), (.sunday, 80)] {
                extra.append(GoalFixture.run("old\(w)-\(d.rawValue)", week: w, day: d, minutes: m))
            }
        }
        for w in 4..<8 {
            for (d, m) in [(PlanWeekday.monday, 30.0), (.wednesday, 30), (.saturday, 80)] {
                extra.append(GoalFixture.run("new\(w)-\(d.rawValue)", week: w, day: d, minutes: m))
            }
        }
        let facts = BaselineFacts.from(GoalFixture.report(weeks: 8, days: [:], extra: extra))
        XCTAssertEqual(facts.trainingDays?.value, [.monday, .wednesday, .saturday])
        XCTAssertEqual(facts.longRunDay?.value, .saturday)
    }

    func testLongRunMustStandOutAndRepeat() {
        // 1.25 times the other runs is enough (boundary)...
        let edge = BaselineFacts.from(GoalFixture.report(weeks: 4, days: [.monday: 40, .wednesday: 40, .saturday: 50]))
        XCTAssertEqual(edge.longRunDay?.value, .saturday)
        // ...just under is not.
        let under = BaselineFacts.from(GoalFixture.report(weeks: 4, days: [.monday: 40, .wednesday: 40, .saturday: 49]))
        XCTAssertNil(under.longRunDay)
        XCTAssertNotNil(under.trainingDays)

        // Long run alternates Saturday and Sunday: two of four weeks each.
        var extra: [Activity] = []
        for w in 0..<4 {
            extra.append(GoalFixture.run("a\(w)", week: w, day: .tuesday, minutes: 30))
            extra.append(GoalFixture.run("b\(w)", week: w, day: .thursday, minutes: 30))
            extra.append(GoalFixture.run("l\(w)", week: w, day: w % 2 == 0 ? .saturday : .sunday, minutes: 80))
            extra.append(GoalFixture.run("e\(w)", week: w, day: w % 2 == 0 ? .sunday : .saturday, minutes: 30))
        }
        let alternating = BaselineFacts.from(GoalFixture.report(weeks: 4, days: [:], extra: extra))
        XCTAssertNil(alternating.longRunDay)
        XCTAssertEqual(alternating.trainingDays?.value, [.tuesday, .thursday, .saturday, .sunday])
    }

    func testTreadmillOnlyCountsWhenRecent() {
        let days: [PlanWeekday: Double] = [.monday: 30, .wednesday: 30, .saturday: 70]
        let none = BaselineFacts.from(GoalFixture.report(weeks: 16, days: days))
        XCTAssertNil(none.treadmillAccess, "no treadmill run doesn't show there is no treadmill")

        let recent = [GoalFixture.run("tm", week: 14, day: .thursday, minutes: 30, outdoor: false)]
        XCTAssertEqual(BaselineFacts.from(GoalFixture.report(weeks: 16, days: days, extra: recent)).treadmillAccess?.value, true)

        // Week 1 Thursday is more than 90 days before asOf (Wednesday after week 15).
        let old = [GoalFixture.run("tm", week: 1, day: .thursday, minutes: 30, outdoor: false)]
        XCTAssertNil(BaselineFacts.from(GoalFixture.report(weeks: 16, days: days, extra: old)).treadmillAccess)
    }
}

extension BaselineFactsTests {
    func testTreadmillWindowBoundary() {
        let days: [PlanWeekday: Double] = [.monday: 30, .wednesday: 30, .saturday: 70]
        let asOf = BaselineFixture.date(day: 16 * 7 + 2, hour: 12)
        func facts(daysBack: Double) -> BaselineFacts {
            let tm = BaselineFixture.run("tm", start: asOf.addingTimeInterval(-daysBack * 86_400), seconds: 30 * 60,
                                         speed: BaselineFixture.easySpeed,
                                         hr: { _ in BaselineFixture.hr(atSpeed: BaselineFixture.easySpeed) },
                                         cadence: 170, outdoor: false)
            return BaselineFacts.from(GoalFixture.report(weeks: 16, days: days, extra: [tm]))
        }
        XCTAssertEqual(facts(daysBack: 89).treadmillAccess?.value, true)
        XCTAssertEqual(facts(daysBack: 90).treadmillAccess?.value, true, "exactly 90 days back is inside the window")
        XCTAssertNil(facts(daysBack: 91).treadmillAccess)
    }
}
