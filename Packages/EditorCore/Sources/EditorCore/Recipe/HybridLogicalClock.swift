import Foundation
import Synchronization

/// A hybrid logical clock timestamp.
///
/// Every recipe parameter carries one so that the M3 merge can be per-parameter
/// last-writer-wins. It encodes as a compact string, `millis.counter.node`.
public struct HLCStamp: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public var millis: Int64
    public var counter: UInt32
    public var node: String

    public init(millis: Int64, counter: UInt32 = 0, node: String) {
        self.millis = millis
        self.counter = counter
        self.node = node
    }

    public static func < (lhs: HLCStamp, rhs: HLCStamp) -> Bool {
        (lhs.millis, lhs.counter, lhs.node) < (rhs.millis, rhs.counter, rhs.node)
    }

    public var description: String { "\(millis).\(counter).\(node)" }

    public init(from decoder: any Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        let parts = string.split(separator: ".", maxSplits: 2)
        guard parts.count == 3, let millis = Int64(parts[0]), let counter = UInt32(parts[1]) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad HLC stamp \(string)"))
        }
        self.init(millis: millis, counter: counter, node: String(parts[2]))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Issues monotonically increasing `HLCStamp`s for one device.
public final class HybridLogicalClock: Sendable {
    public let node: String
    private let last: Mutex<HLCStamp>
    private let wallClock: @Sendable () -> Date

    public init(node: String, wallClock: @escaping @Sendable () -> Date = { Date() }) {
        self.node = node
        self.wallClock = wallClock
        self.last = Mutex(HLCStamp(millis: 0, counter: 0, node: node))
    }

    public func now() -> HLCStamp {
        let wall = Int64(wallClock().timeIntervalSince1970 * 1000)
        return last.withLock { last in
            if wall > last.millis {
                last = HLCStamp(millis: wall, counter: 0, node: node)
            } else {
                last = HLCStamp(millis: last.millis, counter: last.counter + 1, node: node)
            }
            return last
        }
    }

    /// Advances the clock past a stamp received from another device.
    public func observe(_ remote: HLCStamp) {
        last.withLock { last in
            if remote.millis > last.millis || (remote.millis == last.millis && remote.counter > last.counter) {
                last = HLCStamp(millis: remote.millis, counter: remote.counter, node: node)
            }
        }
    }
}
