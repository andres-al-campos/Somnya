import Foundation
import AVFoundation
import UIKit

/// Wraps the microphone permission lifecycle. Three meaningful states drive the onboarding UI:
/// undetermined (can ask) → granted → denied (can only deep-link to Settings).
@MainActor
final class MicPermission: ObservableObject {

    enum State: Equatable {
        case undetermined  // never asked — we can show the system dialog
        case granted
        case denied        // user said no, or restricted — must go to Settings now
    }

    @Published private(set) var state: State = .undetermined

    init() { refresh() }

    /// Read the current OS-level permission into our state.
    func refresh() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:      state = .granted
        case .denied:       state = .denied
        case .undetermined: state = .undetermined
        @unknown default:   state = .undetermined
        }
        SomnyaLog.lifecycle("Mic permission state = \(state)")
    }

    /// Trigger the system permission dialog. Only does anything when undetermined; iOS will
    /// not re-show the dialog after a decision (that's what `openSettings()` is for).
    func request() async {
        guard state == .undetermined else {
            SomnyaLog.lifecycle("Mic permission request skipped — already decided (\(state))")
            return
        }
        let granted = await AVAudioApplication.requestRecordPermission()
        state = granted ? .granted : .denied
        SomnyaLog.lifecycle("Mic permission dialog result = \(granted ? "granted" : "denied")")
    }

    /// Deep-link to this app's page in Settings, where a denied permission can be re-enabled.
    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        SomnyaLog.lifecycle("Opened Settings for mic permission")
    }
}
