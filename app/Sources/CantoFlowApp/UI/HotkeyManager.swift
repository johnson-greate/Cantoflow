import AppKit
import CoreGraphics

/// Manages global hotkeys for recording toggle
final class HotkeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnCurrentlyDown = false
    private let onHotkey: () -> Void

    /// Key codes
    private static let fnKeyCode: Int64 = 63    // Fn / Globe key
    private static let f12KeyCode: Int64 = 111  // F12 key

    init(onHotkey: @escaping () -> Void) {
        self.onHotkey = onHotkey
    }

    deinit {
        stop()
    }

    /// Start listening for hotkeys
    func start() {
        guard eventTap == nil else { return }

        // Listen to both flagsChanged (for Fn key) and keyDown (for F12)
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

        // Use Unmanaged to pass self to C callback
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }

                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()

                // Re-enable tap if it was disabled
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = manager.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }

                manager.handleEvent(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            NotificationManager.shared.notify("Failed to setup hotkey. Enable Accessibility + Input Monitoring.")
            print("Warning: Failed to create CGEvent tap. Enable Accessibility + Input Monitoring.")
            return
        }

        eventTap = tap

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return
        }

        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Stop listening for hotkeys
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
    }

    /// Handle keyboard event
    private func handleEvent(type: CGEventType, event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .keyDown && keyCode == Self.f12KeyCode {
            // F12 key pressed
            DispatchQueue.main.async { [weak self] in
                self?.onHotkey()
            }
        } else if type == .flagsChanged && keyCode == Self.fnKeyCode {
            // Fn / Globe key
            let fnDown = event.flags.contains(.maskSecondaryFn)

            if fnDown && !fnCurrentlyDown {
                fnCurrentlyDown = true
                DispatchQueue.main.async { [weak self] in
                    self?.onHotkey()
                }
            } else if !fnDown && fnCurrentlyDown {
                fnCurrentlyDown = false
            }
        }
    }
}
