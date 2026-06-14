import Foundation
import SwiftData

// MARK: - Detection method

/// How a session was started. Per spec: gesture is the fast path, manual is the in-hand path,
/// auto is reserved for future automatic detection (not in MVP).
enum DetectionMethod: String, Codable {
    case gesture
    case manual
    case auto
}

/// Three-class staging target. N1/N2 are collapsed into light+wake (undetectable without EEG).
/// `unknown` is the honest default before/without a confident classification.
enum SleepStage: String, Codable {
    case deep
    case rem
    case lightWake = "light_wake"
    case unknown
}

// MARK: - SleepDay

/// Groups a primary sleep session plus any naps into one "sleep day".
/// Day boundary is configurable (default 6pm) so a 2am bedtime belongs to the prior day.
@Model
final class SleepDay {
    /// The calendar day this group represents (normalized to the day boundary).
    var date: Date
    @Relationship(deleteRule: .cascade, inverse: \SleepSession.day)
    var sessions: [SleepSession]

    init(date: Date) {
        self.date = date
        self.sessions = []
    }
}

// MARK: - SleepSession

/// One sleep event (a night, or a nap). Writes are incremental at the window level so a
/// crash loses at most one 30s window.
@Model
final class SleepSession {
    var startTime: Date
    var endTime: Date?
    var detectionMethodRaw: String
    /// Initial mic noise-floor baseline (dB-relative); refined adaptively during the session.
    var noiseFloorBaseline: Double?
    /// Optional user tags: e.g. "nap", "alcohol", "bad night".
    var tags: [String]
    var notes: String?
    /// Optional subjective restedness (1-3 faces). A *correlate* only — never training data.
    var restednessRating: Int?
    /// When this session was last exported to JSON. nil = never exported. Drives "export new" so a
    /// batch export skips nights already pulled to the Mac. It's the app's belief, not a Mac receipt —
    /// if the files are lost on the Mac, "export all" re-exports regardless of this stamp.
    var exportedAt: Date?

    @Relationship var day: SleepDay?
    @Relationship(deleteRule: .cascade, inverse: \SensorWindow.session)
    var windows: [SensorWindow]
    @Relationship(deleteRule: .cascade, inverse: \SleepPhase.session)
    var phases: [SleepPhase]
    /// Cached derived analyses (onset + HR track) so reopening a finished night is instant. Cascade so
    /// deleting the session removes its snapshot; recomputed automatically when the algorithm version bumps.
    @Relationship(deleteRule: .cascade, inverse: \SessionAnalysisCache.session)
    var analysisCache: SessionAnalysisCache?

    var detectionMethod: DetectionMethod {
        get { DetectionMethod(rawValue: detectionMethodRaw) ?? .manual }
        set { detectionMethodRaw = newValue.rawValue }
    }

    var isActive: Bool { endTime == nil }

    var duration: TimeInterval {
        (endTime ?? Date()).timeIntervalSince(startTime)
    }

    init(startTime: Date = Date(), detectionMethod: DetectionMethod) {
        self.startTime = startTime
        self.endTime = nil
        self.detectionMethodRaw = detectionMethod.rawValue
        self.noiseFloorBaseline = nil
        self.tags = []
        self.notes = nil
        self.restednessRating = nil
        self.exportedAt = nil
        self.windows = []
        self.phases = []
        self.analysisCache = nil
    }
}

// MARK: - SleepPhase

/// A classified segment within a session. Confidence comes from the model, not a hand-set
/// ceiling. No user-correction field — corrections are not a training source.
@Model
final class SleepPhase {
    var startTime: Date
    var endTime: Date
    var stageRaw: String
    var confidence: Double
    /// Which classifier version produced this — so old phases can be re-evaluated.
    var classifierVersion: String

    @Relationship var session: SleepSession?

    var stage: SleepStage {
        get { SleepStage(rawValue: stageRaw) ?? .unknown }
        set { stageRaw = newValue.rawValue }
    }

    init(startTime: Date, endTime: Date, stage: SleepStage, confidence: Double, classifierVersion: String) {
        self.startTime = startTime
        self.endTime = endTime
        self.stageRaw = stage.rawValue
        self.confidence = confidence
        self.classifierVersion = classifierVersion
    }
}

// MARK: - SensorWindow

/// One 30-second analysis window. Holds all computed features from active sensors plus an
/// optional raw buffer. These feature vectors are the input a future GMM/HSMM is fit on.
@Model
final class SensorWindow {
    var startTime: Date
    /// Window length in seconds (normally 30; stored so it's explicit, not assumed).
    var windowSeconds: Double

    // Accelerometer features (computed per spec: jerk + activity count are day-one).
    var accelRMS: Double
    var accelJerkRMS: Double
    var accelActivityCount: Double
    var accelENMOMean: Double
    var immobilityRunLength: Int
    /// Smoothed tilt angle (van Hees z-angle), discretized posture, and posture changes.
    var tiltAngle: Double
    var postureChangeCount: Int
    /// Dense accel-magnitude envelope (~8 Hz, gravity-removed) for this window. Captured so the
    /// breathing estimator can run on BED MOTION offline (ballistocardiography) — a silent,
    /// emission-free alternative to the mic when the phone rests on the mattress. Same "capture
    /// dense, re-slice forever" rationale as the audio envelope.
    var accelEnvelope: [Double]?
    /// Dense gyro-magnitude envelope (~8 Hz) — rotational micro-motion, for accel+gyro fusion on
    /// heartbeat/BCG offline. Free from the same device-motion callback.
    var gyroEnvelope: [Double]?
    /// Mean gravity vector (g) over the window — sleep POSTURE (back / left / right side). Drift-free.
    var gravityX: Double?
    var gravityY: Double?
    var gravityZ: Double?
    /// Ambient pressure (kPa) and relative altitude (m) from the barometer, sampled per window.
    /// Tracks weather fronts that affect sleep; possibly breathing micro-pressure. nil if no barometer.
    var pressureKPa: Double?
    var relativeAltitudeM: Double?

    // Microphone features (nil until the mic analyzer lands; persisted alongside accel).
    var audioRMS: Double?
    var audioFloor: Double?
    var breathingRate: Double?
    var breathingRateVariability: Double?
    /// Autocorrelation peak height [0...1] for the breathing estimate — exported so the offline
    /// tool can sweep the confidence threshold and tune it against real nights.
    var breathingConfidence: Double?
    /// The raw ~10 Hz loudness envelope for this window (~300 floats). Stored so window size and
    /// thresholds can be re-experimented OFFLINE from the same capture — record dense once,
    /// re-slice forever — instead of baking the 30s choice into the device.
    var audioEnvelope: [Double]?
    /// The band-passed envelope — what breathing detection runs on. Kept alongside the raw one so
    /// the before/after effect of the filter is inspectable, not assumed.
    var audioEnvelopeFiltered: [Double]?
    /// Mel-band energies (~10-20 bins over the breathing band) — future-proofing for a learned model.
    var melBandEnergies: [Double]?

    /// Stage assigned to this window by the current classifier (may be .unknown).
    var assignedStageRaw: String
    var assignedConfidence: Double

    @Relationship var session: SleepSession?

    var assignedStage: SleepStage {
        get { SleepStage(rawValue: assignedStageRaw) ?? .unknown }
        set { assignedStageRaw = newValue.rawValue }
    }

    init(startTime: Date,
         windowSeconds: Double,
         accelRMS: Double,
         accelJerkRMS: Double,
         accelActivityCount: Double,
         accelENMOMean: Double,
         immobilityRunLength: Int,
         tiltAngle: Double,
         postureChangeCount: Int,
         accelEnvelope: [Double]? = nil,
         gyroEnvelope: [Double]? = nil,
         gravityX: Double? = nil,
         gravityY: Double? = nil,
         gravityZ: Double? = nil,
         pressureKPa: Double? = nil,
         relativeAltitudeM: Double? = nil,
         audioRMS: Double? = nil,
         audioFloor: Double? = nil,
         breathingRate: Double? = nil,
         breathingRateVariability: Double? = nil,
         breathingConfidence: Double? = nil,
         audioEnvelope: [Double]? = nil,
         audioEnvelopeFiltered: [Double]? = nil,
         melBandEnergies: [Double]? = nil) {
        self.startTime = startTime
        self.windowSeconds = windowSeconds
        self.accelRMS = accelRMS
        self.accelJerkRMS = accelJerkRMS
        self.accelActivityCount = accelActivityCount
        self.accelENMOMean = accelENMOMean
        self.immobilityRunLength = immobilityRunLength
        self.tiltAngle = tiltAngle
        self.postureChangeCount = postureChangeCount
        self.accelEnvelope = accelEnvelope
        self.gyroEnvelope = gyroEnvelope
        self.gravityX = gravityX
        self.gravityY = gravityY
        self.gravityZ = gravityZ
        self.pressureKPa = pressureKPa
        self.relativeAltitudeM = relativeAltitudeM
        self.audioRMS = audioRMS
        self.audioFloor = audioFloor
        self.breathingRate = breathingRate
        self.breathingRateVariability = breathingRateVariability
        self.breathingConfidence = breathingConfidence
        self.audioEnvelope = audioEnvelope
        self.audioEnvelopeFiltered = audioEnvelopeFiltered
        self.melBandEnergies = melBandEnergies
        self.assignedStageRaw = SleepStage.unknown.rawValue
        self.assignedConfidence = 0
    }
}
