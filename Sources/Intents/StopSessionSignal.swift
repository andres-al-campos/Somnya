import Foundation
import notify

/// Cross-process channel for "stop the running session", used by `StopSessionIntent`.
///
/// Why not the UserDefaults flag that `PendingSessionRequest` uses for *start*: that flag is
/// consumed when the app becomes active, which is exactly the wrong moment for a stop. A stop
/// must not require foregrounding Somnya — the whole point of stopping from an alarm automation
/// is to hand the screen to the *next* action (opening another app), so pulling Somnya to the
/// front would defeat it.
///
/// Darwin notifications are one of the few IPC mechanisms iOS allows between an App Intent's
/// short-lived process and the running app without an app group or foregrounding. They carry no
/// payload and aren't queued — a post while the app is dead is simply lost, which is the correct
/// behaviour here: if the app isn't running there's no live session to stop, and orphan recovery
/// closes the record at next launch.
enum StopSessionSignal {
    /// Must match on both sides; Darwin notification names are a global namespace, so it's
    /// bundle-qualified to avoid colliding with anything else on the device.
    private static let name = "com.aurende.somnya.stopSession"

    /// Broadcast a stop request (called from the intent process).
    static func post() {
        notify_post(name)
    }

    /// Listen for stop requests. The handler runs on the main queue, so it can touch
    /// SessionManager directly. Returns a token to keep alive for as long as you want to observe.
    @discardableResult
    static func observe(_ handler: @escaping () -> Void) -> Int32 {
        var token: Int32 = 0
        notify_register_dispatch(name, &token, .main) { _ in
            handler()
        }
        return token
    }
}
