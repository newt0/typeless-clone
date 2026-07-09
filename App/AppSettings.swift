import Foundation
import KoeCore

/// Typed access to the app's `UserDefaults`-backed preferences (plan M10-T1).
/// Consumers read through closures per use (live application, no relaunch);
/// the Settings UI writes here. API keys never touch this type (invariant 5).
enum AppSettings {
    private static var defaults: UserDefaults { .standard }

    static var preferBuiltInMic: Bool {
        get { defaults.object(forKey: AppDefaultsKey.preferBuiltInMic) as? Bool ?? true }
        set { defaults.set(newValue, forKey: AppDefaultsKey.preferBuiltInMic) }
    }

    static var writingStyle: WritingStyle {
        get {
            (defaults.string(forKey: AppDefaultsKey.writingStyle))
                .flatMap(WritingStyle.init(rawValue:)) ?? .auto
        }
        set { defaults.set(newValue.rawValue, forKey: AppDefaultsKey.writingStyle) }
    }

    static var degradedToClipboard: Bool {
        get { defaults.bool(forKey: AppDefaultsKey.degradedToClipboard) }
        set { defaults.set(newValue, forKey: AppDefaultsKey.degradedToClipboard) }
    }

    /// 0 = keep forever.
    static var historyRetentionDays: Int {
        get { defaults.integer(forKey: AppDefaultsKey.historyRetentionDays) }
        set { defaults.set(newValue, forKey: AppDefaultsKey.historyRetentionDays) }
    }

    static var telemetryOptOut: Bool {
        get { defaults.bool(forKey: AppDefaultsKey.telemetryOptOut) }
        set { defaults.set(newValue, forKey: AppDefaultsKey.telemetryOptOut) }
    }

    static var fnHotkeyEnabled: Bool {
        get { defaults.object(forKey: AppDefaultsKey.fnHotkeyEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: AppDefaultsKey.fnHotkeyEnabled) }
    }

    // MARK: Per-app insertion overrides (M5-T3 table)

    /// JSON wire form for one override row.
    struct OverrideEntry: Codable, Identifiable, Equatable {
        var bundleID: String
        var path: String        // InsertionPath.rawValue
        var extraDelayMS: Int
        var id: String { bundleID }
    }

    static var overrideEntries: [OverrideEntry] {
        get {
            guard let data = defaults.data(forKey: AppDefaultsKey.insertionOverrides) else { return [] }
            return (try? JSONDecoder().decode([OverrideEntry].self, from: data)) ?? []
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: AppDefaultsKey.insertionOverrides)
        }
    }

    static func overrideTable() -> InsertionOverrideTable {
        var byBundleID: [String: AppInsertionOverride] = [:]
        for entry in overrideEntries {
            guard let path = InsertionPath(rawValue: entry.path), !entry.bundleID.isEmpty else { continue }
            byBundleID[entry.bundleID] = AppInsertionOverride(
                preferredPath: path,
                extraPreDelay: .milliseconds(max(0, entry.extraDelayMS))
            )
        }
        return InsertionOverrideTable(byBundleID)
    }
}
