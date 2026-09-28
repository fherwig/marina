import AppKit
import ScreenCaptureKit
import CoreGraphics

_ = NSApplication.shared
let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        // optional 2nd arg: restrict to one pid (two instances can be running)
        let wantPid = CommandLine.arguments.count > 2 ? pid_t(CommandLine.arguments[2]) : nil
        let marina = content.windows.filter {
            $0.owningApplication?.applicationName == "Marina"
                && (wantPid == nil || $0.owningApplication?.processID == wantPid)
        }
        for w in marina { print("window \(w.windowID) \(w.frame) title=\(w.title ?? "-") onscreen=\(w.isOnScreen)") }
        // largest on-screen window is the real one; SwiftUI keeps blank helpers around
        // the main window may be on another Space (isOnScreen false) and still capture fine
        guard let win = marina.filter({ $0.frame.height > 300 }).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            print("no marina window"); exit(1)
        }
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let config = SCStreamConfiguration()
        config.width = Int(win.frame.width)
        config.height = Int(win.frame.height)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let rep = NSBitmapImageRep(cgImage: image)
        let data = rep.representation(using: .png, properties: [:])!
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("ok \(win.frame)")
        exit(0)
    } catch { print("err \(error)"); exit(1) }
}
sem.wait()
