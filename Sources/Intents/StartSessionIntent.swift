import AppIntents
import SwiftData
import Foundation

/// App Intent that begins a sleep session. Appears as an action in the Shortcuts app
/// ("Start Somnya Session") and via Siri, so a Back Tap → Shortcut (or a voice phrase) can
/// start tracking with no taps through the app's UI — the spec's frictionless-start feature.
///
/// Architecture note: an App Intent runs in its own short-lived process, separate from the
/// running app. CoreMotion capture must run *in* the app (the process has to stay alive), so
/// this intent opens the app and hands it a "start now" signal via a shared flag, rather than
/// trying to drive the capture pipeline from the intent process (which would die immediately).
struct StartSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Somnya Session"
    static var description = IntentDescription(
        "Begins sleep tracking immediately with default settings — no setup screen."
    )

    /// Open the app so the in-app capture pipeline can run. (Background-only start becomes
    /// possible once the mic keepalive audio session exists; until then the app must foreground.)
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // Signal the app to start a gesture session as soon as it's active.
        PendingSessionRequest.shared.requestStart(method: .gesture)
        SomnyaLog.lifecycle("StartSessionIntent invoked — pending gesture start queued")
        return .result()
    }
}

/// App Shortcut registration: makes the intent discoverable in Shortcuts/Spotlight and gives
/// it Siri trigger phrases, so the user doesn't have to build a shortcut by hand.
struct SomnyaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartSessionIntent(),
            phrases: [
                "Start \(.applicationName) session",
                "Track my sleep with \(.applicationName)",
                "\(.applicationName) start tracking"
            ],
            shortTitle: "Start Session",
            systemImageName: "moon.zzz.fill"
        )
    }
}
