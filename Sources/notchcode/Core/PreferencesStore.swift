// PreferencesStore.swift
// Preferences live in UserDefaults as one JSON blob under one key.
// A missing or unreadable blob gives the defaults from Contract.swift.
// Choices Contract's `Preferences` has no field for (ExtraPreferences) are stored
// as extra keys in the same blob; `Preferences` decoding ignores them.

import Foundation

/// Owner choices added after the Contract's `Preferences` was fixed. Same blob, extra keys.
struct ExtraPreferences: Equatable, Codable {
    /// Peek every file edit, not only completed turns and subagents.
    var peekEdits: Bool = PreferencesStore.defaultPeekEdits
    /// The Files tool's tree is collapsed so the preview takes the whole well (⌘B).
    var filesTreeHidden: Bool = false
    /// The small keycaps beside buttons and pills inside the card. The footer's key row and
    /// the attention row keep theirs either way; the shortcuts work either way.
    var keycapsBesideButtons: Bool = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        peekEdits = try c.decodeIfPresent(Bool.self, forKey: .peekEdits) ?? PreferencesStore.defaultPeekEdits
        filesTreeHidden = try c.decodeIfPresent(Bool.self, forKey: .filesTreeHidden) ?? false
        keycapsBesideButtons = try c.decodeIfPresent(Bool.self, forKey: .keycapsBesideButtons) ?? true
    }
}

enum PreferencesStore {
    static let key = "notchcode.preferences"
    static let defaultPeekEdits = false

    static func load(from defaults: UserDefaults = .standard) -> Preferences {
        guard let data = defaults.data(forKey: key),
              let prefs = try? JSONDecoder().decode(Preferences.self, from: data) else {
            return Preferences()
        }
        return prefs
    }

    static func loadExtras(from defaults: UserDefaults = .standard) -> ExtraPreferences {
        guard let data = defaults.data(forKey: key),
              let extras = try? JSONDecoder().decode(ExtraPreferences.self, from: data) else {
            return ExtraPreferences()
        }
        return extras
    }

    /// Writes both into one JSON object.
    static func save(_ prefs: Preferences, extras: ExtraPreferences, to defaults: UserDefaults = .standard) {
        guard let base = try? JSONEncoder().encode(prefs),
              let extra = try? JSONEncoder().encode(extras),
              var object = (try? JSONSerialization.jsonObject(with: base)) as? [String: Any],
              let more = (try? JSONSerialization.jsonObject(with: extra)) as? [String: Any] else { return }
        object.merge(more) { _, new in new }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        defaults.set(data, forKey: key)
    }
}
