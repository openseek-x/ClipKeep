import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var store: ClipStore?
    private var monitor: ClipboardMonitor?
    private var hotKey = HotKeyManager()
    private var panelController: HistoryPanelController?
    private var model: HistoryViewModel?
    private var statusItem: NSStatusItem?
    private var retentionTimer: Timer?
    private var settings = Settings()

    /// 保留策略执行间隔：每小时一次，另在启动时执行一次。
    private static let retentionInterval: TimeInterval = 3600

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = SettingsStore.load()

        do {
            store = try ClipStore(dbPath: SettingsStore.databasePath)
        } catch ClipStore.StoreError.rebuiltAfterCorruption(let backup) {
            // 库损坏已自动重建，告知用户旧数据的备份位置而非静默丢弃。
            store = try? ClipStore(dbPath: SettingsStore.databasePath)
            notifyUser(title: "历史记录已重建",
                       body: "原数据库损坏，已备份到 \(backup)")
        } catch {
            presentFatal("无法打开历史数据库：\(error.localizedDescription)")
            return
        }
        guard let store else {
            presentFatal("无法打开历史数据库")
            return
        }

        let model = HistoryViewModel(store: store)
        self.model = model
        panelController = HistoryPanelController(model: model) { [weak self] item in
            self?.restore(item)
        }

        setupStatusItem()
        setupMonitor(store: store)
        setupHotKey()
        setupRetention(store: store)
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        retentionTimer?.invalidate()
        hotKey.unregister()
    }

    // MARK: - 剪贴板监听

    private func setupMonitor(store: ClipStore) {
        let m = ClipboardMonitor { [weak self] clip in
            guard let self else { return }
            // 用户关闭图片记录时直接丢弃，避免无谓的编码开销与磁盘占用。
            if clip.kind == .image && !self.settings.captureImages { return }
            do {
                try store.upsert(clip)
                self.model?.reloadIfVisible(self.panelController?.isVisible == true)
            } catch {
                NSLog("ClipKeep: 写入失败 \(error)")
            }
        }
        m.userBlocklist = settings.blockedSourcePrefixes
        m.start()
        monitor = m
    }

    // MARK: - 快捷键

    private func setupHotKey() {
        do {
            try hotKey.register(settings.shortcut) { [weak self] in
                self?.panelController?.toggle()
            }
        } catch HotKeyManager.HotKeyError.alreadyInUse {
            notifyUser(title: "快捷键被占用",
                       body: "\(settings.shortcut.displayName) 已被其他程序使用，请在设置中更换。")
        } catch {
            notifyUser(title: "快捷键注册失败",
                       body: "可在菜单栏图标中手动打开历史记录。")
        }
    }

    // MARK: - 回填剪贴板

    /// 把选中记录写回剪贴板。
    ///
    /// 只回填、不自动粘贴：自动粘贴需要辅助功能授权（等同模拟按键），
    /// 与本工具的零授权设计相悖。用户回到原位置按 Cmd+V 即可。
    private func restore(_ item: ClipItem) {
        guard let full = model?.fullItem(item) else { return }
        // 先登记，避免回填触发的 changeCount 变化被当成新复制重复记录。
        monitor?.willWriteToPasteboard()

        let pb = NSPasteboard.general
        pb.clearContents()
        switch full.kind {
        case .text:
            pb.setString(full.content, forType: .string)
        case .image:
            if let d = full.imageData, let img = NSImage(data: d) {
                pb.writeObjects([img])
            } else {
                notifyUser(title: "无法读取图片", body: "该记录的图片数据已损坏。")
            }
        }
    }

    // MARK: - 保留策略

    private func setupRetention(store: ClipStore) {
        runRetention(store: store)
        // Timer 回调是 nonisolated 的，显式跳回主 actor（本类状态均在主 actor 上）。
        let t = Timer(timeInterval: Self.retentionInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.runRetention(store: store)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        retentionTimer = t
    }

    private func runRetention(store: ClipStore) {
        do {
            try store.enforceRetention(maxTextItems: settings.maxTextItems,
                                       maxImageItems: settings.captureImages ? settings.maxImageItems : 0,
                                       maxAge: settings.maxAge)
        } catch {
            NSLog("ClipKeep: 清理失败 \(error)")
        }
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "doc.on.clipboard",
                                     accessibilityDescription: "ClipKeep 剪贴板历史")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(withTitle: "打开历史记录 \(settings.shortcut.displayName)",
                     action: #selector(openPanel), keyEquivalent: "")
        menu.addItem(.separator())

        let capture = NSMenuItem(title: "记录图片", action: #selector(toggleImages), keyEquivalent: "")
        capture.state = settings.captureImages ? .on : .off
        menu.addItem(capture)

        let login = NSMenuItem(title: "开机自动启动", action: #selector(toggleLaunchAtLogin),
                               keyEquivalent: "")
        login.state = isLaunchAtLoginEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(withTitle: "打开配置文件…", action: #selector(revealSettings), keyEquivalent: "")
        menu.addItem(withTitle: "清空历史（保留收藏）", action: #selector(clearHistory), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 ClipKeep", action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")

        for i in menu.items where i.action != nil && i.action != #selector(NSApplication.terminate(_:)) {
            i.target = self
        }
        item.menu = menu
        statusItem = item
    }

    @objc private func openPanel() { panelController?.show() }

    @objc private func toggleImages(_ sender: NSMenuItem) {
        settings.captureImages.toggle()
        sender.state = settings.captureImages ? .on : .off
        persistSettings()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let enable = !isLaunchAtLoginEnabled
        do {
            if enable { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            settings.launchAtLogin = enable
            persistSettings()
            sender.state = isLaunchAtLoginEnabled ? .on : .off
            if enable && SMAppService.mainApp.status == .requiresApproval {
                notifyUser(title: "需要在系统设置中批准",
                           body: "请在「登录项」中允许 ClipKeep 开机启动。")
            }
        } catch {
            notifyUser(title: "设置开机启动失败", body: error.localizedDescription)
        }
    }

    private var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func revealSettings() {
        try? SettingsStore.save(settings)   // 确保文件存在后再定位
        NSWorkspace.shared.selectFile(SettingsStore.settingsPath,
                                      inFileViewerRootedAtPath: SettingsStore.directory)
    }

    @objc private func clearHistory() {
        // 确认框会挤掉面板焦点，先抑制"失焦即关"。
        panelController?.suppressAutoClose(for: 60)
        let alert = NSAlert()
        alert.messageText = "清空剪贴板历史？"
        alert.informativeText = "收藏的记录会保留。此操作无法撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        // 弹确认框需要临时激活 app，否则窗口出现在后台无人可见。
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store?.clearAll(keepFavorites: true)
            model?.reload()
        } catch {
            notifyUser(title: "清空失败", body: error.localizedDescription)
        }
    }

    private func persistSettings() {
        do { try SettingsStore.save(settings) }
        catch { NSLog("ClipKeep: 保存设置失败 \(error)") }
        monitor?.userBlocklist = settings.blockedSourcePrefixes
    }

    // MARK: - 提示

    /// 用非阻塞的方式告知用户。
    ///
    /// 不用 UNUserNotificationCenter：它对未签名 app 常静默失败，且会引入通知权限请求，
    /// 与零授权目标冲突。改用菜单栏图标闪烁 + NSAlert 兜底。
    private func notifyUser(title: String, body: String) {
        // 弹窗会挤掉面板焦点，先抑制"失焦即关"避免面板被误关。
        panelController?.suppressAutoClose()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func presentFatal(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "ClipKeep 无法启动"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "退出")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        NSApp.terminate(nil)
    }
}

private extension HistoryViewModel {
    /// 仅在面板可见时刷新，避免后台无谓查询。
    func reloadIfVisible(_ visible: Bool) {
        guard visible else { return }
        reload()
    }
}

@main
struct ClipKeepMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // .accessory：常驻菜单栏，不出现在 Dock 与 Cmd+Tab 中。
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
