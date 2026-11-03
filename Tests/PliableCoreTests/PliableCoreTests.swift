import XCTest
@testable import PliableCore

final class PliableCoreTests: XCTestCase {
    func keys(_ n: PlistNode) -> [String] { n.children.compactMap(\.key) }

    func testXMLKeepsKeyOrder() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>zeta</key><string>z</string><key>alpha</key><dict>
        <key>yy</key><integer>1</integer><key>bb</key><real>2.5</real></dict><key>mid</key><true/></dict></plist>
        """
        let f = try PlistFile.read(Data(xml.utf8))
        XCTAssertEqual(f.format, .xml)
        XCTAssertTrue(f.orderPreserved)
        XCTAssertEqual(keys(f.root), ["zeta", "alpha", "mid"])
        let again = try PlistFile.read(try f.write())
        XCTAssertTrue(again.root.isIdentical(to: f.root))
        XCTAssertEqual(keys(again.root.children[1]), ["yy", "bb"])
    }

    func testOpenStepKeepsOrderAndFormat() throws {
        let f = try PlistFile.read(Data("{ zeta = z; \"New item\" = \"\"; alpha = (a, <0102>); }".utf8))
        XCTAssertEqual(f.format, .openStep)
        XCTAssertEqual(keys(f.root), ["zeta", "New item", "alpha"])
        let out = try f.write()
        let again = try PlistFile.read(out)
        XCTAssertEqual(again.format, .openStep)
        XCTAssertTrue(again.root.isIdentical(to: f.root))
        XCTAssertNotNil(try PropertyListSerialization.propertyList(from: out, format: nil))
    }

    func testStringsFile() throws {
        let f = try PlistFile.read(Data("/* c */\n\"b\" = \"B\";\n\"a\" = \"A\\n\";\n".utf8))
        XCTAssertEqual(f.format, .strings)
        XCTAssertEqual(keys(f.root), ["b", "a"])
        XCTAssertTrue(try PlistFile.read(try f.write()).root.isIdentical(to: f.root))
    }

    func testOpenStepRejectsNonStringTypes() {
        let f = PlistFile(root: PlistNode(kind: .dictionary, children: [PlistNode(key: "n", kind: .integer(1))]), format: .openStep)
        XCTAssertThrowsError(try f.write())
    }

    func testBinaryRoundTripAllTypes() throws {
        let root = PlistNode(kind: .dictionary, children: [
            PlistNode(key: "s", kind: .string("héllo")),
            PlistNode(key: "i", kind: .integer(-5)),
            PlistNode(key: "u", kind: .unsignedInteger(UInt64.max)),
            PlistNode(key: "r", kind: .real(1.25)),
            PlistNode(key: "b", kind: .bool(true)),
            PlistNode(key: "d", kind: .date(Date(timeIntervalSinceReferenceDate: 12.5))),
            PlistNode(key: "x", kind: .data(Data([1, 2, 3]))),
            PlistNode(key: "uid", kind: .uid(7)),
            PlistNode(key: "a", kind: .array, children: [PlistNode(kind: .integer(1))]),
        ])
        let data = try PlistFile(root: root, format: .binary).write()
        let back = try PlistFile.read(data)
        XCTAssertEqual(back.format, .binary)
        let obj = try PropertyListSerialization.propertyList(from: data, format: nil)
        XCTAssertNil(FoundationBridge.mismatch(root, obj))
        XCTAssertNil(FoundationBridge.mismatch(back.root, obj))
    }

    func testXMLRefusesNUL() {
        let f = PlistFile(root: PlistNode(kind: .string("a\u{0}b")), format: .xml)
        XCTAssertThrowsError(try f.write())
    }

    func testEmptyFileIsEmptyDictionary() throws {
        let f = try PlistFile.read(Data())
        XCTAssertEqual(f.root.kind, .dictionary)
        XCTAssertTrue(f.root.children.isEmpty)
    }

    func testSearchMatchesKeysAndScalarValues() throws {
        let f = try PlistFile.read(Data("{ Name = \"Café\"; list = (alpha, beta); count = 42; nested = { inner = x; }; }".utf8))
        let keysOrValues = { (q: String) in PlistSearch.find(q, in: f.root).map { $0.key ?? ValueText.display($0) } }
        XCTAssertEqual(keysOrValues("cafe"), ["Name"])          // value, case/diacritic-insensitive
        XCTAssertEqual(keysOrValues("NEST"), ["nested"])        // key
        XCTAssertEqual(keysOrValues("beta"), ["beta"])          // array element
        XCTAssertEqual(keysOrValues("item"), [])                // container summaries / "Item N" don't match
        XCTAssertEqual(keysOrValues(""), [])
    }

    func testPathRoundTrip() throws {
        let f = try PlistFile.read(Data("{ a = ( { b = c; } ); }".utf8))
        let leaf = f.root.children[0].children[0].children[0]
        XCTAssertEqual(leaf.path, ["a", "0", "b"])
        XCTAssertTrue(f.root.descendant(at: leaf.path) === leaf)
        XCTAssertNil(f.root.descendant(at: ["a", "1"]))
        XCTAssertTrue(f.root.descendant(at: []) === f.root)
    }

    /// Flattens a diff tree to "change path" lines (unchanged rows use "=").
    func lines(_ n: DiffNode) -> [String] {
        var out: [String] = []
        func walk(_ d: DiffNode) {
            let c: String
            switch d.change {
            case .added?: c = "+"
            case .removed?: c = "-"
            case .changed?: c = "~"
            case nil: c = "="
            }
            out.append("\(c) \(d.path.joined(separator: "/"))")
            d.children.forEach(walk)
        }
        n.children.forEach(walk)
        return out
    }

    func testDiffTree() throws {
        let l = try PlistFile.read(Data("{ same = 1; changed = a; gone = x; arr = (1, 2, 3); t = { k = v; }; }".utf8)).root
        let r = try PlistFile.read(Data("{ same = 1; new = y; changed = b; arr = (1, 9); t = (v); }".utf8)).root
        let d = DiffNode.build(l, r)
        XCTAssertEqual(lines(d), [
            "= same", "+ new", "~ changed", "- gone",
            "= arr", "= arr/0", "~ arr/1", "- arr/2",
            "~ t", "- t/k", "+ t/0",
        ])
        XCTAssertTrue(d.hasDifferences)
        XCTAssertFalse(d.children[0].hasDifferences)
        XCTAssertTrue(d.children[4].hasDifferences)   // arr: same type, different contents
        XCTAssertNil(d.children[4].change)
        XCTAssertFalse(DiffNode.build(l, l.deepCopy()).hasDifferences)
    }

    func testDiffIgnoresKeyOrderAndPlacesNewKeys() throws {
        let l = try PlistFile.read(Data("{ b = 2; a = 1; }".utf8)).root
        let r = try PlistFile.read(Data("{ z = 0; a = 1; c = 3; b = 2; }".utf8)).root
        XCTAssertEqual(lines(DiffNode.build(l, r)), ["+ z", "= b", "= a", "+ c"])
        XCTAssertFalse(DiffNode.build(l, try PlistFile.read(Data("{ a = 1; b = 2; }".utf8)).root).hasDifferences)
    }

    func testDiffInsertionIndex() throws {
        let l = try PlistFile.read(Data("{ a = 1; c = 3; arr = (1); t = { k = v; }; }".utf8)).root
        let r = try PlistFile.read(Data("{ z = 0; a = 1; b = 2; c = 3; arr = (1, 2); t = (v); }".utf8)).root
        let d = DiffNode.build(l, r)
        func row(_ path: [String]) -> DiffNode {
            var n = d
            for c in path { n = n.children.first { $0.component == c }! }
            return n
        }
        XCTAssertEqual(row(["z"]).insertionIndex(on: .left), 0)
        XCTAssertEqual(row(["b"]).insertionIndex(on: .left), 1)        // after "a"
        XCTAssertEqual(row(["arr", "1"]).insertionIndex(on: .left), 1)
        XCTAssertNil(row(["t"]).children[0].insertionIndex(on: .right)) // parent changed type
        XCTAssertTrue(row(["a"]).node(.left) === l.children[0])
    }

    func testKeyPaths() throws {
        let r = try PlistFile.read(Data("{ Settings = { Extra = { Deep = x; }; \"com.a.b\" = 1; }; List = (a, b, c); }".utf8)).root
        XCTAssertEqual(r.descendant(at: ["Settings", "Extra", "Deep"])!.dottedKeyPath, "Settings.Extra.Deep")
        XCTAssertEqual(r.descendant(at: ["Settings", "com.a.b"])!.dottedKeyPath, "Settings.\"com.a.b\"")
        XCTAssertEqual(r.descendant(at: ["List", "2"])!.dottedKeyPath, "List.2")
        XCTAssertEqual(r.descendant(at: ["List", "2"])!.plistBuddyPath, ":List:2")
        XCTAssertEqual(r.plistBuddyPath, ":")
    }

    func testSortKeys() throws {
        let r = try PlistFile.read(Data("{ b = 1; \"Item 10\" = 2; a = 3; \"Item 2\" = 4; B = 5; }".utf8)).root
        XCTAssertEqual(r.childrenSortedByKey()?.map { $0.key! }, ["a", "b", "B", "Item 2", "Item 10"])
        r.setChildren(r.childrenSortedByKey()!)
        XCTAssertNil(r.childrenSortedByKey())
        XCTAssertNil(PlistNode(kind: .array).childrenSortedByKey())
    }

    func testHexText() {
        let d = Data((0..<20).map { UInt8($0) } + [0x41, 0x7f])
        XCTAssertEqual(HexText.format(d), "00010203 04050607 08090a0b 0c0d0e0f\n10111213 417f")
        XCTAssertEqual(HexText.ascii(d), "................\n....A.")
        XCTAssertEqual(HexText.parse(HexText.format(d)), d)
        XCTAssertEqual(HexText.parse(""), Data())
        XCTAssertNil(HexText.parse("abc"))
        XCTAssertNil(HexText.parse("zz"))
    }

    func testPreviewHTMLEscapesAndNests() throws {
        let f = try PlistFile.read(Data("{ \"<k>\" = \"<script>&'\\\"\"; list = (1, <0102>); empty = {}; }".utf8))
        let html = PlistHTML.render(f, title: "a<b>.plist")
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("a<b>"))
        XCTAssertTrue(html.contains("&lt;script&gt;&amp;&#39;&quot;"))
        XCTAssertTrue(html.contains("&lt;k&gt;"))
        XCTAssertTrue(html.contains("OpenStep property list"))
        XCTAssertTrue(html.contains("Item 1"))
        XCTAssertTrue(html.contains("&lt;0102&gt;"))
        XCTAssertTrue(html.contains("(3 items)"))
        // Root, list and empty are containers; every <details> is closed.
        XCTAssertEqual(html.components(separatedBy: "<details").count - 1, 3)
        XCTAssertEqual(html.components(separatedBy: "</details>").count - 1, 3)
        XCTAssertTrue(PlistHTML.errorPage(title: "x", message: "<bad>").contains("&lt;bad&gt;"))
    }

    func testPreviewHTMLCollapsesAndTruncatesBigFiles() {
        let inner = (0..<10).map { PlistNode(key: "k\($0)", kind: .dictionary, children: [PlistNode(kind: .integer(1))]) }
        let mid = (0..<600).map { _ in PlistNode(kind: .array, children: [PlistNode(kind: .dictionary, children: inner.map { $0.deepCopy() })]) }
        let html = PlistHTML.render(PlistFile(root: PlistNode(kind: .array, children: mid), format: .binary), title: "big")
        XCTAssertTrue(html.contains("showing the first \(PlistHTML.maxRows)"))
        XCTAssertTrue(html.contains("<details>"))  // deep containers start collapsed
        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
        XCTAssertTrue(html.hasSuffix("</html>"))
        XCTAssertEqual(html.components(separatedBy: "<details").count, html.components(separatedBy: "</details>").count)
        XCTAssertLessThanOrEqual(html.components(separatedBy: "<span class=k").count - 1, PlistHTML.maxRows)
    }

    func testKnownKeys() throws {
        let info = try PlistFile.read(Data("{ CFBundleIdentifier = x; Label = y; CFBundleSupportedPlatforms = (MacOSX); }".utf8)).root
        XCTAssertEqual(KnownKeys.lookup("CFBundleIdentifier", in: info)?.title, "Bundle identifier")
        XCTAssertEqual(KnownKeys.lookup("CFBundleVersion", in: info)?.type, .string)
        // launchd keys only count in a launchd job.
        XCTAssertNil(KnownKeys.lookup("Label", in: info))
        let job = try PlistFile.read(Data("{ Label = com.x; ProgramArguments = (/bin/true); RunAtLoad = 1; }".utf8)).root
        XCTAssertEqual(KnownKeys.lookup("RunAtLoad", in: job)?.type, .boolean)
        XCTAssertNil(KnownKeys.lookup("RunAtLoad", in: job.children[1]))
        // Completions: prefix, case-insensitive, without keys already present, exact-case first.
        let c = KnownKeys.completions(for: "CFBundleI", in: info)
        XCTAssertFalse(c.contains("CFBundleIdentifier"))
        XCTAssertTrue(c.contains("CFBundleIconFile"))
        XCTAssertEqual(KnownKeys.completions(for: "cfbundleinfo", in: info), ["CFBundleInfoDictionaryVersion"])
        XCTAssertTrue(KnownKeys.completions(for: "Run", in: info).isEmpty)
        XCTAssertEqual(KnownKeys.completions(for: "Run", in: job), [])   // RunAtLoad already used
        // Allowed values, for a key's value and for array elements.
        let platforms = info.descendant(at: ["CFBundleSupportedPlatforms", "0"])!
        XCTAssertTrue(KnownKeys.allowedValues(for: platforms).contains("iPhoneOS"))
        let cat = PlistNode(key: "LSApplicationCategoryType", kind: .string(""))
        info.appendChild(cat)
        XCTAssertTrue(KnownKeys.allowedValues(for: cat).contains("public.app-category.utilities"))
        XCTAssertEqual(KnownKeys.allowedValues(for: info.children[0]), [])
    }

    func testManualDateParsing() throws {
        let utc = TimeZone(identifier: "UTC")!
        let expect = PlistDates.parse("2026-10-30T14:12:05Z")!
        for t in ["30/10/2026 14:12:05", "30.10.2026 14:12:05", "2026-10-30 14:12:05", " 30/10/2026  14:12:05 ",
                  "2026-10-30T14:12:05Z"] {
            XCTAssertEqual(PlistDates.parseManual(t, timeZone: utc), expect, t)
        }
        XCTAssertEqual(PlistDates.parseManual("1/2/2026 9:05", timeZone: utc), PlistDates.parse("2026-02-01T09:05:00Z"))
        XCTAssertEqual(PlistDates.parseManual("30/10/2026", timeZone: utc), PlistDates.parse("2026-10-30T00:00:00Z"))
        for bad in ["", "31/02/2026", "30/10/2026 25:00", "30/10/2026x", "hello", "13/13/2026"] {
            XCTAssertNil(PlistDates.parseManual(bad, timeZone: utc), bad)
        }
        XCTAssertEqual(PlistDates.formatManual(expect, timeZone: utc), "30/10/2026 14:12:05")
    }
}
