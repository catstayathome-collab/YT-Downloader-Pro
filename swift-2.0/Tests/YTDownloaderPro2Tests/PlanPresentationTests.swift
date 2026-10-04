import Foundation
import XCTest
@testable import YTDownloaderPro2

final class PlanPresentationTests: XCTestCase {
    private let locales = ["en", "ja", "zh-Hant"]

    func testEveryUpgradeEntryProducesOnlyASanitizedRoute() {
        let routes: [UpgradePresentationRoute] = [
            .init(denial: denial(feature: .videoHD, reason: .videoHeightRequiresPro)),
            .init(denial: denial(feature: .queueBatch, reason: .batchRequiresPro)),
            .init(denial: denial(feature: .playlistExpand, reason: .playlistRequiresPro)),
            .init(denial: denial(feature: .subtitleAdvanced, reason: .advancedSubtitlesRequirePro)),
            .init(requirement: .init(feature: .videoUHD, reason: .sourceQualityRequiresPro)),
            .settings
        ]

        XCTAssertEqual(routes, [
            .lockedQuality(.videoHeightRequiresPro),
            .batchInput,
            .playlistExpansion,
            .advancedSubtitles,
            .restrictedJob(feature: .videoUHD, reason: .sourceQualityRequiresPro),
            .settings
        ])
        XCTAssertEqual(Set(routes.map(\.id)).count, routes.count)
    }

    func testRestrictedJobRouteCannotRetainPrivateJobFields() {
        let privateValues = [
            "https://media-user:secret@example.test/watch?v=private",
            "Private title",
            "/Users/private/Downloads/private.mp4",
            "private-format-id",
            "private-thumbnail-path",
            "private-diagnostic",
            "private-account-id",
            "chrome"
        ]
        let job = DownloadJob(
            sourceURL: privateValues[0],
            title: privateValues[1],
            thumbnailCachePath: privateValues[4],
            sourceMetadata: privateValues[5],
            status: .paused,
            outputURL: URL(fileURLWithPath: privateValues[2]),
            options: DownloadOptions(
                videoQuality: .format(id: privateValues[3], label: "1080p"),
                cookies: .chrome
            ),
            accessRequirement: .init(feature: .videoHD, reason: .videoHeightRequiresPro)
        )

        let route = UpgradePresentationRoute(requirement: job.accessRequirement!)
        let reflectedRoute = String(reflecting: route)

        XCTAssertEqual(route, .restrictedJob(feature: .videoHD, reason: .videoHeightRequiresPro))
        for privateValue in privateValues {
            XCTAssertFalse(reflectedRoute.contains(privateValue), "Route leaked \(privateValue)")
        }
    }

    func testPlanSettingsNamesAndQualityLimitsAreLocalizedInEverySupportedLocale() {
        let expected: [String: (free: String, testPro: String, freeQuality: String, proQuality: String)] = [
            "en": ("Free", "Test Pro", "Up to 720p", "All supported qualities"),
            "ja": ("無料版", "テスト Pro", "最大720p", "対応するすべての画質"),
            "zh-Hant": ("免費版", "測試 Pro", "最高 720p", "所有支援的畫質")
        ]

        for localeIdentifier in locales {
            let locale = Locale(identifier: localeIdentifier)
            let values = expected[localeIdentifier]!
            let free = PlanSettingsPresentation(plan: .free)
            let pro = PlanSettingsPresentation(plan: .testPro)

            XCTAssertEqual(free.planName(locale: locale), values.free)
            XCTAssertEqual(pro.planName(locale: locale), values.testPro)
            XCTAssertEqual(free.qualityAccess(locale: locale), values.freeQuality)
            XCTAssertEqual(pro.qualityAccess(locale: locale), values.proQuality)
        }
    }

    func testLockLabelsAndRestrictedCardStateAreLocalizedInEverySupportedLocale() {
        let expected: [String: (badge: String, requires: String)] = [
            "en": ("Pro", "Requires Pro"),
            "ja": ("Pro", "Pro が必要"),
            "zh-Hant": ("Pro", "需要 Pro")
        ]
        let restricted = DownloadJob(
            sourceURL: "https://example.test/video",
            title: "Video",
            status: .paused,
            accessRequirement: .init(feature: .videoHD, reason: .videoHeightRequiresPro)
        )
        let card = DownloadCardPresentation(job: restricted)

        for localeIdentifier in locales {
            let locale = Locale(identifier: localeIdentifier)
            let values = expected[localeIdentifier]!
            XCTAssertEqual(L10n.string(.planProBadge, locale: locale), values.badge)
            XCTAssertEqual(L10n.string(.planRequiresPro, locale: locale), values.requires)
            XCTAssertEqual(card.statusLabel(locale: locale), values.requires)
        }
        XCTAssertEqual(card.actions, [.viewProFeatures, .cancel])
    }

    func testComparisonRowsAndUnavailableCopyAreCompleteInEverySupportedLocale() {
        let expectedUnavailable = [
            "en": "Upgrading is not available yet.",
            "ja": "アップグレードはまだ利用できません。",
            "zh-Hant": "升級功能尚未開放。"
        ]

        for localeIdentifier in locales {
            let locale = Locale(identifier: localeIdentifier)
            let presentation = PlanComparisonPresentation(currentPlan: .free, route: .settings)
            let rows = presentation.localizedRows(locale: locale)

            XCTAssertEqual(rows.map(\.id), [.quality, .urlInput, .playlist, .subtitles, .history, .support])
            XCTAssertTrue(rows.allSatisfy { !$0.title.isEmpty && !$0.freeValue.isEmpty && !$0.proValue.isEmpty })
            XCTAssertEqual(presentation.unavailableMessage(locale: locale), expectedUnavailable[localeIdentifier])
            XCTAssertEqual(presentation.actions, [.close])
            XCTAssertNil(presentation.externalURL)
        }
    }

    func testRouteReasonCopyIsLocalizedWithoutEmbeddingMediaData() {
        let expected = [
            "en": "Higher video quality requires Pro.",
            "ja": "より高い画質には Pro が必要です。",
            "zh-Hant": "更高畫質需要 Pro。"
        ]
        let presentation = PlanComparisonPresentation(
            currentPlan: .free,
            route: .lockedQuality(.videoHeightRequiresPro)
        )

        for localeIdentifier in locales {
            XCTAssertEqual(
                presentation.reason(locale: Locale(identifier: localeIdentifier)),
                expected[localeIdentifier]
            )
        }
    }

    private func denial(feature: FeatureID, reason: FeatureDenialReason) -> FeatureDenial {
        FeatureDenial(requiredFeature: feature, reason: reason, canChooseFreeAlternative: true)
    }
}
