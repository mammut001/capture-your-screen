# capture-your-screen

macOS menu bar screenshot app with annotation tools, plus a lightweight CLI helper for read-only screen observation.

## capture-screen-helper (P5.2)

`capture-screen-helper` is a command-line tool that reuses the app's ScreenCaptureKit pipeline. It is intended for automation partners such as [Conveyor](https://github.com/mammut001/Conveyor) `desktop_agent.py`.

### What it does

- Captures a **full main display** screenshot to a PNG file you specify
- Prints **safe JSON metadata** to stdout (path, sha256, dimensions, display id, timestamp)
- Checks **Screen Recording** permission without capturing when `--check-permission` is passed

### What it does not do

- No menu bar UI, selection overlay, or annotation editor
- No clipboard writes, file deletion, uploads, or base64 image output
- **No mouse, keyboard, browser, or app control** — read-only screenshot observe only

### Build

```bash
xcodebuild -project capture-your-screen.xcodeproj -scheme capture-screen-helper -configuration Release build
```

Or use the helper script (also runs argument-parser self-tests):

```bash
bash scripts/build_helper.sh
```

Install the built binary wherever Conveyor expects it, for example:

```bash
cp .derivedData/Build/Products/Release/capture-screen-helper /usr/local/bin/
```

### Usage

Check permission:

```bash
capture-screen-helper --check-permission --json
```

Capture once:

```bash
capture-screen-helper --mode full-display --display main --output /absolute/path/screenshot.png --json
```

Supported flags in this release: `--mode full-display`, `--display main`, `--output`, `--json`, `--check-permission`. Other flags return non-zero exit with safe JSON.

### Screen Recording permission

macOS requires **Screen Recording** permission. If it is missing, the helper returns:

```json
{
  "ok": false,
  "error": "screen_recording_permission_required",
  "message": "Screen Recording permission is required.",
  "hint": "Open System Settings → Privacy & Security → Screen Recording"
}
```

Grant permission for `capture-screen-helper` (or the terminal app you run it from) in **System Settings → Privacy & Security → Screen Recording**.

### Manual permission test (not suitable for CI)

1. Build the helper.
2. Run `--check-permission --json` before granting permission — expect `screen_recording_permission: denied`.
3. Enable Screen Recording for the helper in System Settings.
4. Run a capture to an absolute path under `/tmp` — expect `ok: true` and a PNG on disk.
5. Confirm the helper refuses relative paths and existing output files.

Automated capture tests are not run in CI because headless runners typically lack Screen Recording consent.