import Foundation

public struct Cookie: Sendable {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    public var expires: Int?
    public var secure: Bool
    public var httpOnly: Bool

    public init(
        name: String,
        value: String,
        domain: String,
        path: String = "/",
        expires: Int? = nil,
        secure: Bool = false,
        httpOnly: Bool = false
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expires = expires
        self.secure = secure
        self.httpOnly = httpOnly
    }
}

public enum BrowserName: String, Sendable, CaseIterable {
    case safari
    case chrome
    case firefox
}

public struct TwitterCookies: Sendable {
    public var authToken: String?
    public var ct0: String?
    public var cookieHeader: String?
    public var source: String?
    public var warnings: [String]

    public init(
        authToken: String? = nil,
        ct0: String? = nil,
        cookieHeader: String? = nil,
        source: String? = nil,
        warnings: [String] = []
    ) {
        self.authToken = authToken
        self.ct0 = ct0
        self.cookieHeader = cookieHeader
        self.source = source
        self.warnings = warnings
    }

    public var isComplete: Bool { authToken != nil && ct0 != nil }
}

public func hostMatchesCookieDomain(host: String, cookieDomain: String) -> Bool {
    let normalizedHost = host.lowercased()
    var domain = cookieDomain
    if domain.hasPrefix(".") {
        domain = String(domain.dropFirst())
    }
    let domainLower = domain.lowercased()
    return normalizedHost == domainLower || normalizedHost.hasSuffix(".\(domainLower)")
}
