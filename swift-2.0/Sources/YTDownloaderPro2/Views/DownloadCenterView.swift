import AppKit
import SwiftUI

struct DownloadColorToken: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color { Color(red: red, green: green, blue: blue) }

    var relativeLuminance: Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    func contrastRatio(with other: DownloadColorToken) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

struct DownloadCenterPalette: Equatable {
    let windowBackground: DownloadColorToken
    let sidebarBackground: DownloadColorToken
    let cardBackground: DownloadColorToken
    let thumbnailBackground: DownloadColorToken
    let border: DownloadColorToken
    let primaryText: DownloadColorToken
    let secondaryText: DownloadColorToken
}

enum DownloadCenterAppearance {
    static let preferredScheme: ColorScheme = .light
    static let palette = DownloadCenterPalette(
        windowBackground: DownloadColorToken(red: 0.97, green: 0.97, blue: 0.97),
        sidebarBackground: DownloadColorToken(red: 0.94, green: 0.95, blue: 0.95),
        cardBackground: DownloadColorToken(red: 1, green: 1, blue: 1),
        thumbnailBackground: DownloadColorToken(red: 0.92, green: 0.93, blue: 0.94),
        border: DownloadColorToken(red: 0.79, green: 0.80, blue: 0.81),
        primaryText: DownloadColorToken(red: 0.12, green: 0.13, blue: 0.14),
        secondaryText: DownloadColorToken(red: 0.34, green: 0.36, blue: 0.38)
    )
}

enum DownloadCenterAction: Equatable {
    case startAll
    case pauseAll
    case resumeAll
    case cancelActiveAndWaiting
    case clearCompleted

    var confirmation: DownloadConfirmation? {
        switch self {
        case .cancelActiveAndWaiting:
            .cancelActiveAndWaiting
        case .clearCompleted:
            .clearCompleted
        case .startAll, .pauseAll, .resumeAll:
            nil
        }
    }
}

struct DownloadCenterView: View {
    @EnvironmentObject private var store: DownloadStore

    @State private var url = ""
    @State private var pendingConfirmation: DownloadConfirmation?
    @State private var editingJob: DownloadJob?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            mainPane
        }
        .navigationSplitViewStyle(.balanced)
        .navigationSplitViewColumnWidth(min: 196, ideal: 196, max: 196)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                .accessibilityLabel("Settings")
            }
        }
        .sheet(item: $editingJob) { job in
            QueuedOptionsEditor(job: job) { options in
                Task { _ = await store.editQueuedJob(job.id, options: options) }
            }
        }
        .alert(item: $pendingConfirmation) { confirmation in
            Alert(
                title: Text(confirmation.title),
                message: Text(confirmation.message),
                primaryButton: .destructive(Text(confirmation.destructiveButtonTitle)) {
                    performConfirmed(confirmation)
                },
                secondaryButton: .cancel()
            )
        }
        .preferredColorScheme(DownloadCenterAppearance.preferredScheme)
    }

    private var sidebar: some View {
        List(selection: $store.sidebarSection) {
            Section("Downloads") {
                ForEach(DownloadStatus.SidebarSection.allCases, id: \.self) { section in
                    Label {
                        HStack {
                            Text(sidebarTitle(for: section))
                            Spacer(minLength: 8)
                            Text("\(count(for: section))")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    } icon: {
                        Image(systemName: sidebarSymbol(for: section))
                    }
                    .tag(section)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(DownloadCenterAppearance.palette.sidebarBackground.color)
        .foregroundStyle(DownloadCenterAppearance.palette.primaryText.color)
        .navigationTitle("Downloads")
    }

    private var mainPane: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField("Video or playlist URL", text: $url)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(analyzeURL)
                        .accessibilityLabel("Video or playlist URL")

                    Button("Analyze", action: analyzeURL)
                        .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAnalyzing)
                        .keyboardShortcut(.return, modifiers: [])
                }

                bulkToolbar
            }
            .padding(16)

            Divider()

            if store.filteredJobs.isEmpty {
                Spacer()
                Text("No downloads in this section")
                    .foregroundStyle(DownloadCenterAppearance.palette.secondaryText.color)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.filteredJobs) { job in
                            DownloadCardView(job: job) { editingJob = $0 }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .background(DownloadCenterAppearance.palette.windowBackground.color)
        .foregroundStyle(DownloadCenterAppearance.palette.primaryText.color)
        .navigationTitle(sidebarTitle(for: store.sidebarSection))
    }

    private var bulkToolbar: some View {
        HStack(spacing: 8) {
            bulkActionButton(
                title: "Start All",
                systemImage: "play.fill",
                isDisabled: !store.jobs.contains(where: { $0.status == .queued })
            ) {
                route(.startAll)
            }

            bulkActionButton(
                title: "Pause All",
                systemImage: "pause.fill",
                isDisabled: !store.jobs.contains(where: { $0.status.canPause })
            ) {
                route(.pauseAll)
            }

            bulkActionButton(
                title: "Resume All",
                systemImage: "play.fill",
                isDisabled: !store.jobs.contains(where: { $0.status == .paused })
            ) {
                route(.resumeAll)
            }

            bulkActionButton(
                title: "Cancel Active/Waiting",
                systemImage: "xmark",
                role: .destructive,
                isDisabled: !store.jobs.contains(where: { $0.status == .queued || $0.status.isActive })
            ) {
                route(.cancelActiveAndWaiting)
            }

            Spacer(minLength: 0)

            bulkActionButton(
                title: "Clear Completed",
                systemImage: "trash",
                isDisabled: !store.jobs.contains(where: { $0.status == .completed })
            ) {
                route(.clearCompleted)
            }
        }
        .controlSize(.small)
    }

    // Bulk command routing keeps confirmation policy separate from Store execution.
    private func route(_ action: DownloadCenterAction) {
        if let confirmation = action.confirmation {
            pendingConfirmation = confirmation
            return
        }
        switch action {
        case .startAll:
            Task { await store.startAll() }
        case .pauseAll:
            Task { await store.pauseAll() }
        case .resumeAll:
            Task { await store.resumeAll() }
        case .cancelActiveAndWaiting, .clearCompleted:
            return
        }
    }

    private func performConfirmed(_ confirmation: DownloadConfirmation) {
        switch confirmation {
        case .cancelActiveAndWaiting:
            Task { await store.cancelActiveAndWaiting() }
        case .clearCompleted:
            Task { await store.clearCompleted() }
        case .cancelMerging, .removeRecord:
            return
        }
    }

    private func bulkActionButton(
        title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .frame(width: 30, height: 28)
        }
        .buttonStyle(.borderless)
        .disabled(isDisabled)
        .help(title)
        .accessibilityLabel(title)
    }

    private var isAnalyzing: Bool {
        if case .analyzing = store.analysisState {
            true
        } else {
            false
        }
    }

    private func analyzeURL() {
        let requestedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedURL.isEmpty else { return }
        Task { await store.analyzeURL(requestedURL) }
    }

    private func count(for section: DownloadStatus.SidebarSection) -> Int {
        section == .all
            ? store.jobs.count
            : store.jobs.filter { $0.status.sidebarSection == section }.count
    }

    private func sidebarTitle(for section: DownloadStatus.SidebarSection) -> String {
        switch section {
        case .all: "All"
        case .running: "Running"
        case .stopped: "Stopped"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }

    private func sidebarSymbol(for section: DownloadStatus.SidebarSection) -> String {
        switch section {
        case .all: "square.stack.3d.up"
        case .running: "arrow.down.circle"
        case .stopped: "pause.circle"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        }
    }
}

private struct QueuedOptionsEditor: View {
    @Environment(\.dismiss) private var dismiss

    let job: DownloadJob
    let onSave: (DownloadOptions) -> Void

    @State private var outputKind: OutputKind

    init(job: DownloadJob, onSave: @escaping (DownloadOptions) -> Void) {
        self.job = job
        self.onSave = onSave
        _outputKind = State(initialValue: job.options.outputKind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Download")
                .font(.title3.weight(.semibold))
            Text(job.title)
                .lineLimit(2)

            Picker("Output", selection: $outputKind) {
                Text("MP4 video").tag(OutputKind.mp4)
                Text("MP3 audio").tag(OutputKind.mp3)
            }
            .pickerStyle(.segmented)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    var options = job.options
                    options.outputKind = outputKind
                    onSave(options)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

struct SettingsContentView: View {
    @EnvironmentObject private var store: DownloadStore

    var body: some View {
        Form {
            Stepper("Concurrent downloads: \(store.settings.maximumConcurrentDownloads)", value: maximumDownloads, in: 1...10)
        }
        .padding(20)
        .frame(width: 360)
        .background(DownloadCenterAppearance.palette.windowBackground.color)
        .foregroundStyle(DownloadCenterAppearance.palette.primaryText.color)
        .preferredColorScheme(DownloadCenterAppearance.preferredScheme)
    }

    private var maximumDownloads: Binding<Int> {
        Binding(
            get: { store.settings.maximumConcurrentDownloads },
            set: { value in
                var settings = store.settings
                settings.maximumConcurrentDownloads = value
                store.settings = settings
            }
        )
    }
}
