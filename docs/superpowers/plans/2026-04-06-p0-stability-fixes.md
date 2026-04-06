# P0 Stability Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the three root causes of "push-to-talk sometimes doesn't respond": PushToTalkManager state machine race conditions, missing network timeouts in TextPolisher, and silent event tap failure.

**Architecture:** All three fixes are isolated to their own files with no cross-dependencies. Each fix replaces fire-and-forget `asyncAfter` or missing guards with cancellable, trackable mechanisms. No new files are created — only existing files are modified.

**Tech Stack:** Swift, macOS AppKit, GCD (DispatchWorkItem), URLRequest, CGEvent

---

## File Map

| File | Change | Responsibility |
|------|--------|---------------|
| `app/Sources/CantoFlowApp/UI/PushToTalkManager.swift` | Modify | Replace all `asyncAfter` with cancellable `DispatchWorkItem`; add event tap re-enable retry + notification |
| `app/Sources/CantoFlowApp/Core/TextPolisher.swift` | Modify | Add 10s `timeoutInterval` to all 4 URLRequests |
| `app/Sources/CantoFlowApp/UI/MenuBarController.swift` | Modify | Show notification when event tap fails to re-enable |

---

### Task 1: Fix PushToTalkManager state machine race conditions

**Files:**
- Modify: `app/Sources/CantoFlowApp/UI/PushToTalkManager.swift`

The core bug: `DispatchQueue.main.asyncAfter` blocks cannot be cancelled. When a recording is cancelled or stopped, the 5-minute max-duration timer and the 0.3s cancelled→idle timer keep running. If the user starts a new recording before these timers fire, they corrupt the state machine.

**Fix:** Store each timer as a `DispatchWorkItem?` property and cancel it explicitly on every state transition.

- [ ] **Step 1: Add cancellable work item properties**

Replace lines 64-69 of `PushToTalkManager.swift`. Add two new properties after `recordingStartTime`:

```swift
final class PushToTalkManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var triggerKeyDown = false
    private var recordingStartTime: Date?

    /// Cancellable timer for max recording duration (5 min).
    /// Cancelled on every state exit from .recording.
    private var maxDurationWorkItem: DispatchWorkItem?

    /// Cancellable timer for cancelled→idle transition (0.3s).
    /// Cancelled if a new recording starts before it fires.
    private var cancelledIdleWorkItem: DispatchWorkItem?

    weak var delegate: PushToTalkDelegate?
```

- [ ] **Step 2: Rewrite `handleKeyDown()` with cancellable max-duration timer**

Replace the entire `handleKeyDown()` method (lines 222-238):

```swift
    /// Handle key down event
    private func handleKeyDown() {
        guard case .idle = state else { return }

        // Cancel any leftover timers from a previous cycle
        maxDurationWorkItem?.cancel()
        cancelledIdleWorkItem?.cancel()

        recordingStartTime = Date()
        state = .recording(startTime: recordingStartTime!)

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.pushToTalkDidStartRecording()
        }

        // Set up cancellable max duration timer
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if case .recording = self.state {
                self.handleKeyUp()
            }
        }
        maxDurationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + maxRecordingDuration, execute: workItem)
    }
```

- [ ] **Step 3: Rewrite `handleKeyUp()` with cancellable cancelled→idle timer**

Replace the entire `handleKeyUp()` method (lines 242-265):

```swift
    /// Handle key up event
    private func handleKeyUp() {
        guard case .recording(let startTime) = state else { return }

        // Recording ended — cancel the max-duration timer
        maxDurationWorkItem?.cancel()
        maxDurationWorkItem = nil

        let duration = Date().timeIntervalSince(startTime)
        recordingStartTime = nil

        if duration < minHoldDuration {
            // Too short - cancel
            state = .cancelled
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.pushToTalkDidCancel(reason: "Hold too short (\(Int(duration * 1000))ms)")
            }
            // Cancellable reset to idle after a short delay
            let workItem = DispatchWorkItem { [weak self] in
                self?.state = .idle
            }
            cancelledIdleWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
        } else {
            // Valid recording
            state = .processing
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.pushToTalkDidStopRecording(duration: duration)
            }
        }
    }
```

- [ ] **Step 4: Rewrite `cancelRecording()` to cancel all timers**

Replace the entire `cancelRecording()` method (lines 273-282):

```swift
    /// Cancel current recording
    func cancelRecording() {
        guard case .recording = state else { return }

        maxDurationWorkItem?.cancel()
        maxDurationWorkItem = nil

        state = .cancelled
        triggerKeyDown = false
        recordingStartTime = nil

        let workItem = DispatchWorkItem { [weak self] in
            self?.state = .idle
        }
        cancelledIdleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }
```

- [ ] **Step 5: Cancel timers in `markProcessingComplete()`**

Replace `markProcessingComplete()` (line 268-270):

```swift
    /// Mark processing as complete, return to idle
    func markProcessingComplete() {
        // Cancel any stale timers before returning to idle
        maxDurationWorkItem?.cancel()
        maxDurationWorkItem = nil
        cancelledIdleWorkItem?.cancel()
        cancelledIdleWorkItem = nil

        state = .idle
    }
```

- [ ] **Step 6: Cancel timers in `stop()`**

Add timer cleanup to the existing `stop()` method (lines 164-176). Replace:

```swift
    /// Stop listening for the trigger key
    func stop() {
        // Cancel any pending timers
        maxDurationWorkItem?.cancel()
        maxDurationWorkItem = nil
        cancelledIdleWorkItem?.cancel()
        cancelledIdleWorkItem = nil

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
```

- [ ] **Step 7: Build and verify**

Run:
```bash
cd /Volumes/JT2TB/CantoFlow/app && swift build 2>&1 | tail -5
```

Expected: `Build complete!` with no errors.

- [ ] **Step 8: Commit**

```bash
cd /Volumes/JT2TB/CantoFlow
git add app/Sources/CantoFlowApp/UI/PushToTalkManager.swift
git commit -m "fix(stability): replace fire-and-forget asyncAfter with cancellable DispatchWorkItem in PushToTalkManager

All delayed state transitions (max-duration timer, cancelled→idle delay) are now
stored as DispatchWorkItem properties and explicitly cancelled on every state exit.
Prevents stale timers from corrupting the state machine when users press the hotkey
in rapid succession."
```

---

### Task 2: Add network timeout to all TextPolisher API calls

**Files:**
- Modify: `app/Sources/CantoFlowApp/Core/TextPolisher.swift`

The default `URLSession.shared` timeout is 60 seconds. If an LLM API becomes unresponsive, the overlay hangs at "Polishing..." for a full minute, during which push-to-talk is blocked (PushToTalkManager state is `.processing`). A 10-second timeout is generous for LLM polish (typical response is 1-2s) and short enough to not block the user.

- [ ] **Step 1: Add timeout to Gemini request**

In `callGemini()`, after line 272 (`request.httpBody = jsonData`), find:

```swift
        request.httpBody = jsonData

        let (data, response) = try await URLSession.shared.data(for: request)
```

Add `request.timeoutInterval = 10` between them:

```swift
        request.httpBody = jsonData
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
```

- [ ] **Step 2: Add timeout to Qwen request**

In `callQwen()`, after line 337 (`request.httpBody = jsonData`), find:

```swift
        request.httpBody = jsonData

        let (data, response) = try await URLSession.shared.data(for: request)
```

Add `request.timeoutInterval = 10`:

```swift
        request.httpBody = jsonData
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
```

- [ ] **Step 3: Add timeout to OpenAI request**

In `callOpenAI()`, after line 396 (`request.httpBody = jsonData`), find:

```swift
        request.httpBody = jsonData

        let (data, response) = try await URLSession.shared.data(for: request)
```

Add `request.timeoutInterval = 10`:

```swift
        request.httpBody = jsonData
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
```

- [ ] **Step 4: Add timeout to Anthropic request**

In `callAnthropic()`, after line 464 (`request.httpBody = jsonData`), find:

```swift
        request.httpBody = jsonData

        let (data, response) = try await URLSession.shared.data(for: request)
```

Add `request.timeoutInterval = 10`:

```swift
        request.httpBody = jsonData
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
```

- [ ] **Step 5: Build and verify**

Run:
```bash
cd /Volumes/JT2TB/CantoFlow/app && swift build 2>&1 | tail -5
```

Expected: `Build complete!` with no errors.

- [ ] **Step 6: Commit**

```bash
cd /Volumes/JT2TB/CantoFlow
git add app/Sources/CantoFlowApp/Core/TextPolisher.swift
git commit -m "fix(stability): add 10s timeout to all LLM API requests in TextPolisher

Prevents the UI from hanging at 'Polishing...' for 60s (default URLSession timeout)
when an LLM API is unresponsive. 10s is generous for typical 1-2s polish latency and
short enough to unblock push-to-talk quickly on failure."
```

---

### Task 3: Add event tap re-enable retry with user notification

**Files:**
- Modify: `app/Sources/CantoFlowApp/UI/PushToTalkManager.swift`
- Modify: `app/Sources/CantoFlowApp/UI/MenuBarController.swift`

When macOS disables the CGEvent tap (due to timeout or user input), the current code does a single `CGEvent.tapEnable()` call with no verification, no retry, and no notification. If this fails, push-to-talk silently dies forever.

**Fix:** Add a retry loop (up to 3 attempts with 100ms delay), log the event, and if all retries fail, notify the user via NotificationManager and set `isRunning = false` so the menu bar can reflect the broken state.

- [ ] **Step 1: Add a delegate method for tap failure notification**

Add a new method to the `PushToTalkDelegate` protocol (after line 60 in the current file — but the file was already modified in Task 1, so locate the protocol):

```swift
/// Delegate protocol for push-to-talk events
protocol PushToTalkDelegate: AnyObject {
    func pushToTalkDidStartRecording()
    func pushToTalkDidStopRecording(duration: TimeInterval)
    func pushToTalkDidCancel(reason: String)
    func pushToTalkStateDidChange(_ state: PushToTalkState)
    func pushToTalkDidLoseEventTap()
}
```

- [ ] **Step 2: Replace the inline re-enable with a retry method**

Add a new private method to `PushToTalkManager`, right before the `handleEvent` method:

```swift
    /// Attempt to re-enable the event tap with retries.
    /// Called from the event tap callback when macOS disables the tap.
    private func reEnableEventTap() {
        guard let tap = eventTap else {
            isRunning = false
            delegate?.pushToTalkDidLoseEventTap()
            return
        }

        // Try up to 3 times with a short delay between attempts
        for attempt in 1...3 {
            CGEvent.tapEnable(tap: tap, enable: true)

            // Verify the tap is actually enabled by checking if it's valid
            if CGEvent.tapIsEnabled(tap: tap) {
                if attempt > 1 {
                    print("[PushToTalk] Event tap re-enabled after \(attempt) attempts")
                }
                return
            }

            if attempt < 3 {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }

        // All retries failed — notify user
        print("[PushToTalk] ERROR: Failed to re-enable event tap after 3 attempts")
        isRunning = false
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.pushToTalkDidLoseEventTap()
        }
    }
```

- [ ] **Step 3: Update the event tap callback to use the retry method**

Replace the tap-disabled handling inside the `start()` method's callback (the block at lines 134-138 in the original file). Find this inside the callback closure:

```swift
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = manager.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
```

Replace with:

```swift
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    manager.reEnableEventTap()
                    return Unmanaged.passUnretained(event)
                }
```

- [ ] **Step 4: Implement `pushToTalkDidLoseEventTap()` in MenuBarController**

Add the new delegate method to `MenuBarController.swift`, after the existing `pushToTalkStateDidChange` method (around line 539-541):

```swift
    func pushToTalkDidLoseEventTap() {
        NotificationManager.shared.notifyError(
            "Hotkey listener stopped responding. Please restart CantoFlow. If this persists, re-enable Accessibility + Input Monitoring in System Settings."
        )
    }
```

- [ ] **Step 5: Build and verify**

Run:
```bash
cd /Volumes/JT2TB/CantoFlow/app && swift build 2>&1 | tail -5
```

Expected: `Build complete!` with no errors.

- [ ] **Step 6: Commit**

```bash
cd /Volumes/JT2TB/CantoFlow
git add app/Sources/CantoFlowApp/UI/PushToTalkManager.swift app/Sources/CantoFlowApp/UI/MenuBarController.swift
git commit -m "fix(stability): add event tap re-enable retry with user notification

When macOS disables the CGEvent tap (timeout or user input), the app now retries
re-enabling up to 3 times with 100ms delays. If all retries fail, the user is
notified via system notification with actionable guidance (restart app or check
System Settings permissions)."
```

---

## Manual Verification Checklist

After all 3 tasks are complete, test these scenarios:

1. **Rapid double-press:** Press Fn quickly twice (<0.5s gap). Second press should start a new recording cleanly.
2. **Cancel + immediate re-press:** Press Fn, release quickly (<0.3s, triggers cancel), immediately press Fn again. Should start recording on the second press.
3. **Polish timeout:** Temporarily set an invalid API key. Recording should complete with raw text in ~10s, not hang for 60s.
4. **Long idle then press:** Leave the app idle for 10+ minutes, then press Fn. Recording should start immediately (event tap still alive).
5. **Menu bar state after error:** After any error (too short, STT fail, polish timeout), the menu bar should return to "CantoFlow" idle state and Fn should work again.
