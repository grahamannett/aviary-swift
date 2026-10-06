import Cookies
import Foundation

struct BirdConfig {
    private var values: [String: JSON5.Value] = [:]

    var chromeProfile: String? { values["chromeProfile"]?.string }
    var chromeProfileDir: String? { values["chromeProfileDir"]?.string }
    var firefoxProfile: String? { values["firefoxProfile"]?.string }

    static func load(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        warn: (String) -> Void = { fputs("Warning: \($0)\n", stderr) }
    ) -> BirdConfig {
        var config = BirdConfig()
        let paths = [
            homeDirectory.appendingPathComponent(".config/bird/config.json5"),
            workingDirectory.appendingPathComponent(".birdrc.json5"),
        ]
        for path in paths where FileManager.default.fileExists(atPath: path.path) {
            do {
                let raw = try String(contentsOf: path, encoding: .utf8)
                let parsed = try JSON5.parseObject(raw)
                config.values.merge(parsed) { _, local in local }
            } catch {
                warn("Failed to parse config at \(path.path): \(error.localizedDescription)")
            }
        }
        return config
    }

    func resolveCookieSources(cli: [String]) throws -> [BrowserName] {
        let raw: [String]
        if !cli.isEmpty {
            raw = cli
        } else {
            switch values["cookieSource"] {
            case .string(let value): raw = [value]
            case .array(let values): raw = values.compactMap(\.string)
            default: raw = []
            }
        }
        if raw.isEmpty { return BrowserName.defaultCookieSources }
        return try raw.map { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let browser = BrowserName(rawValue: normalized) else {
                throw ConfigError.invalidCookieSource(value)
            }
            return browser
        }
    }

    func resolveTimeout(cli: String?, env: String?) -> Double? {
        Self.positiveNumber([cli.map(JSON5.Value.string), values["timeoutMs"], env.map(JSON5.Value.string)])
    }

    func resolveCookieTimeout(cli: String?, env: String?) -> Double? {
        Self.positiveNumber([cli.map(JSON5.Value.string), values["cookieTimeoutMs"], env.map(JSON5.Value.string)])
    }

    func resolveQuoteDepth(cli: String?, env: String?) -> Int? {
        for value in [cli.map(JSON5.Value.string), values["quoteDepth"], env.map(JSON5.Value.string)] {
            let number: Double?
            switch value {
            case .number(let value): number = value
            case .string(let value):
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                let sign = trimmed.first == "+" || trimmed.first == "-" ? String(trimmed.prefix(1)) : ""
                let digits = trimmed.dropFirst(sign.count).prefix { $0.isASCII && $0.isNumber }
                number = digits.isEmpty ? nil : Double(sign + String(digits))
            default: number = nil
            }
            if let number, number.isFinite, number >= 0, number < Double(Int.max) {
                return Int(number.rounded(.down))
            }
        }
        return nil
    }

    private static func positiveNumber(_ values: [JSON5.Value?]) -> Double? {
        for value in values {
            let number: Double?
            switch value {
            case .number(let value): number = value
            case .bool(let value): number = value ? 1 : 0
            case .string(let value):
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.lowercased().hasPrefix("0x") {
                    number = UInt64(trimmed.dropFirst(2), radix: 16).map { Double($0) }
                } else if trimmed.lowercased().hasPrefix("0b") {
                    number = UInt64(trimmed.dropFirst(2), radix: 2).map { Double($0) }
                } else if trimmed.lowercased().hasPrefix("0o") {
                    number = UInt64(trimmed.dropFirst(2), radix: 8).map { Double($0) }
                } else {
                    number = Double(trimmed)
                }
            default: number = nil
            }
            if let number, number.isFinite, number > 0 { return number }
        }
        return nil
    }
}

enum ConfigError: LocalizedError {
    case invalidCookieSource(String)

    var errorDescription: String? {
        switch self {
        case .invalidCookieSource(let value):
            return "Invalid --cookie-source \"\(value)\". Allowed: safari, chrome, firefox."
        }
    }
}
