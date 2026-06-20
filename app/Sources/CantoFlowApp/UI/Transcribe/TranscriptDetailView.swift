import AppKit
import SwiftUI

/// Right-hand detail: transcript + meeting-notes tabs for the selected item.
struct TranscriptDetailView: View {
    @ObservedObject var store: FileTranscriptionStore
    let item: FileTranscriptionItem?

    private enum Tab { case transcript, notes }
    @State private var tab: Tab = .transcript
    @State private var transcript = ""
    @State private var notes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let item, item.status.hasTranscript {
                Picker("", selection: $tab) {
                    Text("逐字稿").tag(Tab.transcript)
                    Text("會議記錄").tag(Tab.notes)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(12)
                Divider()
                if tab == .transcript {
                    transcriptPane(item)
                } else {
                    notesPane(item)
                }
            } else {
                Spacer()
                Text(placeholder(item)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .onChange(of: item?.transcriptURL) { _ in loadTranscript() }
        .onChange(of: item?.meetingNotesURL) { _ in loadNotes() }
        .onChange(of: item?.id) { _ in tab = .transcript; loadTranscript(); loadNotes() }
        .onAppear { loadTranscript(); loadNotes() }
    }

    private func placeholder(_ item: FileTranscriptionItem?) -> String {
        guard let item else { return "選擇左側檔案查看逐字稿" }
        if case .failed(let reason) = item.status { return reason }
        return "逐字稿尚未完成"
    }

    // MARK: - Transcript

    private func transcriptPane(_ item: FileTranscriptionItem) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(item.displayName).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { copy(transcript) } label: { Label("複製", systemImage: "doc.on.doc") }
                    .disabled(transcript.isEmpty)
                Button { export(transcript, base: TranscriptionWorkspace.transcriptBasename(forSource: item.sourceURL), ext: "txt") }
                    label: { Label("匯出 TXT", systemImage: "square.and.arrow.up") }
                    .disabled(transcript.isEmpty)
            }
            .padding(12)
            ScrollView {
                Text(transcript.isEmpty ? "（讀取逐字稿…）" : transcript)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }

    // MARK: - Meeting notes

    @ViewBuilder
    private func notesPane(_ item: FileTranscriptionItem) -> some View {
        if case .generatingNotes = item.status {
            VStack(spacing: 10) {
                Spacer()
                ProgressView()
                Text("正在生成會議記錄…").foregroundStyle(.secondary)
                Spacer()
            }.frame(maxWidth: .infinity)
        } else if !notes.isEmpty {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button { copy(notes) } label: { Label("複製", systemImage: "doc.on.doc") }
                    Button { export(notes, base: TranscriptionWorkspace.notesBasename(forSource: item.sourceURL), ext: "md") }
                        label: { Label("匯出 MD", systemImage: "square.and.arrow.up") }
                    Button { export(MeetingNotesFormatter.plainText(from: notes), base: TranscriptionWorkspace.notesBasename(forSource: item.sourceURL), ext: "txt") }
                        label: { Text("匯出 TXT") }
                    Button { generate(item) } label: { Label("重新生成", systemImage: "arrow.clockwise") }
                }
                .padding(12)
                ScrollView {
                    Text(notes).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
            }
        } else {
            VStack(spacing: 12) {
                Spacer()
                if store.notesAvailable {
                    Text("把整份逐字稿交給目前的 LLM，整理成會議記錄。").foregroundStyle(.secondary)
                    Button { generate(item) } label: { Label("生成會議記錄", systemImage: "sparkles") }
                        .controlSize(.large)
                } else {
                    Text("尚未設定文字整理模型").foregroundStyle(.secondary)
                    Button("前往設定") { SettingsWindowController.shared.show() }
                }
                Spacer()
            }.frame(maxWidth: .infinity)
        }
    }

    private func generate(_ item: FileTranscriptionItem) {
        let provider = store.notesProvider
        if LLMDisclosure.needsDisclosure(provider) {
            let alert = NSAlert()
            alert.messageText = "生成會議記錄"
            alert.informativeText = "音頻不會上傳；整份逐字稿會傳送至 \(providerName(provider)) 以生成會議記錄。"
            alert.addButton(withTitle: "同意並生成")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            LLMDisclosure.recordConsent(provider)
        }
        store.generateNotes(item.id)
    }

    private func providerName(_ provider: AppConfig.PolishProvider) -> String {
        switch provider {
        case .deepseek: return "DeepSeek"
        case .gemini: return "Google Gemini"
        case .qwen: return "Qwen / DashScope"
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .local: return "本機模型"
        case .auto, .none: return "目前的 LLM"
        }
    }

    // MARK: - IO helpers

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func export(_ text: String, base: String, ext: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(base).\(ext)"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? text.write(to: dest, atomically: true, encoding: .utf8)
    }

    private func loadTranscript() {
        guard let url = item?.transcriptURL else { transcript = ""; return }
        transcript = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func loadNotes() {
        guard let url = item?.meetingNotesURL else { notes = ""; return }
        notes = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
