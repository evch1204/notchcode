// HooksInstaller.swift
// Adds and removes notchcode's hooks in ~/.claude/settings.json, so the Settings window
// can connect and disconnect without Node. Same rules as scripts/lib/settings.mjs:
//
//   - back up to settings.json.notchcode-backup-<timestamp> before any write; keep the newest 5
//   - a symlinked settings.json stays a link: the file it points at is rewritten
//   - add or replace only hook entries whose command contains "notchcode-hook.sh"
//   - never touch any other entry; an event key is removed only when it ends up empty
//   - 2-space pretty print, top-level and nested key order kept exactly
//   - statusLine: ours (notchcode-statusline.sh) replaces whatever was there, which is saved
//     first in ~/Library/Application Support/notchcode/statusline-chain.json as
//     {"previous": <old statusLine>} and keeps running through ours. Disconnect puts it back
//     (or removes the key when there was none) and deletes the chain file.
//   - hooks and the statusLine point at the app's copies of the scripts in
//     ~/Library/Application Support/notchcode/bin/, never into the app bundle, so moving or
//     updating the app never breaks them. The app refreshes the copies at every launch.
//
// JSONSerialization loses key order (NSDictionary), so this uses the small ordered JSON
// parser and printer in OrderedJSON.swift. Untouched strings and numbers are written back
// from their original text, so a connect followed by a disconnect gives back the same bytes
// (for a file that was already 2-space formatted, as Claude Code and Node write it).
//
// The table of hooks must match wantedHooks() in scripts/lib/settings.mjs and
// plugin/hooks/hooks.json; the statusLine logic matches planStatusLine() there.

import Foundation

enum HooksInstaller {
    /// Stale: ours are all there, but they point somewhere other than the bin copies, or at a
    /// copy that is gone (an older connect wrote the bundle's path, or the repo's), or our
    /// PermissionRequest entry still has an older timeout (65 s, before plans).
    enum Status { case connected, notConnected, partial, stale }

    enum InstallError: LocalizedError {
        case invalidJSON(String)
        case notAnObject(String)
        case hookScriptMissing(String)
        case chainUnreadable(String)

        var errorDescription: String? {
            switch self {
            case .invalidJSON(let why): return "settings.json is not valid JSON: \(why)"
            case .notAnObject(let what): return "\(what) in settings.json is not a JSON object; not touching it"
            case .hookScriptMissing(let path): return "hook script missing: \(path)"
            case .chainUnreadable(let path): return "the saved status line in \(path) is not readable; not touching the status line"
            }
        }
    }

    static let marker = "notchcode-hook.sh"
    static let statuslineMarker = "notchcode-statusline.sh"
    /// Keys of the previous statusLine that shape how it looks; ours copies them (same order as settings.mjs).
    private static let carriedStatusLineKeys = ["padding", "refreshInterval"]

    static var settingsPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json").path
    }

    /// Where the statusLine that was there before ours is saved. notchcode-statusline.sh reads it.
    static var chainPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/notchcode/statusline-chain.json").path
    }

    /// The status line script inside the app bundle, or the repo's hooks/ folder when running
    /// unbundled. Only the source of the bin copy; settings.json never names it.
    static var bundledStatuslineScriptPath: String {
        if let url = Bundle.main.url(forResource: "notchcode-statusline", withExtension: "sh") { return url.path }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("hooks/notchcode-statusline.sh").path
    }

    /// The hook script inside the app bundle, or the repo's hooks/ folder when running
    /// unbundled. Only the source of the bin copy; settings.json never names it.
    static var bundledHookScriptPath: String {
        if let url = Bundle.main.url(forResource: "notchcode-hook", withExtension: "sh") { return url.path }
        // Sources/notchcode/ClaudeCode/HooksInstaller.swift -> <repo>/hooks/notchcode-hook.sh
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("hooks/notchcode-hook.sh").path
    }

    /// The copy of the hook script that settings.json names.
    static var installedHookScriptPath: String {
        NotchcodePaths.binDirectory.appendingPathComponent("notchcode-hook.sh").path
    }

    /// The copy of the status line script that settings.json names. It runs the hook script
    /// beside it, so both copies live in the same folder.
    static var installedStatuslineScriptPath: String {
        NotchcodePaths.binDirectory.appendingPathComponent("notchcode-statusline.sh").path
    }

    // MARK: Public

    /// Copies both bundled scripts into the bin folder, each only when it is missing or its
    /// bytes differ, executable (0755). Runs at every launch and before every connect. Never
    /// throws: a failure is logged and the next launch or connect tries again.
    static func installScripts() {
        let fm = FileManager.default
        let bin = NotchcodePaths.binDirectory
        do {
            try fm.createDirectory(at: bin, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            debugLog("installScripts: cannot make \(bin.path): \(error)")
            return
        }
        for (source, target) in [(bundledHookScriptPath, installedHookScriptPath),
                                 (bundledStatuslineScriptPath, installedStatuslineScriptPath)] {
            guard let data = fm.contents(atPath: source) else {
                debugLog("installScripts: no script at \(source)")
                continue
            }
            do {
                if fm.contents(atPath: target) != data {
                    try data.write(to: URL(fileURLWithPath: target), options: .atomic)
                }
                let mode = (try? fm.attributesOfItem(atPath: target))?[.posixPermissions] as? NSNumber
                if mode?.intValue != 0o755 {
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target)
                }
            } catch {
                debugLog("installScripts: cannot copy \(source) to \(target): \(error)")
            }
        }
    }

    /// Connected means every hook and the statusLine are ours; partial means some are.
    /// Either one turns stale when an entry of ours does not name the bin folder, or names a
    /// copy that is not there.
    static func status() -> Status {
        guard let file = try? readSettings(settingsPath), case .object(let top) = file.root else { return .notConnected }
        var hooks: [OJ.Member] = []
        if let h = top.first(where: { $0.key == "hooks" })?.value, case .object(let m) = h { hooks = m }
        let events = wantedEventNames
        let present = events.filter { event in
            guard let groups = hooks.first(where: { $0.key == event })?.value,
                  case .array(let list) = groups else { return false }
            return list.contains(where: groupHasOurs)
        }
        let line = top.first(where: { $0.key == "statusLine" })?.value
        let lineOurs = line.map(isOurStatusLine) ?? false
        let count = present.count + (lineOurs ? 1 : 0)
        if count == 0 { return .notConnected }
        if isStale(hooks: hooks, line: lineOurs ? line : nil) { return .stale }
        return count == events.count + 1 ? .connected : .partial
    }

    /// True when one of our commands does not point into the bin folder, the copy it runs is
    /// missing, or our PermissionRequest hook's timeout is not the wanted one (a plan needs 305 s).
    private static func isStale(hooks: [OJ.Member], line: OJ?) -> Bool {
        let bin = NotchcodePaths.binDirectory.path
        let fm = FileManager.default
        let wantedPermission = wantedHooks { $0 }.first { $0.0 == "PermissionRequest" }
            .flatMap { hooksList($0.1)?.first }.flatMap(timeout(of:))
        var hookCommands: [String] = []
        var timeoutDiffers = false
        for member in hooks {
            guard case .array(let groups) = member.value else { continue }
            for group in groups {
                for hook in hooksList(group) ?? [] where isOurs(hook) {
                    if let c = command(of: hook) { hookCommands.append(c) }
                    if member.key == "PermissionRequest", timeout(of: hook) != wantedPermission { timeoutDiffers = true }
                }
            }
        }
        if timeoutDiffers { return true }
        if hookCommands.contains(where: { !$0.contains(bin) }) { return true }
        if !hookCommands.isEmpty, !fm.fileExists(atPath: installedHookScriptPath) { return true }
        if let line, let c = command(of: line) {
            if !c.contains(bin) { return true }
            // The status line copy runs the hook copy beside it, so both must be there.
            if !fm.fileExists(atPath: installedStatuslineScriptPath)
                || !fm.fileExists(atPath: installedHookScriptPath) { return true }
        }
        return false
    }

    static func connect() throws {
        let path = settingsPath
        // Hooks name the bin copies, so make sure they are there and current first.
        installScripts()
        let script = installedHookScriptPath
        guard FileManager.default.fileExists(atPath: script) else { throw InstallError.hookScriptMissing(script) }
        let lineScript = installedStatuslineScriptPath
        guard FileManager.default.fileExists(atPath: lineScript) else { throw InstallError.hookScriptMissing(lineScript) }
        let chain = chainPath

        // The bin copies are always executable, so the path is the whole command.
        func runnable(_ script: String) -> String { shellQuote(script) }
        let prefix = runnable(script)
        let wanted = wantedHooks { kind in "\(prefix) \(kind)" }
        let lineCommand = runnable(lineScript)

        var file = try readSettings(path)
        guard case .object(var top) = file.root else { throw InstallError.notAnObject("the top level") }
        let before = file.root

        var hooks: [OJ.Member] = []
        if let i = top.firstIndex(where: { $0.key == "hooks" }) {
            guard case .object(let h) = top[i].value else { throw InstallError.notAnObject("\"hooks\"") }
            hooks = h
        }

        for (event, group) in wanted {
            let existingIndex = hooks.firstIndex(where: { $0.key == event })
            var existing: [OJ] = []
            if let i = existingIndex, case .array(let a) = hooks[i].value { existing = a }
            let stripped = stripOurs(existing)
            let oldOurs = existing.filter(groupHasOurs)
            if stripped.removed == 1, oldOurs.count == 1, oldOurs[0].canonical == group.canonical { continue }

            var groups = stripped.groups
            groups.insert(group, at: stripped.firstIndex ?? groups.count)
            if let i = existingIndex {
                hooks[i].value = .array(groups)
            } else {
                hooks.append(OJ.Member(key: event, value: .array(groups)))
            }
        }

        // Our entries on events we no longer install (older versions).
        let wantedNames = Set(wanted.map(\.0))
        hooks = hooks.compactMap { member in
            guard !wantedNames.contains(member.key), case .array(let a) = member.value else { return member }
            let stripped = stripOurs(a)
            if stripped.removed == 0 { return member }
            if stripped.groups.isEmpty { return nil }
            var m = member
            m.value = .array(stripped.groups)
            return m
        }

        if let i = top.firstIndex(where: { $0.key == "hooks" }) {
            top[i].value = .object(hooks)
        } else {
            top.append(OJ.Member(key: "hooks", value: .object(hooks)))
        }

        // statusLine: ours, with the previous one chained.
        enum ChainPlan { case keep, write(OJ), remove }
        var chainPlan = ChainPlan.keep
        let lineIndex = top.firstIndex(where: { $0.key == "statusLine" })
        if let i = lineIndex, isOurStatusLine(top[i].value) {
            // Already ours: only bring the command up to date.
            if case .object(var m) = top[i].value, let c = m.firstIndex(where: { $0.key == "command" }),
               m[c].value.canonical != OJ.string(lineCommand).canonical {
                m[c].value = .string(lineCommand)
                top[i].value = .object(m)
            }
        } else {
            var ours: [OJ.Member] = [.init(key: "type", value: .string("command")),
                                     .init(key: "command", value: .string(lineCommand))]
            if let i = lineIndex, case .object(let old) = top[i].value {
                for key in carriedStatusLineKeys {
                    if let m = old.first(where: { $0.key == key }) { ours.append(.init(key: key, value: m.value)) }
                }
            }
            if let i = lineIndex {
                chainPlan = .write(top[i].value)
                top[i].value = .object(ours)
            } else {
                chainPlan = .remove
                top.append(OJ.Member(key: "statusLine", value: .object(ours)))
            }
        }

        file.root = .object(top)
        if file.existed, file.root.canonical == before.canonical { return }
        // Chain file first: the status line must never point at ours before the old one is saved.
        switch chainPlan {
        case .keep: break
        case .write(let previous): try writeChain(chain, previous: previous)
        case .remove: try? FileManager.default.removeItem(atPath: chain)
        }
        try writeSettings(path, file)
    }

    static func disconnect() throws {
        let path = settingsPath
        var file = try readSettings(path)
        guard file.existed else { return }
        guard case .object(var top) = file.root else { throw InstallError.notAnObject("the top level") }
        let chain = chainPath

        var changed = false
        var restored = false

        // statusLine: put back the saved one, or remove ours when there was none.
        // A statusLine that is not ours (changed by hand since) is left alone.
        if let li = top.firstIndex(where: { $0.key == "statusLine" }), isOurStatusLine(top[li].value) {
            if let previous = try readChain(chain) {
                top[li].value = previous
            } else {
                top.remove(at: li)
            }
            changed = true
            restored = true
        }

        if let hi = top.firstIndex(where: { $0.key == "hooks" }), case .object(let hooks) = top[hi].value {
            var hooksChanged = false
            let kept: [OJ.Member] = hooks.compactMap { member in
                guard case .array(let a) = member.value else { return member }
                let stripped = stripOurs(a)
                if stripped.removed == 0 { return member }
                hooksChanged = true
                if stripped.groups.isEmpty { return nil }
                var m = member
                m.value = .array(stripped.groups)
                return m
            }
            if hooksChanged {
                top[hi].value = .object(kept)   // left as {} when empty, like disconnect.mjs
                changed = true
            }
        }
        guard changed else { return }
        file.root = .object(top)
        try writeSettings(path, file)
        // Chain file last: until settings.json is written, ours may still run and needs it.
        if restored { try? FileManager.default.removeItem(atPath: chain) }
    }

    // MARK: The hooks we install

    private static var wantedEventNames: [String] { wantedHooks { $0 }.map(\.0) }

    /// Mirrors wantedHooks() in scripts/lib/settings.mjs, same order, same key order.
    private static func wantedHooks(_ cmd: (String) -> String) -> [(String, OJ)] {
        func handler(_ kind: String, timeout: Int, async: Bool, ifRule: String? = nil) -> OJ {
            var m: [OJ.Member] = [.init(key: "type", value: .string("command"))]
            if let ifRule { m.append(.init(key: "if", value: .string(ifRule))) }
            m.append(.init(key: "command", value: .string(cmd(kind))))
            m.append(.init(key: "timeout", value: .number(String(timeout))))
            if async { m.append(.init(key: "async", value: .bool(true))) }
            return .object(m)
        }
        func group(_ matcher: String?, _ h: OJ) -> OJ {
            var m: [OJ.Member] = []
            if let matcher { m.append(.init(key: "matcher", value: .string(matcher))) }
            m.append(.init(key: "hooks", value: .array([h])))
            return .object(m)
        }
        func passive(_ kind: String) -> OJ { handler(kind, timeout: 5, async: true) }
        return [
            ("PermissionRequest", group(nil, handler("permission", timeout: 305, async: false))),
            ("PreToolUse", group("Bash", handler("pre_tool", timeout: 65, async: false, ifRule: "Bash(git commit *)"))),
            ("PostToolUse", group("Edit|Write|MultiEdit|Bash", passive("post_tool"))),
            ("Notification", group(nil, passive("notification"))),
            ("Stop", group(nil, passive("stop"))),
            ("SessionStart", group(nil, passive("session_start"))),
            ("SessionEnd", group(nil, passive("session_end"))),
            ("UserPromptSubmit", group(nil, passive("user_prompt"))),
            ("SubagentStart", group(nil, passive("subagent_start"))),
            ("SubagentStop", group(nil, passive("subagent_stop"))),
        ]
    }

    // MARK: Ours vs theirs

    /// The "command" string of a hook or a statusLine object.
    private static func command(of entry: OJ) -> String? {
        guard case .object(let m) = entry,
              let c = m.first(where: { $0.key == "command" })?.value,
              case .string(let s, _) = c else { return nil }
        return s
    }

    /// The "timeout" number of a hook, in seconds.
    private static func timeout(of hook: OJ) -> Double? {
        guard case .object(let m) = hook,
              let t = m.first(where: { $0.key == "timeout" })?.value,
              case .number(let n) = t else { return nil }
        return Double(n)
    }

    private static func isOurs(_ hook: OJ) -> Bool {
        command(of: hook)?.contains(marker) ?? false
    }

    private static func isOurStatusLine(_ line: OJ) -> Bool {
        command(of: line)?.contains(statuslineMarker) ?? false
    }

    private static func hooksList(_ group: OJ) -> [OJ]? {
        guard case .object(let m) = group,
              let h = m.first(where: { $0.key == "hooks" })?.value,
              case .array(let list) = h else { return nil }
        return list
    }

    private static func groupHasOurs(_ group: OJ) -> Bool {
        hooksList(group)?.contains(where: isOurs) ?? false
    }

    /// Drops our hooks from each group; a group left with no hooks is dropped too.
    private static func stripOurs(_ groups: [OJ]) -> (groups: [OJ], firstIndex: Int?, removed: Int) {
        var out: [OJ] = []
        var first: Int?
        var removed = 0
        for group in groups {
            guard let list = hooksList(group), list.contains(where: isOurs),
                  case .object(var members) = group else { out.append(group); continue }
            if first == nil { first = out.count }
            let kept = list.filter { !isOurs($0) }
            removed += list.count - kept.count
            if kept.isEmpty { continue }
            if let i = members.firstIndex(where: { $0.key == "hooks" }) { members[i].value = .array(kept) }
            out.append(.object(members))
        }
        return (out, first, removed)
    }

    private static func shellQuote(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./:@%+=-")
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Chain file

    /// The saved statusLine, verbatim; nil when no chain file exists or it saved none.
    /// A chain file that exists but cannot be parsed throws, so the status line is not guessed at.
    private static func readChain(_ path: String) throws -> OJ? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        guard let root = try? OJParser.parse(Array(data)), case .object(let m) = root else {
            throw InstallError.chainUnreadable(path)
        }
        return m.first(where: { $0.key == "previous" })?.value
    }

    /// Writes {"previous": <statusLine>} atomically, in the same layout as settings.mjs.
    private static func writeChain(_ path: String, previous: OJ) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let text = OJ.object([.init(key: "previous", value: previous)]).pretty(indent: 0) + "\n"
        let tmp = "\(path).tmp-\(getpid())"
        guard fm.createFile(atPath: tmp, contents: Data(text.utf8)) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp])
        }
        if rename(tmp, path) != 0 {
            let err = errno
            try? fm.removeItem(atPath: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
    }

    // MARK: File

    private struct SettingsFile {
        var root: OJ
        var existed: Bool
        var trailingNewline: Bool
    }

    private static func readSettings(_ path: String) throws -> SettingsFile {
        guard FileManager.default.fileExists(atPath: path) else {
            return SettingsFile(root: .object([]), existed: false, trailingNewline: true)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let text = String(decoding: data, as: UTF8.self)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SettingsFile(root: .object([]), existed: true, trailingNewline: true)
        }
        let root = try OJParser.parse(Array(data))
        guard case .object = root else { throw InstallError.notAnObject("the top level") }
        return SettingsFile(root: root, existed: true, trailingNewline: text.hasSuffix("\n"))
    }

    /// Backups kept next to settings.json; older ones we made are deleted. Same in settings.mjs.
    static let keptBackups = 5

    /// Backs up (when the file exists), then writes atomically, keeping the file mode.
    /// A symlinked settings.json (a dotfiles repo) stays a link: the write, the mode and the
    /// backup's content come from the file it points at, and the temp file sits in that
    /// file's folder so the rename replaces the file, not the link.
    private static func writeSettings(_ path: String, _ file: SettingsFile) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let target = realPath(path) ?? path
        var mode: Int = 0o600
        if file.existed {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let stamp = f.string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: ".", with: "-")
            // copyItem copies a symlink as a link; the backup must hold the content.
            try fm.copyItem(atPath: target, toPath: "\(path).notchcode-backup-\(stamp)")
            if let m = (try? fm.attributesOfItem(atPath: target))?[.posixPermissions] as? NSNumber {
                mode = m.intValue & 0o777
            }
            pruneBackups(path)
        }
        var text = file.root.pretty(indent: 0)
        if file.trailingNewline { text += "\n" }
        let tmp = "\(target).notchcode-tmp-\(getpid())"
        guard fm.createFile(atPath: tmp, contents: Data(text.utf8), attributes: [.posixPermissions: mode]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp])
        }
        if rename(tmp, target) != 0 {
            let err = errno
            try? fm.removeItem(atPath: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
    }
}

extension HooksInstaller {
    /// The path with every symlink resolved, or nil when it does not exist.
    fileprivate static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Keeps the newest `keptBackups` `<settings>.notchcode-backup-*` (the timestamps sort by
    /// name); only files with exactly that prefix, which only we make, are deleted.
    fileprivate static func pruneBackups(_ path: String) {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        let prefix = (path as NSString).lastPathComponent + ".notchcode-backup-"
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        let ours = names.filter { $0.hasPrefix(prefix) }.sorted()
        for name in ours.dropLast(keptBackups) {
            try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent(name))
        }
    }
}
