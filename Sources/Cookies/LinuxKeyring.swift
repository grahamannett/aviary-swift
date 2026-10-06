import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Compiled on macOS too so subprocess failure and timeout behavior can be tested
// without access to a desktop keyring. Executable/arguments are an internal test seam.
enum LinuxKeyring {
    static func readPassword(
        timeoutMs: Double?,
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/secret-tool"),
        arguments: [String] = ["lookup", "application", "chrome"]
    ) -> Result<String, NSError> {
        let timeout = timeoutMs.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 30_000
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        // Never include subprocess output in diagnostics: it may contain a secret.
        process.standardError = FileHandle.nullDevice
        defer {
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        do {
            try process.run()
        } catch {
            return failure("secret-tool could not be started.", code: 1)
        }

        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            return failure("secret-tool output could not be read.", code: 2)
        }
        var bytes = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout / 1000
        while process.isRunning {
            drain(descriptor, into: &bytes)
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                // A locked keyring can wait indefinitely. SIGKILL also bounds
                // helpers that ignore SIGTERM; no wait for inherited pipe EOF.
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                return failure("secret-tool timed out after \(Int(timeout)) ms.", code: 3)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        drain(descriptor, into: &bytes)
        guard process.terminationStatus == 0 else {
            return failure("secret-tool exited with status \(process.terminationStatus).", code: Int(process.terminationStatus))
        }
        guard bytes.count < 65_536 else {
            return failure("secret-tool returned an unexpectedly large password.", code: 5)
        }
        guard let password = normalizedEnvironmentValue(String(data: bytes, encoding: .utf8)) else {
            return failure("secret-tool returned no password.", code: 4)
        }
        return .success(password)
    }

    private static func drain(_ descriptor: Int32, into bytes: inout Data) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        // Return regularly so a continuously writing helper cannot bypass the
        // process deadline by keeping this read loop busy.
        for _ in 0..<16 {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            guard count > 0 else { return }
            // Safe-storage passwords are small. Keep memory use bounded even if
            // the injected/helper process unexpectedly writes large output.
            if bytes.count < 65_536 {
                bytes.append(contentsOf: buffer.prefix(min(count, 65_536 - bytes.count)))
            }
        }
    }

    private static func failure(_ message: String, code: Int) -> Result<String, NSError> {
        .failure(NSError(domain: "LinuxChromeKeyring", code: code, userInfo: [NSLocalizedDescriptionKey: message]))
    }
}
