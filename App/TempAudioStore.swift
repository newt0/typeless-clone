import Foundation
import KoeCore

/// ``UntranscribedAudioStoring`` on a temp directory (plan M4-T3 P0 scope):
/// WAVs survive for the app run's retry button; a leftover directory from a
/// previous run is cleared at init (the design allows discard-on-restart —
/// the history row is the durable audit trail).
struct TempAudioStore: UntranscribedAudioStoring {
    private let directory: URL

    init(directory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("dev.newt.Koe-untranscribed", isDirectory: true)
    ) {
        self.directory = directory
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func save(wav: Data) async -> String? {
        let id = UUID().uuidString
        do {
            try wav.write(to: url(for: id), options: .atomic)
            Log.event("untranscribed_audio_saved", category: .stt, code: wav.count)
            return id
        } catch {
            Log.error("untranscribed_audio_save_failed", category: .stt)
            return nil
        }
    }

    func load(id: String) async -> Data? {
        try? Data(contentsOf: url(for: id))
    }

    func delete(id: String) async {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    private func url(for id: String) -> URL {
        // The id is our own UUID; the path stays inside the dedicated dir.
        directory.appendingPathComponent(id).appendingPathExtension("wav")
    }
}
