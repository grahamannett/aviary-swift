import Foundation

enum FirefoxCookies {
    static func load(
        origins: [URL], names: Set<String>, profile: String?,
        roots: [String]? = nil, now: Int = Int(Date().timeIntervalSince1970)
    ) -> (cookies: [Cookie], warnings: [String]) {
        guard let db = resolveDb(profile: profile, roots: roots) else {
            return ([], ["Firefox cookies database not found."])
        }
        let hosts = origins.compactMap { $0.host }
        do {
            let tmp = try SqliteHelper.copyDbWithSidecars(from: db)
            defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
            let rows = try SqliteHelper.query(
                tmp.path,
                sql: "SELECT name, value, host, path, expiry, isSecure, isHttpOnly FROM moz_cookies ORDER BY expiry DESC"
            )
            var cookies: [Cookie] = []
            for row in rows {
                guard let name = row["name"] as? String, !name.isEmpty,
                      let value = row["value"] as? String else { continue }
                if !names.isEmpty && !names.contains(name) { continue }
                guard let host = row["host"] as? String else { continue }
                if !hosts.contains(where: { hostMatchesCookieDomain(host: $0, cookieDomain: host) }) { continue }
                let expiry = (row["expiry"] as? Int64).flatMap { $0 > 0 ? Int($0) : nil }
                if let expiry, expiry <= now { continue }
                cookies.append(
                    Cookie(
                        name: name,
                        value: value,
                        domain: host.hasPrefix(".") ? String(host.dropFirst()) : host,
                        path: (row["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "/",
                        expires: expiry,
                        secure: (row["isSecure"] as? Int64) == 1,
                        httpOnly: (row["isHttpOnly"] as? Int64) == 1
                    )
                )
            }
            return (deduplicateCookies(cookies), [])
        } catch {
            return ([], ["Failed to read Firefox cookies: \(error.localizedDescription)"])
        }
    }

    static func resolveDb(profile: String?, roots: [String]? = nil) -> String? {
        if let profile, profile.contains("/") || profile.contains("\\") {
            let expanded = (profile as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) {
                if !isDir.boolValue { return expanded }
                let sqlite = (expanded as NSString).appendingPathComponent("cookies.sqlite")
                if FileManager.default.fileExists(atPath: sqlite) { return sqlite }
            }
            return nil
        }
        for root in roots ?? firefoxRoots() {
            if let profile, !profile.isEmpty {
                let candidate = "\(root)/\(profile)/cookies.sqlite"
                if FileManager.default.fileExists(atPath: candidate) { return candidate }
                continue
            }
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }
            let names = entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .map(\.lastPathComponent).sorted()
            guard let selected = names.first(where: { $0.contains("default-release") }) ?? names.first else { continue }
            let candidate = "\(root)/\(selected)/cookies.sqlite"
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func firefoxRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #if os(macOS)
        return ["\(home)/Library/Application Support/Firefox/Profiles"]
        #elseif os(Linux)
        return ["\(home)/.mozilla/firefox"]
        #elseif os(Windows)
        let app = ProcessInfo.processInfo.environment["APPDATA"] ?? ""
        return ["\(app)\\Mozilla\\Firefox\\Profiles"]
        #else
        return []
        #endif
    }
}
