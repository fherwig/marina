import AppKit
import ApplicationServices

// Print the AX focused element of a background app (role + a bit of context),
// so focus questions can be answered without activating it.
// usage: swift axfocus.swift <pid>

guard CommandLine.arguments.count > 1, let pid = pid_t(CommandLine.arguments[1]) else {
    print("usage: swift axfocus.swift <pid>"); exit(1)
}

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
}
func str(_ el: AXUIElement, _ name: String) -> String {
    (attr(el, name) as? String) ?? ""
}
func describe(_ el: AXUIElement) -> String {
    let role = str(el, kAXRoleAttribute as String)
    let sub = str(el, kAXSubroleAttribute as String)
    let title = str(el, kAXTitleAttribute as String)
    let desc = str(el, kAXDescriptionAttribute as String)
    let value = (attr(el, kAXValueAttribute as String) as? String) ?? ""
    var out = role
    if !sub.isEmpty { out += "/\(sub)" }
    if !title.isEmpty { out += " title=\"\(title)\"" }
    if !desc.isEmpty { out += " desc=\"\(desc)\"" }
    if !value.isEmpty { out += " value=\"\(value.prefix(40))\"" }
    if let frame = attr(el, "AXFrame") {
        var rect = CGRect.zero
        if AXValueGetValue(frame as! AXValue, .cgRect, &rect) {
            out += " frame=\(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))x\(Int(rect.height))"
        }
    }
    return out
}

let app = AXUIElementCreateApplication(pid)
guard let focused = attr(app, kAXFocusedUIElementAttribute as String) else {
    print("no focused element"); exit(0)
}
var el = focused as! AXUIElement
print("focused: \(describe(el))")
// walk up a few parents for context
for depth in 1...5 {
    guard let parent = attr(el, kAXParentAttribute as String) else { break }
    el = parent as! AXUIElement
    print(String(repeating: "  ", count: depth) + "^ \(describe(el))")
}
