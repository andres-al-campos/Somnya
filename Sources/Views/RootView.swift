import SwiftUI
import SwiftData

/// Minimal shell for the scaffold. The full single-scroll UI (score card → regularity →
/// phases graph → stats for nerds) is post-MVP. For now: a manual start/stop control and a
/// route into the debug screen, so the capture pipeline can be exercised on-device.
struct RootView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SleepSession.startTime, order: .reverse) private var sessions: [SleepSession]

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Somnya")
                    .font(.largeTitle.bold())
                Text("Sleep tracking scaffold — v0.4")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()

                NavigationLink {
                    DebugLogView()
                } label: {
                    Label("Debug Logs", systemImage: "ladybug")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)

                Text("\(sessions.count) session(s) recorded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.92))
            .foregroundStyle(.white)
        }
    }
}
