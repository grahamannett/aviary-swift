import Foundation

enum JSON5 {
    enum Value: Decodable, Equatable {
        case null, bool(Bool), number(Double), string(String), array([Value]), object([String: Value])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode(Double.self) { self = .number(value) }
            else if let value = try? container.decode(String.self) { self = .string(value) }
            else if let value = try? container.decode([Value].self) { self = .array(value) }
            else { self = .object(try container.decode([String: Value].self)) }
        }

        var string: String? {
            guard case .string(let value) = self else { return nil }
            return value
        }
    }

    static func parseObject(_ raw: String) throws -> [String: Value] {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let value = try decoder.decode(Value.self, from: normalizeEscapedKeys(raw))
        guard case .object(let object) = value else { return [:] }
        return object
    }

    // Foundation leaves Unicode escapes in unquoted keys undecoded. Quote only
    // those tokens so its normal string decoder handles them; strings and
    // comments must pass through unchanged.
    private static func normalizeEscapedKeys(_ raw: String) -> Data {
        let bytes = Array(raw.utf8)
        var result: [UInt8] = []
        var index = 0
        func isSpace(_ byte: UInt8) -> Bool { byte == 32 || (9...13).contains(byte) }
        func triviaEnd(_ start: Int) -> Int {
            var cursor = start
            while cursor < bytes.count {
                if isSpace(bytes[cursor]) { cursor += 1; continue }
                guard cursor + 1 < bytes.count, bytes[cursor] == 47 else { break }
                if bytes[cursor + 1] == 47 {
                    cursor += 2
                    while cursor < bytes.count, bytes[cursor] != 10, bytes[cursor] != 13 { cursor += 1 }
                } else if bytes[cursor + 1] == 42 {
                    cursor += 2
                    while cursor + 1 < bytes.count, !(bytes[cursor] == 42 && bytes[cursor + 1] == 47) { cursor += 1 }
                    cursor = min(cursor + 2, bytes.count)
                } else { break }
            }
            return cursor
        }
        while index < bytes.count {
            let start = index
            let trivia = triviaEnd(index)
            if trivia != index {
                result.append(contentsOf: bytes[index..<trivia])
                index = trivia
                continue
            }
            if bytes[index] == 34 || bytes[index] == 39 {
                let quote = bytes[index]
                index += 1
                while index < bytes.count {
                    let byte = bytes[index]
                    index += 1
                    if byte == 92 { index = min(index + 1, bytes.count) }
                    else if byte == quote { break }
                }
            } else if [UInt8(123), 125, 91, 93, 58, 44].contains(bytes[index]) {
                index += 1
            } else {
                while index < bytes.count, !isSpace(bytes[index]),
                      ![UInt8(123), 125, 91, 93, 58, 44, 47, 34, 39].contains(bytes[index]) { index += 1 }
                // Invalid punctuation is left for Foundation to reject.
                if index == start { index += 1 }
                let next = triviaEnd(index)
                if bytes[start..<index].contains(92), next < bytes.count, bytes[next] == 58 {
                    result.append(34)
                    result.append(contentsOf: bytes[start..<index])
                    result.append(34)
                    continue
                }
            }
            result.append(contentsOf: bytes[start..<index])
        }
        return Data(result)
    }
}
