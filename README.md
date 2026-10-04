# FancyMacZones

FancyZones-style window zones for macOS 26 on Apple Silicon. Each display has its own layout of zones:

- **Drag snapping:** while dragging a window, right-click to show the zones of the display under the cursor, then release over a zone to snap the window into it. Right-click again to hide them.
- **Maximize:** drag a window to the top edge of a display to maximize it (no right-click needed).
- **Keyboard:** **⌃⌘ ←→↑↓** moves the focused window to the adjacent zone, across displays, wrapping around.
- **Layouts:** templates (Blank, Focus, Columns, Rows, Grid, Priority Grid) and custom Grid and Canvas layouts, chosen per display from the menu bar item.

It is a menu bar agent app with no Dock icon, built for a minimal footprint: it does essentially nothing while idle. It is for personal use only: self-signed, not sandboxed, not notarized.

Requirements: Swift 6.3 Command Line Tools (Xcode is not needed) and the macOS 26 SDK.

## One-time setup (per Mac)

1. **Create the signing identity.** Run this in **Terminal.app**, not through Claude Code:
   ```sh
   ./scripts/make-cert.sh
   ```
   It creates the self-signed "FancyMacZones Local Signing" code-signing identity in your login keychain. It asks for your login keychain password (hidden input) and shows a system dialog to trust the certificate. Because the identity is stable, the Accessibility grant survives rebuilds. The script is safe to re-run: it exits if the identity already exists. Check the result with:
   ```sh
   security find-identity -v -p codesigning
   ```
2. **Keep macOS's own tiling off.** In System Settings → Desktop & Dock → Windows, turn off **Drag windows to screen edges to tile** and **Drag windows to menu bar to fill screen**. They compete with FancyMacZones's top-edge maximize. To check:
   ```sh
   defaults read com.apple.WindowManager EnableTilingByEdgeDrag      # 0
   defaults read com.apple.WindowManager EnableTopTilingByEdgeDrag   # 0
   ```
3. **Grant Accessibility.** FancyMacZones prompts at launch. Enable it in System Settings → Privacy & Security → Accessibility. The menu bar icon shows a warning triangle until then, and switches to the zones icon within about a second of the grant, without a relaunch. FancyMacZones Dev and production are separate apps to macOS and need separate grants.

## Build, install and run

Production FancyMacZones is installed from the release DMG into `/Applications/FancyMacZones.app` and updates itself (see [Releases and updates](#releases-and-updates)). A local build is a separate development copy, **FancyMacZones Dev**, so testing never touches production:

```sh
./scripts/build-app.sh
```

The script does the following:
1. Builds in debug mode. Debug builds compile in the dev-only behaviour: no update checks, and the event log and `layouts.json` go to their own `FancyMacZones Dev` folders.
2. Assembles `.build/FancyMacZones Dev.app` with bundle ID `local.fancymaczones.dev` and executable `FancyMacZonesDev`, and signs it with "FancyMacZones Local Signing". Settings and Launch at Login are kept separately from production, because they belong to the bundle ID.
3. Quits any running FancyMacZones, production included, because two copies would both snap.
4. Installs the app to `~/Applications/FancyMacZones Dev.app` and removes the build copy, so only one bundle with ID `local.fancymaczones.dev` exists.
5. Launches the app.

Any extra arguments are passed on to the app, for example `./scripts/build-app.sh --log-events`. `BUNDLE_ONLY=1 ./scripts/build-app.sh` builds and signs the production bundle `.build/FancyMacZones.app` without installing it (the release workflow uses this).

To go back to production:

```sh
pkill -x FancyMacZonesDev; open /Applications/FancyMacZones.app
```

Always launch the installed app (with the script, or with `open`). Do not run the binary directly from a terminal: macOS would check permissions against the terminal instead of FancyMacZones.

To run the self-test of the pure logic (it exits before any UI, and a failure gives a non-zero exit status):

```sh
swift run FancyMacZones --self-test
```

## Usage

- **Snap by dragging.** Start dragging a window by its title bar. While the left button is held, **right-click** to toggle the zone overlay. The highlighted zone (accent fill with a ✓ on its number) is where the window will land; release to snap. The right-click never reaches the app under the cursor. If zones overlap, **Overlap Rule** in the menu decides which one wins: the smallest zone (default) or the one whose centre is closest to the cursor.
- **Maximize.** Drag a window to the top edge of any display. A preview covers the usable area; release to maximize. Turn this off with **Drag to Top to Maximize**. **Prevent Mission Control While Dragging** (on by default) stops a hard upward flick against the top edge from opening Mission Control during a window drag.
- **Move with the keyboard.** **⌃⌘ ←→↑↓** moves the focused window to the next zone in that direction, over all displays. With no zone ahead it wraps around to the farthest zone the other way. Zones must overlap the window's current zone along the other axis: with Columns layouts, ↑ and ↓ do nothing.
- **Choose layouts.** The menu bar item lists each display with its layout; pick a template or a custom layout from its submenu. With a single display the row reads "Layout — ‹name›". Blank turns zones off on that display.
- **Edit layouts.** "Edit Layouts…" opens the layout editor: template zone counts per display, and custom Grid and Canvas layouts drawn in full-screen editors. Every committed change is saved to `layouts.json` at once.

Layouts are stored in `~/Library/Application Support/FancyMacZones/layouts.json` (`FancyMacZones Dev/` for the dev build). It is plain JSON you can back up. A corrupt file is renamed aside to `layouts-corrupt-‹timestamp›.json` and defaults are used; edits made by hand while the app runs are overwritten by its next save.

## Known limitations

- **⌃⌘ arrows are taken globally:** apps that use ⌃⌘ + arrows themselves (for example, Xcode's back and forward navigation) no longer receive them while FancyMacZones runs.
- **Right-clicking over WinBar's bar:** during a drag, a right-click with the cursor over WinBar's taskbar may go to WinBar instead. Move the cursor off the bar to toggle zones. Zones that reach the bottom of the screen are drawn partly under the bar; WinBar then trims snapped windows to end above it.
- **Rectangle and MacsyZones:** don't run them alongside FancyMacZones with their drag snapping enabled; the snapping competes.
- Apps that resist resizing (minimum sizes, character-cell terminals) land close to the zone rather than exactly in it. The hotkeys still recognise them.

## Releases and updates

FancyMacZones checks GitHub Releases (`omega123456/FancyMacZones`, which must be public) at launch and then every hour. When a newer version exists, it asks whether to update now. If you accept, it downloads the zip and installs it over the running copy, but only if the download is signed with the same "FancyMacZones Local Signing" certificate. Then it relaunches. The menu has **Automatic Updates** and **Check for Updates…**. Dev builds never update.

To publish a release, run this in Terminal.app with a clean working tree:

```sh
./scripts/release.sh
```

It bumps the version in `Info.plist`, writes the release notes to `.github/release-body.md`, runs a release build and the self-test, commits, tags `vX.Y.Z` and pushes. The tag triggers `.github/workflows/release.yml`, which builds on `macos-26`, signs with the same identity and attaches `FancyMacZones-X.Y.Z.dmg` (manual install: open it and drag FancyMacZones to Applications) and `FancyMacZones-X.Y.Z.zip` (used by the updater) to the release. The app is self-signed, so the first launch from a downloaded DMG is blocked by Gatekeeper: allow it once in System Settings → Privacy & Security → **Open Anyway**. A nightly workflow keeps only the newest 5 releases.

One-time repository setup:
1. Create the public repository `omega123456/FancyMacZones` and set it as `origin`.
2. In Keychain Access, export "FancyMacZones Local Signing" (certificate and private key) as a `.p12`. Then:
   ```sh
   base64 -i FancyMacZones.p12 | gh secret set APPLE_CERTIFICATE
   gh secret set APPLE_CERTIFICATE_PASSWORD   # the .p12 export password
   gh secret set KEYCHAIN_PASSWORD            # any random string (temporary CI keychain)
   gh secret set RELEASE_CLEANUP_TOKEN        # token with contents: write, for the cleanup workflow
   ```
   The workflow pins the certificate's SHA-1, so a different certificate fails the release.

## Event log (diagnostics)

Launch with `--log-events` to append millisecond-timestamped plain-text lines to:

```
~/Library/Logs/FancyMacZones/events.log        # production
~/Library/Logs/FancyMacZones Dev/events.log    # FancyMacZones Dev
```

The file is cleared at each launch and removed when the app starts without the flag. It contains window titles and app names in clear text. To read it:

```sh
./scripts/build-app.sh --log-events
tail -f ~/Library/Logs/FancyMacZones\ Dev/events.log
```

The log is a file rather than the unified log because the Claude Code sandbox blocks `/usr/bin/log`.

## Claude Code sandbox note

SwiftPM only works outside the Claude Code Bash sandbox. `.claude/settings.local.json` excludes `swift build`, `swift run`, `swift package` and `./scripts/build-app.sh` from the sandbox. The exclusion only applies when the whole command is one of these, so don't pipe or chain them (no `|`, `&&` or `cd … &&`). `make-cert.sh` is interactive, so run it in Terminal.app.
