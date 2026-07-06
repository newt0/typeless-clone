import Testing
@testable import KoeCore

@Suite("InputDeviceSelector")
struct InputDeviceSelectorTests {
    // Fixtures.
    let builtIn = AudioInputDevice(id: "builtin-uid", name: "MacBook Pro Microphone", transport: .builtIn)
    let airpods = AudioInputDevice(id: "airpods-uid", name: "AirPods Pro", transport: .bluetooth)
    let usbMic = AudioInputDevice(id: "usb-uid", name: "USB Podcast Mic", transport: .usb)

    // MARK: select

    @Test("prefer built-in keeps the built-in mic even when a headset is the system default")
    func preferBuiltInAvoidsBluetoothDefault() {
        // AirPods just connected and became the system default (HFP, poor STT).
        let chosen = InputDeviceSelector.select(
            from: [airpods, builtIn],
            systemDefault: airpods,
            preferBuiltIn: true
        )
        #expect(chosen == builtIn)
    }

    @Test("prefer built-in reuses the default when it is already the built-in device")
    func preferBuiltInReusesBuiltInDefault() {
        let chosen = InputDeviceSelector.select(
            from: [builtIn, usbMic],
            systemDefault: builtIn,
            preferBuiltIn: true
        )
        #expect(chosen == builtIn)
    }

    @Test("prefer built-in falls back to the default when no built-in device exists")
    func preferBuiltInFallsBackWhenNoBuiltIn() {
        // A Mac mini with only external mics: honour the default rather than nil.
        let chosen = InputDeviceSelector.select(
            from: [airpods, usbMic],
            systemDefault: airpods,
            preferBuiltIn: true
        )
        #expect(chosen == airpods)
    }

    @Test("prefer built-in off follows the system default")
    func followsSystemDefaultWhenPreferenceOff() {
        let chosen = InputDeviceSelector.select(
            from: [builtIn, airpods],
            systemDefault: airpods,
            preferBuiltIn: false
        )
        #expect(chosen == airpods)
    }

    @Test("falls back to any available device when there is no system default")
    func fallsBackToFirstAvailable() {
        #expect(InputDeviceSelector.select(from: [usbMic], systemDefault: nil, preferBuiltIn: false) == usbMic)
        #expect(InputDeviceSelector.select(from: [usbMic], systemDefault: nil, preferBuiltIn: true) == usbMic)
    }

    @Test("no input devices at all yields nil")
    func noDevicesYieldsNil() {
        #expect(InputDeviceSelector.select(from: [], systemDefault: nil, preferBuiltIn: true) == nil)
    }

    // MARK: resolveSwitch

    @Test("AirPods drop mid-recording switches to the built-in mic (prefer built-in)")
    func airpodsDropoutSwitchesToBuiltIn() {
        // Was recording on AirPods; they disconnect, default reverts to built-in.
        let decision = InputDeviceSelector.resolveSwitch(
            current: airpods,
            available: [builtIn],
            systemDefault: builtIn,
            preferBuiltIn: true
        )
        #expect(decision == .switchTo(builtIn))
    }

    @Test("AirPods drop mid-recording switches to the built-in mic (prefer built-in off)")
    func airpodsDropoutSwitchesWithPreferenceOff() {
        let decision = InputDeviceSelector.resolveSwitch(
            current: airpods,
            available: [builtIn],
            systemDefault: builtIn,
            preferBuiltIn: false
        )
        #expect(decision == .switchTo(builtIn))
    }

    @Test("a headset connecting mid-recording does not steal capture from the built-in mic")
    func headsetConnectDoesNotStealFromBuiltIn() {
        // Recording on built-in; AirPods connect and become the default. With
        // prefer-built-in on we stay put — no switch to HFP mid-utterance.
        let decision = InputDeviceSelector.resolveSwitch(
            current: builtIn,
            available: [builtIn, airpods],
            systemDefault: airpods,
            preferBuiltIn: true
        )
        #expect(decision == .keepCurrent)
    }

    @Test("no change in the selected device keeps the current session")
    func noChangeKeepsCurrent() {
        let decision = InputDeviceSelector.resolveSwitch(
            current: builtIn,
            available: [builtIn, usbMic],
            systemDefault: builtIn,
            preferBuiltIn: true
        )
        #expect(decision == .keepCurrent)
    }

    @Test("a transient empty enumeration keeps the current tap alive rather than tearing down")
    func emptyEnumerationKeepsCurrent() {
        let decision = InputDeviceSelector.resolveSwitch(
            current: builtIn,
            available: [],
            systemDefault: nil,
            preferBuiltIn: true
        )
        #expect(decision == .keepCurrent)
    }
}
