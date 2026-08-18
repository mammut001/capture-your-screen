# Capture Your Screen

**A native macOS screenshot and annotation app built on ScreenCaptureKit — plus a small read-only CLI for automation agents.**

Capture Your Screen is a Swift macOS project with two complementary surfaces: a menu bar screenshot app for people, and `capture-screen-helper` for tools that need a safe, machine-readable desktop observation step.

## What makes it interesting

This is not just a wrapper around `screencapture`. The project keeps the desktop capture pipeline, annotation UI, and automation boundary separate so the same native capture stack can serve both interactive use and agent workflows.

- **Native ScreenCaptureKit pipeline** for macOS capture
- **Menu bar app** with post-capture annotation flow
- **Structured annotation system** with canvas, compositor, renderer, selection handles, arrows, and numbered callouts
- **Read-only CLI helper** that writes PNG output and returns safe JSON metadata
- **Permission-aware behavior** for macOS Screen Recording access
- **Automation integration** designed for projects such as [Conveyor](https://github.com/mammut001/Conveyor)

## Architecture

```text
                     ┌──────────────────────┐
                     │  ScreenCaptureKit    │
                     │   capture pipeline   │
                     └──────────┬───────────┘
                                │
                 ┌──────────────┴──────────────┐
                 │                             │
                 ▼                             ▼
      ┌────────────────────┐       ┌──────────────────────┐
      │ macOS menu bar app │       │ capture-screen-helper│
      │ capture + annotate │       │ read-only CLI        │
      └─────────┬──────────┘       └──────────┬───────────┘
                │                             │
                ▼                             ▼
      Annotation editor              PNG + safe JSON
      renderer/compositor            metadata to stdout
```

## Annotation pipeline

The app keeps annotation behavior in a dedicated module rather than mixing drawing state into the capture layer. The repository includes separate canvas, editor, compositor, renderer, toolbar, and shape components, making the post-capture path easier to evolve and test.

## `capture-screen-helper`

`capture-screen-helper` reuses the app's ScreenCaptureKit path for a deliberately narrow automation use case.

### What it does

- Captures the **full main display** to a PNG path you provide
- Prints **safe JSON metadata** to stdout, including path, SHA-256, dimensions, display id, and timestamp
- Checks **Screen Recording** permission without capturing when `--check-permission` is used

### What it deliberately does not do

- No mouse or keyboard input
- No browser or app control
- No uploads
- No clipboard writes
- No file deletion
- No base64 screenshot payloads

That boundary is intentional: the helper is an observation primitive, not a general-purpose computer-control process.

## Build the app

Open the Xcode project:

```bash
open capture-your-screen.xcodeproj
```

## Build the helper

```bash
xcodebuild \
  -project capture-your-screen.xcodeproj \
  -scheme capture-screen-helper \
  -configuration Release \
  build
```

Or use the helper script, which also runs argument-parser self-tests:

```bash
bash scripts/build_helper.sh
```

Install the built binary wherever your automation stack expects it, for example:

```bash
cp .derivedData/Build/Products/Release/capture-screen-helper /usr/local/bin/
```

## CLI usage

Check Screen Recording permission:

```bash
capture-screen-helper --check-permission --json
```

Capture once:

```bash
capture-screen-helper \
  --mode full-display \
  --display main \
  --output /absolute/path/screenshot.png \
  --json
```

Supported flags in this release are `--mode full-display`, `--display main`, `--output`, `--json`, and `--check-permission`. Unsupported arguments return a non-zero exit with safe JSON.

## Screen Recording permission

macOS requires **Screen Recording** permission. When it is missing, the helper returns a structured error such as:

```json
{
  "ok": false,
  "error": "screen_recording_permission_required",
  "message": "Screen Recording permission is required.",
  "hint": "Open System Settings → Privacy & Security → Screen Recording"
}
```

Grant permission to `capture-screen-helper` — or to the terminal app launching it — in **System Settings → Privacy & Security → Screen Recording**.

## Manual helper smoke test

1. Build the helper.
2. Run `--check-permission --json` before granting access and confirm permission is denied.
3. Enable Screen Recording in System Settings.
4. Capture to an absolute path under `/tmp` and confirm a PNG is produced.
5. Confirm relative output paths and pre-existing output files are rejected.

Automated real-screen capture is intentionally not assumed in headless CI because macOS Screen Recording consent is interactive.
