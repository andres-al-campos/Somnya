import SwiftUI
import SwiftData

@main
struct SomnyaApp: App {
    let modelContainer: ModelContainer?
    let startupError: String?

    init() {
        // Never fatalError on a store failure — a silent kill looks exactly like
        // "black screen then the app closes". Capture the error and show it on screen
        // so the failure is diagnosable, per the debug-everything principle.
        do {
            let container = try ModelContainer(
                for: SleepDay.self, SleepSession.self, SleepPhase.self, SensorWindow.self,
                SessionAnalysisCache.self
            )
            self.modelContainer = container
            self.startupError = nil
            SomnyaLog.lifecycle("ModelContainer created OK")
        } catch {
            self.modelContainer = nil
            self.startupError = "Couldn't open the sleep database.\n\n\(error.localizedDescription)\n\nFix: delete and reinstall the app to reset its storage. If it persists, the data model changed — the store needs a migration or wipe."
            SomnyaLog.lifecycle("ModelContainer FAILED: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            if let modelContainer {
                RootView()
                    .modelContainer(modelContainer)
                    .environmentObject(SessionManager(context: modelContainer.mainContext))
            } else {
                StartupErrorView(message: startupError ?? "Unknown startup error.")
            }
        }
    }
}

/// Shown when the persistent store can't be opened, instead of a silent crash.
struct StartupErrorView: View {
    let message: String
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.yellow)
            Text("Somnya couldn't start")
                .font(.headline)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .foregroundStyle(.white)
    }
}
