import AppKit
import SwiftUI

struct DownloadCenterView: View {
    @EnvironmentObject private var store: DownloadStore

    @State private var url = ""
    @State private var showsBulkCancelConfirmation = false
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
        .alert("Cancel active and waiting downloads?", isPresented: $showsBulkCancelConfirmation) {
            Button("Cancel Downloads", role: .destructive) {
                Task { await store.cancelActiveAndWaiting() }
            }
            Button("Keep Downloads", role: .cancel) {}
        } message: {
            Text("Partial files for the selected downloads will be removed.")
        }
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
                    .foregroundStyle(.secondary)
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
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(sidebarTitle(for: store.sidebarSection))
    }

    private var bulkToolbar: some View {
        HStack(spacing: 8) {
            bulkActionButton(
                title: "Start All",
                systemImage: "play.fill",
                isDisabled: !store.jobs.contains(where: { $0.status == .queued })
            ) {
                Task { await store.startAll() }
            }

            bulkActionButton(
                title: "Pause All",
                systemImage: "pause.fill",
                isDisabled: !store.jobs.contains(where: { $0.status.canPause })
            ) {
                Task { await store.pauseAll() }
            }

            bulkActionButton(
                title: "Resume All",
                systemImage: "play.fill",
                isDisabled: !store.jobs.contains(where: { $0.status == .paused })
            ) {
                Task { await store.resumeAll() }
            }

            bulkActionButton(
                title: "Cancel Active/Waiting",
                systemImage: "xmark",
                role: .destructive,
                isDisabled: !store.jobs.contains(where: { $0.status == .queued || $0.status.isActive })
            ) {
                showsBulkCancelConfirmation = true
            }

            Spacer(minLength: 0)

            bulkActionButton(
                title: "Clear Completed",
                systemImage: "trash",
                isDisabled: !store.jobs.contains(where: { $0.status == .completed })
            ) {
                Task { await store.clearCompleted() }
            }
        }
        .controlSize(.small)
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
