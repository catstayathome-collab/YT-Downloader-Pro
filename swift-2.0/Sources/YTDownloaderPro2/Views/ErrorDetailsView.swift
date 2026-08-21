import SwiftUI

struct ErrorDetailsView: View {
    @Environment(\.dismiss) private var dismiss

    let failure: DownloadFailure

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Download Error")
                .font(.title3.weight(.semibold))

            Text(summary)
                .foregroundStyle(.secondary)

            if let recovery = failure.recoverySuggestionKey {
                Text(recovery)
                    .font(.subheadline)
            }

            if let detail = failure.technicalDetail, !detail.isEmpty {
                Text(detail)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 520)
    }

    private var summary: String {
        failure.summaryKey.replacingOccurrences(of: "error.", with: "").replacingOccurrences(of: ".summary", with: "")
    }
}
