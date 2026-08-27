import AppKit
import Carbon.HIToolbox

/// 全局快捷键注册。
///
/// 使用 Carbon `RegisterEventHotKey`：实测无需辅助功能或输入监听授权
/// （注册成功时 `AXIsProcessTrusted()` 仍为 false）。改用 CGEventTap 虽更灵活，
/// 但需要"输入监听"权限（等同全局键盘记录），不符合零授权目标。
///
/// 注意：注册后该组合键会被拦截，不再传递给前台 app。因此绝不能注册 Cmd+C
/// 这类工具自身依赖的按键。
final class HotKeyManager {

    /// 快捷键定义。`keyCode` 为 Carbon 虚拟键码，`modifiers` 为 Carbon 修饰位。
    struct Shortcut: Equatable {
        var keyCode: UInt32
        var modifiers: UInt32

        /// 默认：Cmd+Shift+V。实测注册返回 noErr，且不占用 Option+V 的 √ 字符输入。
        static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_V),
                                        modifiers: UInt32(cmdKey | shiftKey))

        /// 人类可读描述，用于偏好设置展示。
        var displayName: String {
            var s = ""
            if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
            if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
            if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
            if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
            s += Self.keyName(keyCode)
            return s
        }

        static func keyName(_ code: UInt32) -> String {
            let map: [UInt32: String] = [
                UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
                UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
                UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
                UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
                UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
                UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
                UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
                UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
                UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
                UInt32(kVK_Space): "Space",
            ]
            return map[code] ?? "Key\(code)"
        }
    }

    enum HotKeyError: Error {
        /// 该组合已被系统或其他 app 占用。
        case alreadyInUse(status: OSStatus)
        case registrationFailed(status: OSStatus)
    }

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onTrigger: (() -> Void)?
    /// Carbon 回调是 C 函数指针，无法捕获 self，通过该表按 id 查回实例。
    private static var instances: [UInt32: HotKeyManager] = [:]
    private static var nextID: UInt32 = 1
    private let id: UInt32

    /// 四字符签名，用于区分本 app 的热键事件。
    private static let signature: OSType = 0x434C4950  // 'CLIP'

    init() {
        self.id = Self.nextID
        Self.nextID += 1
    }

    deinit {
        unregister()
    }

    /// 注册快捷键。重复调用会先注销旧的。
    func register(_ shortcut: Shortcut, onTrigger: @escaping () -> Void) throws {
        unregister()
        self.onTrigger = onTrigger
        Self.instances[id] = self

        try installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID,
                                        GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Self.instances[id] = nil
            // -9878 = eventHotKeyExistsErr：组合已被占用，调用方应提示用户改键。
            if status == -9878 { throw HotKeyError.alreadyInUse(status: status) }
            throw HotKeyError.registrationFailed(status: status)
        }
        hotKeyRef = ref
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        Self.instances[id] = nil
    }

    private func installHandlerIfNeeded() throws {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, _ in
            var hkID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard err == noErr, hkID.signature == HotKeyManager.signature else { return noErr }
            // 回调在主线程的事件循环中触发，可直接调用 UI 代码。
            HotKeyManager.instances[hkID.id]?.onTrigger?()
            return noErr
        }
        var ref: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), callback,
                                        1, &spec, nil, &ref)
        guard status == noErr else { throw HotKeyError.registrationFailed(status: status) }
        handlerRef = ref
    }
}
