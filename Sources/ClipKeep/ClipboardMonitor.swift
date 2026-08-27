import AppKit
import CryptoKit
import Foundation

/// 轮询剪贴板变更并交给回调入库。
///
/// macOS 不提供剪贴板变更通知，只能轮询 `NSPasteboard.changeCount`。
/// `changeCount` 未变时不读取内容，因此空闲开销仅为一次整数比较。
///
/// 已知竞态（实测确认）：写入方递增 `changeCount` 早于数据写入完成，
/// 首次读取可能返回 nil。对策是短重试，实测缓解后 6/6 成功。
final class ClipboardMonitor {

    /// 轮询间隔。0.3s 兼顾响应感与开销，与成熟剪贴板工具一致。
    static let pollInterval: TimeInterval = 0.3
    /// 读取空值时的重试次数。
    static let readRetries = 5
    /// 每次重试的等待时长。
    static let retryDelay: useconds_t = 15_000

    /// 文本长度上限。超出则截断入库，避免单条吃掉大量内存与磁盘。
    static let maxTextLength = 200_000

    private let pasteboard: NSPasteboard
    private let onCapture: (CapturedClip) -> Void
    /// 用户自定义的来源黑名单，由偏好设置注入。
    var userBlocklist: [String] = []

    private var timer: Timer?
    private var lastChangeCount: Int
    /// 本进程自己写入剪贴板时记录的 changeCount，用于跳过回填造成的自触发。
    private var selfWrittenChangeCount: Int = -1

    init(pasteboard: NSPasteboard = .general, onCapture: @escaping (CapturedClip) -> Void) {
        self.pasteboard = pasteboard
        self.onCapture = onCapture
        // 以当前值为基线，启动瞬间的剪贴板内容不入库，避免把启动前的内容误记为新复制。
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        stop()
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // 加入 common 模式，保证面板打开或菜单弹出时轮询不停摆。
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 通知监听器"接下来这次变更是本进程回填造成的，不要重复记录"。
    func willWriteToPasteboard() {
        // 回填后 changeCount 必然 +1，这里预登记下一个值。
        selfWrittenChangeCount = pasteboard.changeCount + 1
    }

    // MARK: - 轮询

    private func tick() {
        let cc = pasteboard.changeCount
        guard cc != lastChangeCount else { return }
        lastChangeCount = cc

        // 跳过本进程回填触发的变更，否则每次取用历史都会把该条重新写一遍。
        if cc == selfWrittenChangeCount {
            selfWrittenChangeCount = -1
            return
        }

        let types = pasteboard.types ?? []
        let source = frontmostBundleID()
        guard !PrivacyFilter.shouldSkip(types: types, sourceBundleID: source,
                                        userBlocklist: userBlocklist) else { return }

        if let clip = captureText(expecting: cc, source: source) {
            onCapture(clip)
        } else if let clip = captureImage(expecting: cc, source: source) {
            onCapture(clip)
        }
    }

    /// 读取文本，含针对写入竞态的短重试。
    ///
    /// 重试期间若 `changeCount` 再次变化，说明有更新的内容，放弃本轮
    /// （下一轮 tick 会处理新内容），避免把两次复制的数据混在一起。
    private func captureText(expecting cc: Int, source: String?) -> CapturedClip? {
        for attempt in 0..<Self.readRetries {
            if pasteboard.changeCount != cc { return nil }
            if let s = pasteboard.string(forType: .string) {
                guard !Preview.isBlank(s) else { return nil }
                let body = s.count > Self.maxTextLength
                    ? String(s.prefix(Self.maxTextLength))
                    : s
                let hash = SHA256.hash(data: Data(body.utf8))
                    .compactMap { String(format: "%02x", $0) }.joined()
                return .text(body, hash: hash, sourceApp: source)
            }
            if attempt < Self.readRetries - 1 { usleep(Self.retryDelay) }
        }
        return nil
    }

    /// 读取图片。剪贴板只提供未压缩 TIFF，交由 ImageCodec 重编码为 PNG。
    private func captureImage(expecting cc: Int, source: String?) -> CapturedClip? {
        for attempt in 0..<Self.readRetries {
            if pasteboard.changeCount != cc { return nil }
            if let tiff = pasteboard.data(forType: .tiff), !tiff.isEmpty {
                guard let e = ImageCodec.encode(tiffData: tiff) else { return nil }
                return CapturedClip(kind: .image, content: "", contentHash: e.hash,
                                    sourceApp: source, imageData: e.png,
                                    thumbnailData: e.thumbnail,
                                    pixelWidth: e.pixelWidth, pixelHeight: e.pixelHeight)
            }
            if attempt < Self.readRetries - 1 { usleep(Self.retryDelay) }
        }
        return nil
    }

    /// 取当前前台 app 的 bundle id 作为来源。
    ///
    /// 这是启发式判断：轮询发现变更时前台 app 通常仍是复制来源，但用户在
    /// 复制后立刻切换 app 时可能取到错误来源。来源仅用于黑名单与展示，
    /// 因此该误差可接受；密码过滤另有 ConcealedType 标记作为主判据。
    private func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
