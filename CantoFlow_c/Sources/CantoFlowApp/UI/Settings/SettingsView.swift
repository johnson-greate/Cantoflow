import SwiftUI

// MARK: - Settings Store

/// Plain (non-ObservableObject) callback bridge between the Settings UI and the
/// live AppKit pipeline.  Previously ObservableObject, which caused
/// NSConcretePointerArray Combine subscriber crashes on macOS 26 beta whenever
/// a CA transaction committed while the settings window was open.
/// ModelsTab now binds directly to @AppStorage("sttBackend") instead.
final class SettingsStore {
    var onSttBackendChange: ((String) -> Void)?
}

// MARK: - Root Settings View

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(0)

            VocabularyTab()
                .tabItem { Label("Vocabulary", systemImage: "text.book.closed") }
                .tag(1)

            ModelsTab()
                .tabItem { Label("Models", systemImage: "cpu") }
                .tag(2)
        }
        .frame(width: 560, height: 440)
    }
}

// MARK: - General Tab

struct GeneralTab: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("soundFeedback") private var soundFeedback = true
    @AppStorage("polishStyle") private var polishStyleRaw: String = PolishStyle.cantonese.rawValue

    private var polishStyle: PolishStyle {
        PolishStyle(rawValue: polishStyleRaw) ?? .cantonese
    }

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .disabled(true)

                Text("Launch at Login requires installation as a .app bundle. Not available in CLI mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Feedback") {
                Toggle("Sound Feedback", isOn: $soundFeedback)

                Text("Plays a system sound when recording starts and stops.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Text Polish") {
                Picker("潤飾風格", selection: $polishStyleRaw) {
                    ForEach(PolishStyle.allCases, id: \.rawValue) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text(polishStyle.styleDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: appBuildVersion)
                LabeledContent("Build Mode", value: "CLI / SPM")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Vocabulary Tab
//
// Uses plain @State instead of ObservableObject/@Published to avoid the
// NSConcretePointerArray over-release crash on macOS 26 beta.  That crash
// occurs when any @Published change fires a Combine subscriber notification
// during a CA transaction commit (e.g. swipe-delete animation, sheet dismiss).
// @State uses SwiftUI's internal _StateBox graph mechanism, not Combine, so
// it is immune to that CA/Combine interaction bug.

struct VocabularyTab: View {
    @State private var entries: [VocabEntry] = VocabularyStore.shared.personal.entries
    @State private var searchText: String = ""
    @State private var selectedID: UUID?
    @State private var showingAddSheet = false
    @State private var editingEntry: VocabEntry?
    // Staging: holds the entry returned by AddEditTermSheet until the sheet's
    // dismiss animation completes.  The actual VocabularyStore write + list
    // reload happens in onDismiss, which fires after the animation finishes and
    // outside any CoreAnimation transaction — avoiding the
    // _Block_release + IMKCFRunLoopWakeUpReliable crash on macOS 26 beta.
    @State private var stagedAdd: VocabEntry? = nil
    @State private var stagedEdit: VocabEntry? = nil

    private var filteredEntries: [VocabEntry] {
        guard !searchText.isEmpty else { return entries }
        let q = searchText.lowercased()
        return entries.filter {
            $0.term.lowercased().contains(q) ||
            $0.category.displayName.lowercased().contains(q) ||
            ($0.pronunciationHint?.lowercased().contains(q) ?? false) ||
            ($0.notes?.lowercased().contains(q) ?? false)
        }
    }

    private var isFull: Bool { entries.count >= 500 }

    private func reload() {
        entries = VocabularyStore.shared.personal.entries
    }

    private func addEntry(_ entry: VocabEntry) {
        _ = VocabularyStore.shared.addPersonalEntry(entry)
        reload()
    }

    private func removeEntry(id: UUID) {
        VocabularyStore.shared.removePersonalEntry(id: id)
        reload()
    }

    private func updateEntry(_ entry: VocabEntry) {
        VocabularyStore.shared.updatePersonalEntry(entry)
        reload()
    }

    var body: some View {
        VStack(spacing: 0) {
            List(filteredEntries, id: \.id, selection: $selectedID) { entry in
                VocabRowView(entry: entry)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedID = entry.id
                        editingEntry = entry
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            let id = entry.id
                            if selectedID == id { selectedID = nil }
                            // Defer past the swipe-reveal CA animation to avoid
                            // NSConcretePointerArray dealloc-in-CA-transaction crash
                            // on macOS 26 beta.
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(50))
                                removeEntry(id: id)
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search terms...")
            .overlay { emptyStateOverlay }

            Divider()

            VocabBottomBar(
                isFull: isFull,
                hasSelection: selectedID != nil,
                count: entries.count,
                onAdd: { showingAddSheet = true },
                onRemove: {
                    if let id = selectedID {
                        selectedID = nil
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(50))
                            removeEntry(id: id)
                        }
                    }
                }
            )
        }
        // onDismiss fires after the dismiss animation completes — guaranteed to
        // be outside any CA transaction, so state mutations are safe here.
        .sheet(isPresented: $showingAddSheet, onDismiss: {
            if let entry = stagedAdd {
                addEntry(entry)
                stagedAdd = nil
            }
        }) {
            AddEditTermSheet(entry: nil) { stagedAdd = $0 }
        }
        .sheet(item: $editingEntry, onDismiss: {
            if let entry = stagedEdit {
                updateEntry(entry)
                stagedEdit = nil
            }
        }) { entry in
            AddEditTermSheet(entry: entry) { stagedEdit = $0 }
        }
    }

    @ViewBuilder
    private var emptyStateOverlay: some View {
        if entries.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "text.book.closed")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("No Vocabulary Terms")
                    .font(.title3.bold())
                Text("Tap + to add personal terms that improve recognition accuracy.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredEntries.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("No Results for \"\(searchText)\"")
                    .font(.title3.bold())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Vocabulary Bottom Bar

private struct VocabBottomBar: View {
    let isFull: Bool
    let hasSelection: Bool
    let count: Int
    let onAdd: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .frame(width: 26, height: 22)
            }
            .buttonStyle(.borderless)
            .disabled(isFull)
            .help("Add new term")

            Divider().frame(height: 18).padding(.horizontal, 1)

            Button(action: onRemove) {
                Image(systemName: "minus")
                    .frame(width: 26, height: 22)
            }
            .buttonStyle(.borderless)
            .disabled(!hasSelection)
            .help("Remove selected term")

            Spacer()

            Text("\(count) / 500")
                .font(.caption)
                .foregroundStyle(isFull ? Color.orange : Color.secondary)
                .padding(.trailing, 10)
        }
        .padding(.vertical, 3)
        .background(.bar)
    }
}

// MARK: - Vocabulary Row

struct VocabRowView: View {
    let entry: VocabEntry

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.term)
                    .font(.body.bold())

                HStack(spacing: 6) {
                    Text(entry.category.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let hint = entry.pronunciationHint, !hint.isEmpty {
                        Text("·").font(.caption).foregroundStyle(.tertiary)
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .italic()
                    }
                }
            }

            Spacer()

            Image(systemName: "pencil")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Add / Edit Term Sheet

struct AddEditTermSheet: View {
    let existingEntry: VocabEntry?
    let onSave: (VocabEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var term: String
    @State private var pronunciationHint: String
    @State private var category: VocabCategory
    @State private var notes: String

    init(entry: VocabEntry?, onSave: @escaping (VocabEntry) -> Void) {
        self.existingEntry = entry
        self.onSave = onSave
        _term = State(initialValue: entry?.term ?? "")
        _pronunciationHint = State(initialValue: entry?.pronunciationHint ?? "")
        _category = State(initialValue: entry?.category ?? .other)
        _notes = State(initialValue: entry?.notes ?? "")
    }

    private var isEditing: Bool { existingEntry != nil }
    private var canSave: Bool { !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section("Term") {
                    TextField("Word or phrase (e.g. 香港中文大學)", text: $term)
                    TextField("Pronunciation hint (optional)", text: $pronunciationHint)
                }

                Section("Category") {
                    Picker("Category", selection: $category) {
                        ForEach(VocabCategory.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Notes") {
                    TextField("Optional notes or context", text: $notes)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "Edit Term" : "Add Term")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") {
                        let entry = VocabEntry(
                            id: existingEntry?.id ?? UUID(),
                            term: term.trimmingCharacters(in: .whitespacesAndNewlines),
                            pronunciationHint: pronunciationHint.isEmpty ? nil : pronunciationHint,
                            category: category,
                            notes: notes.isEmpty ? nil : notes
                        )
                        // onSave merely stages the entry in the parent (@State var
                        // stagedAdd/stagedEdit) — no list re-render, no CA conflict.
                        // The actual VocabularyStore write + reload happens in the
                        // parent's onDismiss handler, after the animation completes.
                        onSave(entry)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
        .frame(width: 400, height: 320)
    }
}

// MARK: - Models Tab

struct ModelsTab: View {
    @AppStorage("qwenAPIKey") private var qwenAPIKey: String = ""
    @AppStorage("openaiAPIKey") private var openaiAPIKey: String = ""
    @AppStorage("anthropicAPIKey") private var anthropicAPIKey: String = ""

    var body: some View {
        Form {
            Section {
                SecureField("Qwen API Key (QWEN_API_KEY)", text: $qwenAPIKey)
                SecureField("OpenAI API Key (OPENAI_API_KEY)", text: $openaiAPIKey)
                SecureField("Anthropic API Key (ANTHROPIC_API_KEY)", text: $anthropicAPIKey)

                Text("Stored in app preferences. Environment variables take precedence. Takes effect immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("LLM Polish API Keys")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
