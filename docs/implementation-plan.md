# Capture Your Screen — v1 Implementation Plan

> **Document Version**: 1.0  
> **Last Updated**: 2026-04-03  
> **Target Release**: v1.0.0

---

## Table of Contents

1. [Product Goals & v1 Scope](#1-product-goals--v1-scope)
2. [Architecture Overview](#2-architecture-overview)
3. [Global Hotkey System](#3-global-hotkey-system)
4. [Area Selection & Overlay Interaction](#4-area-selection--overlay-interaction)
5. [Folder Storage & iCloud Sync](#5-folder-storage--icloud-sync)
6. [Menu Bar History & Finder Access](#6-menu-bar-history--finder-access)
7. [OCR Service Interface (预留)](#7-ocr-service-interface-预留)
8. [Permissions & Error Handling](#8-permissions--error-handling)
9. [UI Design Principles](#9-ui-design-principles)
10. [Testing & Acceptance Criteria](#10-testing--acceptance-criteria)
11. [Future Extensions](#11-future-extensions)

---

## 1. Product Goals & v1 Scope

### 1.1 Core Value Proposition

A minimal, privacy-first macOS menu bar screenshot tool that captures screen regions with a single global hotkey, automatically saves to iCloud Drive, and provides instant access to screenshot history directly from the menu bar.

### 1.2 v1 Feature Boundaries

**In Scope (v1)**

| Feature | Description |
|---------|-------------|
| Area Selection Capture | Drag to select a screen region; selected area is clear, outside area is blurred/darkened |
| Global Hotkey | User-configurable system-wide shortcut (default: `⌘⇧A`) to trigger capture from any app |
| Auto Save + Copy | On confirmation, copy image to clipboard AND write to `iCloud Drive/Capture Your Screen/` |
| Menu Bar History | Grouped by date (`Today`, `Yesterday`, `Earlier`) with thumbnail, time, Copy, Show in Finder |
| iCloud Folder Access | Single source of truth in Finder at `iCloud Drive/Capture Your Screen/` |
| Hotkey Customization | Settings panel to view/modify hotkey with immediate effect |
| Permission Handling | Graceful prompts for Screen Recording permission |

**Out of Scope (Post-v1)**

- Full-screen or window capture modes
- Annotation / markup tools
- OCR text extraction (interface reserved — see §7)
- Cloud upload / sharing links
- Advertisements or upsells

### 1.3 User Flow

```
[User presses ⌘⇧A or clicks menu bar icon]
         │
         ▼
   ┌─────────────────────────────────┐
   │  Full-screen overlay appears    │
   │  (darkened / blurred background) │
   └─────────────────────────────────┘
         │
         ▼
   ┌─────────────────────────────────┐
   │  User drags to select region    │
   │  (selection rectangle shown)     │
   └─────────────────────────────────┘
         │
    ┌────┴────┐
    │  Esc    │  Enter / Release
    ▼         ▼
  Cancel    Confirm
    │         │
    ▼         ▼
  Overlay    ┌──────────────────┐
  dismisses  │  Capture region  │
             │  Save to folder  │
             │  Copy to clipboard│
             │  Show notification│
             └──────────────────┘
                      │
                      ▼
               Overlay dismisses
```

---

## 2. Architecture Overview

### 2.1 Component Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                         MenuBarExtra (SwiftUI)                       │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌──────────────────┐     ┌───────────────────┐                    │
│  │  MenuBarView     │────▶│  MenuBarViewModel  │                    │
│  │  (SwiftUI View)  │◀────│                    │                    │
│  └──────────────────┘     └─────────┬───────────┘                    │
│                                     │                                │
└─────────────────────────────────────┼────────────────────────────────┘
                                      │
                    ┌─────────────────┼─────────────────┐
                    │                 │                 │
                    ▼                 ▼                 ▼
         ┌──────────────────┐ ┌─────────────────┐ ┌───────────────────┐
         │  HotkeyManager   │ │ ScreenshotStore │ │ CloudStorageResolver│
         │  (HotKey Swift)  │ │                 │ │                   │
         └────────┬─────────┘ └────────┬────────┘ └─────────┬─────────┘
                  │                      │                    │
                  │                      ▼                    │
                  │             ┌──────────────────┐          │
                  │             │ ScreenshotStore  │◀─────────┘
                  │             │ (iCloud folder   │
                  │             │  scanner)         │
                  │             └──────────────────┘
                  │                      │
                  ▼                      │
         ┌───────────────────────────────────────────────────────┐
         │              CaptureCoordinator (State Machine)         │
         ├───────────────────────────────────────────────────────┤
         │  States: idle → capturing → selected → confirmed/cancelled │
         └───────────────────────────┬───────────────────────────┘
                                     │
                                     ▼
         ┌───────────────────────────────────────────────────────┐
         │                  OverlayWindow (NSWindow)              │
         │  ┌─────────────────────────────────────────────────┐  │
         │  │            SelectionOverlayView (SwiftUI)         │  │
         │  │  - Draggable selection rectangle                 │  │
         │  │  - Blur/dark effect outside selection             │  │
         │  │  - ESC to cancel, Enter to confirm               │  │
         │  └─────────────────────────────────────────────────┘  │
         └───────────────────────────────────────────────────────┘
```

### 2.2 Module Responsibilities

| Module | Responsibility |
|--------|----------------|
| `HotkeyManager` | Register/unregister global hotkey using `HotKey` Swift package; persist user preference via `UserDefaults` |
| `CaptureCoordinator` | State machine managing idle → capturing → selected → confirmed/cancelled transitions |
| `OverlayWindow` | Borderless `NSWindow` covering the entire screen for the capture overlay |
| `SelectionOverlayView` | SwiftUI view rendering selection rectangle, blur mask, and instruction text |
| `ScreenshotStore` | Write captured image to iCloud folder; scan folder to build date-grouped history model |
| `CloudStorageResolver` | Resolve `iCloud Drive/Capture Your Screen/` path; detect iCloud availability; fallback to `~/Library/Application Support/CaptureYourScreen/Screenshots/` |
| `MenuBarViewModel` | Provide menu bar UI with capture actions, directory status, and grouped screenshot history |
| `OCRServiceInterface` |预留 — Protocol defining `extractText(from image: NSImage) async throws -> String` for future OCR integration (see §7) |

### 2.3 Data Flow

```
User triggers capture
        │
        ▼
CaptureCoordinator.transition(to: .capturing)
        │
        ▼
OverlayWindow.showFullScreen()
        │
        ▼
User draws selection → CaptureCoordinator.transition(to: .selected)
        │
        ├── [Esc] ──▶ CaptureCoordinator.transition(to: .cancelled) ──▶ OverlayWindow.dismiss()
        │
        └── [Enter / Mouse Up] ──▶
                                    │
                                    ▼
                            ScreenshotStore.save(capturedImage)
                                    │
                    ┌───────────────┴───────────────┐
                    │                               │
                    ▼                               ▼
            Copy to clipboard              Write to iCloud folder
                    │
                    ▼
            Show notification
                    │
                    ▼
            MenuBarViewModel.refreshHistory()
                    │
                    ▼
            OverlayWindow.dismiss()
```

### 2.4 File Structure

```
CaptureYourScreen/
├── App/
│   ├── CaptureYourScreenApp.swift          # @main, MenuBarExtra
│   └── ContentView.swift                    # Menu bar popover root
├── Core/
│   ├── CaptureCoordinator.swift             # State machine
│   ├── HotkeyManager.swift                  # Global hotkey registration
│   ├── ScreenshotStore.swift                # Save & scan screenshots
│   └── CloudStorageResolver.swift          # iCloud path resolution
├── Capture/
│   ├── OverlayWindow.swift                  # Borderless screen window
│   ├── SelectionOverlayView.swift           # Selection UI with blur
│   └── ScreenCapture.swift                  # CGWindow screen capture APIs
├── MenuBar/
│   ├── MenuBarView.swift                    # SwiftUI menu bar UI
│   ├── MenuBarViewModel.swift               # UI state & actions
│   └── ScreenshotHistoryItem.swift          # History item model
├── Services/
│   └── OCRServiceInterface.swift            # 预留 OCR protocol
├── Resources/
│   └── Assets.xcassets/
└── Supporting/
    └── Info.plist
```

---

## 3. Global Hotkey System

### 3.1 Default Hotkey

| Hotkey | Meaning |
|--------|---------|
| `⌘⇧A` (Command + Shift + A) | Trigger area capture |

> **Note**: `⌘⇧A` is chosen over `⌘⌃A` (Command + Control + A) because Control-based combos conflict with many app shortcuts and feel intrusive on macOS.

### 3.2 HotkeyManager API

```swift
// filepath: CaptureYourScreen/Core/HotkeyManager.swift

import Foundation
import Carbon.HIToolbox   // For key codes

final class HotkeyManager: ObservableObject {
    /// Published for UI binding (shows current hotkey in settings)
    @Published private(set) var currentHotkey: HotkeyConfiguration

    /// Register the global hotkey. Call once at app launch.
    func register() throws

    /// Unregister (e.g., during settings change or app quit)
    func unregister()

    /// Update hotkey with new key + modifiers. Re-registers automatically.
    func updateHotkey(_ config: HotkeyConfiguration) throws

    /// Called by the system when the hotkey fires
    func handleHotkeyPressed()
}

/// HotkeyConfiguration is persisted in UserDefaults
struct HotkeyConfiguration: Codable, Equatable {
    var keyCode: UInt32          // e.g., kVK_AN_A = 0x00)
    var modifiers: UInt32        // NSEvent.ModifierFlags rawValue
    var displayString: String     // e.g., "⌘⇧A"
}
```

### 3.3 Persistence

- Hotkey configuration stored in `UserDefaults.standard` under key `"hotkeyConfiguration"`.
- On app launch, `HotkeyManager` loads persisted config or falls back to `⌘⇧A`.
- Changing hotkey in settings immediately unregisters the old and registers the new.

### 3.4 Key Code Reference (Partial)

| Key | Key Code | Display |
|-----|----------|---------|
| A | 0x00 | A |
| S | 0x01 | S |
| D | 0x02 | D |
| 3 | 0x15 | 3 |
| 4 | 0x16 | 4 |
| 8 | 0x28 | 8 |

### 3.5 Recommended Third-Party Package

Use the open-source **[HotKey](https://github.com/soffes/HotKey)** Swift package by Sam Soffes. It wraps `CGEvent` tap registration cleanly and handles the `NSEvent` callback cleanly:

```swift
// Usage with HotKey package
import HotKey

let hotKey = HotKey(key: .a, modifiers: [.command, .shift])
hotKey.keyDownHandler = { [weak self] in
    self?.captureCoordinator.startCapture()
}
```

---

## 4. Area Selection & Overlay Interaction

### 4.1 OverlayWindow

A single **borderless, transparent, full-screen `NSWindow`** that sits above all other windows and the menu bar.

```swift
// filepath: CaptureYourScreen/Capture/OverlayWindow.swift

final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        self.level = .screenSaver          // Above all windows
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.ignoresMouseEvents = false     // We need mouse events!
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
}
```

### 4.2 SelectionOverlayView

The SwiftUI view rendered inside `OverlayWindow`'s `contentView`.

**Visual Layers (bottom to top)**

1. **Dark overlay** — `Color.black.opacity(0.4)` covering the entire screen
2. **Cutout / Clear region** — The selected rectangle is rendered as `Color.clear` (using `compositingGroup` + `lumaGradient` mask) so the screen shows through
3. **Selection border** — `RoundedRectangle` stroke (`Color.white`, 1pt) around the active selection
4. **Resize handles** — 8 small white squares at corners and edge midpoints
5. **Instruction text** — `"Drag to select area — Esc to cancel, Enter to confirm"` at top center
6. **Crosshair cursor** — Custom cursor over the overlay

### 4.3 Blur Effect Implementation

The "outside blurred, inside clear" effect is achieved using a **mask with a clear rectangle cut out**:

```swift
// filepath: CaptureYourScreen/Capture/SelectionOverlayView.swift

struct SelectionOverlayView: View {
    @Binding var selection: CGRect?
    let instruction: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            // Dark overlay
            Color.black.opacity(0.4)
                .overlay(
                    // Clear cutout for selection area
                    selection.map { rect in
                        Rectangle()
                            .fill(.clear)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .blendMode(.clear)
                    }
                )

            // Selection border
            if let rect = selection {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.white, lineWidth: 1)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)

                // Resize handles (8 points)
                ForEach(resizeHandlePositions(for: rect), id: \.self) { point in
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 8, height: 8)
                        .position(point)
                }
            }

            // Instruction text
            VStack {
                Text(instruction)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.top, 60)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

### 4.4 Selection Interaction

| Action | Behavior |
|--------|----------|
| Mouse down | Start selection at point |
| Mouse drag | Expand selection rectangle |
| Mouse up | Finalize selection; transition to `.selected` state |
| Esc key | Cancel and dismiss overlay |
| Enter key | Confirm selection and capture |
| Drag handles | Resize existing selection |

### 4.5 Screen Capture

After confirmation, capture the selected region using `CGWindowListCreateImage`:

```swift
// filepath: CaptureYourScreen/Capture/ScreenCapture.swift

enum ScreenCaptureError: Error {
    case noScreenSelected
    case captureFailure(CGError)
}

struct ScreenCapture {
    /// Capture a specific region of the main display.
    static func captureRegion(_ rect: CGRect) throws -> NSImage {
        let image = CGWindowListCreateImage(
            rect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.boundsIgnoreFraming, .nominalResolution]
        )
        guard let cgImage = image else {
            throw ScreenCaptureError.captureFailure(.failed)
        }
        return NSImage(cgImage: cgImage, size: rect.size)
    }

    /// Capture the entire screen (used as fallback if no selection).
    static func captureFullScreen() throws -> NSImage {
        guard let screen = NSScreen.main else {
            throw ScreenCaptureError.noScreenSelected
        }
        return try captureRegion(screen.frame)
    }
}
```

---

## 5. Folder Storage & iCloud Sync

### 5.1 Storage Path Resolution

```swift
// filepath: CaptureYourScreen/Core/CloudStorageResolver.swift

import Foundation

enum StorageLocation {
    case iCloud(containerIdentifier: String, folderName: String)
    case local(URL)
}

struct CloudStorageResolver {
    static let appFolderName = "Capture Your Screen"
    static let localFallbackFolderName = "CaptureYourScreen"

    /// Primary: iCloud Drive container
    var iCloudContainerURL: URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.yourteamname.capture-your-screen")
    }

    /// Resolved screenshot folder URL
    var screenshotFolderURL: URL? {
        if let iCloud = iCloudContainerURL?
            .appendingPathComponent("Documents")
            .appendingPathComponent(Self.appFolderName, isDirectory: true) {
            return iCloud
        }
        return localFallbackURL
    }

    /// Fallback: Application Support directory
    var localFallbackURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent(Self.localFallbackFolderName, isDirectory: true)
            .appendingPathComponent("Screenshots", isDirectory: true)
    }

    /// Check if iCloud is available
    var isCloudAvailable: Bool {
        iCloudContainerURL != nil
    }

    /// Ensure the target folder exists (creates if needed)
    func ensureFolderExists() throws {
        guard let url = screenshotFolderURL else { return }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
```

### 5.2 File Naming Convention

Format: `Screenshot_yyyy-MM-dd_HH-mm-ss_SSS.png`

Example: `Screenshot_2026-04-03_14-32-01_452.png`

- **Sortable by filename** (timestamp prefix guarantees chronological order in Finder and menu bar)
- Milliseconds (`SSS`) prevent collisions during rapid captures
- Uses PNG lossless format for quality

### 5.3 Save Flow

```
ScreenshotStore.save(image: NSImage)
         │
         ▼
CloudStorageResolver.ensureFolderExists()
         │
         ├── iCloud available ──▶ iCloud folder path
         └── iCloud unavailable ──▶ local fallback path (show notification)
         │
         ▼
Generate filename: Screenshot_yyyy-MM-dd_HH-mm-ss_SSS.png
         │
         ▼
Write PNG data to {folderURL}/{filename}
         │
         ▼
Return ScreenshotRecord(id: filename, url: fileURL, date: Date())
```

### 5.4 iCloud Sync Behavior

- **No custom sync logic** — rely on macOS iCloud Drive native sync
- The folder `iCloud Drive/Capture Your Screen/` appears in Finder automatically
- If iCloud Drive is **offline** (no network), writes go to local `~/Library/Application Support/CaptureYourScreen/Screenshots/` and sync when connection restores
- User is notified via system notification if fallback to local storage occurs

### 5.5 ScreenshotStore API

```swift
// filepath: CaptureYourScreen/Core/ScreenshotStore.swift

struct ScreenshotRecord: Identifiable, Hashable {
    let id: String           // filename
    let url: URL             // full file URL
    let date: Date           // capture timestamp
    var thumbnail: NSImage?  // lazy-loaded 60×60 thumbnail
}

final class ScreenshotStore: ObservableObject {
    @Published private(set) var screenshots: [ScreenshotRecord] = []

    /// Save a new screenshot. Returns the saved record.
    func save(_ image: NSImage) async throws -> ScreenshotRecord

    /// Scan the screenshot folder and rebuild the history list.
    func refreshHistory() async

    /// Delete a screenshot by ID.
    func delete(id: String) throws

    /// Copy a screenshot to the clipboard.
    func copyToClipboard(id: String) throws
}
```

---

## 6. Menu Bar History & Finder Access

### 6.1 Menu Bar UI Structure

```
┌─────────────────────────────────────────┐
│ 📷  Capture Your Screen                 │
├─────────────────────────────────────────┤
│ 🔘 Take Screenshot          ⌘⇧A        │
│ ─────────────────────────────────────── │
│ 📅 Today                               │
│   ├─ [thumb] 14:32:01      [Copy] [Show]│
│   └─ [thumb] 10:15:43      [Copy] [Show]│
│ 📅 Yesterday                           │
│   └─ [thumb] 16:45:22      [Copy] [Show]│
│ 📅 Earlier                             │
│   └─ [thumb] Apr 1, 10:00  [Copy] [Show]│
├─────────────────────────────────────────┤
│ 📂 Open Screenshot Folder               │
│ ⚙️  Settings                           │
│ ─────────────────────────────────────── │
│ ⏻  Quit Capture Your Screen            │
└─────────────────────────────────────────┘
```

### 6.2 History Grouping

```swift
// filepath: CaptureYourScreen/MenuBar/ScreenshotHistoryItem.swift

struct ScreenshotHistoryItem: Identifiable {
    let id: String
    let url: URL
    let date: Date
    let thumbnail: NSImage?
    let displayTime: String   // e.g., "14:32:01" or "Apr 1, 10:00"
}

enum HistoryGroup: String, CaseIterable {
    case today = "Today"
    case yesterday = "Yesterday"
    case earlier = "Earlier"

    var icon: String { switch self {
        case .today: return "calendar.circle.fill"
        case .yesterday: return "calendar.circle"
        case .earlier: return "calendar"
    }}

    static func group(for date: Date) -> HistoryGroup {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return .today }
        if cal.isDateInYesterday(date) { return .yesterday }
        return .earlier
    }
}
```

### 6.3 MenuBarViewModel

```swift
// filepath: CaptureYourScreen/MenuBar/MenuBarViewModel.swift

@MainActor
final class MenuBarViewModel: ObservableObject {
    @Published var historyGroups: [HistoryGroup: [ScreenshotHistoryItem]] = [:]
    @Published var currentHotkeyDisplay: String = "⌘⇧A"
    @Published var isCapturing: Bool = false

    func startCapture() {
        isCapturing = true
        captureCoordinator.startCapture()
    }

    func openScreenshotFolder() {
        let url = storageResolver.screenshotFolderURL ?? storageResolver.localFallbackURL
        NSWorkspace.shared.open(url)
    }

    func copyScreenshot(_ item: ScreenshotHistoryItem) {
        try? screenshotStore.copyToClipboard(id: item.id)
    }

    func showInFinder(_ item: ScreenshotHistoryItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func refresh() async {
        await screenshotStore.refreshHistory()
        rebuildGroups()
    }
}
```

### 6.4 Context Menu Actions

Right-clicking a history item reveals:
- **Copy** — Copy to clipboard
- **Show in Finder** — Open Finder with file selected
- **Delete** — Remove from disk (with confirmation)

---

## 7. OCR Service Interface (预留)

### 7.1 Design Rationale

OCR is **out of scope for v1**, but the interface is designed now to avoid breaking architecture changes later. A protocol-based approach allows injecting any OCR backend (Apple's Vision framework, third-party APIs) without touching the rest of the codebase.

### 7.2 Protocol Definition

```swift
// filepath: CaptureYourScreen/Services/OCRServiceInterface.swift

import Foundation
import AppKit

/// 预留 — OCR Service Protocol
/// v1 does not implement this; the interface exists to allow future
/// integration without architectural changes.
protocol OCRServiceProtocol: Sendable {
    /// Extract text from the given image.
    /// - Parameter image: The source image (screenshot).
    /// - Returns: Extracted text, or empty string if no text found.
    /// - Throws: `OCRError` if processing fails.
    func extractText(from image: NSImage) async throws -> String
}

enum OCRError: Error, LocalizedError {
    case imageTooSmall
    case noTextFound
    case processingFailed(String)
    case serviceUnavailable

    var errorDescription: String? {
        switch self {
        case .imageTooSmall:
            return "Image is too small for text recognition."
        case .noTextFound:
            return "No text found in the image."
        case .processingFailed(let detail):
            return "OCR processing failed: \(detail)"
        case .serviceUnavailable:
            return "OCR service is unavailable."
        }
    }
}

/// 预留 — Apple Vision Framework Implementation
/// Future: `final class VisionOCRService: OCRServiceProtocol`
/// Uses `VNRecognizeTextRequest` internally.
```

### 7.3 Future Integration Points

| Trigger | Action |
|---------|--------|
| User right-clicks history item → "Extract Text" | Call `ocrService.extractText(from: image)` → copy result to clipboard |
| Screenshot confirmation overlay → "Copy Text" button | Same as above |
| Menu bar → "Extract Text from Last Screenshot" | Same as above |

---

## 8. Permissions & Error Handling

### 8.1 Required Permissions

| Permission | Why | Prompt Behavior |
|------------|-----|-----------------|
| **Screen Recording** | Required to capture pixel data via `CGWindowListCreateImage` | System prompt on first capture attempt; guide user to System Settings if denied |
| **iCloud Drive** | Required to save to iCloud Drive folder | Automatic via `NSFileManager`; fallback if unavailable |
| **Notifications** | Show "Copied!" confirmation after capture | Standard notification permission prompt |

### 8.2 Screen Recording Permission Flow

```swift
// filepath: CaptureYourScreen/Core/PermissionManager.swift

import Foundation
import AppKit

enum PermissionStatus {
    case granted
    case denied
    case notDetermined
}

struct PermissionManager {
    /// Check if screen recording permission is granted.
    var screenRecordingStatus: PermissionStatus {
        // Attempt a minimal capture; if it fails with permission error, denied
        let testRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        if CGWindowListCreateImage(testRect, .optionOnScreenOnly, kCGNullWindowID, []) != nil {
            return .granted
        }
        return CGError.accessDenied == .success ? .denied : .notDetermined
    }

    /// Open System Settings → Privacy & Security → Screen Recording
    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Show an alert guiding the user to grant permission.
    func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "Capture Your Screen needs Screen Recording permission to capture your screen.\n\nPlease grant permission in System Settings → Privacy & Security → Screen Recording."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            openScreenRecordingSettings()
        }
    }
}
```

### 8.3 Error Handling Table

| Error | User Message | Recovery |
|-------|-------------|----------|
| Screen recording denied | "Screen Recording permission is required. Please enable it in System Settings." | Button to open Settings |
| iCloud unavailable | "iCloud is not available. Screenshots will be saved locally." | Show notification; continue with local storage |
| Disk full | "Not enough disk space to save the screenshot." | Show notification; discard screenshot |
| File write failure | "Failed to save screenshot. Please check the folder permissions." | Show notification; suggest Open Folder |
| Hotkey registration failed | "Could not register the hotkey. It may be in use by another app." | Fall back to menu bar click-only |

---

## 9. UI Design Principles

### 9.1 Visual Style

- **Native macOS** — Use system SwiftUI components, SF Symbols, and system typography
- **Minimal chrome** — No custom title bars, toolbars, or unnecessary borders
- **High contrast** — Selection border is white on dark overlay for clear visibility
- **Smooth animations** — 200ms ease-in-out for overlay appearance/dismissal

### 9.2 Color Palette

| Element | Color |
|---------|-------|
| Overlay background | `Color.black.opacity(0.4)` |
| Selection border | `Color.white` |
| Resize handles | `Color.white` |
| Instruction text background | `Color.black.opacity(0.6)` |
| Instruction text | `Color.white` |
| Menu bar accent | System accent color |

### 9.3 Typography

| Element | Font |
|---------|------|
| Menu bar header | `.headline` |
| Group headers (Today/Yesterday/Earlier) | `.subheadline.bold` |
| Timestamp | `.caption` |
| Action buttons (Copy/Show) | `.caption` |

### 9.4 Animation

| Animation | Duration | Curve |
|-----------|----------|-------|
| Overlay fade in | 150ms | easeOut |
| Overlay fade out | 100ms | easeIn |
| Selection rectangle appear | 100ms | easeOut |
| Menu bar popover appear | system default | system default |

### 9.5 Accessibility

- VoiceOver labels on all interactive elements
- Minimum touch target size: 44×44pt for menu bar items
- High contrast mode support via system semantic colors
- Reduce Motion support: disable animations if `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`

---

## 10. Testing & Acceptance Criteria

### 10.1 Hotkey Tests

| ID | Scenario | Expected Result |
|----|----------|-----------------|
| HK-01 | User presses `⌘⇧A` in any app (e.g., Safari) | Overlay appears within 300ms |
| HK-02 | User changes hotkey to `⌘⇧X` in settings | New hotkey works immediately; old no longer triggers |
| HK-03 | Another app uses `⌘⇧A` | No conflict; both apps receive the hotkey (system behavior) |
| HK-04 | App launches with a persisted invalid hotkey | Falls back to default `⌘⇧A`; no crash |

### 10.2 Capture Flow Tests

| ID | Scenario | Expected Result |
|----|----------|-----------------|
| CAP-01 | User presses hotkey, drags rectangle, presses Enter | Screenshot saved; clipboard populated; overlay dismissed |
| CAP-02 | User presses hotkey, presses Esc immediately | Overlay dismissed; no screenshot taken |
| CAP-03 | User captures, closes app, reopens | Last screenshot appears in history |
| CAP-04 | Selection rectangle < 10×10px | Confirm button disabled; minimum size enforced |
| CAP-05 | User has two monitors | Overlay covers primary screen only |

### 10.3 Storage & History Tests

| ID | Scenario | Expected Result |
|----|----------|-----------------|
| ST-01 | Capture with iCloud available | File appears in `iCloud Drive/Capture Your Screen/` |
| ST-02 | Capture with iCloud offline | File saved to local fallback; notification shown |
| ST-03 | 100+ screenshots in folder | Menu bar history loads within 1 second |
| ST-04 | Delete a screenshot in Finder | Refresh removes it from menu bar history |
| ST-05 | User renames a file in Finder | Menu bar continues to work; other items unaffected |

### 10.4 Permission Tests

| ID | Scenario | Expected Result |
|----|----------|-----------------|
| PERM-01 | First launch, no permission | Overlay does not appear; permission alert shown |
| PERM-02 | User denies screen recording | Alert with "Open Settings" button; no crash |
| PERM-03 | User grants permission after denial | Next hotkey press works normally |

### 10.5 Visual Checkpoints

- [ ] Overlay covers entire screen including menu bar area
- [ ] Selection area is perfectly clear; outside area is visibly darkened
- [ ] Selection border is crisp white, 1pt
- [ ] 8 resize handles visible at corners and midpoints
- [ ] Instruction text readable against dark background
- [ ] Menu bar shows grouped history with thumbnails
- [ ] Copy and Show in Finder buttons are functional

---

## 11. Future Extensions

The following are **planned post-v1** features, documented here to ensure the architecture does not preclude them.

### 11.1 Annotation & Markup

- Add text, arrows, rectangles, blur/redaction tools after capture
- Store edited version alongside original (e.g., `Screenshot_2026-04-03_14-32-01_452_edited.png`)

### 11.2 OCR Text Extraction

- Integrate `VisionOCRService` via `OCRServiceProtocol`
- "Copy Text" button extracts text from last screenshot
- Right-click history item → "Extract Text"

### 11.3 Multiple Capture Modes

- Full-screen capture
- Window capture (user clicks a window)
- Timed capture (3-second delay)

### 11.4 Cloud Storage Providers

- Add preference for Dropbox, Google Drive, OneDrive in addition to iCloud
- Allow custom save path

### 11.5 Upload & Sharing

- Generate shareable links for screenshots
- Direct upload to Imgur, Cloudinary, or custom server

### 11.6 Notification Actions

- Notification after capture → "Show in Finder", "Copy", "Delete"

### 11.7 Shortcuts.app Integration

- Expose capture functionality as a Siri Shortcut action
