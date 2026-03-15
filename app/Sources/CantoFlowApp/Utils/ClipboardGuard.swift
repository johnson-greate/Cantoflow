import AppKit

/// Guard for preserving and restoring clipboard content
final class ClipboardGuard {
    private var savedItems: [NSPasteboardItem] = []
    private var savedChangeCount: Int = 0

    /// Save current clipboard content
    func save() {
        let pasteboard = NSPasteboard.general
        savedChangeCount = pasteboard.changeCount

        savedItems = []
        if let items = pasteboard.pasteboardItems {
            for item in items {
                let newItem = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) {
                        newItem.setData(data, forType: type)
                    }
                }
                savedItems.append(newItem)
            }
        }
    }

    /// Restore previously saved clipboard content
    func restore() {
        guard !savedItems.isEmpty else { return }

        let pasteboard = NSPasteboard.general

        // Only restore if clipboard wasn't changed by something else
        // (user might have copied something manually)
        pasteboard.clearContents()
        pasteboard.writeObjects(savedItems)

        savedItems = []
    }

    /// Clear saved content without restoring
    func clear() {
        savedItems = []
    }
}
