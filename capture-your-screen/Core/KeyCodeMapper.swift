import Carbon.HIToolbox
import Foundation
import AppKit

/// Maps Carbon key codes to human-readable symbols and builds display strings.
struct KeyCodeMapper {

    // MARK: - A-Z

    static func keyCodeToLetter(_ keyCode: UInt32) -> String? {
        switch keyCode {
        case UInt32(kVK_ANSI_A): return "A"
        case UInt32(kVK_ANSI_B): return "B"
        case UInt32(kVK_ANSI_C): return "C"
        case UInt32(kVK_ANSI_D): return "D"
        case UInt32(kVK_ANSI_E): return "E"
        case UInt32(kVK_ANSI_F): return "F"
        case UInt32(kVK_ANSI_G): return "G"
        case UInt32(kVK_ANSI_H): return "H"
        case UInt32(kVK_ANSI_I): return "I"
        case UInt32(kVK_ANSI_J): return "J"
        case UInt32(kVK_ANSI_K): return "K"
        case UInt32(kVK_ANSI_L): return "L"
        case UInt32(kVK_ANSI_M): return "M"
        case UInt32(kVK_ANSI_N): return "N"
        case UInt32(kVK_ANSI_O): return "O"
        case UInt32(kVK_ANSI_P): return "P"
        case UInt32(kVK_ANSI_Q): return "Q"
        case UInt32(kVK_ANSI_R): return "R"
        case UInt32(kVK_ANSI_S): return "S"
        case UInt32(kVK_ANSI_T): return "T"
        case UInt32(kVK_ANSI_U): return "U"
        case UInt32(kVK_ANSI_V): return "V"
        case UInt32(kVK_ANSI_W): return "W"
        case UInt32(kVK_ANSI_X): return "X"
        case UInt32(kVK_ANSI_Y): return "Y"
        case UInt32(kVK_ANSI_Z): return "Z"
        default: return nil
        }
    }

    // MARK: - 0-9

    static func keyCodeToDigit(_ keyCode: UInt32) -> String? {
        switch keyCode {
        case UInt32(kVK_ANSI_0): return "0"
        case UInt32(kVK_ANSI_1): return "1"
        case UInt32(kVK_ANSI_2): return "2"
        case UInt32(kVK_ANSI_3): return "3"
        case UInt32(kVK_ANSI_4): return "4"
        case UInt32(kVK_ANSI_5): return "5"
        case UInt32(kVK_ANSI_6): return "6"
        case UInt32(kVK_ANSI_7): return "7"
        case UInt32(kVK_ANSI_8): return "8"
        case UInt32(kVK_ANSI_9): return "9"
        default: return nil
        }
    }

    // MARK: - F1-F12

    static func keyCodeToFunction(_ keyCode: UInt32) -> String? {
        switch keyCode {
        case UInt32(kVK_F1):  return "F1"
        case UInt32(kVK_F2):  return "F2"
        case UInt32(kVK_F3):  return "F3"
        case UInt32(kVK_F4):  return "F4"
        case UInt32(kVK_F5):  return "F5"
        case UInt32(kVK_F6):  return "F6"
        case UInt32(kVK_F7):  return "F7"
        case UInt32(kVK_F8):  return "F8"
        case UInt32(kVK_F9):  return "F9"
        case UInt32(kVK_F10): return "F10"
        case UInt32(kVK_F11): return "F11"
        case UInt32(kVK_F12): return "F12"
        default: return nil
        }
    }

    // MARK: - Special keys

    static func keyCodeToSpecial(_ keyCode: UInt32) -> String? {
        switch keyCode {
        case UInt32(kVK_Return):     return "↩"
        case UInt32(kVK_Escape):     return "⎋"
        case UInt32(kVK_Space):      return "Space"
        case UInt32(kVK_Delete):     return "⌫"
        case UInt32(kVK_Tab):        return "⇥"
        case UInt32(kVK_LeftArrow):  return "←"
        case UInt32(kVK_RightArrow): return "→"
        case UInt32(kVK_UpArrow):    return "↑"
        case UInt32(kVK_DownArrow):  return "↓"
        default: return nil
        }
    }

    // MARK: - Full display string

    /// Build the full display string: modifier symbols followed by the key symbol.
    /// e.g. keyCode=kVK_ANSI_A, modifiers=cmdKey|shiftKey → "⌘⇧A"
    static func makeDisplayString(keyCode: UInt32, modifiers: UInt32) -> String {
        var parts: [String] = []
        if modifiers & UInt32(cmdKey)     != 0 { parts.append("⌘") }
        if modifiers & UInt32(shiftKey)   != 0 { parts.append("⇧") }
        if modifiers & UInt32(optionKey)  != 0 { parts.append("⌥") }
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }

        let keyPart: String
        if let letter = keyCodeToLetter(keyCode) {
            // Show uppercase when Shift is held, lowercase otherwise
            keyPart = (modifiers & UInt32(shiftKey) != 0) ? letter : letter.lowercased()
        } else if let digit = keyCodeToDigit(keyCode) {
            keyPart = digit
        } else if let fn = keyCodeToFunction(keyCode) {
            keyPart = fn
        } else if let special = keyCodeToSpecial(keyCode) {
            keyPart = special
        } else {
            keyPart = "Key\(keyCode)"
        }

        parts.append(keyPart)
        return parts.joined()
    }

    // MARK: - NSEvent → Carbon modifiers

    /// Convert NSEvent modifier flags to Carbon modifier flags (cmdKey, shiftKey, etc.).
    static func carbonModifiers(from event: NSEvent) -> UInt32 {
        var mods: UInt32 = 0
        let nsMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if nsMods.contains(.command) { mods |= UInt32(cmdKey) }
        if nsMods.contains(.shift)   { mods |= UInt32(shiftKey) }
        if nsMods.contains(.option)  { mods |= UInt32(optionKey) }
        if nsMods.contains(.control) { mods |= UInt32(controlKey) }
        return mods
    }
}
