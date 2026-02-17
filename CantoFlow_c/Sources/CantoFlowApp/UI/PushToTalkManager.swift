import AppKit
import CoreGraphics

/// Trigger key types supported by PushToTalkManager
enum TriggerKeyType: String, CaseIterable {
    case fn = "fn"           // Fn / Globe key (modifier-based)
    case f12 = "f12"         // F12 key
    case f13 = "f13"         // F13 key
    case f14 = "f14"         // F14 key
    case f15 = "f15"         // F15 key (preferred for external keyboards)

    var displayName: String {
        switch self {
        case .fn: return "Fn (Globe)"
        case .f12: return "F12"
        case .f13: return "F13"
        case .f14: return "F14"
        case .f15: return "F15"
        }
    }

    var keyCode: Int64? {
        switch self {
        case .fn: return 63     // Fn key (modifier)
        case .f12: return 111   // F12
        case .f13: return 105   // F13
        case .f14: return 107   // F14
        case .f15: return 113   // F15
        }
    }

    var isModifierKey: Bool {
        return self == .fn
    }
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
    var triggerKey: TriggerKeyType = .fn {
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

        if triggerKey.isModifierKey {
            // Fn key uses flagsChanged
            mask = 1 << CGEventType.flagsChanged.rawValue
        } else {
            // Function keys use keyDown/keyUp
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
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if triggerKey.isModifierKey {
            // Handle Fn key (modifier-based)
            if type == .flagsChanged && keyCode == triggerKey.keyCode {
                let fnDown = event.flags.contains(.maskSecondaryFn)
                handleKeyStateChange(isDown: fnDown)
            }
        } else {
            // Handle function keys (keyDown/keyUp)
            guard keyCode == triggerKey.keyCode else { return }

            if type == .keyDown {
                handleKeyStateChange(isDown: true)
            } else if type == .keyUp {
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
