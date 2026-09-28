import AppKit
import CoreGraphics

// Deliver key events straight to one process (CGEvent.postToPid) instead of
// posting them to the session — the target app does not need to be frontmost,
// so tests never land in whatever the user is typing in.
// usage: swift axkey.swift <pid> <keycode> [cmd|opt|ctrl|shift ...]
// keycodes: ← 123  → 124  ↓ 125  ↑ 126  ⏎ 36  esc 53  tab 48  0 29  c 8

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[1]), let key = CGKeyCode(args[2]) else {
    print("usage: swift axkey.swift <pid> <keycode> [cmd|opt|ctrl|shift]"); exit(1)
}
var flags: CGEventFlags = []
for m in args.dropFirst(3) {
    switch m {
    case "cmd": flags.insert(.maskCommand)
    case "opt": flags.insert(.maskAlternate)
    case "ctrl": flags.insert(.maskControl)
    case "shift": flags.insert(.maskShift)
    default: break
    }
}
// arrows carry the numeric-pad/function bits in real events
if [123, 124, 125, 126].contains(Int(key)) {
    flags.insert(.maskNumericPad)
    flags.insert(.maskSecondaryFn)
}

let source = CGEventSource(stateID: .hidSystemState)
for isDown in [true, false] {
    guard let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown) else {
        print("event creation failed"); exit(1)
    }
    e.flags = flags
    e.postToPid(pid)
    usleep(30_000)
}
print("sent keycode \(key) flags=\(flags.rawValue) to pid \(pid)")
