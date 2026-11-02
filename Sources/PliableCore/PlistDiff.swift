import Foundation

public enum PlistDiff {
    public enum Change: Equatable {
        case added      // only in the right tree
        case removed    // only in the left tree
        case changed    // in both, different type or value
    }
}

/// Both trees merged into one, row-aligned for a side-by-side view.
public final class DiffNode {
    public enum Side {
        case left, right
        public var opposite: Side { self == .left ? .right : .left }
    }

    /// Dictionary key, or array index as a string (nil for the root).
    public let component: String?
    public let isArrayElement: Bool
    public let left: PlistNode?
    public let right: PlistNode?
    /// nil when this node itself is the same on both sides (children may still differ).
    public let change: PlistDiff.Change?
    public private(set) var children: [DiffNode] = []
    public private(set) weak var parent: DiffNode?
    /// True when this node or anything below it differs.
    public private(set) var hasDifferences = false

    init(component: String?, isArrayElement: Bool, left: PlistNode?, right: PlistNode?, change: PlistDiff.Change?) {
        self.component = component
        self.isArrayElement = isArrayElement
        self.left = left
        self.right = right
        self.change = change
    }

    public func node(_ side: Side) -> PlistNode? { side == .left ? left : right }

    /// Where a copy of the other side's node goes in `side`'s parent container, when this row is missing there:
    /// right after the nearest preceding row that exists on `side` (or first). Nil if the parent itself
    /// differs in type or is missing on `side`.
    public func insertionIndex(on side: Side) -> Int? {
        guard let p = parent, p.change == nil, let container = p.node(side), container.isContainer,
              let i = p.children.firstIndex(where: { $0 === self }) else { return nil }
        for sib in p.children[..<i].reversed() {
            if let n = sib.node(side), n.parent === container, let j = n.indexInParent { return j + 1 }
        }
        return 0
    }

    /// Path in the same form as `PlistNode.path`.
    public var path: [String] {
        var out: [String] = []
        var n: DiffNode? = self
        while let x = n, let c = x.component { out.append(c); n = x.parent }
        return out.reversed()
    }

    public static func build(_ left: PlistNode, _ right: PlistNode) -> DiffNode {
        make(component: nil, isArrayElement: false, left, right)
    }

    private static func make(component: String?, isArrayElement: Bool, _ l: PlistNode?, _ r: PlistNode?) -> DiffNode {
        let change: PlistDiff.Change?
        switch (l, r) {
        case (nil, _): change = .added
        case (_, nil): change = .removed
        case let (l?, r?):
            if l.isContainer || r.isContainer {
                change = l.type == r.type ? nil : .changed
            } else {
                change = l.kind == r.kind ? nil : .changed
            }
        }
        let node = DiffNode(component: component, isArrayElement: isArrayElement, left: l, right: r, change: change)
        var kids: [DiffNode] = []
        if let l, let r, change == nil {
            if l.kind == .dictionary {
                for (k, lc, rc) in mergedKeys(l, r) {
                    kids.append(make(component: k, isArrayElement: false, lc, rc))
                }
            } else if l.kind == .array {
                for i in 0..<max(l.children.count, r.children.count) {
                    kids.append(make(component: String(i), isArrayElement: true,
                                     i < l.children.count ? l.children[i] : nil,
                                     i < r.children.count ? r.children[i] : nil))
                }
            }
        } else {
            // One side only, or the type changed: show each side's contents as removed / added.
            for side in [l, r] {
                guard let s = side, s.isContainer else { continue }
                for (i, c) in s.children.enumerated() {
                    let comp = s.kind == .array ? String(i) : (c.key ?? "")
                    kids.append(make(component: comp, isArrayElement: s.kind == .array,
                                     side === l ? c : nil, side === r ? c : nil))
                }
            }
        }
        node.children = kids
        for k in kids { k.parent = node }
        node.hasDifferences = change != nil || kids.contains { $0.hasDifferences }
        return node
    }

    /// Left keys in left order; keys only on the right are placed after the key that precedes them on the right.
    /// Keys compare literally (like CFEqual), not by Unicode canonical equivalence.
    private static func mergedKeys(_ l: PlistNode, _ r: PlistNode) -> [(String, PlistNode?, PlistNode?)] {
        var rightByKey: [Data: PlistNode] = [:]
        for c in r.children { rightByKey[Data((c.key ?? "").utf8)] = c }
        var leftIndex: [Data: Int] = [:]
        var out: [(String, PlistNode?, PlistNode?)] = []
        for c in l.children {
            let k = c.key ?? ""
            leftIndex[Data(k.utf8)] = out.count
            out.append((k, c, rightByKey[Data(k.utf8)]))
        }
        // Right-only keys go after their nearest preceding shared key (or first, if none).
        var after: [Int: [(String, PlistNode?, PlistNode?)]] = [:]   // left position -> inserts, -1 = start
        var anchor = -1
        for c in r.children {
            let k = c.key ?? ""
            if let i = leftIndex[Data(k.utf8)] { anchor = i } else { after[anchor, default: []].append((k, nil, c)) }
        }
        var merged = after[-1] ?? []
        for (i, e) in out.enumerated() {
            merged.append(e)
            merged += after[i] ?? []
        }
        return merged
    }
}
