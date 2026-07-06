import AppKit
import Carbon.HIToolbox
// CGEvent predates Swift Concurrency and is not `Sendable`. Every event here is
// created, posted, and dropped within one `@MainActor` method, so it never
// crosses an isolation boundary; `@preconcurrency` silences the spurious
// cross-actor Sendable diagnostics.
@preconcurrency import CoreGraphics
import KoeCore

/// Path 1 text insertion — paste simulation (Design §6.2, §6.3; plan M5-T2).
///
/// The reliability-critical primary path: snapshot the clipboard → write the
/// formatted text with nspasteboard markers → synthesize Cmd+V → restore the
/// snapshot. Direct AX writing is never used (silent-failure prone; Design
/// §6.1). AX is read-only, for the preflight and best-effort verification (both
/// via ``InsertionContextProvider``).
///
/// This is the untestable system-API adapter; the pure pieces live in KoeCore
/// (``InsertionPreflight``, ``PasteTextPreparer``, ``PasteboardMarkers``,
/// ``PasteVerification``).
///
/// Scope note (M5-T2): paths 2–3 land in M5-T3. Here, a secure context blocks
/// (nothing inserted or copied), an app-change or an explicitly-verified paste
/// failure leaves the marked text on the clipboard as the designed fallback
/// landing, and everything else pastes and restores.
@MainActor
final class PasteSimulator: TextInserting {
    private let context: InsertionContextProvider
    private let ownBundleID: String
    /// Frontmost bundle id captured when the current recording started; the
    /// coordinator supplies this at record time (future wiring). `nil` skips the
    /// app-change guard — used by the QA hook, which pastes wherever the cursor is.
    ///
    /// ⚠︎ M5-T3 wiring note: this is a single fixed closure, so it cannot tell
    /// two *overlapping* utterances apart (SessionCoordinator records
    /// concurrently, serializing only at insertion). Before wiring the real
    /// pipeline, the per-utterance recording bundle id must be threaded through
    /// `UtteranceContext` (or captured per `insert` call), not read from one
    /// shared closure — otherwise the app-change preflight can consult the wrong
    /// utterance's app. See docs/decisions.md (session 10).
    private let recordingBundleID: @Sendable () -> String?

    /// Guards against overlapping insertions racing on the shared NSPasteboard
    /// snapshot/restore. Production is already serialized by `InsertionSerializer`;
    /// this backstops the DEBUG QA hook, which can be fired repeatedly.
    private var isInserting = false

    init(
        context: InsertionContextProvider = InsertionContextProvider(),
        ownBundleID: String = Bundle.main.bundleIdentifier ?? "dev.newt.Koe",
        recordingBundleID: @escaping @Sendable () -> String? = { nil }
    ) {
        self.context = context
        self.ownBundleID = ownBundleID
        self.recordingBundleID = recordingBundleID
    }

    // MARK: TextInserting

    func insert(_ output: PipelineOutput, _ context: UtteranceContext) async throws -> InsertResult {
        await performInsert(output.text)
    }

    // MARK: Insertion

    /// Run the preflight and, if clear, path 1. Also the direct entry for QA.
    func performInsert(_ text: String) async -> InsertResult {
        // Re-entrancy guard: a second insertion started while one is still in
        // flight would snapshot the first's marked payload and clobber the
        // user's real clipboard on restore. Check-and-set is atomic on the main
        // actor (no await between them).
        guard !isInserting else {
            Log.event("insert_reentrant_skipped", category: .insertion)
            return .clipboardFallback
        }
        isInserting = true
        defer { isInserting = false }

        let facts = context.preflightFacts(recordingBundleID: recordingBundleID())
        switch InsertionPreflight.decide(facts) {
        case .blockedSecureInput(let reason):
            // Invariant 3: never insert, never touch the clipboard.
            Log.event("insert_blocked_secure", category: .insertion, code: secureCode(reason))
            return .blockedSecureInput

        case .clipboardHold:
            // Frontmost app changed since recording: don't paste into the wrong
            // window — leave the marked text for the user to ⌘V (Design §6.3-1).
            Log.event("insert_clipboard_hold_app_changed", category: .insertion)
            let prepared = PasteTextPreparer.prepare(text, targetBundleID: facts.frontmostBundleID).text
            if !putMarkedText(prepared, on: NSPasteboard.general) {
                Log.error("paste_clipboard_write_failed", category: .insertion)
            }
            return .clipboardFallback

        case .proceed:
            return await pasteSimulation(text, targetBundleID: facts.frontmostBundleID)
        }
    }

    private func pasteSimulation(_ rawText: String, targetBundleID: String?) async -> InsertResult {
        let prep = PasteTextPreparer.prepare(rawText, targetBundleID: targetBundleID)
        if prep.warnNewlines {
            // HUD caution lands in M9; log the hazard for now.
            Log.event("paste_terminal_newline", category: .insertion)
        }

        let pasteboard = NSPasteboard.general

        // Nothing safe to paste (e.g. an all-newline terminal payload stripped to
        // empty). Don't run the paste/verify/restore dance and don't claim a
        // paste happened; leave the raw text on the clipboard for a manual ⌘V so
        // nothing is lost (history already has it via write-ahead, invariant 1).
        guard !prep.text.isEmpty else {
            Log.event("paste_empty_after_prep", category: .insertion)
            guard !rawText.isEmpty else { return .pasted } // truly nothing to insert
            if !putMarkedText(rawText, on: pasteboard) {
                Log.error("paste_clipboard_write_failed", category: .insertion)
            }
            return .clipboardFallback
        }

        let sessionID = UUID()
        let sessionType = NSPasteboard.PasteboardType(PasteboardMarkers.sessionType(sessionID))

        // 1. Snapshot every item/type to memory so we can restore afterward.
        let snapshot = snapshotItems(pasteboard)

        // 2. Write the marked payload. If the write itself fails (pasteboard
        // ownership raced away), don't post Cmd+V — that would paste stale
        // content. History still holds the text (write-ahead), so land on the
        // clipboard-fallback path.
        guard writePayload(prep.text, sessionID: sessionID, sessionType: sessionType, to: pasteboard) else {
            Log.error("paste_write_failed", category: .insertion)
            return .clipboardFallback
        }

        // 3. Pre-delay, then 4. synthesize Cmd+V.
        try? await Task.sleep(for: KoeConstants.pastePreDelay)
        await postCmdV()

        // The restore wait doubles as the settle window that lets the paste land
        // before the best-effort AX verification reads the focused element.
        try? await Task.sleep(for: KoeConstants.clipboardRestoreWait)

        // 5. Best-effort verification. Only an explicit failure changes behavior.
        if verify(insertedText: prep.text) == .verifiedFailed {
            // Path 2 (AppleScript) lands in M5-T3. For now leave the marked
            // payload on the clipboard as the fallback landing — do NOT restore
            // (restoring would drop the text the paste failed to insert).
            Log.event("paste_verify_failed", category: .insertion)
            return .clipboardFallback
        }

        // 6. Restore the user's clipboard — but only if our write is still the
        // current content. If the session marker is gone, another process wrote
        // in the meantime and restoring would clobber it (Design §6.3-6).
        if pasteboard.types?.contains(sessionType) ?? false {
            if !restore(snapshot, to: pasteboard) {
                Log.error("paste_restore_failed", category: .insertion)
            }
        }
        Log.event("paste_done", category: .insertion)
        return .pasted
    }

    // MARK: Clipboard

    /// Snapshot all items and all their type/data pairs into memory.
    private func snapshotItems(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var byType: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { byType[type] = data }
            }
            return byType
        }
    }

    /// Write plain text plus the transient/auto-generated/source/session markers
    /// (Design §6.3-3). `ConcealedType` is intentionally omitted. Returns whether
    /// the pasteboard accepted the write.
    @discardableResult
    private func writePayload(
        _ text: String,
        sessionID: UUID,
        sessionType: NSPasteboard.PasteboardType,
        to pasteboard: NSPasteboard
    ) -> Bool {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType(PasteboardMarkers.transient))
        item.setString("", forType: NSPasteboard.PasteboardType(PasteboardMarkers.autoGenerated))
        item.setString(ownBundleID, forType: NSPasteboard.PasteboardType(PasteboardMarkers.source))
        item.setString(sessionID.uuidString, forType: sessionType)
        return pasteboard.writeObjects([item])
    }

    /// Leave marked text on the clipboard for a manual ⌘V (app-change,
    /// verify-failure, and empty-payload landings). Generates a throwaway session
    /// id since there is no restore to gate. Returns whether the write succeeded.
    @discardableResult
    private func putMarkedText(_ text: String, on pasteboard: NSPasteboard) -> Bool {
        let sessionID = UUID()
        let sessionType = NSPasteboard.PasteboardType(PasteboardMarkers.sessionType(sessionID))
        return writePayload(text, sessionID: sessionID, sessionType: sessionType, to: pasteboard)
    }

    /// Restore a snapshot. An empty snapshot leaves the pasteboard cleared
    /// (the clipboard was empty to begin with). Returns whether the write
    /// succeeded (an empty snapshot is a successful no-op).
    @discardableResult
    private func restore(_ snapshot: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return true }
        let items = snapshot.map { byType -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in byType { item.setData(data, forType: type) }
            return item
        }
        return pasteboard.writeObjects(items)
    }

    // MARK: Synthetic Cmd+V

    /// Post Cmd↓ → V↓ → V↑ → Cmd↑ from a private event source to the HID tap,
    /// 10ms apart (Design §6.3-4). The "v" keycode is resolved for the current
    /// layout so non-QWERTY layouts still paste.
    private func postCmdV() async {
        guard let source = CGEventSource(stateID: .privateState) else {
            Log.error("paste_event_source_failed", category: .insertion)
            return
        }
        let v = PasteKeyResolver.vKeyCode()
        let cmd = CGKeyCode(kVK_Command)
        // (key, keyDown, flags) — the V events carry .maskCommand so the target
        // sees Cmd held; the trailing Cmd↑ clears it.
        let sequence: [(CGKeyCode, Bool, CGEventFlags)] = [
            (cmd, true, .maskCommand),
            (v, true, .maskCommand),
            (v, false, .maskCommand),
            (cmd, false, []),
        ]
        for (key, keyDown, flags) in sequence {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: keyDown) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
            try? await Task.sleep(for: KoeConstants.synthKeyInterval)
        }
    }

    // MARK: Verification

    /// Best-effort read of the focused element's value to confirm the paste
    /// landed (Design §6.3-5). Unreadable focus ⇒ `.unverifiable` (assume
    /// success). Uses the last up-to-32 characters of the payload as the needle.
    private func verify(insertedText: String) -> PasteVerification.Verdict {
        let tail = String(insertedText.suffix(32))
        return PasteVerification.verdict(focusedValue: context.focusedValueSnippet(), insertedTail: tail)
    }

    private func secureCode(_ reason: SecureBlockReason) -> Int {
        switch reason {
        case .secureEventInput: return 1
        case .secureField: return 2
        }
    }
}
