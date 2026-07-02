import AppKit
import CoreGraphics
import CryptoKit
import Foundation

enum HelperRunner {
    static let helperVersion = "0.1.0"

    static func run(arguments: [String]) async -> Int32 {
        let args = Array(arguments.dropFirst())
        switch CLIArguments.parse(args) {
        case .failure(let error):
            printJSON(HelperJSON.failure(
                error: "invalid_arguments",
                message: message(for: error)
            ))
            return 2
        case .success(let parsed):
            return await execute(parsed)
        }
    }

    private static func execute(_ args: CLIArguments) async -> Int32 {
        if args.unsupportedFlagsUsed {
            printJSON(HelperJSON.unsupported(
                message: "One or more flags are not supported in this release. Supported: --mode full-display, --display main, --output, --json, --check-permission."
            ))
            return 2
        }

        let permissionManager = PermissionManager()

        if args.checkPermission {
            let granted = permissionManager.screenRecordingStatus == .granted
            printJSON(HelperJSON.permissionStatus(granted: granted))
            return granted ? 0 : 1
        }

        guard args.mode == "full-display" else {
            printJSON(HelperJSON.failure(
                error: "unsupported_mode",
                message: "Only --mode full-display is supported."
            ))
            return 2
        }

        guard args.display == "main" else {
            printJSON(HelperJSON.failure(
                error: "unsupported_display",
                message: "Only --display main is supported."
            ))
            return 2
        }

        guard args.json else {
            printJSON(HelperJSON.failure(
                error: "json_required",
                message: "The --json flag is required."
            ))
            return 2
        }

        guard let outputPath = args.output, !outputPath.isEmpty else {
            printJSON(HelperJSON.failure(
                error: "missing_output",
                message: "An absolute output path is required via --output."
            ))
            return 2
        }

        guard outputPath.hasPrefix("/") else {
            printJSON(HelperJSON.failure(
                error: "relative_output_path",
                message: "Output path must be absolute."
            ))
            return 2
        }

        let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL

        if FileManager.default.fileExists(atPath: outputURL.path) {
            printJSON(HelperJSON.failure(
                error: "output_exists",
                message: "Output file already exists. Refusing to overwrite."
            ))
            return 2
        }

        guard permissionManager.screenRecordingStatus == .granted else {
            printJSON(HelperJSON.failure(
                error: "screen_recording_permission_required",
                message: "Screen Recording permission is required.",
                hint: "Open System Settings → Privacy & Security → Screen Recording"
            ))
            return 1
        }

        let displayID = CGMainDisplayID()
        let bounds = CGDisplayBounds(displayID)

        do {
            let image = try await ScreenCapture.captureRegion(bounds, displayID: displayID)
            guard let pngData = ScreenshotEncoding.pngData(from: image) else {
                printJSON(HelperJSON.failure(
                    error: "image_encoding_failed",
                    message: "Failed to encode screenshot as PNG."
                ))
                return 2
            }

            let parentURL = outputURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parentURL,
                withIntermediateDirectories: true
            )

            try pngData.write(to: outputURL, options: .atomic)

            let sha256 = SHA256.hash(data: pngData)
                .map { String(format: "%02x", $0) }
                .joined()

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let createdAt = formatter.string(from: Date())

            let pixelWidth: Int
            let pixelHeight: Int
            if let rep = image.representations.first as? NSBitmapImageRep {
                pixelWidth = rep.pixelsWide
                pixelHeight = rep.pixelsHigh
            } else if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                pixelWidth = cgImage.width
                pixelHeight = cgImage.height
            } else {
                pixelWidth = Int(image.size.width)
                pixelHeight = Int(image.size.height)
            }

            printJSON(HelperJSON.encode([
                "ok": true,
                "path": outputURL.path,
                "sha256": sha256,
                "width": pixelWidth,
                "height": pixelHeight,
                "display_id": Int(displayID),
                "created_at": createdAt,
                "helper_version": helperVersion,
            ]))
            return 0
        } catch {
            printJSON(HelperJSON.failure(
                error: "capture_failed",
                message: "Screen capture failed."
            ))
            return 2
        }
    }

    private static func message(for error: CLIArguments.ParseError) -> String {
        switch error {
        case .unknownFlag(let flag):
            return "Unknown or unsupported flag: \(flag)."
        case .missingValue(let flag):
            return "Missing value for \(flag)."
        case .duplicateFlag(let flag):
            return "Duplicate flag: \(flag)."
        }
    }

    private static func printJSON(_ text: String) {
        print(text)
    }
}