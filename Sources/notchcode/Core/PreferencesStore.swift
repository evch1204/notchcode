// PreferencesStore.swift
// Preferences live in UserDefaults as one JSON blob under one key, the keys sorted.
// A missing or unreadable blob gives the defaults from Contract.swift.

import Foundation

enum PreferencesStore {
    static let key = "notchcode.preferences"

    static func load(from defaults: UserDefaults = .standard) -> Preferences {
        guard let data = defaults.data(forKey: key),
              let prefs = try? JSONDecoder().decode(Preferences.self, from: data) else {
            return Preferences()
        }
        return prefs
    }

    static func save(_ prefs: Preferences, to defaults: UserDefaults = .standard) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(prefs) else { return }
        defaults.set(data, forKey: key)
    }
}
