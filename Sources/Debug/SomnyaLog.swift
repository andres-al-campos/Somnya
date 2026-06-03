import Foundation
import OSLog

/// Structured logging — a build requirement in every phase. "It didn't track" must be
/// diagnosable in under a minute. The four most likely causes of "recorded nothing" each
/// map to exactly one of these categories going silent:
///   - capture   → sensor never delivered samples
///   - window    → 30s aggregation never ran
///   - persist   → writes never landed in SwiftData
///   - lifecycle → session start/stop and stop reason
///
/// Logs go to OSLog (Console.app / device) AND to an in-memory ring buffer that the in-app
/// debug screen tails, so a failed night can be inspected on-device without a Mac.
enum LogCategory: String, CaseIterable {
    case capture
    case window
    case persist
    case lifecycle
    case guardrail
}

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let category: LogCategory
    let message: String
}

/// Thread-safe in-app log sink the debug screen observes.
@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()
    @Published private(set) var entries: [LogEntry] = []
    private let maxEntries = 2000

    func append(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() { entries.removeAll() }

    func entries(for category: LogCategory) -> [LogEntry] {
        entries.filter { $0.category == category }
    }
}

enum SomnyaLog {
    private static let subsystem = "com.aurende.somnya"
    private static var loggers: [LogCategory: Logger] = {
        var map: [LogCategory: Logger] = [:]
        for cat in LogCategory.allCases {
            map[cat] = Logger(subsystem: subsystem, category: cat.rawValue)
        }
        return map
    }()

    static func log(_ category: LogCategory, _ message: String) {
        loggers[category]?.log("\(message, privacy: .public)")
        let entry = LogEntry(timestamp: Date(), category: category, message: message)
        Task { @MainActor in LogStore.shared.append(entry) }
    }

    static func capture(_ m: String)   { log(.capture, m) }
    static func window(_ m: String)    { log(.window, m) }
    static func persist(_ m: String)   { log(.persist, m) }
    static func lifecycle(_ m: String) { log(.lifecycle, m) }
    static func guardrail(_ m: String) { log(.guardrail, m) }
}
