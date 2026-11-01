import Foundation

/// One node of a property list tree. Containers keep their children in file order.
public final class PlistNode {
    public enum Kind: Equatable {
        case dictionary
        case array
        case string(String)
        case integer(Int64)
        /// Only used for values above Int64.max (stored as 16-byte ints in binary plists).
        case unsignedInteger(UInt64)
        case real(Double)
        case bool(Bool)
        case date(Date)
        case data(Data)
        /// NSKeyedArchiver UID (binary marker 0x8, XML `<dict><key>CF$UID</key>…`).
        case uid(UInt64)

        public static func == (a: Kind, b: Kind) -> Bool {
            switch (a, b) {
            case (.dictionary, .dictionary), (.array, .array): return true
            case let (.string(x), .string(y)): return x.utf8.elementsEqual(y.utf8)
            case let (.integer(x), .integer(y)): return x == y
            case let (.unsignedInteger(x), .unsignedInteger(y)): return x == y
            case let (.real(x), .real(y)): return x.bitPattern == y.bitPattern || x == y
            case let (.bool(x), .bool(y)): return x == y
            case let (.date(x), .date(y)): return x.timeIntervalSinceReferenceDate == y.timeIntervalSinceReferenceDate
            case let (.data(x), .data(y)): return x == y
            case let (.uid(x), .uid(y)): return x == y
            default: return false
            }
        }
    }

    /// Key in the parent dictionary; nil for the root and for array elements.
    public var key: String?
    public var kind: Kind
    public private(set) var children: [PlistNode] = []
    public internal(set) weak var parent: PlistNode?

    public init(key: String? = nil, kind: Kind, children: [PlistNode] = []) {
        self.key = key
        self.kind = kind
        setChildren(children)
    }

    public var isContainer: Bool { kind == .dictionary || kind == .array }

    public var type: PlistType { PlistType(kind) }

    public func setChildren(_ newChildren: [PlistNode]) {
        children = newChildren
        for c in children { c.parent = self }
    }

    public func insertChild(_ child: PlistNode, at index: Int) {
        children.insert(child, at: index)
        child.parent = self
    }

    @discardableResult
    public func removeChild(at index: Int) -> PlistNode {
        let c = children.remove(at: index)
        c.parent = nil
        return c
    }

    public func appendChild(_ child: PlistNode) {
        children.append(child)
        child.parent = self
    }

    public var indexInParent: Int? {
        parent?.children.firstIndex { $0 === self }
    }

    public func isDescendant(of other: PlistNode) -> Bool {
        var p: PlistNode? = self
        while let n = p {
            if n === other { return true }
            p = n.parent
        }
        return false
    }

    public func deepCopy() -> PlistNode {
        PlistNode(key: key, kind: kind, children: children.map { $0.deepCopy() })
    }

    /// Structural equality including key order.
    public func isIdentical(to other: PlistNode) -> Bool {
        let sameKey: Bool
        switch (key, other.key) {
        case (nil, nil): sameKey = true
        case let (a?, b?): sameKey = a.utf8.elementsEqual(b.utf8)
        default: sameKey = false
        }
        guard sameKey, kind == other.kind, children.count == other.children.count else { return false }
        for (a, b) in zip(children, other.children) where !a.isIdentical(to: b) { return false }
        return true
    }

    public func hasChildKey(_ key: String, excluding: PlistNode? = nil) -> Bool {
        children.contains { $0 !== excluding && $0.key.map { $0.utf8.elementsEqual(key.utf8) } == true }
    }

    /// Returns a key not yet used among this dictionary's children.
    public func uniqueChildKey(base: String, excluding: PlistNode? = nil) -> String {
        // Literal comparison (like CFEqual), not Swift's canonical-equivalence ==.
        let used = Set(children.filter { $0 !== excluding }.compactMap { $0.key.map { Array($0.utf8) } })
        if !used.contains(Array(base.utf8)) { return base }
        var i = 2
        while used.contains(Array("\(base) - \(i)".utf8)) { i += 1 }
        return "\(base) - \(i)"
    }
}

public enum PlistType: String, CaseIterable {
    case dictionary = "Dictionary"
    case array = "Array"
    case string = "String"
    case integer = "Integer"
    case real = "Real"
    case boolean = "Boolean"
    case date = "Date"
    case data = "Data"
    case uid = "UID"

    public init(_ kind: PlistNode.Kind) {
        switch kind {
        case .dictionary: self = .dictionary
        case .array: self = .array
        case .string: self = .string
        case .integer, .unsignedInteger: self = .integer
        case .real: self = .real
        case .bool: self = .boolean
        case .date: self = .date
        case .data: self = .data
        case .uid: self = .uid
        }
    }
}

public enum PlistFormat: String, CaseIterable {
    case xml, binary, openStep, strings

    public var displayName: String {
        switch self {
        case .xml: return "XML"
        case .binary: return "Binary"
        case .openStep: return "OpenStep"
        case .strings: return "Strings file"
        }
    }
}

public struct PlistError: LocalizedError, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}
