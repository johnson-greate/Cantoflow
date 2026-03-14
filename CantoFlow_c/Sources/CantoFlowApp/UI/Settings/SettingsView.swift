import AppKit
import SwiftUI

// MARK: - Settings Store

/// Plain (non-ObservableObject) callback bridge between the Settings UI and the
/// live AppKit pipeline.  Previously ObservableObject, which caused
/// NSConcretePointerArray Combine subscriber crashes on macOS 26 beta whenever
/// a CA transaction committed while the settings window was open.
/// The settings tabs bind directly to @AppStorage instead.
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

            APIKeysTab()
                .tabItem { Label("API Keys", systemImage: "key.fill") }
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
    @AppStorage(AudioDeviceManager.preferredInputDeviceDefaultsKey) private var preferredInputDeviceUID: String = ""
    @State private var inputDevices: [AudioInputDevice] = AudioDeviceManager.shared.availableInputDevices()
    @State private var startupStatusMessage: String = ""

    private var polishStyle: PolishStyle {
        PolishStyle(rawValue: polishStyleRaw) ?? .cantonese
    }

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at Login", isOn: $launchAtLogin)

                Text("Uses a per-user LaunchAgent, so it works for the current CLI-style installation too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !startupStatusMessage.isEmpty {
                    Text(startupStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }


            Section("Shortcut Key") {
                HotkeyRecorderView()
                
                Text("Click the box above, then type any key or key combination to record it (e.g. F12, Option+Space, or Fn).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Input Device") {
                Picker("Microphone", selection: $preferredInputDeviceUID) {
                    Text(systemDefaultInputLabel).tag("")
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }

                Button("Refresh Device List") {
                    reloadInputDevices()
                }

                Text("Selected microphone is used on the next recording. If the chosen device is unavailable, CantoFlow falls back to the system default input.")
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
        .onAppear {
            reloadInputDevices()
            launchAtLogin = LaunchAtLoginManager.shared.isEnabled
        }
        .onChange(of: launchAtLogin) { newValue in
            do {
                try LaunchAtLoginManager.shared.setEnabled(newValue)
                startupStatusMessage = newValue
                    ? "Launch at Login enabled."
                    : "Launch at Login disabled."
            } catch {
                startupStatusMessage = "Launch at Login update failed: \(error.localizedDescription)"
                launchAtLogin = LaunchAtLoginManager.shared.isEnabled
            }
        }
    }

    private var systemDefaultInputLabel: String {
        let defaultName = AudioDeviceManager.shared.defaultInputDevice()?.name ?? "System Default"
        return "System Default (\(defaultName))"
    }

    private func reloadInputDevices() {
        inputDevices = AudioDeviceManager.shared.availableInputDevices()
        if !preferredInputDeviceUID.isEmpty,
           !inputDevices.contains(where: { $0.uid == preferredInputDeviceUID }) {
            preferredInputDeviceUID = ""
        }
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
    private enum VocabularyFilterTab: String, CaseIterable, Identifiable {
        case all
        case place
        case action
        case slang
        case food
        case company
        case tech
        case other

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "全部"
            case .place: return "地名"
            case .action: return "動作"
            case .slang: return "口頭禪"
            case .food: return "食物"
            case .company: return "公司"
            case .tech: return "技術"
            case .other: return "其他"
            }
        }

        func matches(_ category: VocabCategory) -> Bool {
            switch self {
            case .all: return true
            case .place: return category == .place
            case .action: return category == .action
            case .slang: return category == .slang
            case .food: return category == .food
            case .company: return category == .company
            case .tech: return category == .tech
            case .other: return category == .other || category == .person || category == .product || category == .transport
            }
        }
    }

    @State private var entries: [VocabEntry] = VocabularyStore.shared.personal.entries
    @State private var searchText: String = ""
    @State private var selectedID: UUID?
    @State private var showingAddSheet = false
    @State private var editingEntry: VocabEntry?
    @State private var selectedTab: VocabularyFilterTab = .all
    @State private var starterPackMessage: String = ""
    @State private var importPreview: VocabularyImportPreview?
    // Staging: holds the entry returned by AddEditTermSheet until the sheet's
    // dismiss animation completes.  The actual VocabularyStore write + list
    // reload happens in onDismiss, which fires after the animation finishes and
    // outside any CoreAnimation transaction — avoiding the
    // _Block_release + IMKCFRunLoopWakeUpReliable crash on macOS 26 beta.
    @State private var stagedAdd: VocabEntry? = nil
    @State private var stagedEdit: VocabEntry? = nil

    private var filteredEntries: [VocabEntry] {
        let categoryFiltered = entries.filter { selectedTab.matches($0.category) }

        guard !searchText.isEmpty else { return categoryFiltered }
        let q = searchText.lowercased()
        return categoryFiltered.filter {
            $0.term.lowercased().contains(q) ||
            $0.category.displayName.lowercased().contains(q) ||
            ($0.pronunciationHint?.lowercased().contains(q) ?? false) ||
            ($0.notes?.lowercased().contains(q) ?? false)
        }
    }

    private var isFull: Bool { entries.count >= 500 }

    private func reload() {
        DispatchQueue.main.async {
            entries = VocabularyStore.shared.personal.entries
        }
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

    private func importStarterPack() {
        let added = VocabularyStore.shared.importHKStarterPack(limit: 100)
        DispatchQueue.main.async {
            selectedTab = .all
            starterPackMessage = added > 0
                ? "Imported Starter Pack #1: \(added) Hong Kong terms."
                : "No new starter terms imported."
            reload()
        }
    }

    private func importStarterPack2() {
        let added = VocabularyStore.shared.importHKStarterPack2(limit: 100)
        DispatchQueue.main.async {
            selectedTab = .all
            starterPackMessage = added > 0
                ? "Imported Starter Pack #2: \(added) malls / estates / roads / office terms."
                : "No new starter terms imported."
            reload()
        }
    }

    private func exportVocabulary() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "cantoflow-personal-vocab.json"
        panel.allowedContentTypes = [.json]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try VocabularyStore.shared.exportPersonalVocabulary(to: url)
            DispatchQueue.main.async {
                starterPackMessage = "Exported personal vocabulary to \(url.lastPathComponent)."
            }
        } catch {
            DispatchQueue.main.async {
                starterPackMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func importVocabulary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            importPreview = try VocabularyStore.shared.previewImportPersonalVocabulary(from: url)
        } catch {
            DispatchQueue.main.async {
                starterPackMessage = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    private func confirmImportVocabulary() {
        guard let preview = importPreview else { return }

        do {
            let added = try VocabularyStore.shared.importPersonalVocabulary(from: preview.sourceURL)
            DispatchQueue.main.async {
                selectedTab = .all
                starterPackMessage = added > 0
                    ? "Imported \(added) terms from \(preview.sourceURL.lastPathComponent)."
                    : "No new terms imported from \(preview.sourceURL.lastPathComponent)."
                importPreview = nil
                reload()
            }
        } catch {
            DispatchQueue.main.async {
                starterPackMessage = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            vocabularyTabs

            if !starterPackMessage.isEmpty {
                Text(starterPackMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }

            List(filteredEntries, id: \.id) { entry in
                Button {
                    DispatchQueue.main.async {
                        selectedID = entry.id
                        editingEntry = entry
                    }
                } label: {
                    VocabRowView(entry: entry)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
                onExport: exportVocabulary,
                onImport: importVocabulary,
                onImportStarterPack: importStarterPack,
                onImportStarterPack2: importStarterPack2,
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
        .sheet(item: $importPreview) { preview in
            VocabularyImportPreviewSheet(
                preview: preview,
                onCancel: { importPreview = nil },
                onConfirm: { confirmImportVocabulary() }
            )
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

    private var vocabularyTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(VocabularyFilterTab.allCases) { tab in
                    Button(tab.title) {
                        selectedTab = tab
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(selectedTab == tab ? Color.accentColor.opacity(0.16) : Color(NSColor.controlBackgroundColor))
                    .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.primary)
                    .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }
}

private struct VocabularyImportPreviewSheet: View {
    let preview: VocabularyImportPreview
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var duplicatePreview: String {
        let sample = preview.duplicateTerms.prefix(12)
        if sample.isEmpty { return "None" }
        return sample.joined(separator: "、")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Import Preview") {
                    LabeledContent("File", value: preview.sourceURL.lastPathComponent)
                    LabeledContent("Total entries", value: "\(preview.totalEntries)")
                    LabeledContent("Can import", value: "\(preview.importableCount)")
                    LabeledContent("Duplicates", value: "\(preview.duplicateCount)")
                    LabeledContent("Blank terms", value: "\(preview.blankTerms)")
                    LabeledContent("Capacity remaining", value: "\(preview.capacityRemaining)")
                }

                Section("Duplicate Terms Sample") {
                    Text(duplicatePreview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if preview.willFillToCapacity {
                    Section("Capacity Note") {
                        Text("Import will stop at the 500-term limit. Some valid terms may remain unimported.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Preview Import")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm Import") {
                        onConfirm()
                        dismiss()
                    }
                    .disabled(preview.importableCount == 0)
                }
            }
        }
        .frame(width: 460, height: 360)
    }
}

// MARK: - Vocabulary Bottom Bar

private struct VocabBottomBar: View {
    let isFull: Bool
    let hasSelection: Bool
    let count: Int
    let onExport: () -> Void
    let onImport: () -> Void
    let onImportStarterPack: () -> Void
    let onImportStarterPack2: () -> Void
    let onAdd: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onExport) {
                Text("Export")
                    .font(.caption)
                    .frame(minWidth: 54, minHeight: 22)
            }
            .buttonStyle(.borderless)
            .help("Export personal vocabulary JSON")

            Divider().frame(height: 18).padding(.horizontal, 1)

            Button(action: onImport) {
                Text("Import")
                    .font(.caption)
                    .frame(minWidth: 54, minHeight: 22)
            }
            .buttonStyle(.borderless)
            .help("Import personal vocabulary JSON")

            Divider().frame(height: 18).padding(.horizontal, 1)

            Button(action: onImportStarterPack) {
                Text("Starter #1")
                    .font(.caption)
                    .frame(minWidth: 68, minHeight: 22)
            }
            .buttonStyle(.borderless)
            .disabled(isFull)
            .help("Import 100 Hong Kong starter terms")

            Divider().frame(height: 18).padding(.horizontal, 1)

            Button(action: onImportStarterPack2) {
                Text("Starter #2")
                    .font(.caption)
                    .frame(minWidth: 68, minHeight: 22)
            }
            .buttonStyle(.borderless)
            .disabled(isFull)
            .help("Import malls, estates, roads, and office terms")

            Divider().frame(height: 18).padding(.horizontal, 1)

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
    private var normalizedTerm: String { term.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isDuplicate: Bool {
        VocabularyStore.shared.containsPersonalTerm(normalizedTerm, excluding: existingEntry?.id)
    }
    private var canSave: Bool { !normalizedTerm.isEmpty && !isDuplicate }

    var body: some View {
        NavigationStack {
            Form {
                Section("Term") {
                    TextField("Word or phrase (e.g. 香港中文大學)", text: $term)
                    TextField("Pronunciation hint (optional)", text: $pronunciationHint)

                    if isDuplicate {
                        Text("This term already exists in your personal vocabulary.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
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
                            term: normalizedTerm,
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

// MARK: - API Keys Tab

struct APIKeysTab: View {
    @AppStorage("geminiAPIKey") private var geminiAPIKey: String = ""
    @AppStorage("dashscopeAPIKey") private var dashscopeAPIKey: String = ""
    @AppStorage("qwenAPIKey") private var qwenAPIKey: String = ""
    @AppStorage("openaiAPIKey") private var openaiAPIKey: String = ""
    @State private var statusMessage: String = ""
    @State private var editingFieldID: String?
    @State private var testState: APIKeyTestState = .idle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Google Gemini") {
                    VStack(alignment: .leading, spacing: 12) {
                        apiKeyField(
                            title: "Gemini API Key",
                            envName: "GEMINI_API_KEY",
                            text: $geminiAPIKey
                        )

                        Text("Gemini polish 會用 Google Gemini endpoint 去潤飾 Whisper 文字，並配合 vocabulary 做校正。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox("Qwen / DashScope") {
                    VStack(alignment: .leading, spacing: 12) {
                        apiKeyField(
                            title: "DashScope API Key",
                            envName: "DASHSCOPE_API_KEY",
                            text: $dashscopeAPIKey
                        )
                        apiKeyField(
                            title: "Qwen API Key (legacy alias)",
                            envName: "QWEN_API_KEY",
                            text: $qwenAPIKey
                        )

                        Text("Qwen polish 會用這個 key 去潤飾 Whisper 文字，並配合 vocabulary 做校正。建議填 DashScope key。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox("Other Providers") {
                    VStack(alignment: .leading, spacing: 12) {
                        apiKeyField(
                            title: "OpenAI API Key",
                            envName: "OPENAI_API_KEY",
                            text: $openaiAPIKey
                        )
                    }
                }

                HStack(spacing: 10) {
                    Circle()
                        .fill(testState.color)
                        .frame(width: 10, height: 10)

                    Button("Test API Key Endpoint") {
                        testAPIKeyEndpoint()
                    }

                    Text(testState.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("API keys are stored in app preferences immediately. Testing uses the first available key in this order: Gemini, DashScope/Qwen, OpenAI.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func apiKeyField(title: String, envName: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
            Text(envName)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            if editingFieldID == envName {
                SecureField("", text: text, prompt: Text("Paste API key here"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit {
                        statusMessage = ""
                        editingFieldID = nil
                    }
            } else {
                Button {
                    statusMessage = ""
                    editingFieldID = envName
                } label: {
                    HStack {
                        Text(maskedAPIKey(text.wrappedValue))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(text.wrappedValue.isEmpty ? .secondary : .primary)
                        Spacer()
                        Text("Edit")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(NSColor.textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.25), lineWidth: 1)
                    )
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func maskedAPIKey(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Paste API key here" }
        guard trimmed.count > 8 else { return String(repeating: "•", count: trimmed.count) }

        let prefix = String(trimmed.prefix(4))
        let suffix = String(trimmed.suffix(4))
        let mask = String(repeating: "•", count: max(8, trimmed.count - 8))
        return prefix + mask + suffix
    }

    private func testAPIKeyEndpoint() {
        guard let target = currentTestTarget() else {
            testState = .failure("No API key entered")
            return
        }

        testState = .testing("Testing \(target.providerName)...")

        Task {
            let result = await performEndpointTest(target: target)
            await MainActor.run {
                switch result {
                case .success:
                    testState = .success("\(target.providerName) endpoint OK (200)")
                case .failure(let message):
                    testState = .failure("\(target.providerName) failed: \(message)")
                }
            }
        }
    }

    private func currentTestTarget() -> APIKeyTestTarget? {
        let dashscope = dashscopeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let gemini = geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let qwen = qwenAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let openai = openaiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        if !gemini.isEmpty {
            return .gemini(gemini)
        }
        if !dashscope.isEmpty {
            return .dashscope(dashscope)
        }
        if !qwen.isEmpty {
            return .dashscope(qwen)
        }
        if !openai.isEmpty {
            return .openAI(openai)
        }
        return nil
    }

    private func performEndpointTest(target: APIKeyTestTarget) async -> APIKeyEndpointTestResult {
        do {
            let request = target.request
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure("invalid response")
            }

            if httpResponse.statusCode == 200 {
                return .success(())
            }
            return .failure("HTTP \(httpResponse.statusCode)")
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

private enum APIKeyEndpointTestResult {
    case success(Void)
    case failure(String)
}

private enum APIKeyTestState {
    case idle
    case testing(String)
    case success(String)
    case failure(String)

    var color: Color {
        switch self {
        case .idle: return .gray
        case .testing: return .orange
        case .success: return .green
        case .failure: return .red
        }
    }

    var message: String {
        switch self {
        case .idle:
            return "No test run yet"
        case .testing(let message), .success(let message), .failure(let message):
            return message
        }
    }
}

private enum APIKeyTestTarget {
    case gemini(String)
    case dashscope(String)
    case openAI(String)

    var providerName: String {
        switch self {
        case .gemini: return "Gemini"
        case .dashscope: return "DashScope"
        case .openAI: return "OpenAI"
        }
    }

    var request: URLRequest {
        switch self {
        case .gemini(let apiKey):
            var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")!)
            request.httpMethod = "POST"
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = """
            {"contents":[{"parts":[{"text":"ping"}]}]}
            """.data(using: .utf8)
            return request
        case .dashscope(let apiKey):
            var request = URLRequest(url: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = """
            {"model":"qwen3.5-plus","messages":[{"role":"user","content":"ping"}],"max_tokens":1,"temperature":0}
            """.data(using: .utf8)
            return request
        case .openAI(let apiKey):
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.httpMethod = "GET"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            return request
        }
    }
}

// MARK: - Hotkey Recorder View

class HotkeyRecorderTracker: ObservableObject {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    private var pendingKeyCode: UInt16?
    private var pendingFlags: UInt64?
    
    var onHotkeyRecorded: ((UInt16, UInt64, Bool) -> Void)?

    func start() {
        stop()
        pendingKeyCode = nil
        pendingFlags = nil
        
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let tracker = Unmanaged<HotkeyRecorderTracker>.fromOpaque(refcon).takeUnretainedValue()
                
                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                let flags = event.flags.rawValue
                
                if type == .keyDown {
                    DispatchQueue.main.async {
                        tracker.onHotkeyRecorded?(keyCode, flags, false)
                    }
                    return nil // consume the event so it doesn't type into the background
                } else if type == .flagsChanged {
                    let flagsMask = CustomHotkey.normalizedModifiers(flags)
                    
                    // If the key specifically hit is a modifier (like Fn/179)
                    let mods: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 179]
                    if mods.contains(keyCode) {
                        if flagsMask == 0 {
                            // All modifiers released - save what we had
                            if let code = tracker.pendingKeyCode, let savedFlags = tracker.pendingFlags {
                                DispatchQueue.main.async {
                                    tracker.onHotkeyRecorded?(code, savedFlags, true)
                                }
                                tracker.pendingKeyCode = nil
                                tracker.pendingFlags = nil
                            }
                        } else {
                            // Modifier pressed down
                            tracker.pendingKeyCode = keyCode
                            tracker.pendingFlags = flags
                        }
                    }
                    return nil // consume the event
                }
                
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else { return }
        
        eventTap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return }
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
}

struct HotkeyRecorderView: View {
    @AppStorage("customHotkey") private var customHotkeyString: String = ""
    @State private var isRecording = false
    @StateObject private var tracker = HotkeyRecorderTracker()

    var currentHotkey: CustomHotkey {
        if let data = Data(base64Encoded: customHotkeyString),
           let decoded = try? JSONDecoder().decode(CustomHotkey.self, from: data) {
            return decoded
        } else if let data = customHotkeyString.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(CustomHotkey.self, from: data) {
            return decoded
        }
        return .defaultFn
    }

    var body: some View {
        Button(action: {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        }) {
            HStack {
                Text(isRecording ? "Listening for key press..." : currentHotkey.displayName)
                    .foregroundStyle(isRecording ? Color.accentColor : Color.primary)
                Spacer()
                if !isRecording {
                    Text("Click to record").font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle()) // Make empty space clickable
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isRecording ? Color.accentColor : Color.gray.opacity(0.2), lineWidth: 1)
        )
        .onAppear {
            tracker.onHotkeyRecorded = { keyCode, flags, isModifier in
                self.saveHotkey(keyCode: keyCode, modifiers: flags, isModifier: isModifier)
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        tracker.start()
    }

    private func stopRecording() {
        tracker.stop()
        isRecording = false
    }
    
    private func saveHotkey(keyCode: UInt16, modifiers: UInt64, isModifier: Bool) {
        var display = ""
        
        let hasControl = (modifiers & CGEventFlags.maskControl.rawValue) != 0
        let hasOption = (modifiers & CGEventFlags.maskAlternate.rawValue) != 0
        let hasShift = (modifiers & CGEventFlags.maskShift.rawValue) != 0
        let hasCommand = (modifiers & CGEventFlags.maskCommand.rawValue) != 0
        
        var modsString = ""
        if hasControl { modsString += "⌃" }
        if hasOption { modsString += "⌥" }
        if hasShift { modsString += "⇧" }
        if hasCommand { modsString += "⌘" }

        // Mapping special keys and modifiers
        switch keyCode {
        case 63, 179: display = "Fn (Globe)"
        case 111: display = "F12"
        case 105: display = "F13"
        case 107: display = "F14"
        case 113: display = "F15"
        case 55, 54: display = "Command"
        case 56, 60: display = "Shift"
        case 58, 61: display = "Option"
        case 59, 62: display = "Control"
        case 49: display = "Space"
        case 36: display = "Return"
        case 53: display = "Escape"
        case 48: display = "Tab"
        case 51: display = "Delete"
        case 123: display = "Left Arrow"
        case 124: display = "Right Arrow"
        case 125: display = "Down Arrow"
        case 126: display = "Up Arrow"
        default: 
            // Optional: convert standard letters
            if let scalar = UnicodeScalar(keyCode), (65...90).contains(keyCode) || (97...122).contains(keyCode) {
                display = String(Character(scalar)).uppercased()
            } else {
                display = isModifier ? "Modifier (\(keyCode))" : "Key (\(keyCode))"
            }
        }
        
        if !isModifier && !modsString.isEmpty {
            display = modsString + display
        }

        let newHotkey = CustomHotkey(keyCode: CGKeyCode(keyCode), modifierFlags: modifiers, displayName: display)
        if let data = try? JSONEncoder().encode(newHotkey) {
            self.customHotkeyString = data.base64EncodedString()
        }

        stopRecording()
    }
}
