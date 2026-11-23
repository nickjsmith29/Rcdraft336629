import SwiftUI

@main
struct RunningCoachWatchApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 8) {
                Image(systemName: "figure.run")
                    .font(.title)
                Text("Running Coach")
                    .font(.headline)
                Text("Live coaching arrives in Phase 2")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
