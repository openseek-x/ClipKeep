import AppKit

/// 程序化构建标准主菜单，让文本输入控件通过 responder chain 获得编辑快捷键。
@MainActor
enum AppMenu {
    static func install() {
        NSApp.mainMenu = make()
    }

    static func make() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "ClipKeep")
        appMenu.addItem(item("退出 ClipKeep", action: #selector(NSApplication.terminate(_:)),
                              key: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(item("撤销", action: Selector(("undo:")), key: "z"))
        let redo = item("重做", action: Selector(("redo:")), key: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(item("剪切", action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(item("复制", action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(item("粘贴", action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(item("全选", action: #selector(NSText.selectAll(_:)), key: "a"))
        editItem.submenu = editMenu
        main.addItem(editItem)

        return main
    }

    private static func item(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        // nil 让 AppKit 从当前 first responder 开始查找 paste:/copy: 等实现。
        item.target = nil
        return item
    }
}
