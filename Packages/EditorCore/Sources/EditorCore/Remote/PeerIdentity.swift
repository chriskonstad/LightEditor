import CryptoKit
import Foundation
import Security
import Synchronization

/// This device's long-term identity for remote editing, and the devices it trusts.
///
/// The first connection is approved by comparing codes on both screens. Both
/// devices then remember each other's identity key, so later connections, e.g.
/// after the iPhone locks and unlocks, are verified by signature and resume
/// without asking again. "Forget" removes the trust.
public final class PeerIdentity: @unchecked Sendable {
    public struct Trusted: Codable, Sendable, Hashable, Identifiable {
        public var key: Data
        public var name: String
        public var id: Data { key }
    }

    private let signingKey: Curve25519.Signing.PrivateKey
    private let trustFile: URL?
    private let trusted: Mutex<[Trusted]>

    /// The public half, sent in each handshake.
    public var publicKey: Data { signingKey.publicKey.rawRepresentation }

    public init(signingKey: Curve25519.Signing.PrivateKey, trustFile: URL?) {
        self.signingKey = signingKey
        self.trustFile = trustFile
        let saved = trustFile.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([Trusted].self, from: $0) } ?? []
        trusted = Mutex(saved)
    }

    /// This device's identity, kept in the Keychain (this device only, never synced).
    public static let shared: PeerIdentity = {
        let directory = URL.applicationSupportDirectory.appending(path: "Remote", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return PeerIdentity(signingKey: Keychain.signingKey(), trustFile: directory.appending(path: "trusted.json"))
    }()

    /// A throwaway identity for tests.
    public static func ephemeral() -> PeerIdentity {
        PeerIdentity(signingKey: Curve25519.Signing.PrivateKey(), trustFile: nil)
    }

    func sign(_ data: Data) throws -> Data {
        try signingKey.signature(for: data)
    }

    static func verify(_ signature: Data, of data: Data, by key: Data) -> Bool {
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { return false }
        return publicKey.isValidSignature(signature, for: data)
    }

    // MARK: Trust

    public var trustedDevices: [Trusted] { trusted.withLock { $0 } }

    public func trusts(_ key: Data) -> Bool { trusted.withLock { $0.contains { $0.key == key } } }

    public func trust(_ key: Data, name: String) {
        trusted.withLock { list in
            list.removeAll { $0.key == key }
            list.append(Trusted(key: key, name: name))
        }
        persist()
    }

    public func forget(_ key: Data) {
        trusted.withLock { $0.removeAll { $0.key == key } }
        persist()
    }

    private func persist() {
        guard let trustFile, let data = try? JSONEncoder().encode(trusted.withLock({ $0 })) else { return }
        try? data.write(to: trustFile, options: [.atomic, .completeFileProtection])
    }
}

/// The identity key in the Keychain.
enum Keychain {
    static let account = "remote-identity"
    static let service = "com.chriskonstad.lighteditor.remote"

    static func signingKey() -> Curve25519.Signing.PrivateKey {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        let add: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecValueData: key.rawRepresentation,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemDelete(add as CFDictionary)
        SecItemAdd(add as CFDictionary, nil)
        return key
    }
}
