import Foundation

struct CLIArguments: Equatable {
    var mode: String?
    var display: String?
    var output: String?
    var json: Bool = false
    var checkPermission: Bool = false
    var overwrite: Bool = false
    var regionX: Int?
    var regionY: Int?
    var regionWidth: Int?
    var regionHeight: Int?

    /// Flags supported in P5.2.
    static let supportedFlags: Set<String> = [
        "--mode", "--display", "--output", "--json", "--check-permission",
    ]

    enum ParseError: Error, Equatable {
        case unknownFlag(String)
        case missingValue(String)
        case duplicateFlag(String)
    }

    static func parse(_ args: [String]) -> Result<CLIArguments, ParseError> {
        var parsed = CLIArguments()
        var index = 0

        while index < args.count {
            let token = args[index]

            switch token {
            case "--mode":
                guard let value = nextValue(after: index, in: args) else {
                    return .failure(.missingValue("--mode"))
                }
                if parsed.mode != nil { return .failure(.duplicateFlag("--mode")) }
                parsed.mode = value
                index += 2
            case "--display":
                guard let value = nextValue(after: index, in: args) else {
                    return .failure(.missingValue("--display"))
                }
                if parsed.display != nil { return .failure(.duplicateFlag("--display")) }
                parsed.display = value
                index += 2
            case "--output":
                guard let value = nextValue(after: index, in: args) else {
                    return .failure(.missingValue("--output"))
                }
                if parsed.output != nil { return .failure(.duplicateFlag("--output")) }
                parsed.output = value
                index += 2
            case "--json":
                if parsed.json { return .failure(.duplicateFlag("--json")) }
                parsed.json = true
                index += 1
            case "--check-permission":
                if parsed.checkPermission { return .failure(.duplicateFlag("--check-permission")) }
                parsed.checkPermission = true
                index += 1
            case "--overwrite":
                if parsed.overwrite { return .failure(.duplicateFlag("--overwrite")) }
                parsed.overwrite = true
                index += 1
            case "--x", "--y", "--width", "--height":
                guard let value = nextValue(after: index, in: args) else {
                    return .failure(.missingValue(token))
                }
                guard let number = Int(value) else {
                    return .failure(.unknownFlag(token))
                }
                switch token {
                case "--x":
                    if parsed.regionX != nil { return .failure(.duplicateFlag("--x")) }
                    parsed.regionX = number
                case "--y":
                    if parsed.regionY != nil { return .failure(.duplicateFlag("--y")) }
                    parsed.regionY = number
                case "--width":
                    if parsed.regionWidth != nil { return .failure(.duplicateFlag("--width")) }
                    parsed.regionWidth = number
                case "--height":
                    if parsed.regionHeight != nil { return .failure(.duplicateFlag("--height")) }
                    parsed.regionHeight = number
                default:
                    break
                }
                index += 2
            case let flag where flag.hasPrefix("-"):
                return .failure(.unknownFlag(flag))
            default:
                return .failure(.unknownFlag(token))
            }
        }

        return .success(parsed)
    }

    var unsupportedFlagsUsed: Bool {
        overwrite
            || mode == "region"
            || display == "active"
            || (display != nil && display != "main" && Int(display!) != nil)
            || regionX != nil || regionY != nil || regionWidth != nil || regionHeight != nil
    }

    private static func nextValue(after index: Int, in args: [String]) -> String? {
        let next = index + 1
        guard next < args.count, !args[next].hasPrefix("-") else {
            return nil
        }
        return args[next]
    }
}