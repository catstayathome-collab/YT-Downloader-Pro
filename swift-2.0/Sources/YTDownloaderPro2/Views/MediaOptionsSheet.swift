import AppKit
import SwiftUI

struct MediaOptionsPresentation: Equatable {
    let videoChoices: [MediaFormat]
    let audioChoices: [MediaFormat]
    private(set) var selectedVideoID: String?
    private(set) var selectedAudioID: String?
    private(set) var options: DownloadOptions

    // MetadataProbe sorts typed formats highest-first, so the first usable choice is the reviewed default.
    init(analysis: VideoAnalysis, defaults: DownloadOptions) {
        videoChoices = analysis.videoFormats
        audioChoices = analysis.audioFormats
        options = defaults
        selectedVideoID = Self.selectedID(for: defaults.videoQuality, in: analysis.videoFormats)
            ?? analysis.videoFormats.first?.id
        selectedAudioID = Self.selectedID(for: defaults.audioQuality, in: analysis.audioFormats)
            ?? analysis.audioFormats.first?.id
        applySelectedFormats()
    }

    init(options: DownloadOptions) {
        self.options = options
        selectedVideoID = Self.selectedID(for: options.videoQuality, in: [])
        selectedAudioID = Self.selectedID(for: options.audioQuality, in: [])
        videoChoices = Self.currentChoice(for: options.videoQuality)
        audioChoices = Self.currentChoice(for: options.audioQuality)
    }

    mutating func selectVideo(_ id: String?) {
        selectedVideoID = id
        applySelectedFormats()
    }

    mutating func selectAudio(_ id: String?) {
        selectedAudioID = id
        applySelectedFormats()
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

    private static func currentChoice(for quality: VideoQuality) -> [MediaFormat] {
        guard case let .format(id, label) = quality else { return [] }
        return [storedFormat(id: id, label: label)]
    }

    private static func currentChoice(for quality: AudioQuality) -> [MediaFormat] {
        guard case let .format(id, label) = quality else { return [] }
        return [storedFormat(id: id, label: label)]
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
            options.videoQuality = .format(id: format.id, label: format.label)
        } else {
            options.videoQuality = .best
        }
        if let selectedAudioID, let format = audioChoices.first(where: { $0.id == selectedAudioID }) {
            options.audioQuality = .format(id: format.id, label: format.label)
        } else {
            options.audioQuality = .best
        }
    }
}

struct MediaOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let title: String
    private let actionTitle: String
    private let videoChoices: [MediaFormat]
    private let audioChoices: [MediaFormat]
    private let onConfirm: (DownloadOptions) -> Void

    @State private var options: DownloadOptions

    init(
        analysis: VideoAnalysis,
        defaults: DownloadOptions,
        title: String = "Media Options",
        actionTitle: String = "Add to Queue",
        onConfirm: @escaping (DownloadOptions) -> Void
    ) {
        let presentation = MediaOptionsPresentation(analysis: analysis, defaults: defaults)
        self.title = title
        self.actionTitle = actionTitle
        videoChoices = presentation.videoChoices
        audioChoices = presentation.audioChoices
        self.onConfirm = onConfirm
        _options = State(initialValue: presentation.options)
    }

    init(
        title: String,
        options: DownloadOptions,
        actionTitle: String = "Save",
        onConfirm: @escaping (DownloadOptions) -> Void
    ) {
        let presentation = MediaOptionsPresentation(options: options)
        self.title = title
        self.actionTitle = actionTitle
        videoChoices = presentation.videoChoices
        audioChoices = presentation.audioChoices
        self.onConfirm = onConfirm
        _options = State(initialValue: presentation.options)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3.weight(.semibold))

            ScrollView {
                Form {
                    DownloadOptionsEditor(options: $options, videoChoices: videoChoices, audioChoices: audioChoices)
                }
                .formStyle(.grouped)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(actionTitle) {
                    onConfirm(options)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 540, idealWidth: 600, maxWidth: 680, minHeight: 500)
        .background(DownloadCenterAppearance.palette.windowBackground.color)
        .foregroundStyle(DownloadCenterAppearance.palette.primaryText.color)
        .preferredColorScheme(DownloadCenterAppearance.preferredScheme)
    }
}

struct DownloadOptionsEditor: View {
    @Binding var options: DownloadOptions

    let videoChoices: [MediaFormat]
    let audioChoices: [MediaFormat]

    @State private var folderError: String?

    var body: some View {
        Group {
            Section("Output") {
                Picker("Output format", selection: $options.outputKind) {
                    Text("MP4 video").tag(OutputKind.mp4)
                    Text("MP3 audio").tag(OutputKind.mp3)
                }
                .pickerStyle(.segmented)

                Picker("Video format", selection: videoSelection) {
                    Text("Highest available").tag(nil as String?)
                    ForEach(videoChoices) { format in
                        Text(format.label)
                            .fixedSize(horizontal: false, vertical: true)
                            .tag(Optional(format.id))
                    }
                }

                Picker("Audio format", selection: audioSelection) {
                    Text("Highest available").tag(nil as String?)
                    ForEach(audioChoices) { format in
                        Text(format.label)
                            .fixedSize(horizontal: false, vertical: true)
                            .tag(Optional(format.id))
                    }
                }
            }

            Section("Subtitles") {
                Picker("Subtitle mode", selection: $options.subtitleMode) {
                    Text("None").tag(SubtitleMode.none)
                    Text("Download").tag(SubtitleMode.download)
                    Text("Embed").tag(SubtitleMode.embed)
                }
                TextField("Subtitle language", text: subtitleLanguage)
                    .disabled(options.subtitleMode == .none)
            }

            Section("Metadata") {
                Toggle("Embed thumbnail", isOn: $options.embedThumbnail)
                Toggle("Embed metadata", isOn: $options.embedMetadata)
                Picker("Browser cookies", selection: $options.cookies) {
                    Text("None").tag(CookieMode.none)
                    Text("Chrome").tag(CookieMode.chrome)
                    Text("Safari").tag(CookieMode.safari)
                }
            }

            Section("Output folder") {
                HStack(spacing: 8) {
                    Text(options.outputDirectoryDisplayPath ?? "Default download folder")
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        chooseFolder()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Choose output folder")
                    .accessibilityLabel("Choose output folder")
                }
                if let folderError {
                    Text(folderError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var videoSelection: Binding<String?> {
        Binding(
            get: {
                guard case let .format(id, _) = options.videoQuality else { return nil }
                return id
            },
            set: { selectedID in
                guard let selectedID, let format = videoChoices.first(where: { $0.id == selectedID }) else {
                    options.videoQuality = .best
                    return
                }
                options.videoQuality = .format(id: format.id, label: format.label)
            }
        )
    }

    private var audioSelection: Binding<String?> {
        Binding(
            get: {
                guard case let .format(id, _) = options.audioQuality else { return nil }
                return id
            },
            set: { selectedID in
                guard let selectedID, let format = audioChoices.first(where: { $0.id == selectedID }) else {
                    options.audioQuality = .best
                    return
                }
                options.audioQuality = .format(id: format.id, label: format.label)
            }
        )
    }

    private var subtitleLanguage: Binding<String> {
        Binding(
            get: { options.subtitleLanguage ?? "" },
            set: { options.subtitleLanguage = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        )
    }

    @MainActor
    private func chooseFolder() {
        guard let directory = OutputFolderPicker.choose() else { return }
        do {
            try OutputFolderPicker.apply(directory, to: &options)
            folderError = nil
        } catch {
            folderError = "The selected folder could not be saved. Choose it again."
        }
    }
}

enum OutputFolderPicker {
    @MainActor
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func apply(_ directory: URL, to options: inout DownloadOptions) throws {
        options.outputDirectoryBookmark = try OutputDirectoryBookmarkService.live.makeBookmark(for: directory)
        options.outputDirectoryDisplayPath = directory.path
    }
}
