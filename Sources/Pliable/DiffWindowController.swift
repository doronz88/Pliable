import AppKit
import PliableCore

private let changeColumnID = NSUserInterfaceItemIdentifier("change")
private let pathColumnID = NSUserInterfaceItemIdentifier("path")
private let leftColumnID = NSUserInterfaceItemIdentifier("left")
private let rightColumnID = NSUserInterfaceItemIdentifier("right")

/// Calls back when a watched file is changed on disk (including atomic replacement).
private final class FileWatcher: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue.main
    private let onChange: () -> Void

    init(_ url: URL, onChange: @escaping () -> Void) {
        presentedItemURL = url
        self.onChange = onChange
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }

    func stop() { NSFileCoordinator.removeFilePresenter(self) }
    func presentedItemDidChange() { onChange() }
}

/// Lists the differences between a document (left) and another plist file (right).
/// Recomputes when either side changes. Selecting a row reveals it in the document's editor.
final class DiffWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let otherURL: URL
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private var entries: [PlistDiff.Entry] = []
    private var watcher: FileWatcher?
    private var refreshPending = false

    // `document` is only set once the document adds this controller; keep our own reference.
    private weak var plistDocument: PlistDocument?

    init(document: PlistDocument, otherURL: URL) {
        self.otherURL = otherURL
        plistDocument = document
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 420),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 480, height: 200)
        window.tabbingMode = .disallowed
        super.init(window: window)
        shouldCloseDocument = false
        window.delegate = self
        buildContent(documentName: document.displayName ?? "This Document")
        window.setFrameAutosaveName("PliableDiffWindow")
        if let host = document.editor?.view.window, !window.setFrameUsingName("PliableDiffWindow") {
            window.setFrameTopLeftPoint(NSPoint(x: host.frame.minX + 40, y: host.frame.maxY - 40))
        }
        NotificationCenter.default.addObserver(self, selector: #selector(documentChanged(_:)),
                                               name: PlistDocument.didChangeNotification, object: document)
        watcher = FileWatcher(otherURL) { [weak self] in self?.scheduleRefresh() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func windowTitle(forDocumentDisplayName displayName: String) -> String {
        "\(displayName) ↔ \(otherURL.lastPathComponent)"
    }

    func windowWillClose(_ notification: Notification) {
        watcher?.stop()
        watcher = nil
        NotificationCenter.default.removeObserver(self)
    }

    private func buildContent(documentName: String) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsMultipleSelection = false
        for (id, title, width) in [(changeColumnID, "Change", 80.0), (pathColumnID, "Key Path", 260.0),
                                   (leftColumnID, documentName, 240.0), (rightColumnID, otherURL.lastPathComponent, 240.0)] {
            let c = NSTableColumn(identifier: id)
            c.title = title
            c.width = width
            c.minWidth = 60
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table

        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.lineBreakMode = .byTruncatingMiddle

        let container = NSView()
        for v in [scroll, status] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            status.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            status.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        window?.contentView = container
    }

    // MARK: Refresh

    @objc private func documentChanged(_ n: Notification) { scheduleRefresh() }

    /// Coalesces bursts of edits into one recompute.
    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshPending = false
            self?.refresh()
        }
    }

    private func refresh() {
        guard let doc = plistDocument else { return }
        let other: PlistFile
        do {
            other = try PlistFile.read(Data(contentsOf: otherURL))
        } catch {
            entries = []
            table.reloadData()
            status.stringValue = "Can’t read \(otherURL.path): \(error.localizedDescription)"
            return
        }
        let selectedPath = table.selectedRow >= 0 && table.selectedRow < entries.count ? entries[table.selectedRow].path : nil
        entries = PlistDiff.diff(doc.root, other.root)
        table.reloadData()
        if let p = selectedPath, let i = entries.firstIndex(where: { $0.path == p }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        }
        status.stringValue = entries.isEmpty ? "The property lists are identical."
            : entries.count == 1 ? "1 difference" : "\(entries.count) differences"
        if doc.format != other.format, entries.isEmpty {
            status.stringValue += " (formats differ: \(doc.format.displayName) vs \(other.format.displayName))"
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    private func describe(_ n: PlistNode?) -> String {
        guard let n else { return "" }
        let v = ValueText.display(n)
        return n.isContainer ? "\(n.type.rawValue) \(v)" : "\(n.type.rawValue): \(v)"
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }
        let e = entries[row]
        let tf = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let t = NSTextField(labelWithString: "")
            t.identifier = id
            t.lineBreakMode = .byTruncatingTail
            t.cell?.usesSingleLineMode = true
            return t
        }()
        tf.textColor = .labelColor
        switch id {
        case changeColumnID:
            switch e.change {
            case .added: tf.stringValue = "Added"; tf.textColor = .systemGreen
            case .removed: tf.stringValue = "Removed"; tf.textColor = .systemRed
            case .changed: tf.stringValue = "Changed"; tf.textColor = .systemOrange
            }
        case pathColumnID: tf.stringValue = e.pathString
        case leftColumnID: tf.stringValue = describe(e.left)
        default: tf.stringValue = describe(e.right)
        }
        tf.toolTip = tf.stringValue
        return tf
    }

    #if DEBUG
    func debugSelect(row: Int) { table.selectRowIndexes([row], byExtendingSelection: false) }
    #endif

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row < entries.count, let doc = plistDocument, let editor = doc.editor else { return }
        // Reveal the node, or for keys only in the other file, its closest existing parent.
        var path = entries[row].path
        while doc.root.descendant(at: path) == nil, !path.isEmpty { path.removeLast() }
        if let n = doc.root.descendant(at: path) { editor.revealNode(n) }
    }
}
