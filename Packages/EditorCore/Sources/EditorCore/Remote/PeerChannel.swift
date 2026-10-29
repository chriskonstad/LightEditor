import Foundation
import Network
import Synchronization

/// Bonjour service for remote editing.
public enum PeerService {
    public static let type = "_lighteditor._tcp"

    /// TCP with peer-to-peer Wi-Fi allowed, so two devices connect directly
    /// (AWDL) with no router, cellular or server in between.
    public static var parameters: NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }
}

/// Length-prefixed frames over one `NWConnection`, optionally sealed.
///
/// Frames are a 4-byte big-endian length then the payload. After the handshake
/// every payload is encrypted by `PeerCrypto.Box`.
public final class PeerChannel: @unchecked Sendable {
    public static let maximumFrame = 512 << 20

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "LightEditor.PeerChannel")
    private let box = Mutex<PeerCrypto.Box?>(nil)
    /// Serializes sends so sealed frames go out in counter order.
    private let sendLock = AsyncLock()

    public var endpointDescription: String { "\(connection.endpoint)" }

    public init(_ connection: NWConnection) {
        self.connection = connection
    }

    /// Starts the connection and waits until it's ready.
    public func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resumed = Mutex(false)
            let finish: @Sendable (Result<Void, any Error>) -> Void = { result in
                guard !resumed.withLock({ let was = $0; $0 = true; return was }) else { return }
                continuation.resume(with: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.success(()))
                case .failed(let error): finish(.failure(error))
                case .cancelled: finish(.failure(PeerError.closed))
                case .waiting(let error): finish(.failure(error))
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// Called once when the connection ends after it was ready.
    public func onClose(_ handler: @escaping @Sendable () -> Void) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: handler()
            default: break
            }
        }
    }

    public func secure(with keys: PeerCrypto.Keys) {
        box.withLock { $0 = PeerCrypto.Box(keys: keys) }
    }

    public func close() {
        connection.cancel()
    }

    public func send(_ payload: Data) async throws {
        await sendLock.lock()
        defer { Task { await sendLock.unlock() } }
        let body = try box.withLock { box -> Data in
            guard var sealer = box else { return payload }
            let sealed = try sealer.seal(payload)
            box = sealer
            return sealed
        }
        guard body.count <= Self.maximumFrame else { throw PeerError.badFrame }
        var length = UInt32(body.count).bigEndian
        let frame = Data(bytes: &length, count: 4) + body
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// The next frame. Only one receive runs at a time (the link's read loop).
    public func receive() async throws -> Data {
        let header = try await read(exactly: 4)
        let length = Int(header.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) })
        guard length <= Self.maximumFrame else { throw PeerError.badFrame }
        let body = length == 0 ? Data() : try await read(exactly: length)
        return try box.withLock { box -> Data in
            guard var opener = box else { return body }
            let opened = try opener.open(body)
            box = opener
            return opened
        }
    }

    /// When bytes last arrived, including partway through a big frame, so a
    /// heartbeat doesn't mistake a long transfer for a dead link.
    public var lastActivity: ContinuousClock.Instant { activity.withLock { $0 } }
    private let activity = Mutex(ContinuousClock.now)

    private func read(exactly count: Int) async throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            let chunk = try await readChunk(min(count - data.count, 1 << 20))
            data.append(chunk)
            activity.withLock { $0 = .now }
        }
        return data
    }

    private func readChunk(_ maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, isComplete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if isComplete { continuation.resume(throwing: PeerError.closed) }
                else { continuation.resume(throwing: PeerError.badFrame) }
            }
        }
    }
}

/// A minimal async mutex, so frames are sealed and sent in the same order.
actor AsyncLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if locked {
            await withCheckedContinuation { waiters.append($0) }
        }
        locked = true
    }

    func unlock() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }
}
