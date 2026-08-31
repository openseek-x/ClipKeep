import AppKit
import SwiftUI

@MainActor
final class AISettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var viewModel: AISettingsViewModel?
    private let secretStore: SecretStore
    private let onSave: (AISettings) -> Void
    private let onClose: () -> Void

    init(secretStore: SecretStore, onSave: @escaping (AISettings) -> Void,
         onClose: @escaping () -> Void) {
        self.secretStore = secretStore
        self.onSave = onSave
        self.onClose = onClose
        super.init()
    }

    func show(settings: AISettings) {
        let viewModel = AISettingsViewModel(settings: settings, secretStore: secretStore,
                                            onSave: { [weak self] saved in
            self?.onSave(saved)
            self?.window?.close()
        }, onCancel: { [weak self] in self?.window?.close() })
        self.viewModel = viewModel

        let root = AISettingsView(model: viewModel)
        let window = self.window ?? makeWindow()
        window.contentView = NSHostingView(rootView: root)
        self.window = window
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        viewModel = nil
        onClose()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 590),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ClipKeep AI 设置"
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }
}

@MainActor
private final class AISettingsViewModel: ObservableObject {
    @Published var settings: AISettings
    @Published var apiKey = ""
    @Published var errorMessage: String?
    private var loadedCredentialScope: String?

    private let secretStore: SecretStore
    private let onSave: (AISettings) -> Void
    private let onCancel: () -> Void

    init(settings: AISettings, secretStore: SecretStore,
         onSave: @escaping (AISettings) -> Void,
         onCancel: @escaping () -> Void) {
        self.settings = settings.validated()
        self.secretStore = secretStore
        self.onSave = onSave
        self.onCancel = onCancel
        loadAPIKey()
    }

    func selectProvider(_ provider: AIProviderKind) {
        guard provider != settings.provider else { return }
        settings.provider = provider
        settings.baseURL = provider.defaultBaseURL
        settings.model = provider.defaultModel
        loadAPIKey()
    }

    func updateBaseURL(_ value: String) {
        settings.baseURL = value
        let newScope = try? AIEndpointPolicy.credentialScope(for: value)
        guard newScope != loadedCredentialScope else { return }
        if newScope == nil {
            apiKey = ""
            loadedCredentialScope = nil
        } else {
            loadAPIKey()
        }
    }

    func save() {
        do {
            let validated = settings.validated()
            _ = try AIEndpointPolicy.validatedBaseURL(validated.baseURL)
            guard !validated.model.isEmpty else { throw AIError.invalidModel }
            if validated.enabled && validated.provider == .openAI && apiKey
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw AIError.missingAPIKey
            }
            try secretStore.saveAPIKey(apiKey, for: validated.provider,
                                       baseURL: validated.baseURL)
            errorMessage = nil
            onSave(validated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancel() { onCancel() }

    private func loadAPIKey() {
        do {
            apiKey = try secretStore.apiKey(for: settings.provider,
                                            baseURL: settings.baseURL)
            loadedCredentialScope = try AIEndpointPolicy.credentialScope(for: settings.baseURL)
            errorMessage = nil
        } catch {
            apiKey = ""
            loadedCredentialScope = nil
            errorMessage = error.localizedDescription
        }
    }
}

private struct AISettingsView: View {
    @ObservedObject var model: AISettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("启用 AI 功能", isOn: $model.settings.enabled)
                .font(.headline)

            Picker("服务", selection: Binding(
                get: { model.settings.provider },
                set: { model.selectProvider($0) }
            )) {
                ForEach(AIProviderKind.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)

            Group {
                labeledField("API Base URL") {
                    TextField("https://api.example.com/v1", text: Binding(
                        get: { model.settings.baseURL },
                        set: { model.updateBaseURL($0) }
                    ))
                }
                labeledField("文本 / 视觉模型") {
                    TextField("需支持图片输入才能处理图片", text: $model.settings.model)
                }
                labeledField(model.settings.provider == .openAI ? "API Key" : "API Key（可选）") {
                    SecureField("保存在 macOS 钥匙串", text: $model.apiKey)
                }
            }

            HStack(spacing: 16) {
                Stepper("输入上限：\(model.settings.maxInputCharacters) 字符",
                        value: $model.settings.maxInputCharacters, in: 500...50_000, step: 500)
                Stepper("输出上限：\(model.settings.maxOutputTokens) tokens",
                        value: $model.settings.maxOutputTokens, in: 64...4_096, step: 64)
            }
            .font(.caption)

            labeledField("自定义指令") {
                TextEditor(text: $model.settings.customInstruction)
                    .font(.system(size: 12))
                    .frame(height: 80)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            }

            Text(privacyNotice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Spacer()
            HStack {
                Spacer()
                Button("取消") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { model.save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 550)
    }

    private var privacyNotice: String {
        if model.settings.provider == .openAI {
            return "只有你主动选择的文本或图片才会发送。图片会先在本地缩小并逐次确认。请求使用 store=false，但服务提供方仍可能按其数据政策执行安全扫描或保留安全日志。"
        }
        return "只有你主动选择的文本或图片才会发送。图片处理要求模型支持视觉输入。HTTP 仅允许 localhost/回环地址；远程兼容服务必须使用 HTTPS。"
    }

    private func labeledField<Content: View>(_ label: String,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content().textFieldStyle(.roundedBorder)
        }
    }
}
