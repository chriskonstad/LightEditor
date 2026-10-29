import Foundation

/// What goes over the wire. Encoded as binary property lists, which carry image
/// data as raw bytes rather than base64.
public enum RemoteProtocol {
    /// Bump when messages change incompatibly; both devices must match.
    public static let version = 2

    static func encode(_ message: WireMessage) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(message)
    }

    static func decode(_ data: Data) throws -> WireMessage {
        try PropertyListDecoder().decode(WireMessage.self, from: data)
    }
}

/// Sent in the clear to start the handshake.
public struct PeerHello: Codable, Sendable {
    public var name: String
    public var protocolVersion: Int
    public var appVersion: String
    public var publicKey: Data
    /// The long-term identity key; the peer proves it holds it with a `proof`.
    public var identityKey: Data
}

enum WireMessage: Codable, Sendable {
    case hello(PeerHello)
    /// A signature over the handshake by the sender's identity key.
    case proof(Data)
    case approval(Bool)
    /// `key` identifies the request across reconnections, so a retry never runs twice.
    case request(id: UInt64, key: String?, RemoteRequest)
    case response(id: UInt64, RemoteResponse)
    case failure(id: UInt64, message: String)
    case event(RemoteEvent)
    /// Heartbeat, so a frozen peer is noticed even when its socket stays open.
    case ping
    case bye
}

/// A .cube file the phone may not have, sent along with renders that use it.
public struct LUTFile: Codable, Sendable, Hashable {
    public var hash: String
    public var name: String
    public var data: Data

    public init(hash: String, name: String, data: Data) {
        self.hash = hash
        self.name = name
        self.data = data
    }
}

/// Everything the iPad needs to open a photo that lives on the phone.
public struct RemoteSessionInfo: Codable, Sendable {
    public var asset: PhotoAsset
    public var filename: String
    public var stored: StoredEdit
    public var info: SourceInfo
    public var photoID: String?
}

/// One Remove fill computed on the phone.
public struct RemoteFill: Codable, Sendable {
    public var key: String
    public var region: NormalizedRect
    public var png: Data
}

/// One AI mask computed on the phone (8-bit gray PNG).
public struct RemoteMask: Codable, Sendable {
    public var shape: MaskShape
    public var png: Data
}

/// Requests the iPad (client) makes of the phone (host).
public enum RemoteRequest: Codable, Sendable {
    case albums
    case assets(LibraryAlbum)
    case thumbnail(assetID: String, pixels: Int)
    case quickPreview(assetID: String, maxPixelSize: Int)
    case beginEditing(assetID: String)
    case storedEdit(assetID: String)
    /// The decoded, ungraded image: the decode cache's half-float bytes, compressed.
    case decode(assetID: String, rawStage: RawStageParams, longEdge: Int)
    /// Computes the AI masks `recipe` uses.
    case aiMasks(assetID: String, recipe: Recipe)
    /// Computes the Remove fills `recipe` needs, from the full-resolution original.
    case fills(assetID: String, recipe: Recipe)
    case save(assetID: String, recipe: Recipe, luts: [LUTFile])
    case export(assetID: String, recipe: Recipe, options: ExportOptions, luts: [LUTFile])
    case exportToLibrary(assetID: String, recipe: Recipe, options: ExportOptions, luts: [LUTFile])
    case revert(assetID: String)
    case bulk(change: BulkChange, assetIDs: [String], luts: [LUTFile])
}

public enum RemoteResponse: Codable, Sendable {
    case albums([LibraryAlbum])
    case assets([PhotoAsset])
    case image(Data?)
    case session(RemoteSessionInfo)
    case stored(StoredEdit)
    case decoded(Data)
    case masks([RemoteMask])
    case fills([RemoteFill])
    case file(name: String, data: Data)
    case done(count: Int)
}

public enum RemoteEvent: Codable, Sendable {
    case libraryChanged
    /// Progress of a long request, e.g. a save or a bulk edit.
    case progress(requestID: UInt64, fraction: Double?, detail: String?)
}
