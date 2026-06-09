import SwiftUI

/// One-time sound-level calibration: teach Somnya what real decibels its mic readings correspond to,
/// so the audio chart can show the familiar "30=whisper, 60=conversation, 85=traffic" dB-SPL scale
/// instead of an uncalibrated relative level. Lives in the test page, after the Sonar Tone test.
///
/// Flow: hold a reference SPL meter (a free phone app on a 2nd device works) next to this phone,
/// play a steady sound, let this meter average for a few seconds, type in the reference reading, tap
/// Calibrate. The offset is stored per-device and used everywhere dB-SPL is shown.
struct CalibrationView: View {
    @StateObject private var meter = CalibrationTester()
    @State private var referenceText: String = ""
    /// The user's measured offset (nil = running on the nominal default).
    @State private var userOffset: Double? = SomnyaConfig.userSPLOffsetDB
    @State private var justCalibrated = false

    private var referenceDB: Double? { Double(referenceText) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("The audio chart already shows approximate decibels (whisper ≈ 30, conversation ≈ 60, traffic ≈ 85) using a built-in default that's within a few dB on any iPhone. Calibrate here only if you want it dialed in to your exact phone — measure against a real sound meter and Somnya learns the precise offset.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                // Live meter readout.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Live level")
                        .font(.headline)
                    Text(meter.isMeasuring ? String(format: "%.1f dBFS", meter.liveDBFS) : "—")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(meter.isMeasuring
                         ? String(format: "Averaging: %.1f dBFS over %d samples", meter.averageDBFS, meter.sampleCount)
                         : "Tap Start, play a steady sound, and let it average for a few seconds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    meter.isMeasuring ? meter.stop() : meter.start()
                } label: {
                    Label(meter.isMeasuring ? "Stop Meter" : "Start Meter",
                          systemImage: meter.isMeasuring ? "stop.fill" : "mic.fill")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.borderedProminent)
                .tint(meter.isMeasuring ? .red : .indigo)

                if meter.isMeasuring {
                    Button("Reset average") { meter.resetAverage() }
                        .font(.callout)
                        .buttonStyle(.bordered)
                        .tint(.gray)
                }

                if let err = meter.errorMessage {
                    Text(err)
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                Divider().overlay(Color.white.opacity(0.2))

                // Reference entry + calibrate.
                VStack(alignment: .leading, spacing: 10) {
                    Text("Reference meter reading")
                        .font(.headline)
                    HStack {
                        TextField("e.g. 68", text: $referenceText)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 140)
                            .foregroundStyle(.black)
                        Text("dB")
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        if let ref = referenceDB {
                            userOffset = meter.calibrate(referenceDB: ref)
                            justCalibrated = true
                        }
                    } label: {
                        Label("Calibrate", systemImage: "checkmark.seal.fill")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(!meter.isMeasuring || referenceDB == nil || meter.sampleCount < 20)

                    if !meter.isMeasuring {
                        Text("Start the meter and let it average before calibrating.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if meter.sampleCount < 20 {
                        Text("Let the average settle (a few seconds of steady sound) first.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                // Current calibration state. dB-SPL always works (nominal default); calibration just
                // upgrades it from "approximate" to "your phone, measured".
                VStack(alignment: .leading, spacing: 4) {
                    if let offset = userOffset {
                        Label(String(format: "Calibrated to your phone — offset %.1f dB", offset),
                              systemImage: "checkmark.circle.fill")
                            .font(.callout.bold())
                            .foregroundStyle(.green)
                        if justCalibrated, meter.isMeasuring {
                            Text(String(format: "Right now that's ≈ %.0f dB-SPL.",
                                        meter.liveDBFS + offset))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Reset to default") {
                            SomnyaConfig.userSPLOffsetDB = nil
                            userOffset = nil
                            justCalibrated = false
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .tint(.gray)
                    } else {
                        Label(String(format: "Using approximate default (%.0f dB) — works now; calibrate for your exact phone.",
                                     SomnyaConfig.nominalSPLOffsetDB),
                              systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.top, 4)

                // How-to.
                VStack(alignment: .leading, spacing: 6) {
                    Text("How to calibrate")
                        .font(.headline)
                    Text("""
                    1. Open a reference SPL meter — a free app like NIOSH SLM or Decibel X on a second phone, or a physical meter.
                    2. Place both mics side by side, same distance from the sound.
                    3. Play a steady sound (pink/white noise or a fan), ideally a moderate ~60–75 dB.
                    4. Tap Start, keep the sound constant, and let the average settle for a few seconds.
                    5. Type the reference meter's reading and tap Calibrate.

                    Tip: repeat at a second, quieter level (~50 dB) to double-check — the two offsets should be close.
                    """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("This is approximate (the mic's auto-gain drifts a little), so dB-SPL is shown as an estimate, not a precision instrument.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle("Sound Level Calibration")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color.black.opacity(0.94))
        .foregroundStyle(.white)
        .onDisappear { meter.stop() }
    }
}
