import SwiftUI

struct ErrorDetailsLayout: Equatable {
    let sheetWidth: Double
    let sheetHeight: Double
    let headerHeight: Double
    let technicalDetailHeight: Double
    let doneRowHeight: Double
    let contentSpacing: Double
    let verticalPadding: Double
    let wrapsLongLines: Bool
    let doneButtonOutsideTechnicalScroll: Bool
}

enum ErrorDetailsPresentation {
    static let layout = ErrorDetailsLayout(
        sheetWidth: 520,
        sheetHeight: 420,
        headerHeight: 110,
        technicalDetailHeight: 190,
        doneRowHeight: 28,
        contentSpacing: 12,
        verticalPadding: 40,
        wrapsLongLines: true,
        doneButtonOutsideTechnicalScroll: true
    )
}

struct ErrorDetailsView: View {
    @Environment(\.dismiss) private var dismiss

    let failure: DownloadFailure

    private let layout = ErrorDetailsPresentation.layout

    var body: some View {
        VStack(alignment: .leading, spacing: layout.contentSpacing) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Download Error")
                    .font(.title3.weight(.semibold))

                Text(summary)
                    .foregroundStyle(DownloadCenterAppearance.palette.secondaryText.color)
                    .lineLimit(2)

                if let recovery = failure.recoverySuggestionKey {
                    Text(recovery)
                        .font(.subheadline)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }
            .frame(height: layout.headerHeight, alignment: .topLeading)

            if let detail = failure.technicalDetail, !detail.isEmpty {
                ScrollView(.vertical) {
                    Text(detail)
                        .font(.system(.body, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: layout.technicalDetailHeight)
                .background(DownloadCenterAppearance.palette.thumbnailBackground.color)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .frame(height: layout.doneRowHeight)
        }
        .padding(20)
        .frame(width: layout.sheetWidth, height: layout.sheetHeight, alignment: .topLeading)
        .background(DownloadCenterAppearance.palette.windowBackground.color)
        .foregroundStyle(DownloadCenterAppearance.palette.primaryText.color)
        .preferredColorScheme(DownloadCenterAppearance.preferredScheme)
    }

    private var summary: String {
        failure.summaryKey.replacingOccurrences(of: "error.", with: "").replacingOccurrences(of: ".summary", with: "")
    }
}
