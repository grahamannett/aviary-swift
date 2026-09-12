import Foundation

public func getCookies(
    url: URL,
    origins: [URL],
    names: [String],
    browsers: [BrowserName],
    chromeProfile: String?,
    firefoxProfile: String?,
    timeoutMs: Int?
) async -> (cookies: [Cookie], warnings: [String]) {
    var all: [Cookie] = []
    var warnings: [String] = []
    let nameSet = Set(names)
    let originList = origins.isEmpty ? [url] : origins
    for browser in browsers {
        switch browser {
        case .safari:
            let result = SafariCookies.load(origins: originList, names: nameSet)
            all.append(contentsOf: result.cookies)
            warnings.append(contentsOf: result.warnings)
        case .chrome:
            let result = ChromeCookies.load(
                origins: originList,
                names: nameSet,
                profile: chromeProfile,
                timeoutMs: timeoutMs
            )
            all.append(contentsOf: result.cookies)
            warnings.append(contentsOf: result.warnings)
        case .firefox:
            let result = FirefoxCookies.load(origins: originList, names: nameSet, profile: firefoxProfile)
            all.append(contentsOf: result.cookies)
            warnings.append(contentsOf: result.warnings)
        }
    }
    return (all, warnings)
}

public func resolveTwitterCredentials(
    authToken: String?,
    ct0: String?,
    cookieSource: [BrowserName],
    chromeProfile: String?,
    firefoxProfile: String?,
    cookieTimeoutMs: Int?
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
    let env = ProcessInfo.processInfo.environment
    if result.authToken == nil {
        result.authToken = firstEnv(env, ["AUTH_TOKEN", "TWITTER_AUTH_TOKEN"])
        if result.authToken != nil { result.source = "environment" }
    }
    if result.ct0 == nil {
        result.ct0 = firstEnv(env, ["CT0", "TWITTER_CT0"])
        if result.ct0 != nil, result.source == nil { result.source = "environment" }
    }
    if let a = result.authToken, let c = result.ct0 {
        result.cookieHeader = "auth_token=\(a); ct0=\(c)"
        return result
    }

    let sources = cookieSource.isEmpty ? [BrowserName.safari, .chrome, .firefox] : cookieSource
    let twitterURL = URL(string: "https://x.com/")!
    let origins = [URL(string: "https://x.com/")!, URL(string: "https://twitter.com/")!]
    #if os(macOS)
    let timeout = cookieTimeoutMs ?? 30_000
    #else
    let timeout = cookieTimeoutMs
    #endif

    for source in sources {
        if source == .chrome, chromeProfile == nil {
            let profiles = ChromeCookies.listChromeProfileCandidates()
            let toTry: [String?] = profiles.isEmpty ? [nil] : profiles.map { Optional($0) }
            for profile in toTry {
                let extracted = await getCookies(
                    url: twitterURL,
                    origins: origins,
                    names: ["auth_token", "ct0"],
                    browsers: [.chrome],
                    chromeProfile: profile,
                    firefoxProfile: firefoxProfile,
                    timeoutMs: timeout
                )
                result.warnings.append(contentsOf: extracted.warnings)
                if let pair = pickAuth(extracted.cookies) {
                    result.authToken = pair.auth
                    result.ct0 = pair.ct0
                    result.cookieHeader = "auth_token=\(pair.auth); ct0=\(pair.ct0)"
                    result.source = profile.map { "Chrome profile \"\($0)\"" } ?? "Chrome default profile"
                    return result
                }
            }
            result.warnings.append(
                "No Twitter cookies found in Chrome. Make sure you are logged into x.com in Chrome (try --chrome-profile \"Profile 3\" if you use a non-default profile)."
            )
            continue
        }

        let extracted = await getCookies(
            url: twitterURL,
            origins: origins,
            names: ["auth_token", "ct0"],
            browsers: [source],
            chromeProfile: chromeProfile,
            firefoxProfile: firefoxProfile,
            timeoutMs: timeout
        )
        result.warnings.append(contentsOf: extracted.warnings)
        if let pair = pickAuth(extracted.cookies) {
            result.authToken = pair.auth
            result.ct0 = pair.ct0
            result.cookieHeader = "auth_token=\(pair.auth); ct0=\(pair.ct0)"
            switch source {
            case .safari: result.source = "Safari"
            case .chrome: result.source = chromeProfile.map { "Chrome profile \"\($0)\"" } ?? "Chrome default profile"
            case .firefox: result.source = firefoxProfile.map { "Firefox profile \"\($0)\"" } ?? "Firefox default profile"
            }
            return result
        }
        switch source {
        case .safari:
            result.warnings.append("No Twitter cookies found in Safari. Make sure you are logged into x.com in Safari.")
        case .chrome:
            result.warnings.append("No Twitter cookies found in Chrome. Make sure you are logged into x.com in Chrome.")
        case .firefox:
            result.warnings.append(
                "No Twitter cookies found in Firefox. Make sure you are logged into x.com in Firefox and the profile exists."
            )
        }
    }

    if result.authToken == nil {
        result.warnings.append(
            "Missing auth_token - provide via --auth-token, AUTH_TOKEN env var, or login to x.com in Safari/Chrome/Firefox"
        )
    }
    if result.ct0 == nil {
        result.warnings.append(
            "Missing ct0 - provide via --ct0, CT0 env var, or login to x.com in Safari/Chrome/Firefox"
        )
    }
    return result
}

private func firstEnv(_ env: [String: String], _ keys: [String]) -> String? {
    for key in keys {
        if let v = env[key], !v.isEmpty { return v }
    }
    return nil
}

private func pickAuth(_ cookies: [Cookie]) -> (auth: String, ct0: String)? {
    func pick(_ name: String) -> String? {
        let matches = cookies.filter { $0.name == name }
        if let x = matches.first(where: { $0.domain.hasSuffix("x.com") }) { return x.value }
        if let t = matches.first(where: { $0.domain.hasSuffix("twitter.com") }) { return t.value }
        return matches.first?.value
    }
    guard let auth = pick("auth_token"), let ct0 = pick("ct0") else { return nil }
    return (auth, ct0)
}
