import Foundation

/// Text shown in and parsed from the editor's Value column, and type conversions.
public enum ValueText {
    public static let maxEditableDataBytes = 512

    public static func display(_ n: PlistNode) -> String {
        switch n.kind {
        case .dictionary, .array:
            let c = n.children.count
            return c == 1 ? "(1 item)" : "(\(c) items)"
        case .string(let s): return s
        case .integer(let v): return String(v)
        case .unsignedInteger(let v): return String(v)
        case .real(let v): return XMLPlistWriter.realString(v)
        case .bool(let b): return b ? "YES" : "NO"
        case .date(let d): return PlistDates.formatPrecise(d)
        case .data(let d):
            let shown = d.prefix(maxEditableDataBytes)
            var s = "<"
            for (i, byte) in shown.enumerated() {
                if i > 0, i % 4 == 0 { s += " " }
                s += String(format: "%02x", byte)
            }
            s += ">"
            if d.count > shown.count { s += " … (\(d.count) bytes)" }
            return s
        case .uid(let v): return String(v)
        }
    }

    public static func isEditable(_ n: PlistNode) -> Bool {
        switch n.kind {
        case .dictionary, .array, .bool: return false
        case .data(let d): return d.count <= maxEditableDataBytes
        default: return true
        }
    }

    public static func parse(_ text: String, as type: PlistType) -> PlistNode.Kind? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case .string: return .string(text)
        case .integer: return parseInteger(t)
        case .real: return parseReal(t).map { .real($0) }
        case .boolean:
            switch t.lowercased() {
            case "yes", "true", "1": return .bool(true)
            case "no", "false", "0": return .bool(false)
            default: return nil
            }
        case .date: return PlistDates.parse(t).map { .date($0) }
        case .data:
            var hex = t
            if hex.hasPrefix("<") { hex.removeFirst() }
            if hex.hasSuffix(">") { hex.removeLast() }
            hex = String(hex.filter { !$0.isWhitespace })
            if hex.lowercased().hasPrefix("0x") { hex.removeFirst(2) }
            guard hex.count % 2 == 0 else { return nil }
            var bytes = [UInt8]()
            bytes.reserveCapacity(hex.count / 2)
            var i = hex.startIndex
            while i < hex.endIndex {
                let j = hex.index(i, offsetBy: 2)
                guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
                bytes.append(b)
                i = j
            }
            return .data(Data(bytes))
        case .uid:
            guard let v = UInt64(t), v <= UInt64(UInt32.max) else { return nil }
            return .uid(v)
        case .dictionary: return .dictionary
        case .array: return .array
        }
    }

    public static func defaultKind(_ type: PlistType) -> PlistNode.Kind {
        switch type {
        case .dictionary: return .dictionary
        case .array: return .array
        case .string: return .string("")
        case .integer: return .integer(0)
        case .real: return .real(0)
        case .boolean: return .bool(false)
        case .date: return .date(Date(timeIntervalSinceReferenceDate: floor(Date().timeIntervalSinceReferenceDate)))
        case .data: return .data(Data())
        case .uid: return .uid(0)
        }
    }

    public struct Conversion {
        public let kind: PlistNode.Kind
        public let children: [PlistNode]
        public let childKeys: [String?]
    }

    /// New contents for `node` after changing its type; nil if the type is unchanged.
    public static func convert(_ node: PlistNode, to type: PlistType) -> Conversion? {
        if node.type == type { return nil }
        switch type {
        case .dictionary:
            guard node.kind == .array else { return Conversion(kind: .dictionary, children: [], childKeys: []) }
            var keys: [String?] = []
            var used = Set<String>()
            for i in node.children.indices {
                var k = "Item \(i)"
                var n = 2
                while used.contains(k) { k = "Item \(i) - \(n)"; n += 1 }
                used.insert(k)
                keys.append(k)
            }
            return Conversion(kind: .dictionary, children: node.children, childKeys: keys)
        case .array:
            guard node.kind == .dictionary else { return Conversion(kind: .array, children: [], childKeys: []) }
            return Conversion(kind: .array, children: node.children, childKeys: node.children.map { _ in nil })
        default:
            if !node.isContainer, let k = parse(display(node), as: type) {
                return Conversion(kind: k, children: [], childKeys: [])
            }
            if case .bool(let b) = node.kind, type == .integer || type == .real {
                return Conversion(kind: type == .integer ? .integer(b ? 1 : 0) : .real(b ? 1 : 0), children: [], childKeys: [])
            }
            return Conversion(kind: defaultKind(type), children: [], childKeys: [])
        }
    }
}
