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

    @Relationship var day: SleepDay?
    @Relationship(deleteRule: .cascade, inverse: \SensorWindow.session)
    var windows: [SensorWindow]
    @Relationship(deleteRule: .cascade, inverse: \SleepPhase.session)
    var phases: [SleepPhase]

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
        self.windows = []
        self.phases = []
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

    // Microphone features (nil until the mic analyzer lands; persisted alongside accel).
    var audioRMS: Double?
    var audioFloor: Double?
    var breathingRate: Double?
    var breathingRateVariability: Double?
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
         audioRMS: Double? = nil,
         audioFloor: Double? = nil,
         breathingRate: Double? = nil,
         breathingRateVariability: Double? = nil,
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
        self.audioRMS = audioRMS
        self.audioFloor = audioFloor
        self.breathingRate = breathingRate
        self.breathingRateVariability = breathingRateVariability
        self.melBandEnergies = melBandEnergies
        self.assignedStageRaw = SleepStage.unknown.rawValue
        self.assignedConfidence = 0
    }
}
