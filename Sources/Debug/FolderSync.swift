import Foundation
import UIKit

/// Sync finished nights into a folder picked once in the system folder picker — usually the Mac's
/// `analysis/sessions/` shared over SMB and connected in Files. The platform does the networking, so
/// there's no server, no IP to type and no local-network permission; the same button works for a USB
/// drive or any other Files location.
///
/// "Missing" is decided by what's in the folder, not by `exportedAt`: files deleted on the Mac come
/// back on the next sync.
@MainActor
enum FolderSync {
    private static let bookmarkKey = "syncFolderBookmark"

    /// The folder picked last time, or nil if none was picked or its bookmark no longer resolves.
    static func folder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
        if stale { try? setFolder(url) }
        return url
    }

    static func setFolder(_ url: URL) throws {
        guard url.startAccessingSecurityScopedResource() else { throw SyncError.noAccess }
        defer { url.stopAccessingSecurityScopedResource() }
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

    /// Write every night the folder doesn't have yet, one at a time — serializing them all up front
    /// would hold the whole backlog (tens of MB a night) in memory at once. Returns how many were written.
    static func sync(_ sessions: [SleepSession], progress: (Int, Int) -> Void) async throws -> Int {
        guard let folder = folder() else { throw SyncError.noFolder }
        guard folder.startAccessingSecurityScopedResource() else { throw SyncError.unreachable }
        defer { folder.stopAccessingSecurityScopedResource() }

        // iOS suspends the app soon after the screen locks or it's left, and a write over SMB stops
        // with it: the first backlog sync stalled mid-night that way. So keep the screen on while it
        // runs, and ask for grace time if it's backgrounded anyway. Restore the idle setting rather
        // than clearing it, since tracking keeps the screen on too.
        let app = UIApplication.shared
        let wasIdleDisabled = app.isIdleTimerDisabled
        app.isIdleTimerDisabled = true
        var grace = UIBackgroundTaskIdentifier.invalid
        grace = app.beginBackgroundTask(withName: "FolderSync") {
            app.endBackgroundTask(grace)
            grace = .invalid
        }
        defer {
            app.isIdleTimerDisabled = wasIdleDisabled
            if grace != .invalid { app.endBackgroundTask(grace) }
        }

        let present: Set<String>
        do {
            present = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        } catch {
            throw SyncError.unreachable
        }
        let missing = sessions.filter { !present.contains(SessionJSON.fileName(for: $0)) }

        for (i, session) in missing.enumerated() {
            progress(i + 1, missing.count)
            // make() reads managed objects, so it stays on the main actor; the write (slow over SMB)
            // goes off-main so the progress overlay keeps painting.
            let data = try SessionJSON.make(from: session)
            let url = folder.appendingPathComponent(SessionJSON.fileName(for: session))
            try await Task.detached(priority: .userInitiated) {
                try data.write(to: url, options: .atomic)
            }.value
            session.exportedAt = Date()
        }
        return missing.count
    }

    enum SyncError: LocalizedError {
        case noFolder, noAccess, unreachable
        var errorDescription: String? {
            switch self {
            case .noFolder:
                return "No sync folder chosen. Open the Export menu, tap Choose sync folder, and pick a folder."
            case .noAccess:
                return "Somnya wasn't given access to that folder. Choose it again from the Export menu."
            case .unreachable:
                return "Can't reach the sync folder. Wake the Mac, check the phone is on the same Wi-Fi, open the folder once in the Files app to reconnect, then try again. If it still fails, choose the folder again."
            }
        }
    }
}
