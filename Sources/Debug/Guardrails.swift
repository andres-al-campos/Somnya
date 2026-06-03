import Foundation
import UIKit

/// A single guardrail result. `passed == false` should surface a visible warning, because a
/// failed guardrail is the most common cause of a silent "it recorded nothing" night.
struct GuardrailResult: Identifiable {
    let id = UUID()
    let name: String
    let passed: Bool
    /// What went wrong + how to fix it (per the global error-message convention).
    let detail: String
}

/// Checks run at session start. These do not throw — they report, so the session can still
/// proceed while the user sees exactly what's degraded.
enum Guardrails {

    /// `motionActive` and `micActive` are passed in by the capture layer once it has tried to
    /// start; the guardrail only knows what it's told.
    static func runSessionStartChecks(motionActive: Bool, micActive: Bool) -> [GuardrailResult] {
        var results: [GuardrailResult] = []

        // 1. Idle timer must be disabled, or the phone locks mid-session and motion stops.
        let idleDisabled = UIApplication.shared.isIdleTimerDisabled
        results.append(GuardrailResult(
            name: "Screen stays awake",
            passed: idleDisabled,
            detail: idleDisabled
                ? "Auto-lock is disabled for this session."
                : "Auto-lock is still on — the phone may sleep and stop tracking. The session will try to keep the screen awake; if tracking stops, check Settings → Display."
        ))

        // 2. Motion updates must actually be running.
        results.append(GuardrailResult(
            name: "Motion updates active",
            passed: motionActive,
            detail: motionActive
                ? "Accelerometer is delivering data."
                : "Motion updates did not start. Movement won't be recorded. Restart the session; if it persists, ensure the app has motion access and you're on a real device."
        ))

        // 3. Mic session is the keepalive — without it, a locked phone suspends the app.
        results.append(GuardrailResult(
            name: "Microphone session active",
            passed: micActive,
            detail: micActive
                ? "Audio session is holding the app alive in the background."
                : "Microphone session did not start. The app may stop tracking when the screen locks. Grant microphone permission in Settings → Somnya, then restart the session."
        ))

        // 4. Real device check — CoreMotion is empty on the simulator.
        #if targetEnvironment(simulator)
        results.append(GuardrailResult(
            name: "Running on real device",
            passed: false,
            detail: "Running on the Simulator — motion sensors return no data here. Build and run on a physical iPhone to actually track sleep."
        ))
        #else
        results.append(GuardrailResult(
            name: "Running on real device",
            passed: true,
            detail: "Running on a physical device."
        ))
        #endif

        for r in results {
            SomnyaLog.guardrail("\(r.name): \(r.passed ? "PASS" : "FAIL") — \(r.detail)")
        }
        return results
    }
}
