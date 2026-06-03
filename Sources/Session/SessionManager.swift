import Foundation
import SwiftData
import UIKit
import AVFoundation

/// Owns the lifecycle of a sleep session: start (with guardrails + screen management),
/// stop, and the active-session reference. Sensor capture layers attach to the active
/// session via `currentSession`. Kept @MainActor because it touches UIApplication and
/// publishes UI state.
@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var currentSession: SleepSession?
    @Published private(set) var lastGuardrailResults: [GuardrailResult] = []
    @Published private(set) var windowCount = 0

    private let context: ModelContext
    private let motion = MotionCapture()
    private var aggregator: WindowAggregator?

    init(context: ModelContext) {
        self.context = context
    }

    var isTracking: Bool { currentSession != nil }

    /// Live mic-permission state, read from the OS (not a stale passed-in flag).
    private var micGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    /// (Re)run the start-up guardrails against the CURRENT real state of motion + mic.
    /// Safe to call multiple times — e.g. again once the first motion sample arrives.
    func refreshGuardrails() {
        lastGuardrailResults = Guardrails.runSessionStartChecks(
            motionActive: motion.isActive && motion.hasDeliveredSample,
            micActive: micGranted
        )
    }

    @discardableResult
    func startSession(method: DetectionMethod) -> SleepSession {
        // If a session is already active, don't silently stack a second one.
        if let existing = currentSession {
            SomnyaLog.lifecycle("startSession ignored — session already active (started \(existing.startTime))")
            return existing
        }

        // Keep the screen awake; without this the phone locks and motion updates stop —
        // the most common "it recorded nothing" cause.
        UIApplication.shared.isIdleTimerDisabled = true

        let session = SleepSession(startTime: Date(), detectionMethod: method)
        context.insert(session)
        do {
            try context.save()
            SomnyaLog.persist("SleepSession saved id=\(session.persistentModelID.hashValue) method=\(method.rawValue)")
        } catch {
            SomnyaLog.persist("FAILED to save SleepSession: \(error)")
        }

        currentSession = session
        windowCount = 0
        SomnyaLog.lifecycle("Session STARTED method=\(method.rawValue) at \(session.startTime)")

        // Wire up capture: aggregator persists windows; motion feeds it decimated samples.
        let agg = WindowAggregator(context: context, session: session)
        aggregator = agg
        motion.onSample = { [weak self] sample in
            // MotionCapture delivers off the main thread; hop back for SwiftData + UI.
            Task { @MainActor in
                guard let self, self.currentSession != nil else { return }
                let before = (self.currentSession?.windows.count ?? 0)
                agg.ingest(sample)
                let after = (self.currentSession?.windows.count ?? 0)
                if after != before { self.windowCount = after }
            }
        }
        // Re-check guardrails the moment real motion data flows in (avoids the start-time
        // race where isDeviceMotionActive hasn't flipped yet).
        motion.onFirstSample = { [weak self] in
            Task { @MainActor in self?.refreshGuardrails() }
        }
        motion.start()

        // Initial guardrail pass against current real state (motion may still be spinning up;
        // it'll be re-checked on first sample, and mic reflects the actual permission).
        refreshGuardrails()
        return session
    }

    /// Stop the active session, set its end time, and release the screen lock.
    func stopSession(reason: String = "manual stop") {
        guard let session = currentSession else {
            SomnyaLog.lifecycle("stopSession ignored — no active session")
            return
        }
        // Stop capture first so the last partial window is flushed before we finalize.
        motion.stop()
        motion.onSample = nil
        aggregator?.finalize()
        aggregator = nil

        session.endTime = Date()
        do {
            try context.save()
            SomnyaLog.persist("SleepSession finalized endTime=\(session.endTime!)")
        } catch {
            SomnyaLog.persist("FAILED to finalize SleepSession: \(error)")
        }

        UIApplication.shared.isIdleTimerDisabled = false
        SomnyaLog.lifecycle("Session STOPPED reason=\(reason) duration=\(Int(session.duration))s")
        currentSession = nil
    }
}
