import AppKit
import PliableCore

/// Popover editors for values that don't fit a one-line cell: multi-line strings, dates (calendar and clock)
/// and data (hex with an ASCII column). Save commits (⌘↩), Esc cancels, clicking outside commits valid changes.
final class ValueEditorController: NSViewController, NSPopoverDelegate, NSTextViewDelegate {
    private enum Mode { case string, date, data }

    /// Data larger than this is shown read-only (formatting and editing megabytes of hex isn't useful).
    private static let maxEditableData = 256 * 1024

    private let mode: Mode
    private let original: PlistNode.Kind
    private let commitHandler: (PlistNode.Kind) -> Void
    private weak var popover: NSPopover?
    private var finished = false

    private let textView = NSTextView()
    private let asciiView = NSTextView()
    private let calendarPicker = NSDatePicker()
    private let textPicker = NSDatePicker()
    private let info = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private var readOnly = false
    /// The pickers work in whole seconds; leave a date alone unless the user changed it.
    private var dateTouched = false

    /// Whether `n` has a popover editor at all (Edit Value…).
    static func canEdit(_ n: PlistNode) -> Bool {
        switch n.kind {
        case .string, .date, .data: return true
        default: return false
        }
    }

    /// Whether double-click / Return should open the popover instead of editing in the cell.
    static func prefersPopover(_ n: PlistNode) -> Bool {
        switch n.kind {
        case .date: return true
        case .data(let d): return d.count > 64 || !ValueText.isEditable(n)
        case .string(let s): return s.contains(where: \.isNewline) || s.count > 200
        default: return false
        }
    }

    /// Shows the editor for `node` next to `view`; `commit` is called with the new contents if they changed.
    static func show(for node: PlistNode, relativeTo view: NSView, commit: @escaping (PlistNode.Kind) -> Void) {
        guard canEdit(node) else { NSSound.beep(); return }
        let c = ValueEditorController(node: node, commit: commit)
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = c
        p.delegate = c
        c.popover = p
        p.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        c.focus()
    }

    private init(node: PlistNode, commit: @escaping (PlistNode.Kind) -> Void) {
        switch node.kind {
        case .date: mode = .date
        case .data: mode = .data
        default: mode = .string
        }
        original = node.kind
        commitHandler = commit
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    override func loadView() {
        let content: NSView
        switch mode {
        case .string: content = buildString()
        case .date: content = buildDate()
        case .data: content = buildData()
        }
        info.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        info.textColor = .secondaryLabelColor
        info.lineBreakMode = .byTruncatingTail
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(save(_:))
        saveButton.keyEquivalent = "\r"
        // In text modes Return types a newline, so Save is ⌘↩ there.
        saveButton.keyEquivalentModifierMask = mode == .date ? [] : .command
        saveButton.toolTip = mode == .date ? "Save (↩)" : "Save (⌘↩)"
        saveButton.isEnabled = !readOnly
        saveButton.bezelColor = .controlAccentColor
        for b in [cancel, saveButton] { b.controlSize = .regular }
        let bar = NSStackView(views: [info, cancel, saveButton])
        bar.orientation = .horizontal
        bar.spacing = 8
        info.setContentHuggingPriority(.defaultLow, for: .horizontal)
        info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [content, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        content.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
        view = stack
        updateInfo()
    }

    private func scrolling(_ tv: NSTextView, width: CGFloat, height: CGFloat) -> NSScrollView {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.borderType = .bezelBorder
        sv.autohidesScrollers = true
        tv.minSize = NSSize(width: 0, height: height)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = .width
        tv.textContainer?.widthTracksTextView = true
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        sv.documentView = tv
        sv.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sv.widthAnchor.constraint(greaterThanOrEqualToConstant: width),
            sv.heightAnchor.constraint(equalToConstant: height),
        ])
        return sv
    }

    private func buildString() -> NSView {
        guard case .string(let s) = original else { return NSView() }
        textView.string = s
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.delegate = self
        return scrolling(textView, width: 460, height: 220)
    }

    private func buildDate() -> NSView {
        guard case .date(let d) = original else { return NSView() }
        calendarPicker.datePickerStyle = .clockAndCalendar
        textPicker.datePickerStyle = .textFieldAndStepper
        for p in [calendarPicker, textPicker] {
            p.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
            p.dateValue = d
            p.target = self
            p.action = #selector(dateChanged(_:))
            p.isBezeled = true
        }
        let now = NSButton(title: "Now", target: self, action: #selector(setNow(_:)))
        now.controlSize = .small
        let row = NSStackView(views: [textPicker, now])
        row.orientation = .horizontal
        let stack = NSStackView(views: [row, calendarPicker])
        stack.orientation = .vertical
        stack.alignment = .leading
        return stack
    }

    private func buildData() -> NSView {
        guard case .data(let d) = original else { return NSView() }
        readOnly = d.count > Self.maxEditableData
        let shown = readOnly ? d.prefix(Self.maxEditableData) : d
        let mono = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.font = mono
        textView.string = HexText.format(shown)
        textView.isEditable = !readOnly
        textView.delegate = self
        asciiView.font = mono
        asciiView.isEditable = false
        asciiView.textColor = .secondaryLabelColor
        asciiView.string = HexText.ascii(shown)
        // 16 bytes per line: 32 hex digits + 3 group spaces; 16 ASCII characters.
        let charW = ("0" as NSString).size(withAttributes: [.font: mono]).width
        let hex = scrolling(textView, width: ceil(charW * 35 + 30), height: 260)
        let ascii = scrolling(asciiView, width: ceil(charW * 16 + 30), height: 260)
        ascii.hasVerticalScroller = false
        // Keep the ASCII column scrolled with the hex column.
        hex.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: hex.contentView, queue: .main) { [weak ascii, weak hex] _ in
            guard let ascii, let hex else { return }
            ascii.contentView.scroll(to: NSPoint(x: 0, y: hex.contentView.bounds.origin.y))
            ascii.reflectScrolledClipView(ascii.contentView)
        }
        let row = NSStackView(views: [hex, ascii])
        row.orientation = .horizontal
        row.alignment = .top
        return row
    }

    private func focus() {
        switch mode {
        case .string, .data: view.window?.makeFirstResponder(textView)
        case .date: view.window?.makeFirstResponder(textPicker)
        }
    }

    // MARK: State

    /// The edited contents, or nil when the text isn't valid for the type.
    private var currentKind: PlistNode.Kind? {
        switch mode {
        case .string: return .string(textView.string)
        case .date: return dateTouched ? .date(calendarPicker.dateValue) : original
        case .data: return HexText.parse(textView.string).map { .data($0) }
        }
    }

    private func updateInfo() {
        switch mode {
        case .string:
            let s = textView.string
            let lines = s.isEmpty ? 0 : s.split(separator: "\n", omittingEmptySubsequences: false).count
            info.stringValue = "\(s.count) characters · \(lines) line\(lines == 1 ? "" : "s")"
        case .date:
            info.stringValue = "Time zone: \(TimeZone.current.localizedName(for: .standard, locale: .current) ?? TimeZone.current.identifier)"
        case .data:
            if readOnly, case .data(let d) = original {
                info.stringValue = "\(d.count) bytes — too large to edit here; showing the first \(Self.maxEditableData / 1024) KB"
            } else if let d = HexText.parse(textView.string) {
                info.stringValue = "\(d.count) byte\(d.count == 1 ? "" : "s")"
                info.textColor = .secondaryLabelColor
                asciiView.string = HexText.ascii(d)
            } else {
                info.stringValue = "Not valid hex (needs pairs of 0–9, a–f)"
                info.textColor = .systemRed
            }
            saveButton.isEnabled = !readOnly && HexText.parse(textView.string) != nil
        }
    }

    func textDidChange(_ notification: Notification) { updateInfo() }

    func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { cancel(nil); return true }
        return false
    }

    @objc private func dateChanged(_ sender: NSDatePicker) {
        let other = sender === calendarPicker ? textPicker : calendarPicker
        other.dateValue = sender.dateValue
        dateTouched = true
    }

    @objc private func setNow(_ sender: Any?) {
        let d = Date(timeIntervalSinceReferenceDate: floor(Date().timeIntervalSinceReferenceDate))
        calendarPicker.dateValue = d
        textPicker.dateValue = d
        dateTouched = true
    }

    // MARK: Finishing

    @objc private func save(_ sender: Any?) {
        guard currentKind != nil else { NSSound.beep(); return }
        finish(commit: true)
    }

    @objc private func cancel(_ sender: Any?) { finish(commit: false) }

    override func cancelOperation(_ sender: Any?) { cancel(sender) }

    private func finish(commit: Bool) {
        guard !finished else { return }
        finished = true
        if commit, !readOnly, let k = currentKind, k != original { commitHandler(k) }
        popover?.close()
    }

    /// Clicking outside the popover keeps valid changes, like editing in a cell and clicking away.
    func popoverDidClose(_ notification: Notification) {
        finish(commit: true)
    }
}
