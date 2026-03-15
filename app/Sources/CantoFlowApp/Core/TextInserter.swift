import AppKit
import ApplicationServices

// Virtual key codes from macOS HIToolbox/Events.h
private let kVK_ANSI_V: CGKeyCode = 0x09  // V key → Cmd+V (paste)
private let kVK_ANSI_Z: CGKeyCode = 0x06  // Z key → Cmd+Z (undo)

// Timing constants for clipboard operations
/// Delay before sending Cmd+V to let the pasteboard settle
private let kClipboardSettleNs: UInt64 = 50_000_000      // 50 ms
/// Delay before restoring clipboard — some apps take 500 ms+ to complete a paste
private let kClipboardRestoreNs: UInt64 = 2_000_000_000  // 2 s

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

/// Text inserter using AX API with Cmd+V fallback.
///
/// MUST run on the main thread: NSPasteboard, CGEvent.post(), and AX API all
/// require main-thread access.  Marked @MainActor to enforce this at compile
/// time and eliminate the IMKCFRunLoopWakeUpReliable mach-port crash that
/// occurs when these APIs are called from Swift's cooperative thread pool.
@MainActor
final class TextInserter {
    // nonisolated init so STTPipeline can create the instance as a stored property
    // without requiring @MainActor on STTPipeline itself.  No main-thread APIs are
    // accessed during initialisation.
    nonisolated init() {}

    private let clipboardGuard = ClipboardGuard()

    /// Insert text into the focused application (AX API first, clipboard fallback)
    @discardableResult
    func insert(text: String) async -> InsertionResult {
        if insertViaAccessibility(text: text) {
            return InsertionResult(method: .axAPI, success: true)
        }
        return await insertViaClipboard(text: text)
    }

    /// Insert text via clipboard + Cmd+V, preserving existing clipboard content.
    /// Async so we can yield the main thread during the 50ms clipboard-ready delay
    /// instead of blocking it with Thread.sleep.
    func insertViaClipboard(text: String) async -> InsertionResult {
        clipboardGuard.save()

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Yield main thread briefly to let the pasteboard settle before sending Cmd+V.
        try? await Task.sleep(nanoseconds: kClipboardSettleNs)

        let success = sendCmdV()

        // Restore clipboard after a delay long enough for the paste to complete.
        // CGEvent posting is asynchronous; some apps take 500 ms+.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: kClipboardRestoreNs)
            self?.clipboardGuard.restore()
        }

        return InsertionResult(method: .clipboard, success: success)
    }

    /// Undo the last insertion (Cmd+Z) for fast IME replace mode.
    func undo() -> Bool {
        return sendCmdZ()
    }

    /// Capture the currently focused AX element for use by CorrectionWatcher.
    /// Call immediately after text insertion while focus is still on the target field.
    func captureCurrentElement() -> AXUIElement? {
        getFocusedElement()
    }

    /// Returns true if the frontmost app is a terminal emulator.
    func isFrontmostAppTerminal() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return terminalBundleIDs.contains(bundleID)
    }

    // MARK: - Private Methods

    /// Insert text using Accessibility API
    private func insertViaAccessibility(text: String) -> Bool {
        guard let focusedElement = getFocusedElement() else { return false }

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

        var selectedRange: AnyObject?
        _ = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRange
        )

        let setResult = AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )

        return setResult == .success
    }

    private func getFocusedElement() -> AXUIElement? {
        let systemElement = AXUIElementCreateSystemWide()

        var focusedApp: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemElement, kAXFocusedApplicationAttribute as CFString, &focusedApp
        ) == .success, let app = focusedApp else { return nil }

        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(
            app as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focusedElement
        ) == .success, let element = focusedElement else { return nil }

        return (element as! AXUIElement)
    }

    private func sendCmdV() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: kVK_ANSI_V, keyDown: true),
              let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: kVK_ANSI_V, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags   = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func sendCmdZ() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: kVK_ANSI_Z, keyDown: true),
              let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: kVK_ANSI_Z, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags   = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
