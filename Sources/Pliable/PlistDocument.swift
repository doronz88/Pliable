import AppKit
import PliableCore

/// Holds the tree and performs every edit with undo registration.
@objc(PlistDocument)
final class PlistDocument: NSDocument {
    private(set) var root = PlistNode(kind: .dictionary)
    private(set) var format: PlistFormat = .xml
    private(set) var orderPreserved = true
    private var file = PlistFile(root: PlistNode(kind: .dictionary), format: .xml)

    enum Change {
        case row(PlistNode)          // the node's own row changed
        case children(PlistNode)     // the node's row and its children changed
        case format
    }
    var onChange: ((Change) -> Void)?
    static let didChangeNotification = Notification.Name("PliableDocumentDidChange")

    private func notify(_ c: Change) {
        onChange?(c)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    var editor: EditorViewController? {
        windowControllers.lazy.compactMap { $0.contentViewController as? EditorViewController }.first
    }

    override class var autosavesInPlace: Bool { false }

    override func makeWindowControllers() {
        let vc = EditorViewController(document: self)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.contentViewController = vc
        window.setContentSize(NSSize(width: 760, height: 560))
        window.toolbar = vc.makeToolbar()
        window.toolbarStyle = .unified
        window.tabbingIdentifier = "PliableDocument"
        let wc = NSWindowController(window: window)
        wc.shouldCascadeWindows = true
        addWindowController(wc)
        window.setFrameAutosaveName("PliableDocumentWindow")
        vc.updateSubtitle()
    }

    override func read(from data: Data, ofType typeName: String) throws {
        let f = try PlistFile.read(data)
        file = f
        root = f.root
        format = f.format
        orderPreserved = f.orderPreserved
        notify(.children(root))
        notify(.format)
    }

    override func data(ofType typeName: String) throws -> Data {
        var f = file
        f.root = root
        f.format = format
        do { return try f.write() } catch {
            throw NSError(domain: "Pliable", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The document could not be saved in the \(format.displayName) format.",
                NSLocalizedRecoverySuggestionErrorKey: error.localizedDescription,
            ])
        }
    }

    // MARK: Edits (each registers its own inverse)

    func setKey(_ node: PlistNode, _ key: String?) {
        let old = node.key
        undoManager?.registerUndo(withTarget: self) { $0.setKey(node, old) }
        node.key = key
        notify(.row(node))
    }

    func replaceContents(_ node: PlistNode, kind: PlistNode.Kind, children: [PlistNode], childKeys: [String?]) {
        let oldKind = node.kind
        let oldChildren = node.children
        let oldKeys = oldChildren.map(\.key)
        undoManager?.registerUndo(withTarget: self) { $0.replaceContents(node, kind: oldKind, children: oldChildren, childKeys: oldKeys) }
        node.kind = kind
        for (c, k) in zip(children, childKeys) { c.key = k }
        node.setChildren(children)
        notify(.children(node))
    }

    func insert(_ child: PlistNode, into parent: PlistNode, at index: Int) {
        undoManager?.registerUndo(withTarget: self) { $0.remove(from: parent, at: index) }
        parent.insertChild(child, at: index)
        notify(.children(parent))
    }

    func remove(from parent: PlistNode, at index: Int) {
        let child = parent.children[index]
        undoManager?.registerUndo(withTarget: self) { $0.insert(child, into: parent, at: index) }
        parent.removeChild(at: index)
        notify(.children(parent))
    }

    func setFormat(_ f: PlistFormat) {
        let old = format
        guard f != old else { return }
        undoManager?.registerUndo(withTarget: self) { $0.setFormat(old) }
        undoManager?.setActionName("Change Format")
        format = f
        notify(.format)
    }

    /// Returns an error message if the tree can't be saved in `f`.
    func problem(savingAs f: PlistFormat) -> String? {
        var copy = file
        copy.root = root
        copy.format = f
        do { _ = try copy.write(); return nil } catch { return error.localizedDescription }
    }

    // MARK: Find (the document is in the responder chain even when the toolbar search field has focus)

    @objc func findItem(_ sender: Any?) { editor?.beginSearch() }
    @objc func findNext(_ sender: Any?) { editor?.find(forward: true) }
    @objc func findPrevious(_ sender: Any?) { editor?.find(forward: false) }

    // MARK: Compare

    @objc func compareWith(_ sender: Any?) {
        guard let window = editor?.view.window else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose a property list to compare with “\(displayName ?? "this document")”."
        panel.prompt = "Compare"
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] r in
            guard let self, r == .OK, let url = panel.url else { return }
            self.compare(with: url)
        }
    }

    func compare(with url: URL) {
        do {
            _ = try PlistFile.read(Data(contentsOf: url))
        } catch {
            if let w = editor?.view.window {
                presentError(error, modalFor: w, delegate: nil, didPresent: nil, contextInfo: nil)
            } else {
                presentError(error)
            }
            return
        }
        let wc = DiffWindowController(document: self, otherURL: url)
        addWindowController(wc)
        wc.showWindow(nil)
    }

    /// Opens `url` as its own document in a new tab of this document's window.
    func openInNewTab(_ url: URL) {
        guard let host = editor?.view.window else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: false) { doc, alreadyOpen, error in
            if let error { NSApp.presentError(error); return }
            guard let doc else { return }
            if doc.windowControllers.isEmpty { doc.makeWindowControllers() }
            guard let w = (doc as? PlistDocument)?.editor?.view.window ?? doc.windowControllers.first?.window else { return }
            if !alreadyOpen, w !== host { host.addTabbedWindow(w, ordered: .above) }
            w.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: Files dropped onto the window

    func handleDroppedFile(_ url: URL) {
        guard let window = editor?.view.window else { return }
        if url.standardizedFileURL == fileURL?.standardizedFileURL { NSSound.beep(); return }
        do {
            _ = try PlistFile.read(Data(contentsOf: url))
        } catch {
            let a = NSAlert()
            a.messageText = "“\(url.lastPathComponent)” isn’t a property list Pliable can read."
            a.informativeText = error.localizedDescription
            a.beginSheetModal(for: window)
            return
        }
        let a = NSAlert()
        a.messageText = "What do you want to do with “\(url.lastPathComponent)”?"
        a.informativeText = "Open it in a new tab, or compare it with “\(displayName ?? "this document")”."
        a.addButton(withTitle: "Open in New Tab")
        a.addButton(withTitle: "Compare")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { [weak self] r in
            switch r {
            case .alertFirstButtonReturn: self?.openInNewTab(url)
            case .alertSecondButtonReturn: self?.compare(with: url)
            default: break
            }
        }
    }

    // MARK: Reload when the file changes on disk

    private var reloadPromptShown = false
    private var reloadScheduled = false

    override func presentedItemDidChange() {
        super.presentedItemDidChange()
        // Short delay so a writer that truncates and then writes is read once, complete.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.reloadScheduled else { return }
            self.reloadScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.reloadScheduled = false
                self.reloadIfChangedOnDisk()
            }
        }
    }

    private func reloadIfChangedOnDisk() {
        guard let url = fileURL, let type = fileType, !reloadPromptShown,
              let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              date != fileModificationDate else { return }
        guard isDocumentEdited else { reload(url, type); return }
        guard let window = editor?.view.window else { return }
        reloadPromptShown = true
        let a = NSAlert()
        a.messageText = "“\(displayName ?? url.lastPathComponent)” was changed by another application."
        a.informativeText = "Reloading discards your unsaved changes."
        a.addButton(withTitle: "Reload")
        a.addButton(withTitle: "Keep My Changes")
        a.beginSheetModal(for: window) { [weak self] r in
            guard let self else { return }
            self.reloadPromptShown = false
            if r == .alertFirstButtonReturn {
                self.reload(url, type)
            } else {
                // Don't ask again for this version of the file.
                self.fileModificationDate = date
            }
        }
    }

    private func reload(_ url: URL, _ type: String) {
        let ed = editor
        let state = ed?.captureViewState()
        do {
            try revert(toContentsOf: url, ofType: type)
        } catch {
            // Partially written or invalid file: keep what we have, retry on the next change.
            return
        }
        if let state { ed?.restoreViewState(state) }
    }
}
