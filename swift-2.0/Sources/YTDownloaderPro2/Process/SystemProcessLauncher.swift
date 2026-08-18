import Foundation

struct SystemProcessLauncher: ProcessRunning {
    func run(executable: URL, arguments: [String]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let standardOutput = Pipe()
                let standardError = Pipe()
                let collection = ProcessCollection(continuation: continuation)

                process.executableURL = executable
                process.arguments = arguments
                process.standardOutput = standardOutput
                process.standardError = standardError
                process.terminationHandler = { terminatedProcess in
                    collection.recordExitCode(terminatedProcess.terminationStatus)
                }

                collection.readStandardOutput(from: standardOutput.fileHandleForReading)
                collection.readStandardError(from: standardError.fileHandleForReading)

                do {
                    try process.run()
                    standardOutput.fileHandleForWriting.closeFile()
                    standardError.fileHandleForWriting.closeFile()
                } catch {
                    standardOutput.fileHandleForWriting.closeFile()
                    standardError.fileHandleForWriting.closeFile()
                    collection.recordLaunchFailure(error)
                }
            }
        }
    }
}

private final class ProcessCollection: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProcessResult, Error>?
    private var stdout = Data()
    private var stderr = Data()
    private var exitCode: Int32?
    private var finishedReadingStandardOutput = false
    private var finishedReadingStandardError = false

    init(continuation: CheckedContinuation<ProcessResult, Error>) {
        self.continuation = continuation
    }

    func readStandardOutput(from handle: FileHandle) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let data = handle.readDataToEndOfFile()
            recordStandardOutput(data)
        }
    }

    func readStandardError(from handle: FileHandle) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let data = handle.readDataToEndOfFile()
            recordStandardError(data)
        }
    }

    func recordExitCode(_ status: Int32) {
        lock.lock()
        exitCode = status
        resumeIfComplete()
        lock.unlock()
    }

    func recordLaunchFailure(_ error: Error) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    private func recordStandardOutput(_ data: Data) {
        lock.lock()
        stdout = data
        finishedReadingStandardOutput = true
        resumeIfComplete()
        lock.unlock()
    }

    private func recordStandardError(_ data: Data) {
        lock.lock()
        stderr = data
        finishedReadingStandardError = true
        resumeIfComplete()
        lock.unlock()
    }

    private func resumeIfComplete() {
        guard
            let exitCode,
            finishedReadingStandardOutput,
            finishedReadingStandardError,
            let continuation
        else {
            return
        }

        self.continuation = nil
        continuation.resume(returning: ProcessResult(
            exitCode: exitCode,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        ))
    }
}
