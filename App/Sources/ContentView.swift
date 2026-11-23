import SwiftUI
import HealthKit
import CoachCore

struct ContentView: View {
    @State private var status = "Not connected to Apple Health yet"

    var body: some View {
        VStack(spacing: 24) {
            Text("Running Coach")
                .font(.largeTitle.bold())
            Text(status)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Connect Apple Health") {
                Task { await requestAccess() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!HKHealthStore.isHealthDataAvailable())
        }
        .padding()
    }

    private func requestAccess() async {
        do {
            try await HealthAccess.store.requestAuthorization(toShare: [], read: HealthAccess.readTypes)
            status = "Apple Health access requested"
        } catch {
            status = "Couldn't request access: \(error.localizedDescription)"
        }
    }
}

/// The data the coach reads (SPEC.md section 5). Read-only in Phase 0.
enum HealthAccess {
    /// One shared store for the app; HKHealthStore is meant to be long-lived.
    static let store = HKHealthStore()

    static var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute()
        ]
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleep)
        }
        let quantities: [HKQuantityTypeIdentifier] = [
            .heartRate, .restingHeartRate, .heartRateVariabilitySDNN, .vo2Max,
            .runningPower, .runningSpeed, .runningStrideLength,
            .runningVerticalOscillation, .runningGroundContactTime,
            .stepCount, .distanceWalkingRunning, .activeEnergyBurned
        ]
        for id in quantities {
            if let t = HKObjectType.quantityType(forIdentifier: id) { types.insert(t) }
        }
        return types
    }
}
