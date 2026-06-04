import SwiftUI
import UIKit

/// Thin UIKit bridge for the system share sheet. Used to hand exported files (CSV now; envelope
/// CSV / raw audio later) off to Files, AirDrop, Mail, etc. Items are URLs so future audio files
/// flow through the exact same path.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
