import Foundation
import KoeCore

/// ``BatchTranscribing`` backed by the Speechmatics Batch (Jobs) REST API
/// (plan M4-T3; https://docs.speechmatics.com/api-ref/batch/): submit the WAV
/// as a job, poll until `done`, fetch the plain-text transcript. The caller
/// (``ResilientTranscriber``) bounds the whole call with `Deadline`, so the
/// poll loop here can be simple and unbounded.
///
/// Invariant 8: like the RT adapter, no smart-formatting/ITN options are sent
/// — only language, operating point, and the vocabulary boost.
public struct SpeechmaticsBatchClient: BatchTranscribing {
    /// (request) → (body, response). Injectable for tests; the default is a
    /// plain URLSession call.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let apiKey: String
    private let jobsEndpoint: URL
    private let language: String
    private let operatingPoint: String
    private let pollInterval: Duration
    private let transport: Transport

    public init(
        apiKey: String,
        jobsEndpoint: URL = URL(string: "https://eu1.asr.api.speechmatics.com/v2/jobs")!,
        language: String = "ja",
        operatingPoint: String = "enhanced",
        pollInterval: Duration = KoeConstants.sttBatchPollInterval,
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }
    ) {
        self.apiKey = apiKey
        self.jobsEndpoint = jobsEndpoint
        self.language = language
        self.operatingPoint = operatingPoint
        self.pollInterval = pollInterval
        self.transport = transport
    }

    public func transcribe(wav: Data, vocab: [STTVocabTerm]) async throws -> String {
        let jobID = try await submit(wav: wav, vocab: vocab)
        while true {
            try await Task.sleep(for: pollInterval)
            switch try await status(of: jobID) {
            case "done":
                return try await transcript(of: jobID)
            case "running", "":
                continue
            case let terminal: // rejected / deleted / expired
                Log.error("stt_batch_job_terminal", category: .stt)
                throw STTError.server(type: terminal)
            }
        }
    }

    // MARK: - Requests

    private func submit(wav: Data, vocab: [STTVocabTerm]) async throws -> String {
        var config: [String: Any] = [
            "language": language,
            "operating_point": operatingPoint,
        ]
        if !vocab.isEmpty {
            // Same wire shape and cap as the RT adapter's additional_vocab.
            config["additional_vocab"] = vocab.prefix(1000).map { term -> [String: Any] in
                var entry: [String: Any] = ["content": term.content]
                if !term.soundsLike.isEmpty { entry["sounds_like"] = term.soundsLike }
                return entry
            }
        }
        let jobConfig: [String: Any] = ["type": "transcription", "transcription_config": config]
        let configJSON = try JSONSerialization.data(withJSONObject: jobConfig)

        let boundary = "koe-\(UUID().uuidString)"
        var body = Data()
        func appendField(_ string: String) { body.append(Data(string.utf8)) }
        appendField("--\(boundary)\r\n")
        appendField("Content-Disposition: form-data; name=\"config\"\r\n\r\n")
        body.append(configJSON)
        appendField("\r\n--\(boundary)\r\n")
        appendField("Content-Disposition: form-data; name=\"data_file\"; filename=\"utterance.wav\"\r\n")
        appendField("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        appendField("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: jobsEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let data = try await send(request)
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = object["id"] as? String
        else { throw STTError.malformedResponse }
        Log.event("stt_batch_job_submitted", category: .stt)
        return id
    }

    private func status(of jobID: String) async throws -> String {
        var request = URLRequest(url: jobsEndpoint.appendingPathComponent(jobID))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let data = try await send(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw STTError.malformedResponse
        }
        let job = object["job"] as? [String: Any] ?? object
        return job["status"] as? String ?? ""
    }

    private func transcript(of jobID: String) async throws -> String {
        var components = URLComponents(
            url: jobsEndpoint.appendingPathComponent(jobID).appendingPathComponent("transcript"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "format", value: "txt")]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let data = try await send(request)
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await transport(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw STTError.connection
        }
        guard let http = response as? HTTPURLResponse else { throw STTError.connection }
        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw STTError.auth
        default:
            Log.error("stt_batch_http_error", category: .stt, code: http.statusCode)
            throw STTError.server(type: "http_\(http.statusCode)")
        }
    }
}
