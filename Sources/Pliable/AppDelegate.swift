import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = NSDocumentController.shared
        NSApp.mainMenu = buildMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if runDebugScript() { return }
        #endif
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
        file.addItem(.separator())
        file.addItem(item("Compare With…", #selector(PlistDocument.compareWith(_:)), "d", [.command, .shift]))

        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Delete", #selector(NSText.delete(_:))))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(.separator())
        let find = item("Find", nil)
        let findMenu = NSMenu(title: "Find")
        findMenu.addItem(item("Find…", #selector(PlistDocument.findItem(_:)), "f"))
        findMenu.addItem(item("Find Next", #selector(PlistDocument.findNext(_:)), "g"))
        findMenu.addItem(item("Find Previous", #selector(PlistDocument.findPrevious(_:)), "g", [.command, .shift]))
        find.submenu = findMenu
        edit.addItem(find)

        let itemMenu = NSMenu(title: "Item")
        itemMenu.addItem(item("Add Item", #selector(EditorViewController.addItem(_:)), "\r"))
        itemMenu.addItem(item("Duplicate", #selector(EditorViewController.duplicate(_:)), "d"))
        itemMenu.addItem(item("Delete Item", #selector(EditorViewController.deleteItems(_:)), "\u{8}"))
        itemMenu.addItem(item("Edit Value…", #selector(EditorViewController.editValue(_:)), "\r", [.command, .option]))
        itemMenu.addItem(.separator())
        itemMenu.addItem(item("Copy Key Path", #selector(EditorViewController.copyKeyPath(_:)), "c", [.command, .option]))
        itemMenu.addItem(item("Copy PlistBuddy Path", #selector(EditorViewController.copyPlistBuddyPath(_:))))
        itemMenu.addItem(.separator())
        itemMenu.addItem(item("Sort Keys", #selector(EditorViewController.sortKeys(_:))))
        itemMenu.addItem(item("Sort Keys Recursively", #selector(EditorViewController.sortKeysRecursively(_:))))
        itemMenu.addItem(.separator())
        itemMenu.addItem(item("Expand All", #selector(EditorViewController.expandAll(_:)), "\u{F703}", [.command, .option]))
        itemMenu.addItem(item("Collapse All", #selector(EditorViewController.collapseAll(_:)), "\u{F702}", [.command, .option]))
        itemMenu.addItem(.separator())
        itemMenu.addItem(item("Copy to Left Side", #selector(DiffWindowController.copyToLeft(_:)), "\u{F702}", [.command, .control]))
        itemMenu.addItem(item("Copy to Right Side", #selector(DiffWindowController.copyToRight(_:)), "\u{F703}", [.command, .control]))
        itemMenu.addItem(item("Make Left Side Match Right", #selector(DiffWindowController.makeLeftMatchRight(_:)), "\u{F702}", [.command, .control, .shift]))
        itemMenu.addItem(item("Make Right Side Match Left", #selector(DiffWindowController.makeRightMatchLeft(_:)), "\u{F703}", [.command, .control, .shift]))

        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(item("Show Key Names", #selector(EditorViewController.toggleKeyNames(_:)), "k", [.command, .option]))

        let window = NSMenu(title: "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = window

        for (title, menu) in [(name, appMenu), ("File", file), ("Edit", edit), ("Item", itemMenu), ("View", viewMenu), ("Window", window)] {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = menu
            main.addItem(top)
        }
        return main
    }

    #if DEBUG
    /// Debug builds only: drive the UI from the environment for non-interactive checks.
    /// PLIABLE_DEBUG_OPEN=<file> [PLIABLE_DEBUG_SEARCH=<text>] [PLIABLE_DEBUG_COMPARE=<file> [PLIABLE_DEBUG_DIFF_ROW=<n>] [PLIABLE_DEBUG_DIFF_STEP=<n>] [PLIABLE_DEBUG_DIFF_ONLY=1] [PLIABLE_DEBUG_DIFF_SELECT_ALL=1] [PLIABLE_DEBUG_DIFF_COPY=left|right] [PLIABLE_DEBUG_DIFF_MATCH=left|right] [PLIABLE_DEBUG_DIFF_DESELECT=1]] [PLIABLE_DEBUG_DROP=<file>] [PLIABLE_DEBUG_TAB=<file>] [PLIABLE_DEBUG_EDIT=1 [PLIABLE_DEBUG_TYPE=<text>] [PLIABLE_DEBUG_COMMIT=1]] [PLIABLE_DEBUG_SAVE=1] [PLIABLE_DEBUG_LOG_EDITED=1] [PLIABLE_DEBUG_EXPAND=1] [PLIABLE_DEBUG_SELECT=<key.path>] [PLIABLE_DEBUG_EDIT_VALUE=1] [PLIABLE_DEBUG_TYPE_FIRST=<text>] [PLIABLE_DEBUG_CMD_RETURN=1]
    private func runDebugScript() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let open = env["PLIABLE_DEBUG_OPEN"] else { return false }
        NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: open), display: true) { doc, _, _ in
            guard let doc = doc as? PlistDocument else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if env["PLIABLE_DEBUG_EXPAND"] != nil { doc.editor?.expandAll(nil) }
                if let q = env["PLIABLE_DEBUG_SEARCH"] { doc.editor?.debugSearch(q) }
                if let c = env["PLIABLE_DEBUG_COMPARE"] {
                    doc.compare(with: URL(fileURLWithPath: c)) { diff in
                        if env["PLIABLE_DEBUG_DIFF_ONLY"] != nil { diff.debugOnlyDifferences() }
                        if let r = env["PLIABLE_DEBUG_DIFF_ROW"].flatMap(Int.init) { diff.debugSelect(row: r) }
                        if let n = env["PLIABLE_DEBUG_DIFF_STEP"].flatMap(Int.init) { diff.debugStep(n) }
                        if env["PLIABLE_DEBUG_DIFF_SELECT_ALL"] != nil { diff.debugSelectAll() }
                        if let c = env["PLIABLE_DEBUG_DIFF_COPY"] { diff.debugCopy(toLeft: c == "left") }
                        if let m = env["PLIABLE_DEBUG_DIFF_MATCH"] { diff.debugMatch(left: m == "left") }
                        if env["PLIABLE_DEBUG_DIFF_DESELECT"] != nil { diff.debugDeselect() }
                    }
                }
                if let d = env["PLIABLE_DEBUG_DROP"] { doc.handleDroppedFile(URL(fileURLWithPath: d)) }
                if let t = env["PLIABLE_DEBUG_TAB"] { doc.openInNewTab(URL(fileURLWithPath: t)) }
                if let path = env["PLIABLE_DEBUG_SELECT"], let n = doc.root.descendant(at: path.split(separator: ".").map(String.init)) {
                    doc.editor?.revealNode(n)
                }
                if env["PLIABLE_DEBUG_CMD_RETURN"] != nil, let w = doc.editor?.view.window {
                    w.makeKeyAndOrderFront(nil)
                    if let t = env["PLIABLE_DEBUG_TYPE_FIRST"] {
                        doc.editor?.beginEditingSelectedRow()
                        (w.firstResponder as? NSTextView)?.insertText(t, replacementRange: NSRange(location: NSNotFound, length: 0))
                    }
                    // What the Add Item menu item (⌘↩) does: send its action up the responder chain from the focus.
                    // (Synthetic key events are dropped when the app can't become active, as in scripted runs.)
                    _ = w.firstResponder?.tryToPerform(#selector(EditorViewController.addItem(_:)), with: nil)
                }
                if env["PLIABLE_DEBUG_EDIT"] != nil {
                    doc.editor?.addItem(nil)
                    if let t = env["PLIABLE_DEBUG_TYPE"], let tv = doc.editor?.view.window?.firstResponder as? NSTextView {
                        tv.insertText(t, replacementRange: tv.selectedRange())
                    }
                    if env["PLIABLE_DEBUG_COMMIT"] != nil, let w = doc.editor?.view.window {
                        w.makeFirstResponder(w.contentView)
                    }
                }
                if env["PLIABLE_DEBUG_EDIT_VALUE"] != nil { doc.editor?.editValue(nil) }
                if env["PLIABLE_DEBUG_SAVE"] != nil, let url = doc.fileURL, let type = doc.fileType {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        doc.save(to: url, ofType: type, for: .saveOperation) { _ in }
                    }
                }
                if env["PLIABLE_DEBUG_LOG_EDITED"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        let w = doc.editor?.view.window
                        NSLog("DEBUGEDITED doc=%d window=%d title=%@ subtitle=%@", doc.isDocumentEdited ? 1 : 0,
                              (w?.isDocumentEdited ?? false) ? 1 : 0, w?.title ?? "", w?.subtitle ?? "")
                    }
                }
            }
        }
        return true
    }
    #endif
}
