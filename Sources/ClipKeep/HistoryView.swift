import AppKit
import SwiftUI

/// 历史面板的数据源与交互状态。
@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var query: String = "" {
        didSet { reload() }
    }
    @Published private(set) var items: [ClipItem] = []
    @Published var selectedIndex: Int = 0

    private let store: ClipStore
    /// 列表一次最多渲染的条数，防止无界读取。
    private let pageLimit = 200

    init(store: ClipStore) {
        self.store = store
    }

    func reload() {
        do {
            items = try store.recent(search: query, limit: pageLimit)
        } catch {
            items = []
            NSLog("ClipKeep: 读取历史失败 \(error)")
        }
        // 搜索后原选中项可能已不在结果内，夹取到有效范围。
        selectedIndex = items.isEmpty ? 0 : min(selectedIndex, items.count - 1)
    }

    var selected: ClipItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), items.count - 1)
    }

    func toggleFavorite(_ item: ClipItem) {
        do {
            try store.setFavorite(id: item.id, !item.isFavorite)
            reload()
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                selectedIndex = index
            }
        } catch { NSLog("ClipKeep: 收藏失败 \(error)") }
    }

    func delete(_ item: ClipItem) {
        do {
            try store.delete(id: item.id)
            reload()
        } catch { NSLog("ClipKeep: 删除失败 \(error)") }
    }

    /// 读取完整内容用于回填（列表中不含图片原图）。
    func fullItem(_ item: ClipItem) -> ClipItem? {
        do { return try store.fullItem(id: item.id) }
        catch {
            NSLog("ClipKeep: 读取完整记录失败 \(error)")
            return nil
        }
    }
}

/// 历史面板视图。
struct HistoryView: View {
    @ObservedObject var model: HistoryViewModel
    @ObservedObject var aiModel: AIActionViewModel
    /// 用户确认取用某条：回填剪贴板并关闭面板。
    var onPick: (ClipItem) -> Void
    var onClose: () -> Void
    var onConfigureAI: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if model.items.isEmpty {
                emptyState
            } else {
                list
            }
            if aiModel.state.isVisible {
                Divider()
                AIResultView(model: aiModel)
            }
            Divider()
            footer
        }
        // 不写死尺寸：窗口可缩放与全屏，交由 NSHostingView 按窗口实际大小布局。
        // minSize 由 HistoryPanelController 在窗口层面约束。
        .frame(minWidth: 380, maxWidth: .infinity,
               minHeight: 260, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            ClipKeepSearchField(text: Binding(
                get: { model.query },
                set: { model.query = $0 }
            ), onMoveUp: { model.moveSelection(-1) },
               onMoveDown: { model.moveSelection(1) },
               onConfirm: {
                   guard !aiModel.state.isVisible else { return }
                   if let s = model.selected { onPick(s) }
               },
               onCancel: onClose)
        }
        // 标题栏透明且隐藏标题，左上角三枚窗口按钮会浮在内容之上，
        // 故左侧留出其宽度，避免遮住搜索图标与输入内容。
        .padding(.leading, 76)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(model.query.isEmpty ? "还没有复制记录" : "没有匹配的记录")
                .foregroundStyle(.secondary)
            if model.query.isEmpty {
                Text("复制任何内容后会自动出现在这里")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { idx, item in
                        HistoryRow(
                            item: item,
                            isSelected: idx == model.selectedIndex,
                            aiEnabled: aiModel.isEnabled,
                            aiActions: item.kind == .text
                                ? AIAction.textActions : AIAction.imageActions,
                            onPick: { model.selectedIndex = idx; onPick(item) },
                            onAI: { model.selectedIndex = idx; performAI($0, on: item) },
                            onConfigureAI: { model.selectedIndex = idx; onConfigureAI() },
                            onToggleFavorite: {
                                model.selectedIndex = idx
                                model.toggleFavorite(item)
                            },
                            onDelete: { model.selectedIndex = idx; model.delete(item) }
                        )
                            .id(item.id)
                            .contentShape(Rectangle())
                            .contextMenu {
                                Menu("AI 处理") {
                                    if aiModel.isEnabled {
                                        ForEach(item.kind == .text
                                                ? AIAction.textActions : AIAction.imageActions) { action in
                                            Button(action.title) { performAI(action, on: item) }
                                        }
                                    } else {
                                        Button("配置 AI…") { onConfigureAI() }
                                    }
                                }
                                Button(item.isFavorite ? "取消收藏" : "收藏") {
                                    model.toggleFavorite(item)
                                }
                                Button("删除", role: .destructive) { model.delete(item) }
                            }
                    }
                }
            }
            // 单参数 onChange：双参数形式需要 macOS 14，此处保持 13.0 兼容。
            .onChange(of: model.selectedIndex) { new in
                guard model.items.indices.contains(new) else { return }
                proxy.scrollTo(model.items[new].id, anchor: .center)
            }
        }
    }

    private func performAI(_ action: AIAction, on item: ClipItem) {
        let target = item.kind == .image ? (model.fullItem(item) ?? item) : item
        aiModel.perform(action, on: target)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if !aiModel.state.isVisible {
                hint("↑↓", "选择")
                hint("↩", "复制")
            }
            hint("esc", "关闭")
            Spacer()
            Text("\(model.items.count) 条")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(.quaternary))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct AIResultView: View {
    @ObservedObject var model: AIActionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.state {
            case .idle:
                EmptyView()
            case .preparing(let action):
                header(title: action.title, icon: "photo.badge.magnifyingglass", color: .accentColor)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在本地准备图片并扫描可见文字…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("取消") { model.cancel() }
            case .confirmationRequired(let confirmation):
                header(title: confirmation.action.title,
                       icon: "exclamationmark.triangle.fill", color: .orange)
                Text(confirmation.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("取消") { model.dismiss() }
                    Button(confirmation.confirmTitle) { model.confirmPendingRequest() }
                }
            case .generating(let action, let partial):
                header(title: action.title, icon: "sparkles", color: .accentColor)
                if partial.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在生成…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    output(partial)
                }
                Button("取消") { model.cancel() }
            case .result(let action, let text):
                header(title: action.title, icon: "sparkles", color: .accentColor)
                output(text)
                HStack {
                    Button("复制结果") { model.copyResult() }
                    Button("保存到历史") { model.saveResult() }
                    Spacer()
                    Button("关闭") { model.dismiss() }
                }
            case .failed(let message):
                header(title: "AI 处理失败", icon: "exclamationmark.circle", color: .red)
                Text(message).font(.caption).foregroundStyle(.secondary)
                Button("关闭") { model.dismiss() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func header(title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(title).font(.system(size: 12, weight: .semibold))
            Spacer()
        }
    }

    private func output(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 150)
    }
}

/// 单行记录。
private struct HistoryRow: View {
    let item: ClipItem
    let isSelected: Bool
    let aiEnabled: Bool
    let aiActions: [AIAction]
    let onPick: () -> Void
    let onAI: (AIAction) -> Void
    let onConfigureAI: () -> Void
    let onToggleFavorite: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.preview.isEmpty ? "（空）" : item.preview)
                        .lineLimit(2)
                        .font(.system(size: 12))
                    HStack(spacing: 6) {
                        Text(relativeTime)
                        if let app = shortAppName { Text("·"); Text(app) }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onPick)

            actionButtons
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .onHover { isHovered = $0 }
    }

    private var showsActions: Bool { isHovered || isSelected }

    private var actionButtons: some View {
        HStack(spacing: 2) {
            Menu {
                if aiEnabled {
                    ForEach(aiActions) { action in
                        Button(action.title) { onAI(action) }
                    }
                } else {
                    Button("配置 AI…", action: onConfigureAI)
                }
            } label: {
                actionIcon("sparkles", color: .accentColor)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24, height: 24)
            .opacity(showsActions ? 1 : 0)
            .allowsHitTesting(showsActions)
            .disabled(!showsActions)
            .accessibilityHidden(!showsActions)
            .accessibilityLabel("AI 处理")
            .help("AI 处理")

            Button(action: onToggleFavorite) {
                actionIcon(item.isFavorite ? "star.fill" : "star",
                           color: item.isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .opacity(showsActions || item.isFavorite ? 1 : 0)
            .allowsHitTesting(showsActions || item.isFavorite)
            .disabled(!showsActions && !item.isFavorite)
            .accessibilityHidden(!showsActions && !item.isFavorite)
            .accessibilityLabel(item.isFavorite ? "取消收藏" : "收藏")
            .help(item.isFavorite ? "取消收藏" : "收藏")

            Button(action: onDelete) {
                actionIcon("trash", color: .secondary)
            }
            .buttonStyle(.plain)
            .opacity(showsActions ? 1 : 0)
            .allowsHitTesting(showsActions)
            .disabled(!showsActions)
            .accessibilityHidden(!showsActions)
            .accessibilityLabel("删除")
            .help("删除")
        }
        // 固定操作区宽度，悬停显隐不会让摘要文字左右跳动。
        .frame(width: 76, alignment: .trailing)
    }

    private func actionIcon(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        if item.kind == .image, let d = item.thumbnailData, let img = NSImage(data: d) {
            Image(nsImage: img)
                .resizable().aspectRatio(contentMode: .fill)
                .frame(width: 34, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Image(systemName: item.kind == .image ? "photo" : "text.alignleft")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 26)
        }
    }

    private var relativeTime: String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f.localizedString(for: item.updatedAt, relativeTo: Date())
    }

    /// bundle id 取末段作为简称，例如 com.apple.Safari → Safari。
    private var shortAppName: String? {
        guard let id = item.sourceApp, let last = id.split(separator: ".").last else { return nil }
        return String(last)
    }
}

/// 承载键盘导航的原生搜索框。
///
/// SwiftUI 的 TextField 无法拦截方向键与回车，且面板需要在不激活 app 的前提下
/// 接收键盘输入，故下沉到 NSTextField 处理。
struct ClipKeepSearchField: NSViewRepresentable {
    @Binding var text: String
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    var onConfirm: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.placeholderString = "搜索历史…"
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 13)
        f.delegate = context.coordinator
        f.cell?.sendsActionOnEndEditing = false
        return f
    }

    func updateNSView(_ view: NSTextField, context: Context) {
        if view.stringValue != text { view.stringValue = text }
        // 面板每次打开都要把焦点交回搜索框。
        if view.window?.firstResponder !== view.currentEditor() {
            view.window?.makeFirstResponder(view)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let parent: ClipKeepSearchField
        init(_ parent: ClipKeepSearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField else { return }
            parent.text = f.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):        parent.onMoveUp();  return true
            case #selector(NSResponder.moveDown(_:)):      parent.onMoveDown(); return true
            case #selector(NSResponder.insertNewline(_:)): parent.onConfirm(); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel(); return true
            default: return false
            }
        }
    }
}
