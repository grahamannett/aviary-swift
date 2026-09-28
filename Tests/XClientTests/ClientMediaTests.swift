import XCTest
import Foundation
@testable import XClient

final class ClientMediaTests: XCTestCase {
    func testChunkedImageUploadAndAltText() async throws {
        let session = ClientMockSession { request, _ in
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            if request.url!.path.hasSuffix("metadata/create.json") { return (200, "{}") }
            if body.contains("command=INIT") { return (200, #"{"media_id_string":"media123"}"#) }
            if body.contains("command=FINALIZE") { return (200, "{}") }
            return (204, "")
        }
        let client = ClientParityTests.makeClient(session)
        let data = Data(repeating: 65, count: 5 * 1024 * 1024 + 1)
        let result = await client.uploadMedia(data: data, mimeType: "image/jpeg", alt: "Accessible image description")
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.mediaId, "media123")
        let requests = await session.recorded()
        XCTAssertEqual(requests.count, 5)
        XCTAssertTrue(requests[1].value(forHTTPHeaderField: "content-type")?.hasPrefix("multipart/form-data; boundary=") == true)
        XCTAssertTrue(String(data: requests[2].httpBody!, encoding: .utf8)!.contains("name=\"segment_index\"\r\n\r\n1"))
        let metadata = try XCTUnwrap(JSON.parse(try XCTUnwrap(requests.last?.httpBody)))
        XCTAssertEqual(JSON.string(JSON.path(metadata, "alt_text", "text")), "Accessible image description")
    }

    func testUploadUsesEntireDataSliceAcrossChunkBoundary() async throws {
        let session = ClientMockSession { request, _ in
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            if body.contains("command=INIT") { return (200, #"{"media_id_string":"slice"}"#) }
            if body.contains("command=FINALIZE") { return (200, "{}") }
            return (204, "")
        }
        let chunkSize = 5 * 1024 * 1024
        var backing = Data([0, 1, 2])
        backing.append(Data(repeating: 65, count: chunkSize))
        backing.append(66)
        let slice = backing.dropFirst(3)
        let result = await ClientParityTests.makeClient(session).uploadMedia(data: slice, mimeType: "image/jpeg")
        XCTAssertTrue(result.success)
        let requests = await session.recorded()
        let chunks = try requests.filter {
            $0.value(forHTTPHeaderField: "content-type")?.hasPrefix("multipart/form-data;") == true
        }.map { request -> Data in
            let body = try XCTUnwrap(request.httpBody)
            let header = Data("Content-Type: image/jpeg\r\n\r\n".utf8)
            let start = try XCTUnwrap(body.range(of: header)).upperBound
            let end = try XCTUnwrap(body.range(of: Data("\r\n--".utf8), options: .backwards)).lowerBound
            return body[start..<end]
        }
        XCTAssertEqual(chunks.map(\.count), [chunkSize, 1])
        XCTAssertEqual(chunks.reduce(into: Data()) { $0.append($1) }, slice)
    }

    func testVideoProcessingFailureIsNotSuccessfulUpload() async {
        let session = ClientMockSession { request, _ in
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            if body.contains("command=INIT") { return (200, #"{"media_id_string":"video1"}"#) }
            if body.contains("command=FINALIZE") { return (200, #"{"processing_info":{"state":"pending","check_after_secs":1}}"#) }
            if request.httpMethod == "GET" { return (200, #"{"processing_info":{"state":"failed","error":{"message":"Invalid video"}}}"#) }
            return (204, "")
        }
        let result = await ClientParityTests.makeClient(session).uploadMedia(data: Data([1, 2, 3]), mimeType: "video/mp4")
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, "Invalid video")
        let requests = await session.recorded()
        XCTAssertEqual(requests.count, 4)
    }

    func testVideoProcessingPollsUntilSuccessAndStopsAtLimit() async {
        for succeeds in [false, true] {
            let session = ClientMockSession { request, index in
                let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                if body.contains("command=INIT") { return (200, #"{"media_id_string":"video1"}"#) }
                if body.contains("command=FINALIZE") { return (200, #"{"processing_info":{"state":"pending","check_after_secs":1}}"#) }
                if request.httpMethod == "GET" {
                    if succeeds, index >= 5 { return (200, #"{"processing_info":{"state":"succeeded"}}"#) }
                    return (200, #"{"processing_info":{"state":"in_progress","check_after_secs":1}}"#)
                }
                return (204, "")
            }
            let result = await ClientParityTests.makeClient(session).uploadMedia(data: Data([1]), mimeType: "video/mp4")
            XCTAssertEqual(result.success, succeeds)
            let requests = await session.recorded()
            XCTAssertEqual(requests.count, succeeds ? 5 : 23)
        }
    }

    func testProcessingRequiresExplicitSuccessAfterPending() async {
        for status in ["{}", #"{"processing_info":{}}"#, #"{"processing_info":{"state":"unknown"}}"#] {
            let session = ClientMockSession { request, _ in
                let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                if body.contains("command=INIT") { return (200, #"{"media_id_string":"video1"}"#) }
                if body.contains("command=FINALIZE") { return (200, #"{"processing_info":{"state":"pending","check_after_secs":1}}"#) }
                if request.httpMethod == "GET" { return (200, status) }
                return (204, "")
            }
            let result = await ClientParityTests.makeClient(session).uploadMedia(data: Data([1]), mimeType: "video/mp4")
            XCTAssertFalse(result.success)
            XCTAssertNil(result.mediaId)
            XCTAssertNotNil(result.error)
            let requests = await session.recorded()
            XCTAssertEqual(requests.count, 4)
        }
    }

    func testFinalizeRejectsMalformedProcessingAndOverflowingDelay() async {
        let invalidProcessing = [
            #"{"processing_info":{}}"#,
            #"{"processing_info":"pending"}"#,
            #"{"processing_info":{"state":"unknown"}}"#,
            #"{"processing_info":{"state":"pending","check_after_secs":\#(Int.max)}}"#,
        ]
        for finalize in invalidProcessing {
            let session = ClientMockSession { request, _ in
                let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                if body.contains("command=INIT") { return (200, #"{"media_id_string":"video1"}"#) }
                if body.contains("command=FINALIZE") { return (200, finalize) }
                return (204, "")
            }
            let result = await ClientParityTests.makeClient(session).uploadMedia(data: Data([1]), mimeType: "video/mp4")
            XCTAssertFalse(result.success)
            XCTAssertNil(result.mediaId)
            XCTAssertNotNil(result.error)
            let requests = await session.recorded()
            XCTAssertEqual(requests.count, 3)
        }
    }

    func testUnsupportedMediaMakesNoRequests() async {
        let session = ClientMockSession { _, _ in XCTFail("Unsupported media must not be uploaded"); return (500, "") }
        let result = await ClientParityTests.makeClient(session).uploadMedia(data: Data([1]), mimeType: "application/pdf")
        XCTAssertFalse(result.success)
        let requests = await session.recorded()
        XCTAssertTrue(requests.isEmpty)
    }
}
