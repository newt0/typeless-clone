import Testing
@testable import KoeCore

/// Contract tests via the in-memory store. The `KeychainSecretStore` is a thin
/// Security-API adapter over the same contract and is verified at runtime on the
/// dev machine (the login keychain is not reliably available on CI runners).
@Suite("SecretStore contract")
struct SecretStoreTests {

    @Test("read returns nil for an absent key")
    func absentKey() {
        let store = InMemorySecretStore()
        #expect(store.read(.geminiAPIKey) == nil)
    }

    @Test("write then read round-trips")
    func roundTrip() {
        let store = InMemorySecretStore()
        #expect(store.write("sk-123", for: .speechmaticsAPIKey))
        #expect(store.read(.speechmaticsAPIKey) == "sk-123")
    }

    @Test("write overwrites the previous value")
    func overwrite() {
        let store = InMemorySecretStore()
        store.write("old", for: .deepgramAPIKey)
        store.write("new", for: .deepgramAPIKey)
        #expect(store.read(.deepgramAPIKey) == "new")
    }

    @Test("keys are isolated from one another")
    func isolation() {
        let store = InMemorySecretStore()
        store.write("a", for: .awsAccessKeyID)
        store.write("b", for: .awsSecretAccessKey)
        #expect(store.read(.awsAccessKeyID) == "a")
        #expect(store.read(.awsSecretAccessKey) == "b")
    }

    @Test("delete removes the value")
    func delete() {
        let store = InMemorySecretStore()
        store.write("x", for: .sonioxAPIKey)
        #expect(store.delete(.sonioxAPIKey))
        #expect(store.read(.sonioxAPIKey) == nil)
    }
}
