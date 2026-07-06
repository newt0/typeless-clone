import CoreAudio
import Foundation
import KoeCore

/// Enumerates microphone input devices and watches the default-input route for
/// changes (Design §7.4; plan M3-T2).
///
/// This is the CoreAudio bridge behind ``InputDeviceSelector``: it turns the
/// HAL's device list into the pure ``AudioInputDevice`` values the selector
/// reasons about, resolves a device UID back to the `AudioDeviceID` the capture
/// engine needs to pin the input node, and fires `onChange` whenever the default
/// input device or the device set changes (AirPods connect/disconnect, a USB mic
/// unplugged).
///
/// The device list is **cached** and refreshed only when the HAL signals a
/// change (or at ``start()``), so the hotkey-press path reads it in memory
/// rather than paying a burst of synchronous `AudioObjectGetPropertyData`
/// round-trips inside the FR-01 ≤200ms press→recording budget.
///
/// `@unchecked Sendable` is the escape hatch that lets the HAL listener block
/// weak-capture the observer under Swift 6 strict concurrency; it is sound
/// because all mutable state (`onChange`, the cache, `listening`) is only ever
/// touched on the main actor — the block reaches it exclusively inside
/// `MainActor.assumeIsolated`, matching the `FnHotkeyTap` pattern.
final class AudioDeviceObserver: @unchecked Sendable {
    /// Fired on the main actor after the cache is refreshed, when the default
    /// input or the device set changes. The engine reconsiders the route here.
    var onChange: (@MainActor () -> Void)?

    /// Cached input devices and the current system default, refreshed on HAL
    /// change. Read synchronously (no HAL) on the hotkey path.
    private(set) var available: [AudioInputDevice] = []
    private(set) var systemDefault: AudioInputDevice?
    /// UID → live `AudioDeviceID`, cached alongside ``available`` so pinning the
    /// input node doesn't re-enumerate the HAL on the hotkey path.
    private var deviceIDsByUID: [String: AudioDeviceID] = [:]

    private let queue = DispatchQueue(label: "dev.newt.Koe.audio-devices")
    private var listening = false

    // The two system properties whose changes matter: which device is the
    // default input, and the membership of the device list itself.
    private var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private lazy var listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        // HAL callback thread → main actor: refresh the cache, then notify.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self?.refresh()
                self?.onChange?()
            }
        }
    }

    /// Begin watching and warm the cache. Idempotent. Call once, before the
    /// first recording, so ``snapshot()`` is populated on the hotkey path.
    @MainActor
    func start() {
        guard !listening else { return }
        listening = true
        refresh()
        let system = AudioObjectID(kAudioObjectSystemObject)
        AudioObjectAddPropertyListenerBlock(system, &defaultInputAddress, queue, listenerBlock)
        AudioObjectAddPropertyListenerBlock(system, &deviceListAddress, queue, listenerBlock)
    }

    deinit {
        guard listening else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        AudioObjectRemovePropertyListenerBlock(system, &defaultInputAddress, queue, listenerBlock)
        AudioObjectRemovePropertyListenerBlock(system, &deviceListAddress, queue, listenerBlock)
    }

    // MARK: - Snapshot

    /// The cached input devices plus which one is the system default, in the
    /// pure form the selector consumes. No HAL I/O.
    @MainActor
    func snapshot() -> (available: [AudioInputDevice], systemDefault: AudioInputDevice?) {
        (available, systemDefault)
    }

    /// Resolve a device UID to its live `AudioDeviceID` for pinning the capture
    /// engine's input node, from the cache. `nil` if the device has vanished.
    @MainActor
    func audioDeviceID(forUID target: String) -> AudioDeviceID? {
        deviceIDsByUID[target]
    }

    /// Re-enumerate the HAL and rebuild the cache. Main-actor only.
    @MainActor
    func refresh() {
        let ids = allDeviceIDs().filter { hasInputStreams($0) }
        var devices: [AudioInputDevice] = []
        var map: [String: AudioDeviceID] = [:]
        for id in ids {
            guard let device = makeDevice(id) else { continue }
            devices.append(device)
            map[device.id] = id
        }
        // Match the default by its AudioDeviceID against the map we just built —
        // no second UID round-trip for the default device.
        let defaultID = defaultInputDeviceID()
        available = devices
        deviceIDsByUID = map
        systemDefault = defaultID.flatMap { d in devices.first { map[$0.id] == d } }
    }

    // MARK: - HAL reads

    private func allDeviceIDs() -> [AudioDeviceID] {
        var address = deviceListAddress
        var dataSize: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, &ids) == noErr else { return [] }
        return ids
    }

    private func defaultInputDeviceID() -> AudioDeviceID? {
        var address = defaultInputAddress
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &deviceID) == noErr, deviceID != 0 else {
            return nil
        }
        return deviceID
    }

    /// A device is an input device iff it exposes ≥1 input channel.
    private func hasInputStreams(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let bufferList = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, bufferList) == noErr else { return false }
        let abl = UnsafeMutableAudioBufferListPointer(bufferList.assumingMemoryBound(to: AudioBufferList.self))
        return abl.contains { $0.mNumberChannels > 0 }
    }

    private func makeDevice(_ id: AudioDeviceID) -> AudioInputDevice? {
        guard let deviceUID = uid(of: id) else { return nil }
        return AudioInputDevice(
            id: deviceUID,
            name: name(of: id) ?? deviceUID,
            transport: transport(of: id)
        )
    }

    private func uid(of device: AudioDeviceID) -> String? {
        cfStringProperty(device, kAudioDevicePropertyDeviceUID)
    }

    private func name(of device: AudioDeviceID) -> String? {
        cfStringProperty(device, kAudioObjectPropertyName)
    }

    private func transport(of device: AudioDeviceID) -> AudioInputDevice.Transport {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return .other }
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        default: return .other
        }
    }

    private func cfStringProperty(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String?
    }
}
