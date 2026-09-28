import Foundation
import SQLite3
import XCTest
@testable import Cookies

private actor CookieRecorder {
    private(set) var calls: [BrowserName] = []
    let fixtures: [BrowserName: [Cookie]]
    init(_ fixtures: [BrowserName: [Cookie]] = [:]) { self.fixtures = fixtures }
    func read(_ browser: BrowserName, _: String?, _: String?, _: Double?) -> (cookies: [Cookie], warnings: [String]) {
        calls.append(browser)
        return (fixtures[browser] ?? [], [])
    }
}

final class CookiesTests: XCTestCase {
    private var directory: URL!
    private let origins = [URL(string: "https://x.com/")!, URL(string: "https://twitter.com/")!]

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("aviary-cookie-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private func pair(_ value: String, domain: String = "x.com") -> [Cookie] {
        [Cookie(name: "auth_token", value: value, domain: domain), Cookie(name: "ct0", value: "csrf-\(value)", domain: domain)]
    }

    func testHostMatchingRejectsSuffixImpostors() {
        XCTAssertTrue(hostMatchesCookieDomain(host: "x.com", cookieDomain: ".x.com"))
        XCTAssertTrue(hostMatchesCookieDomain(host: "api.x.com", cookieDomain: "X.COM"))
        XCTAssertFalse(hostMatchesCookieDomain(host: "notx.com", cookieDomain: "x.com"))
        XCTAssertFalse(hostMatchesCookieDomain(host: "x.com", cookieDomain: "api.x.com"))
    }

    func testCLIPrecedenceAndEnvironmentNormalization() async {
        let recorder = CookieRecorder()
        let provider: CookieProvider = { await recorder.read($0, $1, $2, $3) }
        let explicit = await resolveTwitterCredentials(
            authToken: "cli-auth", ct0: "cli-csrf", cookieSource: [.safari],
            chromeProfile: nil, firefoxProfile: nil, cookieTimeoutMs: nil,
            environment: ["AUTH_TOKEN": "env-auth", "CT0": "env-csrf"], cookieProvider: provider
        )
        XCTAssertEqual(explicit.cookieHeader, "auth_token=cli-auth; ct0=cli-csrf")
        XCTAssertEqual(explicit.source, "CLI argument")
        let normalized = await resolveTwitterCredentials(
            authToken: nil, ct0: nil, chromeProfile: nil, firefoxProfile: nil, cookieTimeoutMs: nil,
            environment: ["AUTH_TOKEN": " \n ", "TWITTER_AUTH_TOKEN": " alternate ", "CT0": " csrf\n"],
            cookieProvider: provider
        )
        XCTAssertEqual(normalized.authToken, "alternate")
        XCTAssertEqual(normalized.ct0, "csrf")
        XCTAssertEqual(normalized.source, "env TWITTER_AUTH_TOKEN")
        let calls = await recorder.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testDefaultBrowserOrderSkipsEmptyAndIncompletePairs() async {
        let recorder = CookieRecorder([
            .safari: [Cookie(name: "auth_token", value: "", domain: "x.com"), Cookie(name: "ct0", value: "empty-auth-csrf", domain: "x.com")],
            .chrome: [Cookie(name: "auth_token", value: "incomplete", domain: "x.com")],
            .firefox: pair("firefox"),
        ])
        let result = await resolveTwitterCredentials(
            authToken: "partial-cli", ct0: nil, chromeProfile: nil, firefoxProfile: nil, cookieTimeoutMs: nil,
            environment: [:], cookieProvider: { await recorder.read($0, $1, $2, $3) }
        )
        XCTAssertEqual(result.authToken, "firefox")
        XCTAssertEqual(result.ct0, "csrf-firefox")
        XCTAssertEqual(result.source, "Firefox default profile")
        let calls = await recorder.calls
        XCTAssertEqual(calls, [.safari, .chrome, .firefox])
        XCTAssertEqual(result.warnings.count, 2)
    }

    func testEmptySourceListDoesNotReadBrowsersAndBlankCredentialsAreIncomplete() async {
        let recorder = CookieRecorder()
        let result = await resolveTwitterCredentials(
            authToken: nil, ct0: nil, cookieSource: [], chromeProfile: nil, firefoxProfile: nil, cookieTimeoutMs: nil,
            environment: ["AUTH_TOKEN": " ", "CT0": "\n"], cookieProvider: { await recorder.read($0, $1, $2, $3) }
        )
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.warnings.count, 2)
        let calls = await recorder.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertFalse(TwitterCookies(authToken: "", ct0: "csrf").isComplete)
    }

    func testEmptyXCookieFallsBackToTwitterCookie() {
        let cookies = pair("", domain: "x.com") + pair("twitter", domain: "twitter.com")
        XCTAssertEqual(pickAuth(cookies)?.auth, "twitter")
        XCTAssertNil(pickAuth(pair("")))
        XCTAssertEqual(pickAuth(cookies)?.ct0, "csrf-twitter")
    }

    func testCredentialsStayWithinOneDomainAndSkipEmptyDuplicates() {
        let incompleteX = [Cookie(name: "auth_token", value: "x-account", domain: "x.com")]
        let twitter = pair("twitter-account", domain: ".TWITTER.COM")
        XCTAssertEqual(pickAuth(incompleteX + twitter)?.auth, "twitter-account")
        XCTAssertEqual(pickAuth(incompleteX + twitter)?.ct0, "csrf-twitter-account")
        XCTAssertNil(pickAuth(incompleteX + [Cookie(name: "ct0", value: "other-account", domain: "twitter.com")]))
        XCTAssertNil(pickAuth(pair("impostor", domain: "notx.com")))
        XCTAssertNil(pickAuth(pair("public-suffix", domain: "com")))
        XCTAssertNil(pickAuth(pair("subdomain", domain: "api.x.com")))
        let empty = [Cookie(name: "auth_token", value: "", domain: "x.com")]
        XCTAssertEqual(pickAuth(empty + pair("valid"))?.auth, "valid")
    }

    func testEnvironmentProfileAppearsInCredentialSource() async {
        let cookies = pair("selected")
        let result = await resolveTwitterCredentials(
            authToken: nil, ct0: nil, cookieSource: [.firefox], chromeProfile: nil, firefoxProfile: nil, cookieTimeoutMs: nil,
            environment: ["SWEET_COOKIE_FIREFOX_PROFILE": " selected.default-release "],
            cookieProvider: { _, _, _, _ in (cookies, []) }
        )
        XCTAssertEqual(result.source, "Firefox profile \"selected.default-release\"")
    }

    func testFirefoxSessionCookiesExpiryAndDuplicateOrder() throws {
        let url = directory.appendingPathComponent("cookies.sqlite")
        let db = try database(url, sql: """
        CREATE TABLE moz_cookies(name TEXT, value TEXT, host TEXT, path TEXT, expiry INTEGER, isSecure INTEGER, isHttpOnly INTEGER);
        INSERT INTO moz_cookies VALUES('auth_token','older','.x.com','/',1500,1,1);
        INSERT INTO moz_cookies VALUES('auth_token','newer','.x.com','/',2000,1,1);
        INSERT INTO moz_cookies VALUES('ct0','session','.x.com','/',0,1,0);
        INSERT INTO moz_cookies VALUES('expired','old','.x.com','/',999,0,0);
        INSERT INTO moz_cookies VALUES('boundary','old','.x.com','/',1000,0,0);
        INSERT INTO moz_cookies VALUES('auth_token','unrelated','.example.com','/',3000,1,1);
        """)
        sqlite3_close(db)
        let result = FirefoxCookies.load(origins: origins, names: [], profile: url.path, roots: [], now: 1000)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(result.cookies.map(\.name), ["auth_token", "ct0"])
        XCTAssertEqual(result.cookies.first?.value, "newer")
        XCTAssertNil(result.cookies.last?.expires)
        XCTAssertEqual(pickAuth(result.cookies)?.ct0, "session")
    }

    func testFirefoxReadsUncheckpointedWAL() throws {
        let url = directory.appendingPathComponent("cookies.sqlite")
        let db = try database(url, sql: """
        PRAGMA journal_mode=WAL;
        PRAGMA wal_autocheckpoint=0;
        CREATE TABLE moz_cookies(name TEXT, value TEXT, host TEXT, path TEXT, expiry INTEGER, isSecure INTEGER, isHttpOnly INTEGER);
        INSERT INTO moz_cookies VALUES('auth_token','in-wal','.x.com','/',2000,1,1);
        """)
        defer { sqlite3_close(db) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + "-wal"))
        let result = FirefoxCookies.load(origins: origins, names: ["auth_token"], profile: url.path, roots: [], now: 1000)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(result.cookies.first?.value, "in-wal")
    }

    func testProfilesUseBirdDefaultsAndExactNames() throws {
        let chromeRoot = directory.appendingPathComponent("chrome")
        try emptyFile(chromeRoot.appendingPathComponent("Default/Cookies"))
        try emptyFile(chromeRoot.appendingPathComponent("Profile 1/Cookies"))
        try #"{"profile":{"last_used":"Profile 1"}}"#.write(to: chromeRoot.appendingPathComponent("Local State"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ChromeCookies.resolveCookiesDb(profile: nil, roots: [chromeRoot.path]), chromeRoot.appendingPathComponent("Default/Cookies").path)
        XCTAssertEqual(ChromeCookies.resolveCookiesDb(profile: " Profile 1 ", roots: [chromeRoot.path]), chromeRoot.appendingPathComponent("Profile 1/Cookies").path)
        XCTAssertNil(ChromeCookies.resolveCookiesDb(profile: "missing/path", roots: [chromeRoot.path]))
        let firefoxRoot = directory.appendingPathComponent("firefox")
        try emptyFile(firefoxRoot.appendingPathComponent("aaa.default/cookies.sqlite"))
        try emptyFile(firefoxRoot.appendingPathComponent("zzz.default-release/cookies.sqlite"))
        XCTAssertEqual(FirefoxCookies.resolveDb(profile: nil, roots: [firefoxRoot.path]), firefoxRoot.appendingPathComponent("zzz.default-release/cookies.sqlite").path)
        XCTAssertEqual(FirefoxCookies.resolveDb(profile: "aaa.default", roots: [firefoxRoot.path]), firefoxRoot.appendingPathComponent("aaa.default/cookies.sqlite").path)
        XCTAssertNil(FirefoxCookies.resolveDb(profile: "default", roots: [firefoxRoot.path]))
    }

    func testChromeEncryptedFixtureHashPrefixAndDuplicateOrder() throws {
        // Independent Node crypto fixture: PBKDF2-SHA1(password, saltysalt, 1003, 16), AES-CBC with a space IV.
        let encrypted = "763130e8628ff4effbd253b343d2f3d6557ac8ef9cee406d0deac75efde26b9949ce5aa5a1b9109637079993c85970c7003fc8"
        XCTAssertEqual(ChromeCrypto.deriveAes128CbcKey(password: "fixture-password", iterations: 1003).map { String(format: "%02x", $0) }.joined(), "5d84e88b8d2628e23102b464d77a5bbd")
        let url = directory.appendingPathComponent("Cookies")
        let db = try database(url, sql: """
        CREATE TABLE meta(key TEXT, value TEXT);
        INSERT INTO meta VALUES('version','24');
        CREATE TABLE cookies(name TEXT, value TEXT, host_key TEXT, path TEXT, expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, encrypted_value BLOB);
        INSERT INTO cookies VALUES('auth_token','older','.x.com','/',11644475100000000,1,1,X'');
        INSERT INTO cookies VALUES('auth_token','','.x.com','/',11644475600000000,1,1,X'\(encrypted)');
        INSERT INTO cookies VALUES('ct0','session','.x.com','/',0,1,0,X'');
        INSERT INTO cookies VALUES('expired','old','.x.com','/',11644474599000000,0,0,X'');
        """)
        sqlite3_close(db)
        let result = ChromeCookies.load(
            origins: origins, names: [], profile: url.path, timeoutMs: 1, environment: [:], roots: [],
            passwordReader: { _, _ in .success("fixture-password") }, now: 1000
        )
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(result.cookies.map(\.name), ["auth_token", "ct0"])
        XCTAssertEqual(pickAuth(result.cookies)?.auth, "fixture-auth")
        XCTAssertEqual(pickAuth(result.cookies)?.ct0, "session")
    }

    func testProviderFailuresProduceActionableWarnings() throws {
        let url = directory.appendingPathComponent("Cookies")
        try emptyFile(url)
        let denied = ChromeCookies.load(
            origins: origins, names: [], profile: url.path, timeoutMs: 1, environment: [:], roots: [],
            passwordReader: { _, _ in .failure(NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "timeout"])) }
        )
        XCTAssertTrue(denied.cookies.isEmpty)
        XCTAssertTrue(denied.warnings.joined().contains("timeout"))
        let empty = ChromeCookies.load(
            origins: origins, names: [], profile: url.path, timeoutMs: 1, environment: [:], roots: [],
            passwordReader: { _, _ in .success("") }
        )
        XCTAssertTrue(empty.warnings.joined().contains("empty"))
        let invalidDB = FirefoxCookies.load(origins: origins, names: [], profile: url.path, roots: [])
        XCTAssertTrue(invalidDB.cookies.isEmpty)
        XCTAssertTrue(invalidDB.warnings.joined().contains("moz_cookies"))
    }

    func testSafariBinaryFixtureAndPermissionWarning() throws {
        let fixture = safariFixture(name: "auth_token", value: "synthetic")
        let decoded = try SafariCookies.decodeBinaryCookies(fixture)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.domain, "x.com")
        XCTAssertEqual(decoded.first?.value, "synthetic")
        XCTAssertEqual(decoded.first?.secure, true)
        XCTAssertEqual(decoded.first?.httpOnly, true)
        XCTAssertNil(decoded.first?.expires)
        let url = directory.appendingPathComponent("Cookies.binarycookies")
        try fixture.write(to: url)
        let filtered = SafariCookies.load(origins: origins, names: ["ct0"], paths: [url.path])
        XCTAssertTrue(filtered.cookies.isEmpty)
        let denied = SafariCookies.load(origins: origins, names: [], paths: [url.path], readFile: { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        })
        XCTAssertTrue(denied.warnings.joined().contains("Full Disk Access"))
        let missing = SafariCookies.load(origins: origins, names: [], paths: [directory.appendingPathComponent("missing").path])
        XCTAssertEqual(missing.warnings, ["Safari Cookies.binarycookies not found."])
    }

    func testMalformedSafariDataIsRejectedWithoutTrapping() throws {
        XCTAssertThrowsError(try SafariCookies.decodeBinaryCookies(Data([0x63, 0x6f, 0x6f, 0x6b, 0, 0, 0, 1])))
        var truncated = safariFixture(name: "auth_token", value: "synthetic")
        truncated.removeLast()
        XCTAssertThrowsError(try SafariCookies.decodeBinaryCookies(truncated))
        var invalidOffset = safariFixture(name: "auth_token", value: "synthetic")
        putUInt32(0xffff_ffff, in: &invalidOffset, at: 20, bigEndian: false)
        XCTAssertThrowsError(try SafariCookies.decodeBinaryCookies(invalidOffset))
        let url = directory.appendingPathComponent("Cookies.binarycookies")
        try truncated.write(to: url)
        let result = SafariCookies.load(origins: origins, names: [], paths: [url.path])
        XCTAssertTrue(result.cookies.isEmpty)
        XCTAssertTrue(result.warnings.joined().contains("Truncated"))
    }

    func testChromeRejectsMalformedPKCS7Padding() {
        let bytes: [UInt8] = [
            0x76, 0x31, 0x30, 0xe8, 0x62, 0x8f, 0xf4, 0xef, 0xfb, 0xd2, 0x53, 0xb3, 0x43, 0xd2, 0xf3, 0xd6, 0x55,
            0x7a, 0xc8, 0xef, 0x9c, 0xee, 0x40, 0x6d, 0x0d, 0xea, 0xc7, 0x5e, 0xfd, 0xe2, 0x6b, 0x99, 0x49, 0xce,
            0x5a, 0xa5, 0xa1, 0xb9, 0x10, 0x96, 0x37, 0x07, 0x99, 0x93, 0xc8, 0x59, 0x70, 0xc7, 0x00, 0x3f, 0xc8,
        ]
        var encrypted = Data(bytes)
        // Alter one padding byte in the final plaintext block, leaving its pad-length byte unchanged.
        encrypted[3 + 16 + 14] ^= 1
        let key = ChromeCrypto.deriveAes128CbcKey(password: "fixture-password", iterations: 1003)
        XCTAssertNil(ChromeCrypto.decryptAes128Cbc(encryptedValue: encrypted, keys: [key], stripHashPrefix: true))
    }

    func testSafariRejectsInvalidCookieStringOffsetsAndExpiration() throws {
        for field in [16, 20, 24, 28] {
            var fixture = safariFixture(name: "auth_token", value: "synthetic")
            putUInt32(0xffff_ffff, in: &fixture, at: 28 + field, bigEndian: false)
            XCTAssertTrue(try SafariCookies.decodeBinaryCookies(fixture).isEmpty)
        }
        for expiration in [Double.infinity, Double.nan, Double.greatestFiniteMagnitude] {
            var fixture = safariFixture(name: "auth_token", value: "synthetic")
            for index in 0..<8 {
                fixture[28 + 40 + index] = UInt8(truncatingIfNeeded: expiration.bitPattern >> (index * 8))
            }
            XCTAssertTrue(try SafariCookies.decodeBinaryCookies(fixture).isEmpty)
        }
    }

    private func emptyFile(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    private func database(_ url: URL, sql: String) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "fixture", code: 1)
        }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "SQLite fixture failed"
            sqlite3_free(error)
            sqlite3_close(db)
            throw NSError(domain: "fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return db
    }

    private func safariFixture(name: String, value: String) -> Data {
        var record = Data(repeating: 0, count: 56)
        for (offsetField, value) in [(16, ".x.com"), (20, name), (24, "/"), (28, value)] {
            putUInt32(UInt32(record.count), in: &record, at: offsetField, bigEndian: false)
            record.append(contentsOf: value.utf8)
            record.append(0)
        }
        putUInt32(UInt32(record.count), in: &record, at: 0, bigEndian: false)
        putUInt32(5, in: &record, at: 8, bigEndian: false)
        var page = Data([0, 0, 1, 0, 1, 0, 0, 0, 16, 0, 0, 0, 0, 0, 0, 0])
        page.append(record)
        var file = Data([0x63, 0x6f, 0x6f, 0x6b, 0, 0, 0, 1, 0, 0, 0, 0])
        putUInt32(UInt32(page.count), in: &file, at: 8, bigEndian: true)
        file.append(page)
        return file
    }

    private func putUInt32(_ value: UInt32, in data: inout Data, at offset: Int, bigEndian: Bool) {
        for index in 0..<4 {
            let shift = bigEndian ? (3 - index) * 8 : index * 8
            data[offset + index] = UInt8(truncatingIfNeeded: value >> shift)
        }
    }
}
