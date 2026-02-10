import Foundation

@main
struct WhispCLI {
    static func main() async {
        await run(arguments: Array(CommandLine.arguments.dropFirst()))
    }
}
