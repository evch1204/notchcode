// AppState+Teleport.swift
// Bringing a session's terminal to the front, and the terminal tables it reads.

import AppKit
import SwiftUI

extension AppState {

    /// TERM_PROGRAM -> bundle id.
    static let terminalBundleIds: [String: String] = [
        "ghostty": "com.mitchellh.ghostty",
        "iTerm.app": "com.googlecode.iterm2",
        "Apple_Terminal": "com.apple.Terminal",
        "vscode": "com.microsoft.VSCode",
        "cursor": "com.todesktop.230313mzl4w4u92",
        "WarpTerminal": "dev.warp.Warp-Stable",
    ]

    static let terminalNames: [String: String] = [
        "ghostty": "Ghostty",
        "iTerm.app": "iTerm",
        "Apple_Terminal": "Terminal",
        "vscode": "VS Code",
        "cursor": "Cursor",
        "WarpTerminal": "Warp",
    ]

    /// Tried in order when a session has no terminal on record: the first one running wins.
    static let knownTerminalBundleIds: [String] = [
        "com.mitchellh.ghostty",
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",
        "dev.warp.Warp",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "org.alacritty",
    ]

    func terminalName(for session: Session?) -> String {
        guard let program = session?.termProgram, let name = Self.terminalNames[program] else {
            return "terminal"
        }
        return name
    }

    func setNotch(width: CGFloat, height: CGFloat) {
        let next = NotchLayout(notchWidth: width, notchHeight: height)
        if next != layout { layout = next }
    }

    /// Bring the session's terminal to the front. Activates the app only; never runs a command.
    /// The session's own terminal first (bundle id, then TERM_PROGRAM), else the first known
    /// terminal that is running. With none, a short "No terminal found" hint and the card stays.
    func teleport(session: Session?) {
        let session = session ?? focusedSession
        let recorded = [session?.termBundleId, session?.termProgram.flatMap { Self.terminalBundleIds[$0] }].compactMap { $0 }
        for bundleId in recorded {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
                activateAndClose(app)
                return
            }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                fold {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
                }
                return
            }
        }
        for bundleId in Self.knownTerminalBundleIds {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
                activateAndClose(app)
                return
            }
        }
        flash("No terminal found")
    }

    private func activateAndClose(_ app: NSRunningApplication) {
        fold { app.activate() }
    }

    /// Teleport fold: the card folds into the notch (height, then width) and the terminal is
    /// brought forward at the 0.15 s mark so it rises behind. Reduce Motion: activate at once.
    private func fold(activate: @escaping () -> Void) {
        skipFocusReturn = true
        let reduce = Theme.Motion.reduceMotion
        if isCardOpen && !reduce {
            teleportFold = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.teleportActivateAt) { activate() }
            DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.foldTotal) { [weak self] in
                self?.teleportFold = false
            }
        } else {
            activate()
        }
        closeCard()
    }
}
