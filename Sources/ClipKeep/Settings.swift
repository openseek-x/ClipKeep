import Foundation

/// 用户偏好。以 JSON 存于 Application Support，权限 0600。
///
/// 不用 UserDefaults 是为了让配置文件可直接查看与备份，也便于出问题时手工修复。
struct Settings: Codable, Equatable {

    /// 保留的文本条数上限。
    var maxTextItems: Int = 200
    /// 保留的图片条数上限。图片单条体积远大于文本，故独立计数。
    var maxImageItems: Int = 50
    /// 保留天数上限。与条数上限取先到者。
    var maxAgeDays: Int = 7
    /// 是否记录图片。
    var captureImages: Bool = true
    /// 快捷键键码与修饰键（Carbon 值）。
    var hotKeyCode: UInt32 = HotKeyManager.Shortcut.default.keyCode
    var hotKeyModifiers: UInt32 = HotKeyManager.Shortcut.default.modifiers
    /// 用户追加的来源 app 黑名单（bundle id 前缀）。
    var blockedSourcePrefixes: [String] = []
    /// 是否开机自启。
    var launchAtLogin: Bool = false
    /// AI 配置为可选字段，保证旧版 settings.json 缺少该键时仍可解码。
    var ai: AISettings? = nil

    var shortcut: HotKeyManager.Shortcut {
        HotKeyManager.Shortcut(keyCode: hotKeyCode, modifiers: hotKeyModifiers)
    }

    var maxAge: TimeInterval { TimeInterval(max(1, maxAgeDays) * 86_400) }

    /// 校验并夹取到合理区间，防止手工编辑写入极端值导致内存或磁盘失控。
    func validated() -> Settings {
        var s = self
        s.maxTextItems = min(max(s.maxTextItems, 10), 5_000)
        s.maxImageItems = min(max(s.maxImageItems, 0), 500)
        s.maxAgeDays = min(max(s.maxAgeDays, 1), 365)
        s.blockedSourcePrefixes = s.blockedSourcePrefixes
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // 空修饰键的热键会拦截裸按键，必定误伤正常输入，回退默认值。
        if s.hotKeyModifiers == 0 {
            s.hotKeyCode = HotKeyManager.Shortcut.default.keyCode
            s.hotKeyModifiers = HotKeyManager.Shortcut.default.modifiers
        }
        s.ai = (s.ai ?? AISettings()).validated()
        return s
    }

    var aiSettings: AISettings { (ai ?? AISettings()).validated() }
}

/// 偏好读写。
enum SettingsStore {

    static var directory: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("ClipKeep", isDirectory: true).path
    }

    static var settingsPath: String { (directory as NSString).appendingPathComponent("settings.json") }
    static var databasePath: String { (directory as NSString).appendingPathComponent("history.sqlite") }

    /// 读取偏好。文件缺失或损坏时返回默认值，不阻断启动。
    static func load() -> Settings {
        guard let data = FileManager.default.contents(atPath: settingsPath) else {
            return Settings()
        }
        guard let s = try? JSONDecoder().decode(Settings.self, from: data) else {
            // 损坏的配置不应让工具无法启动，直接用默认值覆盖。
            return Settings()
        }
        return s.validated()
    }

    static func save(_ settings: Settings) throws {
        try save(settings, to: settingsPath)
    }

    static func save(_ settings: Settings, to path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings.validated())
        // 原子写：先写临时文件再替换，避免崩溃留下半截 JSON。
        let tmp = path + ".tmp"
        try data.write(to: URL(fileURLWithPath: tmp), options: .atomic)
        if FileManager.default.fileExists(atPath: path) {
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path),
                                                       withItemAt: URL(fileURLWithPath: tmp))
        } else {
            try FileManager.default.moveItem(atPath: tmp, toPath: path)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: path)
    }
}

private extension FileManager {
    func contents(atPath path: String) -> Data? {
        guard fileExists(atPath: path) else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }
}
