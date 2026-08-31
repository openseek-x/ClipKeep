import Foundation

enum AIProviderKind: String, Codable, CaseIterable, Identifiable {
    case openAI
    case localCompatible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .localCompatible: return "本地 / OpenAI 兼容"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .localCompatible: return "http://127.0.0.1:11434/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: return "gpt-5.6-luna"
        case .localCompatible: return "qwen3-vl:4b"
        }
    }
}

struct AISettings: Codable, Equatable {
    var enabled = false
    var provider: AIProviderKind = .openAI
    var baseURL = AIProviderKind.openAI.defaultBaseURL
    var model = AIProviderKind.openAI.defaultModel
    var maxInputCharacters = 12_000
    var maxOutputTokens = 800
    var requestTimeoutSeconds = 45
    var customInstruction = ""

    func validated() -> AISettings {
        var settings = self
        settings.baseURL = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.maxInputCharacters = min(max(settings.maxInputCharacters, 500), 50_000)
        settings.maxOutputTokens = min(max(settings.maxOutputTokens, 64), 4_096)
        settings.requestTimeoutSeconds = min(max(settings.requestTimeoutSeconds, 5), 120)
        settings.customInstruction = String(settings.customInstruction.prefix(2_000))
        return settings
    }
}

enum AIAction: String, CaseIterable, Identifiable {
    case summarize
    case translateChinese
    case translateEnglish
    case polish
    case explain
    case extractTodos
    case recognizeImageText
    case describeImage
    case summarizeImage
    case translateImageChinese
    case translateImageEnglish
    case extractImageInfo
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summarize: return "总结"
        case .translateChinese: return "翻译成中文"
        case .translateEnglish: return "翻译成英文"
        case .polish: return "润色"
        case .explain: return "解释"
        case .extractTodos: return "提取待办"
        case .recognizeImageText: return "识别图片文字"
        case .describeImage: return "描述图片"
        case .summarizeImage: return "总结图片"
        case .translateImageChinese: return "翻译图片文字为中文"
        case .translateImageEnglish: return "翻译图片文字为英文"
        case .extractImageInfo: return "提取图片关键信息"
        case .custom: return "自定义指令"
        }
    }

    static let textActions: [AIAction] = [
        .summarize, .translateChinese, .translateEnglish, .polish, .explain, .extractTodos, .custom,
    ]

    static let imageActions: [AIAction] = [
        .recognizeImageText, .describeImage, .summarizeImage,
        .translateImageChinese, .translateImageEnglish, .extractImageInfo, .custom,
    ]

    func supports(_ kind: ClipKind) -> Bool {
        switch kind {
        case .text: return Self.textActions.contains(self)
        case .image: return Self.imageActions.contains(self)
        }
    }

    func instruction(customInstruction: String) -> String {
        switch self {
        case .summarize:
            return "用与输入相同的语言给出简洁、忠实的摘要，不添加输入中没有的事实。"
        case .translateChinese:
            return "把输入翻译成自然、准确的简体中文，保留段落、列表和代码格式，只返回译文。"
        case .translateEnglish:
            return "Translate the input into natural, accurate English. Preserve paragraphs, lists, and code formatting. Return only the translation."
        case .polish:
            return "在不改变含义和语言的前提下润色表达，修正语法和标点，只返回润色后的文本。"
        case .explain:
            return "清晰解释输入内容；必要时分点说明，并明确区分事实与推断。"
        case .extractTodos:
            return "提取明确或可合理推断的待办事项，使用 Markdown 清单；没有待办时明确说明。"
        case .recognizeImageText:
            return "准确识别图片中的可见文字，尽量保留段落、列表和表格结构；只返回识别结果。"
        case .describeImage:
            return "客观、清晰地描述图片中的主要内容、布局和重要细节；不确定的部分要明确说明。"
        case .summarizeImage:
            return "总结图片传达的核心信息；如果是截图、图表或文档，优先概括其内容和结论。"
        case .translateImageChinese:
            return "识别图片中的文字并翻译成自然、准确的简体中文，尽量保留原有结构，只返回译文。"
        case .translateImageEnglish:
            return "Recognize the visible text and translate it into natural, accurate English. Preserve the original structure where possible and return only the translation."
        case .extractImageInfo:
            return "从图片中提取关键事实、数字、日期、名称和待办事项，使用清晰的 Markdown 分点；不要编造不可见的信息。"
        case .custom:
            return customInstruction
        }
    }
}

enum AIInput {
    case text(String)
    case imagePNG(Data)

    var kind: ClipKind {
        switch self {
        case .text: return .text
        case .imagePNG: return .image
        }
    }
}

struct AIRequest {
    let action: AIAction
    let input: AIInput
    let instruction: String
    let model: String
    let maxOutputTokens: Int
    let timeout: TimeInterval
}

enum AIError: LocalizedError {
    case disabled
    case unsupportedAction
    case emptyInput
    case missingImageData
    case imagePreparationFailed
    case inputTooLong(limit: Int)
    case missingCustomInstruction
    case missingAPIKey
    case invalidBaseURL
    case insecureEndpoint
    case invalidModel
    case invalidResponse
    case emptyResponse
    case responseTooLarge
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .disabled: return "AI 功能尚未启用。"
        case .unsupportedAction: return "该 AI 操作不支持当前记录类型。"
        case .emptyInput: return "没有可处理的文本。"
        case .missingImageData: return "无法读取这条记录的完整图片。"
        case .imagePreparationFailed: return "无法生成安全的图片上传副本。"
        case .inputTooLong(let limit): return "文本超过 AI 输入上限（\(limit) 字符）。"
        case .missingCustomInstruction: return "请先在 AI 设置中填写自定义指令。"
        case .missingAPIKey: return "未找到 API Key，请在 AI 设置中保存。"
        case .invalidBaseURL: return "API Base URL 无效。"
        case .insecureEndpoint: return "远程 AI 服务必须使用 HTTPS；HTTP 仅允许本机回环地址。"
        case .invalidModel: return "模型名称不能为空。"
        case .invalidResponse: return "AI 服务返回了无法识别的响应。"
        case .emptyResponse: return "AI 服务没有返回文本。"
        case .responseTooLarge: return "AI 服务返回的数据超过客户端安全上限。"
        case .httpStatus(let status, let message):
            return message.isEmpty ? "AI 服务请求失败（HTTP \(status)）。"
                : "AI 服务请求失败（HTTP \(status)）：\(message)"
        }
    }
}

struct SensitiveDataFinding: Equatable, Identifiable {
    enum Severity: Int, Comparable {
        case medium
        case high

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id: String
    let label: String
    let severity: Severity
}

struct AIConfirmation: Equatable {
    let action: AIAction
    let findings: [SensitiveDataFinding]
    let message: String
    let confirmTitle: String
}

enum AIActionState: Equatable {
    case idle
    case preparing(action: AIAction)
    case confirmationRequired(AIConfirmation)
    case generating(action: AIAction, partial: String)
    case result(action: AIAction, text: String)
    case failed(String)

    var isVisible: Bool {
        if case .idle = self { return false }
        return true
    }
}
