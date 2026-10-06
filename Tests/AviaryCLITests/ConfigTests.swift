import Foundation
import Cookies
import XCTest
@testable import AviaryCLI

final class ConfigTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("aviary-config-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private func load(global: String? = nil, local: String? = nil, warn: (String) -> Void = { _ in }) throws -> BirdConfig {
        let home = directory.appendingPathComponent("home")
        let working = directory.appendingPathComponent("working")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/bird"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        if let global { try global.write(to: home.appendingPathComponent(".config/bird/config.json5"), atomically: true, encoding: .utf8) }
        if let local { try local.write(to: working.appendingPathComponent(".birdrc.json5"), atomically: true, encoding: .utf8) }
        return BirdConfig.load(homeDirectory: home, workingDirectory: working, warn: warn)
    }

    func testJSON5SyntaxDoesNotRewriteStrings() throws {
        let parsed = try JSON5.parseObject(#"""
        {
          // A real comment
          chromeProfile: 'Profile 1',
          /* Another comment */
          chromeProfileDir: "/tmp/*literal*/path,}",
          firefoxProfile: "a\"//quoted",
          cookieSource: ['firefox',],
          timeoutMs: 0x10,
        }
        """#)
        XCTAssertEqual(parsed["chromeProfile"], .string("Profile 1"))
        XCTAssertEqual(parsed["chromeProfileDir"], .string("/tmp/*literal*/path,}"))
        XCTAssertEqual(parsed["firefoxProfile"], .string("a\"//quoted"))
        XCTAssertEqual(parsed["cookieSource"], .array([.string("firefox")]))
        XCTAssertEqual(parsed["timeoutMs"], .number(16))
        XCTAssertEqual(try JSON5.parseObject("null"), [:])
    }

    func testLocalNullOverridesGlobalAndNumbersFallThrough() throws {
        let config = try load(
            global: #"{chromeProfileDir:'/global/profile', cookieSource:'chrome', timeoutMs:900, cookieTimeoutMs:1000, quoteDepth:2}"#,
            local: #"{chromeProfileDir:null, chromeProfile:'Profile 1', cookieSource:null, timeoutMs:-1, cookieTimeoutMs:'22.5', quoteDepth:-1}"#
        )
        XCTAssertNil(config.chromeProfileDir)
        XCTAssertEqual(config.chromeProfile, "Profile 1")
        XCTAssertEqual(try config.resolveCookieSources(cli: []), BrowserName.defaultCookieSources)
        XCTAssertEqual(config.resolveTimeout(cli: "0", env: "300.5"), 300.5)
        XCTAssertEqual(config.resolveCookieTimeout(cli: "invalid", env: "400"), 22.5)
        XCTAssertEqual(config.resolveQuoteDepth(cli: "-5", env: "3"), 3)
        XCTAssertEqual(config.resolveQuoteDepth(cli: "0", env: "3"), 0)
    }

    func testNumericStringsAndQuoteDepthParsing() throws {
        let config = try load(global: #"{timeoutMs:'1.25', quoteDepth:2.9}"#)
        XCTAssertEqual(config.resolveTimeout(cli: nil, env: "9"), 1.25)
        XCTAssertEqual(config.resolveTimeout(cli: " 0x10 ", env: "9"), 16)
        XCTAssertEqual(config.resolveTimeout(cli: "0b10000", env: "9"), 16)
        XCTAssertEqual(config.resolveTimeout(cli: "0o20", env: "9"), 16)
        XCTAssertEqual(config.resolveTimeout(cli: "Infinity", env: "9"), 1.25)
        XCTAssertEqual(config.resolveCookieTimeout(cli: "-4", env: "1e3"), 1000)
        XCTAssertEqual(config.resolveQuoteDepth(cli: nil, env: "9"), 2)
        XCTAssertEqual(config.resolveQuoteDepth(cli: "3.8garbage", env: "9"), 3)
        XCTAssertEqual(config.resolveQuoteDepth(cli: "+4tweets", env: "9"), 4)
        XCTAssertEqual(config.resolveQuoteDepth(cli: "--4", env: "9"), 2)
    }

    func testCookieSourceNormalizationAndValidation() throws {
        let config = try load(global: #"{cookieSource:[' FIREFOX ', 7, 'Chrome']}"#)
        XCTAssertEqual(try config.resolveCookieSources(cli: []), [.firefox, .chrome])
        XCTAssertEqual(try config.resolveCookieSources(cli: [" SAFARI "]), [.safari])
        XCTAssertThrowsError(try config.resolveCookieSources(cli: ["firefoxx"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("Invalid --cookie-source"))
        }
        let invalid = try load(local: #"{cookieSource:'firefoxx'}"#)
        XCTAssertThrowsError(try invalid.resolveCookieSources(cli: []))
    }

    func testInvalidLocalConfigWarnsAndKeepsGlobal() throws {
        var warnings: [String] = []
        let config = try load(global: #"{chromeProfile:'Default'}"#, local: "{ invalid", warn: { warnings.append($0) })
        XCTAssertEqual(config.chromeProfile, "Default")
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains(".birdrc.json5"))
        XCTAssertTrue(warnings[0].contains("Failed to parse config"))
    }

    func testMissingConfigUsesDefaultsWithoutWarnings() throws {
        var warnings: [String] = []
        let config = try load(warn: { warnings.append($0) })
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertEqual(try config.resolveCookieSources(cli: []), BrowserName.defaultCookieSources)
        XCTAssertNil(config.resolveTimeout(cli: nil, env: nil))
        XCTAssertNil(config.resolveCookieTimeout(cli: nil, env: nil))
        XCTAssertNil(config.resolveQuoteDepth(cli: nil, env: nil))
    }

    func testNonFiniteJSON5ValuesDoNotDiscardOtherSettings() throws {
        var warnings: [String] = []
        let config = try load(
            global: #"{chromeProfile:'Default', timeoutMs:Infinity, cookieTimeoutMs:NaN, quoteDepth:-Infinity}"#,
            warn: { warnings.append($0) }
        )
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertEqual(config.chromeProfile, "Default")
        XCTAssertEqual(config.resolveTimeout(cli: nil, env: "2000"), 2000)
        XCTAssertEqual(config.resolveCookieTimeout(cli: nil, env: "3000"), 3000)
        XCTAssertEqual(config.resolveQuoteDepth(cli: nil, env: "2"), 2)
    }

    func testJSON5DecimalFormsAndEscapedIdentifier() throws {
        let parsed = try JSON5.parseObject(#"{\u0063hromeProfile /* comment */ :'Default', timeoutMs:.5, cookieTimeoutMs:2., quoteDepth:+3, 'literal\\u0063':'\\u0063', nested:{foo\u0062ar:1}}"#)
        XCTAssertEqual(parsed["chromeProfile"], .string("Default"))
        XCTAssertEqual(parsed["timeoutMs"], .number(0.5))
        XCTAssertEqual(parsed["cookieTimeoutMs"], .number(2))
        XCTAssertEqual(parsed["quoteDepth"], .number(3))
        XCTAssertEqual(parsed[#"literal\u0063"#], .string(#"\u0063"#))
        XCTAssertEqual(parsed["nested"], .object(["foobar": .number(1)]))
    }
}
