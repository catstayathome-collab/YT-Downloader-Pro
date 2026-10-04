import SwiftUI

struct PlanComparisonView: View {
    @EnvironmentObject private var planController: PlanController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    let route: UpgradePresentationRoute

    var body: some View {
        let presentation = PlanComparisonPresentation(
            currentPlan: planController.currentPlan,
            route: route
        )
        let settings = PlanSettingsPresentation(plan: planController.currentPlan)

        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.string(.planComparisonTitle, locale: locale))
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                LabeledContent(
                    L10n.string(.planCurrent, locale: locale),
                    value: settings.planName(locale: locale)
                )
                LabeledContent(
                    L10n.string(.planQualityAccess, locale: locale),
                    value: settings.qualityAccess(locale: locale)
                )
            }

            Text(presentation.reason(locale: locale))
                .font(.body)
                .foregroundStyle(DownloadCenterAppearance.palette.secondaryText.color)

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                GridRow {
                    columnHeader(.planComparisonColumnFeature)
                    columnHeader(.planComparisonColumnFree)
                    columnHeader(.planComparisonColumnPro)
                }

                Divider().gridCellColumns(3)

                ForEach(presentation.localizedRows(locale: locale), id: \.id) { row in
                    GridRow {
                        Text(row.title).fontWeight(.medium)
                        Text(row.freeValue)
                        Text(row.proValue)
                    }
                    .font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            HStack(alignment: .center, spacing: 16) {
                Text(presentation.unavailableMessage(locale: locale))
                    .font(.callout)
                    .foregroundStyle(DownloadCenterAppearance.palette.secondaryText.color)

                Spacer(minLength: 20)

                Button(L10n.string(.commonClose, locale: locale)) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(L10n.string(.commonClose, locale: locale))
            }
        }
        .padding(24)
        .frame(minWidth: 640, idealWidth: 720, maxWidth: 820, minHeight: 440)
        .background(DownloadCenterAppearance.palette.windowBackground.color)
        .foregroundStyle(DownloadCenterAppearance.palette.primaryText.color)
        .preferredColorScheme(DownloadCenterAppearance.preferredScheme)
    }

    private func columnHeader(_ key: L10n.Key) -> some View {
        Text(L10n.string(key, locale: locale))
            .font(.headline)
    }
}
