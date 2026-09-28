import Foundation

// Article extraction follows Bird 0.8's Draft.js and plain-text fallbacks.
extension JSON {
    static func extractArticleText(_ result: [String: Any]) -> String? {
        guard let article = object(result["article"]) else { return nil }
        let inner = object(path(article, "article_results", "result")) ?? article
        let title = firstText(inner["title"], article["title"])
        if let rich = renderContentState(object(path(article, "article_results", "result", "content_state"))) {
            if let title {
                let hasTitle = rich == title || rich.hasPrefix(title + "\n") ||
                    ["# ", "## ", "### "].contains { rich.hasPrefix($0 + title) }
                if !hasTitle { return title + "\n\n" + rich }
            }
            return rich
        }
        func bodyCandidates(_ value: [String: Any]) -> [Any?] {
            [path(value, "body", "text"), path(value, "body", "richtext", "text"),
             path(value, "body", "rich_text", "text"), path(value, "content", "text"),
             path(value, "content", "richtext", "text"), path(value, "content", "rich_text", "text"),
             value["text"], path(value, "richtext", "text"), path(value, "rich_text", "text")]
        }
        let candidates: [Any?] = [inner["plain_text"], article["plain_text"]] + bodyCandidates(inner) + bodyCandidates(article)
        var body = candidates.lazy.compactMap { firstText($0) }.first
        if body == title { body = nil }
        if body == nil {
            var collected: [String] = []
            collectArticleText(path(article, "article_results", "result") ?? result["article"] ?? inner, into: &collected)
            if let rawArticle = result["article"] { collectArticleText(rawArticle, into: &collected) }
            var seen = Set<String>()
            let unique = collected.filter { $0 != title && seen.insert($0).inserted }
            if !unique.isEmpty { body = unique.joined(separator: "\n\n") }
        }
        if let title, let body, !body.hasPrefix(title) { return title + "\n\n" + body }
        return body ?? title
    }

    private static func collectArticleText(_ value: Any, into texts: inout [String]) {
        if let values = array(value) {
            for value in values { collectArticleText(value, into: &texts) }
        } else if let fields = object(value) {
            for key in (value as? OrderedJSONObject)?.keys ?? fields.keys.sorted() {
                guard let value = fields[key] else { continue }
                if (key == "text" || key == "title"), value is String {
                    if let text = firstText(value) { texts.append(text) }
                } else {
                    collectArticleText(value, into: &texts)
                }
            }
        }
    }

    static func renderContentState(_ content: [String: Any]?) -> String? {
        guard let blocks = array(content?["blocks"]), !blocks.isEmpty else { return nil }
        var entities: [Int: [String: Any]] = [:]
        if let entries = array(content?["entityMap"]) {
            for item in entries {
                let entry = object(item)
                if let key = string(entry?["key"]).flatMap(Int.init) ?? int(entry?["key"]), let value = object(entry?["value"]) {
                    entities[key] = value
                }
            }
        } else if let entries = object(content?["entityMap"]) {
            for (key, value) in entries {
                if let key = Int(key), let value = object(value) { entities[key] = value }
            }
        }
        var lines: [String] = []
        var orderedIndex = 0
        for item in blocks {
            guard let block = object(item) else { continue }
            let type = string(block["type"]) ?? "unstyled"
            if type != "ordered-list-item" { orderedIndex = 0 }
            if type == "atomic" {
                if let rendered = renderAtomicBlock(block, entities: entities) { lines.append(rendered) }
                continue
            }
            if type == "ordered-list-item" { orderedIndex += 1 }
            guard let text = renderBlockText(block, entities: entities) else { continue }
            switch type {
            case "header-one": lines.append("# " + text)
            case "header-two": lines.append("## " + text)
            case "header-three": lines.append("### " + text)
            case "unordered-list-item": lines.append("- " + text)
            case "ordered-list-item": lines.append("\(orderedIndex). " + text)
            case "blockquote": lines.append("> " + text)
            default: lines.append(text)
            }
        }
        return firstText(lines.joined(separator: "\n\n"))
    }

    private static func renderBlockText(_ block: [String: Any], entities: [Int: [String: Any]]) -> String? {
        guard let original = string(block["text"]) else { return nil }
        let text = NSMutableString(string: original)
        let ranges = (array(block["entityRanges"]) ?? []).compactMap(object).sorted {
            (int($0["offset"]) ?? 0) > (int($1["offset"]) ?? 0)
        }
        // Draft.js ranges, like JavaScript string offsets, are measured in UTF-16 code units.
        for range in ranges {
            guard let key = int(range["key"]), let entity = entities[key], string(entity["type"]) == "LINK",
                  let url = string(path(entity, "data", "url")),
                  let offset = int(range["offset"]), let length = int(range["length"]),
                  offset >= 0, length >= 0, offset <= text.length, length <= text.length - offset else { continue }
            let range = NSRange(location: offset, length: length)
            let label = text.substring(with: range)
            text.replaceCharacters(in: range, with: "[\(label)](\(url))")
        }
        return firstText(text as String)
    }

    private static func renderAtomicBlock(_ block: [String: Any], entities: [Int: [String: Any]]) -> String? {
        guard let range = (array(block["entityRanges"]) ?? []).first.flatMap(object),
              let key = int(range["key"]), let entity = entities[key] else { return nil }
        let data = object(entity["data"])
        switch string(entity["type"]) {
        case "MARKDOWN": return firstText(data?["markdown"])
        case "DIVIDER": return "---"
        case "TWEET": return string(data?["tweetId"]).flatMap { $0.isEmpty ? nil : "[Embedded Tweet: https://x.com/i/status/\($0)]" }
        case "LINK": return string(data?["url"]).flatMap { $0.isEmpty ? nil : "[Link: \($0)]" }
        case "IMAGE": return "[Image]"
        default: return nil
        }
    }
}
