import Foundation
import CoreFoundation

public enum ClientFeatures {
    static func configRoot(environment env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        return env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(FileManager.default.homeDirectoryForCurrentUser.path)/.config"
    }

    public static func cachePath(environment env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        return nonempty(env["AVIARY_FEATURES_CACHE"]) ?? nonempty(env["AVIARY_FEATURES_PATH"]) ?? "\(configRoot(environment: env))/aviary/features.json"
    }

    static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func read(_ path: String) -> [String: Any] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return [:] }
        return JSON.parse(data) ?? [:]
    }

    static func merge(_ first: [String: Any], _ second: [String: Any]) -> [String: Any] {
        func booleans(_ value: Any?) -> [String: Bool] {
            (JSON.object(value) ?? [:]).reduce(into: [:]) { result, entry in
                if let number = entry.value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { result[entry.key] = number.boolValue }
            }
        }
        var global = booleans(first["global"])
        global.merge(booleans(second["global"])) { _, new in new }
        var sets: [String: [String: Bool]] = [:]
        for source in [first, second] {
            for (name, values) in JSON.object(source["sets"]) ?? [:] {
                sets[name, default: [:]].merge(booleans(values)) { _, new in new }
            }
        }
        return ["global": global, "sets": sets]
    }

    public static func overrides(environment env: [String: String] = ProcessInfo.processInfo.environment) -> [String: Any] {
        let bundled = ClientResources.url(for: "features", extension: "json")
        var result = bundled.map { read($0.path) } ?? [:]
        let legacy = nonempty(env["BIRD_FEATURES_CACHE"]) ?? nonempty(env["BIRD_FEATURES_PATH"]) ?? "\(configRoot(environment: env))/bird/features.json"
        result = merge(result, read(legacy))
        result = merge(result, read(cachePath(environment: env)))
        for variable in ["BIRD_FEATURES_JSON", "AVIARY_FEATURES_JSON"] {
            if let text = env[variable], let json = JSON.parse(Data(text.utf8)) { result = merge(result, json) }
        }
        return result
    }

    static func values(_ name: String) -> [String: Bool] {
        // Resolve the hierarchy against one snapshot, rather than rereading the
        // bundle and both cache files for every inherited feature set.
        let overrides = overrides()
        let global = (overrides["global"] as? [String: Bool]) ?? [:]
        let sets = (overrides["sets"] as? [String: [String: Bool]]) ?? [:]
        func resolve(_ name: String) -> [String: Bool] {
            var result = clientFeatureParents[name].map(resolve) ?? [:]
            result.merge(localClientFeatures[name] ?? [:]) { _, new in new }
            result.merge(global) { _, new in new }
            result.merge(sets[name] ?? [:]) { _, new in new }
            return result
        }
        return resolve(name)
    }

    public static func refresh(environment env: [String: String] = ProcessInfo.processInfo.environment) throws {
        let path = URL(fileURLWithPath: cachePath(environment: env))
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Environment overrides apply to this invocation; do not persist them into the user's configuration.
        var persistentEnvironment = env
        persistentEnvironment.removeValue(forKey: "BIRD_FEATURES_JSON")
        persistentEnvironment.removeValue(forKey: "AVIARY_FEATURES_JSON")
        let data = try JSONSerialization.data(withJSONObject: overrides(environment: persistentEnvironment), options: [.prettyPrinted, .sortedKeys])
        try data.write(to: path, options: .atomic)
    }
}
