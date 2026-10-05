# Passive UI test rig

Four small scripts for driving and inspecting a **running Marina without
activating it** — so a test never lands keystrokes in whatever the user is
typing in, and works even when Marina sits on another Space.

Start a throwaway instance in the background (the running one keeps its state):

```sh
open -g -n build/Marina.app          # -g: no activation, -n: second instance
pgrep -f "Marina.app/Contents/MacOS/Marina"
```

| Script | What it does |
|---|---|
| `swift axkey.swift <pid> <keycode> [cmd opt ctrl shift]` | Delivers a key event to that process only (`CGEvent.postToPid`). Keycodes: ← 123, → 124, ↓ 125, ↑ 126, ⏎ 36, esc 53, ⇥ 48, 0 29, c 8, t 17, w 13 |
| `swift axfocus.swift <pid>` | Prints the AX focused element (role, title, frame) and its parents — the way to tell *where the keyboard actually is* |
| `swift axmenu.swift <pid> <menu> [item substring]` | Lists a menu's items with their key equivalents and enabled state; presses one if given |
| `swift capany.swift out.png [pid]` | Screenshots Marina's main window via ScreenCaptureKit, off-screen Spaces included |

Kill the throwaway instance with `kill <pid>` when done.

A worked example: `axfocus` reporting the whole 1150×953 hosting view instead
of a strip-sized element is how the tab bar was shown to never accept SwiftUI
focus — which is why its keys are handled by an event monitor in `AppState`.
