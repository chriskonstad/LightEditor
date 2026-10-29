import CryptoKit
import Foundation

/// A parsed 3D LUT in Core Image's color cube layout: RGBA Float32, red varying fastest.
public struct CubeLUT: Sendable, Hashable {
    public var title: String
    public var dimension: Int
    /// `dimension³ × 4` floats.
    public var data: Data
    /// SHA-256 of the source file, used as the `LUTRef` hash.
    public var hash: String

    public var ref: LUTRef { LUTRef(hash: hash, name: title) }
}

public enum CubeParseError: Error, Equatable, LocalizedError {
    case missingSize
    case unsupportedSize(Int)
    case oneDimensional
    case wrongEntryCount(expected: Int, found: Int)
    case badLine(Int, String)

    public var errorDescription: String? {
        switch self {
        case .missingSize: "The file has no LUT_3D_SIZE line."
        case .unsupportedSize(let size): "LUT size \(size) is not supported (2–128)."
        case .oneDimensional: "1D LUTs are not supported; use a 3D .cube."
        case .wrongEntryCount(let expected, let found): "Expected \(expected) entries, found \(found)."
        case .badLine(let line, let text): "Line \(line) is not valid: \(text)"
        }
    }
}

/// Parses Adobe/Resolve `.cube` files.
///
/// Handles comments, TITLE, DOMAIN_MIN/DOMAIN_MAX (input values are rescaled into
/// 0...1), sizes from 2 to 128, and CRLF line endings. 1D LUTs are rejected.
public enum CubeParser {
    public static func parse(_ data: Data, fallbackTitle: String = "LUT") throws -> CubeLUT {
        let text = String(decoding: data, as: UTF8.self)
        var title = fallbackTitle
        var size: Int?
        var domainMin: [Float] = [0, 0, 0]
        var domainMax: [Float] = [1, 1, 1]
        var values: [Float] = []

        var lineNumber = 0
        // Split on any newline; "\r\n" is a single Character in Swift.
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            lineNumber += 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let first = line.first!
            if first.isLetter {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                switch parts[0].uppercased() {
                case "TITLE":
                    title = line.dropFirst(5).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                case "LUT_3D_SIZE":
                    guard parts.count >= 2, let value = Int(parts[1]) else { throw CubeParseError.badLine(lineNumber, line) }
                    guard (2...128).contains(value) else { throw CubeParseError.unsupportedSize(value) }
                    size = value
                    values.reserveCapacity(value * value * value * 3)
                case "LUT_1D_SIZE":
                    throw CubeParseError.oneDimensional
                case "DOMAIN_MIN":
                    domainMin = parts.dropFirst().compactMap { Float($0) }
                    guard domainMin.count == 3 else { throw CubeParseError.badLine(lineNumber, line) }
                case "DOMAIN_MAX":
                    domainMax = parts.dropFirst().compactMap { Float($0) }
                    guard domainMax.count == 3 else { throw CubeParseError.badLine(lineNumber, line) }
                default:
                    continue  // Unknown keywords, such as LUT_3D_INPUT_RANGE, are ignored.
                }
                continue
            }

            var count = 0
            for token in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                guard let value = Float(token) else { throw CubeParseError.badLine(lineNumber, line) }
                values.append(value)
                count += 1
            }
            guard count == 3 else { throw CubeParseError.badLine(lineNumber, line) }
        }

        guard let size else { throw CubeParseError.missingSize }
        let entries = size * size * size
        guard values.count == entries * 3 else {
            throw CubeParseError.wrongEntryCount(expected: entries, found: values.count / 3)
        }

        // The domain describes input coordinates. Core Image cubes always span 0...1,
        // so resample when the domain is not the unit cube. Output values pass through.
        let unitDomain = domainMin == [0, 0, 0] && domainMax == [1, 1, 1]
        var rgba = [Float](repeating: 1, count: entries * 4)
        if unitDomain {
            for i in 0..<entries {
                rgba[i * 4] = values[i * 3]
                rgba[i * 4 + 1] = values[i * 3 + 1]
                rgba[i * 4 + 2] = values[i * 3 + 2]
            }
        } else {
            rgba = resample(values, size: size, domainMin: domainMin, domainMax: domainMax)
        }

        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let bytes = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        return CubeLUT(title: title, dimension: size, data: bytes, hash: hash)
    }

    /// Resamples a LUT whose input domain is not 0...1 onto the unit cube by trilinear lookup.
    private static func resample(_ values: [Float], size: Int, domainMin: [Float], domainMax: [Float]) -> [Float] {
        func lookup(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
            let n = Float(size - 1)
            func coord(_ v: Float, _ axis: Int) -> Float {
                let span = max(domainMax[axis] - domainMin[axis], 1e-6)
                return min(max((v - domainMin[axis]) / span, 0), 1) * n
            }
            let x = coord(r, 0), y = coord(g, 1), z = coord(b, 2)
            let x0 = Int(x), y0 = Int(y), z0 = Int(z)
            let x1 = min(x0 + 1, size - 1), y1 = min(y0 + 1, size - 1), z1 = min(z0 + 1, size - 1)
            let fx = x - Float(x0), fy = y - Float(y0), fz = z - Float(z0)
            func at(_ i: Int, _ j: Int, _ k: Int, _ c: Int) -> Float { values[((k * size + j) * size + i) * 3 + c] }
            func channel(_ c: Int) -> Float {
                let c00 = at(x0, y0, z0, c) * (1 - fx) + at(x1, y0, z0, c) * fx
                let c10 = at(x0, y1, z0, c) * (1 - fx) + at(x1, y1, z0, c) * fx
                let c01 = at(x0, y0, z1, c) * (1 - fx) + at(x1, y0, z1, c) * fx
                let c11 = at(x0, y1, z1, c) * (1 - fx) + at(x1, y1, z1, c) * fx
                return (c00 * (1 - fy) + c10 * fy) * (1 - fz) + (c01 * (1 - fy) + c11 * fy) * fz
            }
            return (channel(0), channel(1), channel(2))
        }
        var rgba = [Float](repeating: 1, count: size * size * size * 4)
        let n = Float(size - 1)
        for k in 0..<size {
            for j in 0..<size {
                for i in 0..<size {
                    let (r, g, b) = lookup(Float(i) / n, Float(j) / n, Float(k) / n)
                    let index = ((k * size + j) * size + i) * 4
                    rgba[index] = r
                    rgba[index + 1] = g
                    rgba[index + 2] = b
                }
            }
        }
        return rgba
    }
}
