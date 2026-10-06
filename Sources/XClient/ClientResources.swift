import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// SwiftPM's generated accessor embeds a build-machine path and can trap when
/// only the executable is installed. Installed resources live beside the real
/// executable, including when invoked through a Homebrew or mise symlink.
enum ClientResources {
    static func url(for name: String, extension suffix: String) -> URL? {
        guard let executable = executableURL() else { return nil }
        if let resource = url(for: name, extension: suffix, executableURL: executable) { return resource }
        #if os(macOS)
        // XCTest can load the test bundle into Apple's separate xctest runner.
        let testBundle = Bundle(for: ResourceMarker.self).bundleURL
        if testBundle.pathExtension == "xctest" {
            return url(for: name, extension: suffix, executableURL: testBundle)
        }
        #endif
        return nil
    }

    static func url(for name: String, extension suffix: String, executableURL: URL) -> URL? {
        let executable = executableURL.resolvingSymlinksInPath()
        var directories = [executable.deletingLastPathComponent()]
        if executable.deletingLastPathComponent().lastPathComponent == "libexec" {
            directories.append(executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("bin", isDirectory: true))
        }

        // SwiftPM's macOS XCTest binary sits inside an .xctest bundle; the
        // resource bundle remains in the build directory beside that bundle.
        var parent = executable.deletingLastPathComponent()
        while parent.path != "/" {
            if parent.pathExtension == "xctest" {
                directories.append(parent.deletingLastPathComponent())
                break
            }
            parent.deleteLastPathComponent()
        }

        for directory in directories {
            for bundleName in ["Aviary_XClient.bundle", "Aviary_XClient.resources"] {
                let bundle = directory.appendingPathComponent(bundleName, isDirectory: true)
                for resourceDirectory in [bundle, bundle.appendingPathComponent("Resources", isDirectory: true)] {
                    let file = resourceDirectory.appendingPathComponent("\(name).\(suffix)")
                    if FileManager.default.isReadableFile(atPath: file.path) { return file }
                }
            }
        }
        return nil
    }

    private static func executableURL() -> URL? {
        #if canImport(Darwin)
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        let status = buffer.withUnsafeMutableBufferPointer { _NSGetExecutablePath($0.baseAddress, &size) }
        guard status == 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
        #elseif os(Linux)
        return URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath()
        #else
        return Bundle.main.executableURL?.resolvingSymlinksInPath()
        #endif
    }
}

#if os(macOS)
private final class ResourceMarker: NSObject {}
#endif
