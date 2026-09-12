import Cookies
import Foundation

struct BirdConfig {
    var chromeProfile: String?
    var chromeProfileDir: String?
    var firefoxProfile: String?
    var cookieSource: [BrowserName] = []
    var cookieTimeoutMs: Int?
    var timeoutMs: Int?
    var quoteDepth: Int?

    static func load() -> BirdConfig {
        var cfg = BirdConfig()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [
            "\(home)/.config/bird/config.json5",
            "\(FileManager.default.currentDirectoryPath)/.birdrc.json5",
        ]
        for path in paths {
            guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let obj = JSON5.parseObject(raw)
            if let v = obj["chromeProfile"] as? String { cfg.chromeProfile = v }
            if let v = obj["chromeProfileDir"] as? String { cfg.chromeProfileDir = v }
            if let v = obj["firefoxProfile"] as? String { cfg.firefoxProfile = v }
            if let v = obj["cookieTimeoutMs"] as? Int { cfg.cookieTimeoutMs = v }
            if let v = obj["timeoutMs"] as? Int { cfg.timeoutMs = v }
            if let v = obj["quoteDepth"] as? Int { cfg.quoteDepth = v }
            if let v = obj["cookieSource"] as? String, let b = BrowserName(rawValue: v) {
                cfg.cookieSource = [b]
            }
            if let v = obj["cookieSource"] as? [String] {
                cfg.cookieSource = v.compactMap(BrowserName.init(rawValue:))
            }
        }
        return cfg
    }
}
