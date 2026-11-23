import XCTest
@testable import CoachCore

final class PlanWeekTests: XCTestCase {
    private let utc = PlanFixture.utc

    func testWeekStartsMondayMidnight() {
        let monday = PlanFixture.firstMonday
        XCTAssertEqual(PlanCalendar.weekStart(containing: monday, timeZone: utc), monday)
        // Sunday 23:30 belongs to the week that started six days earlier.
        let sundayLate = monday.addingTimeInterval(6 * 86_400 + 23.5 * 3600)
        XCTAssertEqual(PlanCalendar.weekStart(containing: sundayLate, timeZone: utc), monday)
        // The next Monday 00:00 starts a new week.
        let nextMonday = monday.addingTimeInterval(7 * 86_400)
        XCTAssertEqual(PlanCalendar.weekStart(containing: nextMonday, timeZone: utc), nextMonday)
    }

    func testWeekDependsOnTheRunnersTimeZone() {
        // Monday 02:00 UTC is still Sunday evening in New York.
        let ny = TimeZone(identifier: "America/New_York")!
        let mondayEarlyUTC = PlanFixture.firstMonday.addingTimeInterval(2 * 3600)
        let start = PlanCalendar.weekStart(containing: mondayEarlyUTC, timeZone: ny)
        XCTAssertLessThan(start, PlanFixture.firstMonday)
        let cal = PlanCalendar.calendar(timeZone: ny)
        XCTAssertEqual(cal.component(.weekday, from: start), 2) // Monday
        XCTAssertEqual(cal.component(.hour, from: start), 0)
    }

    func testNextWeekStartAcrossDaylightSavingChange() {
        // US clocks move forward on Sunday 2026-03-08; that week is 167 hours long.
        let ny = TimeZone(identifier: "America/New_York")!
        let cal = PlanCalendar.calendar(timeZone: ny)
        var c = DateComponents(); c.year = 2026; c.month = 3; c.day = 2
        let monday = cal.date(from: c)!
        let next = PlanCalendar.nextWeekStart(after: monday, timeZone: ny)
        XCTAssertEqual(next.timeIntervalSince(monday), 167 * 3600)
        XCTAssertEqual(cal.component(.hour, from: next), 0)
        XCTAssertEqual(cal.component(.weekday, from: next), 2)
    }

    func testGroupingFillsGapsWithEmptyWeeks() {
        let workouts = [
            PlanFixture.workout("a", week: 0, day: 1, .easy, minutes: 30),
            PlanFixture.workout("b", week: 3, day: 2, .easy, minutes: 40),
            PlanFixture.workout("c", week: 0, day: 0, .easy, minutes: 20)
        ]
        let weeks = PlanWeek.weeks(from: workouts, timeZone: utc)
        XCTAssertEqual(weeks.count, 4)
        XCTAssertEqual(weeks[0].workouts.map(\.id), ["c", "a"])
        XCTAssertTrue(weeks[1].workouts.isEmpty)
        XCTAssertEqual(weeks[1].volume(.time), 0)
        XCTAssertEqual(weeks[3].volume(.time), 40 * 60)
        XCTAssertEqual(weeks[0].weekEnd, weeks[1].weekStart)
    }

    func testEmptyInputGivesNoWeeks() {
        XCTAssertTrue(PlanWeek.weeks(from: [], timeZone: utc).isEmpty)
    }

    func testVolumeIsUnknownForInvalidValues() {
        for bad in [Double.nan, .infinity, -.infinity, -1] {
            let w = PlannedWorkout(id: "x", date: PlanFixture.firstMonday, kind: .easy, durationSeconds: bad)
            XCTAssertNil(w.volume(.time), "\(bad)")
            let week = PlanWeek(weekStart: PlanFixture.firstMonday, weekEnd: PlanFixture.firstMonday, workouts: [
                w, PlanFixture.workout("ok", week: 0, day: 1, .easy, minutes: 30)
            ])
            XCTAssertNil(week.volume(.time), "\(bad)")
        }
    }

    func testDistanceVolumeNeedsDistanceButRestIsZero() {
        let noDistance = PlanFixture.workout("a", week: 0, day: 0, .easy, minutes: 30)
        XCTAssertNil(noDistance.volume(.distance))
        XCTAssertEqual(PlanFixture.workout("b", week: 0, day: 0, .easy, minutes: 30, km: 6).volume(.distance), 6000)
        let rest = PlanFixture.workout("r", week: 0, day: 0, .rest, minutes: 45)
        XCTAssertEqual(rest.volume(.time), 0)
        XCTAssertEqual(rest.volume(.distance), 0)
    }

    func testSwappedToEasyKeepsIdDateAndDuration() {
        let q = PlanFixture.workout("q", week: 0, day: 2, .quality(.intervals), minutes: 55, km: 11)
        let easy = q.swappedToEasy()
        XCTAssertEqual(easy.id, "q")
        XCTAssertEqual(easy.date, q.date)
        XCTAssertEqual(easy.durationSeconds, q.durationSeconds)
        XCTAssertEqual(easy.kind, .easy)
        XCTAssertEqual(easy.distanceMeters, 11_000)
    }

    // MARK: From history

    private func activity(sport: Activity.Sport = .run, samples: [StreamSample] = []) -> Activity {
        Activity(id: "a1", source: .healthKit, sport: sport, start: PlanFixture.firstMonday,
                 durationSeconds: 3000, distanceMeters: 8000, samples: samples)
    }

    func testOnlyRunsConvertFromHistory() {
        XCTAssertNil(PlannedWorkout(activity: activity(sport: .walk), kind: .easy))
        XCTAssertNil(PlannedWorkout(activity: activity(sport: .other("cycling")), kind: .easy))
        XCTAssertNotNil(PlannedWorkout(activity: activity(), kind: .easy))
    }

    func testHistoryDurationIsMovingTime() throws {
        // Moving from 0 s with no sample until a paused one at 600 s, paused to
        // 900 s, then moving to 2100 s. The runner may have stopped any time
        // after 0 s, so the stretch into the pause counts 30 s (MovingTime):
        // 30 + 1200 = 1230 s moving of 2100 elapsed.
        let samples = [
            StreamSample(t: 0), StreamSample(t: 600, isMoving: false),
            StreamSample(t: 900), StreamSample(t: 2100)
        ]
        let w = try XCTUnwrap(PlannedWorkout(activity: activity(samples: samples), kind: .long))
        XCTAssertEqual(w.durationSeconds, 1230)
        XCTAssertEqual(w.durationSeconds, MovingTime.seconds(of: activity(samples: samples)))
        let longerHold = try XCTUnwrap(PlannedWorkout(activity: activity(samples: samples), kind: .long,
                                                      maximumHoldSeconds: 120))
        XCTAssertEqual(longerHold.durationSeconds, 120 + 1200)
        XCTAssertEqual(w.distanceMeters, 8000)
        XCTAssertEqual(w.kind, .long)
        XCTAssertEqual(w.id, "a1")
        XCTAssertEqual(w.date, PlanFixture.firstMonday)
    }

    func testHistoryWithoutStreamsUsesElapsedDuration() throws {
        let w = try XCTUnwrap(PlannedWorkout(activity: activity(samples: [StreamSample(t: 0)]), kind: .easy))
        XCTAssertEqual(w.durationSeconds, 3000)
        // Two samples at one timestamp are one point: still no way to see pauses.
        let same = [StreamSample(t: 5), StreamSample(t: 5, isMoving: false)]
        XCTAssertEqual(try XCTUnwrap(PlannedWorkout(activity: activity(samples: same), kind: .easy)).durationSeconds, 3000)
    }

    func testHistoryWithNoUsableTimeKeepsItsTimeUnknown() throws {
        // No streams and an elapsed duration that isn't a finite non-negative
        // number: the duration stays unknown, so the week's time volume is
        // unknown (never a recovery week, #40). Its distance still counts.
        for bad in [Double.nan, .infinity, -60] {
            var a = activity()
            a.durationSeconds = bad
            let w = try XCTUnwrap(PlannedWorkout(activity: a, kind: .easy))
            XCTAssertTrue(w.durationSeconds.isNaN, "\(bad)")
            XCTAssertNil(w.volume(.time))
            XCTAssertEqual(w.volume(.distance), 8000)
            XCTAssertNil(MovingTime.knownSeconds(of: a))
            XCTAssertEqual(MovingTime.seconds(of: a), 0, "the baseline's weekly load counts it as 0")
        }
    }
}
