# Mize

A macOS presentation tool for live demos. Instead of slides, Mize arranges your
real app windows into named scenes you can page through with arrow keys —
keeping the demo interactive (you type into the real terminal, click in the
real browser) while hiding everything not part of the current scene.

## What it does

You define scenes in a JSON file (or via the in-app editor). Each scene is a
list of "panes," where each pane points to one of your open app windows and
specifies where to put it on screen (full, left half, right half, etc.).

When a scene activates, Mize uses the macOS Accessibility API to move + resize
the target windows into the layout, hides all other apps, and covers the desktop
wallpaper + menu bar + dock with a curtain. You see only the scene's app
windows on a black backdrop. PageDown / Cmd+→ advances to the next scene.

There's no screen capture, no mirroring, no input forwarding. The windows you
interact with *are* the real windows — Mize just arranges them.

## Requirements

- macOS 14 (Sonoma) or later
- Swift 6.0 toolchain (ships with Xcode 16+ / Command Line Tools)
- Accessibility permission (you'll grant this once at first launch)

## Install

The on-disk bundle is `Mize.app` (ASCII) — macOS shows the display name
"Mize" in the Dock and Spotlight via `CFBundleDisplayName`.

```bash
git clone <repo-url> mize && cd mize
./scripts/create-signing-identity.sh    # one-time: makes a self-signed cert
./scripts/finalize-identity.sh          # one-time: trust + keychain partition (sudo + login pwd)
./scripts/build-app.sh                  # produces build/Mize.app
cp -R build/Mize.app /Applications/    # optional: install for Spotlight
```

First launch will prompt you to grant Accessibility in
**System Settings → Privacy & Security → Accessibility**. Toggle Mize on, then
relaunch. Mize verifies on startup and exits with a console message if the
permission isn't granted.

## Use

Launch via Spotlight (`Cmd+Space`, type "Mize") or:

```bash
open /Applications/Mize.app
```

**Important:** don't invoke the binary directly from a terminal
(`./Mize.app/Contents/MacOS/Mize`). macOS attributes Accessibility permission
to the launching terminal app rather than to Mize when you do that.

### Keybindings

| Keys | Action |
|------|--------|
| `PageDown` / `Cmd+→` | Next scene |
| `PageUp` / `Cmd+←` | Previous scene |
| `Cmd+E` | Toggle the scene editor panel |
| `Cmd+,` | Open the active scenes file in your default text editor |
| `Cmd+O` | Open a different scenes file |
| `Cmd+Shift+S` | Save the current scenes as a new file |
| `ESC` | Restore window positions and quit |

Plain arrow keys (without modifiers) and other unbound keys pass through to
whatever app is frontmost.

### The editor (Cmd+E)

A floating panel with:
- Scene title
- Background color picker (system color panel)
- Multi-line text input + position anchor + size slider for an on-curtain title
- A scrollable list of currently-running windows with checkboxes — check to
  include in the current scene, with a layout dropdown (Full / Left Half / etc.)
- Add Scene / Delete Scene / Prev / Next buttons

Every edit auto-saves to the active scenes file. You can also drag the actual
target windows around in the scene (the OS-native title-bar drag) — Mize
captures the new frame on the next scene transition.

### Scenes file format

Stored at `~/Library/Application Support/Mize/Scenes/Default.json` on first
launch. Cmd+O lets you switch between named scene sets in that directory.
Example:

```json
{
  "scenes": [
    {
      "title": "Title slide",
      "backgroundColor": "#0c1a4d",
      "texts": [
        {
          "content": "Welcome to Mize",
          "x": 864, "y": 558,
          "fontSize": 96,
          "color": "#ffffff",
          "alignment": "center"
        }
      ],
      "panes": []
    },
    {
      "title": "Notes + Browser",
      "backgroundColor": "#000000",
      "panes": [
        {
          "appNameContains": "Notes",
          "titleContains": "My demo notes",
          "frame": {"x": 0, "y": 50, "width": 864, "height": 1017}
        },
        {
          "appNameContains": "Brave Browser",
          "titleContains": null,
          "frame": {"x": 864, "y": 50, "width": 864, "height": 1017}
        }
      ]
    }
  ]
}
```

Hot-reloads when saved externally.

## Known limitations

Honest about what doesn't work cleanly:

- **Multi-window-per-app disambiguation is fuzzy across sessions.** Mize
  identifies windows by `CGWindowID` (stable within a session) plus an
  app-name + title fallback (used across sessions). If you have two Slack
  windows and switch channels in both, the fallback may match the wrong one
  on next launch. Workaround: stick to one window per app for scenes where
  precision matters.
- **System menu bar can show through.** When you click into a target app, the
  active app's menu bar renders above Mize's chrome cover (macOS reserves this
  layer for the menu bar). Workaround: enable
  **System Settings → Desktop & Dock → "Automatically hide and show the menu
  bar" → "Always"**.
- **Single display only.** Mize only arranges windows on the primary display.
- **Slack `Cmd+→`/`Cmd+←` collides with Mize's scene navigation.** Inside Slack
  these jump channels. Use PageDown/PageUp instead, or click into a Mize scene
  area first.
- **Not notarized.** Built locally with a self-signed identity. Gatekeeper
  won't complain because you built it; if you distribute the `.app` to others
  they'll need to right-click → Open the first time.
- **Restore on crash isn't guaranteed.** Mize restores window positions on
  graceful exit (ESC, Cmd+Q). If it crashes mid-presentation, your windows
  stay at their scene positions until you manually drag them back.

## Architecture

Three Swift sources do most of the work:

- `WindowManager.swift` — Accessibility (AX) wrapper. Snapshots all visible
  app windows at startup, exposes move/resize/raise/minimize, restores
  original positions on exit. Uses the private but ubiquitous
  `_AXUIElementGetWindow` to bridge AX elements ↔ CGWindowIDs.
- `PresentationApp.swift` — owns the Mize-side NSWindows (main curtain at
  level `.normal - 1`, two chrome covers at `CGShieldingWindowLevel - 1`),
  the scene activation pipeline, key monitors, and the in-memory scene state.
- `SceneStore.swift` — load/save scenes to JSON, watch the file for external
  edits via DispatchSource, remember the last-used scenes file via
  UserDefaults.

The editor panel (`EditorPanel.swift`) is AppKit + NSPanel hosting native
controls. Curtain rendering (`CurtainView.swift`) uses a layer-backed
NSView so background colour transitions animate via CATransaction.

## Why not screen capture?

The original architecture used `ScreenCaptureKit` to mirror the target windows
onto a composited surface, then forward synthesized input events back to the
real apps. It worked but had three persistent problems:

1. Cursor duplication and slight resolution degradation from the capture loop
2. `CGEvent.postToPid` for keyboard input is silently denied by Terminal's
   Secure Input mode (e.g., during `sudo` prompts)
3. Latency made interactive demos feel unresponsive

Switching to AX-based real window manipulation removes all three at the cost
of losing the ability to do multi-window-per-pane *compositing* (since macOS
won't let one app raise another app's window above its own without private
APIs). For live demos, that tradeoff is the right one.

## Contributing

PRs welcome. Things that would make this materially better:

- Better cross-session window identification (multi-window apps)
- Optional per-scene "snapshot of app state" so channel switches survive
- Multi-display support
- Crash-safe state restoration (write snapshot to disk; restore on next launch)
- Unit / integration tests beyond `SceneStoreTests`

## License

MIT — see `LICENSE`.
