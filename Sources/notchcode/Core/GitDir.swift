// GitDir.swift
// Reads a checkout's git facts straight from its `.git` (no `git` process): the branch
// from HEAD, and the repository's name from its git directory. Shared by the transcript
// reader (sessions) and GitRunner (the Git tool).

import Foundation

enum GitDir {

    /// The checked-out branch, from HEAD. A detached HEAD gives its short SHA.
    static func gitBranch(cwd: String) -> String? {
        guard let git = locateGit(from: cwd),
              let head = try? String(contentsOfFile: git.gitDir + "/HEAD", encoding: .utf8)
        else { return nil }
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        if line.hasPrefix(prefix) { return String(line.dropFirst(prefix.count)) }
        if line.hasPrefix("ref: ") { return String(line.dropFirst(5)) }
        guard !line.isEmpty else { return nil }
        return String(line.prefix(7))   // detached HEAD: short SHA
    }

    /// For a linked worktree, the name of the main repo folder. Nil for a plain checkout.
    static func repoName(cwd: String) -> String? {
        guard let git = locateGit(from: cwd), git.isWorktree else { return nil }
        // gitdir looks like <repo>/.git/worktrees/<name>, or <name>.git/worktrees/<name> for a bare repo.
        let parts = URL(fileURLWithPath: git.gitDir).standardizedFileURL.pathComponents
        guard let idx = parts.lastIndex(of: "worktrees"), idx >= 1 else { return nil }
        let gitFolder = parts[idx - 1]
        if gitFolder == ".git" {
            guard idx >= 2, parts[idx - 2] != "/" else { return nil }
        } else if !gitFolder.hasSuffix(".git") {
            return nil
        }
        return repoName(commonDir: NSString.path(withComponents: Array(parts[..<idx])))
    }

    /// "notchcode" for "/…/notchcode/.git", "tools" for a bare "/…/tools.git".
    static func repoName(commonDir: String) -> String? {
        guard !commonDir.isEmpty else { return nil }
        let url = URL(fileURLWithPath: commonDir)
        let last = url.lastPathComponent
        if last == ".git" { return url.deletingLastPathComponent().lastPathComponent }
        if last.hasSuffix(".git") { return String(last.dropLast(4)) }
        return last
    }

    private struct GitLocation {
        var gitDir: String
        var isWorktree: Bool
    }

    /// Walks up from cwd to the first `.git`. A directory is a plain checkout; a file
    /// (`gitdir: <path>`) is a linked worktree or a submodule.
    private static func locateGit(from cwd: String) -> GitLocation? {
        guard !cwd.isEmpty else { return nil }
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: cwd).standardizedFileURL
        for _ in 0..<64 {
            let dotGit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                if isDir.boolValue { return GitLocation(gitDir: dotGit.path, isWorktree: false) }
                guard let text = try? String(contentsOf: dotGit, encoding: .utf8) else { return nil }
                for raw in text.split(whereSeparator: \.isNewline) {
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    guard line.hasPrefix("gitdir:") else { continue }
                    let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    let resolved = path.hasPrefix("/")
                        ? URL(fileURLWithPath: path)
                        : dir.appendingPathComponent(path)
                    let gitDir = resolved.standardizedFileURL.path
                    return GitLocation(gitDir: gitDir, isWorktree: gitDir.contains("/worktrees/"))
                }
                return nil
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }
}
