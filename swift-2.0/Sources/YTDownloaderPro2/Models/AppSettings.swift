import Foundation

struct AppSettings: Codable, Equatable, Sendable {
    static let supportedConcurrentDownloads = 1...10

    var maximumConcurrentDownloads: Int

    static let defaults = AppSettings(maximumConcurrentDownloads: 5)

    init(maximumConcurrentDownloads: Int = 5) {
        self.maximumConcurrentDownloads = Self.clamp(maximumConcurrentDownloads)
    }

    private static func clamp(_ value: Int) -> Int {
        min(max(value, supportedConcurrentDownloads.lowerBound), supportedConcurrentDownloads.upperBound)
    }

}
