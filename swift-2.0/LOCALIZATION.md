# Localization And Recovery Contract

## String Keys

`Sources/YTDownloaderPro2/Resources/Localizable.xcstrings` is the only translation source. Every shipped product string must have an `en`, `ja`, and `zh-Hant` value and a matching `L10n.Key` case. Use dot-separated names in the form `surface.component.intent`, such as `download.action.retry` or `settings.language.system`; error keys are always `error.<categoryRawValue>.summary` and `error.<categoryRawValue>.recovery`.

Use positional placeholders for localized grammar (`%1$@`, `%2$lld`) and pass complete values through `L10n.string`. Do not assemble sentences from translated fragments. `LocalizationTests` owns the explicit visible-key inventory, locale completeness check, and placeholder parity check, so add the key there in the same change.

SwiftPM ships the catalog source as a processed resource, while an Xcode app may compile it. `L10n` reads the same catalog directly when present and falls back to Foundation localization when it has been compiled; there is no second translation table.

## Locale Override

`AppSettings.languageOverride` is the single persisted override. Its supported values are `zh-Hant`, `en`, and `ja`; `nil` means follow the current macOS locale. Unsupported persisted values normalize to `nil`.

`LocalizedSceneRoot` observes `DownloadStore.settings` and applies `AppSettings.locale` through the root `\.locale` environment for both the main window and Settings scene. Views read `@Environment(\.locale)` and pass it to `L10n`, so changing the picker updates visible UI without relaunching. Do not add another language preference or cache localized user-facing strings in persisted jobs.

Persisted format selections contain format identifiers and structured presentation fields, never a localized display label. `MediaFormatPresentation` generates picker labels from those fields and the current locale. The decoder accepts the previous English-label quality payload and migrates recognizable labels into structured fields; newly encoded quality payloads retain only the format ID.

Fallback titles carry an explicit `MediaTitleSource`. Only `.synthesizedUntitledVideo`, `.synthesizedUntitledPlaylist`, and `.synthesizedUnavailableVideo` are localized. `.metadata` and a missing source from an older archive preserve the title exactly, even when it is `Untitled video`, `Untitled playlist`, or `Unavailable video`.

## Error Categories

`DownloadFailure.Category.rawValue` is a persistence contract. Do not rename or remove an existing case without a decoding migration. Every case must remain `CaseIterable` and own complete summary and recovery keys in all three locales.

`DownloadFailure.classify(stderr:context:exitCode:)` is the shared classifier. Specific recovery conditions take priority over context fallback: disk full, output permission, invalid URL, account access, unavailable/private/region, network interruption, 403/client validation, format reselection, and bundled component incompatibility. Context then selects generic analysis, download, post-processing, persistence recovery, or toolchain failure. Keep the maintained helper-output variants in `LocalizationTests` whenever classifier matching changes.

Cards and alerts show only localized summary and recovery text. Failed cards reserve one summary line and two recovery lines at the minimum layout width; they never read `technicalDetail`. Raw process output must never become primary copy. `technicalDetail` is private-set and uses the strongest shared URL, argument, cookie-path, authorization, credential, and token sanitizer during both model initialization and legacy decoding, before UI or persistence can observe it. `ErrorDetailsView` is the only selectable technical-detail surface, and diagnostics apply the same sanitizer. Product messages refer to download or media-processing components rather than internal executable names.

`Category.supportsOptionsRecovery` is true only for authentication, format reselection, output permission, and disk-full failures. Their failed-card action opens the failed record's options, reanalyzes with the edited cookies/folder settings, and then presents only fresh formats before retrying the same stable job ID. Applying the edit rejects any selection outside that fresh metadata snapshot. Other categories keep the unchanged-options Retry action, so every recovery sentence must describe an operation exposed by its corresponding card action.
