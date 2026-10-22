#if os(macOS)
import Darwin
import Foundation
import XCTest
@testable import Cookies

final class KeychainTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("aviary-keychain-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testTimeoutKillsAndReapsTermIgnoringHelper() throws {
        let pidFile = directory.appendingPathComponent("timeout.pid")
        let start = ProcessInfo.processInfo.systemUptime
        let result = Self.readPassword(arguments: Self.unresponsiveHelper(pidFile), timeoutMs: 1000)
        XCTAssertEqual(try failure(result).code, NSURLErrorTimedOut)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
        assertReaped(try pid(at: pidFile))
    }

    func testCancellationKillsAndReapsTermIgnoringHelper() async throws {
        let pidFile = directory.appendingPathComponent("cancelled.pid")
        let task = Task.detached {
            Self.readPassword(arguments: Self.unresponsiveHelper(pidFile), timeoutMs: 5000)
        }
        let child: pid_t
        do {
            child = try await waitForPID(at: pidFile)
        } catch {
            task.cancel()
            _ = await task.value
            throw error
        }
        let start = ProcessInfo.processInfo.systemUptime
        task.cancel()
        let result = await task.value
        XCTAssertEqual(try failure(result).code, NSURLErrorCancelled)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        assertReaped(child)
    }

    func testAlreadyCancelledTaskDoesNotLaunchHelper() async throws {
        let marker = directory.appendingPathComponent("must-not-start")
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return Self.readPassword(arguments: ["-c", "printf started > \"$1\"; printf fixture-password", "keychain-fixture", marker.path])
        }
        let result = await task.value
        XCTAssertEqual(try failure(result).code, NSURLErrorCancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testLargeOutputDoesNotDeadlockOrExposeHelperSecrets() throws {
        let secret = "private-keychain-fixture"
        let chunk = String(repeating: secret, count: 20)
        let script = """
        i=0
        while [ "$i" -lt 4096 ]; do
            printf '%s' '\(chunk)'
            printf '%s' '\(chunk)' >&2
            i=$((i + 1))
        done
        exit 44
        """
        let result = Self.readPassword(arguments: ["-c", script], timeoutMs: 5000)
        let error = try failure(result)
        XCTAssertEqual(error.code, 44)
        XCTAssertFalse(error.localizedDescription.contains(secret))
    }

    func testPasswordNormalizationAndInvalidOutput() throws {
        let password = Self.readPassword(arguments: ["-c", "printf '  fixture-password\n '"])
        XCTAssertEqual(try password.get(), "fixture-password")
        for script in ["printf '  '", "printf '\\377\\376'"] {
            _ = try failure(Self.readPassword(arguments: ["-c", script]))
        }
    }

    func testOversizedOutputCannotBecomeAPassword() throws {
        let script = "i=0; while [ \"$i\" -lt 1024 ]; do printf '%s' '\(String(repeating: "x", count: 128))'; i=$((i + 1)); done"
        _ = try failure(Self.readPassword(arguments: ["-c", script]))
    }

    private static func readPassword(arguments: [String], timeoutMs: Double = 2000) -> Result<String, NSError> {
        ChromeCookies.readKeychain(account: "fixture", service: "fixture", timeoutMs: timeoutMs,
                                  executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: arguments)
    }

    private static func unresponsiveHelper(_ pidFile: URL) -> [String] {
        ["-c", "trap '' TERM; printf '%s' \"$$\" > \"$1\"; while :; do :; done", "keychain-fixture", pidFile.path]
    }

    private func pid(at file: URL) throws -> pid_t {
        let text = try String(contentsOf: file, encoding: .utf8)
        return try XCTUnwrap(pid_t(text).flatMap { $0 > 0 ? $0 : nil })
    }

    private func waitForPID(at file: URL) async throws -> pid_t {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            if let child = try? pid(at: file) { return child }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "KeychainFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture helper did not start"])
    }

    private func failure(_ result: Result<String, NSError>, file: StaticString = #filePath, line: UInt = #line) throws -> NSError {
        guard case .failure(let error) = result else {
            XCTFail("Helper unexpectedly returned a password", file: file, line: line)
            throw NSError(domain: "KeychainFixture", code: 2)
        }
        return error
    }

    private func assertReaped(_ child: pid_t, file: StaticString = #filePath, line: UInt = #line) {
        var status: Int32 = 0
        errno = 0
        let result = Darwin.waitpid(child, &status, WNOHANG)
        let waitError = errno
        if result == 0 {
            // A failing implementation must not leave our still-owned fixture child alive.
            Darwin.kill(child, SIGKILL)
            _ = Darwin.waitpid(child, &status, 0)
        }
        XCTAssertEqual(result, -1, file: file, line: line)
        XCTAssertEqual(waitError, ECHILD, file: file, line: line)
        errno = 0
        let signalResult = Darwin.kill(child, 0)
        let signalError = errno
        XCTAssertEqual(signalResult, -1, file: file, line: line)
        XCTAssertEqual(signalError, ESRCH, file: file, line: line)
    }
}
#endif
