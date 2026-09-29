// AppState+Teleport.swift
// Bringing a session's terminal to the front, and the terminal tables it reads.

import AppKit
import SwiftUI

extension AppState {

    /// The terminals teleport knows: TERM_PROGRAM, the name buttons show, the bundle id.
    /// With no terminal on record for a session, the first one running wins, in this order.
    private static let terminals: [(program: String?, name: String?, bundleId: String)] = [
        ("ghostty", "Ghostty", "com.mitchellh.ghostty"),
        ("iTerm.app", "iTerm", "com.googlecode.iterm2"),
        ("Apple_Terminal", "Terminal", "com.apple.Terminal"),
        ("vscode", "VS Code", "com.microsoft.VSCode"),
        ("cursor", "Cursor", "com.todesktop.230313mzl4w4u92"),
        (nil, nil, "dev.warp.Warp"),
        ("WarpTerminal", "Warp", "dev.warp.Warp-Stable"),
        (nil, nil, "net.kovidgoyal.kitty"),
        (nil, nil, "org.alacritty"),
    ]

    private static func terminal(program: String?) -> (program: String?, name: String?, bundleId: String)? {
        guard let program else { return nil }
        return terminals.first { $0.program == program }
    }

    func terminalName(for session: Session?) -> String {
        Self.terminal(program: session?.termProgram)?.name ?? "terminal"
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
        let recorded = [session?.termBundleId, Self.terminal(program: session?.termProgram)?.bundleId].compactMap { $0 }
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
        for bundleId in Self.terminals.map(\.bundleId) {
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
