import AVFoundation
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// 视频封面：没有缩略图的旧视频，从视频里截第一帧
@MainActor
enum VideoPoster {
    private static var cache: [String: UIImage] = [:]

    static func poster(for mediaId: String) async -> UIImage? {
        if let image = cache[mediaId] { return image }
        guard let api = MediaCache.shared.api else { return nil }
        let asset = AVURLAsset(url: api.playableURL(mediaId))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        guard let result = try? await generator.image(at: .zero) else { return nil }
        let image = UIImage(cgImage: result.image)
        cache[mediaId] = image
        return image
    }
}

/// 从剪贴板粘贴来的一张图：原始字节先留着，等选了“发送”还是“当表情发”再压
struct PastedImage {
    let data: Data
    let isGIF: Bool
    let preview: UIImage
}

/// 上传前在手机上处理媒体：压缩、算尺寸、做缩略图
enum MediaPrep {
    static func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("prep-\(UUID().uuidString).\(ext)")
    }

    /// 照片：长边最多 1920，JPEG 0.78（上行带宽小，原来 2560 的太慢）；缩略图长边 800，聊天气泡直接用它
    static func photo(_ image: UIImage, maxSide: CGFloat = 1920) -> PreparedMedia? {
        let full = resized(image, maxSide: maxSide)
        guard let data = full.jpegData(compressionQuality: 0.78) else { return nil }
        let url = tempURL("jpg")
        do { try data.write(to: url) } catch { return nil }
        // 缩略图和预览从已经缩小的图再缩，不再重画一遍原图
        let small = resized(full, maxSide: 800)
        let thumb = small.jpegData(compressionQuality: 0.72)
        let size = CGSize(width: full.size.width * full.scale, height: full.size.height * full.scale)
        return PreparedMedia(
            localId: "local-\(UUID().uuidString)",
            fileURL: url,
            filename: "photo.jpg",
            meta: UploadMeta(kind: "image", mime: "image/jpeg", width: Int(size.width), height: Int(size.height)),
            thumbnail: thumb,
            preview: small
        )
    }

    /// 相册里的照片：用 ImageIO 直接按目标尺寸解码（顺带把方向转正），不把整张原图画一遍
    static func photo(data: Data, maxSide: CGFloat = 1920) -> PreparedMedia? {
        guard let image = MediaCache.downsample(data, maxPixel: maxSide) else { return nil }
        return photo(image, maxSide: maxSide)
    }

    /// GIF 保持原样（动图）
    static func animatedGIF(_ data: Data) -> PreparedMedia? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let width = properties[kCGImagePropertyPixelWidth] as? Int
        let height = properties[kCGImagePropertyPixelHeight] as? Int
        let url = tempURL("gif")
        do { try data.write(to: url) } catch { return nil }
        return PreparedMedia(
            localId: "local-\(UUID().uuidString)",
            fileURL: url,
            filename: "sticker.gif",
            meta: UploadMeta(kind: "image", mime: "image/gif", width: width, height: height),
            thumbnail: nil,
            preview: UIImage(data: data)
        )
    }

    static func resized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return normalized(image) }
        let factor = maxSide / longest
        let target = CGSize(width: floor(size.width * factor), height: floor(size.height * factor))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
    }

    /// 把方向信息画进像素里，上传后不会转
    static func normalized(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }
    }

    /// 视频：重新编码成长边 1280、约 2Mbps 的 mp4（原片太大，上传和边下边播都慢），取第一帧做封面
    static func video(_ source: URL) async -> PreparedMedia? {
        let asset = AVURLAsset(url: source)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let output = tempURL("mp4")
        var size: CGSize
        do {
            size = try await VideoTranscoder.transcode(asset, to: output)
        } catch {
            // 自己编码失败时退回系统的 720p 导出
            try? FileManager.default.removeItem(at: output)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let naturalSize = try? await track.load(.naturalSize),
                  let transform = try? await track.load(.preferredTransform),
                  let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else { return nil }
            export.shouldOptimizeForNetworkUse = true
            do {
                try await export.export(to: output, as: .mp4)
            } catch {
                return nil
            }
            let oriented = naturalSize.applying(transform)
            let scale = min(1, 1280 / max(abs(oriented.width), abs(oriented.height), 1))
            size = CGSize(width: abs(oriented.width) * scale, height: abs(oriented.height) * scale)
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        var posterImage: UIImage?
        if let frame = try? await generator.image(at: .zero) { posterImage = UIImage(cgImage: frame.image) }
        return PreparedMedia(
            localId: "local-\(UUID().uuidString)",
            fileURL: output,
            filename: "video.mp4",
            meta: UploadMeta(kind: "video", mime: "video/mp4", width: Int(size.width), height: Int(size.height), durationMs: Int(duration.seconds * 1000)),
            thumbnail: posterImage?.jpegData(compressionQuality: 0.7),
            preview: posterImage
        )
    }

    static func voice(url: URL, durationMs: Int) -> PreparedMedia {
        PreparedMedia(
            localId: "local-\(UUID().uuidString)",
            fileURL: url,
            filename: "voice.m4a",
            meta: UploadMeta(kind: "audio", mime: "audio/mp4", durationMs: durationMs),
            thumbnail: nil,
            preview: nil
        )
    }

    static func file(_ source: URL) -> PreparedMedia? {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let url = tempURL(source.pathExtension.isEmpty ? "bin" : source.pathExtension)
        do { try FileManager.default.copyItem(at: source, to: url) } catch { return nil }
        let type = UTType(filenameExtension: source.pathExtension)
        let mime = type?.preferredMIMEType ?? "application/octet-stream"
        return PreparedMedia(
            localId: "local-\(UUID().uuidString)",
            fileURL: url,
            filename: source.lastPathComponent,
            meta: UploadMeta(kind: "file", mime: mime, name: source.lastPathComponent),
            thumbnail: nil,
            preview: nil
        )
    }

    /// 从相册选出来的内容：图片（包括 GIF）或视频。同时处理三个，结果按选的顺序排
    static func load(_ results: [PHPickerResult], photoMaxSide: CGFloat = 1920) async -> [PreparedMedia] {
        var prepared = [PreparedMedia?](repeating: nil, count: results.count)
        await withTaskGroup(of: (Int, PreparedMedia?).self) { group in
            var next = 0
            while next < min(3, results.count) {
                let index = next
                group.addTask { (index, await MediaPrep.prepare(results[index], photoMaxSide: photoMaxSide)) }
                next += 1
            }
            while let (index, media) = await group.next() {
                prepared[index] = media
                if next < results.count {
                    let index = next
                    group.addTask { (index, await MediaPrep.prepare(results[index], photoMaxSide: photoMaxSide)) }
                    next += 1
                }
            }
        }
        return prepared.compactMap { $0 }
    }

    private static func prepare(_ result: PHPickerResult, photoMaxSide: CGFloat) async -> PreparedMedia? {
        let provider = result.itemProvider
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            guard let url = await loadFile(provider, type: .movie) else { return nil }
            defer { try? FileManager.default.removeItem(at: url) }
            return await video(url)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.gif.identifier) {
            guard let data = await loadData(provider, type: .gif) else { return nil }
            return animatedGIF(data)
        }
        if provider.canLoadObject(ofClass: UIImage.self) {
            guard let data = await loadData(provider, type: .image) else { return nil }
            return photo(data: data, maxSide: photoMaxSide)
        }
        return nil
    }

    /// 剪贴板里的图片（最多 9 张）：GIF 保持原样，其余先读出原始字节
    static func pastedImages(_ providers: [NSItemProvider]) async -> [PastedImage] {
        var images: [PastedImage] = []
        for provider in providers.prefix(9) {
            if provider.hasItemConformingToTypeIdentifier(UTType.gif.identifier), let data = await loadData(provider, type: .gif), let preview = UIImage(data: data) {
                images.append(PastedImage(data: data, isGIF: true, preview: preview))
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier), let data = await loadData(provider, type: .image),
                      let preview = MediaCache.downsample(data, maxPixel: 900) {
                images.append(PastedImage(data: data, isGIF: false, preview: preview))
            }
        }
        return images
    }

    /// 粘贴的图当普通图片发：GIF 原样，其余和相册里的照片一样压
    static func pastedPhotos(_ images: [PastedImage]) async -> [PreparedMedia] {
        images.compactMap { $0.isGIF ? animatedGIF($0.data) : photo(data: $0.data) }
    }

    /// 当表情发：GIF 原样；其余缩到长边 512，有透明的存 PNG（存成 JPEG 透明的地方会变黑），没有的存 JPEG
    static func sticker(_ image: PastedImage) async -> PreparedMedia? {
        if image.isGIF { return animatedGIF(image.data) }
        guard let small = MediaCache.downsample(image.data, maxPixel: 512), let cgImage = small.cgImage else { return nil }
        let alphaKinds: [CGImageAlphaInfo] = [.first, .last, .premultipliedFirst, .premultipliedLast]
        let png = alphaKinds.contains(cgImage.alphaInfo)
        guard let data = png ? small.pngData() : small.jpegData(compressionQuality: 0.85) else { return nil }
        let url = tempURL(png ? "png" : "jpg")
        do { try data.write(to: url) } catch { return nil }
        return PreparedMedia(
            localId: "local-\(UUID().uuidString)",
            fileURL: url,
            filename: png ? "sticker.png" : "sticker.jpg",
            meta: UploadMeta(kind: "image", mime: png ? "image/png" : "image/jpeg", width: cgImage.width, height: cgImage.height),
            thumbnail: nil,
            preview: small
        )
    }

    private static func loadData(_ provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    /// 相册给的临时文件在回调结束后会被删，先拷一份
    private static func loadFile(_ provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                let copy = tempURL(url.pathExtension.isEmpty ? "mov" : url.pathExtension)
                do {
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: copy)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

/// 重新编码视频：长边不超过 1280，H.264 约 2Mbps，AAC 96kbps。
/// HDR 素材通过视频合成转成普通色域（BT.709），不然在别的设备上颜色发灰；moov 放在文件头，方便边下边播。
enum VideoTranscoder {
    static let maxSide: CGFloat = 1280
    static let videoBitrate = 2_000_000
    static let audioBitrate = 96_000

    enum Failure: Error {
        case setup, reading, writing
    }

    /// 返回输出画面的尺寸（已经转正）
    static func transcode(_ asset: AVAsset, to output: URL) async throws -> CGSize {
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw Failure.setup }
        let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        let source = composition.renderSize
        let scale = min(1, maxSide / max(source.width, source.height, 1))
        let size = CGSize(width: even(source.width * scale), height: even(source.height * scale))

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        )
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw Failure.setup }
        reader.add(videoOutput)

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw Failure.setup }
        writer.add(videoInput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        var audioInput: AVAssetWriterInput?
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: audioBitrate,
            ])
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(output), writer.canAdd(input) {
                reader.add(output)
                writer.add(input)
                audioOutput = output
                audioInput = input
            }
        }

        guard reader.startReading() else { throw reader.error ?? Failure.reading }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error ?? Failure.writing
        }
        writer.startSession(atSourceTime: .zero)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await VideoTranscoder.pump(videoOutput, into: videoInput, label: "video") }
            if let audioOutput, let audioInput {
                group.addTask { await VideoTranscoder.pump(audioOutput, into: audioInput, label: "audio") }
            }
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? Failure.reading
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure.writing }
        return size
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        max(2, (value / 2).rounded(.down) * 2)
    }

    /// 把读出来的样本一直喂给写入端，读完或写失败就结束这一路
    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, label: String) async {
        let queue = DispatchQueue(label: "whisper.transcode.\(label)")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer(), input.append(sample) else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }
}
