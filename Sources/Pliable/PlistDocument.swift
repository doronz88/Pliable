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
        onChange?(.children(root))
        onChange?(.format)
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
        onChange?(.row(node))
    }

    func replaceContents(_ node: PlistNode, kind: PlistNode.Kind, children: [PlistNode], childKeys: [String?]) {
        let oldKind = node.kind
        let oldChildren = node.children
        let oldKeys = oldChildren.map(\.key)
        undoManager?.registerUndo(withTarget: self) { $0.replaceContents(node, kind: oldKind, children: oldChildren, childKeys: oldKeys) }
        node.kind = kind
        for (c, k) in zip(children, childKeys) { c.key = k }
        node.setChildren(children)
        onChange?(.children(node))
    }

    func insert(_ child: PlistNode, into parent: PlistNode, at index: Int) {
        undoManager?.registerUndo(withTarget: self) { $0.remove(from: parent, at: index) }
        parent.insertChild(child, at: index)
        onChange?(.children(parent))
    }

    func remove(from parent: PlistNode, at index: Int) {
        let child = parent.children[index]
        undoManager?.registerUndo(withTarget: self) { $0.insert(child, into: parent, at: index) }
        parent.removeChild(at: index)
        onChange?(.children(parent))
    }

    func setFormat(_ f: PlistFormat) {
        let old = format
        guard f != old else { return }
        undoManager?.registerUndo(withTarget: self) { $0.setFormat(old) }
        undoManager?.setActionName("Change Format")
        format = f
        onChange?(.format)
    }

    /// Returns an error message if the tree can't be saved in `f`.
    func problem(savingAs f: PlistFormat) -> String? {
        var copy = file
        copy.root = root
        copy.format = f
        do { _ = try copy.write(); return nil } catch { return error.localizedDescription }
    }
}
