import AppKit
import SwiftUI

/// 承载历史面板的浮动窗口。
///
/// 用 `NSPanel` + `.nonactivatingPanel`：面板出现时不激活 ClipKeep、不抢走前台 app 的
/// 焦点，用户取用记录后可直接在原位置按 Cmd+V。这是"不打断工作流"的关键。
///
/// 失焦行为：点击面板以外的区域即自动关闭（类似 Spotlight）。全屏是例外 —— 全屏
/// 占据独立 Space，失焦即关会让面板无法正常使用，故全屏时保持常驻。
///
/// 全屏行为：全屏需要独立 Space 且必然激活本 app，与"临时弹窗"语义冲突，
/// 因此全屏时切换为常驻模式（选取记录后不自动关闭），退出全屏恢复临时弹窗行为。
@MainActor
final class HistoryPanelController: NSObject, NSWindowDelegate {

    private var panel: NSPanel?
    private let model: HistoryViewModel
    private let aiModel: AIActionViewModel
    private let onPick: (ClipItem) -> Void
    private let onConfigureAI: () -> Void

    /// 非全屏时的面板尺寸，退出全屏后恢复。
    private static let defaultSize = NSSize(width: 520, height: 420)
    private static let minSize = NSSize(width: 380, height: 260)

    /// 常态层级。
    ///
    /// 用 `.statusBar`(25) 而非 `.floating`(3)：floating 只高于普通窗口，会被
    /// 其他工具的悬浮窗和全屏应用盖住。statusBar 高于所有普通应用窗口，
    /// 同时低于 `.popUpMenu`(101)，因此不会遮挡系统菜单与输入法候选框。
    private static let normalLevel: NSWindow.Level = .statusBar

    /// 常态 collectionBehavior。
    ///
    /// 顺序敏感：`canJoinAllSpaces` 与 `fullScreenPrimary` 存在互斥关系，
    /// 若 `fullScreenPrimary` 已在集合中再插入 `canJoinAllSpaces`，后者会被系统
    /// 静默丢弃（实测确认）。故必须在同一次赋值中一并给出。
    ///
    /// - canJoinAllSpaces: 切换桌面/Space 时面板跟随，不会留在原 Space
    /// - fullScreenAuxiliary: 其他 app 全屏时面板仍能浮在其上
    /// - fullScreenPrimary: 保留面板自身的全屏能力（绿色按钮）
    private static let normalBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .fullScreenAuxiliary, .fullScreenPrimary]

    /// 面板当前是否处于全屏。全屏下选取记录不关闭面板。
    private var isFullScreen = false

    /// 抑制"失焦即关"的截止时间。
    ///
    /// `.nonactivatingPanel` 在 `.accessory` app 中失焦时，AppKit 不暴露焦点去向：
    /// 实测 `NSApp.isActive`、`NSApp.keyWindow`、`isKeyWindow` 在"焦点转到本 app
    /// 其他窗口"与"焦点转到外部 app"两种情况下读数完全相同，无法区分。
    /// 全局鼠标监听（`addGlobalMonitorForEvents`）虽可注册但不投递事件 ——
    /// 实测需「输入监听」授权，与零授权目标冲突，故不采用。
    ///
    /// 因此改为由本 app 主动声明：凡是自己弹出的窗口（确认框、提示框）在展示前
    /// 调用 `suppressAutoClose()`，在该时间窗内忽略失焦事件。
    private var autoCloseSuppressedUntil: Date = .distantPast

    /// 本 app 主动弹窗前调用，避免面板被自己的弹窗挤掉焦点后误关。
    func suppressAutoClose(for seconds: TimeInterval = 1.5) {
        autoCloseSuppressedUntil = Date().addingTimeInterval(seconds)
    }

    func resumeAutoClose() {
        autoCloseSuppressedUntil = .distantPast
    }

    init(model: HistoryViewModel, aiModel: AIActionViewModel,
         onPick: @escaping (ClipItem) -> Void,
         onConfigureAI: @escaping () -> Void) {
        self.model = model
        self.aiModel = aiModel
        self.onPick = onPick
        self.onConfigureAI = onConfigureAI
        super.init()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 切换显示。已显示时再次按快捷键则关闭。
    func toggle() {
        if isVisible { close() } else { show() }
    }

    func show() {
        model.query = ""          // 每次打开重置搜索，直接看到最新历史
        model.selectedIndex = 0
        model.reload()

        let wasVisible = isVisible
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // 仅在从隐藏状态唤出时定位：
        // - 全屏下重定位会把窗口拽出全屏 Space
        // - 已可见时重定位会让用户手动摆好的位置被重置
        if !isFullScreen && !wasVisible {
            positionAtActiveScreenCenter(panel)
        }
        // 不激活 app，仅让面板成为 key window 以接收键盘。
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        aiModel.cancel()
        // 全屏窗口不能只 orderOut：会留下一个空的全屏 Space。先退出全屏再隐藏。
        if isFullScreen, let panel {
            panel.toggleFullScreen(nil)
            // 等全屏动画结束后再隐藏，否则 Space 不会被回收。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.panel?.orderOut(nil)
            }
            return
        }
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            // closable/miniaturizable/resizable 三者齐备，左上角才会显示完整的
            // 红黄绿三枚按钮；fullScreenPrimary 让绿色按钮执行全屏而非仅缩放。
            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                        .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = Self.normalLevel
        // 切换到其他 app 时不隐藏，面板保持可见。
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.delegate = self
        p.collectionBehavior = Self.normalBehavior
        p.minSize = Self.minSize
        // 面板需能成为 key window 才能接收键盘输入。
        p.becomesKeyOnlyIfNeeded = false

        let root = HistoryView(
            model: model,
            aiModel: aiModel,
            onPick: { [weak self] item in
                guard let self else { return }
                self.onPick(item)
                // 全屏是"常驻浏览"语义：选取后保持打开，便于连续取用多条。
                // 非全屏是临时弹窗，选完即关，立刻把焦点还给原 app。
                if !self.isFullScreen { self.close() }
            },
            onClose: { [weak self] in self?.close() },
            onConfigureAI: onConfigureAI
        )
        p.contentView = NSHostingView(rootView: root)
        return p
    }

    // MARK: - NSWindowDelegate

    /// 点红色关闭按钮时隐藏而非销毁，保留面板实例以便下次快捷键秒开。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    /// 失去键盘焦点即关闭，实现"点击面板外部自动关闭"。
    ///
    /// 三处例外，否则会误关：
    /// 1. 全屏：全屏占据独立 Space，失焦即关会让面板不可用（实测全屏切换本身
    ///    不触发 resignKey，此处为防御用户在全屏下切走又切回）。
    /// 2. 抑制窗口期内：本 app 自己弹出确认框/提示框时（见 `suppressAutoClose`）。
    /// 3. 焦点又回到面板自身：例如从菜单返回。
    func windowDidResignKey(_ notification: Notification) {
        guard !isFullScreen else { return }
        guard Date() >= autoCloseSuppressedUntil else { return }
        // 延后一拍执行：resignKey 触发时焦点转移尚未完成，立即判断会读到中间状态。
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            guard !self.isFullScreen else { return }
            guard Date() >= self.autoCloseSuppressedUntil else { return }
            // 焦点已回到面板自身，不关闭。
            if panel.isKeyWindow { return }
            self.close()
        }
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        isFullScreen = true
        // 全屏窗口必须回到普通层级：statusBar 层会盖住系统菜单栏，
        // 且在全屏 Space 中层级异常。退出全屏时恢复。
        panel?.level = .normal
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        isFullScreen = false
        panel?.level = Self.normalLevel
        // 全屏退出后系统给的尺寸不确定，显式恢复默认尺寸并重新居中。
        if let panel {
            panel.setContentSize(Self.defaultSize)
            positionAtActiveScreenCenter(panel)
        }
    }

    /// 显示在鼠标所在屏幕的中央偏上位置，多显示器下不会跑到另一块屏。
    private func positionAtActiveScreenCenter(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { panel.center(); return }
        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2 + frame.height * 0.08
        )
        panel.setFrameOrigin(origin)
    }
}
