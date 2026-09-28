import Foundation

// JSON objects are normally unordered. Bird's last-resort article extraction walks
// unknown text fields in wire order, so retain that order without adding wire keys.
struct OrderedJSONObject {
    let fields: [String: Any]
    let keys: [String]
}

extension JSON {
    static func foundationValue(_ value: Any) -> Any {
        if let object = value as? OrderedJSONObject { return object.fields.mapValues(foundationValue) }
        if let object = value as? [String: Any] { return object.mapValues(foundationValue) }
        if let array = value as? [Any] { return array.map(foundationValue) }
        return value
    }
}

// Foundation validates and decodes the document. This second, bounded pass only
// records object-key order; scalars retain Foundation's decoded types and values.
struct JSONFieldOrder {
    private let bytes: [UInt8]
    private var index = 0
    private(set) var valid = true

    init(data: Data) { bytes = Array(data) }

    mutating func restore(in value: Any, depth: Int = 0) -> Any {
        skipWhitespace()
        guard depth < 512, index < bytes.count else { return invalidate(value) }
        if bytes[index] == 123 {
            guard let original = value as? [String: Any] else { return invalidate(value) }
            index += 1
            var fields: [String: Any] = [:]
            var keys: [String] = []
            skipWhitespace()
            while index < bytes.count, bytes[index] != 125 {
                let start = index
                guard scanString() else { return invalidate(value) }
                let fragment = Data(bytes[start..<index])
                guard let key = (try? JSONSerialization.jsonObject(with: fragment, options: [.fragmentsAllowed])) as? String else { return invalidate(value) }
                // Foundation may resolve duplicate keys differently from the wire
                // traversal. Keep its original result instead of pairing unrelated values.
                guard fields[key] == nil, let originalValue = original[key] else { return invalidate(value) }
                skipWhitespace()
                guard index < bytes.count, bytes[index] == 58 else { return invalidate(value) }
                index += 1
                let nested = restore(in: originalValue, depth: depth + 1)
                guard valid else { return value }
                keys.append(key)
                fields[key] = nested
                skipWhitespace()
                if index < bytes.count, bytes[index] == 44 { index += 1; skipWhitespace() }
                else { break }
            }
            guard index < bytes.count, bytes[index] == 125 else { return invalidate(value) }
            index += 1
            // JavaScript enumerates canonical array-index keys before other keys.
            let integerKeys = keys.compactMap { key -> (String, UInt32)? in
                guard let number = UInt32(key), number < UInt32.max, String(number) == key else { return nil }
                return (key, number)
            }.sorted { $0.1 < $1.1 }.map(\.0)
            let integerSet = Set(integerKeys)
            return OrderedJSONObject(fields: fields, keys: integerKeys + keys.filter { !integerSet.contains($0) })
        }
        if bytes[index] == 91 {
            guard let original = value as? [Any] else { return invalidate(value) }
            index += 1
            var values: [Any] = []
            skipWhitespace()
            for element in original {
                values.append(restore(in: element, depth: depth + 1))
                skipWhitespace()
                if index < bytes.count, bytes[index] == 44 { index += 1 }
            }
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 93 else { return invalidate(value) }
            index += 1
            return values
        }
        if bytes[index] == 34 { if !scanString() { valid = false }; return value }
        while index < bytes.count, ![UInt8(44), 93, 125, 32, 9, 10, 13].contains(bytes[index]) { index += 1 }
        return value
    }

    private mutating func invalidate(_ value: Any) -> Any {
        valid = false
        return value
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [UInt8(32), 9, 10, 13].contains(bytes[index]) { index += 1 }
    }

    private mutating func scanString() -> Bool {
        guard index < bytes.count, bytes[index] == 34 else { return false }
        index += 1
        while index < bytes.count {
            let character = bytes[index]
            index += 1
            if character == 34 { return true }
            if character == 92 { index += 1 }
        }
        return false
    }
}
