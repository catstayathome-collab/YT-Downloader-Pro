import Foundation

@MainActor
final class DownloadStore: ObservableObject {
    @Published private(set) var jobs: [DownloadJob] = []
    @Published var toolchainMessage = "Checking helpers..."
    @Published var isQueueRunning = false
    @Published private(set) var defaultOptions = DownloadOptions()

    private let runner = DownloadRunner()
    private let saveURL: URL
    private let settingsURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("YT Downloader Pro", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        saveURL = support.appendingPathComponent("downloads.json")
        settingsURL = support.appendingPathComponent("settings.json")
        loadSettings()
        load()
        validateToolchain()
    }

    func firstURL(in text: String) -> String? {
        text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    func analyzeFirstURL(in text: String, options: DownloadOptions) async throws -> VideoAnalysis {
        guard let url = firstURL(in: text) else {
            throw MetadataProbeError.processFailed("Please enter a YouTube URL.")
        }
        let toolchain = try Toolchain.resolve()
        return try await Task.detached {
            try MetadataProbe.analyze(url: url, options: options, toolchain: toolchain)
        }.value
    }

    func add(urls text: String, options: DownloadOptions) {
        let newJobs = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { DownloadJob(url: $0, title: $0, options: options) }

        jobs.append(contentsOf: newJobs)
        save()
    }

    func addAndStart(urls text: String, options: DownloadOptions) {
        add(urls: text, options: options)
        startQueue()
    }

    func remember(options: DownloadOptions) {
        defaultOptions = options
        saveSettings()
    }

    func startQueue() {
        isQueueRunning = true
        startNextQueuedJob()
    }

    func stopQueue() {
        isQueueRunning = false
    }

    func start(_ job: DownloadJob) {
        runner.start(job: job) { [weak self] updated in
            self?.replace(updated)
        }
    }

    func pause(_ job: DownloadJob) {
        isQueueRunning = false
        runner.pause(job.id) { status in
            setStatus(status, for: job.id)
        }
    }

    func cancel(_ job: DownloadJob) {
        runner.cancel(job.id) { status in
            setStatus(status, for: job.id)
        }
    }

    func retry(_ job: DownloadJob) {
        var retryJob = job
        retryJob.status = .queued
        retryJob.progress = 0
        retryJob.error = nil
        replace(retryJob)
        start(retryJob)
    }

    func removeCompleted() {
        jobs.removeAll { $0.status == .completed || $0.status == .cancelled }
        save()
    }

    func remove(_ job: DownloadJob) {
        jobs.removeAll { $0.id == job.id }
        save()
    }

    private func replace(_ updated: DownloadJob) {
        guard let index = jobs.firstIndex(where: { $0.id == updated.id }) else { return }
        jobs[index] = updated
        save()
        if isQueueRunning && [.completed, .failed, .cancelled].contains(updated.status) {
            startNextQueuedJob()
        }
    }

    private func setStatus(_ status: DownloadStatus, for id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].status = status
        jobs[index].updatedAt = Date()
        save()
    }

    private func startNextQueuedJob() {
        guard !jobs.contains(where: { $0.status == .downloading || $0.status == .merging || $0.status == .analyzing }) else {
            return
        }

        guard let next = jobs.first(where: { $0.status == .queued }) else {
            isQueueRunning = false
            return
        }

        start(next)
    }

    private func load() {
        guard let data = try? Data(contentsOf: saveURL) else { return }
        jobs = (try? JSONDecoder().decode([DownloadJob].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: saveURL, options: .atomic)
    }

    private func loadSettings() {
        guard let data = try? Data(contentsOf: settingsURL) else { return }
        if let options = try? JSONDecoder().decode(DownloadOptions.self, from: data) {
            defaultOptions = options
            return
        }

        if
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let downloadPath = object["download_path"] as? String,
            FileManager.default.fileExists(atPath: downloadPath)
        {
            defaultOptions.outputDirectory = downloadPath
        }
    }

    private func saveSettings() {
        guard let data = try? JSONEncoder().encode(defaultOptions) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }

    private func validateToolchain() {
        Task {
            do {
                try Toolchain.validate()
                toolchainMessage = "Helpers ready"
            } catch {
                toolchainMessage = error.localizedDescription
            }
        }
    }
}
