import Foundation

enum SafariCookies {
    static let macEpochDelta = 978_307_200

    static func load(origins: [URL], names: Set<String>) -> (cookies: [Cookie], warnings: [String]) {
        #if os(macOS)
        var warnings: [String] = []
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Library/Cookies/Cookies.binarycookies",
            "\(home)/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies",
        ]
        let hosts = origins.compactMap { $0.host }
        let now = Int(Date().timeIntervalSince1970)
        for path in candidates {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let parsed = decodeBinaryCookies(data)
                let filtered = parsed.filter { cookie in
                    if !names.isEmpty && !names.contains(cookie.name) { return false }
                    if !hosts.contains(where: { hostMatchesCookieDomain(host: $0, cookieDomain: cookie.domain) }) {
                        return false
                    }
                    if let exp = cookie.expires, exp < now { return false }
                    return true
                }
                return (filtered, warnings)
            } catch {
                let message = error.localizedDescription
                warnings.append("Failed to read Safari cookies (\(path)): \(message)")
                let ns = error as NSError
                if message.contains("EPERM") || message.lowercased().contains("not permitted")
                    || message.lowercased().contains("permission")
                    || ns.code == 1 || ns.code == 13 || ns.code == 257 || ns.domain == NSCocoaErrorDomain
                {
                    warnings.append(
                        "macOS blocked Safari cookie access. Grant Full Disk Access to Terminal (or the app that launched aviary) in System Settings → Privacy & Security → Full Disk Access, then retry."
                    )
                }
            }
        }
        if warnings.isEmpty {
            warnings.append("Safari Cookies.binarycookies not found.")
        }
        return ([], warnings)
        #else
        return ([], ["Safari cookies are only available on macOS."])
        #endif
    }

    static func decodeBinaryCookies(_ data: Data) -> [Cookie] {
        guard data.count >= 8, String(data: data.prefix(4), encoding: .utf8) == "cook" else { return [] }
        let pageCount = readUInt32BE(data, 4)
        var cursor = 8
        var pageSizes: [Int] = []
        for _ in 0 ..< pageCount {
            pageSizes.append(Int(readUInt32BE(data, cursor)))
            cursor += 4
        }
        var cookies: [Cookie] = []
        for size in pageSizes {
            let end = min(cursor + size, data.count)
            cookies.append(contentsOf: decodePage(data.subdata(in: cursor ..< end)))
            cursor += size
        }
        return cookies
    }

    private static func decodePage(_ page: Data) -> [Cookie] {
        guard page.count >= 16, readUInt32BE(page, 0) == 0x0000_0100 else { return [] }
        let count = Int(readUInt32LE(page, 4))
        var offsets: [Int] = []
        var cursor = 8
        for _ in 0 ..< count {
            offsets.append(Int(readUInt32LE(page, cursor)))
            cursor += 4
        }
        return offsets.compactMap { decodeCookie(page.subdata(in: $0 ..< page.count)) }
    }

    private static func decodeCookie(_ buf: Data) -> Cookie? {
        guard buf.count >= 48 else { return nil }
        let size = Int(readUInt32LE(buf, 0))
        guard size >= 48, size <= buf.count else { return nil }
        let flags = readUInt32LE(buf, 8)
        let urlOff = Int(readUInt32LE(buf, 16))
        let nameOff = Int(readUInt32LE(buf, 20))
        let pathOff = Int(readUInt32LE(buf, 24))
        let valueOff = Int(readUInt32LE(buf, 28))
        let expiration = readDoubleLE(buf, 40)
        let rawUrl = readCString(buf, urlOff, size)
        guard let name = readCString(buf, nameOff, size) else { return nil }
        let path = readCString(buf, pathOff, size) ?? "/"
        let value = readCString(buf, valueOff, size) ?? ""
        let domain = hostname(from: rawUrl ?? "")
        let expires = expiration > 0 ? Int((expiration + Double(macEpochDelta)).rounded()) : nil
        return Cookie(
            name: name,
            value: value,
            domain: domain,
            path: path,
            expires: expires,
            secure: (flags & 1) != 0,
            httpOnly: (flags & 4) != 0
        )
    }

    private static func hostname(from raw: String) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { return "" }
        let urlString = cleaned.contains("://") ? cleaned : "https://\(cleaned)"
        if let host = URL(string: urlString)?.host {
            return host.hasPrefix(".") ? String(host.dropFirst()) : host
        }
        return cleaned.hasPrefix(".") ? String(cleaned.dropFirst()) : cleaned
    }

    private static func readUInt32BE(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return data[offset ..< offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func readDoubleLE(_ data: Data, _ offset: Int) -> Double {
        guard offset + 8 <= data.count else { return 0 }
        var value: UInt64 = 0
        for i in 0 ..< 8 {
            value |= UInt64(data[offset + i]) << (8 * i)
        }
        return Double(bitPattern: value)
    }

    private static func readCString(_ data: Data, _ offset: Int, _ end: Int) -> String? {
        guard offset > 0, offset < end else { return nil }
        var cursor = offset
        while cursor < end && data[cursor] != 0 {
            cursor += 1
        }
        guard cursor < end else { return nil }
        return String(data: data[offset ..< cursor], encoding: .utf8)
    }
}
