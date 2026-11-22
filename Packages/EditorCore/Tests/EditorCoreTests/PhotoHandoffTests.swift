import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import EditorCore

/// "Edit in LightEditor" from Photos: the hand-off URL, reading a shared file, and
/// finding the library photo it came from.
@Suite struct PhotoHandoffTests {
    private let utc = TimeZone(identifier: "UTC")!

    /// 2025-01-31 21:15:41 in the given zone.
    private func date(_ text: String = "2025-01-31 21:15:41", zone: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: zone)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)!
    }

    private func candidate(_ id: String, _ filenames: [String], created: Date, size: (Int, Int) = (7728, 5152)) -> HandoffCandidate {
        HandoffCandidate(asset: PhotoAsset(id: id, creationDate: created, pixelWidth: size.0, pixelHeight: size.1), filenames: filenames)
    }

    // MARK: URL

    @Test func urlRoundTrips() throws {
        let photo = SharedPhoto(name: "DSCF2030.heic", taken: "2025:01:31 21:15:41", offset: "+09:00", pixelWidth: 7728, pixelHeight: 5152)
        let url = PhotoHandoff(photo: photo).url
        #expect(url.scheme == "lighteditor")
        #expect(url.host() == "edit")
        // "+" must survive: unencoded, URL readers turn it into a space.
        #expect(url.absoluteString.contains("offset=%2B09:00"))
        let decoded = try #require(PhotoHandoff(url: url))
        #expect(decoded.photo == photo)
        #expect(decoded.photo.name == "dscf2030")
    }

    @Test func urlWithoutOptionalFields() throws {
        let photo = SharedPhoto(name: nil, taken: "2025:01:31 21:15:41")
        let decoded = try #require(PhotoHandoff(url: PhotoHandoff(photo: photo).url))
        #expect(decoded.photo == photo)
    }

    @Test func rejectsOtherURLs() {
        #expect(PhotoHandoff(url: URL(string: "https://edit?taken=2025:01:31%2021:15:41")!) == nil)
        #expect(PhotoHandoff(url: URL(string: "lighteditor://open?taken=2025:01:31%2021:15:41")!) == nil)
        // Nothing to search by.
        #expect(PhotoHandoff(url: URL(string: "lighteditor://edit?name=IMG_0001")!) == nil)
        #expect(PhotoHandoff(url: URL(string: "lighteditor://edit?taken=yesterday")!) == nil)
    }

    // MARK: Capture time

    @Test func offsetsParse() {
        #expect(SharedPhoto.seconds(fromOffset: "+09:00") == 32400)
        #expect(SharedPhoto.seconds(fromOffset: "-03:30") == -12600)
        #expect(SharedPhoto.seconds(fromOffset: "09:00") == nil)
    }

    @Test func timeWithoutOffsetMatchesAnyZone() {
        let photo = SharedPhoto(name: "DSCF2030", taken: "2025:01:31 21:15:41")
        // Photos dated the import in whatever zone the device was in.
        #expect(photo.couldBeTaken(at: date(zone: "America/Los_Angeles")))
        #expect(photo.couldBeTaken(at: date(zone: "Asia/Tokyo")))
        #expect(photo.couldBeTaken(at: date(zone: "Asia/Kolkata")))
        #expect(photo.couldBeTaken(at: date(zone: "Pacific/Kiritimati")))
        // Sub-second creation dates.
        #expect(photo.couldBeTaken(at: date(zone: "UTC").addingTimeInterval(0.762)))
        // A different second, or a different day, isn't the same photo.
        #expect(!photo.couldBeTaken(at: date("2025-01-31 21:15:44", zone: "UTC")))
        #expect(!photo.couldBeTaken(at: date("2025-01-30 21:15:41", zone: "UTC")))
        #expect(!photo.couldBeTaken(at: nil))
    }

    @Test func timeWithOffsetMatchesOneInstant() {
        let photo = SharedPhoto(name: "DSC04319", taken: "2025:01:31 21:15:41", offset: "+09:00")
        #expect(photo.couldBeTaken(at: date(zone: "Asia/Tokyo")))
        #expect(!photo.couldBeTaken(at: date(zone: "America/Los_Angeles")))
    }

    // MARK: Matching

    @Test func picksTheSharedFileAmongPhotosFromTheSameSecond() {
        let created = date(zone: "America/Los_Angeles")
        let photo = SharedPhoto(name: "DSCF2030.heic", taken: "2025:01:31 21:15:41", pixelWidth: 7728, pixelHeight: 5152)
        let match = SharedPhotoMatcher.rank(photo, among: [
            candidate("burst", ["DSCF2031.RAF"], created: created),
            candidate("ours", ["DSCF2030.RAF"], created: created),
            candidate("other day", ["DSCF2030.RAF"], created: created.addingTimeInterval(-86400)),
        ])
        #expect(match.map(\.id) == ["ours"])
    }

    @Test func rawPlusJPEGMatchesEitherName() {
        let created = date(zone: "Asia/Tokyo")
        let photo = SharedPhoto(name: "DSC04319.JPG", taken: "2025:01:31 21:15:41", offset: "+09:00")
        let match = SharedPhotoMatcher.rank(photo, among: [candidate("pair", ["DSC04319.JPG", "DSC04319.ARW"], created: created)])
        #expect(match.map(\.id) == ["pair"])
    }

    @Test func croppedEditStillMatchesByName() {
        let created = date(zone: "UTC")
        let photo = SharedPhoto(name: "DSCF2030", taken: "2025:01:31 21:15:41", pixelWidth: 4000, pixelHeight: 3000)
        let match = SharedPhotoMatcher.rank(photo, among: [
            candidate("cropped", ["DSCF2030.RAF"], created: created),
            candidate("same size", ["IMG_0001.JPG"], created: created, size: (3000, 4000)),
        ])
        #expect(match.map(\.id) == ["cropped"])
    }

    @Test func sizeDecidesWhenNamesDiffer() {
        let created = date(zone: "UTC")
        // Rotated: the shared copy is upright, sizes compare either way round.
        let photo = SharedPhoto(name: "renamed", taken: "2025:01:31 21:15:41", pixelWidth: 5152, pixelHeight: 7728)
        let match = SharedPhotoMatcher.rank(photo, among: [
            candidate("a", ["IMG_0001.JPG"], created: created, size: (4032, 3024)),
            candidate("b", ["IMG_0002.JPG"], created: created),
        ])
        #expect(match.map(\.id) == ["b"])
    }

    @Test func timeAloneIsNotEnough() {
        let created = date(zone: "UTC")
        let photo = SharedPhoto(name: "DSCF2030", taken: "2025:01:31 21:15:41", pixelWidth: 100, pixelHeight: 100)
        #expect(SharedPhotoMatcher.rank(photo, among: [candidate("x", ["IMG_9999.JPG"], created: created)]).isEmpty)
    }

    @Test func duplicatesAreAllReturned() {
        let created = date(zone: "UTC")
        let photo = SharedPhoto(name: "DSCF2030", taken: "2025:01:31 21:15:41", pixelWidth: 7728, pixelHeight: 5152)
        let match = SharedPhotoMatcher.rank(photo, among: [
            candidate("first", ["DSCF2030.raf"], created: created),
            candidate("second", ["DSCF2030.raf"], created: created),
        ])
        #expect(match.map(\.id) == ["first", "second"])
    }

    // MARK: Files and the folder library

    /// A small JPEG with the given EXIF capture time.
    private func writeJPEG(named name: String, in directory: URL, taken: String, offset: String? = nil, size: Int = 32) throws -> URL {
        let url = directory.appending(path: name)
        let context = try #require(CGContext(data: nil, width: size, height: size / 2, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.5, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size / 2))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        var exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: taken]
        if let offset { exif[kCGImagePropertyExifOffsetTimeOriginal] = offset }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary: exif] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func readsASharedFile() throws {
        let directory = try temporaryDirectory()
        let url = try writeJPEG(named: "DSCF2030.heic", in: directory, taken: "2025:01:31 21:15:41", offset: "-08:00", size: 40)
        let photo = try #require(SharedPhoto(imageAt: url))
        #expect(photo.name == "dscf2030")
        #expect(photo.taken == "2025:01:31 21:15:41")
        #expect(photo.offset == "-08:00")
        #expect(photo.pixelWidth == 40 && photo.pixelHeight == 20)
        // An item provider's suggested name wins over the temporary file's.
        #expect(SharedPhoto(imageAt: url, name: "IMG_0001")?.name == "img_0001")
    }

    @Test func folderLibraryFindsTheSharedPhoto() async throws {
        let library = try temporaryDirectory()
        _ = try writeJPEG(named: "DSC00001.jpg", in: library, taken: "2025:01:31 21:15:41")
        _ = try writeJPEG(named: "DSC00002.jpg", in: library, taken: "2025:01:31 21:15:41")
        _ = try writeJPEG(named: "DSC00003.jpg", in: library, taken: "2025:02:01 08:00:00")
        // The copy Photos would share: same name and time, different format.
        let shared = try writeJPEG(named: "DSC00002.heic", in: try temporaryDirectory(), taken: "2025:01:31 21:15:41")

        let photo = try #require(SharedPhoto(imageAt: shared))
        let handoff = try #require(PhotoHandoff(url: PhotoHandoff(photo: photo).url))
        let match = await FolderLibrary(directory: library).assets(matching: handoff.photo)
        #expect(match.map(\.id) == ["DSC00002.jpg"])
    }
}

/// Renders carry the original's capture metadata, so edits shared from Photos can be
/// matched back to their asset, but never its location.
@Suite struct RenderMetadataTests {
    @Test(arguments: [ExportFormat.jpeg, .heic])
    func rendersKeepCaptureTimeButNotLocation(format: ExportFormat) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "DSC00001.jpg")
        let image = solid(0.4, 0.3, 0.2, size: 64)
        let cg = try #require(RenderContext.shared.createCGImage(image, from: image.extent))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2025:01:31 21:15:41", kCGImagePropertyExifOffsetTimeOriginal: "-08:00", kCGImagePropertyExifLensModel: "XF16-80mmF4"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "FUJIFILM", kCGImagePropertyTIFFModel: "X-T5"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 19.6, kCGImagePropertyGPSLatitudeRef: "N"],
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        let data = try await Exporter.render(source: PhotoSource(url: url, key: "metadata-\(format)"), recipe: Recipe(), luts: nil, options: ExportOptions(format: format))
        let rendered = directory.appending(path: "render.\(format.fileExtension)")
        try data.write(to: rendered)
        let file = CGImageSourceCreateWithData(data as CFData, nil)
        let properties = try #require(file.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any])
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2025:01:31 21:15:41")
        #expect(exif[kCGImagePropertyExifLensModel] as? String == "XF16-80mmF4")
        #expect(tiff[kCGImagePropertyTIFFModel] as? String == "X-T5")
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)

        let shared = try #require(SharedPhoto(imageAt: rendered))
        #expect(shared.taken == "2025:01:31 21:15:41" && shared.offset == "-08:00")
    }
}
