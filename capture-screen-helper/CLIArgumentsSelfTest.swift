import Foundation

enum CLIArgumentsSelfTest {
    static func run() -> Bool {
        var failures: [String] = []

        func expectParse(_ args: [String], file: StaticString = #file, line: UInt = #line) -> CLIArguments? {
            switch CLIArguments.parse(args) {
            case .success(let parsed):
                return parsed
            case .failure(let error):
                failures.append("\(file):\(line) parse failed: \(error)")
                return nil
            }
        }

        func expectFailure(_ args: [String], file: StaticString = #file, line: UInt = #line) {
            if case .success = CLIArguments.parse(args) {
                failures.append("\(file):\(line) expected failure for \(args)")
            }
        }

        if let parsed = expectParse(["--check-permission", "--json"]) {
            if !parsed.checkPermission || !parsed.json {
                failures.append("check-permission flags not set")
            }
        }

        if let parsed = expectParse([
            "--mode", "full-display",
            "--display", "main",
            "--output", "/tmp/test.png",
            "--json",
        ]) {
            if parsed.mode != "full-display" || parsed.display != "main" || parsed.output != "/tmp/test.png" {
                failures.append("capture args mismatch")
            }
            if parsed.unsupportedFlagsUsed {
                failures.append("supported args flagged unsupported")
            }
        }

        if let parsed = expectParse(["--mode", "region", "--json"]) {
            if !parsed.unsupportedFlagsUsed {
                failures.append("region mode should be unsupported")
            }
        }

        if let parsed = expectParse(["--overwrite", "--json"]) {
            if !parsed.unsupportedFlagsUsed {
                failures.append("overwrite should be unsupported")
            }
        }

        expectFailure(["--unknown-flag"])
        expectFailure(["--mode"])
        expectFailure(["--mode", "full-display", "--mode", "full-display"])

        if failures.isEmpty {
            print("CLIArgumentsSelfTest: all passed")
            return true
        }

        for failure in failures {
            fputs("CLIArgumentsSelfTest failure: \(failure)\n", stderr)
        }
        return false
    }
}