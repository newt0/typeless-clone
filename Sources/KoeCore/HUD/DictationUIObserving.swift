import Foundation

/// UI observation seam (M9 HUD): the coordinator announces each utterance and
/// its outcome; the observer renders. Callbacks may arrive from pipeline tasks
/// — implementations hop to their own isolation.
///
/// Body text (partials, formatted output) deliberately does NOT cross this
/// seam; the HUD's live partial line is fed by the transcriber's `onPartial`
/// side channel, keeping this protocol reusable for text-free consumers (the
/// status item, M10 metrics).
public protocol DictationUIObserving: Sendable {
    /// A new utterance began. `states` yields its lifecycle transitions in
    /// order (finishes when the utterance's session is discarded).
    func utteranceBegan(_ context: UtteranceContext, states: AsyncStream<DictationState>)
    /// The utterance's insertion resolved.
    func utteranceLanded(_ context: UtteranceContext, result: InsertResult)
    /// The utterance failed at some stage (its transcript, if any, is in
    /// history — invariant 1).
    func utteranceFailed(_ context: UtteranceContext)
}
