import Foundation

/// Renders a plist as a self-contained HTML tree (Key / Type / Value) for the Quick Look extension.
public enum PlistHTML {
    /// Rows beyond this are dropped so huge files still preview quickly.
    public static let maxRows = 5000
    /// Files with more rows than this start with containers below `openDepth` collapsed.
    static let collapseThreshold = 300
    static let openDepth = 2

    public static func render(_ file: PlistFile, title: String) -> String {
        let total = count(file.root)
        var r = Renderer(openAll: total <= collapseThreshold)
        r.node(file.root, key: "Root", depth: 0)
        var meta = "\(file.format.displayName) property list · \(total == 1 ? "1 item" : "\(total) items")"
        if r.truncated { meta += " · showing the first \(maxRows)" }
        var body = "<div class=tree><div class=\"row head\"><span>Key</span><span>Type</span><span>Value</span></div>\(r.out)</div>"
        if r.truncated { body += "<p class=note>The rest of the file is not shown. Open it in Pliable to see everything.</p>" }
        return page(title: title, meta: meta, body: body)
    }

    public static func errorPage(title: String, message: String) -> String {
        page(title: title, meta: "Not a readable property list", body: "<p class=note>\(escape(message))</p>")
    }

    /// Escapes text for element content and double-quoted attributes.
    public static func escape(_ s: String) -> String {
        var o = ""
        o.reserveCapacity(s.utf8.count)
        for c in s.unicodeScalars {
            switch c {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            case "'": o += "&#39;"
            default: o.unicodeScalars.append(c)
            }
        }
        return o
    }

    static func count(_ n: PlistNode) -> Int { n.children.reduce(1) { $0 + count($1) } }

    private struct Renderer {
        let openAll: Bool
        var out = ""
        var rows = 0
        var truncated = false

        mutating func node(_ n: PlistNode, key: String, depth: Int) {
            guard rows < maxRows else { truncated = true; return }
            rows += 1
            let k = n.key ?? key
            // Indent via a CSS variable so the Type and Value columns stay aligned at every depth.
            let cells = "<span class=k style=\"--d:\(depth)\">\(escape(k))</span><span class=t>\(n.type.rawValue)</span>"
            guard n.isContainer else {
                out += "<div class=row>\(cells)<span class=\"v \(n.type.rawValue.lowercased())\">\(escape(ValueText.display(n)))</span></div>"
                return
            }
            let summary = "<summary class=row>\(cells)<span class=\"v count\">\(escape(ValueText.display(n)))</span></summary>"
            if n.children.isEmpty {
                out += "<details class=empty>\(summary)</details>"
                return
            }
            out += "<details\(openAll || depth < openDepth ? " open" : "")>\(summary)"
            for (i, c) in n.children.enumerated() {
                node(c, key: "Item \(i)", depth: depth + 1)
                if truncated { break }
            }
            out += "</details>"
        }
    }

    private static func page(title: String, meta: String, body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(title))</title><style>
        :root{color-scheme:light dark;--bg:#fff;--fg:#1d1d1f;--dim:#86868b;--line:#e5e5ea;--stripe:#f5f5f7;--str:#c41a16;--num:#1c00cf;--kw:#9b2393;--data:#643820}
        @media (prefers-color-scheme:dark){:root{--bg:#1e1e1e;--fg:#e5e5e7;--dim:#8e8e93;--line:#3a3a3c;--stripe:#262628;--str:#fc6a5d;--num:#d0bf69;--kw:#fc5fa3;--data:#d9c97c}}
        body{margin:0;background:var(--bg);color:var(--fg);font:13px -apple-system,BlinkMacSystemFont,sans-serif}
        header{padding:10px 14px;border-bottom:1px solid var(--line)}
        h1{font-size:14px;margin:0 0 2px;font-weight:600;word-break:break-all}
        .meta,.note{color:var(--dim);font-size:12px}.note{padding:8px 14px}
        .row{display:grid;grid-template-columns:minmax(10em,34%) 6.5em 1fr;gap:8px;padding:2px 14px;line-height:18px}
        .head{font-weight:600;color:var(--dim);border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--bg)}
        .row:hover{background:var(--stripe)}
        .k{padding-left:calc(var(--d)*14px + 14px);overflow-wrap:anywhere;position:relative}
        summary{list-style:none;cursor:default}summary::-webkit-details-marker{display:none}
        summary .k::before{content:"";position:absolute;left:calc(var(--d)*14px + 2px);top:5px;border:4px solid transparent;border-left:6px solid var(--dim)}
        details[open]>summary .k::before{transform:rotate(90deg);transform-origin:3px 4px}
        details.empty>summary .k::before{display:none}
        .t,.count{color:var(--dim)}
        .v{font:12px ui-monospace,SFMono-Regular,Menlo,monospace;white-space:pre-wrap;overflow-wrap:anywhere}
        .string{color:var(--str)}.integer,.real,.uid{color:var(--num)}.boolean,.date{color:var(--kw)}.data{color:var(--data)}
        </style></head><body><header><h1>\(escape(title))</h1><div class=meta>\(escape(meta))</div></header>\(body)</body></html>
        """
    }
}
