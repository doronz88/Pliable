import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = NSDocumentController.shared
        NSApp.mainMenu = buildMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched without a file: show the Open panel instead of an empty window.
        DispatchQueue.main.async {
            if NSDocumentController.shared.documents.isEmpty {
                NSDocumentController.shared.openDocument(nil)
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSDocumentController.shared.openDocument(nil) }
        return false
    }

    // MARK: Default app

    /// True when Finder opens property lists with this app.
    private var isDefaultPlistEditor: Bool {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: .propertyList) else { return false }
        return Bundle(url: url)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    @objc func makeDefaultPlistEditor(_ sender: Any?) {
        // macOS shows its own confirmation dialog for this change.
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: .propertyList) { error in
            DispatchQueue.main.async {
                if let error = error as NSError? {
                    let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
                    if underlying?.code == userCanceledErr || error.code == userCanceledErr { return }
                    NSAlert(error: error).runModal()
                    return
                }
                let a = NSAlert()
                a.messageText = "Pliable is now the default app for property lists."
                a.runModal()
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(makeDefaultPlistEditor(_:)) {
            let isDefault = isDefaultPlistEditor
            menuItem.state = isDefault ? .on : .off
            return !isDefault
        }
        return true
    }

    private func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        return i
    }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        let name = "Pliable"

        let appMenu = NSMenu(title: name)
        appMenu.addItem(item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Make \(name) the Default Plist Editor", #selector(makeDefaultPlistEditor(_:))))
        appMenu.addItem(.separator())
        let services = item("Services", nil)
        services.submenu = NSMenu(title: "Services")
        NSApp.servicesMenu = services.submenu
        appMenu.addItem(services)
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"))
        appMenu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        appMenu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"))

        let file = NSMenu(title: "File")
        file.addItem(item("New", #selector(NSDocumentController.newDocument(_:)), "n"))
        file.addItem(item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"))
        let recent = item("Open Recent", nil)
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.addItem(item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:))))
        recent.submenu = recentMenu
        file.addItem(recent)
        file.addItem(.separator())
        file.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        file.addItem(item("Save", #selector(NSDocument.save(_:)), "s"))
        file.addItem(item("Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]))
        file.addItem(item("Revert to Saved", #selector(NSDocument.revertToSaved(_:))))

        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Delete", #selector(NSText.delete(_:))))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))

        let itemMenu = NSMenu(title: "Item")
        itemMenu.addItem(item("Add Item", #selector(EditorViewController.addItem(_:)), "\r"))
        itemMenu.addItem(item("Delete Item", #selector(EditorViewController.deleteItems(_:)), "\u{8}"))
        itemMenu.addItem(.separator())
        itemMenu.addItem(item("Expand All", #selector(EditorViewController.expandAll(_:)), "\u{F703}", [.command, .option]))
        itemMenu.addItem(item("Collapse All", #selector(EditorViewController.collapseAll(_:)), "\u{F702}", [.command, .option]))

        let window = NSMenu(title: "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = window

        for (title, menu) in [(name, appMenu), ("File", file), ("Edit", edit), ("Item", itemMenu), ("Window", window)] {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = menu
            main.addItem(top)
        }
        return main
    }
}
