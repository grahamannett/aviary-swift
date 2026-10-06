import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import XClient

final class ClientCacheTests: XCTestCase {
    func testFeatureRefreshReadsLegacyOverridesButOnlyWritesAviary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("bird-features.json")
        let aviary = root.appendingPathComponent("aviary-features.json")
        let original = #"{"global":{"test_feature":false},"sets":{"search":{"legacy_override":true}}}"#
        try Data(original.utf8).write(to: legacy)
        let environment = ["BIRD_FEATURES_CACHE": legacy.path, "AVIARY_FEATURES_CACHE": aviary.path,
                           "AVIARY_FEATURES_JSON": #"{"global":{"test_feature":true}}"#]
        XCTAssertEqual(JSON.bool(JSON.path(ClientFeatures.overrides(environment: environment), "global", "test_feature")), true)
        try ClientFeatures.refresh(environment: environment)
        XCTAssertEqual(try String(contentsOf: legacy), original)
        let updated = try XCTUnwrap(JSON.parse(Data(contentsOf: aviary)))
        XCTAssertEqual(JSON.bool(JSON.path(updated, "global", "test_feature")), false)
        XCTAssertEqual(JSON.bool(JSON.path(updated, "sets", "search", "legacy_override")), true)
    }

    func testFeatureDefaultWriteLocationIsIndependentOfBirdOverride() {
        let environment = ["XDG_CONFIG_HOME": "/tmp/config", "BIRD_FEATURES_CACHE": "/tmp/bird/custom.json"]
        XCTAssertEqual(ClientFeatures.cachePath(environment: environment), "/tmp/config/aviary/features.json")
    }

    func testFractionalQueryTimestampIsFresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("queries.json")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let snapshot: [String: Any] = ["fetchedAt": formatter.string(from: Date()), "ttlMs": 86_400_000,
                                      "ids": ["TweetDetail": "test_id"], "discovery": ["pages": [], "bundles": []]]
        try JSONSerialization.data(withJSONObject: snapshot).write(to: file)
        let store = QueryIdStore(cachePath: file.path, legacyCachePath: root.appendingPathComponent("legacy").path, allowRefresh: false)
        let info = await store.snapshotInfo()
        XCTAssertTrue(info?.isFresh == true)
    }

    func testQueryStatusReportsOnlyCachedIDsAndOmitsIDsWhenUncached() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("queries.json")
        let store = QueryIdStore(cachePath: file.path, legacyCachePath: root.appendingPathComponent("legacy").path, allowRefresh: false)
        let uncached = await store.cliStatus()
        guard case .object(let uncachedFields) = uncached.value else { return XCTFail("Expected status object") }
        XCTAssertEqual(Set(uncachedFields.keys), Set(["cached", "cachePath", "featuresPath", "features"]))
        let snapshot: [String: Any] = ["fetchedAt": "2026-09-22T00:00:00Z", "ttlMs": 86_400_000,
                                      "ids": ["TweetDetail": "one_cached_id"], "discovery": ["pages": [], "bundles": []]]
        try JSONSerialization.data(withJSONObject: snapshot).write(to: file)
        let cached = await store.cliStatus()
        guard case .object(let cachedFields) = cached.value, case .object(let ids) = cachedFields["ids"] else {
            return XCTFail("Expected cached ID snapshot")
        }
        XCTAssertEqual(Set(ids.keys), Set(["TweetDetail"]))
        if case .string(let id) = ids["TweetDetail"] { XCTAssertEqual(id, "one_cached_id") }
        else { XCTFail("Expected cached ID value") }
    }

    func testDiscoveryKeepsQueryIDsWithinTheirOperationObjects() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QueryIdStore(cachePath: root.appendingPathComponent("queries.json").path,
                                 legacyCachePath: root.appendingPathComponent("legacy.json").path,
                                 allowRefresh: true)
        let bundle = """
        a.exports={queryId:"read_id",operationKind:"query",operationName:"TweetDetail"};
        b.exports={queryId:"search_id",operationName:"SearchTimeline"};
        c.exports={operationName:"Bookmarks",operationKind:"query",queryId:"bookmark_id"};
        d.exports={operationName:"Likes"};
        f.exports={queryId:"unrelated_id"};
        """
        await store.refresh(force: true, session: DiscoverySession(bundle: bundle))
        let snapshot = await store.loadDisk()
        let ids = try XCTUnwrap(snapshot).ids
        XCTAssertEqual(ids, ["TweetDetail": "read_id", "SearchTimeline": "search_id", "Bookmarks": "bookmark_id"])
    }
}

private struct DiscoverySession: HTTPSession {
    let bundle: String

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        let body = url.host == "abs.twimg.com"
            ? bundle
            : #"<script src="https://abs.twimg.com/responsive-web/client-web/main.js"></script>"#
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (Data(body.utf8), response)
    }
}
