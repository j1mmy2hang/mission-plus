# Changelog

Release notes for each version. `scripts/release.sh` copies a version's section into the
update window and the GitHub release, so write it for the people using the app.

## 1.1.2

- **Unsaved changes aren't left hidden.** If a window you close (or an app you quit) asks
  "Save changes?", Mission Plus now leaves the overview or Mission Control and brings that window
  forward so you can answer. Before, the question waited out of sight behind the overview.

## 1.1.1

- **Smoother Mission Control again.** After you close or minimize a window, Mission Control rearranges
  the rest as smoothly as before. 1.1.0 queried macOS about Spaces dozens of times a second while
  Mission Control was open, which competed with its animation.
- **⌘W and ⌘M in Mission Control respond faster.**

## 1.1.0

- **Windows from every Space, if you want them.** In Preferences, the overview can also show windows
  on other desktops, full-screen windows, minimized windows and windows of hidden apps, in a strip
  along the bottom. F, M and H mark full-screen, minimized and hidden ones. Opening one switches to
  its Space, restores it or unhides its app.
- **Tidy up without leaving.** ⌘H, ⌘Q, ⌘W and ⌘M no longer close the overview. With hidden or
  minimized windows shown, ⌘H and ⌘M move windows into the strip, and pressing them again undoes it.
- **Straight to the window you pick,** even when its app has windows on several Spaces.
- **Sharper exit.** The window you open grows from a full-resolution snapshot.
- **Windows without a thumbnail** show their app's icon and title on a tint of the app's colours.
- **Fixed:** in Mission Control, close and minimize buttons could appear over windows from other Spaces.

## 1.0.0

First public release.

- **Close and minimize buttons in Mission Control.** Hover any window in macOS's own Mission Control
  to get traffic-light buttons on it.
- **Keyboard shortcuts in Mission Control.** ⌘W, ⌘M, ⌘H and ⌘Q act on the highlighted window;
  ⌥⌘W and ⌥⌘M close or minimize everything; ⌥⌘H hides every other app; arrow keys move between
  windows and ↵ opens one.
- **Window Overview.** A Mission Control–style overview of every window on the current Space,
  with thumbnails and type-to-search. Open it with ⌃⌥↑ (or your own shortcut), or let it replace
  the three- or four-finger swipe up.
- **Updates.** Mission Plus checks for new versions once a day and asks before installing.
