import AppKit
import ApplicationServices

/// Watches the focused text element for user corrections after STT insertion.
/// No keylogger required — uses only Accessibility API (already granted).
///
/// Flow:
///   1. STTPipeline calls `start(element:insertedText:)` after final text insertion.
///   2. After 30 seconds (or `flush()` before next recording), we re-read the element.
///   3. Diff original inserted text vs the current content in that region.
///   4. Extract substituted phrases as vocabulary candidates.
///   5. Auto-add new terms to personal vocabulary + notify user.
@MainActor
final class CorrectionWatcher {
    static let shared = CorrectionWatcher()

    private struct WatchSession {
        let element: AXUIElement
        let insertedText: String
        let contextAnchor: String   // text immediately before insertion, for re-anchoring
    }

    private var session: WatchSession?
    private var watchTask: Task<Void, Never>?

    private static let watchWindowNs: UInt64 = 30_000_000_000  // 30 seconds

    private init() {}

    // MARK: - Public API

    /// Begin watching `element` for corrections to `insertedText`.
    /// Cancels any previous session automatically.
    func start(element: AXUIElement, insertedText: String) {
        cancel()
        guard !insertedText.isEmpty else { return }

        let anchor = captureAnchor(element: element, before: insertedText)
        session = WatchSession(element: element, insertedText: insertedText, contextAnchor: anchor)

        watchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.watchWindowNs)
            guard !Task.isCancelled else { return }
            self?.evaluate()
        }
        print("[CorrectionWatcher] Watching \(insertedText.count) chars for 30s")
    }

    /// Evaluate corrections immediately and cancel the timer.
    /// Call at the start of each new recording to capture corrections from the previous session.
    func flush() {
        watchTask?.cancel()
        watchTask = nil
        evaluate()
    }

    /// Cancel without evaluating (e.g. app quit).
    func cancel() {
        watchTask?.cancel()
        watchTask = nil
        session = nil
    }

    // MARK: - Evaluation

    private func evaluate() {
        guard let s = session else { return }
        session = nil

        guard let currentText = readValue(s.element) else { return }

        guard let region = locateRegion(
            in: currentText,
            anchor: s.contextAnchor,
            originalLength: s.insertedText.count
        ), region != s.insertedText else { return }

        let candidates = diffCandidates(original: s.insertedText, corrected: region)
        guard !candidates.isEmpty else { return }

        var added: [String] = []
        for term in candidates {
            let entry = VocabEntry(
                term: term,
                pronunciationHint: nil,
                category: .other,
                notes: "語音修訂自動學習"
            )
            if VocabularyStore.shared.addPersonalEntry(entry) {
                added.append(term)
            }
        }

        if !added.isEmpty {
            let list = added.joined(separator: "、")
            NotificationManager.shared.notify("自動加入詞庫：\(list)", title: "CantoFlow 學習")
            print("[CorrectionWatcher] Auto-added vocabulary: \(list)")
        }
    }

    // MARK: - AX Helpers

    private func readValue(_ element: AXUIElement) -> String? {
        var obj: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &obj) == .success else {
            return nil
        }
        return obj as? String
    }

    /// Capture up to 30 chars immediately before `inserted` in the element's current value.
    private func captureAnchor(element: AXUIElement, before inserted: String) -> String {
        guard let full = readValue(element),
              let range = full.range(of: inserted, options: .backwards) else { return "" }
        let end = range.lowerBound
        let start = full.index(end, offsetBy: -30, limitedBy: full.startIndex) ?? full.startIndex
        return String(full[start..<end])
    }

    /// Locate the text region in `text` that corresponds to our original insertion,
    /// using `anchor` as a prefix anchor. Returns the (possibly edited) content of that region.
    private func locateRegion(in text: String, anchor: String, originalLength: Int) -> String? {
        let searchFrom: String.Index
        if anchor.isEmpty {
            searchFrom = text.startIndex
        } else if let r = text.range(of: anchor) {
            searchFrom = r.upperBound
        } else {
            return nil  // anchor disappeared — field was cleared or is unrelated
        }

        guard searchFrom < text.endIndex else { return nil }

        // Window = original length + 50% buffer to absorb user additions
        let windowLen = originalLength + max(8, originalLength / 2)
        let remaining = text.distance(from: searchFrom, to: text.endIndex)
        let end = text.index(searchFrom, offsetBy: min(windowLen, remaining))
        let region = String(text[searchFrom..<end])
        return region.isEmpty ? nil : region
    }

    // MARK: - Diff & Candidate Extraction

    private enum Op {
        case keep(Character), delete(Character), insert(Character)
    }

    /// LCS-based character diff producing a sequence of keep/delete/insert ops.
    private func lcsOps(_ a: [Character], _ b: [Character]) -> [Op] {
        let m = a.count, n = b.count
        guard m > 0 || n > 0 else { return [] }
        // Guard against very long inputs — O(mn) must stay fast
        guard m <= 200, n <= 200 else { return [] }

        var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                dp[i][j] = a[i-1] == b[j-1]
                    ? dp[i-1][j-1] + 1
                    : max(dp[i-1][j], dp[i][j-1])
            }
        }

        var ops: [Op] = []
        var i = m, j = n
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && a[i-1] == b[j-1] {
                ops.append(.keep(a[i-1])); i -= 1; j -= 1
            } else if j > 0 && (i == 0 || dp[i][j-1] >= dp[i-1][j]) {
                ops.append(.insert(b[j-1])); j -= 1
            } else {
                ops.append(.delete(a[i-1])); i -= 1
            }
        }
        return ops.reversed()
    }

    /// Extract vocabulary candidates from substitution blocks in the diff.
    ///
    /// A substitution is a run of deletes followed immediately by inserts.
    /// The inserted text is the corrected form. We also try to extend it with
    /// adjacent kept characters to form a meaningful compound (e.g. "拎" → "拎貨").
    private func diffCandidates(original: String, corrected: String) -> [String] {
        let ops = lcsOps(Array(original), Array(corrected))
        var candidates: [String] = []
        var i = 0

        while i < ops.count {
            // Collect a run of consecutive deletes
            var i2 = i
            while i2 < ops.count, case .delete = ops[i2] { i2 += 1 }
            guard i2 > i else { i += 1; continue }  // no deletes found, advance

            // Collect consecutive inserts right after the deletes
            var inserted = ""
            var j = i2
            while j < ops.count, case .insert(let c) = ops[j] { inserted.append(c); j += 1 }
            guard !inserted.isEmpty else { i = i2 + 1; continue }  // delete-only, no substitution

            // Try to extend the inserted form with adjacent kept characters (right side)
            // This turns single-char corrections like "拿"→"拎" into compounds like "拎貨"
            var extended = inserted
            var k = j
            while k < ops.count, extended.count < 8 {
                guard case .keep(let c) = ops[k] else { break }
                extended.append(c)
                k += 1
            }

            let candidate = isValidCandidate(extended) ? extended
                          : isValidCandidate(inserted)  ? inserted
                          : nil
            if let c = candidate { candidates.append(c) }
            i = j
        }

        return candidates
    }

    /// Valid vocabulary candidate: 2–8 characters, contains at least one CJK character.
    private func isValidCandidate(_ s: String) -> Bool {
        guard s.count >= 2, s.count <= 8 else { return false }
        return s.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value)    // CJK Unified Ideographs
            || (0x3400...0x4DBF).contains($0.value) // CJK Extension A
        }
    }
}
