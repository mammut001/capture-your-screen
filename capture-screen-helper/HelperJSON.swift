import Foundation

enum HelperJSON {
    static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"error":"json_encode_failed"}"#
        }
        return text
    }

    static func permissionStatus(granted: Bool) -> String {
        encode([
            "ok": true,
            "screen_recording_permission": granted ? "granted" : "denied",
            "message": granted
                ? "Screen Recording permission is granted."
                : "Screen Recording permission is required.",
            "hint": "Open System Settings → Privacy & Security → Screen Recording",
        ])
    }

    static func failure(error: String, message: String, hint: String? = nil) -> String {
        var payload: [String: Any] = [
            "ok": false,
            "error": error,
            "message": message,
        ]
        if let hint {
            payload["hint"] = hint
        }
        return encode(payload)
    }

    static func unsupported(message: String) -> String {
        failure(error: "unsupported_flag", message: message)
    }
}