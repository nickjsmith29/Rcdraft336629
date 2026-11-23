import XCTest
@testable import CoachCore

// Boundaries of the best-effort noise rule in `BaselineBuilder.fastestStretch`
// (F1 best efforts, #40). Synthetic 1 Hz distance readings; the top plausible
// speed is 7.5 m/s, so one interval allows 7.5 m and two allow 15 m, and a
// held-back reading may be over by at most 5 m (`distanceNoiseMeters`).

final class BestEffortNoiseTests: XCTestCase {
    private func stream(_ distances: [Double]) -> [StreamSample] {
        distances.enumerated().map { StreamSample(t: Double($0.offset), distance: $0.element) }
    }

    func testTheLimitsTheTestsAssume() {
        XCTAssertEqual(BlendedPredictor.plausibleSpeed.upperBound, 7.5)
        XCTAssertEqual(BaselineBuilder.distanceNoiseMeters, 5)
    }

    func testHeldBackReadingCountsWhileTheTwoIntervalRiseIsAtMostTheLimit() throws {
        // 9 m in the first second is over 7.5 m and waits; 15 m over both seconds
        // is exactly the limit, so all of it counts, then 5 m a second.
        let atLimit = stream([0, 9, 15, 20, 25])
        let s = try XCTUnwrap(BaselineBuilder.fastestStretch(atLimit, meters: 25))
        XCTAssertEqual(s.seconds, 4, accuracy: 1e-9)
        XCTAssertEqual(s.startT, 0, accuracy: 1e-9)
    }

    func testHeldBackReadingIsDroppedJustAboveTheTwoIntervalLimit() throws {
        // 15.5 m over two seconds is past the limit: both steps are re-based
        // without counting, so only the 10 m after them is left.
        let over = stream([0, 9, 15.5, 20.5, 25.5])
        XCTAssertNil(BaselineBuilder.fastestStretch(over, meters: 10.5))
        let rest = try XCTUnwrap(BaselineBuilder.fastestStretch(over, meters: 10))
        XCTAssertEqual(rest.seconds, 2, accuracy: 1e-9)
        XCTAssertEqual(rest.startT, 2, accuracy: 1e-9)
    }

    func testFastRunnerLosesRealDistanceWhenNoiseTakesTheRisePastTheLimit() throws {
        // A true 7 m/s with readings +2, +2, +1.5 m off (the first reading true):
        // 9 m, then 15.5 m over two seconds. The rule drops real distance here,
        // and the effort only ever gets slower.
        let truth = (0...20).map { 7.0 * Double($0) }
        var noisy = truth
        noisy[1] += 2; noisy[2] += 1.5
        let s = try XCTUnwrap(BaselineBuilder.fastestStretch(stream(noisy), meters: 100))
        let real = try XCTUnwrap(BaselineBuilder.fastestStretch(stream(truth), meters: 100))
        XCTAssertEqual(real.seconds, 100 / 7, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(s.seconds, real.seconds - 1e-9)
        // 140 m were run, but the count re-bases at the 15.5 m reading, so
        // exactly 140 - 15.5 = 124.5 m are counted.
        XCTAssertNotNil(BaselineBuilder.fastestStretch(stream(noisy), meters: 124.5 - 1e-6))
        XCTAssertNil(BaselineBuilder.fastestStretch(stream(noisy), meters: 124.5 + 1e-6))
    }

    func testNoiseOfUpToTwoMetresLosesNothingUpTo5Point5MetresPerSecond() throws {
        // The documented bound: 2 v + (e2 - e0) <= 15 with |e| <= 2 holds for
        // v <= 5.5. Worst case, repeating: the mark reads 2 m low, the next
        // reading 2 m high (over the limit, held back), the one after 2 m high
        // (the two-interval rise is then 2 v + 4).
        func distances(_ v: Double) -> [Double] {
            (0...399).map { (k: Int) -> Double in
                let error: Double = k % 3 == 0 ? -2 : 2
                return v * Double(k) + error
            }
        }
        // At 5.5 m/s the rise is exactly 15 m: from -2 m to 2192.5 m all counts.
        let kept = stream(distances(5.5))
        XCTAssertNotNil(BaselineBuilder.fastestStretch(kept, meters: 2194.5 - 1e-6))
        XCTAssertNil(BaselineBuilder.fastestStretch(kept, meters: 2194.5 + 1e-6))
        // At 5.6 m/s it is 15.2 m, so most of each three seconds is dropped.
        XCTAssertNil(BaselineBuilder.fastestStretch(stream(distances(5.6)), meters: 1000))
    }

    func testOverByMoreThanTheNoiseAllowanceIsAJumpNotHeldBack() throws {
        // 12.5 m in one second is over by exactly 5 m: held back, and 15 m over
        // two seconds then counts. 12.6 m is over by more: a jump that adds nothing.
        let held = stream([0, 12.5, 15, 20, 25])
        XCTAssertEqual(try XCTUnwrap(BaselineBuilder.fastestStretch(held, meters: 25)).seconds, 4, accuracy: 1e-9)
        let jump = stream([0, 12.6, 15, 20, 25])
        XCTAssertNil(BaselineBuilder.fastestStretch(jump, meters: 12.5))
        XCTAssertNotNil(BaselineBuilder.fastestStretch(jump, meters: 12.3))
    }

    func testHeldBackLastReadingIsNeverCounted() throws {
        // The last reading rises 9 m in one second and nothing follows to show it
        // was noise: it is left out, so the stream counts 10 m, not 19 m.
        let tail = stream([0, 5, 10, 19])
        XCTAssertNil(BaselineBuilder.fastestStretch(tail, meters: 10.5))
        let s = try XCTUnwrap(BaselineBuilder.fastestStretch(tail, meters: 10))
        XCTAssertEqual(s.seconds, 2, accuracy: 1e-9)
        // The same reading with one more after it is counted.
        let followed = stream([0, 5, 10, 19, 22])
        XCTAssertEqual(try XCTUnwrap(BaselineBuilder.fastestStretch(followed, meters: 22)).seconds, 4, accuracy: 1e-9)
        // Only the one reading is lost: a stream whose last step is plausible
        // keeps everything.
        XCTAssertEqual(try XCTUnwrap(BaselineBuilder.fastestStretch(stream([0, 5, 10, 15]), meters: 15)).seconds,
                       3, accuracy: 1e-9)
    }

    func testSustainedOverReadBelowTheTopSpeedCountsInFull() throws {
        // Documented limitation: a 3 m/s run whose stream reads 7 m/s for 30 s
        // (an over-read under the plausible top) counts that distance in full,
        // so a short effort there is too fast. No run-pace check is applied.
        let distances = (0...300).map { k -> Double in
            let t = Double(k)
            return 3 * t + 4 * max(0, min(t, 130) - 100)
        }
        let s = try XCTUnwrap(BaselineBuilder.fastestStretch(stream(distances), meters: 200))
        XCTAssertEqual(s.seconds, 200.0 / 7, accuracy: 1e-9)
    }
}
