import Foundation

@MainActor
final class AIActionViewModel: ObservableObject {
    typealias ImagePreparer = @Sendable (Data) -> ImageCodec.AIUpload?
    typealias ImageTextRecognizer = @Sendable (Data) throws -> String

    @Published private(set) var state: AIActionState = .idle
    @Published private(set) var settings: AISettings

    private struct PendingRequest {
        let action: AIAction
        let input: AIInput
    }

    private let secretStore: SecretStore
    private let onCopyResult: (String) -> Void
    private let onSaveResult: (String) -> Void
    private let imagePreparer: ImagePreparer
    private let imageTextRecognizer: ImageTextRecognizer
    private var pendingRequest: PendingRequest?
    private var generationTask: Task<Void, Never>?
    private var generationID: UUID?

    init(settings: AISettings, secretStore: SecretStore,
         onCopyResult: @escaping (String) -> Void,
         onSaveResult: @escaping (String) -> Void,
         imagePreparer: @escaping ImagePreparer = { ImageCodec.prepareAIUpload(pngData: $0) },
         imageTextRecognizer: @escaping ImageTextRecognizer = {
             try ImageTextScanner.recognizedText(in: $0)
         }) {
        self.settings = settings.validated()
        self.secretStore = secretStore
        self.onCopyResult = onCopyResult
        self.onSaveResult = onSaveResult
        self.imagePreparer = imagePreparer
        self.imageTextRecognizer = imageTextRecognizer
    }

    var isEnabled: Bool { settings.enabled }

    func update(settings: AISettings) {
        cancel()
        self.settings = settings.validated()
    }

    func perform(_ action: AIAction, on item: ClipItem) {
        guard settings.enabled else { state = .failed(AIError.disabled.localizedDescription); return }
        generationTask?.cancel()
        generationTask = nil
        generationID = nil
        pendingRequest = nil
        guard action.supports(item.kind) else {
            state = .failed(AIError.unsupportedAction.localizedDescription)
            return
        }
        if action == .custom && settings.customInstruction
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state = .failed(AIError.missingCustomInstruction.localizedDescription)
            return
        }
        switch item.kind {
        case .text:
            performText(action, text: item.content)
        case .image:
            prepareImage(action, item: item)
        }
    }

    private func performText(_ action: AIAction, text: String) {
        guard !text.isEmpty else { state = .failed(AIError.emptyInput.localizedDescription); return }
        guard text.count <= settings.maxInputCharacters else {
            state = .failed(AIError.inputTooLong(limit: settings.maxInputCharacters).localizedDescription)
            return
        }

        let findings = SensitiveDataScanner.scan(text)
        if let blocked = findings.first(where: { $0.severity == .high }) {
            state = .failed("检测到高风险敏感内容（\(blocked.label)），已阻止发送。")
            return
        }
        if !findings.isEmpty {
            pendingRequest = PendingRequest(action: action, input: .text(text))
            state = .confirmationRequired(AIConfirmation(
                action: action,
                findings: findings,
                message: "文本可能包含敏感信息。确认后将发送至 \(destinationLabel)。",
                confirmTitle: "仍然发送"
            ))
            return
        }
        generate(action: action, input: .text(text))
    }

    private func prepareImage(_ action: AIAction, item: ClipItem) {
        guard let imageData = item.imageData, !imageData.isEmpty else {
            state = .failed(AIError.missingImageData.localizedDescription)
            return
        }
        generationTask?.cancel()
        let preparationID = UUID()
        generationID = preparationID
        state = .preparing(action: action)
        generationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let imagePreparer = self.imagePreparer
                let imageTextRecognizer = self.imageTextRecognizer
                let worker = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    guard let upload = imagePreparer(imageData) else {
                        throw AIError.imagePreparationFailed
                    }
                    try Task.checkCancellation()
                    do {
                        let text = try imageTextRecognizer(upload.png)
                        try Task.checkCancellation()
                        return (upload, text, false)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return (upload, "", true)
                    }
                }
                let prepared = try await withTaskCancellationHandler(operation: {
                    try await worker.value
                }, onCancel: {
                    worker.cancel()
                })
                try Task.checkCancellation()
                guard self.generationID == preparationID else { throw CancellationError() }
                let upload = prepared.0
                let findings = SensitiveDataScanner.scan(prepared.1)
                if let blocked = findings.first(where: { $0.severity == .high }) {
                    state = .failed("图片文字中检测到高风险敏感内容（\(blocked.label)），已阻止发送。")
                } else {
                    pendingRequest = PendingRequest(action: action, input: .imagePNG(upload.png))
                    let dimensions = "\(upload.pixelWidth)×\(upload.pixelHeight)"
                    let size = ByteCountFormatter.string(fromByteCount: Int64(upload.png.count),
                                                         countStyle: .file)
                    var message = "将把 \(dimensions)、\(size) 的图片副本发送至 \(destinationLabel)。"
                    if prepared.2 {
                        message += " 本地文字安全扫描未能完成，请自行确认图片中没有密钥或密码。"
                    } else if !findings.isEmpty {
                        message += " 本地 OCR 可能识别到：\(findings.map(\.label).joined(separator: "、"))。"
                    }
                    state = .confirmationRequired(AIConfirmation(
                        action: action,
                        findings: findings,
                        message: message,
                        confirmTitle: "发送图片并处理"
                    ))
                }
            } catch is CancellationError {
                if self.generationID == preparationID { state = .idle }
            } catch {
                if self.generationID == preparationID { state = .failed(error.localizedDescription) }
            }
            if self.generationID == preparationID {
                self.generationID = nil
                generationTask = nil
            }
        }
    }

    func confirmPendingRequest() {
        guard let pendingRequest else { return }
        self.pendingRequest = nil
        generate(action: pendingRequest.action, input: pendingRequest.input)
    }

    func cancel() {
        generationTask?.cancel()
        generationTask = nil
        generationID = nil
        pendingRequest = nil
        state = .idle
    }

    func dismiss() {
        pendingRequest = nil
        generationTask?.cancel()
        generationTask = nil
        generationID = nil
        state = .idle
    }

    func copyResult() {
        guard case .result(_, let text) = state else { return }
        onCopyResult(text)
    }

    func saveResult() {
        guard case .result(_, let text) = state else { return }
        onSaveResult(text)
    }

    private var destinationLabel: String {
        let scope = (try? AIEndpointPolicy.credentialScope(for: settings.baseURL)) ?? "未知主机"
        return "\(settings.provider.displayName)（\(scope)）/ \(settings.model)"
    }

    private func generate(action: AIAction, input: AIInput) {
        generationTask?.cancel()
        let generationID = UUID()
        self.generationID = generationID
        let settings = self.settings
        let request = AIRequest(
            action: action,
            input: input,
            instruction: action.instruction(customInstruction: settings.customInstruction),
            model: settings.model,
            maxOutputTokens: settings.maxOutputTokens,
            timeout: TimeInterval(settings.requestTimeoutSeconds)
        )
        state = .generating(action: action, partial: "")
        generationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let apiKey = try secretStore.apiKey(for: settings.provider,
                                                    baseURL: settings.baseURL)
                let provider = try AIProviderFactory.make(settings: settings, apiKey: apiKey)
                var output = ""
                for try await delta in provider.stream(request) {
                    try Task.checkCancellation()
                    guard self.generationID == generationID else { throw CancellationError() }
                    output += delta
                    state = .generating(action: action, partial: output)
                }
                guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AIError.emptyResponse
                }
                guard self.generationID == generationID else { return }
                state = .result(action: action, text: output)
            } catch is CancellationError {
                if self.generationID == generationID { state = .idle }
            } catch {
                if self.generationID == generationID { state = .failed(error.localizedDescription) }
            }
            if self.generationID == generationID {
                self.generationID = nil
                generationTask = nil
            }
        }
    }
}
