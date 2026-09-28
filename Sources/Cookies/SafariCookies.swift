import Foundation

enum SafariCookies {
    static let macEpochDelta = 978_307_200

    static func load(
        origins: [URL], names: Set<String>, paths: [String]? = nil,
        now: Int = Int(Date().timeIntervalSince1970),
        readFile: (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) -> (cookies: [Cookie], warnings: [String]) {
        #if os(macOS)
        var warnings: [String] = []
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = paths ?? [
            "\(home)/Library/Cookies/Cookies.binarycookies",
            "\(home)/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies",
        ]
        let hosts = origins.compactMap { $0.host }
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return ([], ["Safari Cookies.binarycookies not found."])
        }
        do {
            let data = try readFile(URL(fileURLWithPath: path))
            let parsed = try decodeBinaryCookies(data)
            let filtered = parsed.filter { cookie in
                if !names.isEmpty && !names.contains(cookie.name) { return false }
                if !hosts.contains(where: { hostMatchesCookieDomain(host: $0, cookieDomain: cookie.domain) }) {
                    return false
                }
                if let exp = cookie.expires, exp < now { return false }
                return true
            }
            return (deduplicateCookies(filtered), warnings)
        } catch {
            let message = error.localizedDescription
            warnings.append("Failed to read Safari cookies (\(path)): \(message)")
            let ns = error as NSError
            if message.contains("EPERM") || message.lowercased().contains("not permitted")
                || message.lowercased().contains("permission")
                || (ns.domain == NSPOSIXErrorDomain && (ns.code == 1 || ns.code == 13))
                || (ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError)
            {
                warnings.append(
                    "macOS blocked Safari cookie access. Grant Full Disk Access to Terminal (or the app that launched aviary) in System Settings → Privacy & Security → Full Disk Access, then retry."
                )
            }
        }
        return ([], warnings)
        #else
        return ([], ["Safari cookies are only available on macOS."])
        #endif
    }

    static func decodeBinaryCookies(_ data: Data) throws -> [Cookie] {
        guard data.count >= 8, String(data: data.prefix(4), encoding: .utf8) == "cook" else { return [] }
        let pageCount = readUInt32BE(data, 4)
        guard Int(pageCount) <= (data.count - 8) / 4 else { throw DecodeError.truncatedPageTable }
        var cursor = 8
        var pageSizes: [Int] = []
        for _ in 0 ..< pageCount {
            pageSizes.append(Int(readUInt32BE(data, cursor)))
            cursor += 4
        }
        var cookies: [Cookie] = []
        for size in pageSizes {
            guard cursor <= data.count, size <= data.count - cursor else { throw DecodeError.truncatedPage }
            let end = cursor + size
            cookies.append(contentsOf: try decodePage(data.subdata(in: cursor ..< end)))
            cursor += size
        }
        return cookies
    }

    private static func decodePage(_ page: Data) throws -> [Cookie] {
        guard page.count >= 16, readUInt32BE(page, 0) == 0x0000_0100 else { return [] }
        let count = Int(readUInt32LE(page, 4))
        guard count <= (page.count - 12) / 4 else { throw DecodeError.truncatedCookieTable }
        var offsets: [Int] = []
        var cursor = 8
        for _ in 0 ..< count {
            offsets.append(Int(readUInt32LE(page, cursor)))
            cursor += 4
        }
        return try offsets.compactMap { offset in
            guard offset >= cursor + 4, offset <= page.count - 4 else { throw DecodeError.invalidCookieOffset }
            let size = Int(readUInt32LE(page, offset))
            guard size <= page.count - offset else { throw DecodeError.truncatedPage }
            return decodeCookie(page.subdata(in: offset ..< offset + size))
        }
    }

    private static func decodeCookie(_ buf: Data) -> Cookie? {
        guard buf.count >= 56 else { return nil }
        let size = Int(readUInt32LE(buf, 0))
        guard size >= 56, size <= buf.count else { return nil }
        let flags = readUInt32LE(buf, 8)
        let urlOff = Int(readUInt32LE(buf, 16))
        let nameOff = Int(readUInt32LE(buf, 20))
        let pathOff = Int(readUInt32LE(buf, 24))
        let valueOff = Int(readUInt32LE(buf, 28))
        let expiration = readDoubleLE(buf, 40)
        guard let rawUrl = readCString(buf, urlOff, size),
              let name = readCString(buf, nameOff, size),
              let path = readCString(buf, pathOff, size),
              let value = readCString(buf, valueOff, size) else { return nil }
        let domain = hostname(from: rawUrl)
        let unixExpiration = (expiration + Double(macEpochDelta)).rounded()
        guard expiration.isFinite, unixExpiration < Double(Int.max) else { return nil }
        let expires = expiration > 0 ? Int(unixExpiration) : nil
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
        guard offset >= 56, offset < end else { return nil }
        var cursor = offset
        while cursor < end && data[cursor] != 0 {
            cursor += 1
        }
        guard cursor < end else { return nil }
        return String(data: data[offset ..< cursor], encoding: .utf8)
    }

    private enum DecodeError: String, LocalizedError {
        case truncatedPageTable = "Truncated Safari cookie page table"
        case truncatedPage = "Truncated Safari cookie page"
        case truncatedCookieTable = "Truncated Safari cookie offset table"
        case invalidCookieOffset = "Invalid Safari cookie offset"
        var errorDescription: String? { rawValue }
    }
}
