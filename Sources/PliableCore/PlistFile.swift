import Foundation

public struct PlistFile {
    public var root: PlistNode
    public var format: PlistFormat
    /// Text encoding for OpenStep / strings output (XML is always written as UTF-8).
    public var textEncoding: String.Encoding
    public var textHasBOM: Bool
    /// False when the file could only be read through Foundation, which does not keep key order.
    public var orderPreserved: Bool

    public init(root: PlistNode, format: PlistFormat, textEncoding: String.Encoding = .utf8, textHasBOM: Bool = false, orderPreserved: Bool = true) {
        self.root = root
        self.format = format
        self.textEncoding = textEncoding
        self.textHasBOM = textHasBOM
        self.orderPreserved = orderPreserved
    }

    public static func read(_ data: Data) throws -> PlistFile {
        if data.isEmpty { return PlistFile(root: PlistNode(kind: .dictionary), format: .xml) }
        let bytes = [UInt8](data.prefix(16))

        // Binary: Foundation is enough (Xcode doesn't keep binary key order either).
        if bytes.starts(with: Array("bplist".utf8)) {
            return try foundationRead(data)
        }

        if looksLikeXML(data) {
            do {
                return PlistFile(root: try XMLPlistReader.read(data), format: .xml)
            } catch {
                return try foundationRead(data, ownError: error)
            }
        }

        let (text, enc, bom) = try decodeText(data)
        do {
            let (root, isStrings) = try OpenStepReader.read(text)
            return PlistFile(root: root, format: isStrings ? .strings : .openStep, textEncoding: enc, textHasBOM: bom)
        } catch {
            return try foundationRead(data, ownError: error)
        }
    }

    public func write() throws -> Data {
        switch format {
        case .xml: return try XMLPlistWriter.write(root)
        case .binary:
            return try PropertyListSerialization.data(fromPropertyList: try FoundationBridge.object(from: root), format: .binary, options: 0)
        case .openStep, .strings:
            let text = try OpenStepWriter.write(root, stringsFile: format == .strings)
            if textEncoding == .utf8 {
                return (textHasBOM ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(text.utf8)
            }
            guard let d = text.data(using: textEncoding) else {
                // Original encoding can't represent the new text; fall back to UTF-8.
                return Data(text.utf8)
            }
            return d
        }
    }

    private static func looksLikeXML(_ data: Data) -> Bool {
        var d = data.prefix(512)
        if d.starts(with: [0xEF, 0xBB, 0xBF]) { d = d.dropFirst(3) }
        if d.starts(with: [0xFF, 0xFE]) || d.starts(with: [0xFE, 0xFF]) {
            // UTF-16: check the decoded prefix.
            guard let s = String(data: Data(d), encoding: .utf16) else { return false }
            let t = s.drop { $0.isWhitespace || $0 == "\u{FEFF}" }
            return t.hasPrefix("<?xml") || t.hasPrefix("<!DOCTYPE") || t.hasPrefix("<plist") || t.hasPrefix("<!--")
        }
        let t = d.drop { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
        return t.starts(with: Array("<?xml".utf8)) || t.starts(with: Array("<!DOCTYPE".utf8)) || t.starts(with: Array("<plist".utf8)) || t.starts(with: Array("<!--".utf8))
    }

    private static func decodeText(_ data: Data) throws -> (String, String.Encoding, Bool) {
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let s = String(data: data.dropFirst(3), encoding: .utf8) { return (s, .utf8, true) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) {
            return (s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s, .utf16, true)
        }
        if let s = String(data: data, encoding: .utf8) { return (s, .utf8, false) }
        if let s = String(data: data, encoding: .macOSRoman) { return (s, .macOSRoman, false) }
        throw PlistError("Unrecognized text encoding")
    }

    private static func foundationRead(_ data: Data, ownError: Error? = nil) throws -> PlistFile {
        var fmt = PropertyListSerialization.PropertyListFormat.xml
        let obj: Any
        do { obj = try PropertyListSerialization.propertyList(from: data, options: [], format: &fmt) } catch {
            throw ownError ?? error
        }
        let f: PlistFormat
        switch fmt {
        case .binary: f = .binary
        case .openStep: f = .openStep
        default: f = .xml
        }
        // Binary has no order to preserve (matches Xcode); for text formats this is a fallback.
        return PlistFile(root: try FoundationBridge.node(from: obj), format: f, orderPreserved: f == .binary)
    }
}

// MARK: - Foundation interop (fallback reading and verification)

public enum FoundationBridge {
    public static func uidValue(_ obj: Any) -> UInt64? {
        // CF bridges UIDs as __NSCFType; description looks like "<CFKeyedArchiverUID 0x…>{value = 5}".
        let desc = String(describing: obj as AnyObject)
        guard desc.hasPrefix("<CFKeyedArchiverUID"), let r = desc.range(of: "value = ") else { return nil }
        return UInt64(desc[r.upperBound...].prefix { $0.isNumber })
    }

    private typealias UIDCreate = @convention(c) (CFAllocator?, UInt32) -> Unmanaged<CFTypeRef>
    private static let uidCreate: UIDCreate? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_CFKeyedArchiverUIDCreate") else { return nil }
        return unsafeBitCast(sym, to: UIDCreate.self)
    }()

    /// Converts a tree to Foundation objects for PropertyListSerialization.
    public static func object(from n: PlistNode) throws -> Any {
        switch n.kind {
        case .dictionary:
            let d = NSMutableDictionary(capacity: n.children.count)
            for c in n.children { d[c.key ?? ""] = try object(from: c) }
            return d
        case .array: return try n.children.map { try object(from: $0) } as NSArray
        case .string(let s): return s as NSString
        case .integer(let v): return NSNumber(value: v)
        case .unsignedInteger(let v): return NSNumber(value: v)
        case .real(let v): return NSNumber(value: v)
        case .bool(let b): return (b ? kCFBooleanTrue : kCFBooleanFalse) as Any
        case .date(let d): return d as NSDate
        case .data(let d): return d as NSData
        case .uid(let v):
            guard let make = uidCreate, v <= UInt64(UInt32.max) else { throw PlistError("Cannot create UID value \(v)") }
            return make(nil, UInt32(v)).takeRetainedValue()
        }
    }

    public static func node(from obj: Any, key: String? = nil) throws -> PlistNode {
        switch obj {
        case let d as NSDictionary:
            let keys = d.allKeys.compactMap { $0 as? String }.sorted()
            return PlistNode(key: key, kind: .dictionary, children: try keys.map { try node(from: d[$0]!, key: $0) })
        case let a as NSArray:
            return PlistNode(key: key, kind: .array, children: try a.map { try node(from: $0) })
        case let s as NSSet:
            return PlistNode(key: key, kind: .array, children: try s.allObjects.map { try node(from: $0) })
        case let s as String:
            return PlistNode(key: key, kind: .string(s))
        case let n as NSNumber:
            return PlistNode(key: key, kind: numberKind(n))
        case let d as Date:
            return PlistNode(key: key, kind: .date(d))
        case let d as Data:
            return PlistNode(key: key, kind: .data(d))
        default:
            if let u = uidValue(obj) { return PlistNode(key: key, kind: .uid(u)) }
            throw PlistError("Unsupported value of class \(type(of: obj))")
        }
    }

    public static func numberKind(_ n: NSNumber) -> PlistNode.Kind {
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
        if CFNumberIsFloatType(n) { return .real(n.doubleValue) }
        // CF reports values above Int64.max as unsigned ('Q') or 128-bit numbers.
        let t = String(cString: n.objCType)
        if (t == "Q" || CFNumberGetType(n).rawValue == 17), n.int64Value < 0 {
            return .unsignedInteger(n.uint64Value)
        }
        return .integer(n.int64Value)
    }

    /// Compares our tree to a Foundation object, ignoring dictionary key order. Returns a mismatch description or nil.
    public static func mismatch(_ n: PlistNode, _ obj: Any, path: String = "Root") -> String? {
        switch (n.kind, obj) {
        case (.dictionary, let d as NSDictionary):
            let ourKeys = n.children.compactMap { $0.key.map { $0 as NSString } }
            if NSSet(array: ourKeys).count != ourKeys.count {
                // Duplicate keys: CF keeps the last one.
                let last = NSMutableDictionary()
                for c in n.children { last[c.key! as NSString] = c }
                if last.count != d.count { return "\(path): key count \(last.count) vs \(d.count)" }
                for (k, c) in last {
                    let c = c as! PlistNode, k = k as! String
                    guard let v = d[k] else { return "\(path): missing key \(k)" }
                    if let m = mismatch(c, v, path: path + "/" + k) { return m }
                }
                return nil
            }
            if n.children.count != d.count { return "\(path): key count \(n.children.count) vs \(d.count)" }
            for c in n.children {
                guard let v = d[c.key!] else { return "\(path): missing key \(c.key!)" }
                if let m = mismatch(c, v, path: path + "/" + c.key!) { return m }
            }
            return nil
        case (.array, let a as NSArray):
            if n.children.count != a.count { return "\(path): count \(n.children.count) vs \(a.count)" }
            for (i, (c, v)) in zip(n.children, a).enumerated() {
                if let m = mismatch(c, v, path: "\(path)[\(i)]") { return m }
            }
            return nil
        case (.array, let s as NSSet):
            return n.children.count == s.count ? nil : "\(path): set count differs"
        case (.string(let x), let y as String):
            return (x as NSString).isEqual(to: y) ? nil : "\(path): string differs"
        case (_, let num as NSNumber):
            let k = numberKind(num)
            if k == n.kind { return nil }
            if case .real(let a) = n.kind, case .real(let b) = k, a.isNaN, b.isNaN { return nil }
            return "\(path): \(n.kind) vs \(k)"
        case (.date(let x), let y as Date):
            return x.timeIntervalSinceReferenceDate == y.timeIntervalSinceReferenceDate ? nil : "\(path): date differs"
        case (.data(let x), let y as Data):
            return x == y ? nil : "\(path): data differs"
        case (.uid(let x), _):
            return uidValue(obj) == x ? nil : "\(path): uid differs"
        default:
            return "\(path): type \(n.type.rawValue) vs \(type(of: obj))"
        }
    }
}
