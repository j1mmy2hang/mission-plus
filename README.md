# Mission Plus

A remake of [Mission Control Plus](https://www.fadel.io/missioncontrolplus): it adds window controls to macOS's own Mission Control.

## In Mission Control (⌃↑, F3 or swipe up)

Hover a window to get **close** and **minimize** buttons on it. Then:

| Key | Action |
|---|---|
| ⌘W / ⌘M | Close / minimize the highlighted window |
| ⌘H / ⌘Q | Hide / quit its app |
| ⌥⌘W / ⌥⌘M | Close / minimize all windows |
| ⌥⌘H | Hide all apps except the highlighted one |
| ⌃⌘F | Open the window in full screen |
| Arrow keys | Move the highlight |
| ↵ | Open the highlighted window |
| Middle-click | Close a window |

Each shortcut can be turned off in Preferences (menu bar icon → Preferences…).

## Window Overview (⌃⌥↑)

A Mission Control–style overview drawn by the app itself, with the same shortcuts and type-to-search.

## Build

```sh
./build.sh          # → build/Mission Plus.app
./build.sh --run    # build and launch
```

Needs Accessibility and Screen Recording permission (System Settings → Privacy & Security).

## How it works

On macOS 26+, Mission Control is drawn by `WindowManager.app`. Its Accessibility tree has an `mc.display` group whose buttons are the thumbnails, and each has a `wid` attribute (the window's CGWindowID). Mission Plus reads those frames, draws its buttons in a click-through window above them, and uses an event tap to catch clicks and keys while Mission Control is open.
