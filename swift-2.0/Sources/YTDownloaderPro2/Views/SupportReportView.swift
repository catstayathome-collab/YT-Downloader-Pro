import AppKit
import SwiftUI

struct SupportReportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

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
                Text(L10n.string(.supportReportTitle, locale: locale))
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(L10n.string(.commonClose, locale: locale)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(L10n.string(.commonClose, locale: locale))
            }

            Text(L10n.string(.supportReportNotice, locale: locale))
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
                Button(L10n.string(.supportReportSave, locale: locale)) { saveReport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave || previewPayload == nil)
                    .accessibilityLabel(L10n.string(.supportReportSave, locale: locale))
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
        GroupBox(L10n.string(.supportReportDetails, locale: locale)) {
            VStack(alignment: .leading, spacing: 12) {
                Picker(L10n.string(.supportReportCategory, locale: locale), selection: $category) {
                    ForEach(Self.categories, id: \.self) { category in
                        Text(category.label(locale: locale)).tag(category)
                    }
                }
                .accessibilityLabel(L10n.string(.supportReportCategory, locale: locale))

                TextField(L10n.string(.supportReportSubject, locale: locale), text: $subject)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10n.string(.supportReportSubject, locale: locale))

                Text(L10n.string(.supportReportMessage, locale: locale))
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
                    .accessibilityLabel(L10n.string(.supportReportMessage, locale: locale))
            }
            .padding(8)
        }
    }

    private var optionalInformation: some View {
        GroupBox(L10n.string(.supportReportOptionalTitle, locale: locale)) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.string(.supportReportOptionalDescription, locale: locale))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ForEach(SupportReportPreviewPresentation.OptionalFieldKind.allCases, id: \.self) { kind in
                    let fieldLabel = kind.label(locale: locale)
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(fieldLabel, isOn: selectionBinding(for: kind))
                            .accessibilityLabel(
                                L10n.string(.supportReportOptionalInclude, locale: locale, fieldLabel)
                            )

                        if enabledOptionalFields.contains(kind) {
                            TextField(fieldLabel, text: valueBinding(for: kind))
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel(fieldLabel)

                            if kind.canRevealDownloadActivity {
                                Label(
                                    L10n.string(.supportReportOptionalActivityWarning, locale: locale),
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
        GroupBox(L10n.string(.supportReportPreviewTitle, locale: locale)) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string(.supportReportPreviewDescription, locale: locale))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ScrollView([.horizontal, .vertical]) {
                    Text(previewPayload ?? L10n.string(.supportReportPreviewFailed, locale: locale))
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
                .accessibilityLabel(L10n.string(.supportReportPreviewTitle, locale: locale))
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
        guard let directory = OutputFolderPicker.choose(
            prompt: L10n.string(.supportReportSavePrompt, locale: locale)
        ) else { return }
        do {
            let destination = try writer.write(composer.makeDraft(), to: directory)
            saveFeedback = SaveFeedback(
                message: L10n.string(.supportReportSaved, locale: locale, destination.path),
                systemImage: "checkmark.circle.fill",
                isError: false
            )
        } catch {
            saveFeedback = SaveFeedback(
                message: L10n.string(.supportReportSaveFailed, locale: locale),
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
    func label(locale: Locale) -> String {
        switch self {
        case .downloadFailure: L10n.string(.supportReportCategoryDownloadFailure, locale: locale)
        case .privacy: L10n.string(.supportReportCategoryPrivacy, locale: locale)
        case .security: L10n.string(.supportReportCategorySecurity, locale: locale)
        case .copyright: L10n.string(.supportReportCategoryCopyright, locale: locale)
        case .cancellation: L10n.string(.supportReportCategoryCancellation, locale: locale)
        case .incorrectCharge: L10n.string(.supportReportCategoryIncorrectCharge, locale: locale)
        case .accountRecovery: L10n.string(.supportReportCategoryAccountRecovery, locale: locale)
        case .general: L10n.string(.supportReportCategoryGeneral, locale: locale)
        }
    }
}

private extension SupportReportPreviewPresentation.OptionalFieldKind {
    func label(locale: Locale) -> String {
        switch self {
        case .sourceURL: L10n.string(.supportReportFieldSourceURL, locale: locale)
        case .mediaTitle: L10n.string(.supportReportFieldMediaTitle, locale: locale)
        case .selectedFormatID: L10n.string(.supportReportFieldSelectedFormatID, locale: locale)
        case .diagnosticExport: L10n.string(.supportReportFieldDiagnosticExport, locale: locale)
        case .screenshot: L10n.string(.supportReportFieldScreenshot, locale: locale)
        case .contactEmail: L10n.string(.supportReportFieldContactEmail, locale: locale)
        case .mediaFile: L10n.string(.supportReportFieldMediaFile, locale: locale)
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
