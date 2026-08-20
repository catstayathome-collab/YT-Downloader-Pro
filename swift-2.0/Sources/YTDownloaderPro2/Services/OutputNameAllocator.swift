import Foundation

struct OutputReservation: Equatable, Sendable {
    let baseURL: URL
    let markerURL: URL
}

actor OutputNameAllocator {
    private static let fallbackBasename = "Untitled Download"
    private static let markerSuffix = ".ytdp-reservation"
    private static let maximumFilenameBytes = 255
    private static let alternateExtensions = [
        "mp4", "m4v", "mkv", "webm", "mov", "mp3", "m4a", "aac", "opus", "ogg", "flac", "wav"
    ]
    private static let unsafeFilenameCharacters = CharacterSet(charactersIn: "/:\\?*\"<>|")
    private static let reservedBasenames: Set<String> = [
        "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
        "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9"
    ]

    private var reservations: [UUID: OutputReservation] = [:]

    func reserve(
        title: String,
        extension fileExtension: String,
        directory: URL,
        jobID: UUID
    ) async throws -> OutputReservation {
        let destination = directory.standardizedFileURL.resolvingSymlinksInPath()
        try validateDestination(destination)

        if let reservation = reservations[jobID] {
            if markerBelongsToJob(at: reservation.markerURL, jobID: jobID) {
                return reservation
            }
            reservations.removeValue(forKey: jobID)
        }

        if let persisted = try persistedReservation(for: jobID, directory: destination) {
            reservations[jobID] = persisted
            return persisted
        }

        let basename = Self.sanitizedBasename(title)
        let normalizedExtension = Self.sanitizedExtension(fileExtension)
        var index = 0

        while true {
            let candidate = Self.candidateBasename(
                basename,
                suffix: index == 0 ? "" : " (\(index))",
                fileExtension: normalizedExtension
            )
            let reservation = OutputReservation(
                baseURL: destination.appendingPathComponent(candidate),
                markerURL: markerURL(for: candidate, directory: destination)
            )

            guard isAvailable(reservation, fileExtension: normalizedExtension) else {
                index += 1
                continue
            }

            do {
                try Data(jobID.uuidString.utf8).write(to: reservation.markerURL, options: .withoutOverwriting)
                reservations[jobID] = reservation
                return reservation
            } catch {
                if markerBelongsToJob(at: reservation.markerURL, jobID: jobID) {
                    reservations[jobID] = reservation
                    return reservation
                }
                if FileManager.default.fileExists(atPath: reservation.markerURL.path) {
                    index += 1
                    continue
                }
                throw filesystemFailure()
            }
        }
    }

    func release(jobID: UUID, removeMarker: Bool) async {
        guard let reservation = reservations.removeValue(forKey: jobID), removeMarker else {
            return
        }

        guard markerBelongsToJob(at: reservation.markerURL, jobID: jobID) else {
            return
        }

        try? FileManager.default.removeItem(at: reservation.markerURL)
    }

    private func validateDestination(_ directory: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isWritableFile(atPath: directory.path) else {
            throw destinationFailure()
        }
    }

    private func persistedReservation(for jobID: UUID, directory: URL) throws -> OutputReservation? {
        let markerURLs: [URL]
        do {
            markerURLs = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            )
        } catch {
            throw filesystemFailure()
        }

        for markerURL in markerURLs where markerURL.lastPathComponent.hasPrefix(".") && markerURL.lastPathComponent.hasSuffix(Self.markerSuffix) {
            guard markerBelongsToJob(at: markerURL, jobID: jobID) else {
                continue
            }
            let filename = markerURL.lastPathComponent
            let basename = String(filename.dropFirst().dropLast(Self.markerSuffix.count))
            guard !basename.isEmpty else {
                continue
            }
            return OutputReservation(
                baseURL: directory.appendingPathComponent(basename),
                markerURL: directory.appendingPathComponent(filename)
            )
        }
        return nil
    }

    private func isAvailable(_ reservation: OutputReservation, fileExtension: String) -> Bool {
        guard !reservations.values.contains(where: { $0.baseURL == reservation.baseURL }) else {
            return false
        }
        guard !FileManager.default.fileExists(atPath: reservation.markerURL.path) else {
            return false
        }
        return !collisionURLs(for: reservation.baseURL, fileExtension: fileExtension)
            .contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func collisionURLs(for baseURL: URL, fileExtension: String) -> [URL] {
        let extensions = Set(Self.alternateExtensions + [fileExtension])
        var urls = [
            baseURL.appendingPathExtension("part"),
            baseURL.appendingPathExtension("ytdl"),
            baseURL.appendingPathExtension("temp")
        ]

        for extensionName in extensions {
            let output = baseURL.appendingPathExtension(extensionName)
            urls.append(output)
            urls.append(output.appendingPathExtension("part"))
            urls.append(output.appendingPathExtension("ytdl"))
        }
        return urls
    }

    private func markerURL(for basename: String, directory: URL) -> URL {
        directory.appendingPathComponent(".\(basename)\(Self.markerSuffix)")
    }

    private func markerBelongsToJob(at markerURL: URL, jobID: UUID) -> Bool {
        guard let data = try? Data(contentsOf: markerURL),
              let value = String(data: data, encoding: .utf8),
              UUID(uuidString: value) == jobID else {
            return false
        }
        return true
    }

    private static func sanitizedBasename(_ title: String) -> String {
        let filtered = String(title.unicodeScalars.filter { !isUnsafeFilenameScalar($0) })
        let trimmed = filtered.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let rootName = trimmed.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? trimmed

        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !reservedBasenames.contains(rootName.lowercased()) else {
            return fallbackBasename
        }
        return trimmed
    }

    private static func sanitizedExtension(_ fileExtension: String) -> String {
        let withoutLeadingDots = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "." })
        let filtered = String(withoutLeadingDots.unicodeScalars.filter { !isUnsafeFilenameScalar($0) })
        return filtered.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    }

    private static func candidateBasename(_ basename: String, suffix: String, fileExtension: String) -> String {
        let extensionBytes = fileExtension.isEmpty ? 0 : fileExtension.lengthOfBytes(using: .utf8) + 1
        let markerOverhead = markerSuffix.lengthOfBytes(using: .utf8) + 1
        let maximumBaseBytes = max(1, min(maximumFilenameBytes - extensionBytes - suffix.lengthOfBytes(using: .utf8), maximumFilenameBytes - markerOverhead - suffix.lengthOfBytes(using: .utf8)))
        return truncated(basename, toUTF8ByteCount: maximumBaseBytes) + suffix
    }

    private static func truncated(_ value: String, toUTF8ByteCount maximum: Int) -> String {
        var result = ""
        for character in value {
            let next = String(character)
            guard result.lengthOfBytes(using: .utf8) + next.lengthOfBytes(using: .utf8) <= maximum else {
                break
            }
            result.append(character)
        }
        return result.isEmpty ? fallbackBasename : result
    }

    private static func isUnsafeFilenameScalar(_ scalar: UnicodeScalar) -> Bool {
        unsafeFilenameCharacters.contains(scalar) || scalar.value <= 0x1F || (0x7F...0x9F).contains(scalar.value)
    }

    private func destinationFailure() -> DownloadFailure {
        DownloadFailure(
            category: .unknown,
            technicalDetail: "The selected download folder is unavailable or not writable."
        )
    }

    private func filesystemFailure() -> DownloadFailure {
        DownloadFailure(
            category: .unknown,
            technicalDetail: "Unable to reserve a download filename in the selected folder."
        )
    }
}
