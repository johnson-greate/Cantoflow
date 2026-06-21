import SwiftUI

/// Left-hand queue of files in the batch.
struct TranscriptionQueueView: View {
    @ObservedObject var store: FileTranscriptionStore
    @Binding var selectedID: UUID?

    var body: some View {
        List(selection: $selectedID) {
            ForEach(store.items) { item in
                row(item)
                    .tag(item.id)
                    .contextMenu { contextMenu(item) }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if store.items.isEmpty {
                Text("尚未加入檔案")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
    }

    private func row(_ item: FileTranscriptionItem) -> some View {
        HStack(spacing: 8) {
            statusDot(item.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.status.displayText + (item.truncated && item.status.hasTranscript ? " · 內容可能不完整" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(Self.durationLabel(item.durationSeconds))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func contextMenu(_ item: FileTranscriptionItem) -> some View {
        if case .failed = item.status {
            Button("重試") { store.retry(item.id) }
        }
        if case .cancelled = item.status {
            Button("重試") { store.retry(item.id) }
        }
        Button("從佇列移除") { store.removeItem(item.id) }
            .disabled(isProcessing(item.status))
    }

    private func isProcessing(_ status: FileTranscriptionStatus) -> Bool {
        switch status {
        case .validating, .preparing, .transcribing, .generatingNotes: return true
        default: return false
        }
    }

    @ViewBuilder
    private func statusDot(_ status: FileTranscriptionStatus) -> some View {
        let color: Color = {
            switch status {
            case .complete, .transcriptReady: return .green
            case .completedWithWarning: return .yellow
            case .failed: return .red
            case .cancelled: return .gray
            case .transcribing, .preparing, .generatingNotes, .validating: return .accentColor
            case .queued: return .secondary
            }
        }()
        Circle().fill(color).frame(width: 8, height: 8)
    }

    static func durationLabel(_ seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
