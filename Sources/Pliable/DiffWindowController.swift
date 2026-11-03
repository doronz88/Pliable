import AppKit
import PliableCore

private typealias Side = DiffNode.Side

private enum Field: String { case key, type, value }

private func columnID(_ side: Side, _ f: Field) -> NSUserInterfaceItemIdentifier {
    NSUserInterfaceItemIdentifier((side == .left ? "L." : "R.") + f.rawValue)
}

private func parseColumn(_ id: NSUserInterfaceItemIdentifier) -> (Side, Field)? {
    let parts = id.rawValue.split(separator: ".")
    guard parts.count == 2, let f = Field(rawValue: String(parts[1])) else { return nil }
    return (parts[0] == "L" ? .left : .right, f)
}

private let textCellID = NSUserInterfaceItemIdentifier("diffText")
private let typePopupID = NSUserInterfaceItemIdentifier("diffType")
private let boolPopupID = NSUserInterfaceItemIdentifier("diffBool")
private let emptyCellID = NSUserInterfaceItemIdentifier("diffEmpty")
private let rowID = NSUserInterfaceItemIdentifier("diffRow")

/// Row view that tints its background by change kind. A selected row keeps its tint (the selection is an
/// accent outline over it rather than a solid fill) and a colored bar marks changed rows at the left edge.
private final class DiffRowView: NSTableRowView {
    var tint: NSColor? { didSet { needsDisplay = true } }
    var marker: NSColor? { didSet { needsDisplay = true } }
    /// Draws a strong divider where the right file's columns begin (column 3), read from the table when drawing
    /// so it follows column resizes.
    var showsDivider = true

    fileprivate func drawDivider() {
        guard showsDivider, let table = superview as? NSTableView, table.numberOfColumns > 3 else { return }
        let dividerX = convert(NSPoint(x: table.rect(ofColumn: 3).minX, y: 0), from: table).x
        NSColor.secondaryLabelColor.setFill()
        NSRect(x: dividerX - 1, y: 0, width: 2, height: bounds.height).fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if let tint {
            tint.setFill()
            bounds.fill()
        }
        if let marker {
            marker.setFill()
            NSRect(x: 0, y: 0, width: 4, height: bounds.height).fill()
        }
        drawDivider()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        if let tint {
            tint.setFill()
            bounds.fill()
        }
        if let marker {
            marker.setFill()
            NSRect(x: 0, y: 0, width: 4, height: bounds.height).fill()
        }
        let accent = NSColor.controlAccentColor
        accent.withAlphaComponent(isEmphasized ? 0.18 : 0.1).setFill()
        bounds.fill()
        let r = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        path.lineWidth = 2
        (isEmphasized ? accent : accent.withAlphaComponent(0.5)).setStroke()
        path.stroke()
        drawDivider()
    }

    // Keep normal text colors on selected rows so values stay readable over the tint.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// Text cell whose leading inset can be set per row (the right side's Key column indents like the outline).
/// On the right side's Key column it can also show a disclosure button, for rows that exist only on the right
/// (their outline triangle is hidden on the left so nothing of theirs appears on the left side).
private final class DiffTextCell: NSTableCellView {
    var leading: NSLayoutConstraint!
    var disclosureLeading: NSLayoutConstraint!
    let disclosure = NSButton()
}

/// Outline view that maps Delete / Return to compare-window actions.
/// Strip above the comparison naming each file, aligned over that file's columns, so it is always clear which
/// side is which (the column headers only say Key / Type / Value).
private final class FileBanner: NSView {
    private let badge = NSTextField(labelWithString: "")
    private let label = NSTextField(labelWithString: "")
    let color: NSColor

    init(letter: String, color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        badge.stringValue = letter
        badge.font = .boldSystemFont(ofSize: 11)
        badge.alignment = .center
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = color.cgColor
        badge.layer?.cornerRadius = 4
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.cell?.wraps = false
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [badge, label] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 18),
            badge.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(name: String, url: URL?) {
        let text = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
        if let dir = url?.deletingLastPathComponent().path {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let shown = dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
            text.append(NSAttributedString(string: "  —  " + shown, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        label.attributedStringValue = text
        toolTip = url?.path ?? name
    }

    override func updateLayer() {
        layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
        badge.layer?.backgroundColor = color.cgColor
    }
    override var wantsUpdateLayer: Bool { true }
}

/// Banners on top, the outline's scroll view below; banners follow the column widths.
private final class DiffContainerView: NSView {
    let left: FileBanner, right: FileBanner, scroll: NSScrollView, outline: NSOutlineView
    private let separator = NSBox()
    static let bannerHeight: CGFloat = 28

    init(left: FileBanner, right: FileBanner, scroll: NSScrollView, outline: NSOutlineView) {
        self.left = left; self.right = right; self.scroll = scroll; self.outline = outline
        super.init(frame: .zero)
        separator.boxType = .separator
        for v in [left, right, separator, scroll] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// x (in the outline) where the right file's columns begin.
    var dividerX: CGFloat {
        guard outline.numberOfColumns > 3 else { return bounds.midX }
        return outline.rect(ofColumn: 3).minX
    }

    override func layout() {
        super.layout()
        let h = Self.bannerHeight
        scroll.frame = NSRect(x: 0, y: h + 1, width: bounds.width, height: max(0, bounds.height - h - 1))
        separator.frame = NSRect(x: 0, y: h, width: bounds.width, height: 1)
        let x = convert(NSPoint(x: dividerX, y: 0), from: outline).x
        left.frame = NSRect(x: 0, y: 0, width: max(0, x - 1), height: h)
        right.frame = NSRect(x: x + 1, y: 0, width: max(0, bounds.width - x - 1), height: h)
    }
}

private final class DiffOutlineView: NSOutlineView {
    var onDelete: (() -> Void)?
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: onDelete?()
        case 36, 76: onReturn?()
        default: super.keyDown(with: event)
        }
    }
}

/// Shows a document (left) and another plist document (right) side by side in one tree, rows aligned by key.
/// Each side has its own Key, Type and Value columns, so a row that exists only in one file shows only on
/// that file's side. Rows only on the right are green, only on the left red, different on both sides yellow.
/// Both sides are editable (keys, types, values; delete; copy a row across); edits go through each document
/// with its own undo, and the tree is recomputed after every change on either side.
final class DiffWindowController: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSToolbarDelegate, NSMenuItemValidation, NSToolbarItemValidation, NSMenuDelegate, NSTextFieldDelegate {
    private let outline = DiffOutlineView()
    private let leftBanner = FileBanner(letter: "A", color: .systemBlue)
    private let rightBanner = FileBanner(letter: "B", color: .systemPurple)
    private var container: DiffContainerView?
    private var tree: DiffNode?
    private var refreshPending = false
    private var onlyDifferences = false
    private var onlyDiffButton: NSButton?
    private var navControl: NSSegmentedControl?
    /// Side of the last clicked or edited column: target of Delete, Return and Undo.
    private var activeSide: Side = .left
    private var discardOtherChanges = false

    // `document` is only set once the document adds this controller; keep our own references.
    private weak var plistDocument: PlistDocument?
    private let other: PlistDocument

    private var leftName: String { plistDocument?.displayName ?? "This Document" }
    private var rightName: String { other.displayName ?? "Other" }

    init(document: PlistDocument, other: PlistDocument) {
        self.other = other
        plistDocument = document
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 700, height: 240)
        window.tabbingMode = .disallowed
        super.init(window: window)
        shouldCloseDocument = false
        window.delegate = self
        other.compareViewers += 1
        if other.sheetHost == nil { other.sheetHost = window }
        buildContent()
        let tb = NSToolbar(identifier: "PliableDiffToolbar")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        window.toolbar = tb
        window.toolbarStyle = .unified
        window.setFrameAutosaveName("PliableDiffWindow3")
        if let host = document.editor?.view.window, !window.setFrameUsingName("PliableDiffWindow3") {
            window.setFrameTopLeftPoint(NSPoint(x: host.frame.minX + 40, y: host.frame.maxY - 40))
        }
        let nc = NotificationCenter.default
        for doc in [document, other] {
            nc.addObserver(self, selector: #selector(documentChanged(_:)), name: PlistDocument.didChangeNotification, object: doc)
            nc.addObserver(self, selector: #selector(editedStateChanged(_:)), name: PlistDocument.editedStateNotification, object: doc)
        }
        nc.addObserver(self, selector: #selector(otherClosed(_:)), name: PlistDocument.didCloseNotification, object: other)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func windowTitle(forDocumentDisplayName displayName: String) -> String {
        "\(displayName) ↔ \(rightName)"
    }

    private func doc(_ side: Side) -> PlistDocument? { side == .left ? plistDocument : other }

    // MARK: Window lifecycle and saving

    override func setDocumentEdited(_ dirtyFlag: Bool) {
        super.setDocumentEdited(dirtyFlag || other.isDocumentEdited)
    }

    @objc private func editedStateChanged(_ n: Notification) {
        window?.isDocumentEdited = (plistDocument?.isDocumentEdited ?? false) || other.isDocumentEdited
    }

    @objc private func otherClosed(_ n: Notification) {
        // The other file was closed in its own window: nothing left to compare with.
        close()
    }

    /// The other side is kept open only for this window; ask about its unsaved changes before closing.
    private var ownsOther: Bool { other.compareViewers == 1 && other.editor == nil }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard ownsOther, other.isDocumentEdited, !discardOtherChanges else { return true }
        let a = NSAlert()
        a.messageText = "Do you want to save the changes made to “\(rightName)”?"
        a.informativeText = "Your changes will be lost if you don’t save them."
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Don’t Save")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: sender) { [weak self] r in
            guard let self else { return }
            switch r {
            case .alertFirstButtonReturn:
                self.save(self.other) { ok in if ok { self.close() } }
            case .alertSecondButtonReturn:
                self.discardOtherChanges = true
                self.close()
            default:
                break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        let owned = ownsOther
        other.compareViewers -= 1
        if other.sheetHost === window { other.sheetHost = nil }
        guard owned else { return }
        if other.isDocumentEdited && !discardOtherChanges {
            // Closed along with the left document: don't lose edits made to the other file.
            other.showWindows()
        } else {
            other.close()
        }
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        doc(activeSide)?.undoManager
    }

    private func save(_ d: PlistDocument, then: ((Bool) -> Void)? = nil) {
        guard let url = d.fileURL, let type = d.fileType else { then?(false); return }
        d.save(to: url, ofType: type, for: .saveOperation) { [weak self] error in
            if let error, let w = self?.window { d.presentError(error, modalFor: w, delegate: nil, didPresent: nil, contextInfo: nil) }
            then?(error == nil)
        }
    }

    /// ⌘S in this window saves whichever of the two files has unsaved changes.
    @objc func saveDocument(_ sender: Any?) {
        var any = false
        for d in [plistDocument, other].compactMap({ $0 }) where d.isDocumentEdited {
            save(d)
            any = true
        }
        if !any { NSSound.beep() }
    }

    // MARK: Content

    private func buildContent() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        outline.style = .fullWidth
        outline.usesAlternatingRowBackgroundColors = true
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.gridStyleMask = .solidVerticalGridLineMask
        outline.indentationPerLevel = 14
        outline.allowsMultipleSelection = true
        outline.rowSizeStyle = .default
        for side in [Side.left, .right] {
            let name = side == .left ? leftName : rightName
            let tip = (side == .left ? plistDocument?.fileURL : other.fileURL)?.path ?? name
            for (f, title, width, minWidth) in [(Field.key, "Key", 210.0, 80.0), (.type, "Type", 92.0, 70.0),
                                                (.value, "Value", 240.0, 60.0)] {
                let c = NSTableColumn(identifier: columnID(side, f))
                c.title = title
                c.width = width
                c.minWidth = minWidth
                c.headerToolTip = "\(side == .left ? "A" : "B"): \(tip)"
                outline.addTableColumn(c)
            }
        }
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked(_:))
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.onDelete = { [weak self] in self?.deleteFromActiveSide(nil) }
        outline.onReturn = { [weak self] in
            if NSApp.currentEvent?.modifierFlags.contains(.option) == true { self?.editValue(nil) } else { self?.beginEditingSelectedRow() }
        }
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        scroll.documentView = outline
        leftBanner.set(name: leftName, url: plistDocument?.fileURL)
        rightBanner.set(name: rightName, url: other.fileURL)
        container = DiffContainerView(left: leftBanner, right: rightBanner, scroll: scroll, outline: outline)
        window?.contentView = container
        NotificationCenter.default.addObserver(self, selector: #selector(columnsResized(_:)),
                                               name: NSTableView.columnDidResizeNotification, object: outline)
    }

    @objc private func columnsResized(_ n: Notification) {
        container?.needsLayout = true
        outline.enumerateAvailableRowViews { rv, _ in rv.needsDisplay = true }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.layoutIfNeeded()
        outline.sizeLastColumnToFit()
        window?.makeFirstResponder(outline)
    }

    // MARK: Toolbar

    private let copyToLeftID = NSToolbarItem.Identifier("copyToLeft")
    private let copyToRightID = NSToolbarItem.Identifier("copyToRight")
    private let onlyDiffID = NSToolbarItem.Identifier("onlyDifferences")
    private let navID = NSToolbarItem.Identifier("diffNav")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [copyToLeftID, copyToRightID, .flexibleSpace, onlyDiffID, navID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case copyToLeftID:
            item.label = "Copy to Left"
            item.toolTip = "Replace the selected row in “\(leftName)” with the one from “\(rightName)” (⌃⌘←)"
            item.image = NSImage(systemSymbolName: "arrow.left.square", accessibilityDescription: "Copy to Left")
            item.action = #selector(copyToLeft(_:))
            item.target = self
        case copyToRightID:
            item.label = "Copy to Right"
            item.toolTip = "Replace the selected row in “\(rightName)” with the one from “\(leftName)” (⌃⌘→)"
            item.image = NSImage(systemSymbolName: "arrow.right.square", accessibilityDescription: "Copy to Right")
            item.action = #selector(copyToRight(_:))
            item.target = self
        case onlyDiffID:
            let b = NSButton(checkboxWithTitle: "Only Differences", target: self, action: #selector(toggleOnlyDifferences(_:)))
            b.state = onlyDifferences ? .on : .off
            b.toolTip = "Hide rows that are the same in both files"
            onlyDiffButton = b
            item.view = b
            item.label = "Only Differences"
        case navID:
            let c = NSSegmentedControl(images: [
                NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous Difference")!,
                NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next Difference")!,
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
        tree = DiffNode.build(doc.root, other.root)
        if first {
            reload(restoring: nil)
            expandDifferences()
            if let d = differences().first { select(d) }
        } else {
            reload(restoring: state)
        }
        updateStatus()
        editedStateChanged(Notification(name: PlistDocument.editedStateNotification))
    }

    private func updateStatus() {
        guard let tree else { return }
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
        if added > 0 { parts.append("\(added) only in “\(rightName)”") }
        if removed > 0 { parts.append("\(removed) only in “\(leftName)”") }
        window?.subtitle = parts.isEmpty ? "The property lists are identical" : parts.joined(separator: " · ")
        navControl?.isEnabled = tree.hasDifferences
    }

    // MARK: Expansion and selection (kept across recomputes by path)

    private struct State {
        var expanded: Set<[String]>
        var selected: [String]?
        var scroll: NSPoint
    }

    private func captureState() -> State {
        var expanded = Set<[String]>()
        for r in 0..<outline.numberOfRows {
            if let n = outline.item(atRow: r) as? DiffNode, outline.isItemExpanded(n) { expanded.insert(n.path) }
        }
        let sel = outline.selectedRow >= 0 ? (outline.item(atRow: outline.selectedRow) as? DiffNode)?.path : nil
        return State(expanded: expanded, selected: sel, scroll: outline.enclosingScrollView?.contentView.bounds.origin ?? .zero)
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
        if let p = state.selected {
            // Keep the selection on the same row, or the nearest row above it that still exists.
            var path = p
            while !path.isEmpty, find(path, in: tree) == nil { path.removeLast() }
            if let n = find(path, in: tree) {
                let row = outline.row(forItem: n)
                if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
            }
        }
        if let sv = outline.enclosingScrollView {
            sv.contentView.scroll(to: state.scroll)
            sv.reflectScrolledClipView(sv.contentView)
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
        let current = selectedNode.map(pos)
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

    private var selectedNode: DiffNode? {
        outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? DiffNode : nil
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
        let color: NSColor?
        switch (item as? DiffNode)?.change {
        case .added?: color = .systemGreen
        case .removed?: color = .systemRed
        case .changed?: color = .systemOrange
        case nil: color = nil
        }
        rv.tint = color?.withAlphaComponent(0.2)
        rv.marker = color
        return rv
    }

    // MARK: Cells

    private func textCell(_ outlineView: NSOutlineView) -> DiffTextCell {
        if let c = outlineView.makeView(withIdentifier: textCellID, owner: self) as? DiffTextCell { return c }
        let cell = DiffTextCell()
        cell.identifier = textCellID
        let tf = NSTextField()
        tf.isBordered = false
        tf.drawsBackground = false
        tf.lineBreakMode = .byTruncatingTail
        tf.cell?.usesSingleLineMode = true
        tf.cell?.sendsActionOnEndEditing = true
        tf.delegate = self
        tf.target = self
        tf.action = #selector(textEdited(_:))
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        cell.textField = tf
        cell.leading = tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2)
        let d = cell.disclosure
        d.bezelStyle = .disclosure
        d.setButtonType(.pushOnPushOff)
        d.title = ""
        d.isHidden = true
        d.target = self
        d.action = #selector(disclosureClicked(_:))
        d.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(d)
        cell.disclosureLeading = d.leadingAnchor.constraint(equalTo: cell.leadingAnchor)
        NSLayoutConstraint.activate([
            cell.leading,
            cell.disclosureLeading,
            d.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func popup(_ outlineView: NSOutlineView, _ id: NSUserInterfaceItemIdentifier, _ titles: [String], _ action: Selector) -> NSPopUpButton {
        if let p = outlineView.makeView(withIdentifier: id, owner: self) as? NSPopUpButton { return p }
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.identifier = id
        p.isBordered = false
        p.controlSize = .small
        p.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        p.addItems(withTitles: titles)
        p.target = self
        p.action = action
        return p
    }

    private func emptyCell(_ outlineView: NSOutlineView) -> NSView {
        if let v = outlineView.makeView(withIdentifier: emptyCellID, owner: self) { return v }
        let v = NSView()
        v.identifier = emptyCellID
        return v
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? DiffNode, let id = tableColumn?.identifier, let (side, field) = parseColumn(id) else { return nil }
        // Rows missing on this side stay blank here; they show on the side that has them.
        guard let node = n.node(side) else { return emptyCell(outlineView) }
        switch field {
        case .key:
            let cell = textCell(outlineView)
            let tf = cell.textField!
            // The outline column indents by itself; the right side's Key column mirrors it.
            let indent = CGFloat(outlineView.level(forItem: n)) * outline.indentationPerLevel
            cell.leading.constant = side == .left ? 2 : indent + 18
            cell.disclosureLeading.constant = indent + 2
            let ownDisclosure = side == .right && n.left == nil && !visibleChildren(n).isEmpty
            cell.disclosure.isHidden = !ownDisclosure
            if ownDisclosure { cell.disclosure.state = outlineView.isItemExpanded(n) ? .on : .off }
            tf.font = .systemFont(ofSize: NSFont.systemFontSize)
            if n.component == nil {
                tf.stringValue = "Root"
                tf.isEditable = false
                tf.textColor = .labelColor
            } else if node.parent?.kind == .array {
                tf.stringValue = "Item \(node.indexInParent ?? 0)"
                tf.isEditable = false
                tf.textColor = .secondaryLabelColor
            } else {
                tf.stringValue = node.key ?? ""
                tf.isEditable = true
                tf.textColor = .labelColor
            }
            tf.toolTip = tf.stringValue
            return cell
        case .type:
            let p = popup(outlineView, typePopupID, PlistType.allCases.map(\.rawValue), #selector(typeChosen(_:)))
            p.selectItem(withTitle: node.type.rawValue)
            return p
        case .value:
            if case .bool(let b) = node.kind {
                let p = popup(outlineView, boolPopupID, ["YES", "NO"], #selector(boolChosen(_:)))
                p.selectItem(at: b ? 0 : 1)
                return p
            }
            let cell = textCell(outlineView)
            cell.leading.constant = 2
            cell.disclosure.isHidden = true
            let tf = cell.textField!
            tf.stringValue = EditorViewController.cellText(node)
            tf.isEditable = ValueText.isEditable(node) && !ValueEditorController.prefersPopover(node)
            tf.textColor = node.isContainer ? .secondaryLabelColor : .labelColor
            // Changed scalar values are bold so the differing cell stands out within the row.
            let differs = n.change == .changed && !node.isContainer
            tf.font = differs ? .boldSystemFont(ofSize: NSFont.systemFontSize) : .systemFont(ofSize: NSFont.systemFontSize)
            tf.toolTip = tf.stringValue.isEmpty ? nil : tf.stringValue
            return cell
        }
    }

    /// Rows that exist only on the right get their disclosure button in the right Key column instead.
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        (item as? DiffNode)?.left != nil
    }

    @objc private func disclosureClicked(_ sender: NSButton) {
        let row = outline.row(for: sender)
        guard row >= 0, let n = outline.item(atRow: row) as? DiffNode else { return }
        if outline.isItemExpanded(n) {
            outline.collapseItem(n)
        } else {
            outline.expandItem(n)
        }
        sender.state = outline.isItemExpanded(n) ? .on : .off
    }

    func outlineViewItemDidExpand(_ notification: Notification) { syncDisclosure(notification) }
    func outlineViewItemDidCollapse(_ notification: Notification) { syncDisclosure(notification) }

    private func syncDisclosure(_ notification: Notification) {
        guard let n = notification.userInfo?["NSObject"] as? DiffNode, n.left == nil else { return }
        let row = outline.row(forItem: n)
        let col = outline.column(withIdentifier: columnID(.right, .key))
        guard row >= 0, col >= 0, let cell = outline.view(atColumn: col, row: row, makeIfNecessary: false) as? DiffTextCell else { return }
        cell.disclosure.state = outline.isItemExpanded(n) ? .on : .off
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let n = selectedNode else { return }
        if n.node(activeSide) == nil, n.node(activeSide.opposite) != nil { activeSide = activeSide.opposite }
        // Reveal the row in each side's editor window, or for rows missing there, the closest existing parent.
        for side in [Side.left, .right] {
            guard let d = doc(side), let editor = d.editor else { continue }
            var path = n.path
            while d.root.descendant(at: path) == nil, !path.isEmpty { path.removeLast() }
            if let target = d.root.descendant(at: path) { editor.revealNode(target) }
        }
    }

    // MARK: Editing

    /// The row and side a control in a cell belongs to.
    private func location(of view: NSView) -> (DiffNode, Side)? {
        let row = outline.row(for: view), col = outline.column(for: view)
        guard row >= 0, col >= 0, let n = outline.item(atRow: row) as? DiffNode,
              let (side, _) = parseColumn(outline.tableColumns[col].identifier) else { return nil }
        return (n, side)
    }

    private func reloadRow(_ n: DiffNode) {
        let row = outline.row(forItem: n)
        if row >= 0 { outline.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(0..<outline.numberOfColumns)) }
    }

    @objc private func textEdited(_ sender: NSTextField) {
        guard let (n, side) = location(of: sender), let d = doc(side), let node = n.node(side) else { return }
        activeSide = side
        let col = outline.column(for: sender)
        let text = sender.stringValue
        if outline.tableColumns[col].identifier == columnID(side, .key) {
            guard let parent = node.parent, parent.kind == .dictionary, text != node.key else { return }
            if parent.hasChildKey(text, excluding: node) {
                reloadRow(n)
                showAlert("The key “\(text)” already exists", "Keys in a dictionary must be unique.")
                return
            }
            d.setKey(node, text)
            d.undoManager?.setActionName("Rename Key")
        } else {
            guard ValueText.isEditable(node), text != ValueText.display(node) else { return }
            guard let kind = ValueText.parse(text, as: node.type) else {
                NSSound.beep()
                reloadRow(n)
                return
            }
            if kind == node.kind { reloadRow(n); return }
            d.replaceContents(node, kind: kind, children: [], childKeys: [])
            d.undoManager?.setActionName("Change Value")
        }
    }

    @objc private func typeChosen(_ sender: NSPopUpButton) {
        guard let (n, side) = location(of: sender), let d = doc(side), let node = n.node(side) else { return }
        activeSide = side
        let type = PlistType.allCases[sender.indexOfSelectedItem]
        guard let conv = ValueText.convert(node, to: type) else { return }
        d.replaceContents(node, kind: conv.kind, children: conv.children, childKeys: conv.childKeys)
        d.undoManager?.setActionName("Change Type")
    }

    @objc private func boolChosen(_ sender: NSPopUpButton) {
        guard let (n, side) = location(of: sender), let d = doc(side), let node = n.node(side) else { return }
        activeSide = side
        let v = sender.indexOfSelectedItem == 0
        guard node.kind != .bool(v) else { return }
        d.replaceContents(node, kind: .bool(v), children: [], childKeys: [])
        d.undoManager?.setActionName("Change Value")
    }

    private func side(ofColumn col: Int) -> Side? {
        col >= 0 && col < outline.numberOfColumns ? parseColumn(outline.tableColumns[col].identifier)?.0 : nil
    }

    @objc private func clicked(_ sender: Any?) {
        guard let s = side(ofColumn: outline.clickedColumn) else { return }
        if outline.clickedRow >= 0, let n = outline.item(atRow: outline.clickedRow) as? DiffNode, n.node(s) == nil { return }
        activeSide = s
    }

    @objc private func doubleClicked(_ sender: Any?) {
        let row = outline.clickedRow, col = outline.clickedColumn
        guard row >= 0, col >= 0 else { return }
        edit(row: row, column: col)
    }

    private func edit(row: Int, column: Int) {
        guard let n = outline.item(atRow: row) as? DiffNode,
              let (side, field) = parseColumn(outline.tableColumns[column].identifier), let node = n.node(side) else { return }
        if field == .value, ValueEditorController.prefersPopover(node) { showValueEditor(n, side: side, row: row); return }
        switch field {
        case .key where node.parent?.kind != .dictionary: return
        case .value where !ValueText.isEditable(node): return
        case .type: return
        default: break
        }
        activeSide = side
        outline.editColumn(column, row: row, with: nil, select: true)
    }

    private func beginEditingSelectedRow() {
        let row = outline.selectedRow
        guard row >= 0, let n = selectedNode else { return }
        let side = n.node(activeSide) != nil ? activeSide : activeSide.opposite
        guard let node = n.node(side) else { return }
        let field: Field = ValueText.isEditable(node) || ValueEditorController.prefersPopover(node) ? .value : .key
        edit(row: row, column: outline.column(withIdentifier: columnID(side, field)))
    }

    // MARK: Popover value editor

    private func showValueEditor(_ n: DiffNode, side: Side, row: Int) {
        let col = outline.column(withIdentifier: columnID(side, .value))
        guard let node = n.node(side), let d = doc(side), col >= 0,
              let anchor = outline.view(atColumn: col, row: row, makeIfNecessary: true) else { return }
        activeSide = side
        ValueEditorController.show(for: node, relativeTo: anchor) { kind in
            d.replaceContents(node, kind: kind, children: [], childKeys: [])
            d.undoManager?.setActionName("Change Value")
        }
    }

    /// ⌥↩: the popover editor for the selected row's value on the active side.
    @objc func editValue(_ sender: Any?) {
        guard outline.selectedRowIndexes.count == 1, let n = selectedNode else { NSSound.beep(); return }
        let side = n.node(activeSide) != nil ? activeSide : activeSide.opposite
        guard let node = n.node(side), ValueEditorController.canEdit(node) else { NSSound.beep(); return }
        showValueEditor(n, side: side, row: outline.selectedRow)
    }

    // MARK: Delete and copy across

    /// Commits a cell edit in progress before rows are copied or deleted (reloading under an open editor drops it).
    private func finishCellEditing() -> Bool {
        guard let w = window, w.firstResponder !== outline else { return true }
        return w.makeFirstResponder(outline)
    }

    /// Selected rows without those whose ancestor row is also selected, in display order.
    private var selectedNodes: [DiffNode] {
        let sel = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? DiffNode }
        return sel.filter { n in
            var p = n.parent
            while let x = p { if sel.contains(where: { $0 === x }) { return false }; p = x.parent }
            return true
        }
    }

    /// Rows a menu command acts on: the right-clicked row if it is outside the selection, else the selection.
    private var targetNodes: [DiffNode] {
        let r = outline.clickedRow
        if r >= 0, !outline.selectedRowIndexes.contains(r), let n = outline.item(atRow: r) as? DiffNode { return [n] }
        return selectedNodes
    }

    private func canDelete(_ n: DiffNode, from side: Side) -> Bool {
        n.node(side)?.parent != nil
    }

    private func delete(_ nodes: [DiffNode], from side: Side) {
        guard finishCellEditing() else { return }
        guard let d = doc(side) else { return }
        var count = 0
        for n in nodes {
            guard let node = n.node(side), let p = node.parent, let i = node.indexInParent else { continue }
            d.remove(from: p, at: i)
            count += 1
        }
        guard count > 0 else { NSSound.beep(); return }
        d.undoManager?.setActionName(count == 1 ? "Delete Item" : "Delete Items")
        activeSide = side
    }

    @objc func deleteFromActiveSide(_ sender: Any?) {
        let nodes = selectedNodes
        guard !nodes.isEmpty else { NSSound.beep(); return }
        let side = nodes.contains { $0.node(activeSide)?.parent != nil } ? activeSide : activeSide.opposite
        delete(nodes, from: side)
    }

    @objc func delete(_ sender: Any?) { deleteFromActiveSide(sender) }
    @objc private func deleteFromLeft(_ sender: Any?) { delete(targetNodes, from: .left) }
    @objc private func deleteFromRight(_ sender: Any?) { delete(targetNodes, from: .right) }

    /// Whether copying `n` from `source` changes the other side: it differs and either exists on `source`
    /// (replace the other side's row, or insert it where its parent matches) or only on the other side (remove it there).
    private func canCopy(_ n: DiffNode, from source: Side) -> Bool {
        guard n.hasDifferences else { return false }
        if n.node(source) == nil { return n.node(source.opposite)?.parent != nil }
        return n.node(source.opposite) != nil || n.insertionIndex(on: source.opposite) != nil
    }

    /// Makes each row on the other side match `source`. Rows are applied bottom-up so a row inserted earlier
    /// doesn't shift where a later one goes.
    @discardableResult
    private func copy(_ nodes: [DiffNode], from source: Side) -> Int {
        guard finishCellEditing() else { return 0 }
        let target = source.opposite
        guard let d = doc(target) else { return 0 }
        var count = 0
        for n in nodes.reversed() where canCopy(n, from: source) {
            if let src = n.node(source) {
                if let dst = n.node(target) {
                    d.replaceContents(dst, kind: src.kind, children: src.children.map { $0.deepCopy() }, childKeys: src.children.map(\.key))
                } else if let container = n.parent?.node(target), let index = n.insertionIndex(on: target) {
                    let c = src.deepCopy()
                    c.key = container.kind == .dictionary ? src.key : nil
                    d.insert(c, into: container, at: index)
                } else {
                    continue
                }
            } else if let dst = n.node(target), let p = dst.parent, let i = dst.indexInParent {
                d.remove(from: p, at: i)
            }
            count += 1
        }
        if count > 0 {
            d.undoManager?.setActionName("Copy from “\(source == .left ? leftName : rightName)”")
            activeSide = target
        } else {
            NSSound.beep()
        }
        return count
    }

    @objc func copyToLeft(_ sender: Any?) { copy(targetNodes, from: .right) }
    @objc func copyToRight(_ sender: Any?) { copy(targetNodes, from: .left) }

    /// Applies every difference, so the left file ends up with the same contents as the right one (key order aside).
    @objc func makeLeftMatchRight(_ sender: Any?) { copy(differences(), from: .right) }
    @objc func makeRightMatchLeft(_ sender: Any?) { copy(differences(), from: .left) }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard outline.clickedRow >= 0 else { return }
        func add(_ title: String, _ action: Selector) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            menu.addItem(i)
        }
        let many = targetNodes.count > 1
        add(many ? "Copy Rows to “\(leftName)”" : "Copy to “\(leftName)”", #selector(copyToLeft(_:)))
        add(many ? "Copy Rows to “\(rightName)”" : "Copy to “\(rightName)”", #selector(copyToRight(_:)))
        menu.addItem(.separator())
        add("Delete from “\(leftName)”", #selector(deleteFromLeft(_:)))
        add("Delete from “\(rightName)”", #selector(deleteFromRight(_:)))
        menu.addItem(.separator())
        add("Edit Value…", #selector(editValue(_:)))
        menu.addItem(.separator())
        add("Make “\(leftName)” Match “\(rightName)”", #selector(makeLeftMatchRight(_:)))
        add("Make “\(rightName)” Match “\(leftName)”", #selector(makeRightMatchLeft(_:)))
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        validate(menuItem.action)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { validate(item.action) }

    private func validate(_ action: Selector?) -> Bool {
        switch action {
        case #selector(copyToLeft(_:)): return targetNodes.contains { canCopy($0, from: .right) }
        case #selector(copyToRight(_:)): return targetNodes.contains { canCopy($0, from: .left) }
        case #selector(makeLeftMatchRight(_:)), #selector(makeRightMatchLeft(_:)): return tree?.hasDifferences == true
        case #selector(deleteFromLeft(_:)): return targetNodes.contains { canDelete($0, from: .left) }
        case #selector(deleteFromRight(_:)): return targetNodes.contains { canDelete($0, from: .right) }
        case #selector(delete(_:)), #selector(deleteFromActiveSide(_:)):
            return selectedNodes.contains { canDelete($0, from: .left) || canDelete($0, from: .right) }
        case #selector(editValue(_:)):
            guard outline.selectedRowIndexes.count == 1, let n = selectedNode else { return false }
            return (n.node(activeSide) ?? n.node(activeSide.opposite)).map(ValueEditorController.canEdit) == true
        case #selector(saveDocument(_:)):
            return (plistDocument?.isDocumentEdited ?? false) || other.isDocumentEdited
        default: return true
        }
    }

    private func showAlert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        if let w = window { a.beginSheetModal(for: w) } else { a.runModal() }
    }

    #if DEBUG
    func debugSelect(row: Int) { outline.selectRowIndexes([row], byExtendingSelection: false) }
    func debugDeselect() { outline.deselectAll(nil) }
    func debugStep(_ times: Int) { for _ in 0..<times { step(forward: true) } }
    func debugOnlyDifferences() { onlyDiffButton?.state = .on; toggleOnlyDifferences(onlyDiffButton!) }
    func debugCopy(toLeft: Bool) { toLeft ? copyToLeft(nil) : copyToRight(nil) }
    func debugSelectAll() { outline.selectAll(nil) }
    func debugMatch(left: Bool) { left ? makeLeftMatchRight(nil) : makeRightMatchLeft(nil) }
    #endif
}
