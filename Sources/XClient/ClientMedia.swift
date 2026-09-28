import Foundation

extension TwitterClient {
    public func uploadMedia(data: Data, mimeType: String, alt: String? = nil) async -> UploadMediaResult {
        let category: String
        if mimeType == "image/gif" { category = "tweet_gif" }
        else if mimeType.hasPrefix("image/") { category = "tweet_image" }
        else if mimeType.hasPrefix("video/") { category = "tweet_video" }
        else { return UploadMediaResult(success: false, mediaId: nil, error: "Unsupported media type: \(mimeType)") }
        let uploadURL = URL(string: "https://upload.twitter.com/i/media/upload.json")!
        do {
            let initResult = try await request(uploadURL, method: "POST", body: formData([
                "command": "INIT", "total_bytes": String(data.count), "media_type": mimeType, "media_category": category,
            ]), extra: ["content-type": "application/x-www-form-urlencoded"])
            let initial = try uploadJSON(initResult)
            guard let mediaId = stringID(initial["media_id_string"]) ?? stringID(initial["media_id"]) else { throw ClientError("Media upload INIT did not return media_id") }
            let chunkSize = 5 * 1024 * 1024
            var segment = 0
            for start in stride(from: data.startIndex, to: data.endIndex, by: chunkSize) {
                let boundary = "Aviary-\(UUID().uuidString)"
                var body = Data()
                let values = ["command": "APPEND", "media_id": mediaId, "segment_index": String(segment)]
                for name in values.keys.sorted() {
                    body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(values[name]!)\r\n".utf8))
                }
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"media\"; filename=\"media\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
                let end = start + min(chunkSize, data.endIndex - start)
                body.append(data[start..<end])
                body.append(Data("\r\n--\(boundary)--\r\n".utf8))
                let result = try await request(uploadURL, method: "POST", body: body, extra: ["content-type": "multipart/form-data; boundary=\(boundary)"])
                try validateUpload(result)
                segment += 1
            }
            let result = try await request(uploadURL, method: "POST", body: formData(["command": "FINALIZE", "media_id": mediaId]),
                                            extra: ["content-type": "application/x-www-form-urlencoded"])
            var processing = try uploadJSON(result)["processing_info"]
            var attempts = 0
            while let value = processing {
                guard let info = JSON.object(value), let state = JSON.string(info["state"]) else {
                    throw ClientError("Invalid media processing state")
                }
                if state == "succeeded" { break }
                if state == "failed" {
                    throw ClientError(JSON.string(JSON.path(info, "error", "message")) ?? JSON.string(JSON.path(info, "error", "name")) ?? "Media processing failed")
                }
                guard state == "pending" || state == "in_progress" else { throw ClientError("Unknown media processing state: \(state)") }
                guard attempts < 20 else { throw ClientError("Media processing did not complete after 20 checks") }
                let seconds = max(1, JSON.int(info["check_after_secs"]) ?? 2)
                guard seconds <= Int.max / 1000 else { throw ClientError("Media processing delay is too large") }
                try await sleepMilliseconds(seconds * 1000)
                var statusURL = URLComponents(url: uploadURL, resolvingAgainstBaseURL: false)!
                statusURL.queryItems = [URLQueryItem(name: "command", value: "STATUS"), URLQueryItem(name: "media_id", value: mediaId)]
                let status = try await request(statusURL.url!)
                guard let next = try uploadJSON(status)["processing_info"] else { throw ClientError("Missing media processing state") }
                processing = next
                attempts += 1
            }
            if let alt, !alt.isEmpty, mimeType.hasPrefix("image/") {
                let metadata = try await request(URL(string: "https://x.com/i/api/1.1/media/metadata/create.json")!, method: "POST",
                    body: try JSONSerialization.data(withJSONObject: ["media_id": mediaId, "alt_text": ["text": alt]]), extra: ["content-type": "application/json"])
                try validateUpload(metadata)
            }
            return UploadMediaResult(success: true, mediaId: mediaId, error: nil)
        } catch { return UploadMediaResult(success: false, mediaId: nil, error: error.localizedDescription) }
    }

    func validateUpload(_ result: (Data, HTTPURLResponse)) throws {
        guard (200..<300).contains(result.1.statusCode) else {
            throw ClientError("HTTP \(result.1.statusCode): \(String(data: result.0, encoding: .utf8).map { String($0.prefix(200)) } ?? "")")
        }
        if let error = apiErrors(JSON.parse(result.0)) { throw ClientError(error) }
    }

    func uploadJSON(_ result: (Data, HTTPURLResponse)) throws -> [String: Any] {
        try validateUpload(result)
        guard let json = JSON.parse(result.0) else { throw ClientError("Invalid media upload JSON response") }
        return json
    }
}
