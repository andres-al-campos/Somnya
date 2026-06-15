import SwiftUI
import SwiftData

/// All recorded sessions, newest first. Tap one to open its detail/summary. This is the
/// "session history list" MVP task — and the answer to "nothing shows after I end a session".
struct SessionHistoryView: View {
    @Query(sort: \SleepSession.startTime, order: .reverse) private var sessions: [SleepSession]
    @Environment(\.modelContext) private var context

    @State private var exportItem: ExportFile?
    @State private var exportError: String?
    @State private var isExporting = false

    /// `sheet(item:)` wrapper — driving presentation off the payload avoids the empty-panel race where
    /// the sheet opens before the file URL is committed. Same pattern as RawDataView.
    private struct ExportFile: Identifiable {
        let id = UUID()
        let url: URL
    }

    /// Finished sessions only — an active (still-recording) night is still gaining windows, so exporting
    /// it would ship an incomplete file and falsely mark it done.
    private var exportable: [SleepSession] { sessions.filter { !$0.isActive } }
    private var unexported: [SleepSession] { exportable.filter { $0.exportedAt == nil } }

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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        export(unexported)
                    } label: {
                        Label("Export new (\(unexported.count))", systemImage: "square.and.arrow.up")
                    }
                    .disabled(unexported.isEmpty)

                    Button {
                        export(exportable)
                    } label: {
                        Label("Export all (\(exportable.count))", systemImage: "square.and.arrow.up.on.square")
                    }
                    .disabled(exportable.isEmpty)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(exportable.isEmpty || isExporting)
            }
        }
        .overlay {
            if isExporting {
                // A blocking, labelled spinner: zipping a few big nights takes a moment, and without
                // this the app looked frozen and the export looked broken.
                ZStack {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Preparing export…").font(.callout)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isExporting)
        .sheet(item: $exportItem) { item in
            ShareSheet(items: [item.url])
        }
        .alert("Export failed", isPresented: .constant(exportError != nil)) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    /// Zip the given sessions into one archive, present the share sheet, and stamp `exportedAt` so a
    /// later "export new" skips them. Stamping happens once the zip is built (we can't see the Mac);
    /// "export all" re-exports regardless, which is the recovery path if the Mac copies are ever lost.
    ///
    /// Serializing reads managed objects (main actor); the heavy write+zip runs off-main so the UI keeps
    /// painting the spinner instead of freezing.
    private func export(_ toExport: [SleepSession]) {
        guard !toExport.isEmpty, !isExporting else { return }
        isExporting = true
        Task {
            // Phase 1 (main actor): managed objects → Sendable JSON blobs.
            let serialized = SessionJSON.serialize(toExport)
            let payload = serialized.blobs.map { (name: $0.name, data: $0.data) }

            // Phase 2 (background): write + compress the Sendable blobs into one zip.
            let zipResult = await Task.detached(priority: .userInitiated) {
                Result { try SessionJSON.zip(blobs: payload) }
            }.value

            isExporting = false
            switch zipResult {
            case .success(let url):
                let now = Date()
                for b in serialized.blobs { b.session.exportedAt = now }
                try? context.save()
                if !serialized.failed.isEmpty {
                    SomnyaLog.lifecycle("Export: \(serialized.failed.count) session(s) skipped (serialize failed)")
                }
                exportItem = ExportFile(url: url)
            case .failure(let error):
                exportError = "Couldn't build the export: \(error.localizedDescription) Free up storage and try again."
            }
        }
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
                Spacer()
                if session.exportedAt != nil {
                    Image(systemName: "checkmark.icloud")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Exported")
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
