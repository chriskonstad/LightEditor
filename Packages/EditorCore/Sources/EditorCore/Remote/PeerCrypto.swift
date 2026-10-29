import CryptoKit
import Foundation

/// Pairing and encryption for remote editing.
///
/// Each side makes a fresh Curve25519 key per connection and they agree on a
/// shared secret. Both screens then show the same six-digit code, derived from
/// that secret and both public keys, and the person approves on both devices
/// after checking the codes match. That's Bluetooth-style numeric comparison: a
/// device in the middle would see different codes. Every message after the
/// handshake is sealed with ChaCha20-Poly1305, with a counter nonce per
/// direction so nothing can be replayed or reordered.
public enum PeerCrypto {
    public struct Keys: Sendable {
        let send: SymmetricKey
        let receive: SymmetricKey
        /// Six digits, e.g. "482 913", the same on both devices.
        public let code: String
    }

    /// Derives this side's keys. `isHost` picks the direction labels, so the
    /// host's send key is the client's receive key.
    public static func keys(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: Data,
        isHost: Bool
    ) throws -> Keys {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let mine = privateKey.publicKey.rawRepresentation
        // Both sides build the same salt: host's key, then client's.
        let salt = isHost ? mine + peerPublicKey : peerPublicKey + mine
        func derive(_ label: String) -> SymmetricKey {
            shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data("LightEditor remote v1 \(label)".utf8), outputByteCount: 32)
        }
        let hostToClient = derive("host to client"), clientToHost = derive("client to host")
        let codeBytes = derive("code").withUnsafeBytes { Array($0.prefix(4)) }
        let number = codeBytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        let digits = String(format: "%06u", number)
        return Keys(
            send: isHost ? hostToClient : clientToHost,
            receive: isHost ? clientToHost : hostToClient,
            code: "\(digits.prefix(3)) \(digits.suffix(3))"
        )
    }

    /// Seals and opens frames in order, one counter per direction.
    public struct Box: Sendable {
        let keys: Keys
        var sent: UInt64 = 0
        var received: UInt64 = 0

        public init(keys: Keys) { self.keys = keys }

        static func nonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
            var bytes = [UInt8](repeating: 0, count: 12)
            withUnsafeBytes(of: counter.bigEndian) { bytes.replaceSubrange(4..<12, with: $0) }
            return try ChaChaPoly.Nonce(data: bytes)
        }

        public mutating func seal(_ plaintext: Data) throws -> Data {
            let box = try ChaChaPoly.seal(plaintext, using: keys.send, nonce: Self.nonce(sent))
            sent += 1
            // The nonce is implied by the counter, so only ciphertext and tag go out.
            return box.ciphertext + box.tag
        }

        public mutating func open(_ sealed: Data) throws -> Data {
            guard sealed.count >= 16 else { throw PeerError.badFrame }
            let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(received), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
            let plaintext = try ChaChaPoly.open(box, using: keys.receive)
            received += 1
            return plaintext
        }
    }
}

public enum PeerError: Error, LocalizedError, Equatable {
    case badFrame
    case closed
    case declined
    case versionMismatch(String)
    case remote(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .badFrame: "The other device sent something unexpected."
        case .closed: "The connection closed."
        case .declined: "The connection wasn't approved."
        case .versionMismatch(let other): "The other device runs a different version of LightEditor (\(other)). Update both."
        case .remote(let message): message
        case .timedOut: "The other device didn't answer."
        }
    }
}
