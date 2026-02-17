import AppKit

// TODO: [Phase 3] Replace alert-based UI with SwiftUI Settings Window
// - Use SwiftUI for proper window lifecycle management
// - Add proper table view for vocabulary list with edit/delete per item
// - Add search/filter functionality
// - Add category management (place, person, slang, etc.)
// - Add export functionality
// - Reference: Consider using NSHostingController to embed SwiftUI in existing AppKit app

/// Simple vocabulary management using alerts (avoids complex window lifecycle issues)
/// NOTE: This is a temporary implementation. NSWindow/NSTableView caused crashes due to
/// view lifecycle issues. SwiftUI rewrite planned for Phase 3.
final class VocabularySettingsWindow {
    static let shared = VocabularySettingsWindow()

    private init() {}

    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        showMainMenu()
    }

    private func showMainMenu() {
        let entries = VocabularyStore.shared.personal.entries
        let hkCount = VocabularyStore.shared.hkCommon?.allTerms.count ?? 0

        let alert = NSAlert()
        alert.messageText = "Vocabulary Settings"

        var infoText = "Personal terms: \(entries.count) / 500\n"
        infoText += "HK common terms: \(hkCount)\n\n"

        if entries.isEmpty {
            infoText += "No personal terms added yet."
        } else {
            let termList = entries.prefix(20).map { "• \($0.term)" }.joined(separator: "\n")
            infoText += "Personal vocabulary:\n\(termList)"
            if entries.count > 20 {
                infoText += "\n... and \(entries.count - 20) more"
            }
        }

        alert.informativeText = infoText
        alert.alertStyle = .informational

        alert.addButton(withTitle: "Add Term...")
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Close")

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            addTermDialog()
        case .alertSecondButtonReturn:
            clearAllDialog()
        default:
            break
        }
    }

    private func addTermDialog() {
        let alert = NSAlert()
        alert.messageText = "Add Vocabulary Term"
        alert.informativeText = "Enter a word or phrase to add to your personal vocabulary:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.placeholderString = "e.g., 香港中文大學"
        alert.accessoryView = textField

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            let term = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !term.isEmpty {
                let existingTerms = VocabularyStore.shared.personal.entries.map { $0.term }
                if existingTerms.contains(term) {
                    let errorAlert = NSAlert()
                    errorAlert.messageText = "Term Already Exists"
                    errorAlert.informativeText = "'\(term)' is already in your vocabulary."
                    errorAlert.runModal()
                } else {
                    let entry = VocabEntry(term: term, category: .other)
                    if VocabularyStore.shared.addPersonalEntry(entry) {
                        // Success - show main menu again
                        showMainMenu()
                    } else {
                        let errorAlert = NSAlert()
                        errorAlert.messageText = "Vocabulary Full"
                        errorAlert.informativeText = "Maximum capacity (500 terms) reached."
                        errorAlert.runModal()
                    }
                }
            }
        }
    }

    private func clearAllDialog() {
        let entries = VocabularyStore.shared.personal.entries
        guard !entries.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No Terms to Clear"
            alert.informativeText = "Your personal vocabulary is already empty."
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Clear All Terms?"
        alert.informativeText = "This will remove all \(entries.count) personal vocabulary terms. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            // Remove all entries one by one
            for entry in entries {
                VocabularyStore.shared.removePersonalEntry(id: entry.id)
            }

            let successAlert = NSAlert()
            successAlert.messageText = "Vocabulary Cleared"
            successAlert.informativeText = "All personal terms have been removed."
            successAlert.runModal()
        }
    }

    // Legacy method for compatibility
    func closeWindow() {
        // No-op since we're using alerts now
    }
}
