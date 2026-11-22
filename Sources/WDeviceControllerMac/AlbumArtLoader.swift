import AppKit
import ImageIO
import Foundation

/// 专辑封面加载：下载后按显示尺寸降采样，避免把大图整张解进内存。
enum AlbumArtLoader {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 32
        return cache
    }()

    static func load(urlString: String, maxPixel: Int = 480) async -> NSImage? {
        let key = "\(urlString)#\(maxPixel)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .returnCacheDataElseLoad

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              !Task.isCancelled else { return nil }

        guard let image = downsample(data: data, maxPixel: maxPixel) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    private static func downsample(data: Data, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
