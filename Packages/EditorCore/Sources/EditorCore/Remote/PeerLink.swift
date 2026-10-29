import CryptoKit
import Foundation
import Network
import Synchronization

/// A paired, encrypted connection to another device running LightEditor.
///
/// Lifecycle: `connect` (client) or `accept` (host) runs the handshake and
/// returns a link waiting for approval, with the six-digit `code` both screens
/// show. Each side calls `approve` after the person taps Allow; `waitForPeer`
/// returns once the other side has approved too. Then requests flow: the client
/// calls `request`, the host answers through its `handler`.
public final class PeerLink: @unchecked Sendable {
    public typealias Handler = @Sendable (RemoteRequest, _ key: String?, _ progress: @escaping @Sendable (Double?, String?) -> Void) async throws -> RemoteResponse

    /// Why a link ended.
    public enum EndReason: Sendable {
        /// This side closed it.
        case local
        /// The other device said goodbye (it disconnected or stopped sharing).
        case peer
        /// The connection was lost, e.g. the other device locked or went to the
        /// background. Worth reconnecting.
        case lost
    }

    public let isHost: Bool
    /// The other device's name, e.g. "Chris's iPad".
    public let peerName: String
    /// Six digits shown on both devices; they must match.
    public let code: String
    /// The other device's identity key, proven during the handshake.
    public let peerIdentity: Data

    private let channel: PeerChannel
    private struct State {
        var nextID: UInt64 = 1
        var pending: [UInt64: CheckedContinuation<RemoteResponse, any Error>] = [:]
        var progress: [UInt64: @Sendable (Double?, String?) -> Void] = [:]
        var handler: Handler?
        var closed = false
        var endReason: EndReason = .lost
        var frozen = false
        var onClose: [@Sendable (EndReason) -> Void] = []
    }
    private let state = Mutex(State())
    private let eventStream: AsyncStream<RemoteEvent>
    private let eventContinuation: AsyncStream<RemoteEvent>.Continuation

    /// Library changes and other pushes from the host.
    public var events: AsyncStream<RemoteEvent> { eventStream }

    private init(channel: PeerChannel, isHost: Bool, peerName: String, peerIdentity: Data, code: String) {
        self.channel = channel
        self.isHost = isHost
        self.peerName = peerName
        self.peerIdentity = peerIdentity
        self.code = code
        (eventStream, eventContinuation) = AsyncStream.makeStream(of: RemoteEvent.self, bufferingPolicy: .bufferingNewest(64))
    }

    // MARK: Handshake

    /// Connects to a host found by `PeerBrowser`.
    public static func connect(to endpoint: NWEndpoint, name: String, identity: PeerIdentity, parameters: NWParameters = PeerService.parameters) async throws -> PeerLink {
        let channel = PeerChannel(NWConnection(to: endpoint, using: parameters))
        try await channel.start()
        return try await handshake(channel, isHost: false, name: name, identity: identity)
    }

    /// Answers a connection that arrived at `PeerListener`.
    public static func accept(_ connection: NWConnection, name: String, identity: PeerIdentity) async throws -> PeerLink {
        let channel = PeerChannel(connection)
        try await channel.start()
        return try await handshake(channel, isHost: true, name: name, identity: identity)
    }

    private static func handshake(_ channel: PeerChannel, isHost: Bool, name: String, identity: PeerIdentity) async throws -> PeerLink {
        do {
            let key = Curve25519.KeyAgreement.PrivateKey()
            let hello = PeerHello(name: name, protocolVersion: RemoteProtocol.version, appVersion: appVersion,
                                  publicKey: key.publicKey.rawRepresentation, identityKey: identity.publicKey)
            try await channel.send(RemoteProtocol.encode(.hello(hello)))
            guard case .hello(let theirs) = try RemoteProtocol.decode(try await channel.receive()) else { throw PeerError.badFrame }
            guard theirs.protocolVersion == RemoteProtocol.version else { throw PeerError.versionMismatch(theirs.appVersion) }
            let keys = try PeerCrypto.keys(privateKey: key, peerPublicKey: theirs.publicKey, isHost: isHost)
            channel.secure(with: keys)

            // Each side signs the whole exchange with its identity key, inside the
            // encrypted channel, so the identities are bound to these session keys.
            func transcript(signerIsHost: Bool) -> Data {
                let (host, client) = isHost ? (hello, theirs) : (theirs, hello)
                return Data("LightEditor proof v2 \(signerIsHost ? "host" : "client")".utf8)
                    + host.publicKey + client.publicKey + host.identityKey + client.identityKey
            }
            try await channel.send(RemoteProtocol.encode(.proof(identity.sign(transcript(signerIsHost: isHost)))))
            guard case .proof(let signature) = try RemoteProtocol.decode(try await channel.receive()),
                  PeerIdentity.verify(signature, of: transcript(signerIsHost: !isHost), by: theirs.identityKey)
            else { throw PeerError.badFrame }
            return PeerLink(channel: channel, isHost: isHost, peerName: theirs.name, peerIdentity: theirs.identityKey, code: keys.code)
        } catch {
            channel.close()
            throw error
        }
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    /// Sends this side's decision. Declining closes the link.
    public func approve(_ allowed: Bool) async throws {
        try await channel.send(RemoteProtocol.encode(.approval(allowed)))
        if !allowed { close() }
    }

    /// Waits for the other side's decision, then starts handling messages.
    public func waitForPeer() async throws {
        let message = try RemoteProtocol.decode(try await channel.receive())
        guard case .approval(let allowed) = message, allowed else {
            close()
            throw PeerError.declined
        }
        channel.onClose { [weak self] in self?.finish(.lost) }
        Task.detached { [self] in await readLoop() }
        Task.detached { [weak self] in await self?.heartbeat() }
    }

    /// How often each side pings, and how long without hearing anything before
    /// the link counts as lost. A suspended iPhone can leave its socket open
    /// while the app is frozen, so silence is the only reliable sign.
    nonisolated(unsafe) static var pingInterval: Duration = .seconds(3)
    nonisolated(unsafe) static var silenceLimit: Duration = .seconds(15)

    private func heartbeat() async {
        while !isClosed {
            try? await Task.sleep(for: Self.pingInterval)
            guard !isClosed, !state.withLock({ $0.frozen }) else { continue }
            if ContinuousClock.now - channel.lastActivity > Self.silenceLimit {
                channel.close()
                finish(.lost)
                return
            }
            try? await channel.send(RemoteProtocol.encode(.ping))
        }
    }

    /// Stops reading and answering, like an app the system froze. For tests.
    func freeze() {
        state.withLock { $0.frozen = true }
    }

    // MARK: Requests

    /// Host side: answers every request.
    public func setHandler(_ handler: @escaping Handler) {
        state.withLock { $0.handler = handler }
    }

    /// Client side: sends a request and waits for the answer.
    public func request(_ request: RemoteRequest, key: String? = nil, progress: (@Sendable (Double?, String?) -> Void)? = nil) async throws -> RemoteResponse {
        let id = state.withLock { state -> UInt64 in
            let id = state.nextID
            state.nextID += 1
            if let progress { state.progress[id] = progress }
            return id
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let closed = state.withLock { state -> Bool in
                    if state.closed { return true }
                    state.pending[id] = continuation
                    return false
                }
                if closed { continuation.resume(throwing: PeerError.closed); return }
                Task {
                    do { try await channel.send(RemoteProtocol.encode(.request(id: id, key: key, request))) }
                    catch { resume(id, with: .failure(error)) }
                }
            }
        } onCancel: {
            resume(id, with: .failure(CancellationError()))
        }
    }

    /// Host side: pushes an event to the client.
    public func send(_ event: RemoteEvent) {
        Task { try? await channel.send(RemoteProtocol.encode(.event(event))) }
    }

    public func onClose(_ handler: @escaping @Sendable (EndReason) -> Void) {
        let alreadyClosed = state.withLock { state -> EndReason? in
            if state.closed { return state.endReason }
            state.onClose.append(handler)
            return nil
        }
        if let alreadyClosed { handler(alreadyClosed) }
    }

    public var isClosed: Bool { state.withLock { $0.closed } }

    /// Ends the link on purpose; the other device won't try to reconnect.
    public func close() {
        Task { [channel] in
            try? await channel.send(RemoteProtocol.encode(.bye))
            channel.close()
        }
        finish(.local)
    }

    /// Drops the connection without a goodbye, as when a device locks. For tests.
    func dropConnection() {
        channel.close()
        finish(.lost)
    }

    private func resume(_ id: UInt64, with result: Result<RemoteResponse, any Error>) {
        let continuation = state.withLock { state in
            state.progress[id] = nil
            return state.pending.removeValue(forKey: id)
        }
        continuation?.resume(with: result)
    }

    private func finish(_ reason: EndReason) {
        let (pending, handlers) = state.withLock { state -> ([CheckedContinuation<RemoteResponse, any Error>], [@Sendable (EndReason) -> Void]) in
            guard !state.closed else { return ([], []) }
            state.closed = true
            state.endReason = reason
            let pending = Array(state.pending.values)
            state.pending.removeAll()
            let handlers = state.onClose
            state.onClose.removeAll()
            return (pending, handlers)
        }
        for continuation in pending { continuation.resume(throwing: PeerError.closed) }
        eventContinuation.finish()
        handlers.forEach { $0(reason) }
    }

    private func readLoop() async {
        while !isClosed {
            if state.withLock({ $0.frozen }) {
                // Frozen (tests): no reads, no pings, until the peer gives up.
                try? await Task.sleep(for: .seconds(3600))
                continue
            }
            let message: WireMessage
            do {
                message = try RemoteProtocol.decode(try await channel.receive())
            } catch {
                break
            }
            switch message {
            case .response(let id, let response):
                resume(id, with: .success(response))
            case .failure(let id, let text):
                resume(id, with: .failure(PeerError.remote(text)))
            case .event(.progress(let id, let fraction, let detail)):
                state.withLock { $0.progress[id] }?(fraction, detail)
            case .event(let event):
                eventContinuation.yield(event)
            case .request(let id, let key, let request):
                handle(id, key, request)
            case .bye:
                channel.close()
                finish(.peer)
                return
            case .hello, .proof, .approval, .ping:
                break
            }
        }
        channel.close()
        finish(.lost)
    }

    private func handle(_ id: UInt64, _ key: String?, _ request: RemoteRequest) {
        guard let handler = state.withLock({ $0.handler }) else {
            Task { try? await channel.send(RemoteProtocol.encode(.failure(id: id, message: "This device isn't sharing its library."))) }
            return
        }
        Task.detached { [channel] in
            let reply: WireMessage
            do {
                let response = try await handler(request, key) { fraction, detail in
                    Task { try? await channel.send(RemoteProtocol.encode(.event(.progress(requestID: id, fraction: fraction, detail: detail)))) }
                }
                reply = .response(id: id, response)
            } catch {
                reply = .failure(id: id, message: error.localizedDescription)
            }
            try? await channel.send(RemoteProtocol.encode(reply))
        }
    }
}
