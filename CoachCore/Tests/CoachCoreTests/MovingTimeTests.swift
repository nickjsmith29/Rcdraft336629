import XCTest
@testable import CoachCore

// MovingTime on synthetic samples.

final class MovingTimeTests: XCTestCase {
    private func activity(_ samples: [StreamSample], duration: Double = 999) -> Activity {
        Activity(id: "a", source: .healthKit, start: Date(timeIntervalSince1970: 0), durationSeconds: duration, samples: samples)
    }

    func testFewerThanTwoSamplesUsesElapsedDuration() {
        XCTAssertEqual(MovingTime.seconds(of: activity([])), 999)
        XCTAssertEqual(MovingTime.seconds(of: activity([StreamSample(t: 0)], duration: 60)), 60)
        XCTAssertEqual(MovingTime.seconds(of: activity([], duration: .nan)), 0)
        XCTAssertEqual(MovingTime.seconds(of: activity([], duration: -5)), 0)
        // Two samples, one with a non-finite time: still fewer than two usable.
        XCTAssertEqual(MovingTime.seconds(of: activity([StreamSample(t: 0), StreamSample(t: .nan)], duration: 42)), 42)
    }

    func testPausesAreLeftOutAndTheStopIsHeldAtMost30Seconds() {
        // Moving 0-100, silent until a paused sample at 400, paused until 500, moving 500-600.
        let samples = [StreamSample(t: 0), StreamSample(t: 100), StreamSample(t: 400, isMoving: false),
                       StreamSample(t: 500), StreamSample(t: 600)]
        XCTAssertEqual(MovingTime.seconds(of: activity(samples)), 100 + 30 + 100)
        XCTAssertEqual(MovingTime.seconds(of: activity(samples), maximumHoldSeconds: 0), 200)
    }

    func testSilentStretchBetweenMovingSamplesCountsInFullAndOrderDoesNotMatter() {
        let samples = [StreamSample(t: 300), StreamSample(t: 0), StreamSample(t: 10), StreamSample(t: 10)]
        XCTAssertEqual(MovingTime.seconds(of: activity(samples)), 300)
    }

    func testTwoSamplesAtTheSameTimestampAreOnePoint() {
        // One point can't show pauses, so the elapsed duration is used.
        let samples = [StreamSample(t: 10, heartRate: 150), StreamSample(t: 10, speed: 3)]
        XCTAssertEqual(MovingTime.seconds(of: activity(samples, duration: 75)), 75)
        let iv = MovingTime.held(samples, streams: [.heartRate: { _ in true }], maximumHoldSeconds: 30)
        XCTAssertTrue(iv.isEmpty)
    }

    func testSameTimestampSamplesMergeAndAnyPausedOnePausesThePoint() {
        let samples = [StreamSample(t: 0), StreamSample(t: 100), StreamSample(t: 100, isMoving: false),
                       StreamSample(t: 200)]
        // The merged point at 100 s is paused: 0-100 ends in a pause (30 s held), 100-200 is paused.
        XCTAssertEqual(MovingTime.seconds(of: activity(samples)), 30)
    }

    func testEachStreamIsHeldForwardOnItsOwnUpToTheLimit() {
        // Heart rate in its own samples every 10 s, speed every second; a pause at 60-70 clears holds.
        var samples: [StreamSample] = []
        for t in 0...100 {
            let moving = !(60..<70).contains(t)
            samples.append(StreamSample(t: Double(t), speed: 3, isMoving: moving))
            if t % 10 == 5, t < 50 { samples.append(StreamSample(t: Double(t) + 0.5, heartRate: 150, isMoving: moving)) }
        }
        let iv = MovingTime.held(samples, streams: [.heartRate: { _ in true }, .speed: { _ in true }],
                                 maximumHoldSeconds: 30)
        let total = iv.last!.end
        XCTAssertEqual(total, 90, accuracy: 1e-9)
        func seconds(_ kind: StreamKind) -> Double { iv.filter { $0.values[kind] != nil }.reduce(0) { $0 + $1.seconds } }
        XCTAssertEqual(seconds(.speed), 90, accuracy: 1e-9)
        // HR from 5.5 s, last reading at 45.5 s held to 60 s (the pause), none after.
        XCTAssertEqual(seconds(.heartRate), 60 - 5.5, accuracy: 1e-9)
        // Contiguous moving clock.
        XCTAssertTrue(zip(iv, iv.dropFirst()).allSatisfy { $0.end == $1.start })
    }
}
