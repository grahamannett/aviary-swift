import Foundation

enum JSON5 {
    static func parseObject(_ raw: String) -> [String: Any] {
        var s = raw
        s = s.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        var out = ""
        var inStr = false
        var prev: Character = "\0"
        for ch in s {
            if ch == "\"" && prev != "\\" { inStr.toggle() }
            if !inStr && ch == "/" && prev == "/" {
                // drop until newline handled below via skip
            }
            out.append(ch)
            prev = ch
        }
        var lines: [String] = []
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            var l = String(line)
            if let idx = l.range(of: "//") {
                // naive: strip // comments not in quotes
                var q = false
                var i = l.startIndex
                var cut: String.Index? = nil
                while i < l.endIndex {
                    let c = l[i]
                    if c == "\"" { q.toggle() }
                    if !q, c == "/", l.index(after: i) < l.endIndex, l[l.index(after: i)] == "/" {
                        cut = i
                        break
                    }
                    i = l.index(after: i)
                }
                if let cut { l = String(l[..<cut]) }
            }
            lines.append(l)
        }
        var text = lines.joined(separator: "\n")
        text = text.replacingOccurrences(of: ",\\s*([}\\]])", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"([\{,]\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:"#, with: "$1\"$2\":", options: .regularExpression)
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }
}
