import Testing
@testable import KoeCore

@Suite("HotkeyEngine — hold mode")
struct HotkeyEngineHoldTests {
    @Test("down starts, up stops")
    func pressHoldRelease() {
        var engine = HotkeyEngine(mode: .hold)
        #expect(engine.handle(.down) == .start)
        #expect(engine.isActive)
        #expect(engine.handle(.up) == .stop)
        #expect(!engine.isActive)
    }

    @Test("repeated down while active is a no-op (key-repeat safe)")
    func duplicateDownIgnored() {
        var engine = HotkeyEngine(mode: .hold)
        #expect(engine.handle(.down) == .start)
        #expect(engine.handle(.down) == .none)
        #expect(engine.isActive)
    }

    @Test("up while already stopped is a no-op")
    func spuriousUpIgnored() {
        var engine = HotkeyEngine(mode: .hold)
        #expect(engine.handle(.up) == .none)
        #expect(!engine.isActive)
    }

    @Test("multiple hold cycles each produce start/stop")
    func repeatedCycles() {
        var engine = HotkeyEngine(mode: .hold)
        for _ in 0..<3 {
            #expect(engine.handle(.down) == .start)
            #expect(engine.handle(.up) == .stop)
        }
    }
}

@Suite("HotkeyEngine — toggle mode")
struct HotkeyEngineToggleTests {
    @Test("each down flips; up is inert")
    func tapToggles() {
        var engine = HotkeyEngine(mode: .toggle)
        #expect(engine.handle(.down) == .start)
        #expect(engine.handle(.up) == .none)   // release does not stop in toggle
        #expect(engine.isActive)
        #expect(engine.handle(.down) == .stop)
        #expect(engine.handle(.up) == .none)
        #expect(!engine.isActive)
    }
}

@Suite("HotkeyEngine — reset")
struct HotkeyEngineResetTests {
    @Test("reset while active emits stop")
    func resetActive() {
        var engine = HotkeyEngine(mode: .hold)
        _ = engine.handle(.down)
        #expect(engine.reset() == .stop)
        #expect(!engine.isActive)
    }

    @Test("reset while stopped is a no-op")
    func resetIdle() {
        var engine = HotkeyEngine(mode: .toggle)
        #expect(engine.reset() == .none)
    }
}

@Suite("FnKey decoding")
struct FnKeyTests {
    @Test("Fn keycode with flag set decodes to down")
    func fnDown() {
        #expect(FnKey.transition(keyCode: FnKey.keyCode, secondaryFnActive: true) == .down)
    }

    @Test("Fn keycode with flag cleared decodes to up")
    func fnUp() {
        #expect(FnKey.transition(keyCode: FnKey.keyCode, secondaryFnActive: false) == .up)
    }

    @Test("non-Fn keycode returns nil (passes through)")
    func otherKeyIgnored() {
        #expect(FnKey.transition(keyCode: 0, secondaryFnActive: true) == nil)
        #expect(FnKey.transition(keyCode: 55, secondaryFnActive: false) == nil) // Cmd
    }

    @Test("end-to-end: decoded Fn transitions drive the engine")
    func decodeThenDrive() {
        var engine = HotkeyEngine(mode: .hold)
        let down = FnKey.transition(keyCode: 63, secondaryFnActive: true)
        let up = FnKey.transition(keyCode: 63, secondaryFnActive: false)
        #expect(down.map { engine.handle($0) } == .start)
        #expect(up.map { engine.handle($0) } == .stop)
    }
}
