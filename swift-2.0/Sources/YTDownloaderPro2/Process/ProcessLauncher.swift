import Foundation

struct ProcessResult: Equatable, Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

protocol ProcessRunning: Sendable {
    func run(executable: URL, arguments: [String]) async throws -> ProcessResult
}
