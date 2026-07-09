import AppKit
import SwiftUI
import KoeCore

/// Owns the HUD `NSPanel` (Design §7.5; plan M9-T1) and feeds it events.
///
/// The panel never takes focus or disturbs IME composition in the target app:
/// `.nonactivatingPanel` + `ignoresMouseEvents` (no interactive elements yet —
/// the M4-T3 retry button will lift that per-state). `.statusBar` level +
/// all-Spaces/full-screen-auxiliary keep it visible over full-screen apps.
/// All decisions — including which utterance's events own the panel — live in
/// ``HUDReducer`` (KoeCore, tested); this class is the untestable AppKit
/// adapter: it hops events to the main actor, runs the two dwell timers, and
/// positions the panel bottom-center of the main screen.
@MainActor
final class HUDPanelController {
    private let panel: NSPanel
    private let store = HUDModelStore()
    private var phaseTimer: Task<Void, Never>?
    private var noticeTimer: Task<Void, Never>?

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
        Task { @MainActor in self.apply(.partial(utterance: context.index, text)) }
    }

    // MARK: Reduction + rendering

    private func apply(_ event: HUDEvent) {
        let previous = store.model
        let model = HUDReducer.reduce(previous, event)
        guard model != previous else { return }
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
        if model.notice != previous.notice, let notice = model.notice {
            noticeTimer?.cancel()
            noticeTimer = Task { [weak self] in
                try? await Task.sleep(for: HUDReducer.noticeDwell(notice))
                guard !Task.isCancelled else { return }
                self?.apply(.noticeDismissFired)
            }
        }
        updatePresence(model)
    }

    /// Show/hide/re-layout only as needed — partials stream many times per
    /// second, and each must not re-issue window-server work when the panel
    /// is already up at the right size (review finding).
    private func updatePresence(_ model: HUDModel) {
        let visible = model.phase != .hidden || model.notice != nil
        guard visible else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        let size = panel.contentView?.fittingSize ?? NSSize(width: 320, height: 44)
        if panel.frame.size != size {
            panel.setContentSize(size)
            layoutBottomCenter(size: size)
        }
        if !panel.isVisible {
            layoutBottomCenter(size: size)
            // Never activates the app or takes key status — the target app
            // keeps focus and IME composition (acceptance criterion).
            panel.orderFrontRegardless()
        }
    }

    private func layoutBottomCenter(size: NSSize) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
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
            self.apply(.began(utterance: context.index))
            // Consume the utterance's lifecycle for as long as it lives; the
            // stream finishes with the session, so nothing needs cancelling.
            Task { [weak self] in
                for await state in states {
                    guard let self else { return }
                    await MainActor.run { self.apply(.state(utterance: context.index, state)) }
                }
            }
        }
    }

    nonisolated func utteranceLanded(_ context: UtteranceContext, result: InsertResult) {
        Task { @MainActor in self.apply(.landed(utterance: context.index, result)) }
    }

    nonisolated func utteranceFailed(_ context: UtteranceContext) {
        Task { @MainActor in self.apply(.failed(utterance: context.index)) }
    }
}
