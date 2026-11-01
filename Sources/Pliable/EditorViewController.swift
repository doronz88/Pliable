import AppKit
import PliableCore

private let keyColumnID = NSUserInterfaceItemIdentifier("key")
private let typeColumnID = NSUserInterfaceItemIdentifier("type")
private let valueColumnID = NSUserInterfaceItemIdentifier("value")
private let textCellID = NSUserInterfaceItemIdentifier("textCell")
private let typePopupID = NSUserInterfaceItemIdentifier("typePopup")
private let boolPopupID = NSUserInterfaceItemIdentifier("boolPopup")
private let nodesPasteboardType = NSPasteboard.PasteboardType("local.pliable.nodes")
private let dragPasteboardType = NSPasteboard.PasteboardType("local.pliable.drag")

/// Outline view that maps Delete/Return to editor actions.
final class PlistOutlineView: NSOutlineView {
    weak var editor: EditorViewController?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: // delete, forward delete
            editor?.deleteItems(nil)
        case 36, 76: // return, enter
            editor?.beginEditingSelectedRow()
        default:
            let mods = event.modifierFlags.intersection([.command, .control, .option])
            if mods.isEmpty, event.charactersIgnoringModifiers == "+" {
                editor?.addItem(nil)
                return
            }
            super.keyDown(with: event)
        }
    }
}

final class EditorViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSTextFieldDelegate, NSMenuItemValidation, NSToolbarDelegate {

    unowned let document: PlistDocument
    private let outline = PlistOutlineView()
    private var formatPopup: NSPopUpButton?
    private var draggedNodes: [PlistNode] = []

    init(document: PlistDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: View setup

    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        outline.editor = self
        outline.style = .fullWidth
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = true
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.autosaveName = "PliableColumns"
        outline.autosaveTableColumns = true
        outline.rowSizeStyle = .default
        outline.indentationPerLevel = 14

        let keyCol = NSTableColumn(identifier: keyColumnID)
        keyCol.title = "Key"
        keyCol.width = 260
        keyCol.minWidth = 80
        let typeCol = NSTableColumn(identifier: typeColumnID)
        typeCol.title = "Type"
        typeCol.width = 110
        typeCol.minWidth = 90
        let valueCol = NSTableColumn(identifier: valueColumnID)
        valueCol.title = "Value"
        valueCol.width = 340
        valueCol.minWidth = 80
        for c in [keyCol, typeCol, valueCol] { outline.addTableColumn(c) }
        outline.outlineTableColumn = keyCol

        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.registerForDraggedTypes([dragPasteboardType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)

        scroll.documentView = outline
        view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        document.onChange = { [weak self] change in self?.apply(change) }
        outline.reloadData()
        outline.expandItem(document.root)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(outline)
        if outline.selectedRow < 0 { outline.selectRowIndexes([0], byExtendingSelection: false) }
    }

    func makeToolbar() -> NSToolbar {
        let tb = NSToolbar(identifier: "PliableToolbar")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        return tb
    }

    func updateSubtitle() {
        var s = document.format.displayName
        if !document.orderPreserved { s += " — key order could not be read from this file" }
        view.window?.subtitle = s
        if let p = formatPopup, let i = PlistFormat.allCases.firstIndex(of: document.format) { p.selectItem(at: i) }
    }

    private func apply(_ change: PlistDocument.Change) {
        switch change {
        case .row(let n):
            outline.reloadItem(n)
        case .children(let n):
            if n === document.root, outline.row(forItem: n) < 0 {
                outline.reloadData()
            } else {
                outline.reloadItem(n, reloadChildren: true)
            }
        case .format:
            updateSubtitle()
        }
    }

    // MARK: Toolbar

    private let addID = NSToolbarItem.Identifier("add")
    private let removeID = NSToolbarItem.Identifier("remove")
    private let formatID = NSToolbarItem.Identifier("format")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [addID, removeID, .flexibleSpace, formatID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case addID:
            item.label = "Add Item"
            item.toolTip = "Add Item (+ or ⌘↩)"
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Item")
            item.action = #selector(addItem(_:))
            item.target = self
        case removeID:
            item.label = "Delete"
            item.toolTip = "Delete Item (⌫)"
            item.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Delete Item")
            item.action = #selector(deleteItems(_:))
            item.target = self
        case formatID:
            let p = NSPopUpButton(frame: .zero, pullsDown: false)
            p.addItems(withTitles: PlistFormat.allCases.map(\.displayName))
            p.target = self
            p.action = #selector(formatChosen(_:))
            p.toolTip = "Format used when saving"
            formatPopup = p
            item.view = p
            item.label = "Format"
            updateSubtitle()
        default:
            return nil
        }
        return item
    }

    @objc private func formatChosen(_ sender: NSPopUpButton) {
        let f = PlistFormat.allCases[sender.indexOfSelectedItem]
        if f == document.format { return }
        if let problem = document.problem(savingAs: f) {
            updateSubtitle()
            showAlert("Can’t use the \(f.displayName) format", problem)
            return
        }
        document.setFormat(f)
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let n = item as? PlistNode else { return 1 }
        return n.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let n = item as? PlistNode else { return document.root }
        return n.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? PlistNode)?.isContainer == true && !(item as! PlistNode).children.isEmpty
    }

    // MARK: Cells

    private func textCell(_ outlineView: NSOutlineView) -> NSTableCellView {
        if let c = outlineView.makeView(withIdentifier: textCellID, owner: self) as? NSTableCellView { return c }
        let cell = NSTableCellView()
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
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
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

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? PlistNode, let col = tableColumn?.identifier else { return nil }
        switch col {
        case keyColumnID:
            let cell = textCell(outlineView)
            let tf = cell.textField!
            if n.parent == nil {
                tf.stringValue = "Root"
                tf.isEditable = false
                tf.textColor = .labelColor
            } else if n.parent?.kind == .array {
                tf.stringValue = "Item \(n.indexInParent ?? 0)"
                tf.isEditable = false
                tf.textColor = .secondaryLabelColor
            } else {
                tf.stringValue = n.key ?? ""
                tf.isEditable = true
                tf.textColor = .labelColor
            }
            return cell
        case typeColumnID:
            let p = popup(outlineView, typePopupID, PlistType.allCases.map(\.rawValue), #selector(typeChosen(_:)))
            p.selectItem(withTitle: n.type.rawValue)
            return p
        default:
            if case .bool(let b) = n.kind {
                let p = popup(outlineView, boolPopupID, ["YES", "NO"], #selector(boolChosen(_:)))
                p.selectItem(at: b ? 0 : 1)
                return p
            }
            let cell = textCell(outlineView)
            let tf = cell.textField!
            tf.stringValue = ValueText.display(n)
            tf.isEditable = ValueText.isEditable(n)
            tf.textColor = n.isContainer ? .secondaryLabelColor : .labelColor
            return cell
        }
    }

    // MARK: Editing

    private func node(for view: NSView) -> PlistNode? {
        let row = outline.row(for: view)
        return row >= 0 ? outline.item(atRow: row) as? PlistNode : nil
    }

    @objc private func textEdited(_ sender: NSTextField) {
        guard let n = node(for: sender) else { return }
        let col = outline.column(for: sender)
        guard col >= 0 else { return }
        let text = sender.stringValue
        if outline.tableColumns[col].identifier == keyColumnID {
            guard let parent = n.parent, parent.kind == .dictionary, text != n.key else { return }
            if parent.hasChildKey(text, excluding: n) {
                outline.reloadItem(n)
                showAlert("The key “\(text)” already exists", "Keys in a dictionary must be unique.")
                return
            }
            document.setKey(n, text)
            document.undoManager?.setActionName("Rename Key")
        } else {
            guard ValueText.isEditable(n), text != ValueText.display(n) else { return }
            guard let kind = ValueText.parse(text, as: n.type) else {
                NSSound.beep()
                outline.reloadItem(n)
                return
            }
            if kind == n.kind { outline.reloadItem(n); return }
            document.replaceContents(n, kind: kind, children: [], childKeys: [])
            document.undoManager?.setActionName("Change Value")
        }
    }

    @objc private func typeChosen(_ sender: NSPopUpButton) {
        guard let n = node(for: sender) else { return }
        let type = PlistType.allCases[sender.indexOfSelectedItem]
        guard let conv = ValueText.convert(n, to: type) else { return }
        document.replaceContents(n, kind: conv.kind, children: conv.children, childKeys: conv.childKeys)
        document.undoManager?.setActionName("Change Type")
    }

    @objc private func boolChosen(_ sender: NSPopUpButton) {
        guard let n = node(for: sender) else { return }
        let v = sender.indexOfSelectedItem == 0
        guard n.kind != .bool(v) else { return }
        document.replaceContents(n, kind: .bool(v), children: [], childKeys: [])
        document.undoManager?.setActionName("Change Value")
    }

    @objc private func doubleClicked(_ sender: Any?) {
        let row = outline.clickedRow, col = outline.clickedColumn
        guard row >= 0, col >= 0 else { return }
        edit(row: row, column: col)
    }

    private func edit(row: Int, column: Int) {
        guard let n = outline.item(atRow: row) as? PlistNode else { return }
        let id = outline.tableColumns[column].identifier
        if id == keyColumnID, n.parent?.kind != .dictionary { return }
        if id == valueColumnID, !ValueText.isEditable(n) { return }
        if id == typeColumnID { return }
        outline.editColumn(column, row: row, with: nil, select: true)
    }

    func beginEditingSelectedRow() {
        let row = outline.selectedRow
        guard row >= 0, let n = outline.item(atRow: row) as? PlistNode else { return }
        let col = ValueText.isEditable(n) ? valueColumnID : keyColumnID
        edit(row: row, column: outline.column(withIdentifier: col))
    }

    private var selectedNodes: [PlistNode] {
        outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? PlistNode }
    }

    /// Selected nodes without root and without nodes whose ancestor is also selected.
    private var topLevelSelection: [PlistNode] {
        let sel = selectedNodes.filter { $0.parent != nil }
        return sel.filter { n in !sel.contains { $0 !== n && n.isDescendant(of: $0) } }
    }

    /// Where a new or pasted item goes: into an expanded container, else after the selection.
    private func insertionPoint() -> (PlistNode, Int)? {
        let sel = selectedNodes.last ?? document.root
        if sel.isContainer, sel.parent == nil || outline.isItemExpanded(sel) {
            return (sel, 0)
        }
        if let p = sel.parent, let i = sel.indexInParent { return (p, i + 1) }
        if sel.isContainer { return (sel, 0) }
        return nil
    }

    private func reveal(_ n: PlistNode, edit column: NSUserInterfaceItemIdentifier?) {
        if let p = n.parent { outline.expandItem(p) }
        let row = outline.row(forItem: n)
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        if let c = column { edit(row: row, column: outline.column(withIdentifier: c)) }
    }

    @objc func addItem(_ sender: Any?) {
        guard let (parent, index) = insertionPoint() else { NSSound.beep(); return }
        let key = parent.kind == .dictionary ? parent.uniqueChildKey(base: "New item") : nil
        let child = PlistNode(key: key, kind: .string(""))
        document.insert(child, into: parent, at: index)
        document.undoManager?.setActionName("Add Item")
        reveal(child, edit: parent.kind == .dictionary ? keyColumnID : valueColumnID)
    }

    @objc func deleteItems(_ sender: Any?) {
        let nodes = topLevelSelection
        guard !nodes.isEmpty else { NSSound.beep(); return }
        let firstRow = outline.selectedRowIndexes.first ?? 0
        // Remove in reverse order so earlier indices stay valid.
        let ordered = nodes.sorted { outline.row(forItem: $0) > outline.row(forItem: $1) }
        for n in ordered {
            guard let p = n.parent, let i = n.indexInParent else { continue }
            document.remove(from: p, at: i)
        }
        document.undoManager?.setActionName(nodes.count == 1 ? "Delete Item" : "Delete Items")
        let row = min(firstRow, outline.numberOfRows - 1)
        if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
    }

    @objc func delete(_ sender: Any?) { deleteItems(sender) }

    @objc func expandAll(_ sender: Any?) { outline.expandItem(document.root, expandChildren: true) }

    @objc func collapseAll(_ sender: Any?) {
        outline.collapseItem(document.root, collapseChildren: true)
        outline.expandItem(document.root)
    }

    // MARK: Copy / paste

    @objc func copy(_ sender: Any?) {
        let nodes = topLevelSelection.isEmpty ? selectedNodes : topLevelSelection
        guard !nodes.isEmpty else { return }
        // Private type: array of {key, value} so keys survive; plain text: XML of the value(s).
        let wrapper = PlistNode(kind: .array, children: nodes.map { n in
            var kids = [PlistNode(key: "value", kind: n.kind, children: n.children.map { $0.deepCopy() })]
            if let k = n.key { kids.insert(PlistNode(key: "key", kind: .string(k)), at: 0) }
            return PlistNode(kind: .dictionary, children: kids)
        })
        let pb = NSPasteboard.general
        pb.clearContents()
        if let d = try? PlistFile(root: wrapper, format: .xml).write() { pb.setData(d, forType: nodesPasteboardType) }
        let textRoot: PlistNode = nodes.count == 1 ? nodes[0].deepCopy() : PlistNode(kind: .array, children: nodes.map { $0.deepCopy() })
        textRoot.key = nil
        if nodes.count == 1, !nodes[0].isContainer {
            pb.setString(ValueText.display(nodes[0]), forType: .string)
        } else if let d = try? PlistFile(root: textRoot, format: .xml).write() {
            pb.setString(String(decoding: d, as: UTF8.self), forType: .string)
        }
    }

    @objc func cut(_ sender: Any?) {
        copy(sender)
        deleteItems(sender)
        document.undoManager?.setActionName("Cut")
    }

    @objc func paste(_ sender: Any?) {
        guard let (parent, start) = insertionPoint() else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        var items: [(String?, PlistNode)] = []
        if let d = pb.data(forType: nodesPasteboardType), let f = try? PlistFile.read(d), f.root.kind == .array {
            for w in f.root.children {
                guard let v = w.children.first(where: { $0.key == "value" }) else { continue }
                var k: String?
                if case .string(let s)? = w.children.first(where: { $0.key == "key" })?.kind { k = s }
                items.append((k, v))
            }
        } else if let s = pb.string(forType: .string) {
            if s.trimmingCharacters(in: .whitespaces).hasPrefix("<"), let f = try? PlistFile.read(Data(s.utf8)), f.format == .xml {
                items.append((nil, f.root))
            } else {
                items.append((nil, PlistNode(kind: .string(s))))
            }
        }
        guard !items.isEmpty else { NSSound.beep(); return }
        var inserted: [PlistNode] = []
        for (offset, (k, v)) in items.enumerated() {
            let node = PlistNode(kind: v.kind, children: v.children.map { $0.deepCopy() })
            if parent.kind == .dictionary { node.key = parent.uniqueChildKey(base: k ?? "New item") }
            document.insert(node, into: parent, at: start + offset)
            inserted.append(node)
        }
        document.undoManager?.setActionName("Paste")
        outline.expandItem(parent)
        let rows = IndexSet(inserted.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        if let r = rows.first { outline.scrollRowToVisible(r) }
    }

    override func selectAll(_ sender: Any?) { outline.selectAll(sender) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(deleteItems(_:)), #selector(delete(_:)), #selector(cut(_:)):
            return !topLevelSelection.isEmpty
        case #selector(copy(_:)):
            return !selectedNodes.isEmpty
        case #selector(paste(_:)):
            let pb = NSPasteboard.general
            return insertionPoint() != nil && (pb.data(forType: nodesPasteboardType) != nil || pb.string(forType: .string) != nil)
        case #selector(addItem(_:)):
            return insertionPoint() != nil
        default:
            return true
        }
    }

    // MARK: Drag and drop (reordering / moving)

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let n = item as? PlistNode, n.parent != nil else { return nil }
        let pi = NSPasteboardItem()
        pi.setString("node", forType: dragPasteboardType)
        return pi
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        let nodes = draggedItems.compactMap { $0 as? PlistNode }
        draggedNodes = nodes.filter { n in !nodes.contains { $0 !== n && n.isDescendant(of: $0) } }
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggedNodes = []
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard !draggedNodes.isEmpty, info.draggingSource as? NSOutlineView === outline else { return [] }
        var target = item as? PlistNode
        var childIndex = index
        if target == nil {
            // Above/below the Root row: drop into Root (start or end).
            target = document.root
            childIndex = index <= 0 ? 0 : document.root.children.count
        } else if let t = target, !t.isContainer {
            // Onto a scalar row: drop right after it in its parent.
            guard let p = t.parent, let i = t.indexInParent else { return [] }
            target = p
            childIndex = i + 1
        }
        guard let t = target, t.isContainer, !draggedNodes.contains(where: { t.isDescendant(of: $0) }) else { return [] }
        if t !== (item as? PlistNode) || childIndex != index { outline.setDropItem(t, dropChildIndex: childIndex) }
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let target = item as? PlistNode else { return false }
        var insertAt = index == NSOutlineViewDropOnItemIndex ? target.children.count : index
        let um = document.undoManager
        um?.beginUndoGrouping()
        for n in draggedNodes.sorted(by: { outline.row(forItem: $0) < outline.row(forItem: $1) }) {
            guard let p = n.parent, let i = n.indexInParent else { continue }
            if p === target, i < insertAt { insertAt -= 1 }
            document.remove(from: p, at: i)
            if target.kind == .dictionary {
                let k = target.uniqueChildKey(base: n.key ?? "New item")
                if k != n.key { document.setKey(n, k) }
            } else if n.key != nil {
                document.setKey(n, nil)
            }
            document.insert(n, into: target, at: insertAt)
            insertAt += 1
        }
        um?.setActionName("Move")
        um?.endUndoGrouping()
        outline.expandItem(target)
        let rows = IndexSet(draggedNodes.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        return true
    }

    // MARK: Helpers

    private func showAlert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        if let w = view.window { a.beginSheetModal(for: w) } else { a.runModal() }
    }
}
