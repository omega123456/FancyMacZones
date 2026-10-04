# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

FancyMacZones is a FancyZones-style window-zone app for macOS 26 on Apple Silicon: right-click while dragging a window to show zones and drop it into one, drag to the top edge to maximize, Ctrl+Cmd+Arrow to move the focused window to the adjacent zone. It is an `LSUIElement` menu bar agent (`local.fancymaczones`) for personal use: self-signed, not sandboxed, not notarized. It is a single SwiftPM executable target that uses system frameworks only (no dependencies, never SwiftUI), with Swift 6.3 Command Line Tools and no Xcode. `Package.swift` pins Swift language mode v5.

## Commands

```sh
swift build                                 # debug build (compile check)
swift run FancyMacZones --self-test         # pure-logic checks; exits before any UI, non-zero on failure
./scripts/build-app.sh                      # debug "FancyMacZones Dev" build → sign → quit running copies (prod too) → install to ~/Applications → launch
./scripts/build-app.sh --log-events         # extra args are passed to the app
BUNDLE_ONLY=1 ./scripts/build-app.sh        # signed production bundle .build/FancyMacZones.app, not installed (CI)
tail -f ~/Library/Logs/FancyMacZones\ Dev/events.log
pkill -x FancyMacZonesDev; open /Applications/FancyMacZones.app   # back to production
./scripts/release.sh                        # (owner runs it) bump Info.plist version, verify, commit, tag vX.Y.Z, push → .github/workflows/release.yml
```

- **Sandbox:** SwiftPM fails inside the Claude Code Bash sandbox. `.claude/settings.local.json` excludes `swift build`, `swift run`, `swift package` and `./scripts/build-app.sh`, but only when the command is exactly one of these. Don't pipe, chain or prefix them (`|`, `&&`, `cd … &&`). `BUNDLE_ONLY=1 ./scripts/build-app.sh` is not exempt (the env prefix): inside the sandbox it reports the signing identity as missing, so run it with the sandbox disabled.
- **App icon:** `scripts/make-icon.swift` draws `Resources/AppIcon.icns` (committed). Build it inside the sandbox, run it with the sandbox disabled (`iconutil` silently fails inside it):
  ```sh
  swiftc -module-cache-path "$TMPDIR/mc" scripts/make-icon.swift -o "$TMPDIR/make-icon"
  "$TMPDIR/make-icon"     # sandbox disabled; pass the sandbox's TMPDIR if it differs
  ```
- **No test framework** (XCTest isn't available with CLT only). `--self-test` is the whole suite. To add coverage, add a `check(...)` in `Sources/FancyMacZones/SelfTest.swift`. It counts failures explicitly, because `assert` is compiled out of release builds.
- **Dev vs production:** production is `/Applications/FancyMacZones.app` (`local.fancymaczones`, from the DMG, self-updating). `build-app.sh` builds **FancyMacZones Dev**: a debug build with bundle ID `local.fancymaczones.dev` and executable `FancyMacZonesDev`, so UserDefaults, the login item and TCC grants are separate. `#if DEBUG` gates the dev behaviour: no updater, its own log folder (`FancyMacZones Dev`) and its own Application Support folder (`~/Library/Application Support/FancyMacZones Dev/layouts.json`).
- **Never run the binary directly** (`.build/.../FancyMacZones`) for real use. TCC would check permissions against the terminal. Launch the installed app with the script or `open ~/Applications/FancyMacZones\ Dev.app`.
- `scripts/make-cert.sh` is interactive (keychain password, trust dialog). The owner runs it in Terminal.app, not you. It creates the "FancyMacZones Local Signing" identity, which keeps the Accessibility grant valid across rebuilds.
- `--log-events` writes to a file because the sandbox blocks `/usr/bin/log`. The log holds window titles and app names in clear text.

## Architecture

All work runs on the main thread and is event-driven. The data flows one way:

```
            CGEvent session tap (mouse buttons only)          Carbon hotkeys (⌃⌘ arrows)
                    │ callback: flags, swallow, y-rewrite          │
                    │ async delivery to main thread                │
                    ▼                                              ▼
 ┌──────────────────────────── Snapper ─────────────────────────────────────┐
 │ drag session state machine · window-drag confirmation (WindowServer)     │
 │ top hot spot · overlap rule · directional/band/wrap target · zone match  │
 └──────┬──────────────────────┬─────────────────────────────┬──────────────┘
        │ reads zones          │ shows/hides                 │ frame writes
        ▼                      ▼                             ▼
   LayoutStore ◄──┐       ZoneOverlay (one panel)        AX helper (size→position→size,
   (JSON file,    │                                       Enhanced UI off/on)
    assignments)  │ edits
        ▲         │
        │   MenuBar (NSStatusItem, menu built on open) ──► EditorWindow ──► Full-screen Grid/Canvas editor
        │                                                  (created on demand, released on close)
   Layouts (pure model: templates, grid, canvas, geometry, editing operations, decisions)

 AppDelegate: Accessibility trust gating · wiring · Updater · LaunchAtLogin · EventLog
```

`AppDelegate` (`App.swift`) gates everything on Accessibility trust. While untrusted it polls every 1 s and the menu shows the untrusted variant.

Cross-cutting rules that need several files to see:

- **Tap callback discipline (DD-1):** the event-tap callback makes no inter-process calls (no AX, no WindowServer), no file I/O and no heavy allocation. It reads event fields, flips flags, swallows or rewrites events, and queues the rest to the main thread. It re-enables itself only while `AXIsProcessTrusted()` holds.
- **All geometry lives in `Layouts.swift` (DD-14, ADR efee8860):** templates, grid and canvas editing, numbering, overlap rules, current-zone matching, directional targets, the top band, exposed top edges, the Mission Control decision and coordinate conversion. Views and Snapper only translate input into these operations and draw the results. **Escalation:** if an operation is missing or wrong, stop and report it to the owner; never put geometry rules in view or Snapper code. Phases 2 and 3 must not modify `Layouts.swift` or `LayoutStore.swift`.
- **Pure logic is kept as `static func`s or value types** so `SelfTest` can cover it without UI. New decision logic follows this pattern.
- **AX access goes through `AX.swift`.** Reads return nil on ordinary failures and throw only `AXFailure`. The global AX messaging timeout is 0.25 s. Frame writes are attempted once and failures are logged, never retried in a loop.
- **Private APIs are resolved with `dlsym` and degrade gracefully.** `_AXUIElementGetWindow` is optional: without it the app's focused window is used. No SkyLight or CGS calls.
- **Idle cost (NFR-1):** no periodic timers except the hourly update check (production only) and the 1 s trust poll, which runs only while untrusted. No AX observers. The menu is built only when it opens (DD-11).
- **Persistence (DD-10, ADR 60d109d4):** `layouts.json` is read once at launch and written atomically once per committed change (requirement 29), never during a drag. Scalar settings live in UserDefaults (`Settings` in `LayoutStore.swift`).
- **Coordinates:** zones are stored as fractions of `NSScreen.visibleFrame` with a top-left origin. AX and CGEvent use top-left global coordinates; Cocoa uses bottom-left. Convert with `Layouts.cocoaRect(fromAX:primaryHeight:)`, `axRect(fromCocoa:)`, `cocoaPoint(fromCG:)` and `place(_:in:)`.
- **Visuals (DD-15, ADR b945ef79):** macOS-native, system accent and semantic colours, light and dark, Increase Contrast and Reduce Transparency honoured. `ZoneStyle` / `ZoneView` in `ZoneOverlay.swift` are shared by the overlay and the editors. No animations.
- Code comments cite "requirement N" (R-N) and "DD-N". These refer to `.agent/plans/2026-10-03_fancymaczones_plan.md`, which holds the full spec, the wireframes and the reasons behind the constants. Its mockup is in `.agent/plans/assets/`.

## Architectural decisions (binding)

`.agent/adr/` is an append-only decision ledger, governed by `.agent/ADR_POLICY.md`. Never edit or delete an existing ADR. To reverse one, write a new ADR with a `## Relationship to previous decisions` section. Read the relevant ADR before you change:
- drag detection, the event tap or window-drag confirmation (33afa74d, ff615fc0)
- frameworks, hotkeys or the editor UI technology (d4a25cde)
- persistence (60d109d4)
- zone geometry versus WinBar's bar (838bb49a)
- theming (b945ef79)
- where geometry and editing rules live (efee8860)

## Verifying behaviour

Acceptance criteria are tagged **[agent]** (builds, `--self-test`, file contents, `codesign`/`plutil` output, `--log-events` lines read from the log file) or **[owner]** (live UI, two displays, Accessibility grants, VoiceOver, Activity Monitor, Mission Control).

- The owner keeps using the desktop while agents work. Only use windows you created: **TextEdit** opened on an empty scratch file (`open -a TextEdit <scratchpad>/t.txt`, so no Open panel appears). Never use Calculator: its fixed size refuses size writes.
- `open`, `pgrep`, `top`, `screencapture`, `/usr/bin/log` and posting CGEvents need the sandbox disabled, which auto mode may deny; report such checks as not verified rather than forcing them. The agent's own process is not Accessibility-trusted, so it can't drive the app's menu through AX.
- Probing techniques and their limits from WinBar: `~/Projects/WindowsTaskbarForMac/.claude/agent-memory/dev-workflow-phase-implementer/` (`verification-techniques.md`, `verification-limits.md`). Synthetic mouse down and up need about 150 ms between them.
