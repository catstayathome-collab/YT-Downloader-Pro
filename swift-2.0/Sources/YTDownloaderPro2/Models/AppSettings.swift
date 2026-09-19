import Foundation

struct AppSettings: Codable, Equatable, Sendable {
    static let supportedConcurrentDownloads = 1...10
    static let supportedLanguageOverrides = Set(L10n.supportedLocaleIdentifiers)

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
        self.languageOverride = Self.normalizedLanguageOverride(languageOverride)
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

    var locale: Locale {
        languageOverride.map(Locale.init(identifier:)) ?? .current
    }

    mutating func setDefaultOutputDirectory(
        _ directory: URL,
        bookmarks: OutputDirectoryBookmarkService = .live
    ) throws {
        defaultOptions.outputDirectoryBookmark = try bookmarks.makeBookmark(for: directory)
        defaultOptions.outputDirectoryDisplayPath = directory.path
    }

    func beginDefaultOutputDirectoryAccess(
        bookmarks: OutputDirectoryBookmarkService = .live
    ) throws -> OutputDirectorySecurityScopedAccess {
        let url = try resolveDefaultOutputDirectory(bookmarks: bookmarks)
        guard bookmarks.startAccessingSecurityScopedResource(at: url) else {
            throw OutputDirectoryBookmarkError.needsReselection
        }
        return OutputDirectorySecurityScopedAccess(url: url) {
            bookmarks.stopAccessingSecurityScopedResource(at: url)
        }
    }

    func withDefaultOutputDirectoryAccess<Result>(
        bookmarks: OutputDirectoryBookmarkService = .live,
        perform operation: (URL) throws -> Result
    ) throws -> Result {
        let access = try beginDefaultOutputDirectoryAccess(bookmarks: bookmarks)
        defer { access.stopAccessing() }
        return try operation(access.url)
    }

    private func resolveDefaultOutputDirectory(
        bookmarks: OutputDirectoryBookmarkService
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

    private static func normalizedLanguageOverride(_ value: String?) -> String? {
        guard let value, supportedLanguageOverrides.contains(value) else { return nil }
        return value
    }
}

enum OutputDirectoryBookmarkError: Error, Equatable, Sendable {
    case needsReselection
}

final class OutputDirectorySecurityScopedAccess {
    let url: URL

    private let stopAccessingClosure: () -> Void
    private var hasStopped = false

    init(url: URL, stopAccessing: @escaping () -> Void) {
        self.url = url
        stopAccessingClosure = stopAccessing
    }

    func stopAccessing() {
        guard !hasStopped else {
            return
        }
        hasStopped = true
        stopAccessingClosure()
    }

    deinit {
        stopAccessing()
    }
}

struct OutputDirectoryBookmarkService: Sendable {
    struct Resolution: Sendable {
        let url: URL
        let isStale: Bool
    }

    private let makeBookmarkClosure: @Sendable (URL) throws -> Data
    private let resolveBookmarkClosure: @Sendable (Data) throws -> Resolution
    private let startAccessingClosure: @Sendable (URL) -> Bool
    private let stopAccessingClosure: @Sendable (URL) -> Void

    init(
        makeBookmark: @escaping @Sendable (URL) throws -> Data,
        resolveBookmark: @escaping @Sendable (Data) throws -> Resolution,
        startAccessingSecurityScopedResource: @escaping @Sendable (URL) -> Bool = { url in
            url.startAccessingSecurityScopedResource()
        },
        stopAccessingSecurityScopedResource: @escaping @Sendable (URL) -> Void = { url in
            url.stopAccessingSecurityScopedResource()
        }
    ) {
        makeBookmarkClosure = makeBookmark
        resolveBookmarkClosure = resolveBookmark
        startAccessingClosure = startAccessingSecurityScopedResource
        stopAccessingClosure = stopAccessingSecurityScopedResource
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

    func startAccessingSecurityScopedResource(at url: URL) -> Bool {
        startAccessingClosure(url)
    }

    func stopAccessingSecurityScopedResource(at url: URL) {
        stopAccessingClosure(url)
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

    func reset() {
        defaults.removeObject(forKey: key)
    }

}
