import Foundation

/// Structural difference between two property list trees.
/// Dictionaries are matched by key, arrays by index.
public enum PlistDiff {
    public enum Change: Equatable {
        case added      // only in the right tree
        case removed    // only in the left tree
        case changed    // in both, different type or value
    }

    public struct Entry {
        public let change: Change
        /// Path components from the root, e.g. ["CFBundleURLTypes", "0", "CFBundleURLName"].
        public let path: [String]
        public let left: PlistNode?
        public let right: PlistNode?

        public var pathString: String { path.isEmpty ? "Root" : path.joined(separator: " › ") }
    }

    public static func diff(_ left: PlistNode, _ right: PlistNode) -> [Entry] {
        var out: [Entry] = []
        compare(left, right, path: [], into: &out)
        return out
    }

    private static func compare(_ l: PlistNode, _ r: PlistNode, path: [String], into out: inout [Entry]) {
        switch (l.kind, r.kind) {
        case (.dictionary, .dictionary):
            // Left order first, then keys only on the right in right order.
            for lc in l.children {
                let k = lc.key ?? ""
                if let rc = r.children.first(where: { $0.key.map { $0.utf8.elementsEqual(k.utf8) } == true }) {
                    compare(lc, rc, path: path + [k], into: &out)
                } else {
                    out.append(Entry(change: .removed, path: path + [k], left: lc, right: nil))
                }
            }
            for rc in r.children {
                let k = rc.key ?? ""
                if !l.hasChildKey(k) {
                    out.append(Entry(change: .added, path: path + [k], left: nil, right: rc))
                }
            }
        case (.array, .array):
            let n = max(l.children.count, r.children.count)
            for i in 0..<n {
                let p = path + [String(i)]
                switch (i < l.children.count ? l.children[i] : nil, i < r.children.count ? r.children[i] : nil) {
                case let (lc?, rc?): compare(lc, rc, path: p, into: &out)
                case let (lc?, nil): out.append(Entry(change: .removed, path: p, left: lc, right: nil))
                case let (nil, rc?): out.append(Entry(change: .added, path: p, left: nil, right: rc))
                default: break
                }
            }
        default:
            let same = l.isContainer || r.isContainer ? false : l.kind == r.kind
            if !same { out.append(Entry(change: .changed, path: path, left: l, right: r)) }
        }
    }
}
