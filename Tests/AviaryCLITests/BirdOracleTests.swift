import ArgumentParser
import Foundation
import XCTest
import XClient
@testable import AviaryCLI

final class BirdOracleTests: XCTestCase {
    struct Corpus: Decodable {
        struct Render: Decodable { let name: String; let mode: String; let tweet: TweetData; let expected: String }
        struct Command: Decodable {
            struct Option: Decodable { let long: String?; let short: String? }
            struct Argument: Decodable { let name: String; let required: Bool; let variadic: Bool }
            let name: String; let aliases: [String]; let options: [Option]; let arguments: [Argument]
        }
        let rendering: [Render]
        let commands: [Command]
        let globalOptions: [Command.Option]
    }

    func corpus() throws -> Corpus {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "bird-0.8-cli", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }

    func testTextRenderingMatchesBirdOracle() throws {
        for fixture in try corpus().rendering {
            let output = CLIOutput(plain: fixture.mode == "plain", noEmoji: fixture.mode == "noEmoji", isTTY: false, environment: [:])
            let actual = output.tweets([fixture.tweet], separator: false) + "\n" + output.stats(fixture.tweet)
            XCTAssertEqual(actual, fixture.expected, "\(fixture.name) in \(fixture.mode) mode")
        }
    }

    func testEveryBirdCommandAndOptionIsAdvertised() throws {
        for command in try corpus().commands {
            guard command.name != "help" else { continue }
            var arguments = [command.name]
            for argument in command.arguments where argument.required {
                arguments.append(argument.name.contains("text") ? "example" : "1234567890123456789")
            }
            let parsed = try AviaryRoot.parseAsRoot(arguments)
            let help = type(of: parsed).helpMessage()
            for option in command.options {
                if let long = option.long { XCTAssertTrue(help.contains(long), "\(command.name) missing \(long)") }
                if let short = option.short { XCTAssertTrue(help.contains(short), "\(command.name) missing \(short)") }
            }
            for alias in command.aliases {
                var aliasArguments = arguments
                aliasArguments[0] = alias
                XCTAssertNoThrow(try AviaryRoot.parseAsRoot(aliasArguments), "\(command.name) alias \(alias)")
            }
        }
    }

    func testBirdGlobalOptionsAreAvailable() throws {
        let help = AviaryRoot.helpMessage()
        for option in try corpus().globalOptions {
            if let long = option.long { XCTAssertTrue(help.contains(long), "Missing global option \(long)") }
            // -V is normalized before ArgumentParser and is tested through the actual entry point.
            if let short = option.short, short != "-V" { XCTAssertTrue(help.contains(short), "Missing global option \(short)") }
        }
        let parsed = try AviaryRoot.parseAsRoot(AviaryRoot.rewrittenArguments(["--quote-depth=2", "--plain", "1234567890123456789"]))
        let read = try XCTUnwrap(parsed as? Read)
        XCTAssertEqual(read.opts.quoteDepth, "2")
        XCTAssertTrue(read.opts.plain)
    }
}
