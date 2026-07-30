# Post-Capture Workflow — Manual Acceptance Test Report

Date: 2026-07-30 (00:54–04:05 EDT) · Commit under test: `62285be` ("Refactor post-capture workflow and services", HEAD → main, pushed)

**Honesty statement.** During this acceptance window the Mac's GUI session became **locked** (`CGSSessionScreenIsLocked = 1`, locked since ~03:17 EDT, verified via `CGSessionCopyCurrentDictionary`). A locked session makes real window interaction, keyboard shortcuts, share sheets, screenshots, and UI scripting impossible, and it also caused the XCTest GUI test-host bootstrap to hang on every post-lock run. Everything below is therefore explicitly separated into (A) directly verified, (B) verified by code inspection only, (C) requires a human at the unlocked machine.

---

## 1. Environment

| Item | Value |
|---|---|
| macOS | 26.5.1 (25F80) |
| Xcode | 26.6 (17F113) |
| Architecture | arm64 (Apple Silicon) |
| Displays | 1 × Built-in Liquid Retina XDR, 3456×2234 (no secondary display available) |
| Configuration | Debug |
| Scheme | `capture-your-screen` |
| Screenshot folder | `/Users/dogecoin/Pictures/Screenshots` (day-subfolders; 108 PNGs before and after testing — unchanged) |
| Global hotkey | ⇧⌘A (default `kVK_ANSI_A + cmdKey|shiftKey`) |
| GUI automation | **Unavailable** — session locked; `osascript`/System Events probe hung and was killed (exit 137). No Accessibility-based UI scripting possible in this window. |

## 2. Baseline architecture found (Phase 1 — all 14 files read in current form)

- **State machine**: `CaptureCoordinator.CaptureState = idle / capturing / reviewing / annotating / sharing / saving` (Equatable, `@Published private(set)`).
- **Normal capture path**: hotkey → `startCapture()` (folder + TCC permission gates) → overlay → `finishCapture` → async `ScreenCapture.captureRegion` guarded by `captureGeneration` → `beginReview()` → creates `PostCaptureSession`, `state = .reviewing`, presents panel. **Nothing copied or saved at this point** (verified in code: `beginReview` touches neither clipboard nor persistence).
- **Quick Save path**: overlay `onQuickSave` → `quickSaveCapture` → `state = .saving` → capture → `performQuickSaveCompletion` = clipboard write + `persistScreenshot` + notification → idle. **Never creates a session, never shows the panel.**
- **Session ownership**: `activeSession: PostCaptureSession?` — sole strong owner of the captured `NSImage`; `beginReview` refuses a second session (`guard activeSession == nil`); released only in `clearSessionToIdle()`.
- **Stale-callback rejection**: every handler and `completeSession` starts with `guard activeSession?.id == sessionID`; `completeSession` re-checks the ID *after* the async save and *after* the success-dismiss sleep. Capture tasks use a separate monotonic `captureGeneration` token.
- **Duplicate prevention**: `isProcessingAction` flag blocks concurrent actions at the coordinator; `PostCapturePanelModel.isBusy` disables all buttons (incl. hidden shortcut buttons) during `.processing`/`.success`; all four terminal paths (Copy / Annotate-Save / Skip / Share) funnel into the single private `completeSession(id:image:copyToClipboard:feedback:)`.
- **Window ownership**: `PostCaptureActionPanelController` owns the one `PostCaptureActionWindow` (NSPanel, floating, `.moveToActiveSpace + .fullScreenAuxiliary`); `AnnotationEditorPresenter` owns the one `AnnotationEditorWindow`; both `present()` methods call `dismiss()` first so two windows can never coexist; coordinator owns `overlayWindow`.
- **Native close routing**: both controllers implement `windowWillClose`; programmatic `dismiss()` nils references *before* `close()` so only a user-initiated close fires the cancel handler. Panel close → session cancel; editor close → annotation cancel → back to panel.
- **Action wiring**: panel emits via `PostCaptureActionHandlers` closures capturing the session UUID → `handleCopy/handleAnnotate/handleShare/handleCancel(sessionID:)`. Annotation editor emits via `AnnotationEditorHandlers` (`onSave/onSkip/onCancel`), mapped from the existing `AnnotationEditorView(onSave:onSaveOriginal:onCancel:)`.
- **Changes outside the feature**: `StorageResolver.swift` — adds `folderPathKey` plain-path persistence + two-tier fallback (saved path, then old-key migration) when bookmark resolution fails; adds `loadString/saveString` to `BookmarkStorage`. `capture_your_screenApp.swift` — one-line startup tweak (`refreshHistory` + start folder watcher + permission refresh in a launch Task). **No discrepancies found** between the code and the previous implementation summary; one behavior note: `hasValidFolder` reloads only when `cachedIsStale` (see §8).

## 3. Build and tests (Phase 2)

- Build command: `xcodebuild -project capture-your-screen.xcodeproj -scheme capture-your-screen -configuration Debug -destination 'platform=macOS' build`
- Test command: `xcodebuild -project capture-your-screen.xcodeproj -scheme capture-your-screen -destination 'platform=macOS' test`
- **Build result: BUILD SUCCEEDED** (full recompile of every Swift file, 2026-07-30 04:03 EDT).
- **Compiler warnings: 3, all pre-existing, none in new post-capture files**:
  - `Core/HotkeyManager.swift:96` — var never mutated
  - `Core/ScreenshotStore.swift:148` — captured var `self` in concurrent code
  - `Core/StorageResolver.swift:188` — main-actor init in nonisolated context
- **Test result (directly observed, 02:11 EDT run, session unlocked, sandbox escalation approved): `result: Passed — total: 44, passed: 44, failed: 0, skipped: 0`.** Suites: PostCaptureWorkflowTests (24), StorageResolverTests (11), HistoryDayGroupingTests (3), HistoryThumbnailPerfTests (6).
- Sandbox limitation: inside the command sandbox, Automatic signing cannot write the login keychain (`login.keychain-db.sb-*` file-write-create denied) → test runner never bootstraps. All test runs were executed **outside** the sandbox with explicit approval.
- Post-lock limitation: every rerun after ~03:17 EDT failed with "The test runner hung before establishing connection"; process sampling showed the GUI test host healthy in its event loop — the locked session prevents XCTest attachment. The 02:11 44/44 xcresult was directly observed by me earlier this same session; the bundle itself was later rotated out by the failed rerun logs.

## 4. Manual test matrix

Result legend: **DV** = directly verified now · **CI** = code inspection only · **AT** = covered by an automated test I observed passing (44/44 run) · **NT** = not tested, needs human.

| ID | Scenario (Phase) | Expected | Observed | Result | Evidence | Issue |
|---|---|---|---|---|---|---|
| T01 | Clean setup: quit stale instances (P3) | 0 instances before relaunch | Stale PID 42939 (old build) terminated via SIGTERM; `pgrep` → none | Pass (DV) | pgrep output | — |
| T02 | Launch Debug app, single instance (P3) | 1 instance | PID 22116, instance count = 1 | Pass (DV) | pgrep count | — |
| T03 | Menu-bar utility, no Dock icon (P3) | UIElement | `lsappinfo` → `ApplicationType="UIElement"` | Pass (DV) | lsappinfo | — |
| T04 | No startup errors (P3) | clean log | `log stream` filtered: no error/fail lines from app | Pass (DV) | /tmp/applog.txt | — |
| T05 | Folder accessible & baseline count (P3) | folder valid | 108 PNGs before; 108 after all testing (no accidental writes) | Pass (DV) | find count | — |
| T06 | Hotkey registered (P3) | ⇧⌘A active | Registration code path + `ensureRegistered()` at launch; cannot observe Carbon registration externally in locked session | Partial (CI) | HotkeyManager.swift | — |
| T07 | Permission granted flow (P4) | capture starts, no redundant alert | `startCapture` refreshes TCC, only alerts when not granted; `applicationDidBecomeActive` re-checks | Not Tested manually (CI) | CaptureCoordinator:102-110 | — |
| T08 | Permission denied flow (P4) | blocked + alert + Settings deep link | Guarded return before overlay; `showPermissionAlert()` | NT (CI) | PermissionManager | — |
| T09 | Normal capture → reviewing, no copy/save/editor, one session, one panel (P5) | per spec | `testNormalCapture_entersReviewingState`, `_doesNotImmediatelySaveCopyOrAnnotate`, `_retainsImageInSession`, `testOnlyOneActiveSessionAtATime` all passed | Pass (AT) + NT for real-GUI look | 44/44 run | — |
| T10 | 2nd hotkey during review does not overlap (P5) | re-front panel, no new session | `startCapture` early-returns re-fronting panel when `.reviewing`; `beginReview` guards `activeSession == nil` | Pass (AT/CI) | CaptureCoordinator:89-93 | — |
| T11 | Panel on capture display, key window, preview fidelity (P5/P6) | per spec | Positioning code centers on `sourceDisplayID` screen; cannot see real window | NT (CI) | PostCaptureActionWindow:109-123 | — |
| T12 | Panel visual quality light/dark (P6) | per spec | Not renderable in locked session | NT | — | — |
| T13 | Button subtitles rendered? (P6) | subtitles visible | **Subtitles are NOT rendered** — `actionButton(title:subtitle:...)` label shows icon+title only; subtitle appears only in hover `.help()` tooltips | **Fail-as-designed → reported** (CI, conclusive from code) | PostCaptureActionView:203-232 | I-02 |
| T14 | Copy: click/⌘C/Return → copy+save once, success, dismiss, idle (P7) | per spec | `testCopy_copiesOnceSavesOnceAndReturnsToIdle` passed; clipboard content fidelity + real keyboard untested | Pass (AT) + NT paste-verify | 44/44 run | — |
| T15 | Rapid duplicate Copy (P8) | one file, one record | `testCopy_repeatedTapsDoNotSaveTwice`, `testSecondActionCannotRunWhileFirstIsProcessing` passed; `isBusy` disables buttons incl. hidden shortcuts | Pass (AT) + NT real double-click | 44/44 run | — |
| T16 | Clipboard failure (P9) | no save, panel stays, retry works | `testCopy_clipboardFailureKeepsSessionRecoverable` passed — clipboard-first ordering means save is skipped on copy failure | Pass (AT) | 44/44 run | — |
| T17 | Save failure after clipboard success (P9) | honest partial message, retry no duplicates | `testCopy_saveFailureReportsPartialSuccessAndAllowsRetryWithoutDuplicates` passed; message = "Copied to the clipboard, but saving to disk failed."; retry re-copies then saves (see §5 note, I-04) | Pass (AT) | 44/44 run | I-04 (note) |
| T18 | Annotate entry: panel closes, editor opens, nothing saved (P10) | per spec | `testAnnotate_opensEditorWithoutSaving` passed; annotation tools themselves not exercised | Pass (AT) + NT tools | 44/44 run | — |
| T19 | Annotate+Save: only annotated image saved once (P11) | per spec | `testAnnotationSave_savesAnnotatedImageExactlyOnce` passed; real compositor output not visually compared | Pass (AT) + NT visual | 44/44 run | — |
| T20 | Skip Annotation: original saved once (P12) | per spec | `testAnnotationSkip_savesOriginalImageExactlyOnce` passed; ⌘↩ shortcut exists in editor | Pass (AT) | 44/44 run | — |
| T21 | Cancel Annotation ×3: back to panel, no dupes (P13) | per spec | `testAnnotationCancel_returnsToReviewingWithPanelAndSavesNothing`, `_thenCopyStillWorks` passed; presenters dismiss-before-present prevent duplicates; native close → cancel via `windowWillClose` | Pass (AT/CI) + NT real windows | 44/44 run | — |
| T22 | Share: picker appears anchored, no LAN/cloud (P14) | per spec | `NSSharingServicePicker(items:[image])` only, anchored to panel contentView; zero networking code in diff | Pass (CI — networking absence conclusive) + NT picker UI | NativeScreenshotSharingService | — |
| T23 | Share picker dismissed (P14) | session recoverable, no error | `testShare_cancellationReturnsToReviewingWithoutErrorOrSave` passed | Pass (AT) | 44/44 run | — |
| T24 | Share service selected (P14) | ≤1 save, defined success point | `testShare_callsServiceWithSessionImageAndSavesOnce` passed. Success point = **service chosen in picker** (delegate `didChoose != nil`), NOT delivery. UI then says "Shared and saved to history" — see wording finding I-03 | Pass (AT) | 44/44 run | I-03 |
| T25 | Share unavailable/failure (P14) | clear recoverable error | `testShare_unavailableServiceProducesClearError`, `testShare_failureKeepsSessionRecoverable` passed | Pass (AT) | 44/44 run | — |
| T26 | Cancel via button/Esc/native close (P15) | nothing written, idle, no delayed save | `testCancel_discardsSessionWithoutSavingOrCopying`, `testCancelActiveSession_cleansAllWindowsAndState` passed; folder count unchanged (108) after entire window | Pass (AT+DV folder count) | 44/44 run | — |
| T27 | Quick Save regression (P16) | copy+save once, no panel, notify, idle | `testQuickSave_copiesOnceSavesOnceAndSkipsPanel` passed | Pass (AT) + NT real overlay gesture | 44/44 run | — |
| T28 | History integration after each terminal path (P17) | records/thumbnails update | `save()` inserts record + publishes thumbnail; FolderWatcher refreshes; HistoryDayGrouping/ThumbnailPerf suites passed | Pass (AT/CI) + NT UI | 44/44 run | — |
| T29 | Storage folder persistence across relaunch (P17) | same folder, no picker | StorageResolverTests (11) incl. `testSaveAndResolveBookmark`, `testStaleBookmark_reResolvesOnAccess`, `testSwitchingFolder_changesResolvedURL` passed; real quit/relaunch cycle not performed | Pass (AT) + NT relaunch | 44/44 run | — |
| T30 | Old-path migration (P17) | no auto-grant, valid recovery | `testOldPathMigration_doesNotAutoGrantAccess`, `testCorruptedBookmarkData_doesNotCrash`, `testNoBookmark_returnsFolderNotSelected` passed | Pass (AT) | 44/44 run | — |
| T31 | Multi-display (P18) | panel on capture display | **Hardware unavailable (1 display)**; positioning falls back `sourceDisplayID → main → first` without force-unwraps | NT (CI fallback safe) | PostCaptureActionWindow:109-123 | — |
| T32 | Spaces / full-screen (P19) | panel in active Space | `.moveToActiveSpace + .fullScreenAuxiliary` + floating level set | NT (CI) | PostCaptureActionWindow:32 | — |
| T33 | Keyboard & focus matrix (P20) | shortcuts scoped to panel | Shortcuts are SwiftUI `keyboardShortcut` buttons inside the panel — they exist only while the panel window exists; **no local/global event monitors are installed anywhere in the new code** (grep-verified), so nothing can leak | Pass (CI — monitor absence conclusive) + NT real keys | PostCaptureActionView:236-249 | — |
| T34 | 20× repeated-session stress (P21) | no leaks/slowdown | `testEveryTerminalPathAllowsANewSession` covers all terminal paths returning to a reusable idle; real 20× GUI loop not possible | Partial (AT) + NT | 44/44 run | — |
| T35 | Stale callback validation (P22) | Session A can't finish Session B | `testStaleCallback_cannotFinishNewerSession`, `testStaleAnnotationCallback_isRejected` passed | Pass (AT) | 44/44 run | — |
| T36 | Stuck-state audit (P23) | none of the 7 stuck states reachable | Code audit per state (see §5, I-01 for the one gap found: reviewing-with-no-panel after ⌘W during processing is prevented by disabled close? → analyzed, not reproducible: NSPanel close button is disabled only via isBusy on Cancel button, but native close during `.saving` fires `handleCancel` which is guarded by `isProcessingAction` → panel closes while state=.saving → completeSession still finishes and dismisses → terminal OK; documented as edge behavior, not a stuck state) | Pass (CI) | analysis | — |
| T37 | Wording audit (P24) | honest labels | See §7 | Reported | — | I-02/03/05 |

## 5. Bugs found

**No reproducible P0 or P1 defect was found.** Nothing met the fix policy bar ("do not change code before reproducing a problem" — the locked session prevented GUI reproduction, and no automated test exposes a defect). The following are findings, not fixed code changes:

- **I-01 · P2 · Native close during an in-flight action leaves panel gone while session finishes in background.** Repro (by analysis): click Copy → while `.saving`, click the panel's red close button. `windowWillClose` fires `onCancel` → `handleCancel` is (correctly) rejected because `isProcessingAction == true`, but the window itself has already closed. `completeSession` then completes the save, tries `panelPresenter.showStatus(.success)` on a nil model (harmless no-op), skips the dismiss-delay (`isPresenting == false`), and cleanly reaches idle with the file saved. Outcome: **no data loss, no stuck state, no double-save** — but the user sees the panel vanish with no confirmation that the copy/save finished (the panelStatus feedback path posts no notification). Root cause: `PostCaptureActionWindow` does not block the native close button while `model.isBusy`. Files: `PostCaptureActionWindow.swift` (`windowShouldClose` not implemented), `CaptureCoordinator.completeSession`. Fix status: **not fixed — reported as a product decision** (either disable close while busy via `windowShouldClose`, or fall back to a notification when the panel is already gone).
- **I-04 · P2 (risk note) · Retry after "copied but save failed" re-runs the clipboard write.** `handleCopy` retry goes through `completeSession(copyToClipboard: true)` again; if the clipboard now fails on the retry, the user gets "couldn't copy" even though the image from the first attempt may still be on the pasteboard. No duplicate file can result (verified by `testCopy_saveFailureReportsPartialSuccessAndAllowsRetryWithoutDuplicates`). Fix status: not fixed — acceptable, flagged per the task's request to "flag that risk".

## 6. Fixes made

**None.** No P0/P1 was reproducible; per the task rules ("Do not change code before reproducing a problem", "Keep fixes minimal") and the GUI lock preventing reproduction, I made zero source changes. Working tree remains identical to committed `62285be` (git status clean before and after).

## 7. UI and wording findings

- **Button subtitles do NOT render (I-02, P2/P3)**: `PostCaptureStrings.copySubtitle` ("Copy to Clipboard"), `annotateSubtitle` ("Mark up before saving"), `shareSubtitle` ("Send or share this screenshot") are passed into `actionButton(title:subtitle:...)` but the button label renders only icon + title; subtitles surface solely as hover tooltips (`.help`). Conclusive from code. Not redesigned per instructions — recommend either rendering the subtitle as a second caption line or removing the dead parameter.
- **`Copy` label vs actual behavior (I-05, product wording decision)**: Current behavior = copy to clipboard **and** save to history. Current label = `Copy`. The ready-state hint and tooltip ("Copy to Clipboard and save to history (⌘C or ↩)") mitigate but the button itself under-describes. Recommendation: **`Copy & Save`** — it matches the actual dual behavior best; "Save and Copy" inverts the user's mental primary intent; bare "Copy" hides the disk write, which matters for user trust. Not changed without your decision.
- **Share success wording overclaims (I-03, P2)**: success point in code is *service chosen in the picker* (`didChoose != nil`), yet the panel then shows **"Shared and saved to history"**. AppKit does not expose final delivery, so "Shared" is not verifiable. Recommend `PostCaptureStrings.sharedAndSaved` → "Sharing opened · Saved to history" (or similar). One-string change; not made without approval since it's P2 wording.
- **Cancel clarity**: button label "Cancel" + tooltip "Discard this screenshot (esc)" — the tooltip is honest; the label alone doesn't say "discard". Acceptable; consider "Discard" if you want zero ambiguity.
- **Annotation Cancel semantics**: editor button just says "Cancel"; nothing tells the user they will *return to the action panel* rather than lose the screenshot (the behavior is the safe one; the labeling just undersells it). P3.
- **Light/dark visual quality**: not inspectable in a locked session — requires human (all colors are semantic/system colors in code, so no hardcoded-color red flags).

## 8. Storage migration findings

- 11/11 `StorageResolverTests` passed in the observed 44/44 run (bookmark save/resolve, stale re-resolution, corrupted-data no-crash, old-path no-auto-grant, path containment, folder switching).
- New behavior in `62285be`: a plain `screenshotFolderPath` string is persisted alongside the security-scoped bookmark, and `loadBookmark()` gains two fallbacks (saved path → old key) that both attempt to mint a fresh bookmark. **Note for a sandboxed app**: minting a bookmark from a raw path only works where the sandbox already permits access; the fallback is best-effort and correctly ends with `cachedResolvedURL = nil` when it can't.
- Behavior note (not a bug): `hasValidFolder` re-resolves only when `cachedIsStale` is true; a folder deleted mid-session is discovered at `prepareFolder()` (throws `folderCreationFailed`/access error) rather than at the pre-capture gate. Failure surfaces through the existing recoverable error path.
- Real quit → relaunch persistence cycle and live old-path migration: **NT — requires human** (locked session; also avoided mutating real preference data per instructions).

## 9. Multi-display and full-screen findings

- **Directly tested: nothing** — one physical display, locked session.
- Code inspection: panel targets the capture display via `sourceDisplayID`, with nil-safe fallback chain to `NSScreen.main`/first — display disconnect mid-review cannot crash positioning (no force-unwraps). `collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]` + `.floating` level is the correct recipe for appearing in the active Space and over full-screen apps. Overlay capture math and annotation-window placement were not re-audited (out of scope, pre-existing).

## 10. Remaining limitations

- Native `NSSharingServicePicker` cannot report final delivery; the implementation (documented in `ScreenshotSharing.share` doc-comment) defines "service chosen" as success. Future LAN sharing must define its own success point (transfer completion) — the current UI string habit of "Shared and saved" would be even more misleading there (see I-03).
- Untested on hardware: multi-display, permission-denied TCC flows, Spaces/full-screen, real keyboards/VoiceOver, real share sheet.
- GUI automation unavailable this session: screen locked from ~03:17 EDT; System Events probe killed (exit 137); XCTest GUI host cannot bootstrap while locked.
- Test execution requires escaping the command sandbox (Automatic signing needs login-keychain write).
- Risk relevant to LAN sharing: `NativeScreenshotSharingService` holds a single continuation — a second concurrent `share()` throws "already in progress"; a LAN implementation must keep that invariant or queue.

## 11. Release recommendation

**CONDITIONAL PASS — fix listed P2 issues first is *not* required for LAN work; strictly: PASS with human-verification caveat.** Choosing per the required options: **CONDITIONAL PASS** — proceed to LAN-sharing implementation only after a human performs the short GUI checklist that this environment could not: (1) one normal capture → panel look/preview/dimensions in light+dark, (2) Copy with paste-verify, (3) Annotate → Cancel → Copy cycle, (4) Share picker open/cancel/choose with a safe target, (5) quit→relaunch folder persistence. Rationale: all 24 workflow unit tests + 20 existing tests were observed passing (44/44) before the session locked; the build is clean (3 pre-existing warnings, none in new code); code audit found no P0/P1, no stuck states, no networking; the only open items are wording (I-03, I-05), non-rendered subtitles (I-02), and the close-while-busy feedback gap (I-01) — all P2/P3 and none block LAN-sharing work.

## 12. Final repository state

- HEAD: `62285be` on `main`, pushed to `origin/main`. **Working tree clean** (git status empty before and after this acceptance pass — no source changes made; this report file is the only new artifact).
- Files modified during acceptance: none (report + memory notes only).
- Tests: 44/44 passed in the directly observed 02:11 EDT run; post-03:17 reruns blocked by locked GUI session (environmental, evidence in §3).
- Unresolved issues: P0 — none; P1 — none; P2 — I-01 (close-while-busy silent finish), I-02 (subtitles not rendered), I-03 (share wording overclaim), I-04 (retry re-copy risk note); P3 — annotation-cancel labeling.
- **No LAN-sharing, QR, Bonjour, networking, or cloud-upload code exists in the diff or was added** (grep-verified: no URLSession/Network/NWListener/Bonjour references in the feature files).
