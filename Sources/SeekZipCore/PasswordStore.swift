import Foundation
#if canImport(Security)
import Security
#endif

/// How archive passwords are stored (M5, TEST-MATRIX ENC-05).
///
/// The engine never passes a password on a command line when it can
/// avoid it (see `SevenZipEngine.resolvePassword`): an explicit
/// password wins, otherwise the store is consulted by archive path.
/// Passwords are never written to the queue file, logs, or the
/// argument vector of any command except the `7zz` call itself —
/// 7-Zip offers no stdin/env password channel (REFERENCE.md §3.2.9),
/// so the `-p` window is kept as short as possible and never logged.
public protocol PasswordStoring: Sendable {
    /// The stored password for the archive at `archivePath`, if any.
    func password(for archivePath: String) -> String?
    /// Stores (or replaces) the password for `archivePath`.
    func save(password: String, for archivePath: String) throws
    /// Removes the stored password for `archivePath`, if any.
    func forget(archivePath: String) throws
}

#if canImport(Security)
/// macOS Keychain storage (service `com.seekzip.passwords`, account =
/// the archive's absolute path). Keychain storage is opt-in: nothing
/// is saved unless the user asks (CLI `password store` / the app's
/// "remember password" toggle). A lookup for an unknown archive
/// returns `nil` without prompting.
public final class KeychainPasswordStore: PasswordStoring {
    private let service = "com.seekzip.passwords"

    public init() {}

    public func password(for archivePath: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: archivePath,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(password: String, for archivePath: String) throws {
        let data = Data(password.utf8)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: archivePath,
            kSecValueData as String: data,
        ]
        var status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: archivePath,
            ]
            status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else {
            throw EngineError.failed(exitCode: 2,
                                     message: "could not save password in Keychain (status \(status))")
        }
    }

    public func forget(archivePath: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: archivePath,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw EngineError.failed(exitCode: 2,
                                     message: "could not forget password in Keychain (status \(status))")
        }
    }
}
#endif

/// In-memory password storage.
///
/// On non-macOS platforms (including the Linux Swift toolchain used
/// for local tests) there is no Keychain, so this is the store:
/// passwords live only for the life of the process and are never
/// persisted anywhere. That is deliberate — a "stored" password that
/// survived in a file on Linux would be worse than no storage at all.
/// On macOS this class is only used by tests; production uses
/// `KeychainPasswordStore`.
/// Access is guarded by `lock`, so the unchecked conformance is sound.
public final class InMemoryPasswordStore: PasswordStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var passwords: [String: String] = [:]

    public init() {}

    public func password(for archivePath: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return passwords[archivePath]
    }

    public func save(password: String, for archivePath: String) throws {
        lock.lock(); defer { lock.unlock() }
        passwords[archivePath] = password
    }

    public func forget(archivePath: String) throws {
        lock.lock(); defer { lock.unlock() }
        passwords[archivePath] = nil
    }
}

/// The store the engine consults by default: Keychain on macOS,
/// in-memory elsewhere (see above).
public enum PasswordStore {
    #if canImport(Security)
    public static let shared: PasswordStoring = KeychainPasswordStore()
    #else
    public static let shared: PasswordStoring = InMemoryPasswordStore()
    #endif
}
