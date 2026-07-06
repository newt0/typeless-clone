import Foundation

/// The three insertion paths in the fallback chain (Design §6.2; plan M5-T3).
/// Ordered by preference: path 1 is default, path 3 is the guaranteed landing.
public enum InsertionPath: String, Sendable, Equatable, CaseIterable {
    /// Path 1 — synthetic Cmd+V paste simulation (M5-T2).
    case paste
    /// Path 2 — AppleScript `keystroke "v" using command down` via System Events.
    /// The fallback for the minority of apps where CGEvent paste doesn't land.
    case appleScript
    /// Path 3 — the designed landing (not an error): leave the marked text on
    /// the clipboard and tell the user to press ⌘V. Always "succeeds".
    case clipboardOnly
}

/// Per-app insertion override (Design §6.2 "switchable via per-app override";
/// plan M5-T3). Populated from settings (M10); the default is plain path 1 with
/// no extra delay.
public struct AppInsertionOverride: Sendable, Equatable {
    /// Which path to start the chain from for this app.
    public let preferredPath: InsertionPath
    /// Extra delay added before posting the paste keystroke, for apps that need
    /// more time to settle after the clipboard write.
    public let extraPreDelay: Duration

    public init(preferredPath: InsertionPath = .paste, extraPreDelay: Duration = .zero) {
        self.preferredPath = preferredPath
        self.extraPreDelay = extraPreDelay
    }
}

/// Bundle-id-keyed table of per-app overrides. An unknown app resolves to `nil`
/// (the caller uses the plain path-1 default). Immutable value; settings (M10)
/// rebuilds it when the user edits overrides.
public struct InsertionOverrideTable: Sendable, Equatable {
    private let byBundleID: [String: AppInsertionOverride]

    public init(_ byBundleID: [String: AppInsertionOverride] = [:]) {
        self.byBundleID = byBundleID
    }

    public func override(for bundleID: String?) -> AppInsertionOverride? {
        guard let bundleID else { return nil }
        return byBundleID[bundleID]
    }
}

/// Builds the ordered list of paths to attempt for a given starting preference.
/// Every plan ends at `.clipboardOnly` — the guaranteed landing — so the chain
/// can never fall off the end with the text lost (invariant 1).
public enum InsertionPathPlanner {
    public static func plan(preferred: InsertionPath) -> [InsertionPath] {
        switch preferred {
        case .paste:
            return [.paste, .appleScript, .clipboardOnly]
        case .appleScript:
            return [.appleScript, .clipboardOnly]
        case .clipboardOnly:
            return [.clipboardOnly]
        }
    }
}

/// Outcome of attempting one path in the chain.
public enum PathAttempt: Sendable, Equatable {
    /// This path landed the text; stop and report this result.
    case landed(InsertResult)
    /// This path failed or timed out; try the next path.
    case advance
}

/// Walks an insertion plan, attempting each path until one lands (Design §6.2,
/// §10.2-3; plan M5-T3). The system work per path lives in the app-layer
/// `attempt` closure (paste / AppleScript / clipboard); this pure walker owns
/// only the ordering and stop-at-first-success, so the fault-injection behavior
/// (block path 1 → walk to path 3) is unit-testable without any system APIs.
public enum InsertionChain {
    /// Attempt each path in `paths` in order, returning the first `.landed`
    /// result. A fully-exhausted plan falls back to `.clipboardFallback` — the
    /// guaranteed floor, since a well-formed plan always ends at
    /// `.clipboardOnly` (see ``InsertionPathPlanner``).
    public static func run(
        _ paths: [InsertionPath],
        isolation: isolated (any Actor)? = #isolation,
        attempt: (InsertionPath) async -> PathAttempt
    ) async -> InsertResult {
        for path in paths {
            if case .landed(let result) = await attempt(path) {
                return result
            }
        }
        return .clipboardFallback
    }
}
