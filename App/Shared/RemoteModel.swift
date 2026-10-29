import EditorCore
import Foundation
import Network
import Observation
import Synchronization
#if os(iOS)
import UIKit
#endif

/// Remote editing: one device shares its library (usually the iPhone, which has
/// the photos and the faster chip) and another edits it (usually the iPad).
///
/// The devices connect directly over peer-to-peer Wi-Fi, found over Bonjour.
/// The first time, both screens show the same six-digit code and the person
/// allows the connection on both. After that the devices trust each other and
/// reconnect on their own: iOS cuts the connection whenever the iPhone locks or
/// switches apps, and editing on the iPad carries on meanwhile (see
/// `RemoteLibrary`).
@MainActor
@Observable
final class RemoteModel {
    /// A first connection waiting for the person to allow it.
    struct Pending: Identifiable {
        let id = UUID()
        let link: PeerLink
        var peerName: String { link.peerName }
        var code: String { link.code }
        var isHost: Bool { link.isHost }
        /// This side allowed it and is waiting for the other.
        var allowed = false
    }

    /// Whether nearby devices can find and edit this device's library.
    var sharing = UserDefaults.standard.bool(forKey: "remote.sharing") {
        didSet {
            UserDefaults.standard.set(sharing, forKey: "remote.sharing")
            sharing ? startSharing() : stopSharing()
        }
    }
    private(set) var discovered: [DiscoveredPeer] = []
    private(set) var connecting: String?
    var pending: Pending?
    /// The device editing this library (on the sharing device), and whether it's connected right now.
    private(set) var editingClient: String?
    private(set) var clientConnected = false
    /// The device whose library this one edits (on the editing device).
    private(set) var connectedHost: String?
    /// The link is down and this device is trying to get it back.
    private(set) var reconnecting = false
    private(set) var trustedDevices: [PeerIdentity.Trusted] = PeerIdentity.shared.trustedDevices
    var message: String?
    /// The Devices sheet shows approvals itself while it's open.
    var devicesVisible = false

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var listener: PeerListener?
    @ObservationIgnored private var listenerFailed = false
    @ObservationIgnored private var browser: PeerBrowser?
    @ObservationIgnored private var browsingForSheet = false
    @ObservationIgnored private var activeLink: PeerLink?
    @ObservationIgnored private var host: RemoteHost?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private let identity = PeerIdentity.shared

    /// The device this one last edited, so it reconnects after a relaunch.
    private struct LastHost: Codable {
        var identity: Data
        var name: String
    }
    private var lastHost: LastHost? {
        get { UserDefaults.standard.data(forKey: "remote.lastHost").flatMap { try? JSONDecoder().decode(LastHost.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "remote.lastHost") }
    }

    /// Simulators can't advertise over Bonjour; Debug simulator builds use a fixed loopback port instead.
    static var simulatorPort: UInt16? {
        #if targetEnvironment(simulator) && DEBUG
        DiscoveredPeer.simulatorPort
        #else
        nil
        #endif
    }

    static var simulatorPeers: [DiscoveredPeer] {
        #if targetEnvironment(simulator) && DEBUG
        [DiscoveredPeer.simulatorHost]
        #else
        []
        #endif
    }

    static var deviceName: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }

    func attach(_ app: AppModel) {
        self.app = app
        if sharing { startSharing() }
        // Was editing another device when the app last closed: pick up where it left off.
        if let last = lastHost, identity.trusts(last.identity) {
            let remote = RemoteLibrary(hostIdentity: last.identity, name: last.name)
            RawDecoder.remote.withLock { $0 = remote }
            connectedHost = last.name
            app.use(remote)
            startReconnecting()
        }
    }

    /// Called when the app comes to the front or goes to the background.
    func scenePhaseChanged(active: Bool) {
        guard active else { return }
        // iOS may have torn down the listener while in the background.
        if sharing, listener == nil || listenerFailed { restartSharing() }
        // Try right away rather than waiting out the backoff.
        if reconnecting { startReconnecting() }
    }

    // MARK: Sharing this library

    private func startSharing() {
        guard listener == nil else { return }
        listenerFailed = false
        do {
            listener = try PeerListener(name: Self.deviceName, port: Self.simulatorPort, onConnection: { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }, onState: { [weak self] problem in
                Task { @MainActor in
                    guard let self, let problem else { return }
                    self.listenerFailed = true
                    if UIApplicationIsActive() { self.message = problem }
                }
            })
        } catch {
            message = "Couldn't share this library: \(error.localizedDescription)"
        }
    }

    private func restartSharing() {
        listener?.stop()
        listener = nil
        startSharing()
    }

    private func stopSharing() {
        listener?.stop()
        listener = nil
        if host != nil { disconnect() }
    }

    private func accept(_ connection: NWConnection) {
        Task {
            do {
                let link = try await PeerLink.accept(connection, name: Self.deviceName, identity: identity)
                if identity.trusts(link.peerIdentity) {
                    // A device allowed before, coming back: no need to ask again.
                    try await link.approve(true)
                    try await link.waitForPeer()
                    activate(link)
                } else if pending == nil {
                    pending = Pending(link: link)
                } else {
                    link.close()
                }
            } catch {
                if UIApplicationIsActive(), (error as? PeerError) != .declined { message = error.localizedDescription }
            }
        }
    }

    // MARK: Editing another library

    func startBrowsing() {
        browsingForSheet = true
        startBrowser()
    }

    func stopBrowsing() {
        browsingForSheet = false
        if !reconnecting { stopBrowser() }
    }

    private func startBrowser() {
        guard browser == nil else { return }
        browser = PeerBrowser(ownName: Self.deviceName) { [weak self] peers in
            Task { @MainActor in self?.discovered = peers + Self.simulatorPeers }
        }
        discovered = Self.simulatorPeers
    }

    private func stopBrowser() {
        browser?.stop()
        browser = nil
        discovered = []
    }

    func connect(to peer: DiscoveredPeer) {
        guard activeLink == nil, pending == nil else { return }
        connecting = peer.name
        Task {
            defer { connecting = nil }
            do {
                let link = try await PeerLink.connect(to: peer.endpoint, name: Self.deviceName, identity: identity, parameters: Self.parameters(for: peer))
                if identity.trusts(link.peerIdentity) {
                    try await link.approve(true)
                    try await link.waitForPeer()
                    activate(link)
                } else {
                    pending = Pending(link: link)
                }
            } catch {
                message = (error as? PeerError) == .declined
                    ? "\(peer.name) didn't allow the connection. Allow it there, or Forget this device on both and connect again."
                    : "Couldn't reach \(peer.name): \(error.localizedDescription)"
            }
        }
    }

    private static func parameters(for peer: DiscoveredPeer) -> NWParameters {
        peer.isLoopback ? .tcp : PeerService.parameters
    }

    // MARK: Approval

    /// The person's answer on this device. Allowing waits for the other device too.
    func respond(allow: Bool) {
        guard var current = pending else { return }
        let link = current.link
        guard allow else {
            pending = nil
            Task { try? await link.approve(false) }
            return
        }
        current.allowed = true
        pending = current
        Task {
            do {
                try await link.approve(true)
                try await link.waitForPeer()
                pending = nil
                identity.trust(link.peerIdentity, name: link.peerName)
                trustedDevices = identity.trustedDevices
                activate(link)
            } catch {
                pending = nil
                message = (error as? PeerError) == .declined ? "\(link.peerName) didn't allow the connection." : error.localizedDescription
            }
        }
    }

    // MARK: Connected

    private func activate(_ link: PeerLink) {
        guard let app else { return }
        let previous = activeLink
        activeLink = link
        if previous !== link { previous?.close() }
        if link.isHost {
            // One host for the whole session, so work in flight survives reconnections.
            if host == nil {
                host = RemoteHost(library: app.localLibrary, luts: app.lutStore, clock: app.clock, beginActivity: Self.backgroundActivity)
            }
            host?.serve(link)
            editingClient = link.peerName
            clientConnected = true
            setScreenAwake(true)
        } else {
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnecting = false
            lastHost = LastHost(identity: link.peerIdentity, name: link.peerName)
            if let remote = app.remoteLibrary, remote.hostIdentity == link.peerIdentity {
                remote.attach(link)
            } else {
                app.remoteLibrary?.shutDown()
                let remote = RemoteLibrary(link: link)
                RawDecoder.remote.withLock { $0 = remote }
                app.use(remote)
            }
            connectedHost = link.peerName
            if !browsingForSheet { stopBrowser() }
            app.flushRemoteOutbox()
        }
        link.onClose { [weak self] reason in
            Task { @MainActor in self?.linkClosed(link, reason: reason) }
        }
    }

    /// Ends the connection on purpose. The other device won't reconnect.
    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnecting = false
        if let activeLink {
            activeLink.close()
        } else if connectedHost != nil {
            endEditingRemotely(message: nil)
        }
        if host != nil, activeLink == nil { endHosting(message: nil) }
    }

    func forget(_ device: PeerIdentity.Trusted) {
        identity.forget(device.key)
        trustedDevices = identity.trustedDevices
        if lastHost?.identity == device.key { lastHost = nil }
    }

    private func linkClosed(_ link: PeerLink, reason: PeerLink.EndReason) {
        guard link === activeLink else { return }
        activeLink = nil
        if link.isHost {
            if reason == .lost {
                // The iPad locked or left; it reconnects on its own.
                clientConnected = false
            } else {
                endHosting(message: reason == .peer ? "\(link.peerName) disconnected" : nil)
            }
        } else {
            if reason == .lost {
                // The phone locked or switched apps. Keep editing; it'll be back.
                startReconnecting()
            } else {
                endEditingRemotely(message: reason == .peer ? "\(link.peerName) ended the connection" : nil)
            }
        }
    }

    private func endHosting(message: String?) {
        host = nil
        editingClient = nil
        clientConnected = false
        setScreenAwake(false)
        if let message { app?.showToast(message) }
    }

    private func endEditingRemotely(message: String?) {
        lastHost = nil
        connectedHost = nil
        reconnecting = false
        app?.remoteLibrary?.shutDown()
        RawDecoder.remote.withLock { $0 = nil }
        app?.useLocalLibrary()
        if !browsingForSheet { stopBrowser() }
        if let message { app?.showToast(message) }
    }

    // MARK: Reconnecting

    /// Looks for the phone again and reconnects without asking, since both
    /// devices already trust each other. Backs off to every 10 s.
    private func startReconnecting() {
        guard let target = app?.remoteLibrary else { return }
        reconnecting = true
        startBrowser()
        reconnectTask?.cancel()
        let identity = self.identity
        reconnectTask = Task { [weak self] in
            var delay = Duration.milliseconds(500)
            while !Task.isCancelled {
                guard let self else { return }
                // The phone by name first, then anything else nearby.
                let candidates = self.discovered.sorted { a, _ in a.name == target.displayName }
                for peer in candidates where !Task.isCancelled {
                    guard let link = try? await PeerLink.connect(to: peer.endpoint, name: Self.deviceName, identity: identity, parameters: Self.parameters(for: peer)) else { continue }
                    guard link.peerIdentity == target.hostIdentity else {
                        link.close()
                        continue
                    }
                    do {
                        try await link.approve(true)
                        try await link.waitForPeer()
                        self.activate(link)
                        return
                    } catch {
                        if (error as? PeerError) == .declined {
                            // The phone forgot this device: connecting needs approval again.
                            self.message = "\(target.displayName) no longer trusts this device. Connect again from Devices."
                            self.endEditingRemotely(message: nil)
                            return
                        }
                    }
                }
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(10))
            }
        }
    }

    // MARK: Helpers

    /// The sharing device stays awake while another device edits it.
    private func setScreenAwake(_ awake: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = awake
        #endif
    }

    /// Lets work for the other device finish when this app goes to the background.
    nonisolated private static let backgroundActivity: @Sendable (String) -> @Sendable () -> Void = { name in
        let holder = Mutex<BackgroundActivity?>(nil)
        let ended = Mutex(false)
        Task { @MainActor in
            let activity = BackgroundActivity.begin(name)
            if ended.withLock({ $0 }) { activity.end() } else { holder.withLock { $0 = activity } }
        }
        return {
            ended.withLock { $0 = true }
            holder.withLock { $0 }?.end()
        }
    }
}

/// Whether the app is in front, so background failures don't show error messages.
@MainActor
private func UIApplicationIsActive() -> Bool {
    #if os(iOS)
    UIApplication.shared.applicationState == .active
    #else
    true
    #endif
}
