import AppKit
import SwiftUI

struct MediaIdentityPresentation: Equatable {
    enum Thumbnail: Equatable {
        case remote(URL)
        case fallback
    }

    let title: String
    let titleSource: MediaTitleSource?
    let durationText: String?
    let thumbnail: Thumbnail
    let titleLineLimit = 3

    init(analysis: VideoAnalysis) {
        title = analysis.title
        titleSource = analysis.titleSource
        durationText = analysis.duration.map(Self.formatDuration)
        thumbnail = analysis.thumbnailURL.map(Thumbnail.remote) ?? .fallback
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct DownloadOptionsViewState: Equatable {
    let availableSubtitleModes: [SubtitleMode]
    let outputFolderLabel: String
    let canSubmit: Bool

    init(options: DownloadOptions, locale: Locale = Locale(identifier: "en")) {
        availableSubtitleModes = options.outputKind == .mp3 ? [.none, .download] : [.none, .download, .embed]
        let hasBookmark = options.outputDirectoryBookmark?.isEmpty == false
        outputFolderLabel = hasBookmark
            ? options.outputDirectoryDisplayPath ?? L10n.string(.mediaSelectedOutputFolder, locale: locale)
            : L10n.string(.mediaChooseOutputFolder, locale: locale)
        canSubmit = hasBookmark
    }
}

struct MediaOptionsPresentation: Equatable {
    let identity: MediaIdentityPresentation?
    let videoChoices: [MediaFormat]
    let audioChoices: [MediaFormat]
    let subtitleChoices: [SubtitleTrack]?
    private(set) var selectedVideoID: String?
    private(set) var selectedAudioID: String?
    private(set) var options: DownloadOptions

    var quickTimeVideoChoices: [MediaFormat] {
        videoChoices.filter(QuickTimeMP4Compatibility.supportsVideo)
    }

    var quickTimeAudioChoices: [MediaFormat] {
        audioChoices.filter(QuickTimeMP4Compatibility.supportsAudio)
    }

    // MetadataProbe sorts typed formats highest-first, so the first usable choice is the reviewed default.
    init(
        analysis: VideoAnalysis,
        defaults: DownloadOptions,
        featurePolicy: FeaturePolicyContext = .publicCompatibility
    ) {
        identity = MediaIdentityPresentation(analysis: analysis)
        videoChoices = analysis.videoFormats
        audioChoices = analysis.audioFormats
        subtitleChoices = analysis.subtitleTracks
        options = defaults.normalizedForExecution()
        let compatibleVideoFormats = defaults.outputKind == .mp4
            ? analysis.videoFormats.filter(QuickTimeMP4Compatibility.supportsVideo)
            : analysis.videoFormats
        let selectableAudioFormats = defaults.outputKind == .mp4
            ? analysis.audioFormats.filter(QuickTimeMP4Compatibility.supportsAudio)
            : analysis.audioFormats
        let videoPresentation = VideoFormatMenuPresentation(
            formats: compatibleVideoFormats,
            selectedID: Self.selectedID(for: defaults.videoQuality, in: compatibleVideoFormats),
            outputKind: defaults.outputKind,
            featurePolicy: featurePolicy
        )
        selectedVideoID = videoPresentation.selectedID
        selectedAudioID = Self.selectedID(for: defaults.audioQuality, in: selectableAudioFormats)
            ?? selectableAudioFormats.first?.id
        applySelectedFormats()
        reconcileSubtitleSelection()
    }

    init(options: DownloadOptions) {
        let options = options.normalizedForExecution()
        identity = nil
        self.options = options
        subtitleChoices = nil
        selectedVideoID = Self.selectedID(for: options.videoQuality, in: [])
        selectedAudioID = Self.selectedID(for: options.audioQuality, in: [])
        videoChoices = Self.currentChoice(for: options.videoQuality, structured: options.selectedVideoFormat)
        audioChoices = Self.currentChoice(for: options.audioQuality, structured: options.selectedAudioFormat)
    }

    mutating func selectVideo(_ id: String?) {
        selectedVideoID = id
        applySelectedFormats()
    }

    mutating func selectAudio(_ id: String?) {
        selectedAudioID = id
        applySelectedFormats()
    }

    func decisionForSelectedOptions(in featurePolicy: FeaturePolicyContext) -> FeatureDecision {
        options.featurePolicyDecision(in: featurePolicy)
    }

    private static func selectedID(for quality: VideoQuality, in choices: [MediaFormat]) -> String? {
        guard case let .format(id, _) = quality, choices.isEmpty || choices.contains(where: { $0.id == id }) else {
            return nil
        }
        return id
    }

    private static func selectedID(for quality: AudioQuality, in choices: [MediaFormat]) -> String? {
        guard case let .format(id, _) = quality, choices.isEmpty || choices.contains(where: { $0.id == id }) else {
            return nil
        }
        return id
    }

    private static func currentChoice(for quality: VideoQuality, structured: PersistedFormatPresentation?) -> [MediaFormat] {
        guard case let .format(id, label) = quality else { return [] }
        if let structured, structured.id == id {
            return [structured.mediaFormat(fallbackLabel: label ?? id)]
        }
        return [storedFormat(id: id, label: label ?? id)]
    }

    private static func currentChoice(for quality: AudioQuality, structured: PersistedFormatPresentation?) -> [MediaFormat] {
        guard case let .format(id, label) = quality else { return [] }
        if let structured, structured.id == id {
            return [structured.mediaFormat(fallbackLabel: label ?? id)]
        }
        return [storedFormat(id: id, label: label ?? id)]
    }

    private static func storedFormat(id: String, label: String) -> MediaFormat {
        MediaFormat(
            id: id,
            label: label,
            codec: nil,
            videoCodec: nil,
            audioCodec: nil,
            container: nil,
            width: nil,
            height: nil,
            resolution: nil,
            framesPerSecond: nil,
            bitrate: nil,
            language: nil,
            estimatedFileSize: nil
        )
    }

    private mutating func applySelectedFormats() {
        if let selectedVideoID, let format = videoChoices.first(where: { $0.id == selectedVideoID }) {
            options.selectVideoFormat(format)
        } else {
            options.selectVideoFormat(nil)
        }
        if let selectedAudioID, let format = audioChoices.first(where: { $0.id == selectedAudioID }) {
            options.selectAudioFormat(format)
        } else {
            options.selectAudioFormat(nil)
        }
    }

    private mutating func reconcileSubtitleSelection() {
        guard options.subtitleMode != .none else { return }
        guard let subtitleChoices, !subtitleChoices.isEmpty else {
            options.subtitleMode = .none
            options.selectSubtitleTrack(nil)
            return
        }
        let selectedTrack = subtitleChoices.first {
            $0.languageCode == options.subtitleLanguage && $0.source == options.subtitleSource
        }
        options.selectSubtitleTrack(selectedTrack ?? subtitleChoices[0])
    }
}

struct MediaOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    private let titleKey: L10n.Key
    private let actionKey: L10n.Key
    private let identity: MediaIdentityPresentation?
    private let videoChoices: [MediaFormat]
    private let audioChoices: [MediaFormat]
    private let subtitleChoices: [SubtitleTrack]?
    private let onConfirm: (DownloadOptions) -> Void

    @State private var options: DownloadOptions

    init(
        analysis: VideoAnalysis,
        defaults: DownloadOptions,
        featurePolicy: FeaturePolicyContext = .publicCompatibility,
        titleKey: L10n.Key = .mediaOptionsTitle,
        actionKey: L10n.Key = .commonAddToQueue,
        onConfirm: @escaping (DownloadOptions) -> Void
    ) {
        let presentation = MediaOptionsPresentation(
            analysis: analysis,
            defaults: defaults,
            featurePolicy: featurePolicy
        )
        self.titleKey = titleKey
        self.actionKey = actionKey
        identity = presentation.identity
        videoChoices = presentation.videoChoices
        audioChoices = presentation.audioChoices
        subtitleChoices = presentation.subtitleChoices
        self.onConfirm = onConfirm
        _options = State(initialValue: presentation.options)
    }

    init(
        titleKey: L10n.Key,
        options: DownloadOptions,
        actionKey: L10n.Key = .commonSave,
        onConfirm: @escaping (DownloadOptions) -> Void
    ) {
        let presentation = MediaOptionsPresentation(options: options)
        self.titleKey = titleKey
        self.actionKey = actionKey
        identity = presentation.identity
        videoChoices = presentation.videoChoices
        audioChoices = presentation.audioChoices
        subtitleChoices = presentation.subtitleChoices
        self.onConfirm = onConfirm
        _options = State(initialValue: presentation.options)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string(titleKey, locale: locale))
                .font(.title3.weight(.semibold))

            if let identity {
                mediaIdentityHeader(identity)
            }

            ScrollView {
                Form {
                    DownloadOptionsEditor(
                        options: $options,
                        videoChoices: videoChoices,
                        audioChoices: audioChoices,
                        subtitleChoices: subtitleChoices
                    )
                }
                .formStyle(.grouped)
            }

            HStack {
                Spacer()
                Button(L10n.string(.commonCancel, locale: locale)) { dismiss() }
                Button(L10n.string(actionKey, locale: locale)) {
                    onConfirm(options)
                    dismiss()
                }
                .disabled(!DownloadOptionsViewState(options: options, locale: locale).canSubmit)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 540, idealWidth: 600, maxWidth: 680, minHeight: 500)
        .background(DownloadCenterAppearance.palette.windowBackground.color)
        .foregroundStyle(DownloadCenterAppearance.palette.primaryText.color)
        .preferredColorScheme(DownloadCenterAppearance.preferredScheme)
    }

    private func mediaIdentityHeader(_ identity: MediaIdentityPresentation) -> some View {
        HStack(alignment: .top, spacing: 12) {
            mediaThumbnail(identity.thumbnail)
                .frame(width: 112, height: 63)
                .background(DownloadCenterAppearance.palette.thumbnailBackground.color)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(MediaFallbackText.localized(identity.title, source: identity.titleSource, locale: locale))
                    .font(.headline)
                    .lineLimit(identity.titleLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let durationText = identity.durationText {
                    Text(durationText)
                        .font(.caption)
                        .foregroundStyle(DownloadCenterAppearance.palette.secondaryText.color)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func mediaThumbnail(_ thumbnail: MediaIdentityPresentation.Thumbnail) -> some View {
        switch thumbnail {
        case let .remote(url):
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    thumbnailFallback
                }
            }
        case .fallback:
            thumbnailFallback
        }
    }

    private var thumbnailFallback: some View {
        Image(systemName: "film")
            .font(.title2)
            .foregroundStyle(DownloadCenterAppearance.palette.secondaryText.color)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(L10n.string(.mediaThumbnailUnavailable, locale: locale))
    }
}

struct DownloadOptionsEditor: View {
    @EnvironmentObject private var store: DownloadStore
    @EnvironmentObject private var planController: PlanController
    @Environment(\.locale) private var locale
    @Binding var options: DownloadOptions

    let videoChoices: [MediaFormat]
    let audioChoices: [MediaFormat]
    var subtitleChoices: [SubtitleTrack]? = nil

    @State private var folderError: String?
    @State private var requestedUpgradeRoute: UpgradePresentationRoute?
    @State private var planChangeNotice: PlanChangeNotice?

    var body: some View {
        Group {
            Section(L10n.string(.mediaOutput, locale: locale)) {
                Picker(L10n.string(.mediaOutputFormat, locale: locale), selection: outputKind) {
                    Text(L10n.string(.downloadCardFormatMP4, locale: locale)).tag(OutputKind.mp4)
                    Text(L10n.string(.downloadCardFormatMP3, locale: locale)).tag(OutputKind.mp3)
                }
                .pickerStyle(.segmented)

                VideoFormatMenu(
                    title: L10n.string(.mediaVideoFormat, locale: locale),
                    emptySelectionLabel: L10n.string(.mediaHighestAvailable, locale: locale),
                    accesses: videoFormatPresentation.accesses,
                    selectedID: videoSelection.wrappedValue,
                    onSelect: { videoSelection.wrappedValue = $0 },
                    onRequestUpgrade: { requestedUpgradeRoute = UpgradePresentationRoute(denial: $0) }
                )

                Picker(L10n.string(.mediaAudioFormat, locale: locale), selection: audioSelection) {
                    Text(L10n.string(.mediaHighestAvailable, locale: locale)).tag(nil as String?)
                    ForEach(visibleAudioChoices) { format in
                        Text(MediaFormatPresentation.label(for: format, locale: locale))
                            .fixedSize(horizontal: false, vertical: true)
                            .tag(Optional(format.id))
                    }
                }
            }

            Section(L10n.string(.mediaSubtitles, locale: locale)) {
                Picker(L10n.string(.mediaSubtitleMode, locale: locale), selection: subtitleModeSelection) {
                    ForEach(viewState.availableSubtitleModes, id: \.self) { mode in
                        Text(subtitleModeLabel(mode)).tag(mode)
                    }
                }
                .disabled(subtitleChoices?.isEmpty == true)

                if let subtitleChoices {
                    if subtitleChoices.isEmpty {
                        Text(L10n.string(.mediaSubtitleUnavailable, locale: locale))
                            .foregroundStyle(DownloadCenterAppearance.palette.secondaryText.color)
                    } else {
                        Picker(
                            L10n.string(.mediaSubtitleLanguage, locale: locale),
                            selection: subtitleTrackSelection
                        ) {
                            Text(L10n.string(.mediaSubtitleChoose, locale: locale)).tag(nil as String?)
                            subtitlePickerSection(source: .official, tracks: subtitleChoices)
                            subtitlePickerSection(source: .automatic, tracks: subtitleChoices)
                        }
                        .disabled(options.subtitleMode == .none)
                    }
                } else {
                    TextField(L10n.string(.mediaSubtitleLanguage, locale: locale), text: subtitleLanguage)
                        .disabled(options.subtitleMode == .none)
                }
            }

            Section(L10n.string(.mediaMetadata, locale: locale)) {
                Toggle(L10n.string(.mediaEmbedThumbnail, locale: locale), isOn: $options.embedThumbnail)
                Toggle(L10n.string(.mediaEmbedMetadata, locale: locale), isOn: $options.embedMetadata)
                Picker(L10n.string(.mediaBrowserCookies, locale: locale), selection: $options.cookies) {
                    Text(L10n.string(.mediaCookiesNone, locale: locale)).tag(CookieMode.none)
                    Text(L10n.string(.mediaCookiesChrome, locale: locale)).tag(CookieMode.chrome)
                    Text(L10n.string(.mediaCookiesSafari, locale: locale)).tag(CookieMode.safari)
                }
            }

            Section(L10n.string(.mediaOutputFolder, locale: locale)) {
                HStack(spacing: 8) {
                    Text(viewState.outputFolderLabel)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        chooseFolder()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help(L10n.string(.mediaChooseOutputFolder, locale: locale))
                    .accessibilityLabel(L10n.string(.mediaChooseOutputFolder, locale: locale))
                }
                if let folderError {
                    Text(folderError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .sheet(item: $requestedUpgradeRoute) { route in
            LocalizedSheetRoot(locale: locale) {
                PlanComparisonView(route: route)
                    .environmentObject(planController)
            }
        }
        .alert(item: $planChangeNotice) { _ in
            Alert(
                title: Text(L10n.string(.planSelectionAdjustedTitle, locale: locale)),
                message: Text(L10n.string(.planSelectionAdjustedMessage, locale: locale)),
                dismissButton: .default(Text(L10n.string(.commonDone, locale: locale)))
            )
        }
        .onChange(of: planController.currentPlan) { _ in
            reconcileVideoSelectionForPlanChange()
        }
    }

    private var viewState: DownloadOptionsViewState {
        DownloadOptionsViewState(options: options, locale: locale)
    }

    private var outputKind: Binding<OutputKind> {
        Binding(
            get: { options.outputKind },
            set: { kind in
                options.selectOutputKind(kind)
                guard kind == .mp4 else { return }
                if !QuickTimeMP4Compatibility.supportsVideo(options.selectedVideoFormat) {
                    selectVideoFormat(id: videoFormatPresentation.highestAllowedID)
                }
                if !QuickTimeMP4Compatibility.supportsAudio(options.selectedAudioFormat) {
                    options.selectAudioFormat(visibleAudioChoices.first)
                }
            }
        )
    }

    private var visibleVideoChoices: [MediaFormat] {
        guard options.outputKind == .mp4 else { return videoChoices }
        return videoChoices.filter(QuickTimeMP4Compatibility.supportsVideo)
    }

    private var visibleAudioChoices: [MediaFormat] {
        guard options.outputKind == .mp4 else { return audioChoices }
        return audioChoices.filter(QuickTimeMP4Compatibility.supportsAudio)
    }

    private var videoFormatPresentation: VideoFormatMenuPresentation {
        VideoFormatMenuPresentation(
            formats: visibleVideoChoices,
            selectedID: videoSelection.wrappedValue,
            outputKind: options.outputKind,
            featurePolicy: planController.featurePolicyContext
        )
    }

    private func subtitleModeLabel(_ mode: SubtitleMode) -> String {
        switch mode {
        case .none: L10n.string(.mediaSubtitleNone, locale: locale)
        case .download: L10n.string(.mediaSubtitleDownload, locale: locale)
        case .embed: L10n.string(.mediaSubtitleEmbed, locale: locale)
        }
    }

    private var videoSelection: Binding<String?> {
        Binding(
            get: {
                guard case let .format(id, _) = options.videoQuality else { return nil }
                return id
            },
            set: { selectedID in
                selectVideoFormat(id: selectedID)
            }
        )
    }

    private func selectVideoFormat(id: String?) {
        guard let id, let format = videoChoices.first(where: { $0.id == id }) else {
            options.selectVideoFormat(nil)
            return
        }
        options.selectVideoFormat(format)
    }

    private func reconcileVideoSelectionForPlanChange() {
        let reconciliation = videoFormatPresentation.selectionReconciliation()
        guard reconciliation.didNormalize else { return }
        selectVideoFormat(id: reconciliation.selectedID)
        planChangeNotice = .videoQualityAdjusted
    }

    private var audioSelection: Binding<String?> {
        Binding(
            get: {
                guard case let .format(id, _) = options.audioQuality else { return nil }
                return id
            },
            set: { selectedID in
                guard let selectedID, let format = audioChoices.first(where: { $0.id == selectedID }) else {
                    options.selectAudioFormat(nil)
                    return
                }
                options.selectAudioFormat(format)
            }
        )
    }

    private var subtitleLanguage: Binding<String> {
        Binding(
            get: { options.subtitleLanguage ?? "" },
            set: { options.subtitleLanguage = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        )
    }

    private var subtitleModeSelection: Binding<SubtitleMode> {
        Binding(
            get: { options.subtitleMode },
            set: { mode in
                options.subtitleMode = mode
                guard mode != .none,
                      options.subtitleLanguage == nil,
                      let first = subtitleChoices?.first else {
                    return
                }
                options.selectSubtitleTrack(first)
            }
        )
    }

    private var subtitleTrackSelection: Binding<String?> {
        Binding(
            get: {
                guard let language = options.subtitleLanguage,
                      let source = options.subtitleSource else {
                    return nil
                }
                return "\(source.rawValue):\(language)"
            },
            set: { selectedID in
                let track = subtitleChoices?.first { $0.id == selectedID }
                options.selectSubtitleTrack(track)
            }
        )
    }

    @ViewBuilder
    private func subtitlePickerSection(source: SubtitleSource, tracks: [SubtitleTrack]) -> some View {
        let matchingTracks = tracks.filter { $0.source == source }
        if !matchingTracks.isEmpty {
            Section(subtitleSourceLabel(source)) {
                ForEach(matchingTracks) { track in
                    Text(subtitleTrackLabel(track)).tag(Optional(track.id))
                }
            }
        }
    }

    private func subtitleTrackLabel(_ track: SubtitleTrack) -> String {
        let officialSuffix = " - Official"
        let name = track.displayName.hasSuffix(officialSuffix)
            ? String(track.displayName.dropLast(officialSuffix.count))
            : track.displayName
        return "\(name) · \(subtitleSourceLabel(track.source))"
    }

    private func subtitleSourceLabel(_ source: SubtitleSource) -> String {
        switch source {
        case .official:
            L10n.string(.mediaSubtitleOfficial, locale: locale)
        case .automatic:
            L10n.string(.mediaSubtitleAutomatic, locale: locale)
        }
    }

    @MainActor
    private func chooseFolder() {
        guard let directory = OutputFolderPicker.choose(prompt: L10n.string(.commonChoose, locale: locale)) else { return }
        do {
            options = try store.optionsBySelectingOutputDirectory(directory, in: options)
            folderError = nil
        } catch {
            folderError = L10n.string(.mediaFolderSaveFailed, locale: locale)
        }
    }
}

private enum PlanChangeNotice: String, Identifiable {
    case videoQualityAdjusted

    var id: String { rawValue }
}

enum OutputFolderPicker {
    @MainActor
    static func choose(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

}
