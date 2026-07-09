import AppKit
import SwiftUI
import KoeCore

/// Owns the HUD `NSPanel` (Design §7.5; plan M9-T1) and feeds it events.
///
/// The panel never takes focus or disturbs IME composition in the target app:
/// `.nonactivatingPanel` + `ignoresMouseEvents` (no interactive elements yet —
/// the M4-T3 retry button will lift that per-state). `.statusBar` level +
/// all-Spaces/full-screen-auxiliary keep it visible over full-screen apps.
/// All decisions live in ``HUDReducer`` (KoeCore, tested); this class is the
/// untestable AppKit adapter: it hops events to the main actor, runs the two
/// dwell timers, and positions the panel bottom-center of the main screen.
@MainActor
final class HUDPanelController {
    private let panel: NSPanel
    private let store = HUDModelStore()
    private var phaseTimer: Task<Void, Never>?
    private var noticeTimer: Task<Void, Never>?
    /// The utterance whose lifecycle currently owns the panel — the most
    /// recently began one. Overlap policy (P0): state/partial events from
    /// older utterances are dropped; action-relevant outcomes
    /// (clipboardFallback / secureBlocked / failed) apply from any utterance
    /// because the user must see them even if a newer recording is up.
    private var currentUtterance = -1
    private var stateTasks: [Int: Task<Void, Never>] = [:]

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: HUDView(store: store))
        self.panel = panel
    }

    // MARK: Entry points (any isolation → main actor)

    /// Engine-side notices (device switch, session cap).
    nonisolated func notify(_ notice: HUDNotice) {
        Task { @MainActor in self.apply(.notice(notice)) }
    }

    /// Live partial line from the transcriber (display-only, never persisted).
    nonisolated func partial(_ text: String, _ context: UtteranceContext) {
        Task { @MainActor in
            guard context.index == self.currentUtterance else { return }
            self.apply(.partial(text))
        }
    }

    // MARK: Reduction + rendering

    private func apply(_ event: HUDEvent) {
        let previous = store.model
        let model = HUDReducer.reduce(previous, event)
        store.model = model

        if model.phase != previous.phase {
            phaseTimer?.cancel()
            phaseTimer = nil
            if let dwell = HUDReducer.phaseDwell(model.phase) {
                phaseTimer = Task { [weak self] in
                    try? await Task.sleep(for: dwell)
                    guard !Task.isCancelled else { return }
                    self?.apply(.phaseDismissFired)
                }
            }
        }
        if case .notice(let notice) = event {
            noticeTimer?.cancel()
            noticeTimer = Task { [weak self] in
                try? await Task.sleep(for: HUDReducer.noticeDwell(notice))
                guard !Task.isCancelled else { return }
                self?.apply(.noticeDismissFired)
            }
        }

        if model.phase == .hidden && model.notice == nil {
            panel.orderOut(nil)
        } else {
            show()
        }
    }

    private func show() {
        layoutBottomCenter()
        // Never activates the app or takes key status — the target app keeps
        // focus and IME composition (acceptance criterion).
        panel.orderFrontRegardless()
    }

    private func layoutBottomCenter() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = panel.contentView?.fittingSize ?? NSSize(width: 320, height: 44)
        panel.setContentSize(size)
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 96
        ))
    }
}

// MARK: - DictationUIObserving

extension HUDPanelController: DictationUIObserving {
    nonisolated func utteranceBegan(_ context: UtteranceContext, states: AsyncStream<DictationState>) {
        Task { @MainActor in
            self.currentUtterance = context.index
            self.stateTasks[context.index] = Task { [weak self] in
                for await state in states {
                    guard let self else { return }
                    await MainActor.run {
                        guard context.index == self.currentUtterance else { return }
                        self.apply(.state(state))
                    }
                }
                Task { @MainActor [weak self] in
                    self?.stateTasks[context.index] = nil
                }
            }
        }
    }

    nonisolated func utteranceLanded(_ context: UtteranceContext, result: InsertResult) {
        Task { @MainActor in
            // Quiet "done" flashes belong to the current utterance only, but
            // the user must always see action-relevant outcomes (see the
            // overlap policy on `currentUtterance`).
            let isCurrent = context.index == self.currentUtterance
            switch result {
            case .pasted, .pastedViaAppleScript:
                if isCurrent { self.apply(.landed(result)) }
            case .clipboardFallback, .blockedSecureInput:
                self.apply(.landed(result))
            }
        }
    }

    nonisolated func utteranceFailed(_ context: UtteranceContext) {
        Task { @MainActor in self.apply(.failed) }
    }
}
