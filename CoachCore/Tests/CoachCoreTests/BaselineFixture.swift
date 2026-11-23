import Foundation
@testable import CoachCore

// A synthetic runner generated in code for the F1 baseline tests. Nothing here
// is any real runner's data: the heart-rate model, paces, races and health
// readings are invented so the expected baseline can be worked out by hand.

enum BaselineFixture {
    static let timeZone = TimeZone(identifier: "America/New_York")!
    static let interval = 5.0
    static let weeks = 16

    /// Invented heart-rate model: bpm = 70 + 25 x speed (m/s).
    static func hr(atSpeed v: Double) -> Double { 70 + 25 * v }

    /// Two marked races agree within 3 bpm, so LTHR = the higher one.
    static let raceAHR = 168.0
    static let raceBHR = 166.0
    static let raceASpeed = 3.9      // 10 km
    static let raceBSpeed = 3.6      // half marathon
    /// Zone-2 midpoint of LTHR 168 is 0.875 x 168 = 147 bpm, reached at 3.08 m/s.
    static let easySpeed = 3.08
    /// Long runs sit below the easy band (140 to 143 bpm), so easy pace comes from easy runs only.
    static let longSpeed = 2.8
    /// Cadence rises by exactly this much per week (linear in start time) on runs that record it.
    static let cadenceSlopePerWeek = 0.25

    static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }

    /// Local time on day `d` (0 = Monday of week 0) at `hour`.
    static func date(day d: Int, hour: Int = 7, minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 1 + d; c.hour = hour; c.minute = minute
        return calendar.date(from: c)!
    }

    /// Wednesday noon of the week after the last generated week.
    static let asOf = date(day: weeks * 7 + 2, hour: 12)

    /// Constant-speed run with samples every 5 s from 0 through the duration.
    static func run(_ id: String,
                    start: Date,
                    seconds: Double,
                    speed: Double,
                    hr: (Double) -> Double?,
                    cadence: Double?,
                    source: Activity.Source = .healthKit,
                    outdoor: Bool = true,
                    distance: Bool = true) -> Activity {
        var ts = Array(stride(from: 0.0, to: seconds, by: interval))
        ts.append(seconds)
        let samples = ts.enumerated().map { i, t in
            StreamSample(t: t,
                         heartRate: hr(t).map { $0 + (i % 2 == 0 ? 0.5 : -0.5) },
                         speed: speed,
                         cadence: cadence,
                         distance: distance ? speed * t : nil,
                         altitude: outdoor ? 30 : nil)
        }
        return Activity(id: id, source: source, start: start, durationSeconds: seconds,
                        distanceMeters: distance ? speed * seconds : nil,
                        isIndoor: outdoor ? false : true, hasRoute: outdoor,
                        samples: samples)
    }

    struct Fixture {
        let activities: [Activity]
        let marks: [EffortMark]
        let health: [DailyHealthSample]
        /// Runs planted without cadence (a device change), in order.
        let cadenceGapIDs: [String]
        let treadmillID: String
        let duplicateID: String
        let duplicateOfID: String
    }

    static func make() -> Fixture {
        var acts: [Activity] = []
        let gapWeek = 9
        var gapIDs: [String] = []
        func cadence(_ start: Date) -> Double {
            168 + cadenceSlopePerWeek * start.timeIntervalSince(date(day: 0)) / (7 * 86_400)
        }
        for w in 0..<weeks {
            // Tue, Thu, Sat easy 35 min (Sat may be a race); Sun long 80 min.
            for (offset, label) in [(1, "tue"), (3, "thu"), (5, "sat")] {
                let id = "w\(w)-\(label)"
                let d = w * 7 + offset
                let cad = cadence(date(day: d))
                if w == 10 && label == "sat" {
                    acts.append(run("race-b", start: date(day: d), seconds: Distance.halfMarathon / raceBSpeed,
                                    speed: raceBSpeed, hr: { _ in raceBHR }, cadence: cad))
                    continue
                }
                if w == 14 && label == "sat" {
                    acts.append(run("race-a", start: date(day: d), seconds: Distance.tenK / raceASpeed,
                                    speed: raceASpeed, hr: { _ in raceAHR }, cadence: cad))
                    continue
                }
                if w == 12 && label == "thu" {
                    acts.append(run("treadmill", start: date(day: d), seconds: 35 * 60, speed: easySpeed,
                                    hr: { _ in hr(atSpeed: easySpeed) }, cadence: cad, outdoor: false))
                    continue
                }
                let noCadence = w == gapWeek
                if noCadence { gapIDs.append(id) }
                acts.append(run(id, start: date(day: d), seconds: 35 * 60, speed: easySpeed,
                                hr: { _ in hr(atSpeed: easySpeed) }, cadence: noCadence ? nil : cad))
            }
            // Long run with heart rate drifting up 3 bpm: a steady run with mild decoupling.
            let longSeconds = 80 * 60.0
            let base = hr(atSpeed: longSpeed)
            let longStart = date(day: w * 7 + 6, hour: 8)
            acts.append(run("w\(w)-sun", start: longStart, seconds: longSeconds,
                            speed: longSpeed, hr: { t in base + 3 * t / longSeconds }, cadence: cadence(longStart)))
        }
        // The same long run recorded again by a plan app: same start, distance only.
        let original = acts.first { $0.id == "w13-sun" }!
        acts.append(run("w13-sun-planapp", start: original.start, seconds: original.durationSeconds,
                        speed: longSpeed, hr: { _ in nil }, cadence: nil, source: .other("plan app")))

        // Race B was also recorded by the plan app, and the runner marked that copy.
        let raceB = acts.first { $0.id == "race-b" }!
        acts.append(run("race-b-planapp", start: raceB.start.addingTimeInterval(20), seconds: raceB.durationSeconds,
                        speed: raceBSpeed, hr: { _ in nil }, cadence: nil, source: .other("plan app")))

        // Race A is marked on the watch's id, race B on the plan app's dropped copy.
        // The time-trial mark names a run that isn't in the history.
        let marks = [EffortMark(activityID: "race-a", kind: .race),
                     EffortMark(activityID: "race-b-planapp", kind: .race),
                     EffortMark(activityID: "missing-run", kind: .timeTrialLast20Min)]

        // Daily readings for the 120 days before asOf, every ninth day missing.
        var health: [DailyHealthSample] = []
        for k in 0..<120 where k % 9 != 4 {
            let day = date(day: weeks * 7 + 2 - k, hour: 6)
            health.append(DailyHealthSample(date: day, kind: .restingHeartRate, value: restingHR(k)))
            health.append(DailyHealthSample(date: day, kind: .hrvSDNN, value: sdnn(k)))
        }
        return Fixture(activities: acts, marks: marks, health: health, cadenceGapIDs: gapIDs,
                       treadmillID: "treadmill", duplicateID: "w13-sun-planapp", duplicateOfID: "w13-sun")
    }

    /// Invented daily readings, `k` days before asOf's day.
    static func restingHR(_ k: Int) -> Double { 50 + Double((k * 7) % 5) - 2 }
    static func sdnn(_ k: Int) -> Double { 60 + Double((k * 3) % 11) - 5 }

    static func options() -> BaselineOptions {
        BaselineOptions(asOf: asOf, timeZone: timeZone)
    }
}
