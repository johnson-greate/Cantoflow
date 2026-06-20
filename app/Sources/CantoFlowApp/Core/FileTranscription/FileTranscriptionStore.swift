import AppKit
import Foundation

/// Drives the whole file-transcription batch and owns the observable state for
/// the Transcribe window. @MainActor — all published mutation on the main thread;
/// audio conversion and the worker process run off-main.
@MainActor
final class FileTranscriptionStore: ObservableObject {
    @Published private(set) var items: [FileTranscriptionItem] = []
    @Published private(set) var overallProgress: Double = 0
    @Published private(set) var isBatchActive = false
    @Published var statusMessage: String = ""

    private let config: AppConfig
    private let workspace = TranscriptionWorkspace()
    private let paths = ASRRuntimePaths()
    private let audioPrep = AudioPreparationService()

    private var runner: FileTranscriptionRunner?
    private var currentBatchID: UUID?
    private var activityToken: NSObjectProtocol?

    // Progress bookkeeping for the ASR stage.
    private var asrTotalDuration: Double = 0
    private var asrCompletedDuration: Double = 0
    private var currentItemDuration: Double = 0

    init(config: AppConfig) {
        self.config = config
        workspace.purgeStaleTemp()
    }

    // MARK: - Derived

    var hasQueuedWork: Bool {
        items.contains { $0.status == .queued }
    }

    var canStart: Bool {
        !isBatchActive && hasQueuedWork && !ASRWorkCoordinator.shared.isPushToTalkActive
    }

    var qwenReady: Bool {
        paths.readiness(for: .qwen3ASR, config: config).ready
    }

    private func isProcessing(_ status: FileTranscriptionStatus) -> Bool {
        switch status {
        case .validating, .preparing, .transcribing, .generatingNotes: return true
        default: return false
        }
    }

    // MARK: - Intake (FR-001..006)

    func addFiles(_ urls: [URL]) {
        var seen = Set(items.map { $0.sourceURL.standardizedFileURL })
        for url in urls {
            guard items.count < TranscribeLimits.maxFilesPerBatch else {
                statusMessage = "最多一次過 \(TranscribeLimits.maxFilesPerBatch) 個檔案"
                break
            }
            do {
                let probe = try FileProbe.probe(url)
                if let rejection = FileIntakeValidator.rejection(
                    ext: url.pathExtension,
                    isRegularFile: probe.isRegularFile,
                    sizeBytes: probe.sizeBytes,
                    durationSeconds: probe.durationSeconds,
                    url: url,
                    alreadyQueued: seen
                ) {
                    if rejection != .duplicate {
                        statusMessage = "\(url.lastPathComponent)：\(rejection.message)"
                    }
                    continue
                }
                items.append(FileTranscriptionItem(
                    sourceURL: url, fileSizeBytes: probe.sizeBytes,
                    durationSeconds: probe.durationSeconds, createdAt: Date()
                ))
                seen.insert(url.standardizedFileURL)
            } catch {
                statusMessage = "\(url.lastPathComponent)：無法讀取音頻，檔案可能受保護或已損壞"
            }
        }
    }

    func removeItem(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        guard !isProcessing(items[idx].status) else { return }
        items.remove(at: idx)
    }

    func clearCompleted() {
        guard !isBatchActive else { return }
        items.removeAll {
            if case .complete = $0.status { return true }
            if case .completedWithWarning = $0.status { return true }
            return false
        }
    }

    func retry(_ id: UUID) {
        guard !isBatchActive, let idx = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[idx].status {
        case .failed, .cancelled:
            items[idx].status = .queued
        default:
            break
        }
    }

    // MARK: - Batch lifecycle

    func startBatch() {
        guard canStart else { return }
        guard qwenReady else {
            statusMessage = "尚未安裝 Qwen3-ASR，請到 設定 → Models 安裝"
            return
        }
        let batchID = UUID()
        guard ASRWorkCoordinator.shared.tryAcquire(.fileBatch(batchID)) else {
            statusMessage = "錄音進行中，請先完成或停止 push-to-talk"
            return
        }

        currentBatchID = batchID
        isBatchActive = true
        statusMessage = ""
        overallProgress = 0
        asrCompletedDuration = 0
        currentItemDuration = 0
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "CantoFlow file transcription"
        )

        let queuedIDs = items.filter { $0.status == .queued }.map(\.id)
        let runner = FileTranscriptionRunner()
        self.runner = runner

        Task { [weak self] in
            await self?.runBatch(batchID: batchID, queuedIDs: queuedIDs, runner: runner)
        }
    }

    func stop() {
        runner?.cancel()
    }

    private func finishBatch(_ batchID: UUID) {
        ASRWorkCoordinator.shared.release(.fileBatch(batchID))
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
        // Purge temp WAVs for this batch.
        for id in items.map(\.id) {
            workspace.removeTempWAV(batchID: batchID, fileID: id)
        }
        runner = nil
        currentBatchID = nil
        isBatchActive = false
    }

    private func setStatus(_ id: UUID, _ status: FileTranscriptionStatus) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].status = status
    }

    private func runBatch(batchID: UUID, queuedIDs: [UUID], runner: FileTranscriptionRunner) async {
        do {
            try workspace.prepareBatchDirectories(batchID)
        } catch {
            for id in queuedIDs { setStatus(id, .failed("無法建立工作目錄")) }
            finishBatch(batchID)
            return
        }

        // Stage 1: convert each input to canonical WAV (sequential, off-main).
        struct Prepared { let id: UUID; let wav: URL; let outputTxt: URL; let duration: Double }
        var prepared: [Prepared] = []
        for id in queuedIDs {
            guard let item = items.first(where: { $0.id == id }) else { continue }
            setStatus(id, .preparing(progress: 0))
            let wav = workspace.tempWAVURL(batchID: batchID, fileID: id)
            let source = item.sourceURL
            do {
                try await Task.detached(priority: .userInitiated) { [audioPrep] in
                    try audioPrep.prepare(source, to: wav) { progress in
                        Task { @MainActor in self.setStatus(id, .preparing(progress: progress)) }
                    }
                }.value
                let base = TranscriptionWorkspace.transcriptBasename(forSource: source)
                let outputTxt = workspace.transcriptsDirectory(batchID)
                    .appendingPathComponent("\(base).txt")
                prepared.append(Prepared(id: id, wav: wav, outputTxt: outputTxt, duration: item.durationSeconds))
            } catch is CancellationError {
                setStatus(id, .cancelled)
            } catch {
                setStatus(id, .failed((error as? LocalizedError)?.errorDescription ?? "音訊準備失敗"))
            }
        }

        guard !prepared.isEmpty else {
            finishBatch(batchID)
            return
        }

        // Stage 2: write manifest and run the worker once over all prepared files.
        asrTotalDuration = prepared.reduce(0) { $0 + $1.duration }
        asrCompletedDuration = 0

        let context = config.useVocabulary ? VocabularyStore.shared.generateWhisperPrompt(maxLength: 500) : ""
        let manifest: [String: Any] = [
            "version": 1,
            "context": context,
            "files": prepared.map { ["id": $0.id.uuidString, "input_wav": $0.wav.path, "output_txt": $0.outputTxt.path] }
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [])
            try data.write(to: workspace.manifestURL(batchID), options: .atomic)
        } catch {
            for p in prepared { setStatus(p.id, .failed("無法寫入工作清單")) }
            finishBatch(batchID)
            return
        }

        let outputByID = Dictionary(uniqueKeysWithValues: prepared.map { ($0.id.uuidString, $0.outputTxt) })
        let durationByID = Dictionary(uniqueKeysWithValues: prepared.map { ($0.id.uuidString, $0.duration) })

        let runConfig = FileTranscriptionRunner.Config(
            pythonURL: paths.python,
            workerScriptURL: config.fileTranscriptionWorker,
            manifestURL: workspace.manifestURL(batchID),
            modelDirURL: paths.qwenModelDirectory,
            outputDirURL: workspace.transcriptsDirectory(batchID),
            traditional: true
        )

        do {
            _ = try await runner.run(runConfig) { event in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.handle(event: event, outputByID: outputByID, durationByID: durationByID)
                    }
                }
            }
        } catch {
            statusMessage = (error as? LocalizedError)?.errorDescription ?? "轉錄引擎錯誤"
        }

        // Any file left mid-flight (worker terminated by cancel) → cancelled.
        for p in prepared {
            if let item = items.first(where: { $0.id == p.id }), isProcessing(item.status) {
                setStatus(p.id, .cancelled)
            }
        }
        finishBatch(batchID)
    }

    private func handle(event: WorkerEvent, outputByID: [String: URL], durationByID: [String: Double]) {
        switch event {
        case .workerReady:
            break
        case .fileStarted(let fileID, _, _):
            currentItemDuration = durationByID[fileID] ?? 0
            if let id = UUID(uuidString: fileID) {
                setStatus(id, .transcribing(progress: 0, chunk: 0, totalChunks: 0))
            }
        case .asrProgress(let fileID, let progress, let chunk, let total, _, _):
            if let id = UUID(uuidString: fileID) {
                setStatus(id, .transcribing(progress: progress, chunk: chunk, totalChunks: total))
            }
            recomputeOverall(currentProgress: progress)
        case .fileCompleted(let fileID, _, _, let language, let truncated, _):
            if let id = UUID(uuidString: fileID), let idx = items.firstIndex(where: { $0.id == id }) {
                items[idx].transcriptURL = outputByID[fileID]
                items[idx].language = language
                items[idx].status = truncated
                    ? .completedWithWarning("部分內容可能不完整")
                    : .transcriptReady
            }
            asrCompletedDuration += durationByID[fileID] ?? 0
            currentItemDuration = 0
            recomputeOverall(currentProgress: 0)
        case .fileFailed(let fileID, _, let message):
            if let id = UUID(uuidString: fileID) {
                setStatus(id, .failed(message.isEmpty ? "轉錄失敗" : message))
            }
            asrCompletedDuration += durationByID[fileID] ?? 0
            currentItemDuration = 0
            recomputeOverall(currentProgress: 0)
        case .batchCompleted:
            overallProgress = 1
        }
    }

    private func recomputeOverall(currentProgress: Double) {
        overallProgress = BatchProgress.overall(
            completedDurations: [asrCompletedDuration],
            currentDuration: currentItemDuration,
            currentProgress: currentProgress,
            totalDuration: asrTotalDuration
        )
    }
}
