// ShellChangesStore.swift
// Keeps each session's shell changes (files a Bash command changed, per turn) on disk, so a
// relaunch of the app does not lose them. The transcript cannot bring them back: background
// agents edit with `sed`, heredocs and scripts, which leave no Edit or Write call to read.
// One JSON file per session under ~/Library/Application Support/notchcode/shell-changes/.
// Files unused for `Theme.Timing.shellChangesKeep` are dropped the first time any is read.

import Foundation

enum ShellChangesStore {
    private static var directory: URL {
        NotchcodePaths.supportDirectory.appendingPathComponent("shell-changes", isDirectory: true)
    }

    private static func url(for sessionId: String) -> URL {
        let safe = sessionId.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return directory.appendingPathComponent(safe + ".json")
    }

    private static let queue = DispatchQueue(label: "notchcode.shell-changes", qos: .utility)
    private static var pruned = false

    /// The session's saved shell changes by turn id, or empty.
    static func load(sessionId: String) -> [String: [FileChange]] {
        if !pruned {
            pruned = true
            queue.async { prune() }
        }
        guard let data = try? Data(contentsOf: url(for: sessionId)),
              let saved = try? JSONDecoder().decode([String: [FileChange]].self, from: data)
        else { return [:] }
        return saved
    }

    /// Writes the session's shell changes in the background; an empty map removes the file.
    static func save(_ files: [String: [FileChange]], sessionId: String) {
        let target = url(for: sessionId)
        queue.async {
            if files.isEmpty {
                try? FileManager.default.removeItem(at: target)
                return
            }
            guard let data = try? JSONEncoder().encode(files) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: target, options: .atomic)
        }
    }

    private static func prune() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-Theme.Timing.shellChangesKeep)
        for item in items {
            let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < cutoff { try? fm.removeItem(at: item) }
        }
    }
}
