import Foundation

public extension PlistNode {
    /// Key path such as `Settings.Extra.Deep` or `List.2` (array elements by index). Keys containing `.` are
    /// quoted so the path stays unambiguous: `Settings."com.example.key"`.
    var dottedKeyPath: String {
        var n = self
        var parts: [String] = []
        while let p = n.parent {
            if p.kind == .array {
                parts.append(String(n.indexInParent ?? 0))
            } else {
                let k = n.key ?? ""
                parts.append(k.contains(".") || k.contains("\"") ? "\"" + k.replacingOccurrences(of: "\"", with: "\\\"") + "\"" : k)
            }
            n = p
        }
        return parts.reversed().joined(separator: ".")
    }

    /// Entry path for `/usr/libexec/PlistBuddy`, e.g. `:Settings:Extra:Deep` (`:` for the root).
    var plistBuddyPath: String {
        ":" + path.joined(separator: ":")
    }

    /// Children in Finder-like key order ("Item 2" before "Item 10", letters before case), or nil when this is not a
    /// dictionary or is already in that order.
    func childrenSortedByKey() -> [PlistNode]? {
        guard kind == .dictionary else { return nil }
        let sorted = children.enumerated().sorted { a, b in
            let ka = a.element.key ?? "", kb = b.element.key ?? ""
            switch ka.localizedStandardCompare(kb) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame:
                // Keys that differ only in ways the comparison ignores: byte order, then original order (stable).
                if !ka.utf8.elementsEqual(kb.utf8) { return ka.utf8.lexicographicallyPrecedes(kb.utf8) }
                return a.offset < b.offset
            }
        }.map(\.element)
        return zip(sorted, children).allSatisfy { $0 === $1 } ? nil : sorted
    }
}

/// Hex dump text for the data editor.
public enum HexText {
    /// Hex digits, 16 bytes per line in groups of 4: `00010203 04050607 08090a0b 0c0d0e0f`.
    public static func format(_ d: Data) -> String {
        var out = ""
        out.reserveCapacity(d.count * 2 + d.count / 4 + 1)
        let digits = Array("0123456789abcdef".utf8)
        var line: [UInt8] = []
        for (i, b) in d.enumerated() {
            if i > 0 {
                if i % 16 == 0 {
                    out += String(decoding: line, as: UTF8.self) + "\n"
                    line.removeAll(keepingCapacity: true)
                } else if i % 4 == 0 {
                    line.append(0x20)
                }
            }
            line.append(digits[Int(b >> 4)])
            line.append(digits[Int(b & 0xf)])
        }
        return out + String(decoding: line, as: UTF8.self)
    }

    /// Printable-ASCII rendering, one line per 16 bytes (others shown as `.`), aligned with `format`.
    public static func ascii(_ d: Data) -> String {
        var lines: [String] = []
        var i = d.startIndex
        while i < d.endIndex {
            let j = d.index(i, offsetBy: 16, limitedBy: d.endIndex) ?? d.endIndex
            lines.append(String(d[i..<j].map { (0x20..<0x7f).contains($0) ? Character(UnicodeScalar($0)) : "." }))
            i = j
        }
        return lines.joined(separator: "\n")
    }

    /// Parses hex digits, ignoring whitespace and optional `<…>` / `0x`; nil if malformed.
    public static func parse(_ text: String) -> Data? {
        guard case .data(let d)? = ValueText.parse(text, as: .data) else { return nil }
        return d
    }
}
