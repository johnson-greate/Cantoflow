import AppKit
import CoreGraphics

/// Represents an arbitrary recorded hotkey combination
struct CustomHotkey: Codable, Equatable {
    var keyCode: CGKeyCode
    var modifierFlags: UInt64 // CGEventFlags.rawValue
    var displayName: String

    var isModifierOnly: Bool {
        // Simple heuristic: if the hotkey has modifiers but NO regular key is pressed
        // 54: Right Command, 55: Left Command
        // 56: Left Shift, 60: Right Shift
        // 57: Caps Lock
        // 58: Left Option, 61: Right Option
        // 59: Left Control, 62: Right Control
        // 63: Fn (Old)
        // 179: Fn/Globe (New Apple Silicon)
        let mods: Set<CGKeyCode> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 179]
        return mods.contains(keyCode)
    }

    /// Mask of modifiers we actually care about (ignoring caps lock, num pad, etc)
    static func normalizedModifiers(_ flags: UInt64) -> UInt64 {
        let mask: UInt64 = CGEventFlags.maskShift.rawValue |
                           CGEventFlags.maskControl.rawValue |
                           CGEventFlags.maskAlternate.rawValue |
                           CGEventFlags.maskCommand.rawValue |
                           CGEventFlags.maskSecondaryFn.rawValue
        return flags & mask
    }

    /// Default starting configuration (Fn Key)
    static let defaultFn = CustomHotkey(
        keyCode: 179, // Use modern Globe key as default
        modifierFlags: CGEventFlags.maskSecondaryFn.rawValue,
        displayName: "Fn (Globe)"
    )
    
    static let defaultF15 = CustomHotkey(
        keyCode: 113,
        modifierFlags: 0,
        displayName: "F15"
    )
}

/// Push-to-Talk state machine
enum PushToTalkState {
    case idle
    case recording(startTime: Date)
    case processing
    case cancelled
}

/// Delegate protocol for push-to-talk events
protocol PushToTalkDelegate: AnyObject {
    func pushToTalkDidStartRecording()
    func pushToTalkDidStopRecording(duration: TimeInterval)
    func pushToTalkDidCancel(reason: String)
    func pushToTalkStateDidChange(_ state: PushToTalkState)
}

/// Manages push-to-talk functionality with support for multiple trigger keys
final class PushToTalkManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var triggerKeyDown = false
    private var recordingStartTime: Date?

    weak var delegate: PushToTalkDelegate?

    /// Current trigger key configuration
    var triggerKey: CustomHotkey = .defaultFn {
        didSet {
            if isRunning {
                stop()
                start()
            }
        }
    }

    /// Minimum hold duration (in seconds) to trigger recording
    let minHoldDuration: TimeInterval = 0.3

    /// Maximum recording duration (in seconds)
    let maxRecordingDuration: TimeInterval = 300 // 5 minutes

    /// Whether the manager is currently running
    private(set) var isRunning = false

    /// Current state
    private(set) var state: PushToTalkState = .idle {
        didSet {
            delegate?.pushToTalkStateDidChange(state)
        }
    }

    deinit {
        stop()
    }

    /// Start listening for the trigger key
    func start() {
        guard eventTap == nil else { return }

        // Determine which events to listen for
        var mask: CGEventMask = 0

        if triggerKey.isModifierOnly {
            // Modifiers like Fn only emit flagsChanged
            mask = 1 << CGEventType.flagsChanged.rawValue
        } else {
            // Normal keys always emit keyDown / keyUp (and we check flags inside handleEvent)
            mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        }

        // Use Unmanaged to pass self to C callback
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }

                let manager = Unmanaged<PushToTalkManager>.fromOpaque(refcon).takeUnretainedValue()

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
        isRunning = true
    }

    /// Stop listening for the trigger key
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }

        isRunning = false
    }

    /// Handle keyboard event
    private func handleEvent(type: CGEventType, event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = CustomHotkey.normalizedModifiers(event.flags.rawValue)
        let expectedFlags = CustomHotkey.normalizedModifiers(triggerKey.modifierFlags)

        if triggerKey.isModifierOnly {
            // Handle pure modifier trigger (like Fn)
            if type == .flagsChanged && (keyCode == triggerKey.keyCode || triggerKey.keyCode == 179 || triggerKey.keyCode == 63) {
                // If it's a modifier, it is "down" if its specific bit is present in the current flags
                // For Fn/Globe, we specifically check the maskSecondaryFn bit
                let isDown = (flags & expectedFlags) != 0
                handleKeyStateChange(isDown: isDown)
            }
        } else {
            // Handle normal keys (keyDown/keyUp) with modifiers
            guard keyCode == triggerKey.keyCode else { return }
            
            // To prevent firing on 'Shift+F12' when only 'F12' is requested, require flag equality
            let isModifiersMatching = (flags == expectedFlags)

            if type == .keyDown && isModifiersMatching {
                handleKeyStateChange(isDown: true)
            } else if type == .keyUp {
                // Ignore modifier mismatch on KeyUp to ensure we reliably stop recording
                handleKeyStateChange(isDown: false)
            }
        }
    }

    /// Handle key state change (down or up)
    private func handleKeyStateChange(isDown: Bool) {
        if isDown && !triggerKeyDown {
            // Key pressed - start recording
            triggerKeyDown = true
            handleKeyDown()
        } else if !isDown && triggerKeyDown {
            // Key released - stop recording
            triggerKeyDown = false
            handleKeyUp()
        }
    }

    /// Handle key down event
    private func handleKeyDown() {
        guard case .idle = state else { return }

        recordingStartTime = Date()
        state = .recording(startTime: recordingStartTime!)

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.pushToTalkDidStartRecording()
        }

        // Set up max duration timer
        DispatchQueue.main.asyncAfter(deadline: .now() + maxRecordingDuration) { [weak self] in
            guard let self = self else { return }
            if case .recording = self.state {
                self.handleKeyUp()
            }
        }
    }

    /// Handle key up event
    private func handleKeyUp() {
        guard case .recording(let startTime) = state else { return }

        let duration = Date().timeIntervalSince(startTime)
        recordingStartTime = nil

        if duration < minHoldDuration {
            // Too short - cancel
            state = .cancelled
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.pushToTalkDidCancel(reason: "Hold too short (\(Int(duration * 1000))ms)")
            }
            // Reset to idle after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.state = .idle
            }
        } else {
            // Valid recording
            state = .processing
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.pushToTalkDidStopRecording(duration: duration)
            }
        }
    }

    /// Mark processing as complete, return to idle
    func markProcessingComplete() {
        state = .idle
    }

    /// Cancel current recording
    func cancelRecording() {
        guard case .recording = state else { return }
        state = .cancelled
        triggerKeyDown = false
        recordingStartTime = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.state = .idle
        }
    }

    /// Get recording duration (if currently recording)
    var currentRecordingDuration: TimeInterval? {
        guard case .recording(let startTime) = state else { return nil }
        return Date().timeIntervalSince(startTime)
    }
}
