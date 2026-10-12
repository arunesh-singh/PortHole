import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ImageIO helpers that turn image bytes into small JPEG thumbnails for Finder.
enum Thumbnailer {
    /// Downloads larger than this are not worth it just for a thumbnail.
    static let maxDownloadBytes: UInt64 = 40 * 1024 * 1024

    /// Thumbnail rendered from a complete image file (any format ImageIO reads).
    static func fromFile(_ url: URL, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return render(source, maxPixelSize: maxPixelSize, allowDecodingFullImage: true)
    }

    /// The thumbnail embedded in the image's metadata (EXIF), if any. Works on a
    /// prefix of the file, so callers don't need to download the whole photo.
    /// Returns nil unless the embedded thumbnail is at least `minPixelSize`.
    static func embedded(in prefix: Data, maxPixelSize: Int, minPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(prefix as CFData, nil) else { return nil }
        guard let image = thumbnailImage(source, maxPixelSize: maxPixelSize, allowDecodingFullImage: false),
              max(image.width, image.height) >= minPixelSize else { return nil }
        return jpeg(image)
    }

    /// Re-encodes thumbnail bytes the device produced (MTP GetThumb), validating them.
    static func fromData(_ data: Data, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return render(source, maxPixelSize: maxPixelSize, allowDecodingFullImage: true)
    }

    private static func render(_ source: CGImageSource, maxPixelSize: Int, allowDecodingFullImage: Bool) -> Data? {
        thumbnailImage(source, maxPixelSize: maxPixelSize, allowDecodingFullImage: allowDecodingFullImage).flatMap(jpeg)
    }

    private static func thumbnailImage(_ source: CGImageSource, maxPixelSize: Int, allowDecodingFullImage: Bool) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 16),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: allowDecodingFullImage,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

extension DeviceBackend {
    /// Fallback thumbnail: download the whole image and scale it down.
    /// Only for still images below `Thumbnailer.maxDownloadBytes`.
    func thumbnailByDownloading(_ path: VPath, maxPixelSize: Int) throws -> Data? {
        guard ThumbnailSupport.isImage(path.name) else { return nil }
        let entry = try stat(path)
        guard !entry.isDirectory, entry.size <= Thumbnailer.maxDownloadBytes else { return nil }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("thumb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        try download(path, to: temp)
        return Thumbnailer.fromFile(temp, maxPixelSize: maxPixelSize)
    }
}
