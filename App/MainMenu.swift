import AppKit
import DesignSystem

/// The menu bar shown while one of Elodie's windows is in front. Its main job is to exist:
/// without Edit commands, ⌘V and friends don't work in any text field, and without Close,
/// neither does ⌘W.
@MainActor
enum MainMenu {
    static func make(controller: AppController) -> NSMenu {
        let bar = NSMenu()
        bar.addItem(submenu(appMenu(controller: controller), title: "Elodie"))
        bar.addItem(submenu(editMenu(), title: String(localized: "Edit")))
        let window = windowMenu()
        bar.addItem(submenu(window, title: String(localized: "Window")))
        NSApp.windowsMenu = window
        let help = helpMenu()
        bar.addItem(submenu(help, title: String(localized: "Help")))
        NSApp.helpMenu = help
        return bar
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        return item
    }

    private static func appMenu(controller: AppController) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "About Elodie"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let settings = ActionMenuItem(title: String(localized: "Settings…")) { [weak controller] in
            controller?.openSettings()
        }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Hide Elodie"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = menu.addItem(withTitle: String(localized: "Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: String(localized: "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Elodie"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ActionMenuItem(title: String(localized: "Elodie Privacy Policy")) {
            NSWorkspace.shared.open(ElodieLinks.privacyPolicy)
        })
        menu.addItem(ActionMenuItem(title: String(localized: "Elodie Support")) {
            NSWorkspace.shared.open(ElodieLinks.support)
        })
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        return menu
    }
}
