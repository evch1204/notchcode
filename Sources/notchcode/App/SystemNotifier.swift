// SystemNotifier.swift
// Optional macOS notification for blocking events (Settings → "When Claude needs you").
// Only posts; clicking it does nothing beyond bringing the app forward.

import Foundation
import UserNotifications

enum SystemNotifier {
    /// UNUserNotificationCenter needs a real app bundle; a bare binary would crash on access.
    private static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, subtitle: String?, body: String, id: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle { content.subtitle = subtitle }
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// Clears the notification once the request is answered anywhere.
    static func remove(id: String) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }
}
