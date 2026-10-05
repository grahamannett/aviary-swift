import ArgumentParser
import Cookies
import Foundation
import XClient

struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Twitter auth_token cookie") var authToken: String?
    @Option(name: .long, help: "Twitter ct0 cookie") var ct0: String?
    @Option(name: .long, help: "Chrome profile name for cookie extraction") var chromeProfile: String?
    @Option(name: .customLong("chrome-profile-dir"), help: "Chrome/Chromium profile directory or cookie DB path") var chromeProfileDir: String?
    @Option(name: .long, help: "Firefox profile name") var firefoxProfile: String?
    @Option(name: .customLong("cookie-timeout"), parsing: .unconditional, help: "Cookie extraction timeout in milliseconds") var cookieTimeout: String?
    @Option(name: .customLong("cookie-source"), parsing: .unconditionalSingleValue, help: "Cookie source safari|chrome|firefox (repeatable)") var cookieSource: [String] = []
    @Option(name: .long, parsing: .unconditionalSingleValue, help: "Attach media file (repeatable, up to 4 images or 1 video)") var media: [String] = []
    @Option(name: .long, parsing: .unconditionalSingleValue, help: "Alt text for the corresponding --media (repeatable)") var alt: [String] = []
    @Option(name: .long, parsing: .unconditional, help: "Request timeout in milliseconds") var timeout: String?
    @Option(name: .customLong("quote-depth"), parsing: .unconditional, help: "Max quoted tweet depth (default: 1; 0 disables)") var quoteDepth: String?
    @Flag(name: .long, help: "Plain output (stable, no emoji, no color)") var plain = false
    @Flag(name: .customLong("no-emoji"), help: "Disable emoji output") var noEmojiFlag = false
    @Flag(name: .customLong("no-color"), help: "Disable ANSI colors (or set NO_COLOR)") var noColorFlag = false

    var output: CLIOutput { CLIOutput(plain: plain, noEmoji: noEmojiFlag, noColor: noColorFlag) }
    func p(_ kind: String) -> String { output.status(kind) }
    func l(_ kind: String) -> String { output.label(kind) }

    mutating func validate() throws {
        do { _ = try BirdConfig().resolveCookieSources(cli: cookieSource) }
        catch { throw ValidationError(error.localizedDescription) }
    }

    func chromeProfileResolved(_ config: BirdConfig) -> String? {
        [chromeProfileDir, chromeProfile, config.chromeProfileDir, config.chromeProfile].compactMap { $0 }.first { !$0.isEmpty }
    }

    func resolvedInvocation() throws -> ResolvedInvocation {
        try ResolvedInvocation(options: self,
            config: BirdConfig.load(warn: { stderrLine("\(p("warn"))\($0)") }),
            environment: ProcessInfo.processInfo.environment)
    }

    func credentials() async throws -> TwitterCookies {
        try await resolvedInvocation().credentials()
    }

    func authenticatedClient() async throws -> TwitterClient {
        let invocation = try resolvedInvocation()
        return invocation.makeClient(try require(await invocation.credentials()))
    }

    func require(_ cookies: TwitterCookies) throws -> TwitterCookies {
        for warning in cookies.warnings { stderrLine("\(p("warn"))\(warning)") }
        guard cookies.isComplete else {
            throw CLIError("\(p("err"))Missing required credentials")
        }
        return cookies
    }
}

/// One configuration/environment snapshot supplies both cookies and HTTP settings.
struct ResolvedInvocation {
    let options: GlobalOptions
    let chromeProfile: String?
    let firefoxProfile: String?
    let cookieSources: [BrowserName]
    let cookieTimeout: Double?
    let timeout: Double?
    let quoteDepth: Int
    let environment: [String: String]

    init(options: GlobalOptions, config: BirdConfig, environment: [String: String]) throws {
        self.options = options
        self.environment = environment
        do { cookieSources = try config.resolveCookieSources(cli: options.cookieSource) }
        catch { throw CLIError("\(options.p("err"))\(error.localizedDescription)") }
        chromeProfile = options.chromeProfileResolved(config)
        firefoxProfile = [options.firefoxProfile, config.firefoxProfile].compactMap { $0 }.first { !$0.isEmpty }
        cookieTimeout = config.resolveCookieTimeout(cli: options.cookieTimeout, env: environment["BIRD_COOKIE_TIMEOUT_MS"])
        timeout = config.resolveTimeout(cli: options.timeout, env: environment["BIRD_TIMEOUT_MS"])
        quoteDepth = config.resolveQuoteDepth(cli: options.quoteDepth, env: environment["BIRD_QUOTE_DEPTH"]) ?? 1
    }

    func credentials() async -> TwitterCookies {
        await resolveTwitterCredentials(
            authToken: options.authToken, ct0: options.ct0, cookieSource: cookieSources,
            chromeProfile: chromeProfile, firefoxProfile: firefoxProfile,
            cookieTimeoutMs: cookieTimeout, environment: environment)
    }

    func makeClient(_ cookies: TwitterCookies) -> TwitterClient {
        TwitterClient(cookies: cookies, timeoutMs: timeout, quoteDepth: quoteDepth)
    }
}

struct JsonFlags: ParsableArguments {
    @Flag(name: .long, help: "Output as JSON") var json = false
    @Flag(name: .customLong("json-full"), help: "Output as JSON with full raw API response in _raw field") var jsonFull = false
    var includeRaw: Bool { jsonFull }
    var asJson: Bool { json || jsonFull }
}

struct PageFlags: ParsableArguments {
    @Flag(name: .long, help: "Fetch all results (paged)") var all = false
    @Option(name: .customLong("max-pages"), parsing: .unconditional, help: "Stop after N pages") var maxPages: String?
    @Option(name: .long, parsing: .unconditional, help: "Resume pagination from a cursor") var cursor: String?

    func resolved(maxPagesImpliesPagination: Bool = false, requiresAll: Bool = false) throws -> Pagination {
        let limit = try maxPages.map { try positiveInt($0, flag: "--max-pages") }
        let use = all || !(cursor ?? "").isEmpty || (maxPagesImpliesPagination && limit != nil)
        if limit != nil, requiresAll ? !all : !use {
            throw CLIError(requiresAll ? "--max-pages requires --all." : "--max-pages requires --all or --cursor.")
        }
        return Pagination(use: use, all: all, maxPages: limit, cursor: cursor)
    }
}

struct Pagination {
    var use: Bool
    var all: Bool
    var maxPages: Int?
    var cursor: String?
}

struct CLIError: Error, CustomStringConvertible {
    var description: String
    var exitCode: Int32
    init(_ message: String, exitCode: Int32 = 1) { description = message; self.exitCode = exitCode }
}

func stderrLine(_ text: String) { fputs(text + "\n", stderr) }

// Commander uses parseInt for these flags, so a numeric prefix is intentional.
func integerPrefix(_ raw: String) -> Int? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let range = text.range(of: #"^[+-]?\d+"#, options: .regularExpression) else { return nil }
    return Int(text[range])
}

func positiveInt(_ raw: String, flag: String, exitCode: Int32 = 1) throws -> Int {
    guard let value = integerPrefix(raw), value > 0 else {
        throw CLIError("Invalid \(flag). Expected a positive integer.", exitCode: exitCode)
    }
    return value
}

func countFlag(_ raw: String, defaultValue: Int, flag: String = "--count", exitCode: Int32 = 1, errorMessage: String? = nil) throws -> Int {
    if raw.isEmpty { return defaultValue }
    guard let value = integerPrefix(raw), value > 0 else {
        throw CLIError(errorMessage ?? "Invalid \(flag). Expected a positive integer.", exitCode: exitCode)
    }
    return value
}

func timelineCount(_ raw: String, usingPagination: Bool, defaultValue: Int = 20) throws -> Int {
    // Bird's all-results methods use a fixed page size and never consume --count.
    // In that mode even an invalid count is ignored, rather than rejecting a run.
    usingPagination ? 20 : try countFlag(raw, defaultValue: defaultValue)
}

func nonNegativeInt(_ raw: String, flag: String, exitCode: Int32 = 1) throws -> Int {
    guard let value = integerPrefix(raw), value >= 0 else {
        throw CLIError("Invalid \(flag). Expected a non-negative integer.", exitCode: exitCode)
    }
    return value
}

func jsonString(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

func printJSON(_ value: some Encodable) throws { print(try jsonString(value)) }
