import SwiftUI

/// In-app debug screen — tails the structured logs so a failed night can be inspected
/// on-device without a Mac. Lives behind "Stats for Nerds" in the full app; standalone here.
struct DebugLogView: View {
    @ObservedObject private var store = LogStore.shared
    @State private var filter: LogCategory?

    private var visibleEntries: [LogEntry] {
        guard let filter else { return store.entries }
        return store.entries(for: filter)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Filter", selection: $filter) {
                Text("All").tag(LogCategory?.none)
                ForEach(LogCategory.allCases, id: \.self) { cat in
                    Text(cat.rawValue.capitalized).tag(LogCategory?.some(cat))
                }
            }
            .pickerStyle(.segmented)
            .padding(8)

            List(visibleEntries.reversed()) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(entry.category.rawValue.uppercased())
                            .font(.caption2.bold())
                            .foregroundStyle(color(for: entry.category))
                        Spacer()
                        Text(entry.timestamp, format: .dateTime.hour().minute().second())
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.message)
                        .font(.caption.monospaced())
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle("Debug Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear") { store.clear() }
            }
        }
    }

    private func color(for category: LogCategory) -> Color {
        switch category {
        case .capture: return .blue
        case .window: return .green
        case .persist: return .purple
        case .lifecycle: return .orange
        case .guardrail: return .red
        }
    }
}
