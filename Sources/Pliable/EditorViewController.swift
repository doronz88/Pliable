import AppKit
import PliableCore

private let keyColumnID = NSUserInterfaceItemIdentifier("key")
private let typeColumnID = NSUserInterfaceItemIdentifier("type")
private let valueColumnID = NSUserInterfaceItemIdentifier("value")
private let textCellID = NSUserInterfaceItemIdentifier("textCell")
private let keyCellID = NSUserInterfaceItemIdentifier("keyCell")

/// Row view with a bar at the left edge marking an item changed since the last save.
final class EditorRowView: NSTableRowView {
    var changed = false { didSet { if changed != oldValue { needsDisplay = true } } }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        drawMarker()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        super.drawSelection(in: dirtyRect)
        drawMarker()
    }

    private func drawMarker() {
        guard changed else { return }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 1, y: 2, width: 3, height: bounds.height - 4), xRadius: 1.5, yRadius: 1.5).fill()
    }
}

private let editorRowID = NSUserInterfaceItemIdentifier("editorRow")

/// Shown in the Key column next to a well-known key: its readable name, or a warning when the value's type is wrong.
final class KeyCellView: NSTableCellView {
    let note = NSTextField(labelWithString: "")
    /// The key text's own width: an editable field has no intrinsic width, so without this the name would win.
    var keyWidth: NSLayoutConstraint!
}

extension Notification.Name {
    /// Posted when "Show Key Names" is toggled, so every open editor redraws its Key column.
    static let pliableKeyNamesToggled = Notification.Name("PliableKeyNamesToggled")
}
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
        case 36, 76: // return, enter (⌥↩ opens the value editor)
            if event.modifierFlags.contains(.option) { editor?.editValue(nil) } else { editor?.beginEditingSelectedRow() }
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
    NSSearchFieldDelegate, NSMenuItemValidation, NSToolbarDelegate, NSMenuDelegate {

    unowned let document: PlistDocument
    private let outline = PlistOutlineView()
    private var formatPopup: NSPopUpButton?
    private var draggedNodes: [PlistNode] = []
    private let pathBar = NSPathControl()

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
        outline.registerForDraggedTypes([dragPasteboardType, .fileURL])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)

        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        scroll.documentView = outline

        // Path of the selected item at the bottom; click a component to select it.
        pathBar.pathStyle = .standard
        pathBar.controlSize = .small
        pathBar.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathBar.isEditable = false
        pathBar.target = self
        pathBar.action = #selector(pathClicked(_:))
        let separator = NSBox()
        separator.boxType = .separator
        let container = NSView()
        for v in [scroll, separator, pathBar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pathBar.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 3),
            pathBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            pathBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            pathBar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            pathBar.heightAnchor.constraint(equalToConstant: 20),
        ])
        view = container
    }

    private var scrollView: NSScrollView? { outline.enclosingScrollView }

    // MARK: Unsaved changes

    @objc private func editedStateChanged(_ n: Notification) {
        updateSubtitle()
        refreshChangeMarkers()
    }

    /// Updates the changed-since-save bars on the rows on screen (new rows get theirs when created).
    private func refreshChangeMarkers() {
        outline.enumerateAvailableRowViews { rv, row in
            guard let rv = rv as? EditorRowView, let n = outline.item(atRow: row) as? PlistNode else { return }
            rv.changed = document.isChanged(n)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rv = (outlineView.makeView(withIdentifier: editorRowID, owner: self) as? EditorRowView) ?? {
            let r = EditorRowView()
            r.identifier = editorRowID
            return r
        }()
        rv.changed = (item as? PlistNode).map(document.isChanged) ?? false
        return rv
    }

    // MARK: Path bar

    private func ancestry(_ n: PlistNode) -> [PlistNode] {
        var chain: [PlistNode] = []
        var p: PlistNode? = n
        while let x = p { chain.append(x); p = x.parent }
        return chain.reversed()
    }

    private func updatePathBar() {
        let n = selectedNodes.count == 1 ? selectedNodes[0] : nil
        pathBar.pathItems = (n.map(ancestry) ?? []).map { x in
            let item = NSPathControlItem()
            let title: String
            if x.parent == nil {
                title = "Root"
            } else if x.parent?.kind == .array {
                title = "Item \(x.indexInParent ?? 0)"
            } else {
                title = x.key ?? ""
            }
            item.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)])
            item.image = NSImage(systemSymbolName: Self.symbol(for: x), accessibilityDescription: x.type.rawValue)
            return item
        }
        let path = n.map { $0.parent == nil ? "Root" : $0.dottedKeyPath }
        pathBar.toolTip = path.map { "\($0) — click a part to select it, ⌥⌘C copies the key path" }
    }

    private static func symbol(for n: PlistNode) -> String {
        switch n.kind {
        case .dictionary: return "curlybraces"
        case .array: return "list.number"
        case .string: return "textformat"
        case .integer, .unsignedInteger, .real: return "number"
        case .bool: return "checkmark.square"
        case .date: return "calendar"
        case .data: return "doc.text"
        case .uid: return "link"
        }
    }

    @objc private func pathClicked(_ sender: NSPathControl) {
        guard let clicked = sender.clickedPathItem, let i = sender.pathItems.firstIndex(of: clicked),
              let n = selectedNodes.first else { return }
        let chain = ancestry(n)
        guard i < chain.count else { return }
        revealNode(chain[i])
        view.window?.makeFirstResponder(outline)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        document.onChange = { [weak self] change in self?.apply(change) }
        NotificationCenter.default.addObserver(self, selector: #selector(keyNamesToggled(_:)), name: .pliableKeyNamesToggled, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(editedStateChanged(_:)),
                                               name: PlistDocument.editedStateNotification, object: document)
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
        if document.isDocumentEdited { s += " — Unsaved changes" }
        if !document.orderPreserved { s += " — key order could not be read from this file" }
        let status = searchStatus()
        if let m = status { s += " — " + m }
        findNav?.isEnabled = status != nil && status != "No matches"
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
            break
        }
        updateSubtitle()
        updatePathBar()
        refreshChangeMarkers()
    }

    // MARK: Toolbar

    private let addID = NSToolbarItem.Identifier("add")
    private let removeID = NSToolbarItem.Identifier("remove")
    private let formatID = NSToolbarItem.Identifier("format")
    private let searchID = NSToolbarItem.Identifier("search")
    private var searchItem: NSSearchToolbarItem?
    private let findNavID = NSToolbarItem.Identifier("findNav")
    private var findNav: NSSegmentedControl?

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [addID, removeID, .flexibleSpace, formatID, findNavID, searchID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == searchID {
            let s = NSSearchToolbarItem(itemIdentifier: id)
            s.searchField.placeholderString = "Find Key or Value"
            s.searchField.sendsSearchStringImmediately = false
            s.searchField.target = self
            s.searchField.action = #selector(searchChanged(_:))
            s.searchField.delegate = self
            s.toolTip = "Find (⌘F, next ⌘G, previous ⇧⌘G)"
            searchItem = s
            return s
        }
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case findNavID:
            let c = NSSegmentedControl(images: [
                NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous Match")!,
                NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next Match")!,
            ], trackingMode: .momentary, target: self, action: #selector(findNavClicked(_:)))
            c.setToolTip("Previous Match (⇧⌘G)", forSegment: 0)
            c.setToolTip("Next Match (⌘G)", forSegment: 1)
            c.isEnabled = false
            findNav = c
            item.view = c
            item.label = "Previous / Next Match"
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

    // MARK: Search

    #if DEBUG
    func debugSearch(_ q: String) {
        searchItem?.searchField.stringValue = q
        searchChanged(searchItem!.searchField)
    }
    #endif

    func beginSearch() {
        guard let s = searchItem else { NSSound.beep(); return }
        s.beginSearchInteraction()
        s.searchField.selectText(nil)
    }

    private var searchQuery: String { searchItem?.searchField.stringValue ?? "" }

    @objc private func findNavClicked(_ sender: NSSegmentedControl) {
        find(forward: sender.selectedSegment == 1)
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        refreshHighlights()
        find(forward: true, includeCurrent: true)
    }

    /// Re-renders Key and Value cells so highlights follow the current search text.
    private func refreshHighlights() {
        let cols = IndexSet([keyColumnID, valueColumnID].map { outline.column(withIdentifier: $0) }.filter { $0 >= 0 })
        outline.reloadData(forRowIndexes: IndexSet(0..<outline.numberOfRows), columnIndexes: cols)
    }

    /// Sets the cell text, marking every occurrence of the search text.
    private func setText(_ tf: NSTextField, _ text: String, highlight: Bool) {
        let q = searchQuery
        guard highlight, !q.isEmpty else { tf.stringValue = text; return }
        let attr = NSMutableAttributedString(string: text, attributes: [
            .font: tf.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: tf.textColor ?? .labelColor,
        ])
        var range = text.startIndex..<text.endIndex
        while let r = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: range), !r.isEmpty {
            attr.addAttributes([.backgroundColor: NSColor.findHighlightColor, .foregroundColor: NSColor.black],
                               range: NSRange(r, in: text))
            range = r.upperBound..<text.endIndex
        }
        tf.attributedStringValue = attr
    }

    /// Selects the next (or previous) node whose key or value contains the search text, wrapping around.
    func find(forward: Bool, includeCurrent: Bool = false) {
        guard let q = searchItem?.searchField.stringValue, !q.isEmpty else {
            if !includeCurrent { beginSearch() }
            return
        }
        let all = PlistSearch.preorder(document.root)
        let n = all.count
        let current = selectedNodes.last.flatMap { s in all.firstIndex { $0 === s } }
        let base = current ?? (forward ? n - 1 : 0)
        let first = includeCurrent && current != nil ? 0 : 1
        for k in first...n {
            let i = ((base + (forward ? k : -k)) % n + n) % n
            if PlistSearch.matches(all[i], q) {
                revealNode(all[i])
                updateSubtitle()
                return
            }
        }
        updateSubtitle()
        // Typing a query with no matches just shows "No matches"; only explicit Next/Previous beeps.
        if !includeCurrent { NSSound.beep() }
    }

    /// "2 of 5 matches", "5 matches" (selection isn't a match), "No matches", or nil when not searching.
    private func searchStatus() -> String? {
        let q = searchQuery
        guard !q.isEmpty else { return nil }
        let matches = PlistSearch.find(q, in: document.root)
        if matches.isEmpty { return "No matches" }
        let noun = matches.count == 1 ? "match" : "matches"
        if let sel = selectedNodes.last, let i = matches.firstIndex(where: { $0 === sel }) {
            return "\(i + 1) of \(matches.count) \(noun)"
        }
        return "\(matches.count) \(noun)"
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard let field = searchItem?.searchField, control === field else { return false }
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            find(forward: !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            field.stringValue = ""
            refreshHighlights()
            updateSubtitle()
            view.window?.makeFirstResponder(outline)
            return true
        default:
            return false
        }
    }

    /// Expands all ancestors of `n`, selects it and scrolls it into view.
    func revealNode(_ n: PlistNode) {
        var chain: [PlistNode] = []
        var p = n.parent
        while let x = p { chain.append(x); p = x.parent }
        for a in chain.reversed() { outline.expandItem(a) }
        let row = outline.row(forItem: n)
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    // MARK: View state (kept across reloads from disk)

    struct ViewState {
        var expanded: Set<[String]>
        var selected: [[String]]
        var scroll: NSPoint
    }

    func captureViewState() -> ViewState {
        var expanded = Set<[String]>()
        for r in 0..<outline.numberOfRows {
            if let n = outline.item(atRow: r) as? PlistNode, outline.isItemExpanded(n) { expanded.insert(n.path) }
        }
        return ViewState(expanded: expanded, selected: selectedNodes.map(\.path),
                         scroll: scrollView?.contentView.bounds.origin ?? .zero)
    }

    func restoreViewState(_ st: ViewState) {
        outline.reloadData()
        func expand(_ n: PlistNode) {
            guard n.isContainer, st.expanded.contains(n.path) else { return }
            outline.expandItem(n)
            n.children.forEach(expand)
        }
        outline.expandItem(document.root)
        document.root.children.forEach(expand)
        let rows = IndexSet(st.selected.compactMap { document.root.descendant(at: $0) }.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        outline.selectRowIndexes(rows.isEmpty ? [0] : rows, byExtendingSelection: false)
        if let sv = scrollView {
            sv.contentView.scroll(to: st.scroll)
            sv.reflectScrolledClipView(sv.contentView)
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if !searchQuery.isEmpty { updateSubtitle() }
        updatePathBar()
    }

    /// Typing a key name selects the next visible row whose key starts with it.
    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        guard tableColumn?.identifier == keyColumnID, let n = item as? PlistNode else { return nil }
        if n.parent == nil { return "Root" }
        return n.parent?.kind == .array ? "Item \(n.indexInParent ?? 0)" : n.key
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

    private func keyCell(_ outlineView: NSOutlineView) -> KeyCellView {
        if let c = outlineView.makeView(withIdentifier: keyCellID, owner: self) as? KeyCellView { return c }
        let cell = KeyCellView()
        cell.identifier = keyCellID
        let tf = NSTextField()
        tf.isBordered = false
        tf.drawsBackground = false
        tf.lineBreakMode = .byTruncatingTail
        tf.cell?.usesSingleLineMode = true
        tf.cell?.sendsActionOnEndEditing = true
        tf.delegate = self
        tf.target = self
        tf.action = #selector(textEdited(_:))
        let note = cell.note
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .tertiaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        note.maximumNumberOfLines = 1
        note.cell?.usesSingleLineMode = true
        note.cell?.truncatesLastVisibleLine = true
        note.alignment = .right
        // The key wins the space; the name shrinks (and truncates) first.
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        note.setContentHuggingPriority(.required, for: .horizontal)
        for v in [tf, note] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        cell.textField = tf
        cell.keyWidth = tf.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        cell.keyWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            cell.keyWidth,
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            tf.trailingAnchor.constraint(equalTo: note.leadingAnchor, constant: -6),
            note.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            note.firstBaselineAnchor.constraint(equalTo: tf.firstBaselineAnchor),
        ])
        return cell
    }

    static var showsKeyNames: Bool {
        get { UserDefaults.standard.object(forKey: "ShowKeyNames") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "ShowKeyNames") }
    }

    /// Readable name of a well-known key, or a warning when its value has the wrong type.
    private func configureNote(_ note: NSTextField, for n: PlistNode) {
        guard let key = n.key, let known = KnownKeys.lookup(key, in: n.parent) else {
            note.stringValue = ""
            note.toolTip = nil
            note.isHidden = true
            return
        }
        let mismatch = known.type.map { $0 != n.type } ?? false
        note.isHidden = !(Self.showsKeyNames || mismatch)
        let oneLine = NSMutableParagraphStyle()
        oneLine.lineBreakMode = .byTruncatingTail
        oneLine.alignment = .right
        let title = NSMutableAttributedString(string: Self.showsKeyNames ? known.title : "", attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor,
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
        ])
        // The warning goes first so that it is the part that stays visible when space is short.
        if mismatch, let t = known.type {
            if title.length > 0 { title.insert(NSAttributedString(string: "  "), at: 0) }
            title.insert(NSAttributedString(string: "⚠︎ should be \(t.rawValue)", attributes: [
                .foregroundColor: NSColor.systemOrange,
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
            ]), at: 0)
        }
        title.addAttribute(.paragraphStyle, value: oneLine, range: NSRange(location: 0, length: title.length))
        note.attributedStringValue = title
        var tip = "\(known.title) (\(known.type?.rawValue ?? "several types allowed"))"
        if mismatch, let t = known.type { tip += "\nThis value is a \(n.type.rawValue); apps expect a \(t.rawValue)." }
        if !known.values.isEmpty { tip += "\nValues: " + known.values.joined(separator: ", ") }
        note.toolTip = tip
    }

    @objc func toggleKeyNames(_ sender: Any?) {
        Self.showsKeyNames.toggle()
        NotificationCenter.default.post(name: .pliableKeyNamesToggled, object: nil)
    }

    @objc private func keyNamesToggled(_ n: Notification) {
        let col = outline.column(withIdentifier: keyColumnID)
        guard col >= 0, outline.numberOfRows > 0 else { return }
        outline.reloadData(forRowIndexes: IndexSet(0..<outline.numberOfRows), columnIndexes: [col])
    }

    // MARK: Completion of well-known keys and values

    private var completing = false

    /// Suggestions for the text being typed in a Key or Value cell: well-known keys for this dictionary, or the
    /// values this key allows. `prefix` is the whole field up to the caret.
    private func suggestions(for control: NSControl, prefix: String) -> [String] {
        let row = outline.row(for: control), col = outline.column(for: control)
        guard row >= 0, col >= 0, let n = outline.item(atRow: row) as? PlistNode else { return [] }
        let id = outline.tableColumns[col].identifier
        var out: [String]
        if id == keyColumnID {
            guard let parent = n.parent, parent.kind == .dictionary else { return [] }
            out = KnownKeys.completions(for: prefix, in: parent)
        } else if id == valueColumnID, case .string = n.kind {
            let p = prefix.lowercased()
            out = KnownKeys.allowedValues(for: n).filter { p.isEmpty || $0.lowercased().hasPrefix(p) }
        } else {
            return []
        }
        out.removeAll { $0 == prefix }
        return out
    }

    func control(_ control: NSControl, textView: NSTextView, completions words: [String],
                 forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
        guard control !== searchItem?.searchField else { return [] }
        let full = textView.string as NSString
        let prefix = full.substring(to: min(full.length, NSMaxRange(charRange)))
        // Completions replace only the "word" being typed; strip the part before it (keys contain dots).
        let found = suggestions(for: control, prefix: prefix).compactMap { s -> String? in
            let ns = s as NSString
            return ns.length >= charRange.location ? ns.substring(from: charRange.location) : nil
        }
        index.pointee = -1   // nothing pre-selected: typing on is never overridden
        return found
    }

    /// Shows suggestions as you type a key (or a value with a fixed set of choices).
    func controlTextDidChange(_ obj: Notification) {
        guard !completing, let control = obj.object as? NSTextField, control !== searchItem?.searchField,
              let tv = obj.userInfo?["NSFieldEditor"] as? NSTextView, !tv.string.isEmpty,
              tv.selectedRange().location == (tv.string as NSString).length,
              !suggestions(for: control, prefix: tv.string).isEmpty else { return }
        completing = true
        tv.complete(nil)
        completing = false
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
            let cell = keyCell(outlineView)
            let tf = cell.textField!
            configureNote(cell.note, for: n)
            defer {
                let w = (tf.stringValue as NSString).size(withAttributes: [.font: tf.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width
                cell.keyWidth.constant = ceil(w) + 6
            }
            if n.parent == nil {
                tf.stringValue = "Root"
                tf.isEditable = false
                tf.textColor = .labelColor
            } else if n.parent?.kind == .array {
                tf.stringValue = "Item \(n.indexInParent ?? 0)"
                tf.isEditable = false
                tf.textColor = .secondaryLabelColor
            } else {
                tf.isEditable = true
                tf.textColor = .labelColor
                setText(tf, n.key ?? "", highlight: true)
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
            let popover = ValueEditorController.prefersPopover(n)
            tf.isEditable = ValueText.isEditable(n) && !popover
            tf.textColor = n.isContainer ? .secondaryLabelColor : .labelColor
            setText(tf, Self.cellText(n), highlight: !n.isContainer)
            tf.toolTip = popover ? "Double-click or press ↩ to edit" : nil
            return cell
        }
    }

    /// One-line rendering for a Value cell: line breaks in strings shown as ⏎.
    static func cellText(_ n: PlistNode) -> String {
        guard case .string(let s) = n.kind, s.contains(where: \.isNewline) else { return ValueText.display(n) }
        return s.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).joined(separator: " ⏎ ")
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
            // A new, empty item renamed to a well-known key takes that key's type (like Xcode).
            if case .string("") = n.kind, let t = KnownKeys.lookup(text, in: parent)?.type, t != .string {
                document.replaceContents(n, kind: ValueText.defaultKind(t), children: [], childKeys: [])
            }
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
        if id == valueColumnID, ValueEditorController.prefersPopover(n) { showValueEditor(n, row: row); return }
        if id == keyColumnID, n.parent?.kind != .dictionary { return }
        if id == valueColumnID, !ValueText.isEditable(n) { return }
        if id == typeColumnID { return }
        outline.editColumn(column, row: row, with: nil, select: true)
    }

    func beginEditingSelectedRow() {
        let row = outline.selectedRow
        guard row >= 0, let n = outline.item(atRow: row) as? PlistNode else { return }
        let col = ValueText.isEditable(n) || ValueEditorController.prefersPopover(n) ? valueColumnID : keyColumnID
        edit(row: row, column: outline.column(withIdentifier: col))
    }

    private func showValueEditor(_ n: PlistNode, row: Int) {
        let col = outline.column(withIdentifier: valueColumnID)
        guard col >= 0, let anchor = outline.view(atColumn: col, row: row, makeIfNecessary: true) else { return }
        ValueEditorController.show(for: n, relativeTo: anchor) { [weak self] kind in
            guard let self else { return }
            self.document.replaceContents(n, kind: kind, children: [], childKeys: [])
            self.document.undoManager?.setActionName("Change Value")
        }
    }

    /// Opens the popover editor (multi-line text, date picker, hex) for the selected value (⌥↩).
    @objc func editValue(_ sender: Any?) {
        let row = outline.selectedRow
        guard outline.selectedRowIndexes.count == 1, let n = outline.item(atRow: row) as? PlistNode,
              ValueEditorController.canEdit(n) else { NSSound.beep(); return }
        outline.scrollRowToVisible(row)
        showValueEditor(n, row: row)
    }

    // MARK: Key paths, sorting, duplicating

    private func copyStrings(_ paths: [String]) {
        guard !paths.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc func copyKeyPath(_ sender: Any?) { copyStrings(selectedNodes.map(\.dottedKeyPath)) }
    @objc func copyPlistBuddyPath(_ sender: Any?) { copyStrings(selectedNodes.map(\.plistBuddyPath)) }

    /// The dictionary Sort Keys acts on: the selected dictionary, else the one containing the selection, else Root.
    private var sortTarget: PlistNode? {
        guard let n = selectedNodes.last else { return document.root.kind == .dictionary ? document.root : nil }
        if n.kind == .dictionary { return n }
        return n.parent?.kind == .dictionary ? n.parent : nil
    }

    private func sortKeys(recursive: Bool) {
        guard finishCellEditing() else { return }
        guard let target = sortTarget else { NSSound.beep(); return }
        let state = captureViewState()
        var count = 0
        func walk(_ n: PlistNode) {
            if let sorted = n.childrenSortedByKey() {
                document.replaceContents(n, kind: .dictionary, children: sorted, childKeys: sorted.map(\.key))
                count += 1
            }
            if recursive { n.children.forEach(walk) }
        }
        walk(target)
        guard count > 0 else { NSSound.beep(); return }
        document.undoManager?.setActionName("Sort Keys")
        restoreViewState(state)
    }

    @objc func sortKeys(_ sender: Any?) { sortKeys(recursive: false) }
    @objc func sortKeysRecursively(_ sender: Any?) { sortKeys(recursive: true) }

    /// Inserts a copy of each selected item right after it (dictionary keys get a " - 2" style suffix).
    @objc func duplicate(_ sender: Any?) {
        guard finishCellEditing() else { return }
        let nodes = topLevelSelection.sorted { outline.row(forItem: $0) > outline.row(forItem: $1) }
        guard !nodes.isEmpty else { NSSound.beep(); return }
        var copies: [PlistNode] = []
        for n in nodes {
            guard let p = n.parent, let i = n.indexInParent else { continue }
            let c = n.deepCopy()
            if p.kind == .dictionary { c.key = p.uniqueChildKey(base: n.key ?? "New item") }
            document.insert(c, into: p, at: i + 1)
            copies.append(c)
        }
        document.undoManager?.setActionName(copies.count == 1 ? "Duplicate Item" : "Duplicate Items")
        let rows = IndexSet(copies.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        if let r = rows.first { outline.scrollRowToVisible(r) }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        // Right-clicking outside the selection acts on the clicked row, like Finder.
        if row >= 0, !outline.selectedRowIndexes.contains(row) {
            outline.selectRowIndexes([row], byExtendingSelection: false)
        }
        func add(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = self
            menu.addItem(i)
        }
        add("Edit Value…", #selector(editValue(_:)), "\r", [.command, .option])
        add("Add Item", #selector(addItem(_:)), "\r")
        add("Duplicate", #selector(duplicate(_:)), "d")
        add("Delete", #selector(deleteItems(_:)), "\u{8}")
        menu.addItem(.separator())
        add("Cut", #selector(cut(_:)), "x")
        add("Copy", #selector(copy(_:)), "c")
        add("Paste", #selector(paste(_:)), "v")
        menu.addItem(.separator())
        add("Copy Key Path", #selector(copyKeyPath(_:)), "c", [.command, .option])
        add("Copy PlistBuddy Path", #selector(copyPlistBuddyPath(_:)))
        menu.addItem(.separator())
        add("Sort Keys", #selector(sortKeys(_:)))
        add("Sort Keys Recursively", #selector(sortKeysRecursively(_:)))
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

    /// Commits a cell edit in progress (or ends one in the search field) and focuses the outline. Commands that
    /// change the tree call this first: reloading rows under an open field editor drops the typed text and can
    /// leave the keyboard focus nowhere. Returns false if the edit couldn't be committed (e.g. invalid input).
    @discardableResult
    private func finishCellEditing() -> Bool {
        guard let w = view.window else { return true }
        if w.firstResponder === outline { return true }
        return w.makeFirstResponder(outline)
    }

    private func reveal(_ n: PlistNode, edit column: NSUserInterfaceItemIdentifier?) {
        if let p = n.parent { outline.expandItem(p) }
        let row = outline.row(forItem: n)
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        guard let c = column else { return }
        view.window?.makeFirstResponder(outline)
        outline.layoutSubtreeIfNeeded()
        edit(row: row, column: outline.column(withIdentifier: c))
    }

    @objc func addItem(_ sender: Any?) {
        guard finishCellEditing() else { return }
        guard let (parent, index) = insertionPoint() else { NSSound.beep(); return }
        let key = parent.kind == .dictionary ? parent.uniqueChildKey(base: "New item") : nil
        let child = PlistNode(key: key, kind: .string(""))
        document.insert(child, into: parent, at: index)
        document.undoManager?.setActionName("Add Item")
        reveal(child, edit: parent.kind == .dictionary ? keyColumnID : valueColumnID)
    }

    @objc func deleteItems(_ sender: Any?) {
        guard finishCellEditing() else { return }
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
        guard finishCellEditing() else { return }
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
        case #selector(toggleKeyNames(_:)):
            menuItem.state = Self.showsKeyNames ? .on : .off
            return true
        case #selector(editValue(_:)):
            return outline.selectedRowIndexes.count == 1 && selectedNodes.first.map(ValueEditorController.canEdit) == true
        case #selector(duplicate(_:)):
            return !topLevelSelection.isEmpty
        case #selector(copyKeyPath(_:)), #selector(copyPlistBuddyPath(_:)):
            return !selectedNodes.isEmpty
        case #selector(sortKeys(_:)):
            return sortTarget?.childrenSortedByKey() != nil
        case #selector(sortKeysRecursively(_:)):
            return sortTarget != nil
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

    private func droppedFileURL(_ info: NSDraggingInfo) -> URL? {
        guard info.draggingSource as? NSOutlineView !== outline else { return nil }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.first
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        if droppedFileURL(info) != nil {
            // A file from Finder: the whole view is the target.
            outline.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .copy
        }
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
        if let url = droppedFileURL(info) {
            // Let the drag finish before showing the sheet.
            DispatchQueue.main.async { [weak self] in self?.document.handleDroppedFile(url) }
            return true
        }
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
