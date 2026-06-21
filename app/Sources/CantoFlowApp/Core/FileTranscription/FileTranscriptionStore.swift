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
    private lazy var notesGenerator = MeetingNotesGenerator(client: LLMCompletionClient(config: config))

    private var runner: FileTranscriptionRunner?
    private var batchTask: Task<Void, Never>?
    private var cancelBox = CancelBox()
    private var currentBatchID: UUID?
    private var activityToken: NSObjectProtocol?

    /// Thread-safe cancel flag readable from the off-main audio-prep task.
    private final class CancelBox: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func cancel() { lock.lock(); flag = true; lock.unlock() }
    }

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

    // MARK: - Meeting notes (FR-060..069)

    var notesAvailable: Bool { notesGenerator.isAvailable() }
    var notesProvider: AppConfig.PolishProvider { notesGenerator.resolvedProvider() }

    func generateNotes(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[idx]
        guard item.status.hasTranscript, let transcriptURL = item.transcriptURL,
              let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8),
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "未辨識到語音內容，無法生成會議記錄"
            return
        }

        let previousStatus = item.status   // restored on failure (keeps old notes)
        let source = item.sourceURL
        let recordingDate = (try? source.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        items[idx].status = .generatingNotes
        statusMessage = ""

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.notesGenerator.generate(
                    transcript: transcript, filename: source.lastPathComponent, recordingDate: recordingDate
                )
                // Atomic replace of the internal notes file (FR-069).
                let notesDir = transcriptURL.deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("notes", isDirectory: true)
                try? FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
                // Fresh filename each generation so the detail view (keyed on the
                // notes URL) reliably reloads after a regenerate; the previous
                // notes file is only abandoned once the new one is written.
                let notesURL = notesDir.appendingPathComponent(
                    "\(TranscriptionWorkspace.notesBasename(forSource: source))-\(UUID().uuidString.prefix(8)).md"
                )
                try self.workspace.atomicWrite(result.markdown, to: notesURL)

                guard let i = self.items.firstIndex(where: { $0.id == id }) else { return }
                let oldNotesURL = self.items[i].meetingNotesURL
                self.items[i].meetingNotesURL = notesURL
                self.items[i].status = .complete
                if result.formatWarning {
                    self.statusMessage = "會議記錄已生成，但格式可能不完整"
                }
                // Remove the superseded notes file after the swap.
                if let oldNotesURL, oldNotesURL != notesURL { try? FileManager.default.removeItem(at: oldNotesURL) }
            } catch {
                // Keep any previous notes; just restore status + surface error.
                guard let i = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.items[i].status = previousStatus
                self.statusMessage = (error as? LocalizedError)?.errorDescription ?? "生成會議記錄失敗"
            }
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
        cancelBox = CancelBox()
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

        batchTask = Task { [weak self] in
            await self?.runBatch(batchID: batchID, queuedIDs: queuedIDs, runner: runner)
        }
    }

    func stop() {
        guard isBatchActive else { return }
        cancelBox.cancel()          // halts the audio-preparation stage (off-main)
        runner?.cancel()            // terminates the worker if it has started
        batchTask?.cancel()
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
        batchTask = nil
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

        // Disk preflight (FR-015): canonical-WAV temp space estimate + headroom.
        let estimatedTemp = queuedIDs
            .compactMap { id in items.first { $0.id == id }?.durationSeconds }
            .reduce(Int64(0)) { $0 + TranscribeLimits.estimatedTempBytes(forAudioSeconds: $1) }
        if let available = try? workspace.transcriptsDirectory(batchID)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage,
           available < estimatedTemp {
            let need = ByteCountFormatter.string(fromByteCount: estimatedTemp, countStyle: .file)
            for id in queuedIDs { setStatus(id, .failed("沒有足夠空間準備音頻（約需 \(need)）")) }
            finishBatch(batchID)
            return
        }

        let cancelBox = self.cancelBox

        // Stage 1: convert each input to canonical WAV (sequential, off-main).
        struct Prepared { let id: UUID; let wav: URL; let outputTxt: URL; let duration: Double }
        var prepared: [Prepared] = []
        for id in queuedIDs {
            if cancelBox.isCancelled { setStatus(id, .cancelled); continue }
            guard let item = items.first(where: { $0.id == id }) else { continue }
            setStatus(id, .preparing(progress: 0))
            let wav = workspace.tempWAVURL(batchID: batchID, fileID: id)
            let source = item.sourceURL
            do {
                try await Task.detached(priority: .userInitiated) { [audioPrep, cancelBox] in
                    try audioPrep.prepare(source, to: wav, isCancelled: { cancelBox.isCancelled }) { progress in
                        Task { @MainActor in self.setStatus(id, .preparing(progress: progress)) }
                    }
                }.value
                // Per-item id suffix so two same-named sources from different
                // folders don't share (and overwrite) one transcript file.
                let base = TranscriptionWorkspace.transcriptBasename(forSource: source)
                let outputTxt = workspace.transcriptsDirectory(batchID)
                    .appendingPathComponent("\(base)-\(id.uuidString.prefix(8)).txt")
                prepared.append(Prepared(id: id, wav: wav, outputTxt: outputTxt, duration: item.durationSeconds))
            } catch {
                if cancelBox.isCancelled {
                    setStatus(id, .cancelled)
                } else {
                    setStatus(id, .failed((error as? LocalizedError)?.errorDescription ?? "音訊準備失敗"))
                }
            }
        }

        // Stop here if the user cancelled during preparation, or nothing converted.
        guard !prepared.isEmpty, !cancelBox.isCancelled else {
            if cancelBox.isCancelled {
                for p in prepared where isProcessing(items.first(where: { $0.id == p.id })?.status ?? .cancelled) {
                    setStatus(p.id, .cancelled)
                }
            }
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
            traditional: true,
            environment: paths.offlineModelEnvironment
        )

        var exitCode: Int32 = 0
        var launchFailed = false
        do {
            exitCode = try await runner.run(runConfig) { event in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.handle(event: event, outputByID: outputByID, durationByID: durationByID)
                    }
                }
            }
        } catch {
            launchFailed = true
            statusMessage = (error as? LocalizedError)?.errorDescription ?? "轉錄引擎錯誤"
        }

        // Resolve any file still mid-flight. A non-zero exit / launch failure that
        // is NOT a user cancel means the worker crashed → mark those files failed
        // (not cancelled), and log the stderr diagnostics (never the transcript).
        let workerFailed = launchFailed || exitCode != 0
        if workerFailed && !cancelBox.isCancelled {
            print("[Transcribe] worker exit=\(exitCode) diagnostics: \(runner.diagnostics.suffix(2000))")
        }
        for p in prepared {
            guard let item = items.first(where: { $0.id == p.id }), isProcessing(item.status) else { continue }
            if cancelBox.isCancelled {
                setStatus(p.id, .cancelled)
            } else if workerFailed {
                setStatus(p.id, .failed("轉錄引擎異常結束"))
            } else {
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
                items[idx].truncated = truncated   // tracked separately from notes warnings
                items[idx].status = .transcriptReady
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
