import Foundation

struct ProcessResult: Equatable, Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum ProcessEvent: Codable, Equatable, Sendable {
    case stdoutLine(String)
    case stderrLine(String)
    case terminated(Int32)
}

protocol ProcessRunning: Sendable {
    func run(executable: URL, arguments: [String]) async throws -> ProcessResult
}

protocol ProcessLaunching: ProcessRunning {
    func start(executable: URL, arguments: [String]) async throws -> RunningProcess
}

actor RunningProcess {
    nonisolated let events: AsyncStream<ProcessEvent>

    private let controller: ProcessController
    private var interrupted = false
    private var terminated = false

    init(controller: ProcessController) {
        self.controller = controller
        events = controller.events
    }

    func interrupt() {
        guard !interrupted else { return }
        interrupted = true
        controller.interruptIfRunning()
    }

    func terminate() {
        guard !terminated else { return }
        terminated = true
        controller.terminateIfRunning()
    }

    func result() async throws -> ProcessResult {
        try await controller.result()
    }
}
