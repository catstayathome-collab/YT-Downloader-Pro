import CryptoKit
import Foundation

/// Private, same-volume staging. Public media is never used as a conversion scratch file.
struct MP4Workspace: Sendable {
    let directory: URL
    let jobID: UUID
    var source: URL { directory.appendingPathComponent("source.mp4") }
    var candidate: URL { directory.appendingPathComponent("converted.mp4") }
    var template: String { directory.appendingPathComponent("source.%(ext)s").path }
    private var owner: URL { directory.appendingPathComponent("owner") }
    private var receipt: URL { directory.appendingPathComponent("verified-source.json") }

    init(directory parent: URL, jobID: UUID) throws {
        self.jobID = jobID
        directory = parent.appendingPathComponent(".ytdp-\(jobID.uuidString)", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try Data(jobID.uuidString.utf8).write(to: owner, options: .withoutOverwriting)
        }
        try checkOwnership()
    }

    func checkOwnership() throws {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let ownerValues = try owner.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              ownerValues.isRegularFile == true, ownerValues.isSymbolicLink != true,
              try Data(contentsOf: owner) == Data(jobID.uuidString.utf8) else {
            throw MP4OutputPlanningError.outputValidationFailed
        }
    }

    func requireMedia(_ url: URL) throws {
        try checkOwnership()
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard url.standardizedFileURL.deletingLastPathComponent() == directory.standardizedFileURL,
              values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else {
            throw MP4OutputPlanningError.outputValidationFailed
        }
    }

    private struct Receipt: Codable { let request: String; let content: String }

    func prepareRequest(for job: DownloadJob) throws {
        try checkOwnership()
        let manifest = directory.appendingPathComponent("request")
        let digest = try requestDigest(job)
        if (try? String(contentsOf: manifest, encoding: .utf8)) == digest { return }
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for url in contents where url.lastPathComponent.hasPrefix("source.") || url == candidate || url == receipt {
            try FileManager.default.removeItem(at: url)
        }
        try Data(digest.utf8).write(to: manifest, options: .atomic)
    }

    private func requestDigest(_ job: DownloadJob) throws -> String {
        var options = job.options
        // Client fallback does not change the requested media selection.
        options.clientStrategy = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(options)
        data.append(Data(job.sourceURL.utf8))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func sourceDigest() throws -> String {
        try Task.checkCancellation()
        try requireMedia(source)
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        try Task.checkCancellation()
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func retainVerifiedSource(for job: DownloadJob) throws {
        let data = try JSONEncoder().encode(Receipt(request: requestDigest(job), content: sourceDigest()))
        try Task.checkCancellation()
        try data.write(to: receipt, options: .atomic)
    }

    // Cleanup only decides whether to retain a potential source. Reuse always hashes
    // and probes it again; cleanup must not block cancellation by reading a large file.
    func hasReceipt(for job: DownloadJob) -> Bool {
        guard let data = try? Data(contentsOf: receipt), let saved = try? JSONDecoder().decode(Receipt.self, from: data) else { return false }
        return saved.request == (try? requestDigest(job))
    }

    func hasVerifiedSource(for job: DownloadJob) -> Bool {
        guard (try? checkOwnership()) != nil,
              let data = try? Data(contentsOf: receipt), let saved = try? JSONDecoder().decode(Receipt.self, from: data),
              saved.request == (try? requestDigest(job)), saved.content == (try? sourceDigest()) else { return false }
        return true
    }

    func discardCandidate() throws {
        try checkOwnership()
        if FileManager.default.fileExists(atPath: candidate.path) { try FileManager.default.removeItem(at: candidate) }
    }

    func isPublished(to destination: URL) -> Bool { sameFile(candidate, destination) }

    // Hard links provide atomic no-replace publication on the destination volume. Publish
    // the main file last; roll back only links made by this call if any sidecar conflicts.
    func publish(to destination: URL) throws {
        try requireMedia(candidate)
        guard destination.deletingLastPathComponent().standardizedFileURL == directory.deletingLastPathComponent().standardizedFileURL else {
            throw MP4OutputPlanningError.outputValidationFailed
        }
        let sidecars = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("source.") && $0.pathExtension == "srt" }
        let pairs = sidecars.map { file in
            (file, destination.deletingPathExtension().appendingPathExtension(String(file.lastPathComponent.dropFirst("source.".count))))
        } + [(candidate, destination)]
        var created: [(URL, URL)] = []
        do {
            for (source, target) in pairs {
                try requireMedia(source)
                if sameFile(source, target) { continue } // Restart after a publication-time crash.
                try FileManager.default.linkItem(at: source, to: target)
                created.append((source, target))
            }
        } catch {
            for (source, target) in created.reversed() where sameFile(source, target) {
                try? FileManager.default.removeItem(at: target)
            }
            throw error
        }
    }

    private func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        guard (try? rhs.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
              let a = try? FileManager.default.attributesOfItem(atPath: lhs.path),
              let b = try? FileManager.default.attributesOfItem(atPath: rhs.path) else { return false }
        return a[.systemNumber] as? NSNumber == b[.systemNumber] as? NSNumber &&
            a[.systemFileNumber] as? NSNumber == b[.systemFileNumber] as? NSNumber
    }

    func remove() throws {
        try checkOwnership()
        try FileManager.default.removeItem(at: directory)
    }
}
