import Foundation

enum FirefoxCookies {
    static func load(origins: [URL], names: Set<String>, profile: String?) -> (cookies: [Cookie], warnings: [String]) {
        guard let db = resolveDb(profile: profile) else {
            return ([], ["Firefox cookies database not found."])
        }
        let hosts = origins.compactMap { $0.host }
        let now = Int(Date().timeIntervalSince1970)
        do {
            let tmp = try SqliteHelper.copyDbWithSidecars(from: db)
            defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
            let rows = SqliteHelper.query(
                tmp.path,
                sql: "SELECT name, value, host, path, expiry, isSecure, isHttpOnly FROM moz_cookies"
            )
            var cookies: [Cookie] = []
            for row in rows {
                guard let name = row["name"] as? String else { continue }
                if !names.isEmpty && !names.contains(name) { continue }
                guard let host = row["host"] as? String else { continue }
                if !hosts.contains(where: { hostMatchesCookieDomain(host: $0, cookieDomain: host) }) { continue }
                let expiry = (row["expiry"] as? Int64).map(Int.init)
                if let expiry, expiry < now { continue }
                cookies.append(
                    Cookie(
                        name: name,
                        value: (row["value"] as? String) ?? "",
                        domain: host.hasPrefix(".") ? String(host.dropFirst()) : host,
                        path: (row["path"] as? String) ?? "/",
                        expires: expiry,
                        secure: (row["isSecure"] as? Int64) == 1,
                        httpOnly: (row["isHttpOnly"] as? Int64) == 1
                    )
                )
            }
            return (cookies, [])
        } catch {
            return ([], ["Failed to read Firefox cookies: \(error.localizedDescription)"])
        }
    }

    private static func resolveDb(profile: String?) -> String? {
        if let profile, profile.contains("/") || profile.contains("\\") {
            let expanded = (profile as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) {
                if !isDir.boolValue { return expanded }
                let sqlite = (expanded as NSString).appendingPathComponent("cookies.sqlite")
                if FileManager.default.fileExists(atPath: sqlite) { return sqlite }
            }
        }
        for root in firefoxRoots() {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            let wanted = profile?.isEmpty == false ? profile : nil
            for entry in entries {
                if let wanted, !entry.contains(wanted) && entry != wanted { continue }
                let sqlite = "\(root)/\(entry)/cookies.sqlite"
                if FileManager.default.fileExists(atPath: sqlite) { return sqlite }
            }
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
