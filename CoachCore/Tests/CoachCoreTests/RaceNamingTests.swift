import Foundation
import XCTest
@testable import CoachCore

// Synthetic values only: no real runner's races or history (#89).
final class RaceNamingTests: XCTestCase {
    private let utc = PlanFixture.utc

    // MARK: The name comes from the race's own distance

    func testStandardAndInBetweenDistancesAreNamedByTheirOwnDistance() {
        let cases: [(Double, String)] = [
            (Distance.fiveK, "5K"),
            (Distance.tenK, "10K"),
            (15_000, "15K"),
            (Distance.tenMiles, "10-mile race"),
            (Distance.halfMarathon, "half marathon"),
            (30_000, "30K"),
            (Distance.marathon, "marathon"),
            (8_000, "8K"),
            (5 * Distance.mile, "5-mile race"),
            (12_000, "12K"),
            (25_000, "25K"),
        ]
        for (meters, name) in cases {
            XCTAssertEqual(PlanFormatting.raceName(meters: meters), name, "\(meters) m")
        }
    }

    func testTheNameIsTheClosestWithinTheTolerance() {
        // Entered as rounded kilometres, still the named race.
        XCTAssertEqual(PlanFormatting.raceName(meters: 21_100), "half marathon")
        XCTAssertEqual(PlanFormatting.raceName(meters: 42_200), "marathon")
        XCTAssertEqual(PlanFormatting.raceName(meters: 16_090), "10-mile race")
        // Exactly a whole number of kilometres beats a named race 0.46% away.
        XCTAssertEqual(PlanFormatting.raceName(meters: 21_000), "21K")
        XCTAssertEqual(PlanFormatting.raceName(meters: 42_000), "42K")
        XCTAssertEqual(PlanFormatting.raceName(meters: 16_000), "16K")
        // The tolerance edge, 0.5% of the named distance.
        XCTAssertEqual(PlanFormatting.raceName(meters: 15_000 * 1.0049), "15K")
        XCTAssertNil(PlanFormatting.raceName(meters: 15_000 * 1.0051))
        XCTAssertEqual(PlanFormatting.raceNameTolerance, 0.005)
    }

    func testNoNameFitsADistanceBetweenNames() {
        XCTAssertNil(PlanFormatting.raceName(meters: 17_300))
        XCTAssertNil(PlanFormatting.raceName(meters: 10_500))
        XCTAssertEqual(PlanFormatting.raceDayPurpose(meters: 17_300), "Race day: your race (17.3 km).")
        XCTAssertEqual(PlanFormatting.raceDayPurpose(meters: 17_300, units: .imperial), "Race day: your race (10.7 mi).")
    }

    func testDistancesThatAreNotFiniteAndAboveZeroHaveNoName() {
        for m in [0, -5_000, .nan, .infinity, -.infinity, 400] as [Double] {
            XCTAssertNil(PlanFormatting.raceName(meters: m), "\(m)")
        }
        for m in [0, -5_000, .nan, .infinity, -.infinity] as [Double] {
            XCTAssertEqual(PlanFormatting.raceDayPurpose(meters: m), "Race day.", "\(m)")
            XCTAssertEqual(PlanFormatting.raceDayPurpose(meters: m, units: .imperial), "Race day.", "\(m)")
        }
    }

    // MARK: The race-day sentence, in both units

    func testRaceDaySentenceInBothUnits() {
        let cases: [(Double, String, String)] = [
            (Distance.fiveK, "Race day: your 5K (5.0 km).", "Race day: your 5K (3.1 mi)."),
            (Distance.tenK, "Race day: your 10K (10.0 km).", "Race day: your 10K (6.2 mi)."),
            (15_000, "Race day: your 15K (15.0 km).", "Race day: your 15K (9.3 mi)."),
            (Distance.tenMiles, "Race day: your 10-mile race (16.1 km).", "Race day: your 10-mile race (10.0 mi)."),
            (Distance.halfMarathon, "Race day: your half marathon (21.1 km).", "Race day: your half marathon (13.1 mi)."),
            (30_000, "Race day: your 30K (30.0 km).", "Race day: your 30K (18.6 mi)."),
            (Distance.marathon, "Race day: your marathon (42.2 km).", "Race day: your marathon (26.2 mi)."),
        ]
        for (meters, metric, imperial) in cases {
            XCTAssertEqual(PlanFormatting.raceDayPurpose(meters: meters), metric)
            XCTAssertEqual(PlanFormatting.raceDayPurpose(meters: meters, units: .metric), metric)
            XCTAssertEqual(PlanFormatting.raceDayPurpose(meters: meters, units: .imperial), imperial)
            // The edge builds it from the prescription, and the watch reads the same text.
            let race = raceWorkout(meters: meters, purpose: metric, stored: meters)
            XCTAssertEqual(PlanFormatting.purpose(of: race), metric)
            XCTAssertEqual(PlanFormatting.purpose(of: race, units: .imperial), imperial)
            let zones = WatchSyncZones(heartRate: HRZones(lthr: 160)!)
            guard case .workout(let w) = WatchSyncMapper.workout(for: race, zones: zones, timeZone: utc,
                                                                options: WatchSyncOptions(units: .imperial)) else {
                return XCTFail("expected a workout")
            }
            XCTAssertEqual(w.purpose, imperial)
        }
    }

    func testTheStoredRaceDistanceWinsOverTheStoredSentence() {
        // A prescription that carries the distance is rebuilt from it, whatever the text says.
        let race = raceWorkout(meters: Distance.tenMiles, purpose: "Race day: your half marathon (16.1 km).",
                               stored: Distance.tenMiles)
        XCTAssertEqual(PlanFormatting.purpose(of: race), "Race day: your 10-mile race (16.1 km).")
        XCTAssertEqual(PlanFormatting.purpose(of: race, units: .imperial), "Race day: your 10-mile race (10.0 mi).")
    }

    func testAPrescriptionWithoutTheDistanceIsRebuiltFromTheWorkoutDistance() {
        // Stored before #89: no distance in the prescription, so the sentence is rebuilt from the workout's distance.
        let old = raceWorkout(meters: Distance.halfMarathon, purpose: "Race day: your half marathon (21.1 km).", stored: nil)
        XCTAssertNil(old.prescription?.raceDistanceMeters)
        XCTAssertEqual(PlanFormatting.purpose(of: old), "Race day: your half marathon (21.1 km).")
        XCTAssertEqual(PlanFormatting.purpose(of: old, units: .imperial), "Race day: your half marathon (13.1 mi).")
        // A stored distance that isn't usable falls back the same way.
        for bad in [Double.nan, .infinity, 0, -1, 1e22, .greatestFiniteMagnitude] {
            let w = raceWorkout(meters: Distance.halfMarathon, purpose: "Race day: your half marathon (21.1 km).", stored: bad)
            XCTAssertEqual(PlanFormatting.purpose(of: w), "Race day: your half marathon (21.1 km).", "\(bad)")
            XCTAssertEqual(PlanFormatting.purpose(of: w, units: .imperial), "Race day: your half marathon (13.1 mi).", "\(bad)")
        }
    }

    func testAnOldTenMileStateIsRebuiltFromTheWorkoutDistance() throws {
        // A state stored before #89 named a 10-mile race by its category.
        let old = raceWorkout(meters: Distance.tenMiles, purpose: "Race day: your half marathon (16.1 km).", stored: nil)
        XCTAssertEqual(PlanFormatting.purpose(of: old), "Race day: your 10-mile race (16.1 km).")
        XCTAssertEqual(PlanFormatting.purpose(of: old, units: .imperial), "Race day: your 10-mile race (10.0 mi).")

        // Through the stored state too: the old JSON has no raceDistanceMeters key.
        let data = try JSONEncoder().encode(WorkoutCoding(old))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("raceDistanceMeters"))
        let back = try JSONDecoder().decode(WorkoutCoding.self, from: data).value()
        XCTAssertNil(back.prescription?.raceDistanceMeters)
        XCTAssertEqual(PlanFormatting.purpose(of: back), "Race day: your 10-mile race (16.1 km).")
        XCTAssertEqual(PlanFormatting.purpose(of: back, units: .imperial), "Race day: your 10-mile race (10.0 mi).")
    }

    func testTheOldRebuildNeedsTheGoalRaceRuleAndTheExactSuffix() {
        // Without .goalRace only the km suffix is rewritten, as before.
        let noRule = raceWorkout(meters: Distance.tenMiles, purpose: "Race day: your half marathon (16.1 km).",
                                 stored: nil, rules: [.taper])
        XCTAssertEqual(PlanFormatting.purpose(of: noRule), "Race day: your half marathon (16.1 km).")
        XCTAssertEqual(PlanFormatting.purpose(of: noRule, units: .imperial), "Race day: your half marathon (10.0 mi).")
        // A suffix that isn't the workout's own distance is left alone.
        let other = raceWorkout(meters: Distance.tenMiles, purpose: "Race day: your half marathon (21.1 km).", stored: nil)
        XCTAssertEqual(PlanFormatting.purpose(of: other), "Race day: your half marathon (21.1 km).")
        XCTAssertEqual(PlanFormatting.purpose(of: other, units: .imperial), "Race day: your half marathon (21.1 km).")
        // A workout distance that isn't usable leaves the text alone.
        for bad in [Double.nan, .infinity, 0, -1, 1e22, .greatestFiniteMagnitude] {
            let w = raceWorkout(meters: bad, purpose: "Race day: your half marathon (16.1 km).", stored: nil)
            XCTAssertEqual(PlanFormatting.purpose(of: w), "Race day: your half marathon (16.1 km).", "\(bad)")
            XCTAssertEqual(PlanFormatting.purpose(of: w, units: .imperial), "Race day: your half marathon (16.1 km).", "\(bad)")
        }
    }

    // MARK: Absurdly long distances are unusable, never a crash

    func testHugeDistancesHaveNoNameAndDoNotTrap() {
        let cap = PlanFormatting.maxRaceDistanceMeters
        XCTAssertEqual(cap, 500_000)
        XCTAssertEqual(PlanFormatting.raceName(meters: cap), "500K")
        XCTAssertEqual(PlanFormatting.raceDayPurpose(meters: cap), "Race day: your 500K (500.0 km).")
        // Past the cap, including where Int(km) or Int(miles) would trap (about 9.2e21 m and up).
        for m in [cap.nextUp, 1_000_000, 9.2e21, 1e22, 1e300, .greatestFiniteMagnitude] as [Double] {
            XCTAssertNil(PlanFormatting.raceName(meters: m), "\(m)")
            XCTAssertEqual(PlanFormatting.raceDayPurpose(meters: m), "Race day.", "\(m)")
            XCTAssertEqual(PlanFormatting.raceDayPurpose(meters: m, units: .imperial), "Race day.", "\(m)")
        }
    }

    func testAHugeDecodedRaceDistanceIsUnusableNotACrash() throws {
        for huge in [1e22, Double.greatestFiniteMagnitude] {
            // Both the stored race distance and the workout's own distance are absurd: the text is kept.
            let w = raceWorkout(meters: huge, purpose: "Race day: your race.", stored: huge)
            let back = try JSONDecoder().decode(WorkoutCoding.self, from: try JSONEncoder().encode(WorkoutCoding(w))).value()
            XCTAssertEqual(back.prescription?.raceDistanceMeters, huge)
            XCTAssertEqual(PlanFormatting.purpose(of: back), "Race day: your race.", "\(huge)")
            XCTAssertEqual(PlanFormatting.purpose(of: back, units: .imperial), "Race day: your race.", "\(huge)")

            // An absurd stored race distance on a real 10-mile workout falls back to the workout's distance.
            let mixed = raceWorkout(meters: Distance.tenMiles, purpose: "Race day: your half marathon (16.1 km).",
                                    stored: huge)
            let mixedBack = try JSONDecoder().decode(WorkoutCoding.self,
                                                     from: try JSONEncoder().encode(WorkoutCoding(mixed))).value()
            XCTAssertEqual(PlanFormatting.purpose(of: mixedBack), "Race day: your 10-mile race (16.1 km).", "\(huge)")
            XCTAssertEqual(PlanFormatting.purpose(of: mixedBack, units: .imperial),
                           "Race day: your 10-mile race (10.0 mi).", "\(huge)")
        }
    }

    func testOtherSessionsCarryNoRaceDistance() {
        let p = WorkoutPrescription(purpose: "Easy run.", phase: .base, segments: [], rules: [.easyByHeartRate])
        XCTAssertNil(p.raceDistanceMeters)
    }

    // MARK: The distance survives the places a prescription is copied

    func testAdjustmentsAndStoredStateKeepTheRaceDistance() throws {
        let race = raceWorkout(meters: Distance.tenMiles, purpose: PlanFormatting.raceDayPurpose(meters: Distance.tenMiles),
                               stored: Distance.tenMiles)
        let scaled = try XCTUnwrap(race.scalingPaces(of: [.race], by: 1.02))
        XCTAssertEqual(scaled.prescription?.raceDistanceMeters, Distance.tenMiles)
        XCTAssertEqual(PlanFormatting.purpose(of: scaled, units: .imperial), "Race day: your 10-mile race (10.0 mi).")

        let coded = try JSONDecoder().decode(WorkoutCoding.self, from: try JSONEncoder().encode(WorkoutCoding(race)))
        let back = try coded.value()
        XCTAssertEqual(back.prescription?.raceDistanceMeters, Distance.tenMiles)
        XCTAssertEqual(back.prescription, race.prescription)

        // A prescription stored before #89 has no such key and decodes as nil.
        let easy = PlannedWorkout(id: "e", date: PlanFixture.date(week: 2, day: 1), kind: .easy, durationSeconds: 1800,
                                  prescription: WorkoutPrescription(purpose: "Easy run.", phase: .base, segments: [],
                                                                    rules: [.easyByHeartRate]))
        let data = try JSONEncoder().encode(WorkoutCoding(easy))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("raceDistanceMeters"))
        XCTAssertNil(try JSONDecoder().decode(WorkoutCoding.self, from: data).value().prescription?.raceDistanceMeters)
    }

    // MARK: Other plan text names the race the same way

    func testPlanBuilderNamesTheRaceByItsOwnDistanceInOtherSessionsToo() throws {
        let start = PlanFixture.date(week: 8, day: 0, hour: 0)
        let history = PlanFixture.easyWeeks([240, 240, 240, 240], start: 4)
        let input = PlanInput(raceDistanceMeters: Distance.tenMiles, raceDate: PlanFixture.date(week: 19, day: 6, hour: 8),
                              startDate: start, trainingDays: [.tuesday, .thursday, .saturday, .sunday], longRunDay: .sunday,
                              recentWeeklySeconds: 240 * 60, recentLongRunSeconds: 80 * 60,
                              heartRateZones: HRZones(lthr: 165), easyPace: EasyPaceSample(secondsPerKm: 360, heartRate: 138),
                              fitnessAnchor: RaceEquivalent(distanceMeters: Distance.fiveK, seconds: 24 * 60))
        guard case .plan(let plan) = PlanBuilder.build(input, history: history, timeZone: utc) else {
            return XCTFail("expected a plan")
        }
        let purposes = plan.workouts.compactMap { $0.prescription?.purpose }
        XCTAssertFalse(purposes.contains { $0.contains("half marathon") }, "a 10-mile race is never called a half marathon")
        XCTAssertTrue(purposes.contains { $0.contains("endurance for the 10-mile race") })
    }

    private func raceWorkout(meters: Double, purpose: String, stored: Double?,
                             rules: [PlanRule] = [.goalRace]) -> PlannedWorkout {
        let zones = HRZones(lthr: 160)!
        let target = WorkoutTarget(heartRate: HeartRateTarget(zones: .z4 ... .z5a, floorBPM: zones.lowerBound(.z4),
                                                              ceilingBPM: zones.lowerBound(.z5b)),
                                   pace: PaceTarget(fastestSecondsPerKm: 280, slowestSecondsPerKm: 290), primary: .pace)
        let seg = WorkoutSegment(role: .main, intensity: .race, durationSeconds: 6000, target: target)
        let p = WorkoutPrescription(purpose: purpose, phase: .taper, segments: [seg], rules: rules,
                                    raceDistanceMeters: stored)
        return PlannedWorkout(id: "race", date: PlanFixture.date(week: 2, day: 6), kind: .race, durationSeconds: 6000,
                              distanceMeters: meters, prescription: p)
    }
}
