import AppKit
import CoreGraphics

/// Global hotkey manager for vocabulary learning.
/// Default binding: F14.
final class LearningHotkeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let onLearnHotkey: () -> Void

    private static let f14KeyCode: Int64 = 107

    init(onLearnHotkey: @escaping () -> Void) {
        self.onLearnHotkey = onLearnHotkey
    }

    deinit {
        stop()
    }

    func start() {
        guard eventTap == nil else { return }

        let mask = 1 << CGEventType.keyDown.rawValue
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }

                let manager = Unmanaged<LearningHotkeyManager>.fromOpaque(refcon).takeUnretainedValue()

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
            NotificationManager.shared.notify("Failed to setup learning hotkey (F14).", title: "CantoFlow 學習")
            print("Warning: Failed to create learning hotkey event tap.")
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

    private func handleEvent(type: CGEventType, event: CGEvent) {
        guard type == .keyDown else { return }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Self.f14KeyCode else { return }

        DispatchQueue.main.async { [weak self] in
            self?.onLearnHotkey()
        }
    }
}
