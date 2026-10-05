import ArgumentParser
import Foundation

/// Derive option arity from the parser declarations, not a second command schema.
/// ArgumentParser's versioned help format is decoded once per process.
struct InvocationArguments {
    private struct Tool: Decodable {
        let serializationVersion: Int
        let command: Command
    }
    private struct Command: Decodable {
        let commandName: String
        let aliases: [String]?
        let arguments: [Argument]?
        let subcommands: [Command]?
    }
    private struct Argument: Decodable {
        struct Name: Decodable {
            let kind: String
            let name: String
            var spelling: String { (kind == "long" ? "--" : "-") + name }
        }
        let kind: String
        let names: [Name]?
        let parsingStrategy: String
    }
    private static let schema: Command = {
        do {
            let tool = try JSONDecoder().decode(Tool.self, from: Data(AviaryRoot._dumpHelp().utf8))
            precondition(tool.serializationVersion == 0, "Unsupported ArgumentParser help schema")
            return tool.command
        } catch {
            preconditionFailure("Invalid ArgumentParser help schema: \(error)")
        }
    }()
    private static func options(_ command: Command) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for argument in command.arguments ?? [] where argument.kind == "option" {
            for name in argument.names ?? [] {
                result[name.spelling] = argument.parsingStrategy == "unconditional"
            }
        }
        return result
    }

    let arguments: [String]
    let output: CLIOutput

    init(_ input: [String]) {
        let root = Self.schema
        let globalOptions = Self.options(root)
        var options = globalOptions
        var commands: [String: Command] = [:]
        for command in root.subcommands ?? [] {
            commands[command.commandName] = command
            for alias in command.aliases ?? [] { commands[alias] = command }
        }
        // Preserve opaque values even before a command has been selected.
        for command in root.subcommands ?? [] {
            options.merge(Self.options(command)) { current, _ in current }
        }
        var result: [String] = []
        var index = input.first == "--" ? 1 : 0
        var selectedCommand = false
        var plain = false
        var noEmoji = false
        var noColor = false
        while index < input.count {
            let token = input[index]
            if token == "--" {
                result.append(contentsOf: input[index...])
                break
            }
            if let unconditional = options[token], index + 1 < input.count {
                let value = input[index + 1]
                // Bind flag-shaped values so root flags cannot steal them.
                // Leave other values separate: ArgumentParser distinguishes an
                // empty argument from a missing value after "=".
                if unconditional && value.hasPrefix("-") {
                    result.append(token + "=" + value)
                } else {
                    result.append(contentsOf: [token, value])
                }
                index += 2
                continue
            }
            if !selectedCommand, !token.hasPrefix("-") {
                if let command = commands[token] {
                    selectedCommand = true
                    options = globalOptions.merging(Self.options(command)) { _, value in value }
                } else {
                    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
                    let isID = trimmed.range(of: #"^\d{8,}$"#, options: .regularExpression) != nil
                    let isURL = trimmed.range(of: #"^(?:https?://)?(?:www\.)?(?:twitter\.com|x\.com)/[^/]+/status/\d+"#, options: [.regularExpression, .caseInsensitive]) != nil
                    if isID || isURL {
                        result.append("read")
                        selectedCommand = true
                        if let command = commands["read"] { options = globalOptions.merging(Self.options(command)) { _, value in value } }
                    }
                }
            }
            if token == "--plain" { plain = true }
            if token == "--no-emoji" { noEmoji = true }
            if token == "--no-color" { noColor = true }
            result.append(token == "-V" ? "--version" : token)
            index += 1
        }
        arguments = result
        output = CLIOutput(plain: plain, noEmoji: noEmoji, noColor: noColor)
    }
}
