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
    case clearHistory

    var confirmation: DownloadConfirmation? {
        switch self {
        case .cancelActiveAndWaiting:
            .cancelActiveAndWaiting
        case .clearHistory:
            .clearHistory
        case .startAll, .pauseAll, .resumeAll:
            nil
        }
    }
}

struct DownloadCenterBulkPresentation {
    let jobs: [DownloadJob]

    func isEnabled(_ action: DownloadCenterAction) -> Bool {
        switch action {
        case .startAll:
            jobs.contains { $0.status == .queued }
        case .pauseAll:
            jobs.contains { $0.status.canPause }
        case .resumeAll:
            jobs.contains { $0.status == .paused }
        case .cancelActiveAndWaiting:
            jobs.contains { $0.status == .queued || $0.status.isActive }
        case .clearHistory:
            jobs.contains { $0.status.isTerminal }
        }
    }

    func symbol(for action: DownloadCenterAction) -> String {
        switch action {
        case .startAll: "play.fill"
        case .pauseAll: "pause.fill"
        case .resumeAll: "play.circle.fill"
        case .cancelActiveAndWaiting: "xmark"
        case .clearHistory: "trash"
        }
    }
}

enum DownloadCenterPresentedAlert: Equatable, Identifiable {
    case confirmation(DownloadConfirmation)
    case automaticUpdate(UpdateNotice)

    var id: String {
        switch self {
        case let .confirmation(confirmation): "confirmation-\(confirmation.id)"
        case let .automaticUpdate(notice): "automatic-update-\(notice.id)"
        }
    }

    static func resolve(
        confirmation: DownloadConfirmation?,
        automaticUpdate: UpdateNotice?
    ) -> DownloadCenterPresentedAlert? {
        if let confirmation {
            return .confirmation(confirmation)
        }
        if let automaticUpdate {
            return .automaticUpdate(automaticUpdate)
        }
        return nil
    }
}

enum SettingsWindowLauncher {
    @discardableResult
    @MainActor
    static func openLegacy() -> Bool {
        let opened = openLegacy(
            openMenuItem: openStandardSettingsMenuItem,
            sendAction: { selector in NSApp.sendAction(selector, to: nil, from: nil) }
        )
        if !opened {
            NSSound.beep()
        }
        return opened
    }

    @discardableResult
    static func openLegacy(
        openMenuItem: () -> Bool = { false },
        sendAction: (Selector) -> Bool
    ) -> Bool {
        if openMenuItem() {
            return true
        }
        for selectorName in ["showSettingsWindow:", "showPreferencesWindow:"] {
            if sendAction(NSSelectorFromString(selectorName)) {
                return true
            }
        }
        return false
    }

    @MainActor
    private static func openStandardSettingsMenuItem() -> Bool {
        guard let item = findSettingsMenuItem(in: NSApp.mainMenu),
              let action = item.action else { return false }
        return NSApp.sendAction(action, to: item.target, from: item)
    }

    @MainActor
    private static func findSettingsMenuItem(in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.keyEquivalent == ",",
               item.keyEquivalentModifierMask.contains(.command),
               item.isEnabled,
               item.action != nil {
                return item
            }
            if let nested = findSettingsMenuItem(in: item.submenu) {
                return nested
            }
        }
        return nil
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

struct DownloadCenterResponderContext: Equatable {
    let urlFieldIsFocused: Bool
    let playlistSelectionIsPresented: Bool
    let modalSheetIsPresented: Bool
    let responderIsEditableText: Bool
    let responderIsControl: Bool
}

enum DownloadCenterFocusClassifier {
    // Editable text always keeps native commands; a playlist otherwise owns Command-A across its controls.
    static func classify(_ context: DownloadCenterResponderContext) -> DownloadCenterKeyboardFocus {
        if context.responderIsEditableText {
            return context.urlFieldIsFocused ? .permanentURLField : .editableText
        }
        if context.playlistSelectionIsPresented {
            return .playlistSelectionSheet
        }
        if context.responderIsControl {
            return .interactiveControl
        }
        if context.modalSheetIsPresented {
            return .modalSheet
        }
        return context.urlFieldIsFocused ? .permanentURLField : .nonEditable
    }
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
        MediaURLValidator.isSupported(value)
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

private enum DownloadOptionsSheet: Identifiable {
    case queued(QueuedJobEditSession)
    case failedPreflight(DownloadJob)
    case failedFresh(FailedJobEditSession)

    var id: String {
        switch self {
        case let .queued(session): "queued-\(session.id)"
        case let .failedPreflight(job): "failed-preflight-\(job.id.uuidString)"
        case let .failedFresh(session): "failed-fresh-\(session.id)"
        }
    }
}

struct DownloadCenterView: View {
    @EnvironmentObject private var store: DownloadStore
    @Environment(\.locale) private var locale

    @State private var url = ""
    @State private var pendingConfirmation: DownloadConfirmation?
    @State private var optionsSheet: DownloadOptionsSheet?
    @State private var analysisSheet: AnalysisSheet?
    @State private var pendingRecordRemovalJobID: UUID?
    @State private var playlistSelectAllToken = UUID()
    @State private var showsAnalysisErrorDetails = false
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
                if #available(macOS 14.0, *) {
                    SettingsLink {
                        Image(systemName: "gearshape")
                    }
                    .help(L10n.string(.appSettings, locale: locale))
                    .accessibilityLabel(L10n.string(.appSettings, locale: locale))
                } else {
                    Button {
                        SettingsWindowLauncher.openLegacy()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help(L10n.string(.appSettings, locale: locale))
                    .accessibilityLabel(L10n.string(.appSettings, locale: locale))
                }
            }
        }
        .sheet(item: $optionsSheet) { sheet in
            switch sheet {
            case let .queued(session):
                MediaOptionsSheet(
                    analysis: session.analysis,
                    defaults: session.options,
                    titleKey: .mediaEditDownload,
                    actionKey: .commonSave
                ) { options in
                    optionsSheet = nil
                    Task { _ = await store.applyQueuedJobEdit(session, options: options) }
                }
            case let .failedPreflight(job):
                MediaOptionsSheet(
                    titleKey: .mediaEditAndRetry,
                    options: job.options,
                    actionKey: .mediaReanalyze
                ) { options in
                    optionsSheet = nil
                    Task {
                        if let session = await store.prepareFailedJobEdit(job.id, options: options) {
                            optionsSheet = .failedFresh(session)
                        }
                    }
                }
            case let .failedFresh(session):
                MediaOptionsSheet(
                    analysis: session.analysis,
                    defaults: session.options,
                    titleKey: .mediaEditAndRetry,
                    actionKey: .downloadActionRetry
                ) { options in
                    optionsSheet = nil
                    Task { _ = await store.applyFailedJobEdit(session, options: options) }
                }
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
        .sheet(isPresented: $showsAnalysisErrorDetails) {
            if case let .failed(failure) = store.analysisState {
                ErrorDetailsView(failure: failure)
            }
        }
        .alert(item: presentedAlert) { alert in
            switch alert {
            case let .confirmation(confirmation):
                Alert(
                    title: Text(confirmation.title(locale: locale)),
                    message: Text(confirmation.message(locale: locale)),
                    primaryButton: .destructive(Text(confirmation.destructiveButtonTitle(locale: locale))) {
                        performConfirmed(confirmation)
                    },
                    secondaryButton: .cancel(Text(L10n.string(.commonCancel, locale: locale)))
                )
            case let .automaticUpdate(notice):
                UpdateAlertFactory.make(notice: notice, locale: locale)
            }
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
                modalSheetIsPresented: analysisSheet != nil || optionsSheet != nil,
                selectedJob: selectedJob,
                perform: performKeyboardDecision
            )
            .frame(width: 0, height: 0)
        }
        .preferredColorScheme(DownloadCenterAppearance.preferredScheme)
    }

    private var presentedAlert: Binding<DownloadCenterPresentedAlert?> {
        Binding(
            get: {
                DownloadCenterPresentedAlert.resolve(
                    confirmation: pendingConfirmation,
                    automaticUpdate: store.automaticUpdateNotice
                )
            },
            set: { alert in
                guard alert == nil else { return }
                if pendingConfirmation != nil {
                    pendingConfirmation = nil
                } else if let id = store.automaticUpdateNotice?.id {
                    store.dismissAutomaticUpdateNotice(id: id)
                }
            }
        )
    }

    private var sidebar: some View {
        List(selection: $store.sidebarSection) {
            Section(L10n.string(.downloadCenterTitle, locale: locale)) {
                ForEach(DownloadStatus.SidebarSection.allCases, id: \.self) { section in
                    Label {
                        HStack {
                            Text(sidebarTitle(for: section, locale: locale))
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
        .navigationTitle(L10n.string(.downloadCenterTitle, locale: locale))
    }

    private var mainPane: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField(L10n.string(.downloadCenterURLPlaceholder, locale: locale), text: $url)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .url)
                        .onSubmit(analyzeURL)
                        .accessibilityLabel(L10n.string(.downloadCenterURLPlaceholder, locale: locale))

                    Button(L10n.string(.downloadCenterAnalyze, locale: locale), action: analyzeURL)
                        .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAnalyzing)
                }

                bulkToolbar
            }
            .padding(16)

            Divider()

            analysisStatus

            if store.filteredJobs.isEmpty {
                Spacer()
                Text(L10n.string(.downloadCenterEmpty, locale: locale))
                    .foregroundStyle(DownloadCenterAppearance.palette.secondaryText.color)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.filteredJobs) { job in
                            DownloadCardView(job: job, isSelected: store.selection.contains(job.id)) { job in
                                if job.status == .failed {
                                    optionsSheet = .failedPreflight(job)
                                } else {
                                    Task {
                                        if let session = await store.prepareQueuedJobEdit(job.id) {
                                            optionsSheet = .queued(session)
                                        }
                                    }
                                }
                            }
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
        .navigationTitle(sidebarTitle(for: store.sidebarSection, locale: locale))
    }

    @ViewBuilder
    private var analysisStatus: some View {
        switch store.analysisState {
        case .analyzing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.string(.downloadCenterAnalyzing, locale: locale))
                    .font(.subheadline)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        case let .failed(failure):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string(failure.summaryKey, locale: locale))
                        .font(.subheadline.weight(.semibold))
                    Text(L10n.string(failure.recoverySuggestionKey ?? failure.category.recoveryKey, locale: locale))
                        .font(.caption)
                        .foregroundStyle(DownloadCenterAppearance.palette.secondaryText.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(L10n.string(.downloadActionErrorDetails, locale: locale)) {
                    showsAnalysisErrorDetails = true
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        case .idle, .video, .playlist:
            EmptyView()
        }
    }

    private var bulkToolbar: some View {
        let presentation = DownloadCenterBulkPresentation(jobs: store.jobs)
        return HStack(spacing: 8) {
            bulkActionButton(
                title: L10n.string(.downloadCenterBulkStart, locale: locale),
                systemImage: presentation.symbol(for: .startAll),
                isDisabled: !presentation.isEnabled(.startAll)
            ) {
                route(.startAll)
            }

            bulkActionButton(
                title: L10n.string(.downloadCenterBulkPause, locale: locale),
                systemImage: presentation.symbol(for: .pauseAll),
                isDisabled: !presentation.isEnabled(.pauseAll)
            ) {
                route(.pauseAll)
            }

            bulkActionButton(
                title: L10n.string(.downloadCenterBulkResume, locale: locale),
                systemImage: presentation.symbol(for: .resumeAll),
                isDisabled: !presentation.isEnabled(.resumeAll)
            ) {
                route(.resumeAll)
            }

            bulkActionButton(
                title: L10n.string(.downloadCenterBulkCancel, locale: locale),
                systemImage: presentation.symbol(for: .cancelActiveAndWaiting),
                role: .destructive,
                isDisabled: !presentation.isEnabled(.cancelActiveAndWaiting)
            ) {
                route(.cancelActiveAndWaiting)
            }

            Spacer(minLength: 0)

            bulkActionButton(
                title: L10n.string(.downloadCenterBulkClearHistory, locale: locale),
                systemImage: presentation.symbol(for: .clearHistory),
                isDisabled: !presentation.isEnabled(.clearHistory)
            ) {
                route(.clearHistory)
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
        case .cancelActiveAndWaiting, .clearHistory:
            return
        }
    }

    private func performConfirmed(_ confirmation: DownloadConfirmation) {
        switch confirmation {
        case .cancelActiveAndWaiting:
            Task { await store.cancelActiveAndWaiting() }
        case .clearHistory:
            Task { await store.clearHistory() }
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
        .opacity(isDisabled ? 0.3 : 1)
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

    private func sidebarTitle(for section: DownloadStatus.SidebarSection, locale: Locale) -> String {
        switch section {
        case .all: L10n.string(.downloadCenterSidebarAll, locale: locale)
        case .running: L10n.string(.downloadCenterSidebarRunning, locale: locale)
        case .stopped: L10n.string(.downloadCenterSidebarStopped, locale: locale)
        case .completed: L10n.string(.downloadCenterSidebarCompleted, locale: locale)
        case .failed: L10n.string(.downloadCenterSidebarFailed, locale: locale)
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

@MainActor
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

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator {
        var parent: KeyboardCommandMonitor
        private var monitor: Any?

        init(parent: KeyboardCommandMonitor) {
            self.parent = parent
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
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
            DownloadCenterFocusClassifier.classify(
                DownloadCenterResponderContext(
                    urlFieldIsFocused: parent.urlFieldIsFocused,
                    playlistSelectionIsPresented: parent.playlistSelectionIsPresented,
                    modalSheetIsPresented: parent.modalSheetIsPresented,
                    responderIsEditableText: responderHierarchy(
                        responder,
                        contains: { $0 is NSTextView || $0 is NSTextField }
                    ),
                    responderIsControl: responderHierarchy(responder, contains: { $0 is NSControl })
                )
            )
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
