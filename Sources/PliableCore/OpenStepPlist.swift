import Foundation

// MARK: - Reader (OpenStep / NeXTSTEP ASCII plists and .strings files)

struct OpenStepReader {
    private let s: [Unicode.Scalar]
    private var i = 0
    private var line: Int { s[..<min(i, s.count)].reduce(1) { $1 == "\n" ? $0 + 1 : $0 } }

    /// Returns the root and whether it was a braceless "strings file" dictionary.
    static func read(_ text: String) throws -> (PlistNode, Bool) {
        var r = OpenStepReader(s: Array(text.unicodeScalars))
        return try r.parseTop()
    }

    private init(s: [Unicode.Scalar]) { self.s = s }

    private func err(_ m: String) -> PlistError { PlistError("OpenStep parse error: \(m) (line \(line))") }

    private var atEnd: Bool { i >= s.count }
    private var cur: Unicode.Scalar? { i < s.count ? s[i] : nil }

    private mutating func skip() {
        while i < s.count {
            let c = s[i]
            if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{0B}" || c == "\u{0C}" || c == "\u{FEFF}" { i += 1; continue }
            if c == "/", i + 1 < s.count {
                if s[i + 1] == "/" {
                    i += 2
                    while i < s.count, s[i] != "\n", s[i] != "\r" { i += 1 }
                    continue
                }
                if s[i + 1] == "*" {
                    i += 2
                    while i + 1 < s.count, !(s[i] == "*" && s[i + 1] == "/") { i += 1 }
                    i = min(i + 2, s.count)
                    continue
                }
            }
            break
        }
    }

    private mutating func parseTop() throws -> (PlistNode, Bool) {
        skip()
        if atEnd { return (PlistNode(kind: .dictionary), true) }
        let start = i
        let v = try parseValue()
        skip()
        if atEnd { return (v, false) }
        // Something follows the first value: a braceless strings file ("key" = "value"; ...).
        guard cur == "=" || cur == ";", case .string = v.kind else { throw err("Unexpected content after top-level value") }
        i = start
        let d = PlistNode(kind: .dictionary)
        try parseDictBody(into: d, terminator: nil)
        return (d, true)
    }

    private mutating func parseValue() throws -> PlistNode {
        skip()
        guard let c = cur else { throw err("Unexpected end of input") }
        switch c {
        case "{":
            i += 1
            let d = PlistNode(kind: .dictionary)
            try parseDictBody(into: d, terminator: "}")
            return d
        case "(":
            i += 1
            let a = PlistNode(kind: .array)
            while true {
                skip()
                guard let c2 = cur else { throw err("Unterminated array") }
                if c2 == ")" { i += 1; break }
                a.appendChild(try parseValue())
                skip()
                if cur == "," { i += 1; continue }
                if cur == ")" { i += 1; break }
                throw err("Expected ',' or ')' in array")
            }
            return a
        case "<":
            i += 1
            var bytes = [UInt8]()
            var hi: UInt8?
            while true {
                guard let c2 = cur else { throw err("Unterminated data") }
                i += 1
                if c2 == ">" { break }
                if c2 == " " || c2 == "\t" || c2 == "\n" || c2 == "\r" { continue }
                guard let h = UInt8(String(c2), radix: 16) else { throw err("Bad character in data") }
                if let hv = hi { bytes.append(hv << 4 | h); hi = nil } else { hi = h }
            }
            guard hi == nil else { throw err("Odd number of hex digits in data") }
            return PlistNode(kind: .data(Data(bytes)))
        case "\"", "'":
            return PlistNode(kind: .string(try parseQuoted()))
        default:
            guard OpenStepReader.isUnquoted(c) else { throw err("Unexpected character '\(c)'") }
            let st = i
            while let c2 = cur, OpenStepReader.isUnquoted(c2) { i += 1 }
            return PlistNode(kind: .string(String(String.UnicodeScalarView(s[st..<i]))))
        }
    }

    private mutating func parseDictBody(into d: PlistNode, terminator: Unicode.Scalar?) throws {
        while true {
            skip()
            guard let c = cur else {
                if terminator == nil { return }
                throw err("Unterminated dictionary")
            }
            if let t = terminator, c == t { i += 1; return }
            let keyNode = try parseValue()
            guard case .string(let key) = keyNode.kind else { throw err("Dictionary key must be a string") }
            skip()
            let value: PlistNode
            if cur == ";" {
                value = PlistNode(kind: .string(key)) // strings-file shorthand: "key";
            } else {
                guard cur == "=" else { throw err("Expected '=' after key \"\(key)\"") }
                i += 1
                value = try parseValue()
                skip()
            }
            value.key = key
            d.appendChild(value)
            if cur == ";" { i += 1; continue }
            if let t = terminator, cur == t { continue } // tolerate a missing final ';'
            if terminator == nil, atEnd { return }
            throw err("Expected ';' after value for key \"\(key)\"")
        }
    }

    private mutating func parseQuoted() throws -> String {
        let q = s[i]
        i += 1
        var out = String.UnicodeScalarView()
        while true {
            guard let c = cur else { throw err("Unterminated quoted string") }
            i += 1
            if c == q { break }
            if c != "\\" { out.append(c); continue }
            guard let e = cur else { throw err("Unterminated escape") }
            i += 1
            switch e {
            case "a": out.append("\u{07}")
            case "b": out.append("\u{08}")
            case "f": out.append("\u{0C}")
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "t": out.append("\t")
            case "v": out.append("\u{0B}")
            case "U", "u":
                var v: UInt32 = 0
                var n = 0
                while n < 4, let h = cur, let d = UInt32(String(h), radix: 16) { v = v << 4 | d; i += 1; n += 1 }
                // Combine UTF-16 surrogate pairs written as two \U escapes.
                if (0xD800...0xDBFF).contains(v), i + 1 < s.count, s[i] == "\\", s[i + 1] == "U" || s[i + 1] == "u" {
                    let save = i
                    i += 2
                    var lo: UInt32 = 0
                    var m = 0
                    while m < 4, let h = cur, let d = UInt32(String(h), radix: 16) { lo = lo << 4 | d; i += 1; m += 1 }
                    if (0xDC00...0xDFFF).contains(lo) {
                        v = 0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00)
                    } else { i = save }
                }
                out.append(Unicode.Scalar(v) ?? "\u{FFFD}")
            case "0"..."7":
                var v = UInt32(String(e), radix: 8)!
                var n = 1
                while n < 3, let h = cur, ("0"..."7").contains(h) { v = v * 8 + UInt32(String(h), radix: 8)!; i += 1; n += 1 }
                out.append(Unicode.Scalar(v) ?? "\u{FFFD}")
            default:
                out.append(e) // \\ \" \' and any other char map to themselves
            }
        }
        return String(out)
    }

    static func isUnquoted(_ c: Unicode.Scalar) -> Bool {
        switch c {
        case "a"..."z", "A"..."Z", "0"..."9", "_", "$", "+", "/", ":", ".", "-": return true
        default: return false
        }
    }
}

// MARK: - Writer

enum OpenStepWriter {
    static func write(_ root: PlistNode, stringsFile: Bool) throws -> String {
        try validate(root)
        var out = ""
        if stringsFile {
            guard root.kind == .dictionary else { throw PlistError("A strings file must have a dictionary as its root.") }
            for c in root.children {
                out += "\(quote(c.key ?? "", force: true)) = "
                try emit(c, depth: 0, into: &out, forceQuote: true)
                out += ";\n"
            }
            return out
        }
        try emit(root, depth: 0, into: &out, forceQuote: false)
        out += "\n"
        return out
    }

    private static func validate(_ n: PlistNode) throws {
        switch n.kind {
        case .dictionary, .array, .string, .data: break
        default:
            throw PlistError("The OpenStep format can only store strings, data, arrays and dictionaries, but \(path(n)) is of type \(n.type.rawValue). Change its type or save in XML or binary format.")
        }
        for c in n.children { try validate(c) }
    }

    private static func path(_ n: PlistNode) -> String {
        var parts: [String] = []
        var p: PlistNode? = n
        while let x = p, let parent = x.parent {
            parts.append(x.key ?? "Item \(x.indexInParent ?? 0)")
            p = parent
        }
        return parts.isEmpty ? "Root" : "“" + parts.reversed().joined(separator: " › ") + "”"
    }

    static func quote(_ s: String, force: Bool) -> String {
        if !force, !s.isEmpty, s.unicodeScalars.allSatisfy(OpenStepReader.isUnquoted) { return s }
        var r = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": r += "\\\""
            case "\\": r += "\\\\"
            case "\n": r += "\\n"
            case "\t": r += "\\t"
            case "\r": r += "\\r"
            default:
                if c.value < 0x20 { r += String(format: "\\%03o", c.value) } else { r.unicodeScalars.append(c) }
            }
        }
        return r + "\""
    }

    private static func emit(_ n: PlistNode, depth: Int, into out: inout String, forceQuote: Bool) throws {
        let ind = String(repeating: "    ", count: depth)
        switch n.kind {
        case .dictionary:
            if n.children.isEmpty { out += "{ }"; return }
            out += "{\n"
            for c in n.children {
                out += "\(ind)    \(quote(c.key ?? "", force: forceQuote)) = "
                try emit(c, depth: depth + 1, into: &out, forceQuote: forceQuote)
                out += ";\n"
            }
            out += "\(ind)}"
        case .array:
            if n.children.isEmpty { out += "( )"; return }
            out += "(\n"
            for (idx, c) in n.children.enumerated() {
                out += "\(ind)    "
                try emit(c, depth: depth + 1, into: &out, forceQuote: forceQuote)
                out += idx == n.children.count - 1 ? "\n" : ",\n"
            }
            out += "\(ind))"
        case .string(let s):
            out += quote(s, force: forceQuote)
        case .data(let d):
            out += "<"
            for (k, byte) in d.enumerated() {
                if k > 0, k % 4 == 0 { out += " " }
                out += String(format: "%02x", byte)
            }
            out += ">"
        default:
            throw PlistError("Unsupported type for OpenStep")
        }
    }
}
