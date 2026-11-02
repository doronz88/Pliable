import Foundation

/// Finds nodes whose key or (scalar) value contains a query string.
public enum PlistSearch {
    public static func matches(_ n: PlistNode, _ query: String) -> Bool {
        guard !query.isEmpty, n.parent != nil else { return false }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if let k = n.key, k.range(of: query, options: opts) != nil { return true }
        if n.isContainer { return false }
        return ValueText.display(n).range(of: query, options: opts) != nil
    }

    /// All matching nodes under `root`, depth-first in display order.
    public static func find(_ query: String, in root: PlistNode) -> [PlistNode] {
        var out: [PlistNode] = []
        func walk(_ n: PlistNode) {
            if matches(n, query) { out.append(n) }
            n.children.forEach(walk)
        }
        walk(root)
        return out
    }

    /// Every node under `root` in depth-first display order.
    public static func preorder(_ root: PlistNode) -> [PlistNode] {
        var out: [PlistNode] = []
        func walk(_ n: PlistNode) { out.append(n); n.children.forEach(walk) }
        walk(root)
        return out
    }
}

public extension PlistNode {
    /// Path from the root: dictionary keys and array indices (same form as `PlistDiff.Entry.path`).
    var path: [String] {
        var out: [String] = []
        var n = self
        while let p = n.parent {
            out.append(p.kind == .array ? String(n.indexInParent ?? 0) : (n.key ?? ""))
            n = p
        }
        return out.reversed()
    }

    /// Resolves a `path` below this node; nil when any component is missing.
    func descendant(at path: [String]) -> PlistNode? {
        var n = self
        for c in path {
            if n.kind == .array {
                guard let i = Int(c), n.children.indices.contains(i) else { return nil }
                n = n.children[i]
            } else {
                guard let next = n.children.first(where: { $0.key.map { $0.utf8.elementsEqual(c.utf8) } == true }) else { return nil }
                n = next
            }
        }
        return n
    }
}
