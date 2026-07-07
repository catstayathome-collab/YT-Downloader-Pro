import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var store = DownloadStore()
    @State private var urlText = ""
    @State private var options = DownloadOptions()
    @State private var analysis: VideoAnalysis?
    @State private var isAnalyzing = false
    @State private var analysisError: String?

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 14) {
                Text("YT Downloader Pro")
                    .font(.title2.bold())

                Text(store.toolchainMessage)
                    .font(.caption)
                    .foregroundStyle(store.toolchainMessage == "Helpers ready" ? .green : .orange)

                URLInputView(text: $urlText) {
                    addAndStart()
                }
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

                HStack {
                    Button(isAnalyzing ? "Analyzing..." : "Analyze") {
                        analyze()
                    }
                    .disabled(isAnalyzing || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let analysis {
                        Text(analysis.title)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                if let analysisError {
                    Text(analysisError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }

                Picker("Format", selection: $options.format) {
                    ForEach(DownloadFormat.allCases) { format in
                        Text(format.rawValue.uppercased()).tag(format)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Audio only", isOn: $options.audioOnly)
                Toggle("Embed thumbnail", isOn: $options.embedThumbnail)

                if let analysis, !analysis.videoFormats.isEmpty, options.format == .mp4, !options.audioOnly {
                    Picker("Video", selection: videoSelection) {
                        ForEach(analysis.videoFormats) { format in
                            Text(format.label).tag(Optional(format.formatID))
                        }
                    }
                }

                if let analysis, !analysis.audioFormats.isEmpty {
                    Picker("Audio", selection: audioSelection) {
                        ForEach(analysis.audioFormats) { format in
                            Text(format.label).tag(Optional(format.formatID))
                        }
                    }
                }

                Picker("Subtitles", selection: $options.subtitleMode) {
                    ForEach(SubtitleMode.allCases) { mode in
                        Text(mode.rawValue.capitalized).tag(mode)
                    }
                }

                Picker("Cookies", selection: $options.cookiesMode) {
                    ForEach(CookiesMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                HStack {
                    Text(options.outputDirectory)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose...") {
                        chooseDirectory()
                    }
                }

                Button("Add to Queue") {
                    store.add(urls: urlText, options: options)
                    store.remember(options: options)
                    urlText = ""
                }
                .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Add & Start") {
                    addAndStart()
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                HStack {
                    Button(store.isQueueRunning ? "Queue Running" : "Start All") {
                        store.startQueue()
                    }
                    .disabled(store.isQueueRunning || store.jobs.allSatisfy { $0.status != .queued })

                    Button("Stop Queue") {
                        store.stopQueue()
                    }
                    .disabled(!store.isQueueRunning)
                }

                HStack {
                    Button("Clear Finished") {
                        store.removeCompleted()
                    }
                }

                Spacer()
            }
            .padding()
            .frame(minWidth: 300)
        } detail: {
            DownloadQueueView(store: store)
        }
        .frame(minWidth: 980, minHeight: 640)
        .onAppear {
            options = store.defaultOptions
        }
    }

    private var videoSelection: Binding<String?> {
        Binding {
            options.videoFormatID
        } set: { newValue in
            options.videoFormatID = newValue
            options.videoFormatLabel = analysis?.videoFormats.first { $0.formatID == newValue }?.label
            store.remember(options: options)
        }
    }

    private var audioSelection: Binding<String?> {
        Binding {
            options.audioFormatID
        } set: { newValue in
            options.audioFormatID = newValue
            options.audioFormatLabel = analysis?.audioFormats.first { $0.formatID == newValue }?.label
            store.remember(options: options)
        }
    }

    private func analyze() {
        isAnalyzing = true
        analysisError = nil
        Task {
            do {
                let result = try await store.analyzeFirstURL(in: urlText, options: options)
                analysis = result
                options.videoFormatID = result.videoFormats.first?.formatID
                options.videoFormatLabel = result.videoFormats.first?.label
                options.audioFormatID = result.audioFormats.first?.formatID
                options.audioFormatLabel = result.audioFormats.first?.label
                store.remember(options: options)
            } catch {
                analysisError = error.localizedDescription
            }
            isAnalyzing = false
        }
    }

    private func addAndStart() {
        guard !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.addAndStart(urls: urlText, options: options)
        store.remember(options: options)
        urlText = ""
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            options.outputDirectory = url.path
            store.remember(options: options)
        }
    }
}

struct URLInputView: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.string = text
        textView.minSize = NSSize(width: 0, height: 120)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            _text = text
            self.onSubmit = onSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                return false
            }
            text = textView.string
            onSubmit()
            return true
        }
    }
}

struct DownloadQueueView: View {
    @ObservedObject var store: DownloadStore

    var body: some View {
        List(store.jobs) { job in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(job.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(job.status.label)
                        .font(.caption.bold())
                        .foregroundStyle(color(for: job.status))
                }

                Text(job.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                ProgressView(value: job.progress)

                HStack {
                    Text("\(Int(job.progress * 100))%")
                    Text(job.speed)
                    if !job.outputPath.isEmpty {
                        Text(job.outputPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Start") { store.start(job) }
                        .disabled(job.status == .downloading || job.status == .merging || job.status == .completed)
                    Button("Pause") { store.pause(job) }
                        .disabled(job.status != .downloading)
                    Button("Cancel") { store.cancel(job) }
                        .disabled(job.status == .completed || job.status == .cancelled)
                    Button("Retry") { store.retry(job) }
                        .disabled(job.status != .failed && job.status != .paused)
                    Button("Remove") { store.remove(job) }
                        .disabled(job.status == .downloading || job.status == .merging)
                }
                .font(.caption)

                if let error = job.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func color(for status: DownloadStatus) -> Color {
        switch status {
        case .completed: .green
        case .failed: .red
        case .paused: .orange
        case .cancelled: .secondary
        default: .blue
        }
    }
}
