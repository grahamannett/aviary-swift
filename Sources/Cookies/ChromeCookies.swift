import Foundation
#if os(macOS)
import Darwin
#endif

enum ChromeCookies {
    static func load(
        origins: [URL],
        names: Set<String>,
        profile: String?,
        timeoutMs: Double?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        roots: [String]? = nil,
        passwordReader: ((String, Double?) -> Result<String, NSError>)? = nil,
        now: Int = Int(Date().timeIntervalSince1970)
    ) -> (cookies: [Cookie], warnings: [String]) {
        #if os(Windows)
        return WindowsChrome.load(origins: origins, names: names, profile: profile)
        #else
        guard let dbPath = resolveCookiesDb(profile: profile, roots: roots) else {
            return ([], ["Chrome cookies database not found."])
        }
        let keychain = keychainFor(dbPath: dbPath)
        let password: String
        var warnings: [String] = []
        if let reader = passwordReader {
            switch reader(dbPath, timeoutMs) {
            case .success(let value): password = value
            case .failure(let error):
                #if os(Linux)
                password = ""
                warnings.append(linuxKeyringWarning(error))
                #else
                return ([], ["Failed to read macOS Keychain (\(keychain.label)): \(error.localizedDescription)"])
                #endif
            }
        } else if let envName = envOverride(for: dbPath), let env = normalizedEnvironmentValue(environment[envName]) {
            password = env
        } else {
            #if os(macOS)
            switch readKeychain(account: keychain.account, service: keychain.service, timeoutMs: timeoutMs ?? 30_000) {
            case .success(let pw):
                password = pw
            case .failure(let err):
                return ([], ["Failed to read macOS Keychain (\(keychain.label)): \(err.localizedDescription)"])
            }
            #elseif os(Linux)
            switch LinuxKeyring.readPassword(timeoutMs: timeoutMs) {
            case .success(let value): password = value
            case .failure(let error):
                password = ""
                warnings.append(linuxKeyringWarning(error))
            }
            #else
            return ([], ["Chrome cookie extraction is not supported on this platform."])
            #endif
        }
        #if os(macOS)
        guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ([], ["macOS Keychain returned an empty \(keychain.label) password."])
        }
        #endif
        #if os(Linux)
        let keys = [
            ChromeCrypto.deriveAes128CbcKey(password: password, iterations: 1),
            ChromeCrypto.deriveAes128CbcKey(password: "peanuts", iterations: 1),
            ChromeCrypto.deriveAes128CbcKey(password: "", iterations: 1),
        ]
        #else
        let keys = [ChromeCrypto.deriveAes128CbcKey(password: password.trimmingCharacters(in: .whitespacesAndNewlines), iterations: 1003)]
        #endif
        do {
            let tmp = try SqliteHelper.snapshot(from: dbPath)
            defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
            let metaRows = (try? SqliteHelper.query(tmp.path, sql: "SELECT value FROM meta WHERE key = 'version'")) ?? []
            let metaVersion = (metaRows.first?["value"] as? String).flatMap(Int.init)
                ?? (metaRows.first?["value"] as? Int64).map(Int.init)
                ?? 0
            let stripHash = metaVersion >= 24
            let hosts = origins.compactMap { $0.host }
            let rows = try SqliteHelper.query(
                tmp.path,
                sql: "SELECT name, value, host_key, path, expires_utc, is_secure, is_httponly, encrypted_value FROM cookies ORDER BY expires_utc DESC"
            )
            var cookies: [Cookie] = []
            for row in rows {
                guard let name = row["name"] as? String, !name.isEmpty else { continue }
                if !names.isEmpty && !names.contains(name) { continue }
                guard let hostKey = row["host_key"] as? String else { continue }
                if !hosts.contains(where: { hostMatchesCookieDomain(host: $0, cookieDomain: hostKey) }) { continue }
                var value = row["value"] as? String
                if value == nil || value?.isEmpty == true {
                    guard let blob = row["encrypted_value"] as? Data else { continue }
                    value = ChromeCrypto.decryptAes128Cbc(encryptedValue: blob, keys: keys, stripHashPrefix: stripHash)
                }
                guard let value else { continue }
                if let exp = chromeExpiry(row["expires_utc"]), exp < now { continue }
                cookies.append(
                    Cookie(
                        name: name,
                        value: value,
                        domain: hostKey.hasPrefix(".") ? String(hostKey.dropFirst()) : hostKey,
                        path: (row["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "/",
                        expires: chromeExpiry(row["expires_utc"]),
                        secure: intFlag(row["is_secure"]),
                        httpOnly: intFlag(row["is_httponly"])
                    )
                )
            }
            return (deduplicateCookies(cookies), warnings)
        } catch {
            return ([], warnings + ["Failed to read Chrome cookies: \(error.localizedDescription)"])
        }
        #endif
    }

    private static func chromeExpiry(_ value: Any?) -> Int? {
        let raw: Int64?
        if let i = value as? Int64 { raw = i }
        else if let i = value as? Int { raw = Int64(i) }
        else { raw = nil }
        guard let webkit = raw, webkit > 0 else { return nil }
        return Int((Double(webkit) / 1_000_000.0) - 11_644_473_600.0)
    }

    private static func intFlag(_ value: Any?) -> Bool {
        if let i = value as? Int64 { return i == 1 }
        if let i = value as? Int { return i == 1 }
        if let s = value as? String { return s == "1" }
        return false
    }

    static func chromeRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #if os(macOS)
        return [
            "\(home)/Library/Application Support/Google/Chrome",
        ]
        #elseif os(Linux)
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? "\(home)/.config"
        return ["\(xdg)/google-chrome"]
        #elseif os(Windows)
        let local = ProcessInfo.processInfo.environment["LOCALAPPDATA"] ?? ""
        return ["\(local)\\Google\\Chrome\\User Data"]
        #else
        return []
        #endif
    }

    static func resolveCookiesDb(profile: String?, roots: [String]? = nil) -> String? {
        if let profile, profile.contains("/") || profile.contains("\\") {
            let expanded = (profile as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) {
                if !isDir.boolValue { return expanded }
                for extra in ["Cookies", "Network/Cookies"] {
                    let p = (expanded as NSString).appendingPathComponent(extra)
                    if FileManager.default.fileExists(atPath: p) { return p }
                }
            }
            return nil
        }
        let profileDir = normalizedEnvironmentValue(profile) ?? "Default"
        for root in roots ?? chromeRoots() {
            for extra in ["Cookies", "Network/Cookies"] {
                let p = "\(root)/\(profileDir)/\(extra)"
                if FileManager.default.fileExists(atPath: p) { return p }
            }
        }
        return nil
    }

    private static func keychainFor(dbPath: String) -> (account: String, service: String, label: String) {
        let lower = dbPath.lowercased()
        if lower.contains("bravesoftware") {
            return ("Brave", "Brave Safe Storage", "Brave Safe Storage")
        }
        return ("Chrome", "Chrome Safe Storage", "Chrome Safe Storage")
    }

    private static func envOverride(for dbPath: String) -> String? {
        let lower = dbPath.lowercased()
        if lower.contains("bravesoftware") { return "SWEET_COOKIE_BRAVE_SAFE_STORAGE_PASSWORD" }
        return "SWEET_COOKIE_CHROME_SAFE_STORAGE_PASSWORD"
    }

    #if os(macOS)
    // Executable/arguments are an internal fixture seam; production always uses security.
    static func readKeychain(
        account: String,
        service: String,
        timeoutMs: Double,
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/security"),
        arguments: [String]? = nil
    ) -> Result<String, NSError> {
        guard !Task.isCancelled else { return keychainFailure("macOS Keychain helper was cancelled.", code: NSURLErrorCancelled) }
        let timeout = timeoutMs.isFinite && timeoutMs > 0 ? timeoutMs : 30_000
        let proc = Process()
        proc.executableURL = executableURL
        proc.arguments = arguments ?? ["find-generic-password", "-w", "-a", account, "-s", service]
        let output = Pipe()
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = output
        // Helper output may contain credentials; never include it in diagnostics.
        proc.standardError = FileHandle.nullDevice
        defer {
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        do {
            try proc.run()
        } catch {
            return keychainFailure("macOS Keychain helper could not be started.", code: 1)
        }

        func stopAndReap() {
            if proc.isRunning { proc.terminate() }
            let graceDeadline = ProcessInfo.processInfo.systemUptime + 0.25
            while proc.isRunning, ProcessInfo.processInfo.systemUptime < graceDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            // Signal only this still-owned child, never a discovered PID/process group.
            if proc.isRunning { Darwin.kill(proc.processIdentifier, SIGKILL) }
            proc.waitUntilExit()
        }

        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            stopAndReap()
            return keychainFailure("macOS Keychain helper output could not be read.", code: 2)
        }
        var bytes = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout / 1000
        while proc.isRunning {
            if Task.isCancelled {
                stopAndReap()
                return keychainFailure("macOS Keychain helper was cancelled.", code: NSURLErrorCancelled)
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                stopAndReap()
                return keychainFailure("macOS Keychain helper timed out.", code: NSURLErrorTimedOut)
            }
            guard drainKeychainOutput(descriptor, into: &bytes) else {
                stopAndReap()
                return keychainFailure("macOS Keychain helper output could not be read.", code: 2)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        proc.waitUntilExit()
        if Task.isCancelled {
            return keychainFailure("macOS Keychain helper was cancelled.", code: NSURLErrorCancelled)
        }
        // Nonblocking reads do not wait for pipe EOF from a helper's descendants.
        guard drainKeychainOutput(descriptor, into: &bytes) else {
            return keychainFailure("macOS Keychain helper output could not be read.", code: 2)
        }
        guard proc.terminationStatus == 0 else {
            return keychainFailure("macOS Keychain helper exited with status \(proc.terminationStatus).", code: Int(proc.terminationStatus))
        }
        guard bytes.count < 65_536,
              let password = normalizedEnvironmentValue(String(data: bytes, encoding: .utf8)) else {
            return keychainFailure("macOS Keychain helper returned an invalid or empty password.", code: 3)
        }
        return .success(password)
    }

    private static func drainKeychainOutput(_ descriptor: Int32, into bytes: inout Data) -> Bool {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 4096) { buffer in
            // Bound each drain so continuous output cannot bypass timeout/cancellation.
            for _ in 0..<16 {
                let count = Darwin.read(descriptor, buffer.baseAddress, buffer.count)
                if count > 0 {
                    if bytes.count < 65_536 {
                        bytes.append(buffer.baseAddress!, count: min(count, 65_536 - bytes.count))
                    }
                } else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
                    return true
                } else if errno != EINTR {
                    return false
                }
            }
            return true
        }
    }

    private static func keychainFailure(_ message: String, code: Int) -> Result<String, NSError> {
        .failure(NSError(domain: "keychain", code: code, userInfo: [NSLocalizedDescriptionKey: message]))
    }
    #endif

    #if os(Linux)
    private static func linuxKeyringWarning(_ error: NSError) -> String {
        "Failed to read Linux Chrome keyring: \(error.localizedDescription) Trying Chrome basic-storage cookie keys; unlock the keyring, install libsecret-tools, provide SWEET_COOKIE_CHROME_SAFE_STORAGE_PASSWORD, or use Firefox/explicit credentials."
    }
    #endif
}

enum WindowsChrome {
    static func load(origins: [URL], names: Set<String>, profile: String?) -> (cookies: [Cookie], warnings: [String]) {
        #if os(Windows)
        return ([], ["Windows cookie extraction requires a Windows Swift toolchain"])
        #else
        _ = origins; _ = names; _ = profile
        return ([], [])
        #endif
    }
}
