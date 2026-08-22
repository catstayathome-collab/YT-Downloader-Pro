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

enum DownloadCenterKeyboardCommand: Equatable {
    case enter
    case space
    case delete
    case commandA
    case commandV
}

enum DownloadCenterKeyboardFocus: Equatable {
    case permanentURLField
    case editableText
    case interactiveControl
    case playlistSelectionSheet
    case modalSheet
    case nonEditable
}

enum DownloadCenterCommandDecision: Equatable {
    case analyzePermanentURL
    case toggleSelectedJob(UUID)
    case requestRecordRemoval(UUID)
    case selectAllPlaylistEntries
    case placeClipboardURL(String)
}

enum DownloadCenterCommandRouter {
    // Keep routing pure so a monitor consumes input only when the current focus makes the command legal.
    static func route(
        _ command: DownloadCenterKeyboardCommand,
        focus: DownloadCenterKeyboardFocus,
        selectedJob: DownloadJob?,
        clipboard: String?
    ) -> DownloadCenterCommandDecision? {
        switch command {
        case .enter:
            return focus == .permanentURLField ? .analyzePermanentURL : nil
        case .space:
            guard focus == .nonEditable,
                  let selectedJob,
                  selectedJob.status.canPause || selectedJob.status == .paused else { return nil }
            return .toggleSelectedJob(selectedJob.id)
        case .delete:
            guard focus == .nonEditable,
                  let selectedJob,
                  DownloadCardPresentation(job: selectedJob).actions.contains(.removeRecord) else { return nil }
            return .requestRecordRemoval(selectedJob.id)
        case .commandA:
            return focus == .playlistSelectionSheet ? .selectAllPlaylistEntries : nil
        case .commandV:
            guard focus == .nonEditable,
                  let clipboard = clipboard?.trimmingCharacters(in: .whitespacesAndNewlines),
                  isSupportedURL(clipboard) else { return nil }
            return .placeClipboardURL(clipboard)
        }
    }

    private static func isSupportedURL(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              let host = url.host,
              !host.isEmpty else { return false }
        return ["http", "https"].contains(scheme)
    }
}

private enum AnalysisSheet: Identifiable {
    case video(VideoAnalysis)
    case playlist(PlaylistAnalysis)

    var id: String {
        switch self {
        case let .video(analysis): "video-\(analysis.sourceURL)"
        case let .playlist(analysis): "playlist-\(analysis.id)"
        }
    }
}

struct DownloadCenterView: View {
    @EnvironmentObject private var store: DownloadStore

    @State private var url = ""
    @State private var pendingConfirmation: DownloadConfirmation?
    @State private var editingJob: DownloadJob?
    @State private var analysisSheet: AnalysisSheet?
    @State private var pendingRecordRemovalJobID: UUID?
    @State private var playlistSelectAllToken = UUID()
    @FocusState private var focusedField: FocusedField?

    private enum FocusedField: Hashable {
        case url
    }

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
            MediaOptionsSheet(title: "Edit Download", options: job.options) { options in
                Task { _ = await store.editQueuedJob(job.id, options: options) }
            }
        }
        .sheet(item: $analysisSheet) { sheet in
            switch sheet {
            case let .video(analysis):
                MediaOptionsSheet(analysis: analysis, defaults: store.settings.defaultOptions) { options in
                    analysisSheet = nil
                    Task { await store.addVideo(options: options) }
                }
            case let .playlist(analysis):
                PlaylistSelectionSheet(
                    analysis: analysis,
                    defaults: store.settings.defaultOptions,
                    selectAllToken: playlistSelectAllToken
                ) { selectedIDs, options in
                    analysisSheet = nil
                    Task { await store.addPlaylistEntries(selectedIDs: selectedIDs, options: options) }
                }
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
        .onChange(of: store.analysisState) { state in
            switch state {
            case let .video(analysis):
                focusedField = nil
                analysisSheet = .video(analysis)
            case let .playlist(analysis):
                focusedField = nil
                analysisSheet = .playlist(analysis)
            case .idle, .analyzing, .failed:
                break
            }
        }
        .background {
            KeyboardCommandMonitor(
                urlFieldIsFocused: focusedField == .url,
                playlistSelectionIsPresented: isPlaylistSelectionPresented,
                modalSheetIsPresented: analysisSheet != nil || editingJob != nil,
                selectedJob: selectedJob,
                perform: performKeyboardDecision
            )
            .frame(width: 0, height: 0)
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
                        .focused($focusedField, equals: .url)
                        .onSubmit(analyzeURL)
                        .accessibilityLabel("Video or playlist URL")

                    Button("Analyze", action: analyzeURL)
                        .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAnalyzing)
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
                            DownloadCardView(job: job, isSelected: store.selection.contains(job.id)) { editingJob = $0 }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    store.selection = [job.id]
                                }
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
        case .removeRecord:
            guard let jobID = pendingRecordRemovalJobID else { return }
            pendingRecordRemovalJobID = nil
            Task { await store.removeRecord(jobID) }
        case .cancelMerging:
            return
        }
    }

    private var selectedJob: DownloadJob? {
        store.jobs.first(where: { store.selection.contains($0.id) })
    }

    private var isPlaylistSelectionPresented: Bool {
        guard case .some(.playlist) = analysisSheet else { return false }
        return true
    }

    private func performKeyboardDecision(_ decision: DownloadCenterCommandDecision) {
        switch decision {
        case .analyzePermanentURL:
            analyzeURL()
        case let .toggleSelectedJob(jobID):
            guard let job = store.jobs.first(where: { $0.id == jobID }) else { return }
            if job.status == .paused {
                Task { await store.resume(jobID) }
            } else if job.status.canPause {
                Task { await store.pause(jobID) }
            }
        case let .requestRecordRemoval(jobID):
            pendingRecordRemovalJobID = jobID
            pendingConfirmation = .removeRecord
        case .selectAllPlaylistEntries:
            playlistSelectAllToken = UUID()
        case let .placeClipboardURL(clipboardURL):
            url = clipboardURL
            focusedField = .url
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

private struct KeyboardCommandMonitor: NSViewRepresentable {
    let urlFieldIsFocused: Bool
    let playlistSelectionIsPresented: Bool
    let modalSheetIsPresented: Bool
    let selectedJob: DownloadJob?
    let perform: (DownloadCenterCommandDecision) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator {
        var parent: KeyboardCommandMonitor
        private var monitor: Any?

        init(parent: KeyboardCommandMonitor) {
            self.parent = parent
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let command = keyboardCommand(for: event) else { return event }
            let focus = keyboardFocus(for: NSApp.keyWindow?.firstResponder)
            let clipboard = command == .commandV ? NSPasteboard.general.string(forType: .string) : nil
            guard let decision = DownloadCenterCommandRouter.route(
                command,
                focus: focus,
                selectedJob: parent.selectedJob,
                clipboard: clipboard
            ) else {
                return event
            }
            parent.perform(decision)
            return nil
        }

        private func keyboardCommand(for event: NSEvent) -> DownloadCenterKeyboardCommand? {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let characters = event.charactersIgnoringModifiers
            if modifiers == [] {
                switch characters {
                case " ": return .space
                case "\r", "\n": return .enter
                case "\u{7F}", "\u{8}": return .delete
                default: return nil
                }
            }
            guard modifiers == .command else { return nil }
            switch characters?.lowercased() {
            case "a": return .commandA
            case "v": return .commandV
            default: return nil
            }
        }

        private func keyboardFocus(for responder: NSResponder?) -> DownloadCenterKeyboardFocus {
            if responderHierarchy(responder, contains: { $0 is NSTextView || $0 is NSTextField }) {
                return parent.urlFieldIsFocused ? .permanentURLField : .editableText
            }
            if responderHierarchy(responder, contains: { $0 is NSControl }) {
                return .interactiveControl
            }
            if parent.playlistSelectionIsPresented {
                return .playlistSelectionSheet
            }
            if parent.modalSheetIsPresented {
                return .modalSheet
            }
            return parent.urlFieldIsFocused ? .permanentURLField : .nonEditable
        }

        private func responderHierarchy(_ responder: NSResponder?, contains predicate: (NSResponder) -> Bool) -> Bool {
            var current = responder
            while let candidate = current {
                if predicate(candidate) {
                    return true
                }
                current = candidate.nextResponder
            }
            return false
        }
    }
}
