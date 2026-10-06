import Foundation
import XCTest
@testable import XClient

final class ClientResourcesTests: XCTestCase {
    func testBuildTreeResourcesAreAvailable() throws {
        let queries = try XCTUnwrap(ClientResources.url(for: "query-ids", extension: "json"))
        let ids = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: queries)) as? [String: String])
        XCTAssertEqual(bakedQueryIds()["CreateTweet"], ids["CreateTweet"])
        XCTAssertNotEqual(bakedQueryIds()["CreateTweet"], fallbackQueryIds["CreateTweet"])
        XCTAssertNotNil(ClientResources.url(for: "features", extension: "json"))
    }

    func testResourcesResolveBesideSymlinkTargetForBothBundleLayouts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("installation/bin")
        let links = root.appendingPathComponent("shims")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("aviary")
        try Data().write(to: executable)
        let link = links.appendingPathComponent("bird")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        XCTAssertNil(ClientResources.url(for: "query-ids", extension: "json", executableURL: link))

        for name in ["Aviary_XClient.bundle", "Aviary_XClient.resources"] {
            let bundle = bin.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            let queryFile = bundle.appendingPathComponent("query-ids.json")
            try Data(#"{"CreateTweet":"installed-id"}"#.utf8).write(to: queryFile)
            XCTAssertEqual(ClientResources.url(for: "query-ids", extension: "json", executableURL: link), queryFile)
            try FileManager.default.removeItem(at: bundle)
        }
    }

    func testMacOSXCTestLayoutFindsSiblingResources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Aviary_XClient.bundle/Resources")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let queryFile = bundle.appendingPathComponent("query-ids.json")
        try Data("{}".utf8).write(to: queryFile)
        let testExecutable = root.appendingPathComponent("AviaryPackageTests.xctest/Contents/MacOS/AviaryPackageTests")
        XCTAssertEqual(ClientResources.url(for: "query-ids", extension: "json", executableURL: testExecutable), queryFile)
    }

    func testPackagedPrivateSelfTestFindsResourcesInBin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("bin/Aviary_XClient.resources")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let featureFile = bundle.appendingPathComponent("features.json")
        try Data("{}".utf8).write(to: featureFile)
        let helper = root.appendingPathComponent("libexec/aviary-selftest")
        XCTAssertEqual(ClientResources.url(for: "features", extension: "json", executableURL: helper), featureFile)
    }
}
