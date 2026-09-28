import AppKit
import ApplicationServices

// Inspect (and optionally press) a menu item of a background app over the AX
// API — no activation, no keystrokes, so it never fights the user for focus.
// usage: swift axmenu.swift <pid> <menu title> [item title substring to press]

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[1]) else {
    print("usage: swift axmenu.swift <pid> <menu> [press-substring]")
    exit(1)
}
let menuTitle = args[2]
let pressSubstring = args.count > 3 ? args[3] : nil

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
}
func children(_ el: AXUIElement) -> [AXUIElement] {
    (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}
func title(_ el: AXUIElement) -> String {
    (attr(el, kAXTitleAttribute as String) as? String) ?? ""
}

let app = AXUIElementCreateApplication(pid)
guard let bar = attr(app, kAXMenuBarAttribute as String) else {
    print("no menu bar (is the app running?)"); exit(1)
}
// swiftlint:disable:next force_cast
let menuBar = bar as! AXUIElement
guard let menu = children(menuBar).first(where: { title($0) == menuTitle }) else {
    print("menu '\(menuTitle)' not found. Menus: \(children(menuBar).map(title))")
    exit(1)
}
guard let dropdown = children(menu).first else { print("no dropdown"); exit(1) }

for item in children(dropdown) {
    let t = title(item)
    if t.isEmpty { continue }
    let cmd = (attr(item, "AXMenuItemCmdChar") as? String) ?? ""
    let virt = (attr(item, "AXMenuItemCmdVirtualKey") as? Int).map { " virtkey=\($0)" } ?? ""
    let mods = (attr(item, "AXMenuItemCmdModifiers") as? Int) ?? 0
    let enabled = (attr(item, kAXEnabledAttribute as String) as? Bool) ?? false
    print("\(enabled ? "on " : "off") \(t)  [key='\(cmd)'\(virt) mods=\(mods)]")
    if let sub = pressSubstring, t.contains(sub) {
        let err = AXUIElementPerformAction(item, kAXPressAction as CFString)
        print("   → AXPress: \(err == .success ? "ok" : "failed (\(err.rawValue))")")
    }
}
