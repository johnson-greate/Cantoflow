import Foundation

/// Serializes access to the local ASR engine so push-to-talk and a file batch
/// can never run two Qwen processes at once (PRD §17, FR-040/041).
///
/// Lock-based (not @MainActor) so it can be acquired/released from any context —
/// PTT runs on the main thread, the file batch may release from background work.
/// Never decide ownership by scanning the process list; that races.
final class ASRWorkCoordinator {
    static let shared = ASRWorkCoordinator()

    enum Owner: Equatable {
        case pushToTalk
        case fileBatch(UUID)
    }

    private let lock = NSLock()
    private var _owner: Owner?

    /// Internal (not private) so tests can use isolated instances; production
    /// code always goes through `shared`.
    init() {}

    var owner: Owner? {
        lock.lock(); defer { lock.unlock() }
        return _owner
    }

    var isBusy: Bool { owner != nil }

    var isPushToTalkActive: Bool { owner == .pushToTalk }

    var isFileBatchActive: Bool {
        if case .fileBatch = owner { return true }
        return false
    }

    /// Acquire ownership. Returns true if granted (or already held by the SAME
    /// owner — re-entrant), false if a different owner currently holds it.
    @discardableResult
    func tryAcquire(_ owner: Owner) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let current = _owner {
            return current == owner
        }
        _owner = owner
        return true
    }

    /// Release ownership only if `owner` currently holds it (no-op otherwise).
    func release(_ owner: Owner) {
        lock.lock(); defer { lock.unlock() }
        if _owner == owner {
            _owner = nil
        }
    }
}
