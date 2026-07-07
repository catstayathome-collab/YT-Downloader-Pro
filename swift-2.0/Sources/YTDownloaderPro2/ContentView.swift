import SwiftUI

struct ContentView: View {
    @StateObject private var store = DownloadStore()
    @State private var urlText = ""
    @State private var options = DownloadOptions()

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 14) {
                Text("YT Downloader Pro")
                    .font(.title2.bold())

                Text(store.toolchainMessage)
                    .font(.caption)
                    .foregroundStyle(store.toolchainMessage == "Helpers ready" ? .green : .orange)

                TextEditor(text: $urlText)
                    .font(.body.monospaced())
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

                Picker("Format", selection: $options.format) {
                    ForEach(DownloadFormat.allCases) { format in
                        Text(format.rawValue.uppercased()).tag(format)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Audio only", isOn: $options.audioOnly)
                Toggle("Embed thumbnail", isOn: $options.embedThumbnail)

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
                    urlText = ""
                }
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
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            options.outputDirectory = url.path
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
