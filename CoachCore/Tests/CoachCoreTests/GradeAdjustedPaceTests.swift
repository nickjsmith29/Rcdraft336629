import XCTest
@testable import CoachCore

/// SPEC 3.6 "Default curve", every value checked by hand.
final class GradeAdjustedPaceTests: XCTestCase {
    private let curve = DefaultGradePaceCurve()

    /// Minetti's polynomial written out term by term, independent of the implementation.
    private func cr(_ i: Double) -> Double {
        155.4 * pow(i, 5) - 30.4 * pow(i, 4) - 43.3 * pow(i, 3) + 46.3 * pow(i, 2) + 19.5 * i + 3.6
    }

    func testSpecValuesUphill() {
        for g in [0.0, 0.005, 0.01, 0.015, 0.02] { XCTAssertEqual(curve.factor(grade: g), 1.0, accuracy: 1e-12, "g=\(g)") }
        XCTAssertEqual(curve.factor(grade: 0.03), 1.06, accuracy: 0.005)
        XCTAssertEqual(curve.factor(grade: 0.05), 1.17, accuracy: 0.005)
        XCTAssertEqual(curve.factor(grade: 0.10), 1.51, accuracy: 0.005)
        XCTAssertEqual(curve.factor(grade: 0.20), 2.32, accuracy: 0.005)
        // Exact values from the polynomial, by hand: Cr(0) = 3.6.
        XCTAssertEqual(cr(0), 3.6, accuracy: 1e-12)
        for g in [0.03, 0.05, 0.1, 0.2, 0.3, 0.45] {
            XCTAssertEqual(curve.factor(grade: g), cr(g - 0.02) / 3.6, accuracy: 1e-12, "g=\(g)")
        }
    }

    func testSpecValuesDownhill() {
        XCTAssertEqual(curve.factor(grade: -0.09), 0.88, accuracy: 1e-12)
        XCTAssertEqual(curve.factor(grade: -0.18), 1.0, accuracy: 1e-12)
        XCTAssertEqual(curve.factor(grade: -0.30), 1.0, accuracy: 1e-12)
        XCTAssertEqual(curve.factor(grade: -0.45), 1.0, accuracy: 1e-12)
        // The straight lines: halfway down each is the midpoint.
        XCTAssertEqual(curve.factor(grade: -0.045), 0.94, accuracy: 1e-12)
        XCTAssertEqual(curve.factor(grade: -0.135), 0.94, accuracy: 1e-12)
        XCTAssertEqual(curve.factor(grade: -0.01), 1 - 0.12 / 9, accuracy: 1e-12)
        XCTAssertEqual(curve.factor(grade: -0.12), 0.88 + 0.12 / 3, accuracy: 1e-12)
    }

    func testContinuity() {
        let e = 1e-9
        XCTAssertEqual(curve.factor(grade: -e), curve.factor(grade: 0), accuracy: 1e-7)
        XCTAssertEqual(curve.factor(grade: e), curve.factor(grade: 0), accuracy: 1e-7)
        XCTAssertEqual(curve.factor(grade: 0.02 - e), curve.factor(grade: 0.02), accuracy: 1e-7)
        XCTAssertEqual(curve.factor(grade: 0.02 + e), curve.factor(grade: 0.02), accuracy: 1e-7)
        XCTAssertEqual(curve.factor(grade: -0.09 - e), curve.factor(grade: -0.09), accuracy: 1e-7)
        XCTAssertEqual(curve.factor(grade: -0.09 + e), curve.factor(grade: -0.09), accuracy: 1e-7)
        XCTAssertEqual(curve.factor(grade: -0.18 - e), curve.factor(grade: -0.18), accuracy: 1e-7)
        XCTAssertEqual(curve.factor(grade: -0.18 + e), curve.factor(grade: -0.18), accuracy: 1e-7)
    }

    func testClampingAtFortyFivePercent() {
        XCTAssertEqual(curve.factor(grade: 0.45), curve.factor(grade: 0.9), accuracy: 1e-12)
        XCTAssertEqual(curve.factor(grade: 0.45), curve.factor(grade: 5), accuracy: 1e-12)
        XCTAssertEqual(curve.factor(grade: -0.45), curve.factor(grade: -3), accuracy: 1e-12)
        XCTAssertEqual(curve.factor(grade: 0.45), cr(0.43) / 3.6, accuracy: 1e-12)
        XCTAssertEqual(DefaultGradePaceCurve.gradeLimit, 0.45)
    }

    func testNonFiniteGradeIsFlat() {
        XCTAssertEqual(curve.factor(grade: .nan), 1)
        XCTAssertEqual(curve.factor(grade: .infinity), 1)
        XCTAssertEqual(curve.factor(grade: -.infinity), 1)
    }

    func testShapeProperties() {
        var previous = 1.0
        var g = 0.02
        while g <= 0.45 {
            let f = curve.factor(grade: g)
            XCTAssertGreaterThanOrEqual(f, previous - 1e-12, "uphill factor must not fall (g=\(g))")
            XCTAssertGreaterThanOrEqual(f, 1)
            previous = f
            g += 0.005
        }
        g = -0.45
        while g < 0 {
            let f = curve.factor(grade: g)
            XCTAssertGreaterThanOrEqual(f, 0.88 - 1e-12)
            XCTAssertLessThanOrEqual(f, 1 + 1e-12)
            g += 0.005
        }
    }

    func testStandardAccessorAndCustomCurveSeam() {
        let c: DefaultGradePaceCurve = .standard
        XCTAssertEqual(c, DefaultGradePaceCurve())
        struct Flat: GradePaceCurve { func factor(grade: Double) -> Double { 1 } }
        XCTAssertEqual(Flat().factor(grade: 0.2), 1)
    }
}
