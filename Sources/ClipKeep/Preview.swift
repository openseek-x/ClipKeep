import Foundation

/// 列表摘要与文本规范化。
enum Preview {
    /// 摘要最大字符数。超出部分截断并加省略号。
    static let maxPreviewChars = 120

    /// 折叠所有连续空白为单空格，去除首尾空白，再按字符数截断。
    ///
    /// 按 `Character` 截断而非 UTF-16 code unit，避免把 emoji 或组合字符切成两半。
    static func summary(for text: String) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if collapsed.count <= maxPreviewChars { return collapsed }
        return String(collapsed.prefix(maxPreviewChars)) + "…"
    }

    /// 判断文本是否只含空白（含全角空格等 Unicode 空白）。这类内容不入库。
    static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}
