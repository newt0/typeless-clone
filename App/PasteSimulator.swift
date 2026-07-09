import AppKit
import Carbon.HIToolbox
// CGEvent predates Swift Concurrency and is not `Sendable`. Every event here is
// created, posted, and dropped within one `@MainActor` method, so it never
// crosses an isolation boundary; `@preconcurrency` silences the spurious
// cross-actor Sendable diagnostics.
@preconcurrency import CoreGraphics
import KoeCore

/// Text insertion with the full fallback chain (Design §6.2, §6.3, §10.2-3;
/// plan M5-T2 path 1, M5-T3 paths 2–3 + per-app overrides).
///
/// Preflight → walk the insertion plan for the target app:
/// - **Path 1** (`.paste`): snapshot clipboard → write marked payload →
///   synthetic Cmd+V → best-effort AX verify → restore. (M5-T2)
/// - **Path 2** (`.appleScript`): same, but the keystroke is sent via
///   `System Events` AppleScript — the fallback for the minority of apps where
///   CGEvent paste doesn't land.
/// - **Path 3** (`.clipboardOnly`): the designed landing — leave the marked
///   text on the clipboard for a manual ⌘V (invariant 1's triple landing:
///   clipboard + HUD + history; HUD is M9, history write-ahead is M7).
///
/// Direct AX writing is never used (silent-failure prone; Design §6.1). AX is
/// read-only, for the preflight and best-effort verification (both via
/// ``InsertionContextProvider``). The pure ordering/decision logic lives in
/// KoeCore (``InsertionPreflight``, ``InsertionPathPlanner``, ``InsertionChain``,
/// ``InsertionOverrideTable``, ``PasteTextPreparer``, ``PasteboardMarkers``,
/// ``PasteVerification``); this class is the untestable system-API adapter.
@MainActor
final class PasteSimulator: TextInserting {
    private let context: InsertionContextProvider
    private let ownBundleID: String
    /// Per-app override table (preferred path + extra pre-delay). Empty by
    /// default; Settings (M10) rebuilds it via ``updateOverrides(_:)``.
    /// Resolved against the target app's bundle id at insertion time.
    private var overrides: InsertionOverrideTable
    /// M10 "LLM 失敗時" setting: true ⇒ a degraded (raw-transcript) output
    /// lands on the clipboard instead of being pasted. Read per insertion.
    private let degradedToClipboard: () -> Bool
    /// Guards against overlapping insertions racing on the shared NSPasteboard
    /// snapshot/restore. Production is already serialized by `InsertionSerializer`;
    /// this backstops the DEBUG QA hooks, which can be fired repeatedly.
    private var isInserting = false

    init(
        context: InsertionContextProvider = InsertionContextProvider(),
        ownBundleID: String = Bundle.main.bundleIdentifier ?? "dev.newt.Koe",
        overrides: InsertionOverrideTable = InsertionOverrideTable(),
        degradedToClipboard: @escaping () -> Bool = { false }
    ) {
        self.context = context
        self.ownBundleID = ownBundleID
        self.overrides = overrides
        self.degradedToClipboard = degradedToClipboard
    }

    /// Settings (M10) pushes edited per-app overrides; next insertion uses them.
    func updateOverrides(_ table: InsertionOverrideTable) {
        overrides = table
    }

    // MARK: TextInserting

    func insert(_ output: PipelineOutput, _ context: UtteranceContext) async throws -> InsertResult {
        // The recording-time bundle id rides the utterance itself, so two
        // overlapping dictations each check against the app they were spoken
        // into (session-10 review note, closed by the E2E wiring).
        await performInsert(
            output.text,
            recordingBundleID: context.recordingBundleID,
            // M10 "LLM 失敗時 = クリップボードのみ": a degraded output skips
            // the paste and takes the clipboard landing (after the secure
            // preflight — invariant 3 always wins).
            forceClipboardLanding: output.degraded && degradedToClipboard()
        )
    }

    // MARK: Insertion

    /// Run the preflight and, if clear, the per-app insertion plan.
    /// `recordingBundleID` is the app the utterance was dictated into; `nil`
    /// skips the app-change guard (QA hook pastes wherever the cursor is).
    func performInsert(
        _ text: String,
        recordingBundleID: String?,
        forceClipboardLanding: Bool = false
    ) async -> InsertResult {
        guard beginInserting() else { return .clipboardFallback }
        defer { isInserting = false }

        let facts = context.preflightFacts(recordingBundleID: recordingBundleID)
        switch InsertionPreflight.decide(facts) {
        case .blockedSecureInput(let reason):
            // Invariant 3: never insert, never touch the clipboard.
            Log.event("insert_blocked_secure", category: .insertion, code: secureCode(reason))
            return .blockedSecureInput

        case .proceed where forceClipboardLanding:
            Log.event("insert_clipboard_degraded_setting", category: .insertion)
            return clipboardLanding(text, targetBundleID: facts.frontmostBundleID)

        case .clipboardHold:
            // Frontmost app changed since recording: don't paste into the wrong
            // window — leave the marked text for the user to ⌘V (Design §6.3-1).
            // This is the path-3 landing, decided up front by the preflight.
            Log.event("insert_clipboard_hold_app_changed", category: .insertion)
            return clipboardLanding(text, targetBundleID: facts.frontmostBundleID)

        case .proceed:
            let override = overrides.override(for: facts.frontmostBundleID)
            return await runPlan(
                preferred: override?.preferredPath ?? .paste,
                extraPreDelay: override?.extraPreDelay ?? .zero,
                text: text,
                targetBundleID: facts.frontmostBundleID
            )
        }
    }

    /// Shared clipboard landing (app-changed hold + degraded-output setting):
    /// prepare, fall back to the raw text when preparation strips everything,
    /// and never clobber the user's clipboard for an empty payload (review
    /// finding — an empty degraded utterance wiped the clipboard).
    private func clipboardLanding(_ text: String, targetBundleID: String?) -> InsertResult {
        let prepared = PasteTextPreparer.prepare(text, targetBundleID: targetBundleID).text
        let payload = prepared.isEmpty ? text : prepared
        guard !payload.isEmpty else { return .pasted } // nothing to keep
        if !putMarkedText(payload, on: NSPasteboard.general) {
            Log.error("paste_clipboard_write_failed", category: .insertion)
        }
        return .clipboardFallback
    }

    /// Set the re-entrancy guard. Returns `false` (and logs) if an insertion is
    /// already in flight; check-and-set is atomic on the main actor.
    private func beginInserting() -> Bool {
        guard !isInserting else {
            Log.event("insert_reentrant_skipped", category: .insertion)
            return false
        }
        isInserting = true
        return true
    }

    /// Prepare the text and walk the plan from `preferred`. Shared by production
    /// and the DEBUG force-path QA hooks.
    private func runPlan(
        preferred: InsertionPath,
        extraPreDelay: Duration,
        text rawText: String,
        targetBundleID: String?
    ) async -> InsertResult {
        let prep = PasteTextPreparer.prepare(rawText, targetBundleID: targetBundleID)
        if prep.warnNewlines {
            // HUD caution lands in M9; log the hazard for now.
            Log.event("paste_terminal_newline", category: .insertion)
        }

        // Nothing safe to paste (e.g. an all-newline terminal payload stripped to
        // empty). Don't run the chain or claim a paste; leave the raw text on the
        // clipboard for a manual ⌘V so nothing is lost (history has it, inv. 1).
        guard !prep.text.isEmpty else {
            Log.event("paste_empty_after_prep", category: .insertion)
            guard !rawText.isEmpty else { return .pasted } // truly nothing to insert
            if !putMarkedText(rawText, on: NSPasteboard.general) {
                Log.error("paste_clipboard_write_failed", category: .insertion)
            }
            return .clipboardFallback
        }

        // Snapshot the user's clipboard ONCE, before any path writes to it, and
        // thread it through every attempt. A per-attempt snapshot would let a
        // later path capture an earlier *failed* path's leftover marked payload
        // (failed paths intentionally don't restore) and then "restore" that
        // instead of the user's real content — silently clobbering the clipboard.
        let originalSnapshot = snapshotItems(NSPasteboard.general)
        let plan = InsertionPathPlanner.plan(preferred: preferred)
        return await InsertionChain.run(plan) { [self] path in
            await attempt(path, text: prep.text, extraPreDelay: extraPreDelay, originalSnapshot: originalSnapshot)
        }
    }

    /// Perform one path's system work and report whether it landed.
    /// `originalSnapshot` is the user's pre-chain clipboard, restored on a landed
    /// keystroke paste (shared across all paths — see ``runPlan``).
    private func attempt(
        _ path: InsertionPath,
        text: String,
        extraPreDelay: Duration,
        originalSnapshot: [[NSPasteboard.PasteboardType: Data]]
    ) async -> PathAttempt {
        switch path {
        case .paste:
            let outcome = await pasteViaKeystroke(
                text: text, extraPreDelay: extraPreDelay, success: .pasted,
                originalSnapshot: originalSnapshot, post: { [self] in await postCmdV() }
            )
            if case .landed = outcome { Log.event("paste_done", category: .insertion) }
            return outcome

        case .appleScript:
            let outcome = await pasteViaKeystroke(
                text: text, extraPreDelay: extraPreDelay, success: .pastedViaAppleScript,
                originalSnapshot: originalSnapshot, post: { [self] in await runAppleScriptPaste() }
            )
            if case .landed = outcome { Log.event("paste_applescript_done", category: .insertion) }
            return outcome

        case .clipboardOnly:
            // Designed landing (Design §6.2): leave the marked text for ⌘V.
            if !putMarkedText(text, on: NSPasteboard.general) {
                Log.error("paste_clipboard_write_failed", category: .insertion)
            }
            Log.event("paste_clipboard_landing", category: .insertion)
            return .landed(.clipboardFallback)
        }
    }

    /// Shared paste body for paths 1 and 2 (they differ only in how the Cmd+V
    /// keystroke is delivered via `post`). Snapshot → write marked payload →
    /// pre-delay → post → settle → verify → restore-if-still-ours.
    private func pasteViaKeystroke(
        text: String,
        extraPreDelay: Duration,
        success: InsertResult,
        originalSnapshot: [[NSPasteboard.PasteboardType: Data]],
        post: () async -> Bool
    ) async -> PathAttempt {
        let pasteboard = NSPasteboard.general
        let sessionID = UUID()
        let sessionType = NSPasteboard.PasteboardType(PasteboardMarkers.sessionType(sessionID))

        // If the write fails (pasteboard ownership raced away), don't post the
        // keystroke — that would paste stale content. Advance; the payload isn't
        // there but history holds the text and the next path re-writes it.
        guard writePayload(text, sessionID: sessionID, sessionType: sessionType, to: pasteboard) else {
            Log.error("paste_write_failed", category: .insertion)
            return .advance
        }

        // A cancelled pre-delay must not post the keystroke: the clipboard write
        // may not have propagated yet and the target would paste stale content.
        // Advance instead — the payload stays for the next path, ultimately the
        // clipboard landing (which posts no keystroke).
        do {
            try await Task.sleep(for: KoeConstants.pastePreDelay + extraPreDelay)
        } catch {
            return .advance
        }
        // Couldn't deliver the keystroke → advance, leaving the payload for the
        // next path.
        guard await post() else { return .advance }

        // The restore wait doubles as the settle window that lets the paste land
        // before the best-effort AX verification reads the focused element.
        // The keystroke is already out, so the settle/verify/restore choreography
        // must finish even if this Task is cancelled — the unstructured child
        // shields the sleep from cancellation. Aborting early would either
        // restore before the target reads the clipboard (pasting the OLD
        // content) or skip the restore entirely (permanently clobbering the
        // user's clipboard).
        await Task { try? await Task.sleep(for: KoeConstants.clipboardRestoreWait) }.value
        if verify(insertedText: text) == .verifiedFailed {
            // Explicit failure → next path. Do NOT restore (restoring would drop
            // the text the paste failed to insert); the marked payload stays.
            Log.event("paste_verify_failed", category: .insertion)
            return .advance
        }

        // Restore the user's clipboard — but only if our write is still the
        // current content. If the session marker is gone, another process wrote
        // in the meantime and restoring would clobber it (Design §6.3-6).
        if pasteboard.types?.contains(sessionType) ?? false {
            if !restore(originalSnapshot, to: pasteboard) {
                Log.error("paste_restore_failed", category: .insertion)
            }
        }
        return .landed(success)
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

    /// Leave marked text on the clipboard for a manual ⌘V (path 3, app-change,
    /// and empty-payload landings). Generates a throwaway session id since there
    /// is no restore to gate. Returns whether the write succeeded.
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

    // MARK: Keystroke delivery

    /// Path 1: post Cmd↓ → V↓ → V↑ → Cmd↑ from a private event source to the HID
    /// tap, 10ms apart (Design §6.3-4). The "v" keycode is resolved for the
    /// current layout so non-QWERTY layouts still paste. Returns whether the
    /// event source could be created.
    private func postCmdV() async -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else {
            Log.error("paste_event_source_failed", category: .insertion)
            return false
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
        return true
    }

    /// Path 2: deliver Cmd+V via `System Events` AppleScript (Design §6.2). Run
    /// through `osascript` so the call is cancellable and bounded by the stage
    /// timeout — a hung/blocked run is terminated and reported as a failure so
    /// the chain advances. Returns whether the script exited cleanly (exit 0).
    private func runAppleScriptPaste() async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"System Events\" to keystroke \"v\" using command down"]

        // Terminate if the run overruns the per-stage timeout (e.g. a blocked
        // Automation-permission prompt); same-actor capture of `process`.
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: KoeConstants.insertionStageTimeout)
            if process.isRunning {
                Log.error("paste_applescript_timeout", category: .insertion)
                process.terminate()
            }
        }
        // The handler must be installed BEFORE run(): a handler assigned after
        // the process already exited is never invoked, which would leave this
        // continuation suspended forever and stall the insertion FIFO.
        let launched = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            process.terminationHandler = { _ in continuation.resume(returning: true) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
            }
        }
        watchdog.cancel()
        guard launched else {
            Log.error("paste_applescript_launch_failed", category: .insertion)
            return false
        }

        let ok = process.terminationStatus == 0
        if !ok { Log.event("paste_applescript_failed", category: .insertion, code: Int(process.terminationStatus)) }
        return ok
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

    // MARK: QA

    #if DEBUG
    /// DEBUG-only QA entry: run the chain from a forced starting path, bypassing
    /// the app-change guard (there's no recording app in QA) but still honoring
    /// the secure-input block. Lets the owner exercise each path by hand before
    /// the pipeline is wired end-to-end.
    func debugInsert(_ text: String, forcing path: InsertionPath) async -> InsertResult {
        guard beginInserting() else { return .clipboardFallback }
        defer { isInserting = false }

        let facts = context.preflightFacts(recordingBundleID: nil)
        if case .blockedSecureInput(let reason) = InsertionPreflight.decide(facts) {
            Log.event("insert_blocked_secure", category: .insertion, code: secureCode(reason))
            return .blockedSecureInput
        }
        return await runPlan(
            preferred: path, extraPreDelay: .zero, text: text, targetBundleID: facts.frontmostBundleID
        )
    }
    #endif
}
