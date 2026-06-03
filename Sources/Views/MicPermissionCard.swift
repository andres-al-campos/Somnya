import SwiftUI

/// Onboarding card for the microphone permission. Adapts to the three states:
///   undetermined → explain why, then trigger the system dialog
///   granted      → quiet confirmation
///   denied       → can't re-prompt, so deep-link to Settings with clear instructions
struct MicPermissionCard: View {
    @ObservedObject var mic: MicPermission

    var body: some View {
        Group {
            switch mic.state {
            case .granted:
                row(icon: "checkmark.circle.fill", tint: .green,
                    title: "Microphone enabled",
                    body: "Somnya can listen for breathing and ambient quiet.")

            case .undetermined:
                VStack(alignment: .leading, spacing: 10) {
                    row(icon: "mic.fill", tint: .indigo,
                        title: "Microphone access",
                        body: "Somnya uses the mic to detect breathing and tell quiet wakefulness from sleep. Audio is processed on-device.")
                    Button("Enable Microphone") {
                        Task { await mic.request() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                }

            case .denied:
                VStack(alignment: .leading, spacing: 10) {
                    row(icon: "mic.slash.fill", tint: .yellow,
                        title: "Microphone is off",
                        body: "Without it, Somnya can't hear breathing and tracking is less accurate. Turn it on in Settings → Somnya → Microphone.")
                    Button("Open Settings") { mic.openSettings() }
                        .buttonStyle(.bordered)
                        .tint(.white)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        // Re-check when returning from Settings.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification)) { _ in
            mic.refresh()
        }
    }

    private func row(icon: String, tint: Color, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(body).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
