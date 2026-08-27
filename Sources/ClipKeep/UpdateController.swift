import AppKit
import Sparkle

/// 自动更新。
///
/// 用 Sparkle 而非自研：更新是代码执行通道，自研验签、DMG 挂载、原子替换、
/// 进程接力等环节任一处出错都可能变成远程执行漏洞。Sparkle 是 macOS 事实标准，
/// 这些环节已被长期审计。
///
/// 安全模型：
/// - Sparkle 用 EdDSA(Ed25519) 验签更新包，公钥硬编码在 Info.plist 的 `SUPublicEDKey`。
///   私钥只在维护者的钥匙串中，绝不进仓库。即使 GitHub 账号被完全攻破，
///   攻击者没有私钥也无法让已安装的 ClipKeep 接受其构造的包。
/// - appcast 与 DMG 均通过 HTTPS 获取，`SUFeedURL` 固定指向本仓库。
/// - 实测确认：篡改 DMG 一个字节后 `sign_update --verify` 即拒绝。
///
/// 交互策略：自动检查但不静默安装。发现新版本时由 Sparkle 弹出标准更新面板，
/// 用户确认后才下载安装。剪贴板历史以明文存储，静默替换本机可执行代码的
/// 风险收益比不划算，故保留用户决定权。
@MainActor
final class UpdateController: NSObject {

    /// Sparkle 的标准控制器，负责检查、下载、验签、安装与 UI。
    private let controller: SPUStandardUpdaterController

    /// 更新面板即将出现时通知外部（用于抑制历史面板的"失焦即关"）。
    private let onWillShowUpdateUI: () -> Void

    /// SPUUpdater 的 delegate 为弱引用，需由本类持有。
    private let delegate: Delegate

    init(onWillShowUpdateUI: @escaping () -> Void) {
        self.onWillShowUpdateUI = onWillShowUpdateUI
        // 先构造 delegate 持有者再建 controller：SPUUpdater 的 delegate 是只读的，
        // 只能通过构造参数注入。
        let d = Delegate(onWillShowUpdateUI: onWillShowUpdateUI)
        self.delegate = d
        // startingUpdater: true 让 Sparkle 自行按 Info.plist 的配置调度检查。
        // userDriverDelegate 传 nil 使用 Sparkle 的标准更新面板。
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                 updaterDelegate: d,
                                                 userDriverDelegate: nil)
        super.init()
    }

    /// 用户从菜单栏主动触发检查。
    ///
    /// 与自动检查的区别：主动检查即使"已是最新"也会给出反馈，
    /// 而自动检查在无更新时保持静默。
    func checkForUpdates() {
        onWillShowUpdateUI()
        // 更新面板需要 app 处于前台才可见（本 app 平时是 .accessory 不激活）。
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// 当前是否允许自动检查，用于菜单项勾选状态。
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// 上次检查时间，用于菜单项展示。
    var lastUpdateCheckDate: Date? { controller.updater.lastUpdateCheckDate }
}

/// Sparkle 的 delegate 实现。
///
/// 单独成类而非让 `UpdateController` 直接实现：Sparkle 的回调是 nonisolated 的，
/// 而 `UpdateController` 标注了 `@MainActor`，两者混在一起需要大量
/// `assumeIsolated` 逃逸。分离后边界清晰。
private final class Delegate: NSObject, SPUUpdaterDelegate {

    private let onWillShowUpdateUI: () -> Void

    init(onWillShowUpdateUI: @escaping () -> Void) {
        self.onWillShowUpdateUI = onWillShowUpdateUI
        super.init()
    }

    /// Sparkle 即将展示更新面板时抑制历史面板自动关闭。
    func updater(_ updater: SPUUpdater, willShowUpdateAlert item: SUAppcastItem) {
        let cb = onWillShowUpdateUI
        Task { @MainActor in cb() }
    }

    /// 下载失败时仅记录日志。
    ///
    /// 不额外弹窗：网络不可用是常态，自动检查失败应静默；
    /// 用户主动检查时 Sparkle 的标准 driver 会自行提示。
    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem,
                 error: Error) {
        NSLog("ClipKeep: 更新下载失败 \(error.localizedDescription)")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // SUNoUpdateError 是"已是最新"的正常情形，不作为错误记录。
        let e = error as NSError
        if e.code == Int(SUError.noUpdateError.rawValue) { return }
        NSLog("ClipKeep: 更新检查中止 \(error.localizedDescription)")
    }
}
