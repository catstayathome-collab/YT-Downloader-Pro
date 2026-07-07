import Foundation

@MainActor
final class DownloadStore: ObservableObject {
    @Published private(set) var jobs: [DownloadJob] = []
    @Published var toolchainMessage = "Checking helpers..."

    private let runner = DownloadRunner()
    private let saveURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("YT Downloader Pro", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        saveURL = support.appendingPathComponent("downloads.json")
        load()
        validateToolchain()
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

    func start(_ job: DownloadJob) {
        runner.start(job: job) { [weak self] updated in
            self?.replace(updated)
        }
    }

    func pause(_ job: DownloadJob) {
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

    private func replace(_ updated: DownloadJob) {
        guard let index = jobs.firstIndex(where: { $0.id == updated.id }) else { return }
        jobs[index] = updated
        save()
    }

    private func setStatus(_ status: DownloadStatus, for id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].status = status
        jobs[index].updatedAt = Date()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: saveURL) else { return }
        jobs = (try? JSONDecoder().decode([DownloadJob].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: saveURL, options: .atomic)
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
