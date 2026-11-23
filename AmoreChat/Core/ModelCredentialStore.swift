import Foundation

/// Production uses Keychain; unit tests inject volatile memory, never plaintext persistence.
@MainActor protocol ModelCredentialStore {
    func read(for id: UUID) -> String?
    func save(_ value: String, for id: UUID) throws
    func remove(for id: UUID)
}
