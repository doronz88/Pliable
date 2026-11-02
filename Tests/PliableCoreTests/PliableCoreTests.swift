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
}
