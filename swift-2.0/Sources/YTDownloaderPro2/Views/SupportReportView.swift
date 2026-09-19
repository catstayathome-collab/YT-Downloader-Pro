import AppKit
import SwiftUI

struct SupportReportView: View {
    @Environment(\.dismiss) private var dismiss

    private let environment: SupportReportDraft.Environment
    private let selectedJob: DownloadJob?
    private let selectedFailure: DownloadFailure?
    private let diagnosticLines: [String]
    private let writer: LocalSupportReportWriter

    @State private var category: SupportReportDraft.Category = .downloadFailure
    @State private var subject = ""
    @State private var message = ""
    @State private var enabledOptionalFields: Set<SupportReportPreviewPresentation.OptionalFieldKind> = []
    @State private var optionalValues = SupportReportComposer.OptionalValues()
    @State private var incidentID = UUID()
    @State private var saveFeedback: SaveFeedback?

    init(
        environment: SupportReportDraft.Environment,
        selectedJob: DownloadJob? = nil,
        selectedFailure: DownloadFailure? = nil,
        diagnosticLines: [String] = [],
        writer: LocalSupportReportWriter = LocalSupportReportWriter()
    ) {
        self.environment = environment
        self.selectedJob = selectedJob
        self.selectedFailure = selectedFailure
        self.diagnosticLines = diagnosticLines
        self.writer = writer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Create Support Report")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close support report")
            }

            Text("Nothing is sent automatically. Review the exact report below, then choose a folder to save a local JSON file.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    reportDetails
                    optionalInformation
                    exactPreview
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let saveFeedback {
                Label(saveFeedback.message, systemImage: saveFeedback.systemImage)
                    .foregroundStyle(saveFeedback.isError ? .red : .green)
                    .textSelection(.enabled)
                    .accessibilityLabel(saveFeedback.message)
            }

            HStack {
                Spacer()
                Button("Save Local Report...") { saveReport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave || previewPayload == nil)
                    .accessibilityLabel("Choose a folder and save the reviewed support report locally")
            }
        }
        .padding(24)
        .frame(minWidth: 680, idealWidth: 760, minHeight: 700, idealHeight: 780)
        .background(DownloadCenterAppearance.palette.windowBackground.color)
        .foregroundStyle(DownloadCenterAppearance.palette.primaryText.color)
        .preferredColorScheme(DownloadCenterAppearance.preferredScheme)
        .onChange(of: category) { _ in saveFeedback = nil }
        .onChange(of: subject) { _ in saveFeedback = nil }
        .onChange(of: message) { _ in saveFeedback = nil }
    }

    private var reportDetails: some View {
        GroupBox("Report Details") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Category", selection: $category) {
                    ForEach(Self.categories, id: \.self) { category in
                        Text(category.label).tag(category)
                    }
                }
                .accessibilityLabel("Support category")

                TextField("Subject", text: $subject)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Support report subject")

                Text("Message")
                    .font(.callout.weight(.medium))
                TextEditor(text: $message)
                    .font(.body)
                    .frame(minHeight: 110)
                    .padding(6)
                    .background(.background)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.separator, lineWidth: 1)
                    }
                    .accessibilityLabel("Support report message")
            }
            .padding(8)
        }
    }

    private var optionalInformation: some View {
        GroupBox("Optional Information") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Every item is off by default. Enable only information you want to include in the saved report.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ForEach(SupportReportPreviewPresentation.OptionalFieldKind.allCases, id: \.self) { kind in
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(kind.label, isOn: selectionBinding(for: kind))
                            .accessibilityLabel("Include \(kind.label)")

                        if enabledOptionalFields.contains(kind) {
                            TextField(kind.placeholder, text: valueBinding(for: kind))
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel(kind.label)

                            if kind.canRevealDownloadActivity {
                                Label(
                                    "This information can reveal viewing or download activity.",
                                    systemImage: "exclamationmark.shield"
                                )
                                .font(.caption)
                                .foregroundStyle(.orange)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(8)
        }
    }

    private var exactPreview: some View {
        GroupBox("Exact JSON Preview") {
            VStack(alignment: .leading, spacing: 8) {
                Text("The local file will contain exactly this JSON. File and screenshot fields store names only; no attachment or media file is copied.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ScrollView([.horizontal, .vertical]) {
                    Text(previewPayload ?? "The preview could not be created.")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(minHeight: 220, maxHeight: 320)
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.separator, lineWidth: 1)
                }
                .accessibilityLabel("Exact JSON support report preview")
            }
            .padding(8)
        }
    }

    private var composer: SupportReportComposer {
        SupportReportComposer(
            category: category,
            subject: subject,
            message: message,
            environment: environment,
            incidentID: incidentID,
            selectedJob: selectedJob,
            selectedFailure: selectedFailure,
            diagnosticLines: diagnosticLines,
            enabledOptionalFields: enabledOptionalFields,
            optionalValues: optionalValues
        )
    }

    private var previewPayload: String? {
        try? SupportReportJSONPreview(draft: composer.makeDraft()).payload
    }

    private var canSave: Bool {
        !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func selectionBinding(
        for kind: SupportReportPreviewPresentation.OptionalFieldKind
    ) -> Binding<Bool> {
        Binding(
            get: { enabledOptionalFields.contains(kind) },
            set: { isEnabled in
                if isEnabled {
                    enabledOptionalFields.insert(kind)
                } else {
                    enabledOptionalFields.remove(kind)
                }
                saveFeedback = nil
            }
        )
    }

    private func valueBinding(
        for kind: SupportReportPreviewPresentation.OptionalFieldKind
    ) -> Binding<String> {
        Binding(
            get: { optionalValues[keyPath: kind.valueKeyPath] },
            set: { value in
                optionalValues[keyPath: kind.valueKeyPath] = value
                saveFeedback = nil
            }
        )
    }

    @MainActor
    private func saveReport() {
        guard let directory = OutputFolderPicker.choose(prompt: "Save Report") else { return }
        do {
            let destination = try writer.write(composer.makeDraft(), to: directory)
            saveFeedback = SaveFeedback(
                message: "Saved locally: \(destination.path)",
                systemImage: "checkmark.circle.fill",
                isError: false
            )
        } catch {
            saveFeedback = SaveFeedback(
                message: "The report could not be saved. Choose another local folder and try again.",
                systemImage: "exclamationmark.triangle.fill",
                isError: true
            )
        }
    }
}

private extension SupportReportView {
    struct SaveFeedback: Equatable {
        var message: String
        var systemImage: String
        var isError: Bool
    }

    static let categories: [SupportReportDraft.Category] = [
        .downloadFailure,
        .privacy,
        .security,
        .copyright,
        .cancellation,
        .incorrectCharge,
        .accountRecovery,
        .general
    ]
}

private extension SupportReportDraft.Category {
    var label: String {
        switch self {
        case .downloadFailure: "Download failure"
        case .privacy: "Privacy"
        case .security: "Security"
        case .copyright: "Copyright"
        case .cancellation: "Cancellation"
        case .incorrectCharge: "Incorrect charge"
        case .accountRecovery: "Account recovery"
        case .general: "General"
        }
    }
}

private extension SupportReportPreviewPresentation.OptionalFieldKind {
    var label: String {
        switch self {
        case .sourceURL: "Source URL"
        case .mediaTitle: "Media title"
        case .selectedFormatID: "Selected format identifier"
        case .diagnosticExport: "Diagnostic export file name"
        case .screenshot: "Screenshot file name"
        case .contactEmail: "Contact email"
        case .mediaFile: "Media file name"
        }
    }

    var placeholder: String {
        switch self {
        case .sourceURL: "https://www.youtube.com/watch?v=..."
        case .mediaTitle: "Title shown by the app"
        case .selectedFormatID: "For example: 137+140"
        case .diagnosticExport: "diagnostics.jsonl"
        case .screenshot: "screenshot.png"
        case .contactEmail: "name@example.com"
        case .mediaFile: "video.mp4"
        }
    }

    var valueKeyPath: WritableKeyPath<SupportReportComposer.OptionalValues, String> {
        switch self {
        case .sourceURL: \SupportReportComposer.OptionalValues.sourceURL
        case .mediaTitle: \SupportReportComposer.OptionalValues.mediaTitle
        case .selectedFormatID: \SupportReportComposer.OptionalValues.selectedFormatID
        case .diagnosticExport: \SupportReportComposer.OptionalValues.diagnosticExportName
        case .screenshot: \SupportReportComposer.OptionalValues.screenshotName
        case .contactEmail: \SupportReportComposer.OptionalValues.contactEmail
        case .mediaFile: \SupportReportComposer.OptionalValues.mediaFileName
        }
    }
}
