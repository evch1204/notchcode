// NotchcodeApp.swift
// Entry point. An accessory app with no scenes and no windows of its own: the
// notch panel (made by AppDelegate) is the only surface, Settings included.

import AppKit

@main
enum NotchcodeApp {
    /// Kept for the life of the process; NSApplication holds its delegate weakly.
    @MainActor private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
