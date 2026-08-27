import Foundation

/// 剪贴板条目类型。原始值直接持久化到 SQLite，新增类型只能追加，不可改动既有值。
enum ClipKind: String {
    case text
    case image
}

/// 一条剪贴板历史记录。
///
/// `content` 对文本是正文本身；对图片为空，图片字节存在 `imageData` / `thumbnailData`。
struct ClipItem {
    let id: Int64
    let kind: ClipKind
    /// 文本正文。图片条目为空串。
    let content: String
    /// 列表展示用的单行摘要，已折叠空白并截断。
    let preview: String
    /// 去重键：文本取正文 SHA-256，图片取 PNG 字节 SHA-256。
    let contentHash: String
    /// 来源 app 的 bundle identifier，取不到时为 nil。
    let sourceApp: String?
    let isFavorite: Bool
    let createdAt: Date
    let updatedAt: Date
    /// 图片原图 PNG 字节。文本条目为 nil；列表查询默认不加载。
    let imageData: Data?
    /// 图片缩略图 PNG 字节，用于列表渲染，避免解码原图。
    let thumbnailData: Data?
    /// 图片像素尺寸，用于展示 "800×600"。
    let pixelWidth: Int?
    let pixelHeight: Int?
}

/// 监听器捕获到的一次剪贴板变更，尚未写库。
struct CapturedClip {
    let kind: ClipKind
    let content: String
    let contentHash: String
    let sourceApp: String?
    let imageData: Data?
    let thumbnailData: Data?
    let pixelWidth: Int?
    let pixelHeight: Int?

    static func text(_ body: String, hash: String, sourceApp: String?) -> CapturedClip {
        CapturedClip(kind: .text, content: body, contentHash: hash, sourceApp: sourceApp,
                     imageData: nil, thumbnailData: nil, pixelWidth: nil, pixelHeight: nil)
    }
}
