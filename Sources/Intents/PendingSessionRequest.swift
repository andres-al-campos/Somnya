import Foundation
import Combine

/// Bridges the App Intent process and the running app. The intent records a "start requested"
/// flag; the app consumes it when it becomes active and drives the real SessionManager.
///
/// Backed by UserDefaults so the signal survives the intent process exiting and the app
/// launching fresh — the intent's process and the app's process don't share memory.
@MainActor
final class PendingSessionRequest: ObservableObject {
    static let shared = PendingSessionRequest()

    private let key = "com.aurende.somnya.pendingStart"
    private let methodKey = "com.aurende.somnya.pendingStartMethod"

    /// Record that a session should start (called from the intent).
    func requestStart(method: DetectionMethod) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: key)
        defaults.set(method.rawValue, forKey: methodKey)
    }

    /// Consume a pending request, if any. Returns the method to start with, or nil.
    func consumePendingStart() -> DetectionMethod? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: key) else { return nil }
        defaults.set(false, forKey: key)
        let raw = defaults.string(forKey: methodKey) ?? DetectionMethod.gesture.rawValue
        return DetectionMethod(rawValue: raw) ?? .gesture
    }
}
