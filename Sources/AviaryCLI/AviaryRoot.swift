import ArgumentParser
import Foundation

public struct AviaryRoot: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "aviary",
        abstract: "Post tweets and replies via Twitter/X GraphQL API",
        discussion: "fast X CLI for tweeting, replying, and reading",
        version: "0.1.0",
        subcommands: [
            Tweet.self, Reply.self, HelpCmd.self, QueryIds.self, Home.self, Read.self, Replies.self, Thread.self,
            Search.self, Mentions.self, UserTweets.self, Bookmarks.self, Unbookmark.self, Likes.self,
            News.self, Lists.self, ListTimeline.self, Following.self, Followers.self,
            Follow.self, Unfollow.self, About.self, Whoami.self, Check.self,
        ]
    )

    @OptionGroup var opts: GlobalOptions

    public init() {}

    public func run() async throws { print(AviaryRoot.helpMessage()) }

    public static func rewrittenArguments(_ arguments: [String]) -> [String] {
        InvocationArguments(arguments).arguments
    }

    public static func mainAsync() async {
        let invocation = InvocationArguments(Array(CommandLine.arguments.dropFirst()))
        let args = invocation.arguments
        do {
            var command = try AviaryRoot.parseAsRoot(args)
            if var asyncCommand = command as? any AsyncParsableCommand { try await asyncCommand.run() }
            else { try command.run() }
        } catch let error as CLIError {
            let output = invocation.output
            let prefix = output.status("err")
            stderrLine(error.description.hasPrefix(prefix) ? error.description : prefix + error.description)
            Foundation.exit(error.exitCode)
        } catch let exit as ExitCode {
            Foundation.exit(exit.rawValue)
        } catch {
            // Keep ArgumentParser's detailed usage/help, but use Bird's parser error status.
            if AviaryRoot.exitCode(for: error).rawValue == 0 { AviaryRoot.exit(withError: error) }
            stderrLine(AviaryRoot.fullMessage(for: error))
            Foundation.exit(1)
        }
    }
}
