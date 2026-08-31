import Foundation
import ImageIO
import Vision

/// 用系统 Vision 在本地识别图片文字，仅用于上传前的敏感信息扫描。
///
/// OCR 不是安全边界：漏识别是可能的，因此图片即使未命中也必须由用户逐次确认上传。
enum ImageTextScanner {
    enum ScanError: Error {
        case invalidImage
    }

    private static let maxScannedCharacters = 50_000

    static func recognizedText(in pngData: Data) throws -> String {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ScanError.invalidImage
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        // 随机形态的 Token 不应被语言模型“纠正”为普通单词。
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        try Task.checkCancellation()
        let lines = (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first?.string
        }
        return String(lines.joined(separator: "\n").prefix(maxScannedCharacters))
    }
}
