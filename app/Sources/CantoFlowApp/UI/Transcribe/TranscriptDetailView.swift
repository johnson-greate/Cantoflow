import AppKit
import SwiftUI

/// Right-hand detail: the read-only transcript for the selected item, with
/// Copy and Export TXT. (Meeting-notes generation is added in Phase 5.)
struct TranscriptDetailView: View {
    let item: FileTranscriptionItem?
    @State private var transcript: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let item, item.status.hasTranscript {
                toolbar(item)
                Divider()
                ScrollView {
                    Text(transcript.isEmpty ? "（讀取逐字稿…）" : transcript)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            } else {
                Spacer()
                Text(placeholder(item))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .onChange(of: item?.transcriptURL) { _ in loadTranscript() }
        .onAppear { loadTranscript() }
    }

    private func placeholder(_ item: FileTranscriptionItem?) -> String {
        guard let item else { return "選擇左側檔案查看逐字稿" }
        if case .failed(let reason) = item.status { return reason }
        return "逐字稿尚未完成"
    }

    private func toolbar(_ item: FileTranscriptionItem) -> some View {
        HStack {
            Text(item.displayName).font(.headline).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(transcript, forType: .string)
            } label: { Label("複製", systemImage: "doc.on.doc") }
                .disabled(transcript.isEmpty)
            Button { exportTxt(item) } label: { Label("匯出 TXT", systemImage: "square.and.arrow.up") }
                .disabled(transcript.isEmpty)
        }
        .padding(12)
    }

    private func loadTranscript() {
        guard let url = item?.transcriptURL else { transcript = ""; return }
        transcript = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func exportTxt(_ item: FileTranscriptionItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = TranscriptionWorkspace.transcriptBasename(forSource: item.sourceURL) + ".txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? transcript.write(to: dest, atomically: true, encoding: .utf8)
    }
}
