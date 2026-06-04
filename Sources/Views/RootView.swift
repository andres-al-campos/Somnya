import SwiftUI
import SwiftData

/// Minimal shell for the scaffold. The full single-scroll UI (score card → regularity →
/// phases graph → stats for nerds) is post-MVP. For now: manual start/stop, a live session
/// timer, guardrail warnings, and a route into the debug screen — enough to drive sessions
/// by hand on-device while the capture pipeline is built out.
struct RootView: View {
    @EnvironmentObject private var session: SessionManager
    @StateObject private var mic = MicPermission()
    @Query(sort: \SleepSession.startTime, order: .reverse) private var sessions: [SleepSession]

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Somnya")
                    .font(.largeTitle.bold())
                Text("v0.4 scaffold")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if session.isTracking, let active = session.currentSession {
                    LiveSessionView(session: active)
                    Text("\(session.windowCount) window(s) this session")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                MicPermissionCard(mic: mic)
                    .onChange(of: mic.state) { _, _ in
                        // If the user grants/revokes mic while a session is live, the
                        // guardrail summary should reflect it immediately.
                        if session.isTracking { session.refreshGuardrails() }
                    }

                startStopButton

                if !session.lastGuardrailResults.isEmpty {
                    GuardrailSummary(results: session.lastGuardrailResults)
                }

                Spacer()

                HStack {
                    NavigationLink {
                        SessionHistoryView()
                    } label: {
                        Label("History (\(sessions.count))", systemImage: "list.bullet.rectangle")
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)

                    NavigationLink {
                        DebugLogView()
                    } label: {
                        Label("Debug", systemImage: "ladybug")
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.94))
            .foregroundStyle(.white)
        }
        .onAppear { consumePendingStartIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification)) { _ in
            consumePendingStartIfNeeded()
        }
    }

    /// If an App Intent (gesture/Shortcut) requested a start, honor it now that the app is live.
    private func consumePendingStartIfNeeded() {
        if let method = PendingSessionRequest.shared.consumePendingStart(),
           !session.isTracking {
            session.startSession(method: method)
            SomnyaLog.lifecycle("Pending start consumed — session started via \(method.rawValue)")
        }
    }

    @ViewBuilder
    private var startStopButton: some View {
        if session.isTracking {
            Button(role: .destructive) {
                session.stopSession()
            } label: {
                Label("Stop Tracking", systemImage: "stop.fill")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        } else {
            Button {
                session.startSession(method: .manual)
            } label: {
                Label("Start Tracking", systemImage: "moon.zzz.fill")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
        }
    }
}

/// Live elapsed-time readout for the active session.
struct LiveSessionView: View {
    let session: SleepSession
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 4) {
            Text("Tracking")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(elapsed)
                .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
            Text("started \(session.startTime, format: .dateTime.hour().minute())")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .onReceive(tick) { now = $0 }
    }

    private var elapsed: String {
        let s = Int(now.timeIntervalSince(session.startTime))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

/// Compact pass/fail summary of the session-start guardrails. Failures are the most common
/// "it recorded nothing" cause, so they're surfaced, not hidden.
struct GuardrailSummary: View {
    let results: [GuardrailResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(results) { r in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: r.passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(r.passed ? .green : .yellow)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.name).font(.caption.bold())
                        if !r.passed {
                            Text(r.detail).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}
