import Foundation

public let fallbackQueryIds: [String: String] = [
    "CreateTweet": "TAJw1rBsjAtdNgTdlo2oeg",
    "CreateRetweet": "ojPdsZsimiJrUGLR1sjUtA",
    "DeleteRetweet": "iQtK4dl5hBmXewYZuEOKVw",
    "CreateFriendship": "8h9JVdV8dlSyqyRDJEPCsA",
    "DestroyFriendship": "ppXWuagMNXgvzx6WoXBW0Q",
    "FavoriteTweet": "lI07N6Otwv1PhnEgXILM7A",
    "UnfavoriteTweet": "ZYKSe-w7KEslx3JhSIk5LA",
    "CreateBookmark": "aoDbu3RHznuiSkQ9aNM67Q",
    "DeleteBookmark": "Wlmlj2-xzyS1GN3a6cj-mQ",
    "TweetDetail": "97JF30KziU00483E_8elBA",
    "SearchTimeline": "M1jEez78PEfVfbQLvlWMvQ",
    "UserArticlesTweets": "8zBy9h4L90aDL02RsBcCFg",
    "UserTweets": "Wms1GvIiHXAPBaCr9KblaA",
    "Bookmarks": "RV1g3b8n_SGOHwkqKYSCFw",
    "Following": "BEkNpEt5pNETESoqMsTEGA",
    "Followers": "kuFUYP9eV1FPoEy4N-pi7w",
    "Likes": "JR2gceKucIKcVNB_9JkhsA",
    "BookmarkFolderTimeline": "KJIQpsvxrTfRIlbaRIySHQ",
    "ListOwnerships": "wQcOSjSQ8NtgxIwvYl1lMg",
    "ListMemberships": "BlEXXdARdSeL_0KyKHHvvg",
    "ListLatestTweetsTimeline": "2TemLyqrMpTeAmysdbnVqw",
    "ListByRestId": "wXzyA5vM_aVkBL9G8Vp3kw",
    "HomeTimeline": "edseUwk9sP5Phz__9TIRnA",
    "HomeLatestTimeline": "iOEZpOdfekFsxSlPQCQtPg",
    "ExploreSidebar": "lpSN4M6qpimkF4nRFPE3nQ",
    "ExplorePage": "kheAINB_4pzRDqkzG3K-ng",
    "GenericTimelineById": "uGSr7alSjR9v6QJAIaqSKQ",
    "TrendHistory": "Sj4T-jSB9pr0Mxtsc1UKZQ",
    "AboutAccountQuery": "zs_jFPFT78rBpXv9Z3U2YQ",
]

public func bakedQueryIds() -> [String: String] {
    var ids = fallbackQueryIds
    if let url = Bundle.module.url(forResource: "query-ids", withExtension: "json", subdirectory: "Resources")
        ?? Bundle.module.url(forResource: "query-ids", withExtension: "json"),
       let data = try? Data(contentsOf: url),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
    {
        for (k, v) in obj { ids[k] = v }
    }
    return ids
}

public struct QueryIdSnapshot: Codable {
    public var fetchedAt: String
    public var ttlMs: Int
    public var ids: [String: String]
    public var discovery: Discovery
    public struct Discovery: Codable {
        public var pages: [String]
        public var bundles: [String]
    }
}

public actor QueryIdStore {
    public static let shared = QueryIdStore()
    private var memory: QueryIdSnapshot?
    private var baked: [String: String] = bakedQueryIds()

    public func cachePath() -> String {
        if let env = ProcessInfo.processInfo.environment["BIRD_QUERY_IDS_CACHE"], !env.isEmpty {
            return env
        }
        let base: String
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = "\(xdg)/bird"
        } else {
            base = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.config/bird"
        }
        return "\(base)/query-ids-cache.json"
    }

    public func getQueryId(_ name: String) -> String {
        if let mem = memory?.ids[name] { return mem }
        if let disk = loadDisk()?.ids[name] { return disk }
        return baked[name] ?? fallbackQueryIds[name] ?? ""
    }

    public func snapshotInfo() -> (snapshot: QueryIdSnapshot, cachePath: String, ageMs: Int, isFresh: Bool)? {
        let path = cachePath()
        guard let snap = loadDisk() ?? memory else { return nil }
        let age = ageMs(snap)
        return (snap, path, age, age < snap.ttlMs)
    }

    public func loadDisk() -> QueryIdSnapshot? {
        let path = cachePath()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(QueryIdSnapshot.self, from: data)
    }

    public func queryIdsForCLI() -> [String: String] {
        var ids = baked
        if let snap = loadDisk() ?? memory {
            for (k, v) in snap.ids { ids[k] = v }
        }
        return ids
    }

    public func refresh(force: Bool, session: HTTPSession) async {
        if skipRefresh() { return }
        if !force, let snap = loadDisk(), ageMs(snap) < snap.ttlMs {
            memory = snap
            return
        }
        let pages = [
            "https://x.com/?lang=en",
            "https://x.com/explore",
            "https://x.com/notifications",
            "https://x.com/settings/profile",
        ]
        var bundles: [String] = []
        var found: [String: String] = [:]
        let bundleRe = try! NSRegularExpression(
            pattern: #"https://abs\.twimg\.com/responsive-web/client-web(?:-legacy)?/[A-Za-z0-9.-]+\.js"#
        )
        for page in pages {
            guard let url = URL(string: page) else { continue }
            var req = URLRequest(url: url)
            req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            guard let (data, _) = try? await session.data(for: req),
                  let html = String(data: data, encoding: .utf8) else { continue }
            let ns = html as NSString
            bundleRe.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                if let m, let r = Range(m.range, in: html) {
                    bundles.append(String(html[r]))
                }
            }
        }
        bundles = Array(Set(bundles))
        for bundle in bundles {
            guard let url = URL(string: bundle),
                  let (data, _) = try? await session.data(for: URLRequest(url: url)),
                  let js = String(data: data, encoding: .utf8) else { continue }
            extractOps(js, into: &found)
        }
        if found.isEmpty { return }
        let snap = QueryIdSnapshot(
            fetchedAt: ISO8601DateFormatter().string(from: Date()),
            ttlMs: 24 * 60 * 60 * 1000,
            ids: found,
            discovery: .init(pages: pages, bundles: bundles)
        )
        memory = snap
        let path = cachePath()
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private func ageMs(_ snap: QueryIdSnapshot) -> Int {
        let f = ISO8601DateFormatter()
        guard let d = f.date(from: snap.fetchedAt) else { return Int.max }
        return Int(Date().timeIntervalSince(d) * 1000)
    }

    private func skipRefresh() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if env["AVIARY_SKIP_QUERY_ID_REFRESH"] == "1" { return true }
        if env["XCTestConfigurationFilePath"] != nil { return true }
        return false
    }

    private func extractOps(_ js: String, into found: inout [String: String]) {
        let patterns: [(String, Int, Int)] = [
            (#"e\.exports=\{queryId\s*:\s*[\"']([^\"']+)[\"']\s*,\s*operationName\s*:\s*[\"']([^\"']+)[\"']"#, 2, 1),
            (#"e\.exports=\{operationName\s*:\s*[\"']([^\"']+)[\"']\s*,\s*queryId\s*:\s*[\"']([^\"']+)[\"']"#, 1, 2),
        ]
        for (pat, opG, idG) in patterns {
            guard let re = try? NSRegularExpression(pattern: pat) else { continue }
            let ns = js as NSString
            re.enumerateMatches(in: js, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m else { return }
                let op = ns.substring(with: m.range(at: opG))
                let qid = ns.substring(with: m.range(at: idG))
                if fallbackQueryIds.keys.contains(op) {
                    found[op] = qid
                }
            }
        }
    }
}
