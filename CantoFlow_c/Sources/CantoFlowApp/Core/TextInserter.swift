import AppKit
import ApplicationServices

// Known terminal emulator bundle IDs where Cmd+Z does not undo text input
private let terminalBundleIDs: Set<String> = [
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "dev.warp.desktop",
    "net.kovidgoyal.kitty",
    "com.microsoft.VSCode",
    "io.alacritty",
    "co.zeit.hyper",
]

/// Methods for inserting text
enum InsertionMethod: String {
    case axAPI = "ax_api"
    case clipboard = "clipboard"
}

/// Result of text insertion
struct InsertionResult {
    let method: InsertionMethod
    let success: Bool
}

/// Text inserter using AX API with Cmd+V fallback
final class TextInserter {
    private let clipboardGuard = ClipboardGuard()

    /// Insert text into the focused application
    /// - Parameter text: Text to insert
    /// - Returns: InsertionResult indicating the method used and success status
    @discardableResult
    func insert(text: String) -> InsertionResult {
        // Try AX API first
        if insertViaAccessibility(text: text) {
            return InsertionResult(method: .axAPI, success: true)
        }

        // Fallback to clipboard + Cmd+V
        return insertViaClipboard(text: text)
    }

    /// Insert text with clipboard, preserving existing clipboard content
    /// - Parameter text: Text to insert
    /// - Returns: InsertionResult
    func insertViaClipboard(text: String) -> InsertionResult {
        // Save current clipboard
        clipboardGuard.save()

        // Copy text to clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Small delay to ensure clipboard is ready
        Thread.sleep(forTimeInterval: 0.05)

        // Send Cmd+V
        let success = sendCmdV()

        // Restore clipboard after a LONG delay to ensure paste completes
        // CGEvent posting is asynchronous, paste can take 500ms+ in some apps
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.clipboardGuard.restore()
        }

        return InsertionResult(method: .clipboard, success: success)
    }

    /// Undo the last insertion (for fast IME mode)
    func undo() -> Bool {
        return sendCmdZ()
    }

    /// Returns true if the frontmost app is a terminal emulator.
    /// In terminals, Cmd+Z does not undo text and pasted newlines execute commands,
    /// so fast IME raw-paste must be suppressed.
    func isFrontmostAppTerminal() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return terminalBundleIDs.contains(bundleID)
    }

    // MARK: - Private Methods

    /// Insert text using Accessibility API
    private func insertViaAccessibility(text: String) -> Bool {
        // Get the focused element
        guard let focusedElement = getFocusedElement() else {
            return false
        }

        // Check if element is editable
        var isEditable: AnyObject?
        let editableResult = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXRoleAttribute as CFString,
            &isEditable
        )

        guard editableResult == .success,
              let role = isEditable as? String,
              role == kAXTextFieldRole || role == kAXTextAreaRole else {
            return false
        }

        // Get current selection range (not used but needed for AX context)
        var selectedRange: AnyObject?
        _ = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRange
        )

        // Try to set selected text (replaces selection or inserts at cursor)
        let setResult = AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )

        return setResult == .success
    }

    /// Get the currently focused accessibility element
    private func getFocusedElement() -> AXUIElement? {
        let systemElement = AXUIElementCreateSystemWide()

        var focusedApp: AnyObject?
        let appResult = AXUIElementCopyAttributeValue(
            systemElement,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApp
        )

        guard appResult == .success, let app = focusedApp else {
            return nil
        }

        var focusedElement: AnyObject?
        let elementResult = AXUIElementCopyAttributeValue(
            app as! AXUIElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard elementResult == .success, let element = focusedElement else {
            return nil
        }

        return (element as! AXUIElement)
    }

    /// Send Cmd+V keystroke
    private func sendCmdV() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key down
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) else {
            return false
        }
        keyDown.flags = .maskCommand

        // Key up
        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            return false
        }
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        return true
    }

    /// Send Cmd+Z keystroke (undo)
    private func sendCmdZ() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key down
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x06, keyDown: true) else {
            return false
        }
        keyDown.flags = .maskCommand

        // Key up
        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x06, keyDown: false) else {
            return false
        }
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        return true
    }
}
