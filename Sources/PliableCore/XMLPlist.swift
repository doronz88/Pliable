import Foundation

// MARK: - Reader
//
// Uses Foundation's XMLParser only to get values in file order; PropertyListSerialization returns
// unordered dictionaries. If XMLParser rejects a file that CF accepts (e.g. raw control characters),
// PlistFile falls back to PropertyListSerialization.

final class XMLPlistReader: NSObject, XMLParserDelegate {
    private var stack: [PlistNode] = []
    private var pendingKeys: [String?] = []
    private var text = ""
    private var collecting = false
    private var root: PlistNode?
    private var failure: PlistError?

    static func read(_ data: Data) throws -> PlistNode {
        let r = XMLPlistReader()
        let parser = XMLParser(data: data)
        parser.delegate = r
        parser.shouldResolveExternalEntities = false
        let ok = parser.parse()
        if let f = r.failure { throw f }
        if !ok {
            let e = parser.parserError.map { "\($0.localizedDescription) (line \(parser.lineNumber))" } ?? "unknown error"
            throw PlistError("XML parse error: \(e)")
        }
        guard let root = r.root else { throw PlistError("XML property list has no value") }
        return root
    }

    private func fail(_ parser: XMLParser, _ msg: String) {
        if failure == nil { failure = PlistError("\(msg) (line \(parser.lineNumber))") }
        parser.abortParsing()
    }

    private func attach(_ node: PlistNode, _ parser: XMLParser) {
        guard let top = stack.last else {
            if root != nil { fail(parser, "More than one top-level value"); return }
            root = node
            return
        }
        if top.kind == .dictionary {
            guard let k = pendingKeys[pendingKeys.count - 1] else { fail(parser, "Dictionary value without a <key>"); return }
            node.key = k
            pendingKeys[pendingKeys.count - 1] = nil
        }
        top.appendChild(node)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "plist": break
        case "dict", "array":
            let n = PlistNode(kind: name == "dict" ? .dictionary : .array)
            attach(n, parser)
            stack.append(n)
            pendingKeys.append(nil)
        case "key", "string", "integer", "real", "date", "data":
            text = ""
            collecting = true
        case "true", "false":
            attach(PlistNode(kind: .bool(name == "true")), parser)
        default:
            fail(parser, "Unknown element <\(name)>")
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collecting { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if collecting { text += String(decoding: CDATABlock, as: UTF8.self) }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let t = text
        collecting = false
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "dict":
            guard let n = stack.popLast() else { return }
            if pendingKeys.popLast().flatMap({ $0 }) != nil { fail(parser, "<key> without a value"); return }
            // CF converts {CF$UID = <integer>} into a UID object.
            if n.children.count == 1, n.children[0].key == "CF$UID", case .integer(let v) = n.children[0].kind, v >= 0, v <= Int64(UInt32.max) {
                n.kind = .uid(UInt64(v)); n.setChildren([])
            }
        case "array":
            stack.removeLast()
            pendingKeys.removeLast()
        case "key":
            guard let top = stack.last, top.kind == .dictionary else { fail(parser, "<key> outside a dictionary"); return }
            if pendingKeys[pendingKeys.count - 1] != nil { fail(parser, "Two <key>s in a row"); return }
            pendingKeys[pendingKeys.count - 1] = t
        case "string":
            attach(PlistNode(kind: .string(t)), parser)
        case "integer":
            guard let k = parseInteger(trimmed) else { fail(parser, "Bad <integer> '\(trimmed)'"); return }
            attach(PlistNode(kind: k), parser)
        case "real":
            guard let v = parseReal(trimmed) else { fail(parser, "Bad <real> '\(trimmed)'"); return }
            attach(PlistNode(kind: .real(v)), parser)
        case "date":
            guard let d = PlistDates.parse(trimmed) else { fail(parser, "Bad <date> '\(trimmed)'"); return }
            attach(PlistNode(kind: .date(d)), parser)
        case "data":
            guard let d = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters) else { fail(parser, "Bad <data>"); return }
            attach(PlistNode(kind: .data(d)), parser)
        default:
            break
        }
    }
}

func parseInteger(_ s: String) -> PlistNode.Kind? {
    var str = s
    var negative = false
    if str.hasPrefix("-") { negative = true; str.removeFirst() } else if str.hasPrefix("+") { str.removeFirst() }
    var radix = 10
    if str.lowercased().hasPrefix("0x") { radix = 16; str.removeFirst(2) }
    guard !str.isEmpty, let mag = UInt64(str, radix: radix) else { return nil }
    if negative {
        if mag <= UInt64(Int64.max) { return .integer(-Int64(mag)) }
        if mag == UInt64(Int64.max) + 1 { return .integer(Int64.min) }
        return nil
    }
    if mag <= UInt64(Int64.max) { return .integer(Int64(mag)) }
    return .unsignedInteger(mag)
}

func parseReal(_ s: String) -> Double? {
    switch s.lowercased() {
    case "nan": return .nan
    case "inf", "+inf", "infinity", "+infinity": return .infinity
    case "-inf", "-infinity": return -.infinity
    default: return Double(s)
    }
}

public enum PlistDates {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func parse(_ s: String) -> Date? {
        if let d = iso.date(from: s) ?? isoFrac.date(from: s) { return d }
        // Tolerate a missing zone designator (treated as UTC, like CF).
        if !s.hasSuffix("Z"), let d = iso.date(from: s + "Z") ?? isoFrac.date(from: s + "Z") { return d }
        return nil
    }

    /// Format used by the date editor's text field: day first, 24-hour clock, in `timeZone`.
    public static let manualFormat = "dd/MM/yyyy HH:mm:ss"

    private static let manualFormats = [
        "dd/MM/yyyy HH:mm:ss", "dd/MM/yyyy HH:mm", "dd/MM/yyyy",
        "dd.MM.yyyy HH:mm:ss", "dd.MM.yyyy HH:mm", "dd.MM.yyyy",
        "dd-MM-yyyy HH:mm:ss", "dd-MM-yyyy HH:mm", "dd-MM-yyyy",
        "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd",
        "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd HH:mm", "yyyy/MM/dd",
    ]

    private static func formatter(_ format: String, _ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = tz
        f.dateFormat = format
        f.isLenient = false
        return f
    }

    /// `d` as the editor's text field shows it.
    public static func formatManual(_ d: Date, timeZone: TimeZone = .current) -> String {
        formatter(manualFormat, timeZone).string(from: d)
    }

    /// Parses a date typed by hand: dd/MM/yyyy (also with `.` or `-`) or yyyy-MM-dd (also with `/`), each with
    /// an optional HH:mm or HH:mm:ss, in `timeZone`; or an ISO 8601 date with a zone (e.g. 2026-10-30T14:12:00Z).
    public static func parseManual(_ text: String, timeZone: TimeZone = .current) -> Date? {
        let s = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "  ", with: " ")
        guard !s.isEmpty else { return nil }
        if s.contains("T"), let d = iso.date(from: s) ?? isoFrac.date(from: s) { return d }
        for fmt in manualFormats {
            let f = formatter(fmt, timeZone)
            // Round-trip check rejects partial matches like 31/02 or trailing junk.
            if let d = f.date(from: s), normalized(s) == f.string(from: d) { return d }
        }
        return nil
    }

    /// `s` with single-digit day/month/hour/minute/second fields zero-padded, so "1/2/2026 9:05" matches its
    /// formatted form "01/02/2026 09:05".
    private static func normalized(_ s: String) -> String {
        var out = "", num = ""
        func flush() {
            if !num.isEmpty { out += num.count == 1 ? "0" + num : num; num = "" }
        }
        for ch in s {
            if ch.isNumber { num.append(ch) } else { flush(); out.append(ch) }
        }
        flush()
        return out
    }

    /// Plist XML representation: whole seconds, UTC.
    public static func format(_ d: Date) -> String {
        iso.string(from: Date(timeIntervalSinceReferenceDate: floor(d.timeIntervalSinceReferenceDate)))
    }

    public static func formatPrecise(_ d: Date) -> String {
        let t = d.timeIntervalSinceReferenceDate
        return t == floor(t) ? iso.string(from: d) : isoFrac.string(from: d)
    }
}

// MARK: - Writer

enum XMLPlistWriter {
    static func write(_ root: PlistNode) throws -> Data {
        try checkNoNUL(root)
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">

        """
        emit(root, depth: 0, into: &out)
        out += "</plist>\n"
        return Data(out.utf8)
    }

    private static func checkNoNUL(_ n: PlistNode) throws {
        if let k = n.key, k.utf8.contains(0) { throw PlistError("The key “\(k.replacingOccurrences(of: "\0", with: "␀"))” contains a NUL character, which the XML format cannot store. Save in binary format instead.") }
        if case .string(let s) = n.kind, s.utf8.contains(0) { throw PlistError("A string value contains a NUL character, which the XML format cannot store. Save in binary format instead.") }
        for c in n.children { try checkNoNUL(c) }
    }

    static func escape(_ s: String) -> String {
        var r = ""
        r.reserveCapacity(s.utf8.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": r += "&amp;"
            case "<": r += "&lt;"
            case ">": r += "&gt;"
            default: r.unicodeScalars.append(ch)
            }
        }
        return r
    }

    static func realString(_ v: Double) -> String {
        if v.isNaN { return "nan" }
        if v.isInfinite { return v < 0 ? "-infinity" : "+infinity" }
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        return "\(v)"
    }

    private static func emit(_ n: PlistNode, depth: Int, into out: inout String) {
        let ind = String(repeating: "\t", count: depth)
        switch n.kind {
        case .dictionary:
            if n.children.isEmpty { out += "\(ind)<dict/>\n"; return }
            out += "\(ind)<dict>\n"
            for c in n.children {
                out += "\(ind)\t<key>\(escape(c.key ?? ""))</key>\n"
                emit(c, depth: depth + 1, into: &out)
            }
            out += "\(ind)</dict>\n"
        case .array:
            if n.children.isEmpty { out += "\(ind)<array/>\n"; return }
            out += "\(ind)<array>\n"
            for c in n.children { emit(c, depth: depth + 1, into: &out) }
            out += "\(ind)</array>\n"
        case .string(let s): out += "\(ind)<string>\(escape(s))</string>\n"
        case .integer(let v): out += "\(ind)<integer>\(v)</integer>\n"
        case .unsignedInteger(let v): out += "\(ind)<integer>\(v)</integer>\n"
        case .real(let v): out += "\(ind)<real>\(realString(v))</real>\n"
        case .bool(let b): out += "\(ind)<\(b ? "true" : "false")/>\n"
        case .date(let d): out += "\(ind)<date>\(PlistDates.format(d))</date>\n"
        case .data(let d):
            let b64 = d.base64EncodedString()
            if b64.isEmpty { out += "\(ind)<data>\n\(ind)</data>\n"; return }
            out += "\(ind)<data>\n"
            var i = b64.startIndex
            while i < b64.endIndex {
                let j = b64.index(i, offsetBy: 68, limitedBy: b64.endIndex) ?? b64.endIndex
                out += "\(ind)\(b64[i..<j])\n"
                i = j
            }
            out += "\(ind)</data>\n"
        case .uid(let v):
            out += "\(ind)<dict>\n\(ind)\t<key>CF$UID</key>\n\(ind)\t<integer>\(v)</integer>\n\(ind)</dict>\n"
        }
    }
}
