import Foundation

struct AppSettings: Codable, Equatable, Sendable {
    static let supportedConcurrentDownloads = 1...10

    var maximumConcurrentDownloads: Int
    var languageOverride: String?
    var defaultOptions: DownloadOptions
    var automaticallyCheckForUpdates: Bool

    static let defaults = AppSettings()

    init(
        maximumConcurrentDownloads: Int = 5,
        languageOverride: String? = nil,
        defaultOptions: DownloadOptions = .defaults,
        automaticallyCheckForUpdates: Bool = true
    ) {
        self.maximumConcurrentDownloads = Self.clamp(maximumConcurrentDownloads)
        self.languageOverride = languageOverride
        self.defaultOptions = defaultOptions
        self.automaticallyCheckForUpdates = automaticallyCheckForUpdates
    }

    private enum CodingKeys: String, CodingKey {
        case maximumConcurrentDownloads
        case languageOverride
        case defaultOptions
        case automaticallyCheckForUpdates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            maximumConcurrentDownloads: try container.decodeIfPresent(Int.self, forKey: .maximumConcurrentDownloads) ?? 5,
            languageOverride: try container.decodeIfPresent(String.self, forKey: .languageOverride),
            defaultOptions: try container.decodeIfPresent(DownloadOptions.self, forKey: .defaultOptions) ?? .defaults,
            automaticallyCheckForUpdates: try container.decodeIfPresent(Bool.self, forKey: .automaticallyCheckForUpdates) ?? true
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.clamp(maximumConcurrentDownloads), forKey: .maximumConcurrentDownloads)
        try container.encodeIfPresent(languageOverride, forKey: .languageOverride)
        try container.encode(defaultOptions, forKey: .defaultOptions)
        try container.encode(automaticallyCheckForUpdates, forKey: .automaticallyCheckForUpdates)
    }

    func clampedForPersistence() -> AppSettings {
        AppSettings(
            maximumConcurrentDownloads: maximumConcurrentDownloads,
            languageOverride: languageOverride,
            defaultOptions: defaultOptions,
            automaticallyCheckForUpdates: automaticallyCheckForUpdates
        )
    }

    mutating func setDefaultOutputDirectory(
        _ directory: URL,
        bookmarks: OutputDirectoryBookmarkService = .live
    ) throws {
        defaultOptions.outputDirectoryBookmark = try bookmarks.makeBookmark(for: directory)
        defaultOptions.outputDirectoryDisplayPath = directory.path
    }

    func resolvedDefaultOutputDirectory(
        bookmarks: OutputDirectoryBookmarkService = .live
    ) throws -> URL {
        guard let bookmark = defaultOptions.outputDirectoryBookmark else {
            throw OutputDirectoryBookmarkError.needsReselection
        }

        do {
            let resolution = try bookmarks.resolveBookmark(bookmark)
            guard !resolution.isStale else {
                throw OutputDirectoryBookmarkError.needsReselection
            }
            return resolution.url
        } catch is OutputDirectoryBookmarkError {
            throw OutputDirectoryBookmarkError.needsReselection
        } catch {
            throw OutputDirectoryBookmarkError.needsReselection
        }
    }

    private static func clamp(_ value: Int) -> Int {
        min(max(value, supportedConcurrentDownloads.lowerBound), supportedConcurrentDownloads.upperBound)
    }
}

enum OutputDirectoryBookmarkError: Error, Equatable, Sendable {
    case needsReselection
}

struct OutputDirectoryBookmarkService: Sendable {
    struct Resolution: Sendable {
        let url: URL
        let isStale: Bool
    }

    private let makeBookmarkClosure: @Sendable (URL) throws -> Data
    private let resolveBookmarkClosure: @Sendable (Data) throws -> Resolution

    init(
        makeBookmark: @escaping @Sendable (URL) throws -> Data,
        resolveBookmark: @escaping @Sendable (Data) throws -> Resolution
    ) {
        makeBookmarkClosure = makeBookmark
        resolveBookmarkClosure = resolveBookmark
    }

    static let live = OutputDirectoryBookmarkService(
        makeBookmark: { directory in
            try directory.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        },
        resolveBookmark: { bookmark in
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return Resolution(url: url, isStale: isStale)
        }
    )

    func makeBookmark(for directory: URL) throws -> Data {
        try makeBookmarkClosure(directory)
    }

    func resolveBookmark(_ bookmark: Data) throws -> Resolution {
        try resolveBookmarkClosure(bookmark)
    }
}

struct AppSettingsStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "app-settings") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return .defaults
        }
        return settings.clampedForPersistence()
    }

    func save(_ settings: AppSettings) {
        let normalized = settings.clampedForPersistence()
        guard let data = try? JSONEncoder().encode(normalized) else {
            return
        }
        defaults.set(data, forKey: key)
    }

}
