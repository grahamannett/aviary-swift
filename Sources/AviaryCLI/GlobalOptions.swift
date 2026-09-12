import ArgumentParser
import Cookies
import Foundation
import XClient

struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Twitter auth_token cookie")
    var authToken: String?

    @Option(name: .long, help: "Twitter ct0 cookie")
    var ct0: String?

    @Option(name: .long, help: "Chrome profile name for cookie extraction")
    var chromeProfile: String?

    @Option(name: .customLong("chrome-profile-dir"), help: "Chrome/Chromium profile directory or cookie DB path")
    var chromeProfileDir: String?

    @Option(name: .long, help: "Firefox profile name")
    var firefoxProfile: String?

    @Option(name: .customLong("cookie-timeout"), help: "Cookie extraction timeout in milliseconds")
    var cookieTimeout: Int?

    @Option(name: .customLong("cookie-source"), parsing: .unconditionalSingleValue, help: "Cookie source safari|chrome|firefox (repeatable)")
    var cookieSource: [String] = []

    @Option(name: .long, parsing: .unconditionalSingleValue, help: "Attach media file")
    var media: [String] = []

    @Option(name: .long, parsing: .unconditionalSingleValue, help: "Alt text for media")
    var alt: [String] = []

    @Option(name: .long, help: "Request timeout in milliseconds")
    var timeout: Int?

    @Option(name: .customLong("quote-depth"), help: "Max quoted tweet depth")
    var quoteDepth: Int?

    @Flag(name: .long, help: "Plain output (stable, no emoji, no color)")
    var plain: Bool = false

    @Flag(name: .customLong("no-emoji"), help: "Disable emoji output")
    var noEmojiFlag: Bool = false

    @Flag(name: .customLong("no-color"), help: "Disable ANSI colors")
    var noColorFlag: Bool = false

    func chromeProfileResolved(_ config: BirdConfig) -> String? {
        chromeProfileDir ?? chromeProfile ?? config.chromeProfileDir ?? config.chromeProfile
    }

    func browsers(_ config: BirdConfig) -> [BrowserName] {
        let raw = cookieSource.isEmpty ? config.cookieSource.map(\.rawValue) : cookieSource
        return raw.compactMap { BrowserName(rawValue: $0.lowercased()) }
    }

    func credentials() async -> TwitterCookies {
        let config = BirdConfig.load()
        return await resolveTwitterCredentials(
            authToken: authToken,
            ct0: ct0,
            cookieSource: browsers(config),
            chromeProfile: chromeProfileResolved(config),
            firefoxProfile: firefoxProfile ?? config.firefoxProfile,
            cookieTimeoutMs: cookieTimeout ?? config.cookieTimeoutMs ?? envInt("BIRD_COOKIE_TIMEOUT_MS")
        )
    }

    func makeClient(_ cookies: TwitterCookies) -> TwitterClient {
        let config = BirdConfig.load()
        return TwitterClient(
            cookies: cookies,
            timeoutMs: timeout ?? config.timeoutMs ?? envInt("BIRD_TIMEOUT_MS"),
            quoteDepth: quoteDepth ?? config.quoteDepth ?? envInt("BIRD_QUOTE_DEPTH") ?? 1
        )
    }

    var noEmoji: Bool { plain || noEmojiFlag }
    var noColor: Bool {
        if plain || noColorFlag { return true }
        return ProcessInfo.processInfo.environment["NO_COLOR"] != nil
    }

    func p(_ kind: String) -> String {
        if noEmoji {
            switch kind {
            case "ok": return "OK "
            case "err": return "ERR "
            case "warn": return "WARN "
            default: return "INFO "
            }
        }
        switch kind {
        case "ok": return "✅ "
        case "err": return "❌ "
        case "warn": return "⚠️ "
        default: return "📍 "
        }
    }

    func printWarnings(_ cookies: TwitterCookies) {
        for w in cookies.warnings {
            fputs("\(p("warn"))\(w)\n", stderr)
        }
    }

    func require(_ cookies: TwitterCookies) async throws -> TwitterCookies {
        printWarnings(cookies)
        guard cookies.authToken != nil, cookies.ct0 != nil else {
            fputs("\(p("err"))Missing required credentials\n", stderr)
            throw ExitCode(1)
        }
        return cookies
    }
}

struct JsonFlags: ParsableArguments {
    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false
    @Flag(name: .customLong("json-full"), help: "Output as JSON with raw API response")
    var jsonFull: Bool = false
    var includeRaw: Bool { jsonFull }
    var asJson: Bool { json || jsonFull }
}

struct PageFlags: ParsableArguments {
    @Flag(name: .long, help: "Fetch all pages")
    var all: Bool = false
    @Option(name: .customLong("max-pages"), help: "Fetch N pages")
    var maxPages: Int?
    @Option(name: .long, help: "Delay in ms between page fetches")
    var delay: Int = 1000
    @Option(name: .long, help: "Resume pagination from a cursor")
    var cursor: String?
    var usePagination: Bool { all || maxPages != nil || cursor != nil }
}

func envInt(_ key: String) -> Int? {
    ProcessInfo.processInfo.environment[key].flatMap(Int.init)
}

func printJSON(_ value: some Encodable) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}
