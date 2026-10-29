import CoreGraphics
import CryptoKit
import Foundation
import Network
import Synchronization
import Testing
@testable import EditorCore

@Suite struct PeerCryptoTests {
    @Test func bothSidesDeriveTheSameCodeAndKeys() throws {
        let host = Curve25519.KeyAgreement.PrivateKey(), client = Curve25519.KeyAgreement.PrivateKey()
        let hostKeys = try PeerCrypto.keys(privateKey: host, peerPublicKey: client.publicKey.rawRepresentation, isHost: true)
        let clientKeys = try PeerCrypto.keys(privateKey: client, peerPublicKey: host.publicKey.rawRepresentation, isHost: false)
        #expect(hostKeys.code == clientKeys.code)
        #expect(hostKeys.code.count == 7)
        var hostBox = PeerCrypto.Box(keys: hostKeys), clientBox = PeerCrypto.Box(keys: clientKeys)
        for text in ["one", "two", "three"] {
            let sealed = try hostBox.seal(Data(text.utf8))
            #expect(try clientBox.open(sealed) == Data(text.utf8))
        }
        let reply = try clientBox.seal(Data("back".utf8))
        #expect(try hostBox.open(reply) == Data("back".utf8))
    }

    @Test func aDeviceInTheMiddleSeesADifferentCode() throws {
        let host = Curve25519.KeyAgreement.PrivateKey(), client = Curve25519.KeyAgreement.PrivateKey(), attacker = Curve25519.KeyAgreement.PrivateKey()
        let hostSees = try PeerCrypto.keys(privateKey: host, peerPublicKey: attacker.publicKey.rawRepresentation, isHost: true)
        let clientSees = try PeerCrypto.keys(privateKey: client, peerPublicKey: attacker.publicKey.rawRepresentation, isHost: false)
        #expect(hostSees.code != clientSees.code)
    }

    @Test func replayedFramesAreRejected() throws {
        let host = Curve25519.KeyAgreement.PrivateKey(), client = Curve25519.KeyAgreement.PrivateKey()
        var sender = PeerCrypto.Box(keys: try PeerCrypto.keys(privateKey: host, peerPublicKey: client.publicKey.rawRepresentation, isHost: true))
        var receiver = PeerCrypto.Box(keys: try PeerCrypto.keys(privateKey: client, peerPublicKey: host.publicKey.rawRepresentation, isHost: false))
        let first = try sender.seal(Data("a".utf8))
        _ = try receiver.open(first)
        #expect(throws: (any Error).self) { try receiver.open(first) }
    }
}

/// Two links over loopback TCP, as two devices would use over peer-to-peer Wi-Fi.
@Suite(.serialized) struct PeerLinkTests {
    final class Accepted: @unchecked Sendable {
        let link = Mutex<PeerLink?>(nil)
        let error = Mutex<(any Error)?>(nil)
    }

    func pair(hostApproves: Bool = true, hostIdentity: PeerIdentity = .ephemeral(), clientIdentity: PeerIdentity = .ephemeral()) async throws -> (host: PeerLink, client: PeerLink) {
        let accepted = Accepted()
        let ready = Mutex<UInt16?>(nil)
        let listener = try PeerListener(name: "Test Host \(UUID().uuidString.prefix(4))", onConnection: { connection in
            Task {
                do { accepted.link.withLock { $0 = nil }; let link = try await PeerLink.accept(connection, name: "Test iPhone", identity: hostIdentity); accepted.link.withLock { $0 = link } }
                catch { accepted.error.withLock { $0 = error } }
            }
        }, onState: { _ in })
        defer { listener.stop() }
        for _ in 0..<300 where (listener.port ?? 0) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        _ = ready
        let port = try #require(listener.port)
        let client = try await PeerLink.connect(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), name: "Test iPad", identity: clientIdentity, parameters: .tcp)
        var host: PeerLink?
        for _ in 0..<300 {
            host = accepted.link.withLock { $0 }
            if host != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let hostLink = try #require(host)
        #expect(hostLink.code == client.code, "both screens show the same code")
        #expect(hostLink.peerName == "Test iPad" && client.peerName == "Test iPhone")
        #expect(hostLink.peerIdentity == clientIdentity.publicKey && client.peerIdentity == hostIdentity.publicKey, "identities are proven")
        try await hostLink.approve(hostApproves)
        try await client.approve(true)
        if hostApproves {
            async let hostWait: Void = hostLink.waitForPeer()
            try await client.waitForPeer()
            try await hostWait
        }
        return (hostLink, client)
    }

    @Test func requestsRoundTripAfterBothApprove() async throws {
        let (host, client) = try await pair()
        host.setHandler { request, _, progress in
            guard case .thumbnail(let id, let pixels) = request else { return .done(count: 0) }
            progress(0.5, "halfway")
            return .image(Data("\(id)-\(pixels)".utf8) + Data(repeating: 7, count: 3_000_000))
        }
        let progressSeen = Mutex(false)
        let response = try await client.request(.thumbnail(assetID: "abc", pixels: 240)) { fraction, _ in
            if fraction == 0.5 { progressSeen.withLock { $0 = true } }
        }
        guard case .image(let data?) = response else { Issue.record("wrong response"); return }
        #expect(data.prefix(7) == Data("abc-240".utf8))
        #expect(data.count == 3_000_007, "big payloads arrive whole")
        host.send(.libraryChanged)
        var events = client.events.makeAsyncIterator()
        let event = await events.next()
        if case .libraryChanged? = event {} else { Issue.record("no event") }
        client.close()
        for _ in 0..<100 where !host.isClosed { try await Task.sleep(for: .milliseconds(10)) }
        #expect(host.isClosed, "closing one side closes the other")
    }

    @Test func declineEndsTheConnection() async throws {
        let (_, client) = try await pair(hostApproves: false)
        await #expect(throws: PeerError.declined) { try await client.waitForPeer() }
    }

    @Test func hostErrorsReachTheClient() async throws {
        let (host, client) = try await pair()
        host.setHandler { _, _, _ in throw LibraryError.noOriginal }
        await #expect(throws: PeerError.remote(LibraryError.noOriginal.localizedDescription)) {
            try await client.request(.albums)
        }
        client.close()
    }
}

/// The iPad's library and decoder backed by a phone's, over a loopback link.
@Suite(.serialized) struct RemoteLibraryTests {
    @Test func editsPhotosOnTheOtherDevice() async throws {
        let (folder, _) = try makeFolderLibrary(count: 3)
        let (hostLink, clientLink) = try await PeerLinkTests().pair()
        let host = RemoteHost(library: folder, decoder: RawDecoder(cache: DecodeCache(directory: nil)), luts: nil, clock: testClock)
        host.serve(hostLink)
        let remote = RemoteLibrary(link: clientLink)
        RawDecoder.remote.withLock { $0 = remote }
        defer { RawDecoder.remote.withLock { $0 = nil }; clientLink.close() }

        #expect(remote.displayName == "Test iPhone")
        let list = await remote.assets(in: .recents)
        #expect(list.count == 3)
        let asset = list[0]
        let thumbnail = await remote.thumbnail(for: asset, pixelSize: CGSize(width: 64, height: 64))
        #expect(thumbnail != nil)

        let session = try await remote.beginEditing(asset) { _ in }
        #expect(session.original.isRemote)
        // The decode arrives bit for bit as the phone made it.
        let decoder = RawDecoder(cache: DecodeCache(directory: nil))
        let here = try await decoder.decode(session.original, rawStage: RawStageParams(), longEdge: 256)
        let local = try await folder.beginEditing(asset) { _ in }
        let there = try await RawDecoder(cache: DecodeCache(directory: nil)).decode(local.original, rawStage: RawStageParams(), longEdge: 256)
        #expect(here.size == there.size)
        #expect(here.serialized() == there.serialized())
        #expect(try await decoder.info(for: session.original).nativeSize == there.info.nativeSize)

        // Saving renders and stores the edit on the phone.
        var recipe = Recipe()
        recipe.setScalar(.exposure, 0.5, at: testClock.now())
        try await remote.saveEdit(session, recipe: recipe, luts: [], progress: { _, _ in })
        guard case .ours(let saved) = await folder.storedEdit(for: asset) else { Issue.record("not saved on the phone"); return }
        #expect(saved.scalar(.exposure, defaults: .generic) == 0.5)
        guard case .ours = await remote.storedEdit(for: asset) else { Issue.record("not visible remotely"); return }
    }
}

@Suite(.serialized) struct PeerDiscoveryTests {
    /// Advertising and browsing find each other over Bonjour.
    @Test func browserFindsTheListener() async throws {
        let name = "Discovery \(UUID().uuidString.prefix(6))"
        let listener = try PeerListener(name: name, onConnection: { $0.cancel() }, onState: { print("DISCOVERY listener \($0 ?? "ready")") })
        defer { listener.stop() }
        let found = Mutex<[DiscoveredPeer]>([])
        let browser = PeerBrowser(ownName: "someone else") { peers in found.withLock { $0 = peers } }
        defer { browser.stop() }
        for _ in 0..<100 {
            if found.withLock({ $0.contains { $0.name == name } }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("DISCOVERY found \(found.withLock { $0.map(\.name) })")
        #expect(found.withLock { $0.contains { $0.name == name } })
    }
}


/// The phone locks mid-edit: the iPad keeps working and nothing is lost or done twice.
@Suite(.serialized) struct RemoteReconnectTests {
    final class Counter: @unchecked Sendable {
        let saves = Mutex(0)
    }

    /// A library that counts saves and can be slowed down, standing in for Photos.
    final class SlowFolder: PhotoLibrary, @unchecked Sendable {
        let inner: FolderLibrary
        let counter: Counter
        let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
        let hold = Mutex(false)

        init(_ inner: FolderLibrary, counter: Counter) { self.inner = inner; self.counter = counter }
        var displayName: String { "Slow" }
        func authorizationStatus() -> LibraryAuthorization { .authorized }
        func requestAuthorization() async -> LibraryAuthorization { .authorized }
        func albums() async -> [LibraryAlbum] { await inner.albums() }
        func assets(in album: LibraryAlbum) async -> AssetList { await inner.assets(in: album) }
        func thumbnail(for asset: PhotoAsset, pixelSize: CGSize) async -> CGImage? { await inner.thumbnail(for: asset, pixelSize: pixelSize) }
        func quickPreview(for asset: PhotoAsset, maxPixelSize: Int) async -> CGImage? { nil }
        func beginEditing(_ asset: PhotoAsset, progress: @escaping @Sendable (Double) -> Void) async throws -> EditingSession { try await inner.beginEditing(asset, progress: progress) }
        func storedEdit(for asset: PhotoAsset) async -> StoredEdit { await inner.storedEdit(for: asset) }
        func save(_ session: EditingSession, recipe: Recipe, rendered: Data, format: ExportFormat) async throws {
            if hold.withLock({ $0 }) { await withCheckedContinuation { c in gate.withLock { $0 = c } } }
            counter.saves.withLock { $0 += 1 }
            try await inner.save(session, recipe: recipe, rendered: rendered, format: format)
        }
        func saveBatch(_ edits: [PendingEdit]) async throws { try await inner.saveBatch(edits) }
        func revert(_ asset: PhotoAsset) async throws { try await inner.revert(asset) }
        func addPhoto(fileAt url: URL, rawAlternate: URL?) async throws {}
        func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
        func release() { hold.withLock { $0 = false }; gate.withLock { let c = $0; $0 = nil; return c }?.resume() }
    }

    @Test func aSaveSurvivesTheLinkDroppingAndRunsOnce() async throws {
        let (folder, _) = try makeFolderLibrary(count: 2)
        let counter = Counter()
        let slow = SlowFolder(folder, counter: counter)
        let hostID = PeerIdentity.ephemeral(), clientID = PeerIdentity.ephemeral()
        let host = RemoteHost(library: slow, decoder: RawDecoder(cache: DecodeCache(directory: nil)), luts: nil, clock: testClock)
        let (h1, c1) = try await PeerLinkTests().pair(hostIdentity: hostID, clientIdentity: clientID)
        host.serve(h1)
        let outboxDirectory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let remote = RemoteLibrary(link: c1, outboxDirectory: outboxDirectory)
        RawDecoder.remote.withLock { $0 = remote }
        defer { RawDecoder.remote.withLock { $0 = nil }; remote.shutDown() }

        let asset = await remote.assets(in: .recents)[0]
        let session = try await remote.beginEditing(asset) { _ in }
        var recipe = Recipe()
        recipe.setScalar(.exposure, 0.7, at: testClock.now())

        // The phone is slow to save, and locks while saving.
        slow.hold.withLock { $0 = true }
        let saving = Task { try await remote.saveEdit(session, recipe: recipe, luts: [], progress: { _, _ in }) }
        try await Task.sleep(for: .milliseconds(300))
        h1.dropConnection()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!remote.isConnected)
        #expect(remote.outbox.entry(for: asset.id) != nil, "the edit is kept on the iPad")

        // Offline: the open photo still opens, with the pending edit on top.
        let offline = try await remote.beginEditing(asset) { _ in }
        guard case .ours(let pendingRecipe) = offline.stored else { Issue.record("pending edit missing"); return }
        #expect(pendingRecipe.scalar(.exposure, defaults: .generic) == 0.7)

        // The phone unlocks and finishes; the iPad reconnects and its retry joins the same save.
        slow.release()
        let (h2, c2) = try await PeerLinkTests().pair(hostIdentity: hostID, clientIdentity: clientID)
        host.serve(h2)
        remote.attach(c2)
        try await saving.value
        #expect(counter.saves.withLock { $0 } == 1, "saved once, not twice")
        #expect(remote.outbox.isEmpty)
        guard case .ours(let saved) = await folder.storedEdit(for: asset) else { Issue.record("not saved"); return }
        #expect(saved.scalar(.exposure, defaults: .generic) == 0.7)
    }

    @Test func theOutboxSurvivesARestart() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let host = Data(repeating: 3, count: 32)
        var recipe = Recipe()
        recipe.setScalar(.contrast, 12, at: testClock.now())
        let first = RemoteOutbox(host: host, directory: directory)
        let old = first.add(assetID: "a", recipe: Recipe(), luts: [])
        let newer = first.add(assetID: "a", recipe: recipe, luts: [])
        first.remove("a", ifKey: old.key)
        #expect(first.entry(for: "a")?.key == newer.key, "an older save finishing doesn't drop a newer edit")
        let reopened = RemoteOutbox(host: host, directory: directory)
        #expect(reopened.entry(for: "a")?.recipe == recipe)
        #expect(RemoteOutbox(host: Data(repeating: 4, count: 32), directory: directory).isEmpty, "per device")
    }
}

@Suite(.serialized) struct PeerHeartbeatTests {
    /// A frozen phone (its app suspended, socket still open) is noticed by silence.
    @Test func aFrozenPeerCountsAsLost() async throws {
        let (interval, limit) = (PeerLink.pingInterval, PeerLink.silenceLimit)
        PeerLink.pingInterval = .milliseconds(100)
        PeerLink.silenceLimit = .milliseconds(600)
        defer { PeerLink.pingInterval = interval; PeerLink.silenceLimit = limit }
        let (host, client) = try await PeerLinkTests().pair()
        let reason = Mutex<PeerLink.EndReason?>(nil)
        client.onClose { ended in reason.withLock { $0 = ended } }
        try await Task.sleep(for: .milliseconds(400))
        #expect(!client.isClosed, "pings keep a healthy link up")
        host.freeze()
        for _ in 0..<40 where !client.isClosed { try await Task.sleep(for: .milliseconds(50)) }
        #expect(client.isClosed)
        #expect(reason.withLock { $0 } == .lost, "lost, so the iPad reconnects rather than giving up")
    }
}
