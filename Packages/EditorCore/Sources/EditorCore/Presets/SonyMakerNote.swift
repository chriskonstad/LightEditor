import Foundation

/// Reads the few plain tags we need from a Sony ARW's maker notes: the Creative Look,
/// its adjustments and the white balance shift.
///
/// ImageIO only exposes the look's name, so this walks the TIFF structure itself:
/// IFD0 → Exif IFD (0x8769) → MakerNote (0x927C) → Sony IFD. Tag numbers and meanings
/// follow exiftool's Sony tables. Only unencrypted tags are read.
struct SonyMakerNote {
    /// Raw tag values: integers for numeric tags, strings for ASCII ones.
    private(set) var integers: [UInt16: [Int]] = [:]
    private(set) var strings: [UInt16: String] = [:]

    /// The tags `SonyLooks.CameraSettings` uses; everything else is skipped.
    static let wanted: Set<UInt16> = [0x2004, 0x2005, 0x2026, 0x2032, 0x2033, 0x2034, 0x2036, 0xb020]

    init?(fileAt url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        self.init(data: data)
    }

    init?(data: Data) {
        guard let tiff = TIFFReader(data: data),
              let exif = tiff.entries(at: tiff.firstIFDOffset).first(where: { $0.tag == 0x8769 }),
              let makerNote = tiff.entries(at: Int(exif.value)).first(where: { $0.tag == 0x927C })
        else { return nil }
        var start = Int(makerNote.value)
        // Most Sony maker notes start with "SONY DSC \0\0\0" or "SONY CAM \0\0\0"; some go straight to the IFD.
        if tiff.bytes(at: start, count: 4) == Array("SONY".utf8) { start += 12 }
        for entry in tiff.entries(at: start) where Self.wanted.contains(entry.tag) {
            switch entry.type {
            case 2:
                strings[entry.tag] = tiff.string(entry)
            case 3, 4, 8, 9:
                integers[entry.tag] = tiff.integers(entry)
            default:
                continue
            }
        }
    }

    func integer(_ tag: UInt16) -> Int? { integers[tag]?.first }
}

/// Just enough TIFF to follow IFDs and read small values, in either byte order.
private struct TIFFReader {
    struct Entry {
        var tag: UInt16
        var type: UInt16
        var count: UInt32
        /// The value itself when it fits in 4 bytes, otherwise its offset.
        var value: UInt32
        /// Where the 4-byte value field sits, for values stored inline.
        var valueOffset: Int
    }

    let data: Data
    let littleEndian: Bool
    private(set) var firstIFDOffset = 0

    init?(data: Data) {
        guard data.count >= 8 else { return nil }
        self.data = data
        switch (data[data.startIndex], data[data.startIndex + 1]) {
        case (0x49, 0x49): littleEndian = true
        case (0x4D, 0x4D): littleEndian = false
        default: return nil
        }
        guard u16(at: 2) == 42, let first = u32(at: 4) else { return nil }
        firstIFDOffset = Int(first)
    }

    func bytes(at offset: Int, count: Int) -> [UInt8]? {
        guard offset >= 0, count >= 0, offset + count <= data.count else { return nil }
        let start = data.startIndex + offset
        return Array(data[start..<start + count])
    }

    func u16(at offset: Int) -> UInt16? {
        guard let b = bytes(at: offset, count: 2) else { return nil }
        return littleEndian ? UInt16(b[0]) | UInt16(b[1]) << 8 : UInt16(b[0]) << 8 | UInt16(b[1])
    }

    func u32(at offset: Int) -> UInt32? {
        guard let b = bytes(at: offset, count: 4) else { return nil }
        let v = b.map(UInt32.init)
        return littleEndian ? v[0] | v[1] << 8 | v[2] << 16 | v[3] << 24 : v[0] << 24 | v[1] << 16 | v[2] << 8 | v[3]
    }

    func entries(at offset: Int) -> [Entry] {
        guard let count = u16(at: offset), count < 1000 else { return [] }
        return (0..<Int(count)).compactMap { index in
            let base = offset + 2 + index * 12
            guard let tag = u16(at: base), let type = u16(at: base + 2),
                  let count = u32(at: base + 4), let value = u32(at: base + 8) else { return nil }
            return Entry(tag: tag, type: type, count: count, value: value, valueOffset: base + 8)
        }
    }

    private static func size(of type: UInt16) -> Int {
        switch type {
        case 3, 8: 2
        case 4, 9: 4
        default: 1
        }
    }

    /// Where an entry's value starts: inline when it fits in 4 bytes.
    private func valueStart(_ entry: Entry) -> Int {
        Int(entry.count) * Self.size(of: entry.type) <= 4 ? entry.valueOffset : Int(entry.value)
    }

    func integers(_ entry: Entry) -> [Int] {
        guard entry.count <= 64 else { return [] }
        let start = valueStart(entry)
        let size = Self.size(of: entry.type)
        return (0..<Int(entry.count)).compactMap { index in
            let offset = start + index * size
            switch entry.type {
            case 3: return u16(at: offset).map(Int.init)
            case 8: return u16(at: offset).map { Int(Int16(bitPattern: $0)) }
            case 4: return u32(at: offset).map(Int.init)
            case 9: return u32(at: offset).map { Int(Int32(bitPattern: $0)) }
            default: return nil
            }
        }
    }

    func string(_ entry: Entry) -> String? {
        guard entry.count <= 256, let bytes = bytes(at: valueStart(entry), count: Int(entry.count)) else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}
