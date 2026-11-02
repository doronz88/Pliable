import AppKit
import PliableCore

private let keyColumnID = NSUserInterfaceItemIdentifier("key")
private let leftTypeColumnID = NSUserInterfaceItemIdentifier("leftType")
private let leftValueColumnID = NSUserInterfaceItemIdentifier("leftValue")
private let rightTypeColumnID = NSUserInterfaceItemIdentifier("rightType")
private let rightValueColumnID = NSUserInterfaceItemIdentifier("rightValue")
private let cellID = NSUserInterfaceItemIdentifier("diffCell")
private let rowID = NSUserInterfaceItemIdentifier("diffRow")

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

/// Row view that tints its background by change kind.
private final class DiffRowView: NSTableRowView {
    var tint: NSColor? { didSet { needsDisplay = true } }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let tint else { return }
        tint.setFill()
        bounds.fill()
    }
}

/// Shows a document (left) and another plist file (right) side by side in one tree, rows aligned by key.
/// Rows only on the right are green, only on the left red, and different on both sides yellow;
/// matching rows keep normal colors. Recomputes when either side changes.
final class DiffWindowController: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSToolbarDelegate {
    private let otherURL: URL
    private let outline = NSOutlineView()
    private var tree: DiffNode?
    private var watcher: FileWatcher?
    private var refreshPending = false
    private var onlyDifferences = false
    private var onlyDiffButton: NSButton?
    private var navControl: NSSegmentedControl?
    private var readError: String?

    // `document` is only set once the document adds this controller; keep our own reference.
    private weak var plistDocument: PlistDocument?

    init(document: PlistDocument, otherURL: URL) {
        self.otherURL = otherURL
        plistDocument = document
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 600, height: 240)
        window.tabbingMode = .disallowed
        super.init(window: window)
        shouldCloseDocument = false
        window.delegate = self
        buildContent(leftName: document.displayName ?? "This Document")
        let tb = NSToolbar(identifier: "PliableDiffToolbar")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        window.toolbar = tb
        window.toolbarStyle = .unified
        window.setFrameAutosaveName("PliableDiffWindow2")
        if let host = document.editor?.view.window, !window.setFrameUsingName("PliableDiffWindow2") {
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

    private func buildContent(leftName: String) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        outline.style = .fullWidth
        outline.usesAlternatingRowBackgroundColors = true
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.gridStyleMask = .solidVerticalGridLineMask
        outline.indentationPerLevel = 14
        outline.allowsMultipleSelection = false
        let rightName = otherURL.lastPathComponent
        for (id, title, width) in [(keyColumnID, "Key", 230.0),
                                   (leftTypeColumnID, "Type", 70.0), (leftValueColumnID, leftName, 250.0),
                                   (rightTypeColumnID, "Type", 70.0), (rightValueColumnID, rightName, 250.0)] {
            let c = NSTableColumn(identifier: id)
            c.title = title
            c.width = width
            c.minWidth = 50
            if id == leftTypeColumnID || id == leftValueColumnID { c.headerToolTip = leftName }
            if id == rightTypeColumnID || id == rightValueColumnID { c.headerToolTip = otherURL.path }
            outline.addTableColumn(c)
        }
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.dataSource = self
        outline.delegate = self
        scroll.documentView = outline
        window?.contentView = scroll
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.layoutIfNeeded()
        outline.sizeLastColumnToFit()
    }

    // MARK: Toolbar

    private let onlyDiffID = NSToolbarItem.Identifier("onlyDifferences")
    private let navID = NSToolbarItem.Identifier("diffNav")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, onlyDiffID, navID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case onlyDiffID:
            let b = NSButton(checkboxWithTitle: "Only Differences", target: self, action: #selector(toggleOnlyDifferences(_:)))
            b.state = onlyDifferences ? .on : .off
            b.toolTip = "Hide rows that are the same in both files"
            onlyDiffButton = b
            item.view = b
            item.label = "Only Differences"
        case navID:
            let c = NSSegmentedControl(images: [
                NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous Difference")!,
                NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next Difference")!,
            ], trackingMode: .momentary, target: self, action: #selector(navClicked(_:)))
            c.setToolTip("Previous Difference (⇧⌘G)", forSegment: 0)
            c.setToolTip("Next Difference (⌘G)", forSegment: 1)
            c.isEnabled = tree?.hasDifferences == true
            navControl = c
            item.view = c
            item.label = "Previous / Next Difference"
        default:
            return nil
        }
        return item
    }

    @objc private func toggleOnlyDifferences(_ sender: NSButton) {
        let state = captureState()
        onlyDifferences = sender.state == .on
        reload(restoring: state)
    }

    @objc private func navClicked(_ sender: NSSegmentedControl) {
        step(forward: sender.selectedSegment == 1)
    }

    // ⌘G / ⇧⌘G in this window step through differences (this controller is ahead of the document in the responder chain).
    @objc func findNext(_ sender: Any?) { step(forward: true) }
    @objc func findPrevious(_ sender: Any?) { step(forward: false) }

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
        let first = tree == nil
        let state = captureState()
        do {
            let other = try PlistFile.read(Data(contentsOf: otherURL))
            tree = DiffNode.build(doc.root, other.root)
            readError = nil
        } catch {
            tree = nil
            readError = "Can’t read \(otherURL.lastPathComponent): \(error.localizedDescription)"
        }
        if first {
            reload(restoring: nil)
            expandDifferences()
            if let d = differences().first { select(d) }
        } else {
            reload(restoring: state)
        }
        updateStatus()
    }

    private func updateStatus() {
        guard let tree else {
            window?.subtitle = readError ?? ""
            navControl?.isEnabled = false
            return
        }
        var added = 0, removed = 0, changed = 0
        for d in differences() {
            switch d.change {
            case .added?: added += 1
            case .removed?: removed += 1
            case .changed?: changed += 1
            case nil: break
            }
        }
        var parts: [String] = []
        if changed > 0 { parts.append("\(changed) changed") }
        if added > 0 { parts.append("\(added) added") }
        if removed > 0 { parts.append("\(removed) removed") }
        window?.subtitle = parts.isEmpty ? "The property lists are identical" : parts.joined(separator: " · ")
        navControl?.isEnabled = tree.hasDifferences
    }

    // MARK: Expansion and selection (kept across recomputes by path)

    private struct State {
        var expanded: Set<[String]>
        var selected: [String]?
    }

    private func captureState() -> State {
        var expanded = Set<[String]>()
        for r in 0..<outline.numberOfRows {
            if let n = outline.item(atRow: r) as? DiffNode, outline.isItemExpanded(n) { expanded.insert(n.path) }
        }
        let sel = outline.selectedRow >= 0 ? (outline.item(atRow: outline.selectedRow) as? DiffNode)?.path : nil
        return State(expanded: expanded, selected: sel)
    }

    private func reload(restoring state: State?) {
        outline.reloadData()
        guard let tree else { return }
        outline.expandItem(tree)
        guard let state else { return }
        func expand(_ n: DiffNode) {
            guard state.expanded.contains(n.path) else { return }
            outline.expandItem(n)
            visibleChildren(n).forEach(expand)
        }
        visibleChildren(tree).forEach(expand)
        if let p = state.selected, let n = find(p, in: tree) {
            let row = outline.row(forItem: n)
            if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
        }
    }

    private func expandDifferences() {
        func walk(_ n: DiffNode) {
            guard n.hasDifferences, !n.children.isEmpty else { return }
            outline.expandItem(n)
            visibleChildren(n).forEach(walk)
        }
        if let tree { walk(tree) }
    }

    private func find(_ path: [String], in root: DiffNode) -> DiffNode? {
        var n = root
        for c in path {
            guard let next = visibleChildren(n).first(where: { $0.component == c }) else { return nil }
            n = next
        }
        return n
    }

    // MARK: Difference navigation

    /// Top-most differing rows in display order (children of an added/removed/changed row are not listed again).
    private func differences() -> [DiffNode] {
        var out: [DiffNode] = []
        func walk(_ n: DiffNode) {
            if n.change != nil { out.append(n); return }
            n.children.forEach(walk)
        }
        tree?.children.forEach(walk)
        return out
    }

    private func preorder() -> [DiffNode] {
        var out: [DiffNode] = []
        func walk(_ n: DiffNode) { out.append(n); visibleChildren(n).forEach(walk) }
        if let tree { walk(tree) }
        return out
    }

    private func step(forward: Bool) {
        let diffs = differences()
        guard !diffs.isEmpty else { NSSound.beep(); return }
        let order = preorder()
        let pos = { (d: DiffNode) in order.firstIndex { $0 === d } ?? 0 }
        let current = outline.selectedRow >= 0 ? (outline.item(atRow: outline.selectedRow) as? DiffNode).map(pos) : nil
        let target: DiffNode
        if let c = current {
            target = forward ? (diffs.first { pos($0) > c } ?? diffs[0]) : (diffs.last { pos($0) < c } ?? diffs[diffs.count - 1])
        } else {
            target = forward ? diffs[0] : diffs[diffs.count - 1]
        }
        select(target)
    }

    private func select(_ n: DiffNode) {
        var chain: [DiffNode] = []
        var p = n.parent
        while let x = p { chain.append(x); p = x.parent }
        for a in chain.reversed() { outline.expandItem(a) }
        let row = outline.row(forItem: n)
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    // MARK: Data source

    private func visibleChildren(_ n: DiffNode) -> [DiffNode] {
        onlyDifferences ? n.children.filter(\.hasDifferences) : n.children
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let n = item as? DiffNode else { return tree == nil ? 0 : 1 }
        return visibleChildren(n).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let n = item as? DiffNode else { return tree! }
        return visibleChildren(n)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let n = item as? DiffNode else { return false }
        return !visibleChildren(n).isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rv = (outlineView.makeView(withIdentifier: rowID, owner: self) as? DiffRowView) ?? {
            let r = DiffRowView()
            r.identifier = rowID
            return r
        }()
        switch (item as? DiffNode)?.change {
        case .added?: rv.tint = NSColor.systemGreen.withAlphaComponent(0.22)
        case .removed?: rv.tint = NSColor.systemRed.withAlphaComponent(0.22)
        case .changed?: rv.tint = NSColor.systemYellow.withAlphaComponent(0.2)
        case nil: rv.tint = nil
        }
        return rv
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? DiffNode, let col = tableColumn?.identifier else { return nil }
        let cell = (outlineView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = cellID
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingTail
            tf.cell?.usesSingleLineMode = true
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf)
            c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        let tf = cell.textField!
        tf.textColor = .labelColor
        tf.font = .systemFont(ofSize: NSFont.systemFontSize)
        switch col {
        case keyColumnID:
            if n.component == nil {
                tf.stringValue = "Root"
            } else if n.isArrayElement {
                tf.stringValue = "Item \(n.component!)"
                tf.textColor = .secondaryLabelColor
            } else {
                tf.stringValue = n.component!
            }
        case leftTypeColumnID, rightTypeColumnID:
            let side = col == leftTypeColumnID ? n.left : n.right
            tf.stringValue = side?.type.rawValue ?? ""
            tf.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            tf.textColor = .secondaryLabelColor
        default:
            let side = col == leftValueColumnID ? n.left : n.right
            tf.stringValue = side.map(ValueText.display) ?? ""
            if side?.isContainer == true { tf.textColor = .secondaryLabelColor }
        }
        tf.toolTip = tf.stringValue.isEmpty ? nil : tf.stringValue
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard outline.selectedRow >= 0, let n = outline.item(atRow: outline.selectedRow) as? DiffNode,
              let doc = plistDocument, let editor = doc.editor else { return }
        // Reveal the node in the editor, or for rows only in the other file, its closest existing parent.
        var path = n.path
        while doc.root.descendant(at: path) == nil, !path.isEmpty { path.removeLast() }
        if let target = doc.root.descendant(at: path) { editor.revealNode(target) }
    }

    #if DEBUG
    func debugSelect(row: Int) { outline.selectRowIndexes([row], byExtendingSelection: false) }
    func debugDeselect() { outline.deselectAll(nil) }
    func debugStep(_ times: Int) { for _ in 0..<times { step(forward: true) } }
    func debugOnlyDifferences() { onlyDiffButton?.state = .on; toggleOnlyDifferences(onlyDiffButton!) }
    #endif
}
