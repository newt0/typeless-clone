import AudioToolbox
import AVFoundation
import KoeCore

/// Owns the microphone `AVAudioEngine` and converts its input to the STT wire
/// format (Design §7.4; plan M3-T1/M3-T2).
///
/// The engine is built and `prepare()`d once at construction and kept
/// stopped-but-ready, so a hotkey press only pays ``start()`` (FR-01:
/// press→recording ≤200ms, ~50ms in practice). ``start()`` selects an input
/// device (``InputDeviceSelector`` — prefer built-in to dodge Bluetooth HFP),
/// pins it, installs an input tap, converts each buffer to 16kHz mono PCM16 via
/// `AVAudioConverter`, appends it to a ``SessionAudioBuffer`` for STT
/// batch-resend (M4-T3), and yields it as `Data` on an `AsyncStream` sized to
/// ~40ms chunks. No client-side NR/AGC — raw audio only (invariant 8).
///
/// Device-switch survival (M3-T2): while recording, the engine watches the
/// default-input route (``AudioDeviceObserver``) and the AVAudioEngine
/// configuration. When the recorded device disappears (AirPods drop) it re-pins
/// the best remaining device and reinstalls the tap **on the same session** —
/// the ``SessionAudioBuffer`` and chunk stream survive, so the transcript covers
/// audio from before and after the switch (invariant 1). The caller is notified
/// so the HUD (M9) can flash the switch.
///
/// The recording window runs under `ProcessInfo.beginActivity(.userInitiated)`
/// so App Nap can't stall capture→insertion.
///
/// Concurrency: the tap block fires on CoreAudio's realtime thread, which
/// serializes callbacks; the non-Sendable AVFoundation objects live in
/// ``TapState`` and are only touched there. ``start()``/``stop()`` and the
/// route-change handler run on the main actor and only mutate the tap while the
/// engine is stopped, so they never race the tap thread.
@MainActor
final class AudioCaptureEngine {
    /// Converted audio chunks (16kHz mono PCM16 LE), ~40ms each. The M4 STT
    /// client is the real consumer; until then AppDelegate drains it.
    typealias ChunkStream = AsyncStream<Data>

    private let engine = AVAudioEngine()
    private let format: AudioFormatSpec
    private let deviceObserver = AudioDeviceObserver()
    /// Read fresh on each start (and each switch) so a Settings toggle takes
    /// effect on the next dictation without reconstructing the engine.
    private let preferBuiltIn: () -> Bool

    private var activity: NSObjectProtocol?
    private var continuation: ChunkStream.Continuation?
    private var tapState: TapState?
    /// The device capture is currently pinned to; drives the switch decision.
    private var currentDevice: AudioInputDevice?
    private var configChangeObserver: NSObjectProtocol?
    private var isRecording = false

    /// Fired on the main actor when the 20-minute session cap stops recording;
    /// the caller shows the HUD notice.
    private let onCapReached: () -> Void
    /// Fired on the main actor after a mid-session device switch, with the
    /// device now in use; the caller flashes the HUD switch notice (M9).
    private let onDeviceSwitched: (AudioInputDevice) -> Void

    init(
        format: AudioFormatSpec = .stt,
        preferBuiltIn: @escaping () -> Bool = { true },
        onCapReached: @escaping () -> Void = {},
        onDeviceSwitched: @escaping (AudioInputDevice) -> Void = { _ in }
    ) {
        self.format = format
        self.preferBuiltIn = preferBuiltIn
        self.onCapReached = onCapReached
        self.onDeviceSwitched = onDeviceSwitched
        engine.prepare()
    }

    /// Begin capture and return the live chunk stream, or `nil` when capture did
    /// not start. Called on Fn/alt hotkey down.
    ///
    /// Returns `nil` in two cases the caller must treat identically — do not
    /// show the recording state and do not touch the drain task:
    /// - **already recording**: a second start (e.g. the other hotkey fires
    ///   while one is held) is ignored so the live tap/stream keep running
    ///   uninterrupted rather than being orphaned;
    /// - **failure to start**: bad input format, converter init failure, or
    ///   `engine.start()` throwing (e.g. mic TCC not yet granted). The icon must
    ///   not claim "recording" while zero audio is captured (invariant 1).
    func start() -> ChunkStream? {
        guard !isRecording else {
            Log.error("audio_start_while_recording", category: .audio)
            return nil
        }

        // Pick and pin the input device before reading the input format — pinning
        // changes which hardware the input node reflects.
        let snapshot = deviceObserver.snapshot()
        let selected = InputDeviceSelector.select(
            from: snapshot.available,
            systemDefault: snapshot.systemDefault,
            preferBuiltIn: preferBuiltIn()
        )
        pin(selected)

        let inputFormat = engine.inputNode.inputFormat(forBus: 0)
        guard
            inputFormat.channelCount > 0,
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: format.sampleRate,
                channels: AVAudioChannelCount(format.channelCount),
                interleaved: true
            ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            Log.error("audio_converter_init_failed", category: .audio)
            return nil
        }

        // Protect capture→insertion from App Nap for the whole recording window.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated], reason: "Koe dictation"
        )

        let (stream, continuation) = ChunkStream.makeStream()
        self.continuation = continuation

        let state = TapState(
            converter: converter,
            outputFormat: outputFormat,
            buffer: SessionAudioBuffer(format: format),
            onChunk: { continuation.yield($0) },
            onCap: { [weak self] in
                // Hop to the main actor to tear the engine down safely.
                Task { @MainActor in self?.handleCapReached() }
            }
        )
        self.tapState = state

        installTap(inputFormat: inputFormat, state: state)

        do {
            try engine.start()
        } catch {
            Log.error("audio_engine_start_failed", category: .audio)
            engine.inputNode.removeTap(onBus: 0)
            self.tapState = nil
            continuation.finish()
            self.continuation = nil
            endActivity()
            return nil
        }

        isRecording = true
        currentDevice = selected
        startWatchingRoute()
        Log.event("audio_recording_started", category: .audio)
        return stream
    }

    /// Stop capture on hotkey up. Idempotent.
    func stop() {
        guard isRecording else { return }
        teardown()
        Log.event("audio_recording_stopped", category: .audio)
    }

    /// Cap hit: stop recording, then notify so the HUD can explain the limit.
    private func handleCapReached() {
        guard isRecording else { return }
        teardown()
        Log.event("audio_session_cap_reached", category: .audio)
        onCapReached()
    }

    // MARK: - Device-switch survival (M3-T2)

    /// Start reacting to default-input and engine-configuration changes for the
    /// duration of this recording.
    private func startWatchingRoute() {
        deviceObserver.onChange = { [weak self] in self?.handleRouteChange() }
        deviceObserver.start()
        // AVAudioEngine posts this when the hardware format changes out from under
        // it (e.g. the pinned device vanished); reconcile the same way.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleRouteChange() }
        }
    }

    /// The default-input route or device set changed. Re-select and, if a
    /// different device wins, rebind capture to it without dropping the session.
    private func handleRouteChange() {
        guard isRecording, let state = tapState else { return }
        let snapshot = deviceObserver.snapshot()
        let decision = InputDeviceSelector.resolveSwitch(
            current: currentDevice,
            available: snapshot.available,
            systemDefault: snapshot.systemDefault,
            preferBuiltIn: preferBuiltIn()
        )
        guard case let .switchTo(target) = decision else { return }

        // Reconfigure while the engine is stopped so we never mutate the tap
        // under a live realtime callback. Buffer + continuation live in `state`
        // and survive — the transcript spans both devices.
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        pin(target)

        let inputFormat = engine.inputNode.inputFormat(forBus: 0)
        guard
            inputFormat.channelCount > 0,
            let converter = AVAudioConverter(from: inputFormat, to: state.outputFormat)
        else {
            Log.error("audio_device_switch_converter_failed", category: .audio)
            teardown()
            onCapReached() // reuse the "recording ended unexpectedly" icon reset
            return
        }
        state.rebind(converter: converter)
        installTap(inputFormat: inputFormat, state: state)

        do {
            try engine.start()
        } catch {
            Log.error("audio_device_switch_restart_failed", category: .audio)
            teardown()
            onCapReached()
            return
        }

        currentDevice = target
        Log.event("audio_device_switched", category: .audio)
        onDeviceSwitched(target)
    }

    /// Pin the input node's HAL device so macOS does not silently follow the
    /// system default away from our selection (e.g. onto a freshly-connected
    /// Bluetooth headset). No-op if the device vanished before we could pin.
    private func pin(_ device: AudioInputDevice?) {
        guard
            let device,
            let deviceID = deviceObserver.audioDeviceID(forUID: device.id),
            let unit = engine.inputNode.audioUnit
        else { return }
        var id = deviceID
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            Log.error("audio_device_pin_failed", category: .audio, code: Int(status))
        }
    }

    // MARK: - Tap plumbing

    private func installTap(inputFormat: AVAudioFormat, state: TapState) {
        // Size the tap to ~40ms of input frames so converted chunks land in the
        // STT 20–50ms window. CoreAudio may not honour it exactly — a hint.
        let tapFrames = AVAudioFrameCount(
            format.frameCount(for: KoeConstants.audioChunkDuration, atSampleRate: inputFormat.sampleRate)
        )
        engine.inputNode.installTap(onBus: 0, bufferSize: tapFrames, format: inputFormat) { buffer, _ in
            state.process(buffer)
        }
    }

    private func teardown() {
        isRecording = false
        currentDevice = nil
        stopWatchingRoute()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        tapState = nil
        continuation?.finish()
        continuation = nil
        endActivity()
    }

    private func stopWatchingRoute() {
        deviceObserver.onChange = nil
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }
    }

    private func endActivity() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}

/// Holds the non-Sendable AVFoundation conversion state. Every method runs on
/// CoreAudio's realtime tap thread (which serializes callbacks), so the
/// `@unchecked Sendable` escape hatch is sound — the object is never touched
/// from two threads at once. The one exception is ``rebind(converter:)``, called
/// from the main actor only while the engine (and thus the tap) is stopped.
private final class TapState: @unchecked Sendable {
    private var converter: AVAudioConverter
    let outputFormat: AVAudioFormat
    private var buffer: SessionAudioBuffer
    private let onChunk: @Sendable (Data) -> Void
    private let onCap: @Sendable () -> Void

    private let clock = ContinuousClock()
    private let started: ContinuousClock.Instant
    private var firstChunkLogged = false
    private var capped = false

    init(
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat,
        buffer: SessionAudioBuffer,
        onChunk: @escaping @Sendable (Data) -> Void,
        onCap: @escaping @Sendable () -> Void
    ) {
        self.converter = converter
        self.outputFormat = outputFormat
        self.buffer = buffer
        self.onChunk = onChunk
        self.onCap = onCap
        self.started = clock.now
    }

    /// Swap in a converter for a new input device, keeping the accumulated
    /// ``buffer`` and the output format. Safe because the caller has stopped the
    /// engine, so no tap callback is in flight.
    func rebind(converter: AVAudioConverter) {
        self.converter = converter
    }

    func process(_ input: AVAudioPCMBuffer) {
        guard !capped, input.frameLength > 0 else { return }

        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { _, inStatus in
            if supplied {
                inStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inStatus.pointee = .haveData
            return input
        }

        guard status != .error, out.frameLength > 0, let channel = out.int16ChannelData else { return }
        let byteCount = Int(out.frameLength) * MemoryLayout<Int16>.size * Int(outputFormat.channelCount)
        let data = Data(bytes: channel[0], count: byteCount)

        if !firstChunkLogged {
            firstChunkLogged = true
            Log.event("audio_first_buffer_ms", category: .audio, code: elapsedMilliseconds())
        }

        onChunk(data)

        if buffer.append(data) == .capReached {
            capped = true
            onCap()
        }
    }

    /// Press→first-buffer latency in whole milliseconds (FR-01 acceptance; ≤200ms).
    private func elapsedMilliseconds() -> Int {
        let c = (clock.now - started).components
        return Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000)
    }
}
