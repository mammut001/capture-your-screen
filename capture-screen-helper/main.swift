import Foundation

@main
struct CaptureScreenHelperMain {
    static func main() async {
        #if DEBUG
        if CommandLine.arguments.contains("--self-test") {
            exit(CLIArgumentsSelfTest.run() ? 0 : 1)
        }
        #endif
        let exitCode = await HelperRunner.run(arguments: CommandLine.arguments)
        exit(exitCode)
    }
}