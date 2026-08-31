import AppKit
import Foundation

@main
struct AIUnitTests {
    private static var failures = 0
    private static var assertions = 0

    @MainActor
    static func main() async throws {
        testSettingsValidation()
        try testSettingsBackwardCompatibility()
        try testSettingsFirstSaveAndReplace()
        testEndpointPolicy()
        testSensitiveDataScanner()
        testActionMediaSupport()
        try testImageUploadPreparation()
        try testOpenAIRequestBody()
        try testOpenAIImageRequestBody()
        try testLocalRequestBody()
        try testLocalImageRequestBody()
        try testStreamingEvents()
        await testImageStateMachine()
        testAppMenu()

        guard failures == 0 else {
            print("AI tests failed: \(failures)")
            exit(1)
        }
        print("AI tests passed: \(assertions) assertions")
    }

    private static func testSettingsValidation() {
        var settings = AISettings()
        settings.maxInputCharacters = -1
        settings.maxOutputTokens = 99_999
        settings.requestTimeoutSeconds = 1
        settings.baseURL = "  https://api.openai.com/v1  "
        let validated = settings.validated()
        expect(validated.maxInputCharacters == 500, "clamps minimum input")
        expect(validated.maxOutputTokens == 4_096, "clamps maximum output")
        expect(validated.requestTimeoutSeconds == 5, "clamps minimum timeout")
        expect(validated.baseURL == "https://api.openai.com/v1", "trims base URL")
    }

    private static func testSettingsBackwardCompatibility() throws {
        let oldJSON = """
            {
              "maxTextItems": 200,
              "maxImageItems": 50,
              "maxAgeDays": 7,
              "captureImages": true,
              "hotKeyCode": 9,
              "hotKeyModifiers": 768,
              "blockedSourcePrefixes": [],
              "launchAtLogin": false
            }
            """
        let settings = try JSONDecoder().decode(Settings.self, from: Data(oldJSON.utf8))
        expect(settings.ai == nil, "old settings decode without AI key")
        expect(!settings.validated().aiSettings.enabled, "old settings keep AI disabled")
    }

    private static func testSettingsFirstSaveAndReplace() throws {
        let directory = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("clipkeep-settings-test-\(UUID().uuidString)")
        let path = (directory as NSString).appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(atPath: directory) }

        var settings = Settings()
        settings.ai = AISettings(enabled: true)
        try SettingsStore.save(settings, to: path)
        expect(FileManager.default.fileExists(atPath: path), "first settings save creates target")
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
               "settings file permission is 0600")

        settings.maxTextItems = 321
        try SettingsStore.save(settings, to: path)
        let decoded = try JSONDecoder().decode(Settings.self,
                                               from: Data(contentsOf: URL(fileURLWithPath: path)))
        expect(decoded.maxTextItems == 321, "existing settings are atomically replaced")
        expect(!FileManager.default.fileExists(atPath: path + ".tmp"),
               "settings replacement leaves no temp file")
    }

    private static func testEndpointPolicy() {
        expect((try? AIEndpointPolicy.validatedBaseURL("https://api.example.com/v1")) != nil,
               "allows HTTPS")
        expect((try? AIEndpointPolicy.validatedBaseURL("http://127.0.0.1:11434/v1")) != nil,
               "allows IPv4 loopback HTTP")
        expect((try? AIEndpointPolicy.validatedBaseURL("http://localhost:11434/v1")) != nil,
               "allows localhost HTTP")
        expect((try? AIEndpointPolicy.validatedBaseURL("http://api.example.com/v1")) == nil,
               "rejects remote HTTP")
        expect((try? AIEndpointPolicy.validatedBaseURL("https://user:pass@example.com/v1")) == nil,
               "rejects URL credentials")
        expect((try? AIEndpointPolicy.validatedBaseURL("https://example.com/v1?key=secret")) == nil,
               "rejects URL query secrets")
        let original = URL(string: "https://api.example.com/v1/responses")!
        expect(AIEndpointPolicy.isAllowedRedirect(from: original,
                                                  to: URL(string: "https://api.example.com/v2/responses")!),
               "allows same-origin redirect")
        expect(!AIEndpointPolicy.isAllowedRedirect(from: original,
                                                   to: URL(string: "https://other.example.com/v1/responses")!),
               "rejects cross-origin redirect")
        expect((try? AIEndpointPolicy.credentialScope(
            for: "https://API.example.com:443/v1")) == "https://api.example.com",
               "normalizes default HTTPS port in credential scope")
        expect((try? AIEndpointPolicy.credentialScope(
            for: "https://api.example.com:8443/v1")) == "https://api.example.com:8443",
               "keeps custom port in credential scope")
        expect((try? AIEndpointPolicy.credentialScope(
            for: "http://127.0.0.1:11434/v1")) == "http://127.0.0.1:11434",
               "scopes local credentials by port")
    }

    private static func testSensitiveDataScanner() {
        let keyFindings = SensitiveDataScanner.scan("-----BEGIN PRIVATE KEY-----\nabc")
        expect(keyFindings.contains { $0.id == "private-key" && $0.severity == .high },
               "detects private keys")
        let tokenFindings = SensitiveDataScanner.scan("token sk-test_123456789012345678901234")
        expect(tokenFindings.contains { $0.id == "openai-key" && $0.severity == .high },
               "detects API keys")
        let passwordFindings = SensitiveDataScanner.scan("password = correct-horse-battery")
        expect(passwordFindings.contains { $0.id == "password" && $0.severity == .medium },
               "marks password fields for confirmation")
        expect(SensitiveDataScanner.scan("请总结这段普通文本。").isEmpty,
               "does not flag ordinary text")
    }

    private static func testActionMediaSupport() {
        expect(AIAction.summarize.supports(.text), "text summary supports text")
        expect(!AIAction.summarize.supports(.image), "text summary rejects images")
        expect(AIAction.describeImage.supports(.image), "image description supports images")
        expect(!AIAction.describeImage.supports(.text), "image description rejects text")
        expect(AIAction.custom.supports(.text) && AIAction.custom.supports(.image),
               "custom action supports both media kinds")
    }

    private static func testImageUploadPreparation() throws {
        let source = try makePNG(width: 3_000, height: 1_200)
        let upload = ImageCodec.prepareAIUpload(pngData: source)
        expect(upload != nil, "prepares valid PNG for AI")
        expect(max(upload?.pixelWidth ?? 0, upload?.pixelHeight ?? 0)
               <= ImageCodec.aiUploadMaxLongEdge, "AI image long edge is bounded")
        expect((upload?.png.count ?? Int.max) <= ImageCodec.aiUploadMaxBytes,
               "AI image bytes are bounded")
        expect(upload?.pixelWidth == 2_048 && upload?.pixelHeight == 819,
               "AI image keeps aspect ratio")
        expect(ImageCodec.prepareAIUpload(pngData: Data()) == nil,
               "rejects empty image data")
    }

    private static func testOpenAIRequestBody() throws {
        let provider = OpenAIResponsesProvider(baseURL: URL(string: "https://api.openai.com/v1")!,
                                               apiKey: "test")
        let object = try jsonObject(provider.requestBody(for: sampleRequest))
        expect(object["store"] as? Bool == false, "OpenAI request disables storage")
        expect(object["stream"] as? Bool == true, "OpenAI request enables streaming")
        expect(object["tool_choice"] as? String == "none", "OpenAI request disables tools")
        expect(object["input"] as? String == "hello", "OpenAI request sends selected text only")
    }

    private static func testOpenAIImageRequestBody() throws {
        let provider = OpenAIResponsesProvider(baseURL: URL(string: "https://api.openai.com/v1")!,
                                               apiKey: "test")
        let object = try jsonObject(provider.requestBody(for: imageRequest))
        let input = object["input"] as? [[String: Any]]
        let content = input?.first?["content"] as? [[String: Any]]
        let image = content?.first { $0["type"] as? String == "input_image" }
        expect((image?["image_url"] as? String)?.hasPrefix("data:image/png;base64,") == true,
               "OpenAI image request uses PNG data URL")
        expect(image?["detail"] as? String == "high", "OpenAI image request uses high detail")
        expect(object["store"] as? Bool == false, "OpenAI image request disables storage")
    }

    private static func testLocalRequestBody() throws {
        let provider = LocalCompatibleProvider(baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
                                               apiKey: "")
        let object = try jsonObject(provider.requestBody(for: sampleRequest))
        expect(object["stream"] as? Bool == true, "local request enables streaming")
        expect(object["model"] as? String == "test-model", "local request uses configured model")
        let messages = object["messages"] as? [[String: Any]]
        expect(messages?.last?["content"] as? String == "hello",
               "local request sends selected text only")
    }

    private static func testLocalImageRequestBody() throws {
        let provider = LocalCompatibleProvider(baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
                                               apiKey: "")
        let object = try jsonObject(provider.requestBody(for: imageRequest))
        let messages = object["messages"] as? [[String: Any]]
        let content = messages?.last?["content"] as? [[String: Any]]
        let image = content?.first { $0["type"] as? String == "image_url" }
        let imageURL = image?["image_url"] as? [String: String]
        expect(imageURL?["url"]?.hasPrefix("data:image/png;base64,") == true,
               "local image request uses PNG data URL")
        expect(imageURL?["detail"] == "high", "local image request uses high detail")
        expect(object["stream"] as? Bool == true, "local image request enables streaming")
    }

    private static func testStreamingEvents() throws {
        let openAI = try OpenAIResponsesProvider.parseEvent(Data(
            #"{"type":"response.output_text.delta","delta":"你好"}"#.utf8))
        expect(delta(from: openAI) == "你好", "parses OpenAI response delta")

        let local = try LocalCompatibleProvider.parseEvent(Data(
            #"{"choices":[{"delta":{"content":"world"}}]}"#.utf8))
        expect(delta(from: local) == "world", "parses local chat delta")

        expect(throwsError {
            _ = try OpenAIResponsesProvider.parseEvent(Data(
                #"{"type":"error","error":{"message":"rate limited"}}"#.utf8))
        }, "surfaces OpenAI stream errors")

        expect(throwsError {
            _ = try LocalCompatibleProvider.parseEvent(Data(
                #"{"error":{"message":"model missing"}}"#.utf8))
        }, "surfaces local stream errors")
    }

    @MainActor
    private static func testImageStateMachine() async {
        let normal = makeActionModel(recognizedText: "ordinary screenshot")
        normal.perform(.describeImage, on: imageItem())
        await waitUntil { if case .confirmationRequired = normal.state { return true }; return false }
        if case .confirmationRequired(let confirmation) = normal.state {
            expect(confirmation.action == .describeImage, "image action requires confirmation")
            expect(confirmation.message.contains("api.openai.com"),
                   "image confirmation shows destination host")
            expect(confirmation.confirmTitle == "发送图片并处理",
                   "image confirmation has explicit upload command")
        } else {
            expect(false, "image action requires confirmation")
            expect(false, "image confirmation shows destination host")
            expect(false, "image confirmation has explicit upload command")
        }

        let highRisk = makeActionModel(
            recognizedText: "sk-test_123456789012345678901234")
        highRisk.perform(.describeImage, on: imageItem())
        await waitUntil { if case .failed = highRisk.state { return true }; return false }
        expect(failureMessage(highRisk.state)?.contains("已阻止发送") == true,
               "OCR high-risk secret blocks image upload")

        let mediumRisk = makeActionModel(recognizedText: "password=correct-horse-battery")
        mediumRisk.perform(.describeImage, on: imageItem())
        await waitUntil { if case .confirmationRequired = mediumRisk.state { return true }; return false }
        if case .confirmationRequired(let confirmation) = mediumRisk.state {
            expect(confirmation.findings.contains { $0.severity == .medium },
                   "OCR medium-risk text is included in confirmation")
            expect(confirmation.message.contains("疑似密码字段"),
                   "OCR confirmation names medium-risk finding")
        } else {
            expect(false, "OCR medium-risk text is included in confirmation")
            expect(false, "OCR confirmation names medium-risk finding")
        }

        let ocrFailure = makeActionModel(recognizer: { _ in
            throw ImageTextScanner.ScanError.invalidImage
        })
        ocrFailure.perform(.describeImage, on: imageItem())
        await waitUntil { if case .confirmationRequired = ocrFailure.state { return true }; return false }
        if case .confirmationRequired(let confirmation) = ocrFailure.state {
            expect(confirmation.message.contains("安全扫描未能完成"),
                   "OCR failure is disclosed before upload")
        } else {
            expect(false, "OCR failure is disclosed before upload")
        }

        let missing = makeActionModel(recognizedText: "")
        missing.perform(.describeImage, on: imageItem(data: nil))
        expect(failureMessage(missing.state)?.contains("完整图片") == true,
               "missing full image fails locally")

        let cancellable = makeActionModel(
            preparer: { _ in
                Thread.sleep(forTimeInterval: 0.15)
                guard !Task.isCancelled else { return nil }
                return ImageCodec.AIUpload(png: Data([1]), pixelWidth: 1, pixelHeight: 1)
            },
            recognizer: { _ in "" }
        )
        cancellable.perform(.describeImage, on: imageItem())
        cancellable.cancel()
        try? await Task.sleep(nanoseconds: 250_000_000)
        expect(cancellable.state == .idle, "cancelled image preparation cannot overwrite idle state")
    }

    @MainActor
    private static func testAppMenu() {
        let main = AppMenu.make()
        let edit = main.items.compactMap(\.submenu).first { $0.title == "编辑" }
        expect(edit != nil, "main menu contains Edit menu")
        let paste = edit?.items.first { $0.action == #selector(NSText.paste(_:)) }
        expect(paste?.keyEquivalent == "v", "Edit menu binds Command-V to paste")
        expect(paste?.keyEquivalentModifierMask.contains(.command) == true,
               "paste shortcut uses Command modifier")
        expect(paste?.target == nil, "paste command targets current responder")
        expect(edit?.items.contains { $0.action == #selector(NSText.copy(_:)) } == true,
               "Edit menu exposes copy command")
        expect(edit?.items.contains { $0.action == #selector(NSText.selectAll(_:)) } == true,
               "Edit menu exposes select-all command")
    }

    private static var sampleRequest: AIRequest {
        AIRequest(action: .summarize, input: .text("hello"), instruction: "summarize",
                  model: "test-model", maxOutputTokens: 128, timeout: 10)
    }

    private static var imageRequest: AIRequest {
        AIRequest(action: .describeImage, input: .imagePNG(Data([0, 1, 2, 3])),
                  instruction: "describe", model: "vision-model",
                  maxOutputTokens: 128, timeout: 10)
    }

    @MainActor
    private static func makeActionModel(
        recognizedText: String? = nil,
        preparer: @escaping AIActionViewModel.ImagePreparer = { _ in
            ImageCodec.AIUpload(png: Data([1]), pixelWidth: 320, pixelHeight: 180)
        },
        recognizer: AIActionViewModel.ImageTextRecognizer? = nil
    ) -> AIActionViewModel {
        let resolvedRecognizer: AIActionViewModel.ImageTextRecognizer = recognizer ?? { _ in
            recognizedText ?? ""
        }
        return AIActionViewModel(
            settings: AISettings(enabled: true),
            secretStore: SecretStore(),
            onCopyResult: { _ in },
            onSaveResult: { _ in },
            imagePreparer: preparer,
            imageTextRecognizer: resolvedRecognizer
        )
    }

    private static func imageItem(data: Data? = Data([1])) -> ClipItem {
        ClipItem(id: 1, kind: .image, content: "", preview: "[图片]",
                 contentHash: "hash", sourceApp: nil, isFavorite: false,
                 createdAt: Date(), updatedAt: Date(), imageData: data,
                 thumbnailData: nil, pixelWidth: 320, pixelHeight: 180)
    }

    @MainActor
    private static func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func failureMessage(_ state: AIActionState) -> String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    private static func makePNG(width: Int, height: Int) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw AIError.imagePreparationFailed
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw AIError.imagePreparationFailed
        }
        return data
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private static func delta(from result: StreamParseResult) -> String? {
        if case .delta(let value) = result { return value }
        return nil
    }

    private static func throwsError(_ body: () throws -> Void) -> Bool {
        do {
            try body()
            return false
        } catch {
            return true
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        assertions += 1
        if condition() {
            print("PASS: \(name)")
        } else {
            failures += 1
            print("FAIL: \(name)")
        }
    }
}
