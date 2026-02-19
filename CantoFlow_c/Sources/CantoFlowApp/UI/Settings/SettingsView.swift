import SwiftUI

// MARK: - Settings Store

/// Observable bridge between the SwiftUI Settings UI and the live AppKit pipeline.
final class SettingsStore: ObservableObject {
    @Published var sttBackend: String
    var onSttBackendChange: ((String) -> Void)?

    init(sttBackend: String = "whisper") {
        self.sttBackend = sttBackend
    }
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

            Section("About") {
                LabeledContent("Version", value: "\(appShortVersion) (\(appBuildNumber))")
                LabeledContent("Build Mode", value: "CLI / SPM")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Vocabulary View Model

@MainActor
final class VocabularyViewModel: ObservableObject {
    @Published var entries: [VocabEntry] = []
    @Published var searchText: String = ""

    init() { reload() }

    var filteredEntries: [VocabEntry] {
        guard !searchText.isEmpty else { return entries }
        let q = searchText.lowercased()
        return entries.filter {
            $0.term.lowercased().contains(q) ||
            $0.category.displayName.lowercased().contains(q) ||
            ($0.pronunciationHint?.lowercased().contains(q) ?? false) ||
            ($0.notes?.lowercased().contains(q) ?? false)
        }
    }

    var isFull: Bool { entries.count >= 500 }

    func reload() {
        entries = VocabularyStore.shared.personal.entries
    }

    @discardableResult
    func add(_ entry: VocabEntry) -> Bool {
        let ok = VocabularyStore.shared.addPersonalEntry(entry)
        reload()
        return ok
    }

    func remove(id: UUID) {
        VocabularyStore.shared.removePersonalEntry(id: id)
        reload()
    }

    func update(_ entry: VocabEntry) {
        VocabularyStore.shared.updatePersonalEntry(entry)
        reload()
    }
}

// MARK: - Vocabulary Tab

struct VocabularyTab: View {
    @StateObject private var viewModel = VocabularyViewModel()
    @State private var selectedID: UUID?
    @State private var showingAddSheet = false
    @State private var editingEntry: VocabEntry?

    var body: some View {
        VStack(spacing: 0) {
            List(viewModel.filteredEntries, id: \.id, selection: $selectedID) { entry in
                VocabRowView(entry: entry)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedID = entry.id
                        editingEntry = entry
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            let id = entry.id
                            let wasSelected = selectedID == id
                            if wasSelected { selectedID = nil }
                            // Defer @Published mutation out of the swipe-animation CA
                            // transaction to avoid NSConcretePointerArray crash on
                            // macOS 26 beta (same pattern as add/edit sheets).
                            DispatchQueue.main.async { viewModel.remove(id: id) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .searchable(text: $viewModel.searchText, placement: .toolbar, prompt: "Search terms...")
            .overlay { emptyStateOverlay }

            Divider()

            VocabBottomBar(
                isFull: viewModel.isFull,
                hasSelection: selectedID != nil,
                count: viewModel.entries.count,
                onAdd: { showingAddSheet = true },
                onRemove: {
                    if let id = selectedID {
                        selectedID = nil
                        DispatchQueue.main.async { viewModel.remove(id: id) }
                    }
                }
            )
        }
        .sheet(isPresented: $showingAddSheet) {
            AddEditTermSheet(entry: nil) { viewModel.add($0) }
        }
        .sheet(item: $editingEntry) { entry in
            AddEditTermSheet(entry: entry) { viewModel.update($0) }
        }
    }

    @ViewBuilder
    private var emptyStateOverlay: some View {
        if viewModel.entries.isEmpty {
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
        } else if viewModel.filteredEntries.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("No Results for \"\(viewModel.searchText)\"")
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
                        // Capture the entry value before any state changes.
                        let entry = VocabEntry(
                            id: existingEntry?.id ?? UUID(),
                            term: term.trimmingCharacters(in: .whitespacesAndNewlines),
                            pronunciationHint: pronunciationHint.isEmpty ? nil : pronunciationHint,
                            category: category,
                            notes: notes.isEmpty ? nil : notes
                        )
                        // Dismiss the sheet first, then update the parent list in the
                        // next run-loop cycle.  Calling onSave() and dismiss() in the
                        // same synchronous block causes SwiftUI to process a list
                        // re-render and a sheet dismissal in the same CoreAnimation
                        // transaction, which crashes on macOS 26 beta (over-release of
                        // a Combine subscriber block during CA commit).
                        dismiss()
                        DispatchQueue.main.async { onSave(entry) }
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
    @EnvironmentObject private var store: SettingsStore
    @AppStorage("qwenAPIKey") private var qwenAPIKey: String = ""
    @AppStorage("openaiAPIKey") private var openaiAPIKey: String = ""
    @AppStorage("anthropicAPIKey") private var anthropicAPIKey: String = ""

    var body: some View {
        Form {
            Section {
                Picker("STT Backend", selection: $store.sttBackend) {
                    Text("Whisper (Local)").tag("whisper")
                    Text("FunASR (Server)").tag("funasr")
                }
                .onChange(of: store.sttBackend) { newValue in
                    store.onSttBackendChange?(newValue)
                }

                Text("Whisper runs fully offline. FunASR requires the companion Python server on localhost:10095.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Speech Recognition")
            }

            Section {
                SecureField("Qwen API Key (QWEN_API_KEY)", text: $qwenAPIKey)
                SecureField("OpenAI API Key (OPENAI_API_KEY)", text: $openaiAPIKey)
                SecureField("Anthropic API Key (ANTHROPIC_API_KEY)", text: $anthropicAPIKey)

                Text("Stored in app preferences. Overrides environment variables. Takes effect on next launch.")
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
