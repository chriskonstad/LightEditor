import Foundation
import Network
import os
import Synchronization

/// Advertises this device over Bonjour (including peer-to-peer Wi-Fi) and hands
/// over each incoming connection.
public final class PeerListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LightEditor.PeerListener")

    /// `port` pins the port, for simulators, which don't register Bonjour services.
    public init(name: String, port: UInt16? = nil, onConnection: @escaping @Sendable (NWConnection) -> Void, onState: @escaping @Sendable (String?) -> Void) throws {
        if let port, let fixed = NWEndpoint.Port(rawValue: port) {
            listener = try NWListener(using: PeerService.parameters, on: fixed)
        } else {
            listener = try NWListener(using: PeerService.parameters)
        }
        listener.service = NWListener.Service(name: name, type: PeerService.type)
        listener.newConnectionHandler = onConnection
        listener.serviceRegistrationUpdateHandler = { change in
            if case .add(let endpoint) = change { Logger.remote.info("Advertising \(String(describing: endpoint), privacy: .public)") }
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .failed(let error): onState("Couldn't advertise: \(error.localizedDescription)")
            case .waiting(let error): onState("Waiting for the network: \(error.localizedDescription)")
            case .ready: onState(nil)
            default: break
            }
        }
        listener.start(queue: queue)
    }

    /// The local port, once listening; used by tests to connect over loopback.
    public var port: UInt16? { listener.port?.rawValue }

    public func stop() {
        listener.cancel()
    }
}

/// A device advertising LightEditor nearby.
public struct DiscoveredPeer: Identifiable, Hashable, Sendable {
    public var name: String
    public var endpoint: NWEndpoint
    /// Reached over loopback (simulators on one Mac), which needs plain TCP parameters.
    public var isLoopback = false

    public init(name: String, endpoint: NWEndpoint, isLoopback: Bool = false) {
        self.name = name
        self.endpoint = endpoint
        self.isLoopback = isLoopback
    }

    public var id: String { name }

    /// Simulators don't register Bonjour services, so in Debug simulator builds
    /// the sharing device also listens here and others offer it as a nearby device.
    public static let simulatorPort: UInt16 = 52731
    public static let simulatorHost = DiscoveredPeer(
        name: "Simulator on this Mac", endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: simulatorPort)!), isLoopback: true
    )
}

/// Finds nearby devices that share their library.
public final class PeerBrowser: @unchecked Sendable {
    private let browser: NWBrowser
    private let queue = DispatchQueue(label: "LightEditor.PeerBrowser")

    /// `ownName` hides this device's own advertisement.
    public init(ownName: String, onChange: @escaping @Sendable ([DiscoveredPeer]) -> Void) {
        browser = NWBrowser(for: .bonjour(type: PeerService.type, domain: nil), using: PeerService.parameters)
        browser.browseResultsChangedHandler = { results, _ in
            let peers = results.compactMap { result -> DiscoveredPeer? in
                guard case .service(let name, _, _, _) = result.endpoint, name != ownName else { return nil }
                return DiscoveredPeer(name: name, endpoint: result.endpoint)
            }
            onChange(peers.sorted { $0.name < $1.name })
        }
        browser.start(queue: queue)
    }

    public func stop() {
        browser.cancel()
    }
}

extension Logger {
    static let remote = Logger(subsystem: "com.chriskonstad.lighteditor", category: "remote")
}
