import os

/// The single logging seam for the whole app (invariant 4: no body text).
///
/// By design there is **no API here that accepts a runtime `String`**: event
/// names are `StaticString` (compile-time literals) and metadata is numeric, so
/// a transcript, formatted text, or dictionary term can never be interpolated
/// into a log line. Direct `os_log` / `NSLog` / `print` are banned by CI
/// everywhere except this file.
public enum Log {
    public enum Category: String, Sendable {
        case app, session, hotkey, audio, stt, llm, insertion, history, permission
    }

    private static let subsystem = "dev.newt.Koe"

    private static func logger(_ category: Category) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }

    /// Record an event. `code` is an optional numeric detail (e.g. an error
    /// code, a state raw value, a duration in ms) — never free text.
    public static func event(_ name: StaticString, category: Category = .app, code: Int? = nil) {
        if let code {
            logger(category).notice("\(name, privacy: .public) code=\(code, privacy: .public)")
        } else {
            logger(category).notice("\(name, privacy: .public)")
        }
    }

    /// Record an error-level event. Same body-text-free contract as ``event``.
    public static func error(_ name: StaticString, category: Category = .app, code: Int? = nil) {
        if let code {
            logger(category).error("\(name, privacy: .public) code=\(code, privacy: .public)")
        } else {
            logger(category).error("\(name, privacy: .public)")
        }
    }
}
