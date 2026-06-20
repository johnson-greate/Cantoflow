import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TranscribeView: View {
    @ObservedObject var store: FileTranscriptionStore
    @State private var selectedID: UUID?

    private var selectedItem: FileTranscriptionItem? {
        store.items.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                TranscriptionQueueView(store: store, selectedID: $selectedID)
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 380)
                TranscriptDetailView(item: selectedItem)
                    .frame(minWidth: 380, maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 520)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
            return true
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("檔案轉錄").font(.title3.weight(.semibold))
            Spacer()
            Button { addFiles() } label: { Label("加入檔案", systemImage: "plus") }
                .disabled(store.isBatchActive)
            if store.isBatchActive {
                Button(role: .destructive) { store.stop() } label: { Label("停止", systemImage: "stop.fill") }
            } else {
                Button { store.startBatch() } label: { Label("開始轉錄", systemImage: "play.fill") }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!store.canStart)
            }
        }
        .padding(12)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if store.isBatchActive {
                ProgressView(value: store.overallProgress)
                    .frame(maxWidth: 240)
                Text("\(Int(store.overallProgress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(store.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if !store.isBatchActive && store.items.contains(where: { isCompleted($0.status) }) {
                Button("清除已完成") { store.clearCompleted() }
            }
        }
        .padding(12)
    }

    private func isCompleted(_ status: FileTranscriptionStatus) -> Bool {
        if case .complete = status { return true }
        if case .completedWithWarning = status { return true }
        return false
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.wav, .mp3, .mpeg4Audio]
        guard panel.runModal() == .OK else { return }
        store.addFiles(panel.urls)
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { store.addFiles(urls) }
    }
}
