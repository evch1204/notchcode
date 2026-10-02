// PlanUsage.swift
// The plan limits Claude Code itself knows: the per-model weekly windows ("Fable") and where
// the week went, from the usage cache Claude Code keeps in ~/.claude.json
// (`cachedUsageUtilization`, written whenever it answers `/usage`), and the "What's
// contributing to your limits usage?" section of `claude -p /usage`. The app never calls an
// API: `PlanUsageRunner` runs the owner's own CLI headlessly (no hooks, no model turn), which
// refreshes that cache.

import Foundation

/// What Claude Code's own usage cache (~/.claude.json, cachedUsageUtilization) said.
struct PlanUsage: Equatable {
    var fetchedAt: Date
    var fiveHourPercent: Double?
    var fiveHourResetsAt: Date?
    var weekPercent: Double?
    var weekResetsAt: Date?
    var modelWeeks: [ModelWeek]
    /// Rows with percent > 0 first, in the file's order.
    var weekBreakdown: [NamedShare]
}

/// The "What's contributing to your limits usage?" section of `claude -p /usage`.
struct UsageBehaviors: Equatable {
    struct Period: Equatable {
        var title: String       // "Last 24h"
        var requests: Int
        var sessions: Int
        var lines: [String]
    }
    var day: Period?
    var week: Period?
}

enum PlanUsageError: Error, Equatable {
    /// No `claude` executable in the usual places or on the login shell's PATH.
    case notFound
    /// It ran but failed, timed out or printed no result.
    case failed
}

enum PlanUsageReader {

    /// The usage cache in Claude Code's config file, or nil when absent or unreadable.
    static func read(configPath: String = NotchcodePaths.claudeConfigFile.path) -> PlanUsage? {
        guard let data = FileManager.default.contents(atPath: configPath) else { return nil }
        return parse(configData: data)
    }

    /// `cachedUsageUtilization` out of the config file's bytes. Every key may be missing or null.
    static func parse(configData: Data) -> PlanUsage? {
        guard let root = (try? JSONSerialization.jsonObject(with: configData)) as? [String: Any],
              let cache = root["cachedUsageUtilization"] as? [String: Any],
              let fetchedMs = number(cache["fetchedAtMs"]),
              let utilization = cache["utilization"] as? [String: Any] else { return nil }

        var plan = PlanUsage(fetchedAt: Date(timeIntervalSince1970: fetchedMs / 1000), modelWeeks: [], weekBreakdown: [])
        let limits = (utilization["limits"] as? [[String: Any]]) ?? []
        func limit(_ kind: String) -> [String: Any]? { limits.first { $0["kind"] as? String == kind } }

        if let five = utilization["five_hour"] as? [String: Any], let percent = number(five["utilization"]) {
            plan.fiveHourPercent = clamp(percent)
            plan.fiveHourResetsAt = date(five["resets_at"])
        } else if let session = limit("session"), let percent = number(session["percent"]) {
            plan.fiveHourPercent = clamp(percent)
            plan.fiveHourResetsAt = date(session["resets_at"])
        }
        if let week = utilization["seven_day"] as? [String: Any], let percent = number(week["utilization"]) {
            plan.weekPercent = clamp(percent)
            plan.weekResetsAt = date(week["resets_at"])
        } else if let week = limit("weekly_all"), let percent = number(week["percent"]) {
            plan.weekPercent = clamp(percent)
            plan.weekResetsAt = date(week["resets_at"])
        }

        for row in limits where row["kind"] as? String == "weekly_scoped" {
            guard let scope = row["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let name = model["display_name"] as? String, !name.isEmpty,
                  let percent = number(row["percent"]),
                  !plan.modelWeeks.contains(where: { $0.name == name }) else { continue }
            plan.modelWeeks.append(ModelWeek(name: name, percent: clamp(percent), resetsAt: date(row["resets_at"])))
        }

        let rows = ((utilization["seven_day_breakdown"] as? [String: Any])?["rows"] as? [[String: Any]]) ?? []
        let shares = rows.compactMap { row -> NamedShare? in
            guard let name = (row["display_name"] as? String) ?? (row["key"] as? String),
                  let percent = number(row["percent"]) else { return nil }
            return NamedShare(name: name, percent: clamp(percent))
        }
        plan.weekBreakdown = shares.filter { $0.percent > 0 } + shares.filter { $0.percent <= 0 }
        return plan
    }

    /// The two periods of "What's contributing to your limits usage?", or nil when the
    /// section is absent. A period starts at "Last 24h · 155 requests · 2 sessions"; its
    /// indented lines follow.
    static func behaviors(fromResult text: String) -> UsageBehaviors? {
        var periods: [UsageBehaviors.Period] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let period = periodHeader(line) {
                periods.append(period)
            } else if raw.first?.isWhitespace == true, !periods.isEmpty {
                periods[periods.count - 1].lines.append(line)
            }
        }
        guard !periods.isEmpty else { return nil }
        var result = UsageBehaviors()
        for period in periods {
            if period.title.contains("24h") || period.title.contains("day") {
                if result.day == nil { result.day = period }
            } else if result.week == nil {
                result.week = period
            }
        }
        if result.day == nil, result.week == nil { result.day = periods.first }
        return result
    }

    /// "Last 24h · 155 requests · 2 sessions" -> its title and counts.
    private static func periodHeader(_ line: String) -> UsageBehaviors.Period? {
        guard line.hasPrefix("Last ") else { return nil }
        let parts = line.components(separatedBy: "·").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3 else { return nil }
        func count(_ part: String, _ word: String) -> Int? {
            let pieces = part.split(separator: " ")
            guard pieces.count == 2, pieces[1].hasPrefix(word) else { return nil }
            return Int(pieces[0])
        }
        guard let requests = count(parts[1], "request"), let sessions = count(parts[2], "session") else { return nil }
        return UsageBehaviors.Period(title: parts[0], requests: requests, sessions: sessions, lines: [])
    }

    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    private static func clamp(_ percent: Double) -> Double { min(100, max(0, percent)) }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return isoFractional.date(from: text) ?? iso.date(from: text)
    }
}

/// Runs `claude -p /usage --output-format json --setting-sources "" --resume <id>` in
/// `NotchcodePaths.usageRunDirectory`: about 300 ms, no tokens, no model turn, no hooks. It
/// refreshes Claude Code's usage cache and prints the usage text as the JSON's `result`.
enum PlanUsageRunner {

    private static let lock = NSLock()
    /// The resolved `claude` path; `.some(nil)` once nothing resolved.
    private static var resolved: String??

    /// Where a resolution is searched before asking the login shell.
    private static var candidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [home + "/.local/bin/claude", home + "/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    }

    private static var sessionIdFile: URL { NotchcodePaths.usageRunDirectory.appendingPathComponent("session-id") }

    /// The run's session id, read from disk, made on first use, and replaced when its
    /// transcript has grown past `Theme.Limits.planUsageTranscriptBytes`.
    static func sessionId() -> String {
        let fm = FileManager.default
        try? fm.createDirectory(at: NotchcodePaths.usageRunDirectory, withIntermediateDirectories: true)
        if let data = fm.contents(atPath: sessionIdFile.path) {
            let id = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if UUID(uuidString: id) != nil {
                let size = (try? fm.attributesOfItem(atPath: transcriptURL(for: id).path)[.size] as? NSNumber)?.intValue ?? 0
                if size <= Theme.Limits.planUsageTranscriptBytes { return id }
            }
        }
        let id = UUID().uuidString.lowercased()
        try? Data(id.utf8).write(to: sessionIdFile, options: .atomic)
        return id
    }

    /// Claude Code keeps a project's transcripts in ~/.claude/projects/<cwd with every
    /// character but letters and digits turned into "-">.
    static func transcriptURL(for id: String) -> URL {
        let folder = String(NotchcodePaths.usageRunDirectory.path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return NotchcodePaths.claudeProjectsDirectory
            .appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent(id + ".jsonl")
    }

    /// The usage text, or why there is none. `resolveAgain` (a forced refresh) looks for the
    /// executable again after an earlier search found nothing. A new session's first run
    /// (`--session-id`) never prints "What's contributing to your limits usage?", so a
    /// successful one is followed by one `--resume`, whose text is used when it succeeds.
    static func run(resolveAgain: Bool = false) async -> Result<String, PlanUsageError> {
        guard let claude = await executable(resolveAgain: resolveAgain) else { return .failure(.notFound) }
        let id = sessionId()
        let cwd = NotchcodePaths.usageRunDirectory.path
        let fresh = !FileManager.default.fileExists(atPath: transcriptURL(for: id).path)

        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["HOME"] = home
        env["PATH"] = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", env["PATH"]]
            .compactMap { $0 }.joined(separator: ":")

        func invoke(_ flag: String) async -> ProcessRunner.Result {
            await ProcessRunner.run(
                executable: claude,
                arguments: ["-p", "/usage", "--output-format", "json", "--setting-sources", "", flag, id],
                cwd: cwd,
                environment: env,
                timeout: Theme.Timing.planUsageTimeout
            )
        }

        // A known id resumes; an unknown one starts with --session-id. Each failure the
        // other way round retries once with the other flag.
        var flag = fresh ? "--session-id" : "--resume"
        var result = await invoke(flag)
        if result.status != 0, !result.timedOut {
            let said = result.out + result.err
            if !fresh, said.contains("No conversation found") {
                flag = "--session-id"
                result = await invoke(flag)
            } else if fresh, said.contains("already in use") {
                flag = "--resume"
                result = await invoke(flag)
            }
        }
        func resultText(_ run: ProcessRunner.Result) -> String? {
            guard run.status == 0,
                  let object = (try? JSONSerialization.jsonObject(with: Data(run.out.utf8))) as? [String: Any] else { return nil }
            return object["result"] as? String
        }
        guard let text = resultText(result) else { return .failure(.failed) }
        if flag == "--session-id", !text.contains("What's contributing"),
           let resumed = resultText(await invoke("--resume")) {
            return .success(resumed)
        }
        return .success(text)
    }

    /// The `claude` executable, resolved once for the app's lifetime.
    private static func executable(resolveAgain: Bool) async -> String? {
        let cached = lock.withLock { resolved }
        if let cached, !(resolveAgain && cached == nil) { return cached }

        let fm = FileManager.default
        var found = candidates.first { fm.isExecutableFile(atPath: $0) }
        if found == nil {
            let shell = await ProcessRunner.run(executable: "/bin/zsh", arguments: ["-lc", "command -v claude"],
                                                timeout: Theme.Timing.claudeLookupTimeout)
            let path = shell.out.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            if shell.status == 0, path.hasPrefix("/"), fm.isExecutableFile(atPath: path) { found = path }
        }
        lock.withLock { resolved = .some(found) }
        return found
    }
}
