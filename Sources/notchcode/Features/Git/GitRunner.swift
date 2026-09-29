// GitRunner.swift
// Runs `/usr/bin/git` for the Git tool and parses what it prints: status, ahead and behind,
// recent commits, branches and worktrees, and the push. Off the main thread, with
// GIT_OPTIONAL_LOCKS=0; read-only except `git push` after the owner confirmed it.

import Foundation

/// `/usr/bin/git -C <dir>`, synchronously; call it off the main thread. Output goes to
/// temporary files rather than pipes, so a large diff never fills a pipe and an ssh helper
/// that outlives git (ControlPersist) never holds the read open.
enum GitRunner {
    struct Result {
        var status: Int32
        var out: String
        var err: String
        var timedOut = false
    }

    static func run(_ args: [String], cwd: String, timeout: Double = Theme.Timing.gitReadTimeout) -> Result {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("notchcode-git-" + UUID().uuidString)
        let outURL = base.appendingPathExtension("out")
        let errURL = base.appendingPathExtension("err")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? fm.removeItem(at: outURL)
            try? fm.removeItem(at: errURL)
        }
        guard let outHandle = try? FileHandle(forWritingTo: outURL),
              let errHandle = try? FileHandle(forWritingTo: errURL) else {
            return Result(status: -1, out: "", err: "could not run git")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd, "-c", "core.quotePath=false"] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        // No prompt can be answered from a notch: fail instead of waiting on one.
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outHandle
        process.standardError = errHandle

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            try? outHandle.close()
            try? errHandle.close()
            return Result(status: -1, out: "", err: "could not run git")
        }
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            _ = done.wait(timeout: .now() + 1)
        }
        try? outHandle.close()
        try? errHandle.close()

        func text(_ url: URL) -> String {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: Theme.Limits.gitOutputBytes)) ?? nil
            return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        let status = process.isRunning ? -1 : process.terminationStatus
        return Result(status: timedOut ? -1 : status, out: text(outURL), err: text(errURL), timedOut: timedOut)
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Everything the tool shows about `cwd`'s worktree.
    static func read(cwd: String) -> GitSnapshot {
        let top = run(["rev-parse", "--show-toplevel"], cwd: cwd)
        let root = trimmed(top.out)
        guard top.status == 0, !root.isEmpty else { return GitSnapshot(cwd: cwd, isRepo: false) }
        var snap = GitSnapshot(cwd: cwd, isRepo: true, root: root)
        let common = run(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd: root)
        if common.status == 0 { snap.repoName = GitDir.repoName(commonDir: trimmed(common.out)) }

        let head = run(["rev-parse", "--abbrev-ref", "HEAD"], cwd: root)
        if head.status == 0 {
            let name = trimmed(head.out)
            snap.branch = name == "HEAD" || name.isEmpty ? nil : name
        } else {
            // No commit yet: the branch still has a name.
            let unborn = run(["symbolic-ref", "--short", "HEAD"], cwd: root)
            if unborn.status == 0, !trimmed(unborn.out).isEmpty { snap.branch = trimmed(unborn.out) }
        }

        let remotes = lines(run(["remote"], cwd: root).out)
        let upstream = run(["rev-parse", "--abbrev-ref", "@{u}"], cwd: root)
        if upstream.status == 0, !trimmed(upstream.out).isEmpty {
            snap.upstream = trimmed(upstream.out)
        }
        if let up = snap.upstream, let owner = remotes.first(where: { up.hasPrefix($0 + "/") }) {
            snap.remote = owner
        } else {
            snap.remote = remotes.contains("origin") ? "origin" : remotes.first
        }

        if snap.upstream != nil {
            // "<behind>\t<ahead>": left is the upstream, right is HEAD.
            let counts = trimmed(run(["rev-list", "--left-right", "--count", "@{u}...HEAD"], cwd: root).out)
                .split(whereSeparator: { $0 == "\t" || $0 == " " })
            if counts.count == 2 {
                snap.behind = Int(counts[0]) ?? 0
                snap.ahead = Int(counts[1]) ?? 0
            }
            snap.unpushed = snap.ahead
        } else if snap.branch != nil {
            let args = remotes.isEmpty
                ? ["rev-list", "--count", "HEAD"]
                : ["rev-list", "--count", "HEAD", "--not", "--remotes"]
            snap.unpushed = Int(trimmed(run(args, cwd: root).out)) ?? 0
        }

        // Uncommitted files: the same commands the hook's tree report runs.
        let status = run(["status", "--porcelain=v1", "--untracked-files=all"], cwd: root)
        let entries = UnifiedDiff.status(status.out.split(separator: "\n").map(String.init))
        var diffText = run(["diff", "HEAD", "--no-color", "--no-ext-diff", "--no-renames",
                            "--src-prefix=a/", "--dst-prefix=b/"], cwd: root).out
        for entry in entries.filter({ $0.code == "??" }).prefix(Theme.Limits.gitUntrackedDiffs) {
            // Exit 1 means "they differ", which is the point.
            let new = run(["diff", "--no-index", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/",
                           "--", "/dev/null", entry.path], cwd: root)
            if !diffText.isEmpty, !diffText.hasSuffix("\n") { diffText += "\n" }
            diffText += new.out
        }
        var byPath: [String: FileDiff] = [:]
        for diff in UnifiedDiff.parse(diffText) where byPath[diff.path] == nil { byPath[diff.path] = diff }
        var seen = Set<String>()
        for entry in entries where !seen.contains(entry.path) {
            seen.insert(entry.path)
            let diff = byPath[entry.path]
            var file = FileChange(path: entry.path, added: diff?.added ?? 0, removed: diff?.removed ?? 0,
                                  kind: kind(statusCode: entry.code))
            file.patch = diff?.lines ?? []
            file.patchTruncated = diff?.truncated ?? false
            file.snippet = Array(file.patch.prefix(DiffBuilder.snippetLimit))
            snap.files.append(file)
        }
        for file in snap.files.prefix(Theme.Limits.gitLineCountFiles) where file.kind != "deleted" {
            let url = URL(fileURLWithPath: root).appendingPathComponent(file.path)
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let data = (try? handle.read(upToCount: Theme.Limits.gitOutputBytes)) ?? nil
            try? handle.close()
            if let data { snap.lineCounts[file.path] = lineCount(data) }
        }

        let log = run(["log", "-\(Theme.Limits.gitRecentCommits)", "--format=%h%x1f%s%x1f%ct"], cwd: root)
        if log.status == 0 {
            for (index, line) in lines(log.out).enumerated() {
                let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 3 else { continue }
                snap.commits.append(GitCommit(
                    sha: parts[0],
                    subject: parts[1],
                    date: Date(timeIntervalSince1970: TimeInterval(parts[2]) ?? 0),
                    pushed: index >= snap.unpushed
                ))
            }
        }
        return snap
    }

    /// "new" for an untracked or added file, "deleted", else "edit"; the diff pane's badge
    /// reads A, D or M from it.
    private static func kind(statusCode code: String) -> String {
        if code == "??" || code.contains("A") { return "new" }
        if code.contains("D") { return "deleted" }
        return "edit"
    }

    /// Lines in a file's bytes: its newlines, plus one for a last line without one.
    private static func lineCount(_ data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        let newlines = data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        return data.last == 0x0A ? newlines : newlines + 1
    }

    /// "main" when the repository has it, else "master", else nil.
    private static func defaultBranch(root: String) -> String? {
        for name in ["main", "master"] where run(["show-ref", "--verify", "--quiet", "refs/heads/" + name], cwd: root).status == 0 {
            return name
        }
        return nil
    }

    /// A branch checked out nowhere, read from the repository's main folder: its changes
    /// against its upstream (else the default branch) with `git diff base...branch`, the
    /// commits `base..branch`, and what a push would send. Nothing is checked out.
    static func readBranch(repo: String, name: String, key: String) -> GitSnapshot {
        let ref = "refs/heads/" + name
        guard run(["show-ref", "--verify", "--quiet", ref], cwd: repo).status == 0 else {
            return GitSnapshot(cwd: key, isRepo: false)
        }
        var snap = GitSnapshot(cwd: key, isRepo: true, root: repo)
        snap.checkedOut = false
        snap.branch = name
        let common = run(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd: repo)
        if common.status == 0 { snap.repoName = GitDir.repoName(commonDir: trimmed(common.out)) }

        let remotes = lines(run(["remote"], cwd: repo).out)
        let upstream = run(["rev-parse", "--abbrev-ref", name + "@{u}"], cwd: repo)
        if upstream.status == 0, !trimmed(upstream.out).isEmpty { snap.upstream = trimmed(upstream.out) }
        if let up = snap.upstream, let owner = remotes.first(where: { up.hasPrefix($0 + "/") }) {
            snap.remote = owner
        } else {
            snap.remote = remotes.contains("origin") ? "origin" : remotes.first
        }

        if let up = snap.upstream {
            let counts = trimmed(run(["rev-list", "--left-right", "--count", up + "..." + ref], cwd: repo).out)
                .split(whereSeparator: { $0 == "\t" || $0 == " " })
            if counts.count == 2 {
                snap.behind = Int(counts[0]) ?? 0
                snap.ahead = Int(counts[1]) ?? 0
            }
            snap.unpushed = snap.ahead
            snap.base = up
        } else {
            let args = remotes.isEmpty
                ? ["rev-list", "--count", ref]
                : ["rev-list", "--count", ref, "--not", "--remotes"]
            snap.unpushed = Int(trimmed(run(args, cwd: repo).out)) ?? 0
            if let main = defaultBranch(root: repo), main != name { snap.base = main }
        }

        guard let base = snap.base else { return snap }
        snap.baseAhead = Int(trimmed(run(["rev-list", "--count", base + ".." + ref], cwd: repo).out)) ?? 0

        // Changes vs the base: the list and counts from --numstat, the kinds from
        // --name-status, the lines from -p (the hook's flags, so one parser reads them).
        let range = base + "..." + ref
        let numstat = run(["diff", "--numstat", "--no-renames", range], cwd: repo)
        let names = run(["diff", "--name-status", "--no-renames", range], cwd: repo)
        let patch = run(["diff", "-p", "--no-color", "--no-ext-diff", "--no-renames",
                         "--src-prefix=a/", "--dst-prefix=b/", range], cwd: repo)
        var kinds: [String: String] = [:]
        for line in lines(names.out) {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            kinds[parts[1]] = kind(statusCode: parts[0])
        }
        var byPath: [String: FileDiff] = [:]
        for diff in UnifiedDiff.parse(patch.out) where byPath[diff.path] == nil { byPath[diff.path] = diff }
        for line in lines(numstat.out) {
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            let path = parts[2]
            let diff = byPath[path]
            var file = FileChange(path: path, added: Int(parts[0]) ?? diff?.added ?? 0,
                                  removed: Int(parts[1]) ?? diff?.removed ?? 0, kind: kinds[path] ?? "edit")
            file.patch = diff?.lines ?? []
            file.patchTruncated = diff?.truncated ?? false
            file.snippet = Array(file.patch.prefix(DiffBuilder.snippetLimit))
            snap.files.append(file)
        }
        for file in snap.files.prefix(Theme.Limits.gitLineCountFiles) where file.kind != "deleted" {
            let blob = run(["cat-file", "blob", ref + ":" + file.path], cwd: repo)
            if blob.status == 0 { snap.lineCounts[file.path] = lineCount(Data(blob.out.utf8)) }
        }

        let log = run(["log", "-\(Theme.Limits.gitRecentCommits)", "--format=%h%x1f%s%x1f%ct", base + ".." + ref], cwd: repo)
        if log.status == 0 {
            for (index, line) in lines(log.out).enumerated() {
                let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 3 else { continue }
                snap.commits.append(GitCommit(
                    sha: parts[0],
                    subject: parts[1],
                    date: Date(timeIntervalSince1970: TimeInterval(parts[2]) ?? 0),
                    pushed: index >= snap.unpushed
                ))
            }
        }
        return snap
    }

    /// Every repository the folders belong to, with its local branches: the newest
    /// `gitPickerBranches` by last commit (`for-each-ref --sort=-committerdate refs/heads`)
    /// and every checked-out one besides, each placed by `git worktree list --porcelain`
    /// (main checkout, a worktree, or nowhere), with its uncommitted files (checkouts only)
    /// and the commits it is ahead of its upstream, or of the default branch without one.
    /// Repositories in the order the folders come, each listed once.
    static func listBranches(cwds: [String]) -> (repos: [GitRepoGroup], rootByCwd: [String: String]) {
        var repos: [GitRepoGroup] = []
        var rootByCwd: [String: String] = [:]
        var seenRoots = Set<String>()
        for cwd in cwds {
            let top = run(["rev-parse", "--show-toplevel"], cwd: cwd)
            let root = trimmed(top.out)
            guard top.status == 0, !root.isEmpty else { continue }
            rootByCwd[cwd] = root
            if seenRoots.contains(root) { continue }
            let list = run(["worktree", "list", "--porcelain"], cwd: root)
            guard list.status == 0 else { continue }
            let entries = worktreeEntries(list.out)
            guard let main = entries.first else { continue }
            for entry in entries { seenRoots.insert(entry.path) }
            if repos.contains(where: { $0.id == main.path }) { continue }
            let name: String
            if main.bare {
                let last = URL(fileURLWithPath: main.path).lastPathComponent
                name = last.hasSuffix(".git") ? String(last.dropLast(4)) : last
            } else {
                name = URL(fileURLWithPath: main.path).lastPathComponent
            }

            // Branch -> the folder it is checked out in; the first entry is the main one.
            var checkouts: [String: GitBranch.Place] = [:]
            for (index, entry) in entries.enumerated() where !entry.bare {
                guard let branch = entry.branch, FileManager.default.fileExists(atPath: entry.path) else { continue }
                checkouts[branch] = index == 0 ? .main(entry.path) : .worktree(entry.path)
            }
            let defaultName = defaultBranch(root: root)

            let refs = run(["for-each-ref", "--sort=-committerdate",
                            "--format=%(refname:short)%1f%(upstream:short)%1f%(committerdate:unix)", "refs/heads"], cwd: root)
            var branches: [GitBranch] = []
            for (index, line) in lines(refs.out).enumerated() {
                let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 3 else { continue }
                let place = checkouts[parts[0]] ?? .nowhere
                if index >= Theme.Limits.gitPickerBranches, place == .nowhere { continue }
                var branch = GitBranch(
                    name: parts[0],
                    upstream: parts[1].isEmpty ? nil : parts[1],
                    date: Date(timeIntervalSince1970: TimeInterval(parts[2]) ?? 0),
                    place: place
                )
                if let path = branch.path {
                    let status = run(["status", "--porcelain=v1", "--untracked-files=all"], cwd: path)
                    branch.uncommitted = status.status == 0 ? lines(status.out).count : nil
                }
                let ref = "refs/heads/" + branch.name
                let base: String?
                if let upstream = branch.upstream {
                    base = upstream
                } else if let defaultName, defaultName != branch.name {
                    base = "refs/heads/" + defaultName
                } else {
                    base = nil
                }
                if let base {
                    let count = run(["rev-list", "--count", base + ".." + ref], cwd: root)
                    branch.ahead = count.status == 0 ? Int(trimmed(count.out)) : nil
                }
                branches.append(branch)
            }
            if !branches.isEmpty {
                repos.append(GitRepoGroup(id: main.path, name: name, defaultBranch: defaultName, branches: branches))
            }
        }
        return (repos, rootByCwd)
    }

    /// The blocks of `git worktree list --porcelain`: "worktree <path>", then "branch
    /// refs/heads/<name>", "detached" or "bare", separated by a blank line.
    private static func worktreeEntries(_ text: String) -> [(path: String, branch: String?, bare: Bool)] {
        var entries: [(path: String, branch: String?, bare: Bool)] = []
        for block in text.components(separatedBy: "\n\n") {
            var path: String?
            var branch: String?
            var bare = false
            for line in block.split(separator: "\n").map(String.init) {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
                if line.hasPrefix("branch ") {
                    let ref = String(line.dropFirst("branch ".count))
                    branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
                }
                if line == "bare" { bare = true }
            }
            if let path { entries.append((path, branch, bare)) }
        }
        return entries
    }

    /// The first useful line of a failed push, for the header. Credential failures say so
    /// and point at the terminal, where a prompt can be answered.
    static func errorLine(_ result: Result, remote: String) -> String {
        if result.timedOut { return "git push took too long" + Theme.Glyphs.separator + "push from the terminal" }
        let all = lines(result.err).map(trimmed)
        let credentials = ["could not read Username", "terminal prompts disabled", "Permission denied",
                           "Authentication failed", "Host key verification failed", "could not read Password"]
        if all.contains(where: { line in credentials.contains { line.contains($0) } }) {
            return "No credentials for " + remote + " here" + Theme.Glyphs.separator + "push from the terminal"
        }
        let marked = all.first { line in
            ["fatal:", "error:", "! [rejected]", "! [remote rejected]", "remote: error"].contains { line.contains($0) }
        }
        let line = marked ?? all.first { !$0.hasPrefix("hint:") && !$0.hasPrefix("To ") } ?? ""
        var text = line
        for prefix in ["fatal: ", "error: "] where text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)) }
        return text.isEmpty ? "git push failed" : text
    }
}
