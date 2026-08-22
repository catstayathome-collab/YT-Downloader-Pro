# Localization And Recovery Contract

## String Keys

`Sources/YTDownloaderPro2/Resources/Localizable.xcstrings` is the only translation source. Every shipped product string must have an `en`, `ja`, and `zh-Hant` value and a matching `L10n.Key` case. Use dot-separated names in the form `surface.component.intent`, such as `download.action.retry` or `settings.language.system`; error keys are always `error.<categoryRawValue>.summary` and `error.<categoryRawValue>.recovery`.

Use positional placeholders for localized grammar (`%1$@`, `%2$lld`) and pass complete values through `L10n.string`. Do not assemble sentences from translated fragments. `LocalizationTests` owns the explicit visible-key inventory, locale completeness check, and placeholder parity check, so add the key there in the same change.

SwiftPM ships the catalog source as a processed resource, while an Xcode app may compile it. `L10n` reads the same catalog directly when present and falls back to Foundation localization when it has been compiled; there is no second translation table.

## Locale Override

`AppSettings.languageOverride` is the single persisted override. Its supported values are `zh-Hant`, `en`, and `ja`; `nil` means follow the current macOS locale. Unsupported persisted values normalize to `nil`.

`LocalizedSceneRoot` observes `DownloadStore.settings` and applies `AppSettings.locale` through the root `\.locale` environment for both the main window and Settings scene. Views read `@Environment(\.locale)` and pass it to `L10n`, so changing the picker updates visible UI without relaunching. Do not add another language preference or cache localized user-facing strings in persisted jobs.

## Error Categories

`DownloadFailure.Category.rawValue` is a persistence contract. Do not rename or remove an existing case without a decoding migration. Every case must remain `CaseIterable` and own complete summary and recovery keys in all three locales.

`DownloadFailure.classify(stderr:context:exitCode:)` is the shared classifier. Specific recovery conditions take priority over context fallback: disk full, output permission, invalid URL, account access, unavailable/private/region, network interruption, 403/client validation, format reselection, and bundled component incompatibility. Context then selects generic analysis, download, post-processing, persistence recovery, or toolchain failure.

Cards and alerts show only localized summary and recovery text. Raw process output must never become primary copy. `technicalDetail` is sanitized at `DownloadFailure` initialization, remains selectable only in `ErrorDetailsView`, and diagnostics apply the stronger URL, argument, cookie, authorization, and token redaction path. Product messages refer to download or media-processing components rather than internal executable names.
