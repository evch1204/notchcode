// GitRunner.swift
// Runs `/usr/bin/git` for the Git tool and parses what it prints: status, ahead and behind,
// the newest commit, recent co-authors, branches and worktrees, and the writes: push, pull, fetch, commit and the
// undo's reset. Off the main thread, with GIT_OPTIONAL_LOCKS=0; the writes run only from
// `AppState`'s explicit presses (and the quiet fetch), never from a read.

import Foundation

/// `/usr/bin/git -C <dir>`, through `ProcessRunner` (temporary files, not pipes; SIGTERM
/// then SIGKILL past the timeout).
enum GitRunner {
    typealias Result = ProcessRunner.Result

    static func run(_ args: [String], cwd: String, timeout: Double = Theme.Timing.gitReadTimeout) async -> Result {
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        // No prompt can be answered from a notch: fail instead of waiting on one.
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        // Paths from `git status` come back as pathspecs: `app/[id]/page.tsx` must not glob to `app/i/page.tsx`.
        env["GIT_LITERAL_PATHSPECS"] = "1"
        return await ProcessRunner.run(
            executable: "/usr/bin/git",
            arguments: ["-C", cwd, "-c", "core.quotePath=false"] + args,
            environment: env,
            timeout: timeout
        )
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Everything the tool shows about `cwd`'s worktree.
    static func read(cwd: String) async -> GitSnapshot {
        let top = await run(["rev-parse", "--show-toplevel"], cwd: cwd)
        let root = trimmed(top.out)
        guard top.status == 0, !root.isEmpty else { return GitSnapshot(cwd: cwd, isRepo: false) }
        var snap = GitSnapshot(cwd: cwd, isRepo: true, root: root)
        let common = await run(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd: root)
        if common.status == 0 { snap.repoName = GitDir.repoName(commonDir: trimmed(common.out)) }

        let head = await run(["rev-parse", "--abbrev-ref", "HEAD"], cwd: root)
        if head.status == 0 {
            let name = trimmed(head.out)
            snap.branch = name == "HEAD" || name.isEmpty ? nil : name
        } else {
            // No commit yet: the branch still has a name.
            let unborn = await run(["symbolic-ref", "--short", "HEAD"], cwd: root)
            if unborn.status == 0, !trimmed(unborn.out).isEmpty { snap.branch = trimmed(unborn.out) }
        }

        let remotes = lines(await run(["remote"], cwd: root).out)
        await resolveUpstream(&snap, of: "@{u}", branch: snap.branch, remotes: remotes, root: root)
        if snap.upstream != nil || snap.branch != nil {
            await countUnpushed(&snap, upstream: snap.upstream == nil ? nil : "@{u}", ref: "HEAD", remotes: remotes, root: root)
        }

        // Uncommitted files: the same commands the hook's tree report runs.
        let status = await run(["status", "--porcelain=v1", "--untracked-files=all"], cwd: root)
        let entries = UnifiedDiff.status(status.out.split(separator: "\n").map(String.init))
        var diffText = await run(["diff", "HEAD", "--no-color", "--no-ext-diff", "--no-renames",
                            "--src-prefix=a/", "--dst-prefix=b/"], cwd: root).out
        for entry in entries.filter({ $0.code == "??" }).prefix(Theme.Limits.gitUntrackedDiffs) {
            // Exit 1 means "they differ", which is the point.
            let new = await run(["diff", "--no-index", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/",
                           "--", "/dev/null", entry.path], cwd: root)
            if !diffText.isEmpty, !diffText.hasSuffix("\n") { diffText += "\n" }
            diffText += new.out
        }
        var byPath: [String: FileDiff] = [:]
        for diff in UnifiedDiff.parse(diffText) where byPath[diff.path] == nil { byPath[diff.path] = diff }
        var seen = Set<String>()
        for entry in entries where !seen.contains(entry.path) {
            seen.insert(entry.path)
            var file = fileChange(entry.path, kind: kind(statusCode: entry.code), diff: byPath[entry.path])
            file.renamedFrom = entry.renamedFrom
            snap.files.append(file)
        }
        for file in snap.files.prefix(Theme.Limits.gitLineCountFiles) where file.kind != "deleted" {
            // Regular files only: an untracked FIFO would block the read forever.
            guard let handle = RegularFile.open(root + "/" + file.path) else { continue }
            let data = (try? handle.read(upToCount: Theme.Limits.gitOutputBytes)) ?? nil
            try? handle.close()
            if let data { snap.lineCounts[file.path] = lineCount(data) }
        }

        snap.commits = await recentCommits([], unpushed: snap.unpushed, root: root)
        // Undo resets to HEAD~1, which the root commit does not have.
        snap.headHasParent = await run(["rev-parse", "--verify", "--quiet", "HEAD~1"], cwd: root).status == 0
        snap.recentCoauthors = await recentCoauthors(root: root)
        return snap
    }

    /// The co-author suggestions: every Co-authored-by trailer value of the last
    /// `gitCoauthorLog` commits, trimmed, newest first, each once (case-insensitively), at most
    /// `gitCoauthorHistory`.
    private static func recentCoauthors(root: String) async -> [String] {
        let log = await run(["log", "-\(Theme.Limits.gitCoauthorLog)",
                             "--format=%(trailers:key=Co-authored-by,valueonly,separator=%x1f)"], cwd: root)
        guard log.status == 0 else { return [] }
        var seen = Set<String>()
        var names: [String] = []
        for part in log.out.split(whereSeparator: { $0 == "\u{1f}" || $0 == "\n" }) {
            let value = trimmed(String(part))
            guard !value.isEmpty, seen.insert(value.lowercased()).inserted else { continue }
            names.append(value)
            if names.count == Theme.Limits.gitCoauthorHistory { break }
        }
        return names
    }

    /// The upstream `spec` names ("@{u}", or "<branch>@{u}") and the remote a push goes to:
    /// the upstream's, else origin, else the first; with an upstream, the exact push target.
    private static func resolveUpstream(_ snap: inout GitSnapshot, of spec: String, branch: String?,
                                        remotes: [String], root: String) async {
        let upstream = await run(["rev-parse", "--abbrev-ref", spec], cwd: root)
        if upstream.status == 0, !trimmed(upstream.out).isEmpty { snap.upstream = trimmed(upstream.out) }
        if let up = snap.upstream, let owner = remotes.first(where: { up.hasPrefix($0 + "/") }) {
            snap.remote = owner
        } else {
            snap.remote = remotes.contains("origin") ? "origin" : remotes.first
        }
        if snap.upstream != nil, let branch { await resolvePushTarget(&snap, branch: branch, root: root) }
    }

    /// What a push would send from `ref`: behind and ahead of `upstream`, or without one the
    /// commits on no remote.
    private static func countUnpushed(_ snap: inout GitSnapshot, upstream: String?, ref: String,
                                      remotes: [String], root: String) async {
        if let upstream {
            // "<behind>\t<ahead>": left is the upstream, right is the ref.
            let counts = trimmed(await run(["rev-list", "--left-right", "--count", upstream + "..." + ref], cwd: root).out)
                .split(whereSeparator: { $0 == "\t" || $0 == " " })
            if counts.count == 2 {
                snap.behind = Int(counts[0]) ?? 0
                snap.ahead = Int(counts[1]) ?? 0
            }
            snap.unpushed = snap.ahead
        } else {
            let args = remotes.isEmpty
                ? ["rev-list", "--count", ref]
                : ["rev-list", "--count", ref, "--not", "--remotes"]
            snap.unpushed = Int(trimmed(await run(args, cwd: root).out)) ?? 0
        }
    }

    /// A file of the list with its parsed diff; counts are 0 without one.
    private static func fileChange(_ path: String, kind: String, diff: FileDiff?) -> FileChange {
        var file = FileChange(path: path, added: diff?.added ?? 0, removed: diff?.removed ?? 0, kind: kind)
        file.patch = diff?.lines ?? []
        file.patchTruncated = diff?.truncated ?? false
        return file
    }

    /// The last `gitRecentCommits` commits (of `range`, else HEAD's), the newest `unpushed` of
    /// them marked as not pushed.
    private static func recentCommits(_ range: [String], unpushed: Int, root: String) async -> [GitCommit] {
        let log = await run(["log", "-\(Theme.Limits.gitRecentCommits)", "--format=%h%x1f%s%x1f%ct"] + range, cwd: root)
        guard log.status == 0 else { return [] }
        return lines(log.out).enumerated().compactMap { index, line in
            let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { return nil }
            return GitCommit(
                sha: parts[0],
                subject: parts[1],
                date: Date(timeIntervalSince1970: TimeInterval(parts[2]) ?? 0),
                pushed: index >= unpushed
            )
        }
    }

    /// The upstream as git's config names it (`branch.<b>.remote` and `.merge`), so the push
    /// can name the exact remote and branch the confirm shows: `upstream` alone is the
    /// remote-tracking ref, which a custom fetch refspec can name differently.
    private static func resolvePushTarget(_ snap: inout GitSnapshot, branch: String, root: String) async {
        let ref = await run(["for-each-ref", "--format=%(upstream:remotename)%1f%(upstream:remoteref)",
                             "refs/heads/" + branch], cwd: root)
        let parts = trimmed(ref.out).split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
        guard ref.status == 0, parts.count == 2, !parts[0].isEmpty, parts[1].hasPrefix("refs/heads/") else { return }
        snap.remote = parts[0]
        snap.upstreamBranch = String(parts[1].dropFirst("refs/heads/".count))
    }

    /// "new" for an untracked or added file, "renamed" for a staged rename, "deleted", else
    /// "edit"; the diff pane's badge reads A, R, D or M from it.
    private static func kind(statusCode code: String) -> String {
        if code == "??" { return "new" }
        if code.contains("R") { return "renamed" }
        if code.contains("A") { return "new" }
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
    private static func defaultBranch(root: String) async -> String? {
        for name in ["main", "master"] {
            if await run(["show-ref", "--verify", "--quiet", "refs/heads/" + name], cwd: root).status == 0 { return name }
        }
        return nil
    }

    /// A branch checked out nowhere, read from the repository's main folder: its changes
    /// against its upstream (else the default branch) with `git diff base...branch`, the
    /// commits `base..branch`, and what a push would send. Nothing is checked out.
    static func readBranch(repo: String, name: String, key: String) async -> GitSnapshot {
        let ref = "refs/heads/" + name
        guard await run(["show-ref", "--verify", "--quiet", ref], cwd: repo).status == 0 else {
            return GitSnapshot(cwd: key, isRepo: false)
        }
        var snap = GitSnapshot(cwd: key, isRepo: true, root: repo)
        snap.checkedOut = false
        snap.branch = name
        let common = await run(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd: repo)
        if common.status == 0 { snap.repoName = GitDir.repoName(commonDir: trimmed(common.out)) }

        let remotes = lines(await run(["remote"], cwd: repo).out)
        await resolveUpstream(&snap, of: name + "@{u}", branch: name, remotes: remotes, root: repo)
        await countUnpushed(&snap, upstream: snap.upstream, ref: ref, remotes: remotes, root: repo)
        if let up = snap.upstream {
            snap.base = up
        } else if let main = await defaultBranch(root: repo), main != name {
            snap.base = main
        }

        guard let base = snap.base else { return snap }
        snap.baseAhead = Int(trimmed(await run(["rev-list", "--count", base + ".." + ref], cwd: repo).out)) ?? 0

        // Changes vs the base, with the hook's flags so one parser reads them: the counts and
        // the kinds (from the mode lines) come with the lines.
        let patch = await run(["diff", "-p", "--no-color", "--no-ext-diff", "--no-renames",
                         "--src-prefix=a/", "--dst-prefix=b/", base + "..." + ref], cwd: repo)
        var seen = Set<String>()
        for diff in UnifiedDiff.parse(patch.out) where !seen.contains(diff.path) {
            seen.insert(diff.path)
            snap.files.append(fileChange(diff.path, kind: diff.kind ?? "edit", diff: diff))
        }
        for file in snap.files.prefix(Theme.Limits.gitLineCountFiles) where file.kind != "deleted" {
            let blob = await run(["cat-file", "blob", ref + ":" + file.path], cwd: repo)
            if blob.status == 0 { snap.lineCounts[file.path] = lineCount(Data(blob.out.utf8)) }
        }

        snap.commits = await recentCommits([base + ".." + ref], unpushed: snap.unpushed, root: repo)
        return snap
    }

    /// Every repository the folders belong to, with its local branches: the newest
    /// `gitPickerBranches` by last commit (`for-each-ref --sort=-committerdate refs/heads`)
    /// and every checked-out one besides, each placed by `git worktree list --porcelain`
    /// (main checkout, a worktree, or nowhere), with its uncommitted files (checkouts only)
    /// and the commits it is ahead of its upstream, or of the default branch without one.
    /// Repositories in the order the folders come, each listed once.
    static func listBranches(cwds: [String]) async -> (repos: [GitRepoGroup], rootByCwd: [String: String]) {
        var repos: [GitRepoGroup] = []
        var rootByCwd: [String: String] = [:]
        var seenRoots = Set<String>()
        for cwd in cwds {
            let top = await run(["rev-parse", "--show-toplevel"], cwd: cwd)
            let root = trimmed(top.out)
            guard top.status == 0, !root.isEmpty else { continue }
            rootByCwd[cwd] = root
            if seenRoots.contains(root) { continue }
            let list = await run(["worktree", "list", "--porcelain"], cwd: root)
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
            let defaultName = await defaultBranch(root: root)

            let refs = await run(["for-each-ref", "--sort=-committerdate",
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
                    let status = await run(["status", "--porcelain=v1", "--untracked-files=all"], cwd: path)
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
                    let count = await run(["rev-list", "--count", base + ".." + ref], cwd: root)
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

    /// The first useful line of a failed write, for the header (a commit's: the form).
    /// Credential failures say so and point at the terminal, where a prompt can be answered;
    /// a pull that cannot fast-forward, a missing identity and a commit hook say what to do.
    static func errorLine(_ result: Result, remote: String, op: GitOp) -> String {
        let command = op.command
        let terminal = Theme.Glyphs.separator + command + " from the terminal"
        if result.timedOut { return "git " + command + " took too long" + terminal }
        // A commit hook may print to either stream.
        let all = (lines(result.err) + (op == .commit ? lines(result.out) : [])).map(trimmed)
        let credentials = ["could not read Username", "terminal prompts disabled", "Permission denied",
                           "Authentication failed", "Host key verification failed", "could not read Password"]
        if op != .commit, all.contains(where: { line in credentials.contains { line.contains($0) } }) {
            return "No credentials for " + remote + " here" + terminal
        }
        switch op {
        case .pull:
            if all.contains(where: { $0.contains("would be overwritten") }) {
                return "Uncommitted changes in the way" + terminal
            }
            if all.contains(where: { $0.contains("Not possible to fast-forward") || $0.contains("diverged") }) {
                return "Pull needs a merge" + terminal
            }
        case .commit:
            if all.contains(where: { $0.contains("Please tell me who you are") || $0.contains("empty ident") }) {
                return "No git identity" + Theme.Glyphs.separator + "set user.name and user.email in the terminal"
            }
            let hook = all.first { line in
                let lower = line.lowercased()
                return lower.hasPrefix("husky") || lower.contains("pre-commit hook")
                    || (lower.contains("hook") && lower.contains("failed"))
            }
            if let hook {
                return "A commit hook said no" + Theme.Glyphs.separator + String(hook.prefix(Theme.Limits.gitHookLine))
            }
        case .publish, .push, .fetch, .undo:
            break
        }
        let marked = all.first { line in
            ["fatal:", "error:", "! [rejected]", "! [remote rejected]", "remote: error"].contains { line.contains($0) }
        }
        let line = marked ?? all.first { !$0.hasPrefix("hint:") && !$0.hasPrefix("To ") } ?? ""
        var text = line
        for prefix in ["fatal: ", "error: "] where text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)) }
        return text.isEmpty ? "git " + command + " failed" : text
    }
}
