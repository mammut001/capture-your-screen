import Foundation

@main
struct CaptureScreenHelperMain {
    static func main() async {
        // Available in Release so `scripts/build_helper.sh` can verify the binary.
        if CommandLine.arguments.contains("--self-test") {
            exit(CLIArgumentsSelfTest.run() ? 0 : 1)
        }
        let exitCode = await HelperRunner.run(arguments: CommandLine.arguments)
        exit(exitCode)
    }
}