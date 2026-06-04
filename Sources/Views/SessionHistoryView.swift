import SwiftUI
import SwiftData

/// All recorded sessions, newest first. Tap one to open its detail/summary. This is the
/// "session history list" MVP task — and the answer to "nothing shows after I end a session".
struct SessionHistoryView: View {
    @Query(sort: \SleepSession.startTime, order: .reverse) private var sessions: [SleepSession]
    @Environment(\.modelContext) private var context

    var body: some View {
        Group {
            if sessions.isEmpty {
                ContentUnavailableView(
                    "No sessions yet",
                    systemImage: "moon.zzz",
                    description: Text("Tap Start Tracking to record your first session.")
                )
            } else {
                List {
                    ForEach(sessions) { session in
                        NavigationLink {
                            SessionDetailView(session: session)
                        } label: {
                            row(for: session)
                        }
                    }
                    .onDelete(perform: delete)
                }
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(for session: SleepSession) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(session.startTime.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline.bold())
                if session.isActive {
                    Text("ACTIVE")
                        .font(.caption2.bold())
                        .foregroundStyle(.green)
                }
            }
            HStack(spacing: 12) {
                Label(durationString(session), systemImage: "clock")
                Label("\(session.windows.count)", systemImage: "square.stack.3d.up")
                Label(session.detectionMethod.rawValue, systemImage: "hand.tap")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func delete(at offsets: IndexSet) {
        for i in offsets {
            let s = sessions[i]
            SomnyaLog.lifecycle("Session deleted start=\(s.startTime)")
            context.delete(s)
        }
        try? context.save()
    }

    private func durationString(_ session: SleepSession) -> String {
        let s = Int(session.duration)
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
