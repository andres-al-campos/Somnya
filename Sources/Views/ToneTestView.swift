import SwiftUI

/// Sonar comfort test: play a clean, phone-generated tone at each candidate frequency and judge
/// whether it bothers you (headache, audible whine) — the honest precondition for any sonar build.
/// A YouTube tone can't answer this (encoding artifacts); a math-generated sine can.
struct ToneTestView: View {
    @StateObject private var tone = ToneTester()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Play a clean tone to test whether the sonar band (18–22 kHz) bothers you or anything around you. Start LOW volume. Stop immediately if you feel discomfort.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Frequency: \(Int(tone.frequency)) Hz")
                        .font(.headline)
                    HStack {
                        ForEach(ToneTester.testFrequencies, id: \.self) { f in
                            Button {
                                let wasPlaying = tone.isPlaying
                                if wasPlaying { tone.stop() }
                                tone.frequency = f
                                if wasPlaying { tone.start() }
                            } label: {
                                Text("\(Int(f / 1000))k")
                                    .font(.caption.bold())
                                    .frame(maxWidth: .infinity, minHeight: 36)
                            }
                            .buttonStyle(.bordered)
                            .tint(tone.frequency == f ? .indigo : .gray)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Volume (amplitude): \(String(format: "%.2f", tone.amplitude))")
                        .font(.headline)
                    Slider(value: $tone.amplitude, in: 0.02...0.5)
                        .disabled(tone.isPlaying)
                    Text("Set before playing. Lower is safer; raise only if you can't tell it's on.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Button {
                    tone.isPlaying ? tone.stop() : tone.start()
                } label: {
                    Label(tone.isPlaying ? "Stop Tone" : "Play Tone",
                          systemImage: tone.isPlaying ? "stop.fill" : "play.fill")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.borderedProminent)
                .tint(tone.isPlaying ? .red : .indigo)

                Text("What to check: Can you hear a whine? Any head pressure/headache after ~30s? Does the neighbor's pet react? Note which frequencies are clean for you — that's the usable sonar band.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle("Sonar Tone Test")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color.black.opacity(0.94))
        .foregroundStyle(.white)
        .onDisappear { tone.stop() }
    }
}
