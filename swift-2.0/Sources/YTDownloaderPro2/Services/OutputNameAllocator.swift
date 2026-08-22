import Darwin
import Foundation

struct OutputReservation: Equatable, Sendable {
    let baseURL: URL
    let markerURL: URL
}

actor OutputNameAllocator {
    private static let fallbackBasename = "Untitled Download"
    private static let markerSuffix = ".ytdp-reservation"
    private static let lockSuffix = ".ytdp-reservation.lock"
    private static let maximumFilenameBytes = 255
    private static let maximumExtensionBytes = 64
    private static let unsafeFilenameCharacters = CharacterSet(charactersIn: "/:\\?*\"<>|")
    private static let reservedBasenames: Set<String> = [
        "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
        "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9"
    ]

    private var reservations: [UUID: OutputReservation] = [:]
    private let lockAcquiredHook: (@Sendable (URL) async -> Void)?

    init(lockAcquiredHook: (@Sendable (URL) async -> Void)? = nil) {
        self.lockAcquiredHook = lockAcquiredHook
    }

    func reserve(
        title: String,
        extension fileExtension: String,
        directory: URL,
        jobID: UUID
    ) async throws -> OutputReservation {
        let destination = directory.standardizedFileURL.resolvingSymlinksInPath()
        try validateDestination(destination)

        if let reservation = reservations[jobID] {
            if try await withCandidateLock(for: reservation, operation: {
                markerBelongsToJob(at: reservation.markerURL, jobID: jobID)
            }) {
                return reservation
            }
            reservations.removeValue(forKey: jobID)
        }

        if let persisted = try await persistedReservation(for: jobID, directory: destination) {
            reservations[jobID] = persisted
            return persisted
        }

        let basename = Self.sanitizedBasename(title)
        let normalizedExtension: String
        do {
            normalizedExtension = try Self.validatedExtension(fileExtension)
        } catch {
            throw invalidExtensionFailure()
        }
        var index = 0

        while true {
            guard let candidate = Self.candidateBasename(
                basename,
                suffix: index == 0 ? "" : " (\(index))",
                fileExtension: normalizedExtension
            ) else {
                throw filesystemFailure()
            }
            let reservation = OutputReservation(
                baseURL: destination.appendingPathComponent(candidate),
                markerURL: markerURL(for: candidate, directory: destination)
            )

            do {
                let claim = try await withCandidateLock(for: reservation, operation: {
                    guard try isAvailable(reservation) else {
                        return Claim.unavailable
                    }
                    do {
                        try Data(jobID.uuidString.utf8).write(to: reservation.markerURL, options: .withoutOverwriting)
                        return Claim.claimed
                    } catch {
                        return markerBelongsToJob(at: reservation.markerURL, jobID: jobID) ? .sameJob : .unavailable
                    }
                })

                switch claim {
                case .claimed, .sameJob:
                    reservations[jobID] = reservation
                    return reservation
                case .unavailable:
                    index += 1
                }
            } catch {
                throw filesystemFailure()
            }
        }
    }

    func release(jobID: UUID, removeMarker: Bool) async {
        guard let reservation = reservations.removeValue(forKey: jobID), removeMarker else {
            return
        }

        try? await withCandidateLock(for: reservation, operation: {
            guard markerBelongsToJob(at: reservation.markerURL, jobID: jobID) else {
                return
            }
            try? FileManager.default.removeItem(at: reservation.markerURL)
        })
    }

    func owns(_ reservation: OutputReservation, jobID: UUID) async -> Bool {
        do {
            return try await withCandidateLock(for: reservation, operation: {
                markerBelongsToJob(at: reservation.markerURL, jobID: jobID)
            })
        } catch {
            return false
        }
    }

    func removeOwnedArtifacts(_ urls: [URL], reservation: OutputReservation, jobID: UUID) async -> Bool {
        do {
            return try await withCandidateLock(for: reservation, operation: {
                guard markerBelongsToJob(at: reservation.markerURL, jobID: jobID) else {
                    return false
                }
                for url in urls {
                    try? FileManager.default.removeItem(at: url)
                }
                return true
            })
        } catch {
            return false
        }
    }

    private func validateDestination(_ directory: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isWritableFile(atPath: directory.path) else {
            throw destinationFailure()
        }
    }

    private func persistedReservation(for jobID: UUID, directory: URL) async throws -> OutputReservation? {
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
            let filename = markerURL.lastPathComponent
            let basename = String(filename.dropFirst().dropLast(Self.markerSuffix.count))
            guard !basename.isEmpty else {
                continue
            }
            let reservation = OutputReservation(
                baseURL: directory.appendingPathComponent(basename),
                markerURL: directory.appendingPathComponent(filename)
            )
            if try await withCandidateLock(for: reservation, operation: {
                markerBelongsToJob(at: reservation.markerURL, jobID: jobID)
            }) {
                return reservation
            }
        }
        return nil
    }

    private func isAvailable(_ reservation: OutputReservation) throws -> Bool {
        guard !reservations.values.contains(where: { $0.baseURL == reservation.baseURL }) else {
            return false
        }
        guard !FileManager.default.fileExists(atPath: reservation.markerURL.path) else {
            return false
        }
        let directoryContents: [URL]
        do {
            directoryContents = try FileManager.default.contentsOfDirectory(
                at: reservation.baseURL.deletingLastPathComponent(),
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            )
        } catch {
            throw filesystemFailure()
        }
        let basename = reservation.baseURL.lastPathComponent
        return !directoryContents.contains { url in
            let name = url.lastPathComponent
            return name == basename || name.hasPrefix("\(basename).")
        }
    }

    private func markerURL(for basename: String, directory: URL) -> URL {
        directory.appendingPathComponent(".\(basename)\(Self.markerSuffix)")
    }

    private func lockURL(for reservation: OutputReservation) -> URL {
        reservation.markerURL.appendingPathExtension("lock")
    }

    private func withCandidateLock<T>(
        for reservation: OutputReservation,
        operation: () throws -> T
    ) async throws -> T {
        let lockURL = lockURL(for: reservation)
        let descriptor = lockURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw filesystemFailure()
        }
        defer { close(descriptor) }

        while flock(descriptor, LOCK_EX) == -1 {
            guard errno == EINTR else {
                throw filesystemFailure()
            }
        }
        defer { _ = flock(descriptor, LOCK_UN) }

        if let lockAcquiredHook {
            await lockAcquiredHook(lockURL)
        }
        return try operation()
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

    private static func validatedExtension(_ fileExtension: String) throws -> String {
        let withoutLeadingDots = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "." })
        let extensionName = String(withoutLeadingDots)
        guard !extensionName.isEmpty,
              extensionName.lengthOfBytes(using: .utf8) <= maximumExtensionBytes,
              extensionName.unicodeScalars.allSatisfy({ !isUnsafeFilenameScalar($0) }) else {
            throw ExtensionValidationError.invalid
        }
        return extensionName
    }

    private static func candidateBasename(_ basename: String, suffix: String, fileExtension: String) -> String? {
        let extensionBytes = fileExtension.isEmpty ? 0 : fileExtension.lengthOfBytes(using: .utf8) + 1
        let auxiliaryOverhead = lockSuffix.lengthOfBytes(using: .utf8) + 1
        let maximumBaseBytes = min(
            maximumFilenameBytes - extensionBytes - suffix.lengthOfBytes(using: .utf8),
            maximumFilenameBytes - auxiliaryOverhead - suffix.lengthOfBytes(using: .utf8)
        )
        guard maximumBaseBytes > 0 else {
            return nil
        }
        let shortened = truncated(basename, toUTF8ByteCount: maximumBaseBytes)
        let candidate = (shortened.isEmpty ? truncated(fallbackBasename, toUTF8ByteCount: maximumBaseBytes) : shortened) + suffix
        return candidate.isEmpty ? nil : candidate
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
        return result
    }

    private static func isUnsafeFilenameScalar(_ scalar: UnicodeScalar) -> Bool {
        unsafeFilenameCharacters.contains(scalar) || scalar.value <= 0x1F || (0x7F...0x9F).contains(scalar.value)
    }

    private func destinationFailure() -> DownloadFailure {
        DownloadFailure(
            category: .outputPermissionDenied,
            technicalDetail: "The selected download folder is unavailable or not writable."
        )
    }

    private func filesystemFailure() -> DownloadFailure {
        DownloadFailure(
            category: .outputPermissionDenied,
            technicalDetail: "Unable to reserve a download filename in the selected folder."
        )
    }

    private func invalidExtensionFailure() -> DownloadFailure {
        DownloadFailure(
            category: .downloadFailed,
            technicalDetail: "The selected output file extension is invalid."
        )
    }

    private enum Claim {
        case claimed
        case sameJob
        case unavailable
    }

    private enum ExtensionValidationError: Error {
        case invalid
    }
}
