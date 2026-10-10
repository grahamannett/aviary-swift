import Foundation

public typealias CookieProvider = @Sendable (
    _ browser: BrowserName,
    _ chromeProfile: String?,
    _ firefoxProfile: String?,
    _ timeoutMs: Double?
) async -> (cookies: [Cookie], warnings: [String])

public func getCookies(
    url: URL,
    origins: [URL],
    names: [String],
    browsers: [BrowserName],
    chromeProfile: String?,
    firefoxProfile: String?,
    timeoutMs: Double?,
    environment: [String: String] = ProcessInfo.processInfo.environment
) async -> (cookies: [Cookie], warnings: [String]) {
    var all: [Cookie] = []
    var warnings: [String] = []
    let nameSet = Set(names)
    let originList = origins.isEmpty ? [url] : origins
    for browser in browsers {
        if Task.isCancelled { break }
        let result: (cookies: [Cookie], warnings: [String])
        switch browser {
        case .safari:
            result = SafariCookies.load(origins: originList, names: nameSet)
        case .chrome:
            result = ChromeCookies.load(
                origins: originList, names: nameSet,
                profile: chromeProfile ?? normalizedEnvironmentValue(environment["SWEET_COOKIE_CHROME_PROFILE"]),
                timeoutMs: timeoutMs, environment: environment
            )
        case .firefox:
            result = FirefoxCookies.load(
                origins: originList, names: nameSet,
                profile: firefoxProfile ?? normalizedEnvironmentValue(environment["SWEET_COOKIE_FIREFOX_PROFILE"])
            )
        }
        all.append(contentsOf: result.cookies)
        warnings.append(contentsOf: result.warnings)
    }
    return (deduplicateCookies(all), warnings)
}

public func resolveTwitterCredentials(
    authToken: String?,
    ct0: String?,
    cookieSource: [BrowserName]? = nil,
    chromeProfile: String?,
    firefoxProfile: String?,
    cookieTimeoutMs: Double?,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    cookieProvider: CookieProvider? = nil
) async -> TwitterCookies {
    var result = TwitterCookies(warnings: [])
    if let authToken, !authToken.isEmpty {
        result.authToken = authToken
        result.source = "CLI argument"
    }
    if let ct0, !ct0.isEmpty {
        result.ct0 = ct0
        if result.source == nil { result.source = "CLI argument" }
    }
    if result.authToken == nil, let value = firstEnvironmentCookie(environment, ["AUTH_TOKEN", "TWITTER_AUTH_TOKEN"]) {
        result.authToken = value.value
        if result.source == nil { result.source = "env \(value.key)" }
    }
    if result.ct0 == nil, let value = firstEnvironmentCookie(environment, ["CT0", "TWITTER_CT0"]) {
        result.ct0 = value.value
        if result.source == nil { result.source = "env \(value.key)" }
    }
    if let auth = result.authToken, let csrf = result.ct0 {
        result.cookieHeader = "auth_token=\(auth); ct0=\(csrf)"
        return result
    }

    let sources = cookieSource ?? BrowserName.defaultCookieSources
    let timeout = cookieTimeoutMs.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 30_000
    let resolvedChrome = chromeProfile ?? normalizedEnvironmentValue(environment["SWEET_COOKIE_CHROME_PROFILE"])
    let resolvedFirefox = firefoxProfile ?? normalizedEnvironmentValue(environment["SWEET_COOKIE_FIREFOX_PROFILE"])
    let provider: CookieProvider = cookieProvider ?? { source, chrome, firefox, timeout in
        await getCookies(
            url: URL(string: "https://x.com/")!,
            origins: [URL(string: "https://x.com/")!, URL(string: "https://twitter.com/")!],
            names: ["auth_token", "ct0"], browsers: [source],
            chromeProfile: chrome, firefoxProfile: firefox, timeoutMs: timeout,
            environment: environment
        )
    }
    for source in sources {
        if Task.isCancelled { break }
        let extracted = await provider(source, resolvedChrome, resolvedFirefox, timeout)
        result.warnings.append(contentsOf: extracted.warnings)
        if Task.isCancelled { break }
        if source == .firefox, hasAmbiguousAuthContexts(extracted.cookies) {
            result.warnings.append("Found multiple Firefox account contexts; refusing to choose an account. Provide both --auth-token and --ct0 explicitly, or use a Firefox profile with only one account context.")
            continue
        }
        if let pair = pickAuth(extracted.cookies) {
            result.authToken = pair.auth
            result.ct0 = pair.ct0
            result.cookieHeader = "auth_token=\(pair.auth); ct0=\(pair.ct0)"
            switch source {
            case .safari: result.source = "Safari"
            case .chrome: result.source = resolvedChrome.flatMap { $0.isEmpty ? nil : $0 }.map { "Chrome profile \"\($0)\"" } ?? "Chrome default profile"
            case .firefox: result.source = resolvedFirefox.flatMap { $0.isEmpty ? nil : $0 }.map { "Firefox profile \"\($0)\"" } ?? "Firefox default profile"
            }
            return result
        }
        switch source {
        case .safari:
            #if os(macOS)
            result.warnings.append("No Twitter cookies found in Safari. Make sure you are logged into x.com in Safari.")
            #endif
        case .chrome:
            result.warnings.append("No Twitter cookies found in Chrome. Make sure you are logged into x.com in Chrome.")
        case .firefox:
            result.warnings.append("No Twitter cookies found in Firefox. Make sure you are logged into x.com in Firefox and the profile exists.")
        }
    }
    let availableBrowsers = BrowserName.defaultCookieSources.map { $0.rawValue.capitalized }.joined(separator: "/")
    if result.authToken == nil {
        result.warnings.append("Missing auth_token - provide via --auth-token, AUTH_TOKEN env var, or login to x.com in \(availableBrowsers)")
    }
    if result.ct0 == nil {
        result.warnings.append("Missing ct0 - provide via --ct0, CT0 env var, or login to x.com in \(availableBrowsers)")
    }
    return result
}

func normalizedEnvironmentValue(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
    return trimmed
}

private func firstEnvironmentCookie(_ env: [String: String], _ keys: [String]) -> (key: String, value: String)? {
    for key in keys {
        if let value = normalizedEnvironmentValue(env[key]) { return (key, value) }
    }
    return nil
}

private func isAuthCookie(_ cookie: Cookie) -> Bool {
    guard !cookie.value.isEmpty, cookie.name == "auth_token" || cookie.name == "ct0" else { return false }
    let domain = cookie.domain.lowercased()
    return domain == "x.com" || domain == ".x.com" || domain == "twitter.com" || domain == ".twitter.com"
}

private func hasAmbiguousAuthContexts(_ cookies: [Cookie]) -> Bool {
    var context: String?
    var foundContext = false
    for cookie in cookies where isAuthCookie(cookie) {
        if foundContext, context != cookie.originAttributes { return true }
        context = cookie.originAttributes
        foundContext = true
    }
    return false
}

func pickAuth(_ cookies: [Cookie]) -> (auth: String, ct0: String)? {
    guard !hasAmbiguousAuthContexts(cookies) else { return nil }
    for domain in ["x.com", "twitter.com"] {
        let dottedDomain = ".\(domain)"
        var auth: String?
        var csrf: String?
        for cookie in cookies where !cookie.value.isEmpty {
            guard cookie.domain.caseInsensitiveCompare(domain) == .orderedSame
                || cookie.domain.caseInsensitiveCompare(dottedDomain) == .orderedSame else { continue }
            if cookie.name == "auth_token", auth == nil { auth = cookie.value }
            if cookie.name == "ct0", csrf == nil { csrf = cookie.value }
            if let auth, let csrf { return (auth, csrf) }
        }
    }
    return nil
}

func deduplicateCookies(_ cookies: [Cookie]) -> [Cookie] {
    struct Key: Hashable { let name: String; let domain: String; let path: String; let originAttributes: String? }
    var seen = Set<Key>()
    return cookies.filter {
        seen.insert(Key(name: $0.name, domain: $0.domain, path: $0.path, originAttributes: $0.originAttributes)).inserted
    }
}
