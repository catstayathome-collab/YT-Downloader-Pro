import Foundation

struct SystemProcessLauncher: ProcessLaunching {
    func run(executable: URL, arguments: [String]) async throws -> ProcessResult {
        let running = try await start(executable: executable, arguments: arguments)
        return try await running.result()
    }

    func start(executable: URL, arguments: [String]) async throws -> RunningProcess {
        let controller = ProcessController()
        try await controller.launch(executable: executable, arguments: arguments)
        return RunningProcess(controller: controller)
    }
}

struct ProcessLineBuffer: Sendable {
    private var bytes = Data()

    mutating func append(_ chunk: Data) -> [String] {
        bytes.append(chunk)
        return consumeCompleteLines()
    }

    mutating func finish() -> [String] {
        defer { bytes.removeAll(keepingCapacity: false) }
        guard !bytes.isEmpty else { return [] }
        return [Self.decodeLine(bytes)]
    }

    private mutating func consumeCompleteLines() -> [String] {
        var lines: [String] = []
        while let newlineIndex = bytes.firstIndex(of: 0x0A) {
            let lineBytes = bytes.prefix(upTo: newlineIndex)
            bytes.removeSubrange(...newlineIndex)
            lines.append(Self.decodeLine(lineBytes))
        }
        return lines
    }

    private static func decodeLine(_ data: Data) -> String {
        let withoutCarriageReturn: Data
        if data.last == 0x0D {
            withoutCarriageReturn = data.dropLast()
        } else {
            withoutCarriageReturn = data
        }
        return String(decoding: withoutCarriageReturn, as: UTF8.self)
    }
}

final class ProcessController: @unchecked Sendable {
    let events: AsyncStream<ProcessEvent>

    private let lock = NSLock()
    private let eventContinuation: AsyncStream<ProcessEvent>.Continuation
    private var process: Process?
    private var stdout = Data()
    private var stderr = Data()
    private var stdoutBuffer = ProcessLineBuffer()
    private var stderrBuffer = ProcessLineBuffer()
    private var exitCode: Int32?
    private var stdoutFinished = false
    private var stderrFinished = false
    private var childTerminated = false
    private var didFinish = false
    private var processResult: Result<ProcessResult, Error>?
    private var resultContinuations: [CheckedContinuation<ProcessResult, Error>] = []

    init() {
        var continuation: AsyncStream<ProcessEvent>.Continuation?
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation!
    }

    func launch(executable: URL, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let process = Process()
                let standardOutput = Pipe()
                let standardError = Pipe()

                process.executableURL = executable
                process.arguments = arguments
                process.standardOutput = standardOutput
                process.standardError = standardError
                process.terminationHandler = { [weak self] terminatedProcess in
                    self?.recordExitCode(terminatedProcess.terminationStatus)
                }

                standardOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    self?.read(handle: handle, pipe: .stdout)
                }
                standardError.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    self?.read(handle: handle, pipe: .stderr)
                }

                lock.lock()
                self.process = process
                lock.unlock()

                do {
                    try process.run()
                    standardOutput.fileHandleForWriting.closeFile()
                    standardError.fileHandleForWriting.closeFile()
                    continuation.resume(returning: ())
                } catch {
                    standardOutput.fileHandleForReading.readabilityHandler = nil
                    standardError.fileHandleForReading.readabilityHandler = nil
                    standardOutput.fileHandleForWriting.closeFile()
                    standardError.fileHandleForWriting.closeFile()
                    recordLaunchFailure(error)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func interruptIfRunning() {
        signal { $0.interrupt() }
    }

    func terminateIfRunning() {
        signal { $0.terminate() }
    }

    func result() async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let processResult {
                lock.unlock()
                continuation.resume(with: processResult)
                return
            }
            resultContinuations.append(continuation)
            lock.unlock()
        }
    }

    private func signal(_ action: (Process) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !childTerminated, !didFinish, let process, process.isRunning else { return }

        // Foundation has no atomic PID identity/liveness check. This lock prevents requests
        // after observed termination, but cannot close a process exit race during delivery.
        action(process)
    }

    private func read(handle: FileHandle, pipe: PipeKind) {
        let data = handle.availableData
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            finish(pipe: pipe)
            return
        }

        lock.lock()
        let events: [ProcessEvent]
        switch pipe {
        case .stdout:
            stdout.append(data)
            events = stdoutBuffer.append(data).map(ProcessEvent.stdoutLine)
        case .stderr:
            stderr.append(data)
            events = stderrBuffer.append(data).map(ProcessEvent.stderrLine)
        }
        yield(events)
        lock.unlock()
    }

    private func recordExitCode(_ status: Int32) {
        lock.lock()
        childTerminated = true
        exitCode = status
        let completion = completionIfReady()
        lock.unlock()
        publish(completion)
    }

    private func finish(pipe: PipeKind) {
        lock.lock()
        let finalLines: [String]
        switch pipe {
        case .stdout:
            guard !stdoutFinished else {
                lock.unlock()
                return
            }
            stdoutFinished = true
            finalLines = stdoutBuffer.finish()
        case .stderr:
            guard !stderrFinished else {
                lock.unlock()
                return
            }
            stderrFinished = true
            finalLines = stderrBuffer.finish()
        }
        let lineEvents: [ProcessEvent]
        switch pipe {
        case .stdout:
            lineEvents = finalLines.map(ProcessEvent.stdoutLine)
        case .stderr:
            lineEvents = finalLines.map(ProcessEvent.stderrLine)
        }
        yield(lineEvents)
        let completion = completionIfReady()
        lock.unlock()
        publish(completion)
    }

    private func recordLaunchFailure(_ error: Error) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        processResult = .failure(error)
        let continuations = resultContinuations
        resultContinuations.removeAll()
        lock.unlock()
        eventContinuation.finish()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private func completionIfReady() -> Completion? {
        guard
            !didFinish,
            let exitCode,
            stdoutFinished,
            stderrFinished
        else {
            return nil
        }

        didFinish = true
        process = nil
        let result = ProcessResult(
            exitCode: exitCode,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        )
        processResult = .success(result)
        let continuations = resultContinuations
        resultContinuations.removeAll()
        return Completion(exitCode: exitCode, resultContinuations: continuations, result: result)
    }

    private func yield(_ events: [ProcessEvent]) {
        for event in events {
            eventContinuation.yield(event)
        }
    }

    private func publish(_ completion: Completion?) {
        guard let completion else { return }
        eventContinuation.yield(.terminated(completion.exitCode))
        eventContinuation.finish()
        for continuation in completion.resultContinuations {
            continuation.resume(returning: completion.result)
        }
    }

    private enum PipeKind {
        case stdout
        case stderr
    }

    private struct Completion {
        let exitCode: Int32
        let resultContinuations: [CheckedContinuation<ProcessResult, Error>]
        let result: ProcessResult
    }
}
