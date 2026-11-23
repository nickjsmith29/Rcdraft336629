import Foundation
@testable import CoachCore

// Synthetic runners for the F13 progress tests. Nothing here is any real
// runner's data: paces, heart rates, cadence and daily readings are invented.

enum ProgressFixture {
    static let utc = TimeZone(identifier: "UTC")!
    /// Monday 2026-06-01 00:00 UTC.
    static let monday = Date(timeIntervalSince1970: 1_780_272_000)
    /// The fixed easy heart rate the tests measure easy pace at (chosen by the caller, not a default).
    static let easyHR = 140.0
    /// Heart rate of the hard runs, above the easy ceiling of the fixture's race-derived zones.
    static let hardHR = 165.0

    static func at(week: Int, day: Int = 0, hour: Double = 7) -> Date {
        monday.addingTimeInterval(Double(week * 7 + day) * 86_400 + hour * 3600)
    }

    /// Wednesday noon of `week`: the end of a dashboard.
    static func asOf(week: Int) -> Date { at(week: week, day: 2, hour: 12) }

    /// One synthetic training week. `nil` easy speed means a week off.
    struct Week {
        var easySpeed: Double?
        /// Heart-rate rise across the Sunday long run, bpm (more rise = more decoupling).
        var longRunDriftBPM: Double = 4
        var cadence: Double? = 170
        /// Labels ("tue", "thu", "sat") of runs done at `hardHR` instead of the easy HR.
        var hard: [String] = []

        static func easy(_ speed: Double, drift: Double = 4) -> Week { Week(easySpeed: speed, longRunDriftBPM: drift) }
        static let off = Week(easySpeed: nil)
    }

    /// Constant-speed run, samples every `step` seconds, distance from speed.
    static func run(_ id: String, start: Date, seconds: Double, speed: Double,
                    hr: @escaping (Double) -> Double?, cadence: Double?, step: Double = 20,
                    indoor: Bool? = nil) -> Activity {
        var ts = Array(stride(from: 0.0, to: seconds, by: step))
        ts.append(seconds)
        let samples = ts.enumerated().map { i, t in
            StreamSample(t: t, heartRate: hr(t).map { $0 + (i % 2 == 0 ? 0.5 : -0.5) }, speed: speed,
                         cadence: cadence, distance: speed * t)
        }
        return Activity(id: id, source: .healthKit, start: start, durationSeconds: seconds,
                        distanceMeters: speed * seconds, isIndoor: indoor, hasRoute: indoor == true ? false : nil,
                        samples: samples)
    }

    /// Tue, Thu, Sat 35-minute runs and a Sunday 60-minute long run per week,
    /// all at the week's easy speed. Easy runs sit at `easyHR`; the long run's
    /// heart rate rises evenly by the week's drift, centred on `easyHR`.
    static func history(_ weeks: [Week], firstWeek: Int = 0) -> [Activity] {
        var acts: [Activity] = []
        for (i, w) in weeks.enumerated() {
            guard let v = w.easySpeed else { continue }
            let week = firstWeek + i
            for (day, label) in [(1, "tue"), (3, "thu"), (5, "sat")] {
                let hr = w.hard.contains(label) ? hardHR : easyHR
                acts.append(run("w\(week)-\(label)", start: at(week: week, day: day), seconds: 35 * 60, speed: v,
                                hr: { _ in hr }, cadence: w.cadence))
            }
            let long = 60 * 60.0
            let drift = w.longRunDriftBPM
            acts.append(run("w\(week)-sun", start: at(week: week, day: 6, hour: 8), seconds: long, speed: v,
                            hr: { t in easyHR - drift / 2 + drift * t / long }, cadence: w.cadence))
        }
        return acts
    }

    /// Daily resting HR and HRV at 06:00 for `days` days before `end`'s day;
    /// `k` is days before `end` (0 = that day).
    static func health(days: Int, before end: Date,
                       resting: (Int) -> Double = { _ in 50 },
                       sdnn: (Int) -> Double = { _ in 60 }) -> [DailyHealthSample] {
        let endDay = PlanCalendar.calendar(timeZone: utc).startOfDay(for: end)
        return (0..<days).flatMap { k -> [DailyHealthSample] in
            let d = endDay.addingTimeInterval(-Double(k) * 86_400 + 6 * 3600)
            return [DailyHealthSample(date: d, kind: .restingHeartRate, value: resting(k)),
                    DailyHealthSample(date: d, kind: .hrvSDNN, value: sdnn(k))]
        }
    }

    static func options(asOf: Date, configure: (inout ProgressOptions) -> Void = { _ in }) -> ProgressOptions {
        var o = ProgressOptions(asOf: asOf, timeZone: utc)
        o.baseline.easyHeartRate = .bpm(easyHR)
        configure(&o)
        return o
    }

    static func dashboard(_ weeks: [Week], asOfWeek: Int, health: [DailyHealthSample] = [],
                          efforts: [EffortMark] = [], plan: [PlannedWorkout] = [], extra: [Activity] = [],
                          configure: (inout ProgressOptions) -> Void = { _ in }) -> ProgressDashboard {
        ProgressBuilder.build(activities: history(weeks) + extra, efforts: efforts, dailyHealth: health, plan: plan,
                              options: options(asOf: asOf(week: asOfWeek), configure: configure))
    }

    /// Speeds rising (or falling) by `rate` per week from `start`.
    static func trend(_ count: Int, start: Double, rate: Double) -> [Week] {
        (0..<count).map { .easy(start * pow(1 + rate, Double($0))) }
    }
}
