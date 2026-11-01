// Round-trips every plist given on stdin (one path per line) through PliableCore and checks the
// result against Foundation's PropertyListSerialization.
import Foundation
import PliableCore

var total = 0, skipped = 0, ok = 0
var fallbacks: [String] = []
var failures: [String] = []

func hasDuplicateKeys(_ n: PlistNode) -> Bool {
    if n.kind == .dictionary {
        let keys = n.children.compactMap { $0.key.map { Array($0.utf8) } }
        if Set(keys).count != keys.count { return true }
    }
    return n.children.contains(where: hasDuplicateKeys)
}

/// XML stores whole seconds (Foundation's writer floors too).
func truncatedDates(_ n: PlistNode) -> PlistNode {
    let c = n.deepCopy()
    func walk(_ x: PlistNode) {
        if case .date(let d) = x.kind { x.kind = .date(Date(timeIntervalSinceReferenceDate: floor(d.timeIntervalSinceReferenceDate))) }
        x.children.forEach(walk)
    }
    walk(c)
    return c
}

func check(_ path: String) {
    guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { skipped += 1; return }
    guard let fobj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { skipped += 1; return }
    total += 1
    let file: PlistFile
    do { file = try PlistFile.read(data) } catch { failures.append("READ \(path): \(error)"); return }
    if !file.orderPreserved { fallbacks.append(path) }
    // With duplicate keys Foundation keeps only one copy, so semantic comparison doesn't apply.
    let dup = hasDuplicateKeys(file.root)
    if !dup, let m = FoundationBridge.mismatch(file.root, fobj) { failures.append("READ-DIFF \(path): \(m)"); return }

    var formats: [PlistFormat] = [.xml, .binary]
    if file.format == .openStep || file.format == .strings { formats.append(file.format) }
    for f in formats {
        var out = file
        out.format = f
        let d: Data
        do { d = try out.write() } catch {
            // Fine only if Foundation also refuses this content in this format.
            if f == .xml, (try? PropertyListSerialization.data(fromPropertyList: fobj, format: .xml, options: 0)) == nil { continue }
            failures.append("WRITE-\(f) \(path): \(error)"); return
        }
        guard let back = try? PropertyListSerialization.propertyList(from: d, options: [], format: nil) else {
            failures.append("FOUNDATION-REJECTS-\(f) \(path)"); return
        }
        let reference = f == .xml ? truncatedDates(file.root) : file.root
        if !dup, let m = FoundationBridge.mismatch(reference, back) { failures.append("WRITE-DIFF-\(f) \(path): \(m)"); return }
        // Text formats must keep key order exactly (binary order isn't preserved, same as Xcode).
        if f != .binary {
            guard let again = try? PlistFile.read(d), again.root.isIdentical(to: reference) else {
                failures.append("ORDER-\(f) \(path)"); return
            }
        }
    }
    ok += 1
}

while let line = readLine() {
    autoreleasepool { check(line) }
}
print("checked=\(total) ok=\(ok) failed=\(failures.count) orderFallback=\(fallbacks.count) skipped(unreadable by Foundation)=\(skipped)")
for f in fallbacks.prefix(20) { print("FALLBACK \(f)") }
for f in failures.prefix(50) { print(f) }
exit(failures.isEmpty ? 0 : 1)
