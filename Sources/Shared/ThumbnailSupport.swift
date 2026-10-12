import Foundation

/// Which files get Finder thumbnails. Shared so the extension can skip IPC for
/// files that never have one.
enum ThumbnailSupport {
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp", "tif", "tiff", "dng", "avif",
    ]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "3gp", "mkv", "webm"]

    private static func ext(_ name: String) -> String { (name as NSString).pathExtension.lowercased() }

    static func isImage(_ name: String) -> Bool { imageExtensions.contains(ext(name)) }
    static func isVideo(_ name: String) -> Bool { videoExtensions.contains(ext(name)) }
    static func hasThumbnail(_ name: String) -> Bool { isImage(name) || isVideo(name) }
}
