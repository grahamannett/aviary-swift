import Darwin
import Cookies
import Foundation
import Testing

@Suite struct CookiesTests {
    @Test func hostMatch() {
        #expect(hostMatchesCookieDomain(host: "x.com", cookieDomain: ".x.com"))
        #expect(hostMatchesCookieDomain(host: "x.com", cookieDomain: "x.com"))
    }

    @Test func envBeatsBrowsers() async {
        setenv("AUTH_TOKEN", "env_auth", 1)
        setenv("CT0", "env_ct0", 1)
        let r = await resolveTwitterCredentials(
            authToken: nil, ct0: nil, cookieSource: [.safari], chromeProfile: nil, firefoxProfile: nil, cookieTimeoutMs: 1
        )
        #expect(r.authToken == "env_auth")
        #expect(r.ct0 == "env_ct0")
        unsetenv("AUTH_TOKEN")
        unsetenv("CT0")
    }

    @Test func safariEPERMWarningString() {
        let expected = "macOS blocked Safari cookie access. Grant Full Disk Access to Terminal (or the app that launched aviary)"
        #expect(expected.contains("Full Disk Access"))
    }
}
