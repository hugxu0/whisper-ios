import ImageIO
import UIKit

/// 图片缓存：内存 + 磁盘两级。媒体文件不会变，按 ID 缓存到 Caches/media 下，读出来时按需要的尺寸缩小解码。
/// 读盘、下载、解码都在后台，主线程只做登记。
@MainActor
final class MediaCache {
    static let shared = MediaCache()

    var api: APIClient?
    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<Data?, Never>] = [:]
    let directory: URL

    private init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.totalCostLimit = 120 * 1024 * 1024
    }

    func fileURL(_ id: String, thumb: Bool) -> URL {
        directory.appendingPathComponent(thumb ? "\(id)_thumb" : id)
    }

    func cachedImage(_ id: String, thumb: Bool, maxPixel: CGFloat) -> UIImage? {
        memory.object(forKey: key(id, thumb, maxPixel))
    }

    private func key(_ id: String, _ thumb: Bool, _ maxPixel: CGFloat) -> NSString {
        "\(id)|\(thumb)|\(Int(maxPixel))" as NSString
    }

    /// 取原始字节：先看磁盘，没有就下载。同一个文件同时只下载一次。
    func data(_ id: String, thumb: Bool) async -> Data? {
        let taskKey = "\(id)|\(thumb)"
        if let existing = inFlight[taskKey] { return await existing.value }
        let file = fileURL(id, thumb: thumb)
        let api = self.api
        let task = Task.detached(priority: .userInitiated) { () -> Data? in
            if let data = try? Data(contentsOf: file) { return data }
            guard let api, let data = try? await api.data(api.mediaURL(id, thumb: thumb)) else { return nil }
            try? data.write(to: file, options: .atomic)
            return data
        }
        inFlight[taskKey] = task
        let result = await task.value
        inFlight[taskKey] = nil
        return result
    }

    /// 取图片并缩小到 maxPixel（最长边像素）；缩略图没有时退回原图
    func image(_ id: String, thumb: Bool, maxPixel: CGFloat) async -> UIImage? {
        let cacheKey = key(id, thumb, maxPixel)
        if let image = memory.object(forKey: cacheKey) { return image }
        var data = await self.data(id, thumb: thumb)
        if data == nil, thumb { data = await self.data(id, thumb: false) }
        guard let data else { return nil }
        let image = await Task.detached(priority: .userInitiated) { MediaCache.downsample(data, maxPixel: maxPixel) }.value
        if let image {
            memory.setObject(image, forKey: cacheKey, cost: Int(image.size.width * image.size.height * 4))
        }
        return image
    }

    nonisolated static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// 动图（GIF 贴纸）：返回带帧的 UIImage；不是动图时和 image 一样
    func animatedImage(_ id: String, maxPixel: CGFloat) async -> UIImage? {
        let cacheKey = "anim|\(id)|\(Int(maxPixel))" as NSString
        if let image = memory.object(forKey: cacheKey) { return image }
        guard let data = await data(id, thumb: false) else { return nil }
        let image = await Task.detached(priority: .userInitiated) { MediaCache.decodeAnimated(data, maxPixel: maxPixel) }.value
        if let image { memory.setObject(image, forKey: cacheKey, cost: data.count * 4) }
        return image
    }

    nonisolated static func decodeAnimated(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return downsample(data, maxPixel: maxPixel) }
        var frames: [UIImage] = []
        var duration: Double = 0
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel)] as CFDictionary
        for index in 0 ..< min(count, 120) {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options) else { continue }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            duration += delay < 0.02 ? 0.1 : delay
            frames.append(UIImage(cgImage: frame))
        }
        return UIImage.animatedImage(with: frames, duration: duration)
    }

    /// 自己上传的文件先放进缓存，发出去后不用再下载
    func store(_ data: Data, id: String, thumb: Bool) {
        try? data.write(to: fileURL(id, thumb: thumb), options: .atomic)
    }

    func diskUsage() async -> Int64 {
        let directory = self.directory
        return await Task.detached {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return files.reduce(Int64(0)) { total, url in total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }.value
    }

    func clearDisk() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
