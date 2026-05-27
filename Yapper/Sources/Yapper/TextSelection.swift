import AppKit
import ApplicationServices

enum TextSelection {
    /// Try the accessibility API first; fall back to copying via Cmd+C if no
    /// selection is exposed (web views and Electron apps frequently don't).
    static func grab() -> String? {
        let trusted = AXIsProcessTrusted()
        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        fputs("Yapper: grab — AX trusted=\(trusted), frontmost=\(frontApp)\n", stderr)
        if let text = axSelectedText(), !text.isEmpty {
            fputs("Yapper: AX selection \(text.count) chars\n", stderr)
            return text
        }
        fputs("Yapper: AX returned nothing — trying Cmd+C\n", stderr)
        let text = clipboardSelectedText()
        fputs("Yapper: clipboard path returned \(text?.count ?? 0) chars\n", stderr)
        return text
    }

    private static func axSelectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        var value: AnyObject?
        let status = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &value)
        guard status == .success, let s = value as? String else { return nil }
        return s
    }

    private static func clipboardSelectedText() -> String? {
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        let beforeCount = pb.changeCount
        fputs("Yapper: pasteboard changeCount before Cmd+C = \(beforeCount)\n", stderr)

        synthesizeCmdC()

        let deadline = Date().addingTimeInterval(0.5)
        while pb.changeCount == beforeCount && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        let afterCount = pb.changeCount
        fputs("Yapper: pasteboard changeCount after wait = \(afterCount)\n", stderr)
        if afterCount == beforeCount {
            return nil
        }

        let copied = pb.string(forType: .string)
        if let previous, copied != previous {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                pb.clearContents()
                pb.setString(previous, forType: .string)
            }
        }
        return copied
    }

    private static func synthesizeCmdC() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let cKey: CGKeyCode = 8 // 'c'
        let down = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
