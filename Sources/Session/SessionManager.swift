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
    /// The session just finished by stopSession(), held briefly so the UI can offer save/discard on a
    /// too-short recording. Cleared once the user decides (keep) or it's deleted (discard).
    @Published var lastFinishedSession: SleepSession?

    private let context: ModelContext
    private var isCleaningUp = false
    private let motion = MotionCapture()
    private let audio = AudioKeepalive()
    private var aggregator: WindowAggregator?
    private var pickup = PickupDetector()
    /// Kept alive for the process lifetime so the Shortcuts stop signal stays observed.
    private var stopSignalToken: Int32?

    init(context: ModelContext) {
        self.context = context
        SomnyaLog.lifecycle("SessionManager created")
        recoverOrphanedSessions()
        observeStopSignal()
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.closeIfCaptureStopped() }
        }
    }

    /// Close the active session at its last window if no window has landed for
    /// `captureStoppedSeconds`. Without this a session whose capture died when the app was
    /// suspended stayed "active" until the next Stop, hours later, and read as a 23-hour night.
    /// Returns whether it closed one.
    @discardableResult
    func closeIfCaptureStopped(now: Date = Date()) -> Bool {
        guard let session = currentSession else { return false }
        let lastWindow = session.windows.map(\.startTime).max() ?? session.startTime
        guard now.timeIntervalSince(lastWindow) > SomnyaConfig.captureStoppedSeconds else { return false }
        // Drop the partial window instead of flushing it: it holds only what arrived after the
        // app woke, which would land hours past the real end.
        aggregator?.closeHeartbeat()
        aggregator = nil
        finish(session, endTime: lastWindow.addingTimeInterval(SomnyaConfig.windowSeconds),
               endReason: .recovered,
               reason: "capture stopped \(Int(now.timeIntervalSince(lastWindow) / 60)) min before")
        return true
    }

    /// Listen for `StopSessionIntent` (Shortcuts/Siri/alarm automation). Registered once for the
    /// process lifetime rather than per-session, since the intent can fire at any time and a
    /// no-active-session stop is already a safe no-op.
    private func observeStopSignal() {
        stopSignalToken = StopSessionSignal.observe { [weak self] in
            guard let self else { return }
            guard self.currentSession != nil else {
                SomnyaLog.lifecycle("Stop signal received — no active session, ignoring")
                return
            }
            SomnyaLog.lifecycle("Stop signal received from Shortcuts intent")
            self.stopSession(reason: "shortcut intent", endReason: .intent)
        }
    }

    /// A clean stop always sets `endTime`. So any session WITHOUT one at launch is a crash
    /// leftover — it would otherwise show as "recording" forever and stack up. Close each at the end
    /// of its last window (best estimate of when capture died), or at its start if it has none.
    private func recoverOrphanedSessions() {
        let descriptor = FetchDescriptor<SleepSession>(
            predicate: #Predicate { $0.endTime == nil }
        )
        guard let orphans = try? context.fetch(descriptor), !orphans.isEmpty else { return }
        for s in orphans {
            let lastWindow = s.windows.map(\.startTime).max()
            s.endTime = lastWindow?.addingTimeInterval(SomnyaConfig.windowSeconds) ?? s.startTime
            // Mark it so history can show this end time is an estimate, not a real wake.
            s.endReason = .recovered
        }
        do {
            try context.save()
            SomnyaLog.lifecycle("Recovered \(orphans.count) orphaned session(s) from a prior crash — closed them so they no longer show as recording.")
        } catch {
            SomnyaLog.lifecycle("FAILED to recover orphaned sessions: \(error)")
        }
    }

    var isTracking: Bool { currentSession != nil }

    /// Live mic-permission state, read from the OS (not a stale passed-in flag).
    private var micGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    /// (Re)run the start-up guardrails against the CURRENT real state of motion + mic.
    /// Safe to call multiple times — e.g. again once the first motion sample arrives.
    /// Mic guardrail reflects the live audio session (the keepalive), not just the permission.
    func refreshGuardrails() {
        lastGuardrailResults = Guardrails.runSessionStartChecks(
            motionActive: motion.isActive && motion.hasDeliveredSample,
            micActive: micGranted && audio.isActive
        )
    }

    /// Runs when nothing is waiting on the phone: when a night ends, since the app can stay open for
    /// days without a launch, and at launch, since a run can be cut short by Start or by quitting.
    func cleanUpOldNights() async {
        guard !isCleaningUp else { return }
        isCleaningUp = true
        await RawRetention.prune(context.container)
        isCleaningUp = false
    }

    @discardableResult
    func startSession(method: DetectionMethod) -> SleepSession {
        // If a session is already active, don't silently stack a second one.
        if let existing = currentSession {
            if closeIfCaptureStopped() {
                return startSession(method: method)
            }
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
        // At each 30s flush, pull breathing features from the audio analyzer (nil if mic off).
        agg.audioFeatureProvider = { [weak self] in
            self?.audio.analyzer.snapshotWindow()
        }
        // At each flush, stamp the window with the latest barometer reading (nil if no barometer).
        agg.barometerProvider = { [weak self] in
            (self?.motion.latestPressureKPa, self?.motion.latestRelativeAltitudeM)
        }
        pickup = PickupDetector()
        agg.onWindow = { [weak self] window in
            guard let self, let nightEnd = self.pickup.observe(.init(window)) else { return }
            // Defer: this runs inside the aggregator's flush, which stopping would tear down.
            Task { @MainActor in
                guard self.currentSession === session else { return }
                self.aggregator?.closeHeartbeat()
                self.aggregator = nil
                self.finish(session, endTime: nightEnd, endReason: .pickup,
                            reason: "phone picked up and didn't go back to sleep")
            }
        }
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
        // Dense 50 Hz magnitude stream → the BCG/breathing envelope. Hop to main for the same
        // SwiftData-actor reasons; this only appends to in-memory buffers (cheap at 50 Hz).
        motion.onRawMagnitude = { [weak self] _, accelMag, gyroMag, gravity, vertical in
            Task { @MainActor in
                guard let self, self.currentSession != nil else { return }
                agg.ingestRawMagnitude(accelMag: accelMag, gyroMag: gyroMag, gravity: gravity, vertical: vertical)
            }
        }
        // Start the audio keepalive so the app survives the screen locking. Only attempt it
        // if mic permission is granted; otherwise log honestly and proceed motion-only
        // (foreground tracking still works, it just won't survive a lock).
        if micGranted {
            audio.start()
        } else {
            SomnyaLog.capture("Mic not granted — skipping audio keepalive. Tracking will stop when the screen locks. Grant mic in Settings → Somnya for overnight tracking.")
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
    func stopSession(reason: String = "manual stop", endReason: EndReason = .manualStop) {
        guard let session = currentSession else {
            SomnyaLog.lifecycle("stopSession ignored — no active session")
            return
        }
        if closeIfCaptureStopped() { return }
        // Flush the last partial window before finishing.
        aggregator?.finalize()
        aggregator = nil
        finish(session, endTime: pickup.restingEnd ?? Date(), endReason: endReason, reason: reason)
    }

    private func finish(_ session: SleepSession, endTime: Date, endReason: EndReason, reason: String) {
        motion.stop()
        motion.onSample = nil
        motion.onRawMagnitude = nil
        audio.stop()
        aggregator = nil

        session.endTime = endTime
        session.endReason = endReason
        deleteWindows(of: session, after: endTime)
        do {
            try context.save()
            SomnyaLog.persist("SleepSession finalized endTime=\(session.endTime!)")
        } catch {
            SomnyaLog.persist("FAILED to finalize SleepSession: \(error)")
        }

        UIApplication.shared.isIdleTimerDisabled = false
        SomnyaLog.lifecycle("Session STOPPED reason=\(reason) duration=\(Int(session.duration))s")
        lastFinishedSession = session  // surfaced so the UI can offer discard if it's too short
        currentSession = nil
        Task { await cleanUpOldNights() }
    }

    /// What was recorded while waiting to see if a pickup was the end. Fetched rather than read from
    /// `session.windows`, which would load the whole night's streams on the main thread.
    private func deleteWindows(of session: SleepSession, after end: Date) {
        let id = session.persistentModelID
        let tail = FetchDescriptor<SensorWindow>(
            predicate: #Predicate { $0.startTime >= end && $0.session?.persistentModelID == id })
        (try? context.fetch(tail))?.forEach(context.delete)
    }

    /// Discard a just-finished session the user chose not to keep (e.g. a too-short recording).
    /// Cascade-deletes its windows/cache. No-op if it's not the held finished session.
    func discardSession(_ session: SleepSession) {
        context.delete(session)
        do {
            try context.save()
            SomnyaLog.lifecycle("Session DISCARDED (too short / user choice) start=\(session.startTime)")
        } catch {
            SomnyaLog.persist("FAILED to discard session: \(error)")
        }
        if lastFinishedSession === session { lastFinishedSession = nil }
    }

    /// Keep a just-finished session (clear the pending save/discard prompt).
    func keepFinishedSession() { lastFinishedSession = nil }
}

extension PickupDetector.Reading {
    init(_ w: SensorWindow) {
        var gravity: (x: Double, y: Double, z: Double)?
        if let x = w.gravityX, let y = w.gravityY, let z = w.gravityZ { gravity = (x, y, z) }
        self.init(start: w.startTime, seconds: w.windowSeconds, gravity: gravity,
                  gyro: w.gyroMean ?? w.gyroEnvelope.flatMap { $0.isEmpty ? nil : $0.reduce(0, +) / Double($0.count) } ?? 0,
                  activity: w.accelActivityCount)
    }
}
