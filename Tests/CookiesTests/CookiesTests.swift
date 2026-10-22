import Foundation
import CSQLite
import XCTest
@testable import Cookies

private actor CookieRecorder {
    private(set) var calls: [BrowserName] = []
    private(set) var timeouts: [Double?] = []
    let fixtures: [BrowserName: [Cookie]]
    init(_ fixtures: [BrowserName: [Cookie]] = [:]) { self.fixtures = fixtures }
    func read(_ browser: BrowserName, _: String?, _: String?, _ timeout: Double?) -> (cookies: [Cookie], warnings: [String]) {
        calls.append(browser)
        timeouts.append(timeout)
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

    func testCancellationStopsBrowserFallbackAndRejectsCancelledProviderCredentials() async {
        let recorder = CookieRecorder([
            .chrome: [Cookie(name: "auth_token", value: "cancelled-auth", domain: "x.com"),
                      Cookie(name: "ct0", value: "cancelled-csrf", domain: "x.com")],
            .firefox: [Cookie(name: "auth_token", value: "other-account", domain: "x.com"),
                       Cookie(name: "ct0", value: "other-csrf", domain: "x.com")],
        ])
        let task = Task.detached {
            await resolveTwitterCredentials(
                authToken: nil, ct0: nil, cookieSource: [.chrome, .firefox],
                chromeProfile: nil, firefoxProfile: nil, cookieTimeoutMs: nil,
                environment: [:], cookieProvider: { browser, chrome, firefox, timeout in
                    let result = await recorder.read(browser, chrome, firefox, timeout)
                    withUnsafeCurrentTask { $0?.cancel() }
                    return result
                }
            )
        }
        let result = await task.value
        XCTAssertFalse(result.isComplete)
        XCTAssertNil(result.cookieHeader)
        let calls = await recorder.calls
        XCTAssertEqual(calls, [.chrome])
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
        XCTAssertEqual(calls, BrowserName.defaultCookieSources)
        XCTAssertEqual(result.warnings.count, BrowserName.defaultCookieSources.count - 1)
        let timeouts = await recorder.timeouts
        XCTAssertEqual(timeouts, Array(repeating: 30_000, count: BrowserName.defaultCookieSources.count))
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

    func testFirefoxPreservesContainerIdentityAndRejectsAmbiguousAccounts() async throws {
        let url = directory.appendingPathComponent("cookies.sqlite")
        let db = try database(url, sql: """
        CREATE TABLE moz_cookies(name TEXT, value TEXT, host TEXT, path TEXT, expiry INTEGER, isSecure INTEGER, isHttpOnly INTEGER, originAttributes TEXT);
        INSERT INTO moz_cookies VALUES('auth_token','default-auth','.x.com','/',2000,1,1,'');
        INSERT INTO moz_cookies VALUES('ct0','default-csrf','.x.com','/',2000,1,0,'');
        INSERT INTO moz_cookies VALUES('auth_token','container-auth','.x.com','/',3000,1,1,'^userContextId=2');
        INSERT INTO moz_cookies VALUES('ct0','container-csrf','.x.com','/',3000,1,0,'^userContextId=2');
        """)
        defer { sqlite3_close(db) }
        let extracted = FirefoxCookies.load(origins: origins, names: ["auth_token", "ct0"], profile: url.path, roots: [], now: 1000)
        XCTAssertTrue(extracted.warnings.isEmpty)
        XCTAssertEqual(Set(extracted.cookies.map(\.value)), ["default-auth", "default-csrf", "container-auth", "container-csrf"])
        XCTAssertEqual(Set(extracted.cookies.compactMap(\.originAttributes)), ["", "^userContextId=2"])
        XCTAssertNil(pickAuth(extracted.cookies))
        let result = await resolveTwitterCredentials(
            authToken: nil, ct0: nil, cookieSource: [.firefox], chromeProfile: nil, firefoxProfile: url.path,
            cookieTimeoutMs: nil, environment: [:], cookieProvider: { _, _, _, _ in extracted }
        )
        XCTAssertFalse(result.isComplete)
        XCTAssertNil(result.cookieHeader)
        XCTAssertTrue(result.warnings.contains { $0.contains("multiple Firefox account contexts") })
        XCTAssertFalse(result.warnings.joined().contains("container-auth"))
    }

    func testFirefoxNeverPairsCredentialsAcrossContainers() throws {
        let url = directory.appendingPathComponent("cookies.sqlite")
        let db = try database(url, sql: """
        CREATE TABLE moz_cookies(name TEXT, value TEXT, host TEXT, path TEXT, expiry INTEGER, isSecure INTEGER, isHttpOnly INTEGER, originAttributes TEXT);
        INSERT INTO moz_cookies VALUES('auth_token','first-auth','.x.com','/',2000,1,1,'^userContextId=1');
        INSERT INTO moz_cookies VALUES('ct0','second-csrf','.x.com','/',2000,1,0,'^userContextId=2');
        """)
        defer { sqlite3_close(db) }
        let result = FirefoxCookies.load(origins: origins, names: [], profile: url.path, roots: [], now: 1000)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertNil(pickAuth(result.cookies))
    }

    func testFirefoxSingleContainerRetainsDomainPreferenceAndIgnoresUnrelatedContexts() throws {
        let url = directory.appendingPathComponent("cookies.sqlite")
        let db = try database(url, sql: """
        CREATE TABLE moz_cookies(name TEXT, value TEXT, host TEXT, path TEXT, expiry INTEGER, isSecure INTEGER, isHttpOnly INTEGER, originAttributes TEXT);
        INSERT INTO moz_cookies VALUES('auth_token','twitter-auth','.twitter.com','/',3000,1,1,'^userContextId=3&privateBrowsingId=1');
        INSERT INTO moz_cookies VALUES('ct0','twitter-csrf','.twitter.com','/',3000,1,0,'^userContextId=3&privateBrowsingId=1');
        INSERT INTO moz_cookies VALUES('auth_token','x-auth','.x.com','/',2000,1,1,'^userContextId=3&privateBrowsingId=1');
        INSERT INTO moz_cookies VALUES('ct0','x-csrf','.x.com','/',2000,1,0,'^userContextId=3&privateBrowsingId=1');
        INSERT INTO moz_cookies VALUES('auth_token','expired','.x.com','/',999,1,1,'^userContextId=4');
        INSERT INTO moz_cookies VALUES('ct0','','.x.com','/',2000,1,0,'^userContextId=4');
        INSERT INTO moz_cookies VALUES('preference','unrelated','.x.com','/',2000,1,0,'');
        """)
        defer { sqlite3_close(db) }
        let result = FirefoxCookies.load(origins: origins, names: [], profile: url.path, roots: [], now: 1000)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(pickAuth(result.cookies)?.auth, "x-auth")
        XCTAssertEqual(pickAuth(result.cookies)?.ct0, "x-csrf")
    }

    func testFirefoxIncompleteSecondContextStillRejectsAutomaticSelection() {
        let cookies = [
            Cookie(name: "auth_token", value: "default-auth", domain: "x.com", originAttributes: ""),
            Cookie(name: "ct0", value: "default-csrf", domain: "x.com", originAttributes: ""),
            Cookie(name: "auth_token", value: "other-auth", domain: "twitter.com", originAttributes: "^userContextId=2"),
        ]
        XCTAssertNil(pickAuth(cookies))
        XCTAssertNil(pickAuth(Array(cookies.reversed())))
    }

    func testFirefoxPartitionIdentityIsNotReducedToContainerID() {
        let cookies = [
            Cookie(name: "auth_token", value: "first-auth", domain: "x.com", originAttributes: "^userContextId=1&partitionKey=%28https%2Cx.com%29"),
            Cookie(name: "ct0", value: "other-csrf", domain: "x.com", originAttributes: "^userContextId=1&partitionKey=%28https%2Cexample.com%29"),
        ]
        XCTAssertNil(pickAuth(cookies))
    }

    func testSQLiteSnapshotUsesCommittedWALStateAndSurvivesCheckpoint() throws {
        let url = directory.appendingPathComponent("cookies.sqlite")
        let db = try database(url, sql: """
        PRAGMA journal_mode=WAL;
        PRAGMA wal_autocheckpoint=0;
        CREATE TABLE credentials(name TEXT PRIMARY KEY, value TEXT);
        INSERT INTO credentials VALUES('auth_token','old-auth'),('ct0','old-csrf');
        """)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "BEGIN IMMEDIATE; UPDATE credentials SET value = 'new-auth' WHERE name = 'auth_token';", nil, nil, nil), SQLITE_OK)
        let before = try SqliteHelper.snapshot(from: url.path)
        defer { try? FileManager.default.removeItem(at: before.deletingLastPathComponent()) }
        XCTAssertEqual(try SqliteHelper.query(before.path, sql: "SELECT value FROM credentials ORDER BY name").compactMap { $0["value"] as? String }, ["old-auth", "old-csrf"])
        XCTAssertEqual(sqlite3_exec(db, "UPDATE credentials SET value = 'new-csrf' WHERE name = 'ct0'; COMMIT;", nil, nil, nil), SQLITE_OK)
        let after = try SqliteHelper.snapshot(from: url.path)
        defer { try? FileManager.default.removeItem(at: after.deletingLastPathComponent()) }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try SqliteHelper.query(after.path, sql: "SELECT value FROM credentials ORDER BY name").compactMap { $0["value"] as? String }, ["new-auth", "new-csrf"])
        XCTAssertEqual(try SqliteHelper.query(before.path, sql: "SELECT value FROM credentials ORDER BY name").compactMap { $0["value"] as? String }, ["old-auth", "old-csrf"])
        XCTAssertEqual(try SqliteHelper.query(after.path, sql: "PRAGMA integrity_check").first?["integrity_check"] as? String, "ok")
    }

    func testSQLiteSnapshotRejectsExclusiveLockAndRecoversAfterUnlock() throws {
        let url = directory.appendingPathComponent("locked.sqlite")
        let db = try database(url, sql: "CREATE TABLE state(value INTEGER); INSERT INTO state VALUES(1); BEGIN EXCLUSIVE; UPDATE state SET value = 2;")
        defer { sqlite3_close(db) }
        XCTAssertThrowsError(try SqliteHelper.snapshot(from: url.path)) { error in
            XCTAssertEqual((error as NSError).code, Int(SQLITE_BUSY))
        }
        XCTAssertEqual(sqlite3_exec(db, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
        let snapshot = try SqliteHelper.snapshot(from: url.path)
        defer { try? FileManager.default.removeItem(at: snapshot.deletingLastPathComponent()) }
        XCTAssertEqual(try SqliteHelper.query(snapshot.path, sql: "SELECT value FROM state").first?["value"] as? Int64, 1)
    }

    func testSQLiteSnapshotRejectsCorruptDatabase() throws {
        let url = directory.appendingPathComponent("corrupt.sqlite")
        try Data("not a SQLite database".utf8).write(to: url)
        XCTAssertThrowsError(try SqliteHelper.snapshot(from: url.path))
        let result = FirefoxCookies.load(origins: origins, names: [], profile: url.path, roots: [])
        XCTAssertTrue(result.cookies.isEmpty)
        XCTAssertTrue(result.warnings.contains { $0.contains("Failed to read Firefox cookies") })
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
        // Independent Node crypto fixtures: PBKDF2-SHA1(password, saltysalt,
        // platform rounds, 16), AES-CBC with a space IV and a 32-byte hash prefix.
        #if os(Linux)
        let encrypted = "7631307c85eec015f7ccd901b24a3c7c7e21df94abcae88543b965b8eaf04d9b315c391206280087fae016ff49c5c4ff423103"
        #else
        let encrypted = "763130e8628ff4effbd253b343d2f3d6557ac8ef9cee406d0deac75efde26b9949ce5aa5a1b9109637079993c85970c7003fc8"
        #endif
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
        #if os(macOS)
        let empty = ChromeCookies.load(
            origins: origins, names: [], profile: url.path, timeoutMs: 1, environment: [:], roots: [],
            passwordReader: { _, _ in .success("") }
        )
        XCTAssertTrue(empty.warnings.joined().contains("empty"))
        #endif
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
        #if os(macOS)
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
        #else
        let unsupported = SafariCookies.load(origins: origins, names: [])
        XCTAssertTrue(unsupported.cookies.isEmpty)
        XCTAssertEqual(unsupported.warnings, ["Safari cookies are only available on macOS."])
        #endif
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
        #if os(macOS)
        XCTAssertTrue(result.warnings.joined().contains("Truncated"))
        #else
        XCTAssertEqual(result.warnings, ["Safari cookies are only available on macOS."])
        #endif
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

    func testPBKDF2AndChromeCbcIndependentVectorsOnEveryPlatform() {
        // RFC 6070 PBKDF2-HMAC-SHA1 vectors, followed by independent Node
        // crypto fixtures for both existing Chrome cookie key derivations.
        XCTAssertEqual(hex(ChromeCrypto.pbkdf2SHA1(password: "password", salt: Data("salt".utf8), iterations: 1, keyLength: 20)), "0c60c80f961f0e71f3a9b524af6012062fe037a6")
        XCTAssertEqual(hex(ChromeCrypto.pbkdf2SHA1(password: "password", salt: Data("salt".utf8), iterations: 2, keyLength: 20)), "ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957")
        let fixtures = [
            (1, "b0869219efa7a3882db045fb68f43b42", "7631307c85eec015f7ccd901b24a3c7c7e21df94abcae88543b965b8eaf04d9b315c391206280087fae016ff49c5c4ff423103"),
            (1003, "5d84e88b8d2628e23102b464d77a5bbd", "763130e8628ff4effbd253b343d2f3d6557ac8ef9cee406d0deac75efde26b9949ce5aa5a1b9109637079993c85970c7003fc8"),
        ]
        for (rounds, expectedKey, encrypted) in fixtures {
            let key = ChromeCrypto.deriveAes128CbcKey(password: "fixture-password", iterations: rounds)
            XCTAssertEqual(hex(key), expectedKey)
            XCTAssertEqual(ChromeCrypto.decryptAes128Cbc(encryptedValue: unhex(encrypted), keys: [key], stripHashPrefix: true), "fixture-auth")
            XCTAssertNil(ChromeCrypto.decryptAes128Cbc(encryptedValue: unhex(encrypted).dropLast(), keys: [key], stripHashPrefix: true))
        }
    }

    func testLinuxKeyringChecksLaunchExitAndEmptyOutputWithoutExposingSecrets() throws {
        let absent = LinuxKeyring.readPassword(timeoutMs: 100, executableURL: directory.appendingPathComponent("missing-secret-tool"))
        XCTAssertTrue(keyringError(absent).contains("could not be started"))
        let shell = URL(fileURLWithPath: "/bin/sh")
        let nonzero = LinuxKeyring.readPassword(
            timeoutMs: 1000, executableURL: shell,
            arguments: ["-c", "printf private-password; printf private-stderr >&2; exit 9"]
        )
        let message = keyringError(nonzero)
        XCTAssertTrue(message.contains("status 9"))
        XCTAssertFalse(message.contains("private"))
        let empty = LinuxKeyring.readPassword(timeoutMs: 1000, executableURL: shell, arguments: ["-c", "printf '  '"])
        XCTAssertTrue(keyringError(empty).contains("no password"))
        let success = LinuxKeyring.readPassword(timeoutMs: 1000, executableURL: shell, arguments: ["-c", "printf 'fixture-password\\n'"])
        XCTAssertEqual(try success.get(), "fixture-password")
    }

    func testLinuxKeyringTimeoutStopsAnUnresponsiveHelper() {
        let start = ProcessInfo.processInfo.systemUptime
        let result = LinuxKeyring.readPassword(
            timeoutMs: 30, executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; while :; do :; done"]
        )
        XCTAssertTrue(keyringError(result).contains("timed out"))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
    }

    #if os(Linux)
    func testLinuxDefaultsAndExplicitSafariWarning() async {
        XCTAssertEqual(BrowserName.defaultCookieSources, [.chrome, .firefox])
        let result = await resolveTwitterCredentials(
            authToken: nil, ct0: nil, cookieSource: [.safari], chromeProfile: nil,
            firefoxProfile: nil, cookieTimeoutMs: nil, environment: [:]
        )
        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(result.warnings.contains("Safari cookies are only available on macOS."))
        XCTAssertFalse(result.warnings.joined().contains("logged into x.com in Safari"))
        XCTAssertFalse(result.warnings.joined().contains("Safari/Chrome/Firefox"))
    }

    func testLinuxChromeSafeStorageOverrideAndBasicStorageKeys() throws {
        let url = directory.appendingPathComponent("Cookies")
        let encrypted = "7631307c85eec015f7ccd901b24a3c7c7e21df94abcae88543b965b8eaf04d9b315c391206280087fae016ff49c5c4ff423103"
        let db = try chromeDatabase(url, encrypted: encrypted, metaVersion: 24)
        defer { sqlite3_close(db) }
        let overridden = ChromeCookies.load(
            origins: origins, names: [], profile: url.path, timeoutMs: 1,
            environment: ["SWEET_COOKIE_CHROME_SAFE_STORAGE_PASSWORD": "fixture-password"], roots: []
        )
        XCTAssertTrue(overridden.warnings.isEmpty)
        XCTAssertEqual(pickAuth(overridden.cookies)?.auth, "fixture-auth")
        // Independently encrypted with peanuts and empty-password basic stores.
        for basic in ["76313047fa48bab749c8ce1f50caba670847e1", "7631305f757c63304a78ed25740e436a9c1785"] {
            XCTAssertEqual(sqlite3_exec(db, "UPDATE meta SET value='23'; UPDATE cookies SET encrypted_value=X'\(basic)' WHERE name='auth_token';", nil, nil, nil), SQLITE_OK)
            let recovered = ChromeCookies.load(
                origins: origins, names: [], profile: url.path, timeoutMs: 1,
                environment: [:], roots: [], passwordReader: { _, _ in
                    .failure(NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "keyring unavailable"]))
                }
            )
            XCTAssertEqual(pickAuth(recovered.cookies)?.auth, "basic-auth")
            XCTAssertTrue(recovered.warnings.joined().contains("keyring unavailable"))
            XCTAssertTrue(recovered.warnings.joined().contains("SWEET_COOKIE_CHROME_SAFE_STORAGE_PASSWORD"))
        }
    }

    func testLinuxChromeKeyringFailureContinuesToFirefox() async throws {
        let chromeURL = directory.appendingPathComponent("Cookies")
        let db = try chromeDatabase(chromeURL, encrypted: "7631307c85eec015f7ccd901b24a3c7c7e21df94abcae88543b965b8eaf04d9b315c391206280087fae016ff49c5c4ff423103", metaVersion: 24)
        defer { sqlite3_close(db) }
        let chrome = ChromeCookies.load(
            origins: origins, names: [], profile: chromeURL.path, timeoutMs: 1,
            environment: [:], roots: [], passwordReader: { _, _ in
                .failure(NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "secret-tool timed out"]))
            }
        )
        let firefoxCookies = pair("firefox")
        let result = await resolveTwitterCredentials(
            authToken: nil, ct0: nil, chromeProfile: nil, firefoxProfile: nil,
            cookieTimeoutMs: 1, environment: [:], cookieProvider: { browser, _, _, _ in
                browser == .chrome ? chrome : (firefoxCookies, [])
            }
        )
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.source, "Firefox default profile")
        XCTAssertTrue(result.warnings.joined().contains("secret-tool timed out"))
        XCTAssertFalse(result.warnings.joined().contains("fixture-password"))
    }

    private func chromeDatabase(_ url: URL, encrypted: String, metaVersion: Int) throws -> OpaquePointer {
        try database(url, sql: """
        CREATE TABLE meta(key TEXT, value TEXT);
        INSERT INTO meta VALUES('version','\(metaVersion)');
        CREATE TABLE cookies(name TEXT, value TEXT, host_key TEXT, path TEXT, expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, encrypted_value BLOB);
        INSERT INTO cookies VALUES('auth_token','','.x.com','/',0,1,1,X'\(encrypted)');
        INSERT INTO cookies VALUES('ct0','session','.x.com','/',0,1,0,X'');
        """)
    }
    #endif

    private func keyringError(_ result: Result<String, NSError>) -> String {
        switch result {
        case .success: XCTFail("Expected a keyring failure"); return ""
        case .failure(let error): return error.localizedDescription
        }
    }

    private func hex(_ value: Data) -> String {
        value.map { String(format: "%02x", $0) }.joined()
    }

    private func unhex(_ value: String) -> Data {
        let bytes = Array(value.utf8)
        return Data(stride(from: 0, to: bytes.count, by: 2).map { offset in
            UInt8(String(decoding: bytes[offset..<offset + 2], as: UTF8.self), radix: 16)!
        })
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
