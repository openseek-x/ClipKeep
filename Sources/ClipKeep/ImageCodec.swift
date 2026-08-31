import AppKit
import CryptoKit
import Foundation
import ImageIO

/// 剪贴板图片的读取与编码。
///
/// 剪贴板中的图片是未压缩 TIFF：实测一张 2880×1800 Retina 截图为 158MB。
/// 直接落库会让几张截图吃掉数 GB，因此必须重编码为 PNG（实测压缩约 97 倍）。
enum ImageCodec {

    /// 原图 PNG 超过此字节数时按长边反复缩放。
    /// 取 2MB：实测 2880×1800 Retina 截图重编码后仅 93KB，正常截图远不会触发；
    /// 该阈值只用于拦截不可压缩的病态图像。
    static let maxImageBytes = 2 * 1024 * 1024
    /// 缩放起始长边像素。
    static let maxLongEdge: CGFloat = 2048
    /// 缩放下限长边像素。缩到此值仍超限则放弃记录。
    static let minLongEdge: CGFloat = 256
    /// 缩放尝试次数上限，防止极端输入下无限循环。
    static let maxScaleAttempts = 5
    /// 列表缩略图长边像素。
    static let thumbnailLongEdge: CGFloat = 240
    /// 缩略图字节上限。超出则降低尺寸重编码，避免噪点图产生 140KB 缩略图。
    static let maxThumbnailBytes = 24 * 1024

    /// 发送给 AI 的副本限制。图片历史仍保留原有入库质量，只有上传副本会缩小。
    static let aiUploadMaxLongEdge = 2_048
    static let aiUploadMaxBytes = 2 * 1024 * 1024
    /// 拒绝异常巨大的源像素网格，避免缩略解码本身消耗失控。
    private static let aiUploadMaxSourcePixels: Int64 = 100_000_000

    struct Encoded {
        let png: Data
        let thumbnail: Data
        let pixelWidth: Int
        let pixelHeight: Int
        /// PNG 字节的 SHA-256，作为去重键。
        let hash: String
    }

    struct AIUpload: Sendable {
        let png: Data
        let pixelWidth: Int
        let pixelHeight: Int
    }

    /// 为多模态请求生成受限 PNG 副本。
    ///
    /// 使用 ImageIO 的缩略解码路径，不先把超大源图完整展开到内存；重新编码会移除
    /// 原 PNG 中可能存在的附加元数据。返回 nil 时调用方不得上传原始字节兜底。
    static func prepareAIUpload(pngData sourcePNG: Data) -> AIUpload? {
        guard !Task.isCancelled, !sourcePNG.isEmpty,
              let source = CGImageSourceCreateWithData(sourcePNG as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }
        let sourceWidth = width.int64Value
        let sourceHeight = height.int64Value
        guard sourceWidth > 0, sourceHeight > 0,
              sourceWidth <= aiUploadMaxSourcePixels / sourceHeight else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: aiUploadMaxLongEdge,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        guard !Task.isCancelled else { return nil }
        var rep = NSBitmapImageRep(cgImage: cgImage)
        guard var png = pngData(from: rep) else { return nil }

        // 不可压缩图像即使尺寸受限仍可能超过 2MB，逐级缩小直至满足上传硬上限。
        var attempts = 0
        while png.count > aiUploadMaxBytes && max(rep.pixelsWide, rep.pixelsHigh) > 256
                && attempts < maxScaleAttempts {
            guard !Task.isCancelled else { return nil }
            let target = NSSize(width: max(1, CGFloat(rep.pixelsWide) / 2),
                                height: max(1, CGFloat(rep.pixelsHigh) / 2))
            guard let smaller = resized(rep, to: target), let data = pngData(from: smaller) else {
                return nil
            }
            rep = smaller
            png = data
            attempts += 1
        }
        guard !Task.isCancelled, png.count <= aiUploadMaxBytes else { return nil }
        return AIUpload(png: png, pixelWidth: rep.pixelsWide, pixelHeight: rep.pixelsHigh)
    }

    /// 从 TIFF 字节编码出入库所需的 PNG、缩略图与尺寸。
    ///
    /// 只接受 TIFF 输入：实测剪贴板图片仅提供 `public.tiff`，`public.png` 返回 nil。
    /// 返回 nil 表示无法解码或即使缩到下限仍超限，调用方应跳过该条。
    static func encode(tiffData: Data) -> Encoded? {
        guard let rep = NSBitmapImageRep(data: tiffData) else { return nil }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 0, h > 0 else { return nil }

        guard var png = pngData(from: rep) else { return nil }
        var outW = w, outH = h

        // 超限则反复按长边缩小直至入限。
        // 单次缩放不足以保证达标：实测 2600×2600 不可压缩噪点图缩到 2048 后
        // PNG 仍有 13.8MB，因此必须循环收敛而非缩一次就放弃。
        if png.count > maxImageBytes {
            var longEdge = min(maxLongEdge, CGFloat(max(w, h)))
            var attempts = 0
            while png.count > maxImageBytes && longEdge >= minLongEdge && attempts < maxScaleAttempts {
                let scale = longEdge / CGFloat(max(w, h))
                let target = NSSize(width: CGFloat(w) * scale, height: CGFloat(h) * scale)
                guard let scaled = resized(rep, to: target),
                      let d = pngData(from: scaled) else { return nil }
                png = d
                outW = scaled.pixelsWide
                outH = scaled.pixelsHigh
                longEdge /= 2
                attempts += 1
            }
            // 缩到下限仍超限说明是极端病态图像，放弃记录，避免拖垮数据库。
            if png.count > maxImageBytes { return nil }
        }

        guard var thumb = encodedThumbnail(rep, width: w, height: h) else { return nil }
        // 噪点类图像的缩略图也可能偏大（实测达 140KB），逐级减半直至入限。
        var thumbEdge = thumbnailLongEdge
        var thumbAttempts = 0
        while thumb.count > maxThumbnailBytes && thumbEdge > 48 && thumbAttempts < maxScaleAttempts {
            thumbEdge /= 2
            guard let smaller = encodedThumbnail(rep, width: w, height: h,
                                                 longEdge: thumbEdge) else { break }
            thumb = smaller
            thumbAttempts += 1
        }

        let hash = SHA256.hash(data: png).compactMap { String(format: "%02x", $0) }.joined()
        return Encoded(png: png, thumbnail: thumb,
                       pixelWidth: outW, pixelHeight: outH, hash: hash)
    }

    /// 按指定长边生成缩略图 PNG 字节。
    private static func encodedThumbnail(_ rep: NSBitmapImageRep, width: Int, height: Int,
                                         longEdge: CGFloat = thumbnailLongEdge) -> Data? {
        guard let r = resized(rep, to: thumbnailSize(width: width, height: height,
                                                     longEdge: longEdge)) else { return nil }
        return pngData(from: r)
    }

    /// 保持长宽比的缩略图目标尺寸。小图不放大。
    private static func thumbnailSize(width: Int, height: Int,
                                      longEdge: CGFloat = thumbnailLongEdge) -> NSSize {
        let long = CGFloat(max(width, height))
        guard long > longEdge else {
            return NSSize(width: width, height: height)
        }
        let scale = longEdge / long
        return NSSize(width: max(1, CGFloat(width) * scale),
                      height: max(1, CGFloat(height) * scale))
    }

    private static func pngData(from rep: NSBitmapImageRep) -> Data? {
        rep.representation(using: .png, properties: [:])
    }

    /// 将位图重绘到目标像素尺寸。
    ///
    /// 显式构造 `NSBitmapImageRep` 并设置 size 为像素数，避免 Retina 环境下
    /// `NSImage.lockFocus` 隐式按 backing scale 放大导致输出尺寸翻倍。
    private static func resized(_ rep: NSBitmapImageRep, to target: NSSize) -> NSBitmapImageRep? {
        let pw = Int(target.width.rounded()), ph = Int(target.height.rounded())
        guard pw > 0, ph > 0 else { return nil }
        guard let out = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        out.size = NSSize(width: pw, height: ph)

        guard let ctx = NSGraphicsContext(bitmapImageRep: out) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        rep.draw(in: NSRect(x: 0, y: 0, width: pw, height: ph),
                 from: .zero, operation: .copy, fraction: 1.0,
                 respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return out
    }
}
